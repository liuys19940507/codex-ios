import Foundation
import Combine

@MainActor
final class ComposerModel: ObservableObject {
    @Published var text: String { didSet { save() } }
    @Published private(set) var message: String?
    @Published private(set) var storageMessage: String?
    @Published private(set) var attachments: [DraftAttachment] = []
    @Published private(set) var uploading = false
    @Published private(set) var importing = false
    private(set) var writable = true
    private let serverID: UUID
    private let threadID: String
    private let drafts: DraftStore
    private let attachmentStore: AttachmentDraftStore
    private var importsInProgress = 0
    var hasContent: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty }
    func beginAttachmentImport() { importsInProgress += 1; importing = true }
    func endAttachmentImport() { importsInProgress = max(0, importsInProgress - 1); importing = importsInProgress > 0 }
    init(serverID: UUID, threadID: String, drafts: DraftStore = DraftStore(), attachmentStore: AttachmentDraftStore? = nil) {
        self.serverID = serverID; self.threadID = threadID; self.drafts = drafts
        self.attachmentStore = attachmentStore ?? AttachmentDraftStore(root: drafts.root.appendingPathComponent("attachments"))
        do { text = try drafts.read(serverID: serverID, threadID: threadID) }
        catch { text = ""; writable = false; storageMessage = "无法读取本地草稿，原文件已保留。" }
        do { attachments = try self.attachmentStore.load(serverID: serverID, threadID: threadID) }
        catch { writable = false; storageMessage = "无法读取附件草稿，原文件已保留。请先核对本机存储。" }
    }
    private func save() {
        guard writable else { return }
        do { try drafts.write(text, serverID: serverID, threadID: threadID); storageMessage = nil }
        catch { storageMessage = "草稿未能保存，请复制内容后重试。" }
    }
    func importData(_ data: Data, name: String, kind: AttachmentKind) async throws {
        guard writable else { throw ClientCommandError(message: "草稿存储暂不可用，请先核对本机存储。") }
        guard attachments.count < AttachmentLimits.count else { throw ClientCommandError(message: "一次最多添加10个附件。") }
        try AttachmentLimits.filename(name); try AttachmentLimits.data(data)
        beginAttachmentImport(); defer { endAttachmentImport() }
        let store = attachmentStore, server = serverID
        let item = try await Task.detached(priority: .userInitiated) { try store.store(data, name: name, kind: kind, serverID: server) }.value
        do { try append(item) }
        catch { try? store.discardUnreferenced(item, serverID: server); throw error }
    }
    func addImageAddress(_ value: String, serverPath: Bool) async throws {
        let location = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !serverPath, location.lowercased().hasPrefix("data:image/") {
            guard let separator = location.range(of: ";base64,"), location.utf8.count <= 28 * 1024 * 1024,
                  let data = Data(base64Encoded: String(location[separator.upperBound...])) else { throw ClientCommandError(message: "图片 data URL 无效。") }
            let ext = location.lowercased().hasPrefix("data:image/jpeg") ? "jpg" : "png"
            try await importData(data, name: "图片地址." + ext, kind: .image); return
        }
        let kind: AttachmentKind = serverPath ? .serverImage : .imageURL
        try AttachmentLimits.imageLocation(location, kind: kind)
        try append(DraftAttachment(id: UUID(), name: serverPath ? "电脑图片" : "图片地址", kind: kind, location: location))
    }
    private func append(_ attachment: DraftAttachment) throws {
        var actual = try attachmentStore.load(serverID: serverID, threadID: threadID)
        guard actual.count < AttachmentLimits.count else { throw ClientCommandError(message: "一次最多添加10个附件。") }
        actual.append(attachment)
        try attachmentStore.write(actual, serverID: serverID, threadID: threadID)
        attachments = actual; message = nil
    }
    func removeAttachment(_ id: UUID) throws {
        let actual = try attachmentStore.load(serverID: serverID, threadID: threadID).filter { $0.id != id }
        try attachmentStore.write(actual, serverID: serverID, threadID: threadID)
        attachments = actual
    }
    func previewURL(_ attachment: DraftAttachment) -> URL? { try? attachmentStore.localURL(for: attachment, serverID: serverID) }
    func reportAttachmentError(_ error: Error) { message = error.localizedDescription }
    private func upload(_ items: [DraftAttachment], projectID: String, using sender: CommandSender, method: Command.Method) async throws {
        let store = attachmentStore, server = serverID
        let lease = try store.lease(items, serverID: server)
        defer { lease.release() }
        for (index, item) in items.enumerated() {
            message = "正在上传附件 \(index + 1)/\(items.count)…"
            let payload = try await Task.detached(priority: .userInitiated) { try store.payload(for: item, serverID: server, projectID: projectID) }.value
            let response = try await sender.uploadAttachment(payload, method: method)
            guard UUID(uuidString: response.id) == item.id, response.name == item.name, response.kind == item.kind,
                  response.size >= 0, response.size <= AttachmentLimits.bytes else { throw ConnectionError.invalidResponse }
            if let encoded = payload.base64 {
                let size = encoded.utf8.count / 4 * 3 - encoded.suffix(2).filter { $0 == "=" }.count
                guard response.size == size else { throw ConnectionError.invalidResponse }
            }
        }
    }
    func submitInput(using sender: CommandSender, snapshot: Snapshot, mode: InputMode, features: [String: Bool], stillCurrent: @MainActor () -> Bool = { true }) async -> Operation? {
        guard writable, !uploading, !importing else { return nil }
        let sent = text, sentAttachments = attachments
        do {
            let ids = sentAttachments.map { $0.id.uuidString.lowercased() }
            let params = try CommandParameters.input(text: sent, snapshot: snapshot, mode: mode, features: features, attachmentIDs: ids)
            if let blocked = sender.blocked(method: .input, params: params) { message = "之前的操作尚未确认，请先核对结果。"; return blocked }
            uploading = !sentAttachments.isEmpty; defer { uploading = false }
            try await upload(sentAttachments, projectID: snapshot.thread.projectId, using: sender, method: .input)
            guard stillCurrent() else { throw ClientCommandError(message: "当前会话状态已变化，附件和文字仍是草稿，请返回会话后发送。") }
            let result = await sender.submit(method: .input, params: params)
            finish(result, sent: sent, sentAttachments: sentAttachments); return result
        } catch { message = error.localizedDescription; return nil }
    }
    func submitCreate(using sender: CommandSender, projectID: String, model: String? = nil, reasoning: String? = nil, features: [String: Bool] = [:], stillCurrent: @MainActor () -> Bool = { true }) async -> Operation? {
        guard writable, !uploading, !importing else { return nil }
        let sent = text, sentAttachments = attachments
        do {
            try CommandParameters.text(sent, hasAttachments: !sentAttachments.isEmpty)
            if !sentAttachments.isEmpty, features["attachments"] != true { throw ClientCommandError(message: "当前服务不支持附件，请更新 Windows 桥接服务。") }
            var params: [String: JSONValue] = ["projectId": .string(projectID), "text": .string(sent)]
            if !sentAttachments.isEmpty { params["attachments"] = .array(sentAttachments.map { .string($0.id.uuidString.lowercased()) }) }
            if let model { params["model"] = .string(model) }
            if let reasoning { params["reasoning"] = .string(reasoning) }
            if let blocked = sender.blocked(method: .create, params: params) { message = "之前的操作尚未确认，请先核对结果。"; return blocked }
            uploading = !sentAttachments.isEmpty; defer { uploading = false }
            try await upload(sentAttachments, projectID: projectID, using: sender, method: .create)
            guard stillCurrent() else { throw ClientCommandError(message: "当前项目或连接状态已变化，草稿已保留，请重新发送。") }
            let result = await sender.submit(method: .create, params: params)
            finish(result, sent: sent, sentAttachments: sentAttachments); return result
        } catch { message = error.localizedDescription; return nil }
    }
    private func finish(_ result: Operation, sent: String, sentAttachments: [DraftAttachment]) {
        if result.state == .accepted, !sentAttachments.isEmpty {
            do {
                let submitted = Set(sentAttachments.map(\.id))
                let remaining = try attachmentStore.load(serverID: serverID, threadID: threadID).filter { !submitted.contains($0.id) }
                try attachmentStore.write(remaining, serverID: serverID, threadID: threadID)
                attachments = remaining
            } catch { storageMessage = "输入已确认，附件草稿未能清空，请核对后再发送。" }
        }
        if result.state == .accepted && text == sent {
            guard (try? drafts.read(serverID: serverID, threadID: threadID)) == sent else {
                message = "输入已确认，本地草稿未清空，请核对内容。"; return
            }
            text = ""
        }
        switch result.state {
        case .accepted: message = hasContent ? "上一条输入已确认，当前编辑内容仍是草稿。" : "输入已确认。"
        case .pending: message = "正在提交，请稍候。"
        case .unknown: message = "结果尚未确认，草稿已保留，请先核对任务。"
        case .failed: message = result.message ?? "本次输入未被接受，草稿已保留。"
        }
    }
}
