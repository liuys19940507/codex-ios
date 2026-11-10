import Foundation
import Combine

@MainActor
final class ComposerModel: ObservableObject {
    @Published var text: String { didSet { save() } }
    @Published private(set) var message: String?
    @Published private(set) var storageMessage: String?
    private(set) var writable = true
    private let serverID: UUID
    private let threadID: String
    private let drafts: DraftStore
    init(serverID: UUID, threadID: String, drafts: DraftStore = DraftStore()) {
        self.serverID = serverID; self.threadID = threadID; self.drafts = drafts
        do { text = try drafts.read(serverID: serverID, threadID: threadID) }
        catch { text = ""; writable = false; storageMessage = "无法读取本地草稿，原文件已保留。" }
    }
    private func save() {
        guard writable else { return }
        do { try drafts.write(text, serverID: serverID, threadID: threadID); storageMessage = nil }
        catch { storageMessage = "草稿未能保存，请复制内容后重试。" }
    }
    func submitInput(using sender: CommandSender, snapshot: Snapshot, mode: InputMode, features: [String: Bool]) async -> Operation? {
        guard writable else { return nil }
        let sent = text
        do {
            let params = try CommandParameters.input(text: sent, snapshot: snapshot, mode: mode, features: features)
            let result = await sender.submit(method: .input, params: params)
            finish(result, sent: sent); return result
        } catch { message = error.localizedDescription; return nil }
    }
    func submitCreate(using sender: CommandSender, projectID: String, model: String? = nil, reasoning: String? = nil) async -> Operation? {
        guard writable else { return nil }
        let sent = text
        do {
            try CommandParameters.text(sent)
            var params: [String: JSONValue] = ["projectId": .string(projectID), "text": .string(sent)]
            if let model { params["model"] = .string(model) }
            if let reasoning { params["reasoning"] = .string(reasoning) }
            let result = await sender.submit(method: .create, params: params)
            finish(result, sent: sent); return result
        } catch { message = error.localizedDescription; return nil }
    }
    private func finish(_ result: Operation, sent: String) {
        if result.state == .accepted && text == sent {
            guard (try? drafts.read(serverID: serverID, threadID: threadID)) == sent else {
                message = "输入已确认，本地草稿未清空，请核对内容。"; return
            }
            text = ""
        }
        switch result.state {
        case .accepted: message = text.isEmpty ? "输入已确认。" : "上一条输入已确认，当前编辑内容仍是草稿。"
        case .pending: message = "正在提交，请稍候。"
        case .unknown: message = "结果尚未确认，草稿已保留，请先核对任务。"
        case .failed: message = result.message ?? "本次输入未被接受，草稿已保留。"
        }
    }
}
