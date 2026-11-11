import Foundation
import Combine

struct ClientCommandError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct CommandRecord: Codable, Identifiable, Sendable {
    var id: String { receipt.id }
    let method: Command.Method
    let context: String
    let createdAt: String
    var receipt: Operation
    var reviewed: Bool
}

struct OperationJournal {
    let root: URL
    private let write: (Data, URL) throws -> Void
    init(root: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("CodexRemote/operations"),
         write: @escaping (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }) {
        self.root = root; self.write = write
    }
    private func url(_ serverID: UUID) -> URL { root.appendingPathComponent(serverID.uuidString + ".json") }
    func load(serverID: UUID) throws -> [CommandRecord] {
        let file = url(serverID)
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let values = try JSONDecoder().decode([CommandRecord].self, from: Data(contentsOf: file))
        guard Set(values.map(\.id)).count == values.count, values.allSatisfy({ UUID(uuidString: $0.id) != nil }) else { throw ConnectionError.invalidResponse }
        return values
    }
    @discardableResult
    func save(_ records: [CommandRecord], serverID: UUID) throws -> [CommandRecord] {
        // MainActor callers serialize access. A late screen's snapshot must
        // merge with the namespace on disk rather than replace newer UUIDs.
        var merged = try load(serverID: serverID)
        func priority(_ state: Operation.State) -> Int {
            switch state { case .pending: return 0; case .unknown: return 1; case .failed: return 2; case .accepted: return 3 }
        }
        for incoming in records {
            if let index = merged.firstIndex(where: { $0.id == incoming.id }) {
                let existing = merged[index]
                guard existing.method == incoming.method, existing.context == incoming.context else { throw ConnectionError.invalidResponse }
                let winner = priority(incoming.receipt.state) >= priority(existing.receipt.state) ? incoming.receipt : existing.receipt
                let other = winner == incoming.receipt ? existing.receipt : incoming.receipt
                merged[index].receipt = Operation(id: winner.id, state: winner.state, result: winner.result == .null ? other.result : winner.result, message: winner.message)
                merged[index].reviewed = existing.reviewed || incoming.reviewed
            } else { merged.append(incoming) }
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try write(JSONEncoder().encode(merged), url(serverID))
        return merged
    }
}

@MainActor
final class CommandSender: ObservableObject {
    @Published private(set) var records: [CommandRecord] = []
    @Published private(set) var lastOperation: Operation?
    @Published private(set) var busy = false
    @Published private(set) var checkingIDs = Set<String>()
    @Published private(set) var message: String?
    let serverID: UUID
    private let transport: any BridgeTransport
    private let journal: OperationJournal
    private let canSend: @MainActor (Command.Method) -> Bool
    private var unreadable = false
    private var inFlight = 0
    var unresolved: [CommandRecord] { records.filter { !$0.reviewed && ($0.receipt.state == .pending || $0.receipt.state == .unknown) } }

    init(serverID: UUID, transport: any BridgeTransport, journal: OperationJournal = OperationJournal(),
         canSend: @escaping @MainActor (Command.Method) -> Bool = { _ in true }) {
        self.serverID = serverID; self.transport = transport; self.journal = journal; self.canSend = canSend
        do {
            var loaded = try journal.load(serverID: serverID), changed = false
            for index in loaded.indices where loaded[index].receipt.state == .pending {
                let old = loaded[index].receipt
                loaded[index].receipt = Operation(id: old.id, state: .unknown, result: old.result, message: "上次发送结果尚未确认，请核对任务。")
                changed = true
            }
            if changed { loaded = try journal.save(loaded, serverID: serverID) }
            records = loaded
        } catch { unreadable = true; message = "无法读取操作记录。为避免重复提交，暂时不能发送。" }
    }

    func canSubmit(_ method: Command.Method) -> Bool { !unreadable && canSend(method) }
    func uploadAttachment(_ upload: AttachmentUpload, method: Command.Method) async throws -> UploadedAttachment {
        guard canSubmit(method) else { throw ClientCommandError(message: "请先连接服务并完成同步，再发送附件。") }
        return try await transport.uploadAttachment(upload)
    }
    func blocked(method: Command.Method, params: [String: JSONValue]) -> Operation? {
        unresolved.last(where: { $0.context == Self.context(method, params) })?.receipt
    }
    func submit(method: Command.Method, params: [String: JSONValue]) async -> Operation {
        if let existing = blocked(method: method, params: params) {
            lastOperation = existing; message = "之前的操作尚未确认，请先核对结果。"; return existing
        }
        guard canSubmit(method) else { return failure("请先连接服务并完成同步，再发送操作。") }
        let command = Command(id: UUID().uuidString, method: method, params: params)
        let pending = Operation(id: command.id, state: .pending, result: .null, message: nil)
        let entry = CommandRecord(method: method, context: Self.context(method, params), createdAt: ISO8601DateFormatter().string(from: Date()), receipt: pending, reviewed: false)
        do {
            var next = records; next.append(entry)
            records = try journal.save(next, serverID: serverID)
        } catch { return failure("无法保存操作标识，本次操作尚未发送。") }
        lastOperation = pending; message = nil; inFlight += 1; busy = true
        defer { inFlight -= 1; busy = inFlight > 0 }
        let receipt: Operation
        var queryAfterFailure = false
        do {
            let response = try await transport.command(command)
            guard response.id == command.id else { throw ConnectionError.invalidResponse }
            receipt = response
        } catch {
            let state: Operation.State
            if let failure = error as? ConnectionError, case .server(let status, _) = failure, [400, 401, 403, 404, 409, 413, 422].contains(status) { state = .failed }
            else { state = .unknown; queryAfterFailure = true }
            receipt = Operation(id: command.id, state: state, result: .null,
                                message: state == .unknown ? "操作可能已提交，正在核对结果，请勿重复发送。" : "服务未接受此操作，请刷新并检查输入。")
        }
        let saved = remember(receipt)
        if queryAfterFailure && saved.state == .unknown { return await reconcile(id: command.id) }
        return saved
    }

    func reconcile(id: String) async -> Operation {
        guard UUID(uuidString: id) != nil, let existing = records.first(where: { $0.id == id }) else {
            return Operation(id: id, state: .unknown, result: .null, message: "本机没有此操作的记录。")
        }
        checkingIDs.insert(id); defer { checkingIDs.remove(id) }
        let receipt: Operation
        do {
            let response = try await transport.get("/v1/operations/\(id)", as: Operation.self)
            guard response.id == id else { throw ConnectionError.invalidResponse }
            receipt = Operation(id: response.id, state: response.state, result: response.result == .null ? existing.receipt.result : response.result, message: response.message)
        } catch {
            receipt = Operation(id: id, state: .unknown, result: existing.receipt.result, message: "暂时无法确认结果，请查看任务后再决定，勿直接重复发送。")
        }
        return remember(receipt)
    }

    func acknowledgeReviewed(id: String) throws {
        guard !busy, let index = records.firstIndex(where: { $0.id == id }), records[index].receipt.state == .unknown else {
            throw ClientCommandError(message: "此操作仍在处理中，请稍后核对。")
        }
        var next = records; next[index].reviewed = true
        records = try journal.save(next, serverID: serverID)
    }
    func respond(request: Pending, snapshot: Snapshot, response: JSONValue, features: [String: Bool]) async -> Operation {
        do { return await submit(method: .respond, params: try CommandParameters.response(request: request, snapshot: snapshot, response: response, features: features)) }
        catch { return failure(error.localizedDescription) }
    }
    private func remember(_ receipt: Operation) -> Operation {
        if let index = records.firstIndex(where: { $0.id == receipt.id }) { records[index].receipt = receipt }
        lastOperation = receipt
        do {
            records = try journal.save(records, serverID: serverID)
            let saved = records.first(where: { $0.id == receipt.id })?.receipt ?? receipt
            lastOperation = saved; message = saved.message; return saved
        } catch { message = "已取得操作回执，但本机未能保存；重开后请核对结果。"; return receipt }
    }
    private func failure(_ message: String) -> Operation {
        let value = Operation(id: UUID().uuidString, state: .failed, result: .null, message: message)
        lastOperation = value; self.message = message; return value
    }
    private static func context(_ method: Command.Method, _ params: [String: JSONValue]) -> String {
        let key = method == .create ? "projectId" : method == .respond ? "requestId" : "threadId"
        let value: String
        if case .string(let id) = params[key] { value = id } else { value = "" }
        let turn: String
        if method == .interrupt, case .string(let id) = params["turnId"] { turn = ":" + id } else { turn = "" }
        return method.rawValue + ":" + value + turn
    }
}

enum InputMode: String, Sendable { case start, steer, queue }
enum CommandParameters {
    static func text(_ value: String, hasAttachments: Bool = false) throws {
        if !hasAttachments && value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw ClientCommandError(message: "请输入指令或添加附件。") }
        if value.utf8.count > 65536 { throw ClientCommandError(message: "单次输入最多64 KiB，请缩短内容。草稿已保留。") }
    }
    static func input(text: String, snapshot: Snapshot, mode: InputMode, features: [String: Bool], attachmentIDs: [String] = []) throws -> [String: JSONValue] {
        try self.text(text, hasAttachments: !attachmentIDs.isEmpty)
        var params: [String: JSONValue] = ["threadId": .string(snapshot.thread.id), "text": .string(text), "mode": .string(mode.rawValue)]
        if !attachmentIDs.isEmpty {
            guard features["attachments"] == true, attachmentIDs.count <= AttachmentLimits.count,
                  attachmentIDs.allSatisfy({ UUID(uuidString: $0) != nil }), Set(attachmentIDs.map { $0.lowercased() }).count == attachmentIDs.count else {
                throw ClientCommandError(message: "当前服务不支持这些附件，请更新服务后重试。")
            }
            params["attachments"] = .array(attachmentIDs.map { .string($0.lowercased()) })
        }
        if mode == .queue && features["queue"] != true { throw ClientCommandError(message: "服务不支持排队，内容已保留为草稿。") }
        if mode == .steer {
            guard features["steer"] == true, let turnID = snapshot.thread.activeTurnId else { throw ClientCommandError(message: "当前轮次不可追加指令，请刷新。") }
            params["expectedTurnId"] = .string(turnID)
        }
        if mode == .start && (snapshot.thread.activeTurnId != nil || snapshot.thread.status == "active") { throw ClientCommandError(message: "已有轮次正在运行，请追加指令或保留草稿。") }
        return params
    }
    static func response(request: Pending, snapshot: Snapshot, response: JSONValue, features: [String: Bool]) throws -> [String: JSONValue] {
        guard request.state == .pending, snapshot.pending.contains(request), request.threadId == snapshot.thread.id, request.turnId == snapshot.thread.activeTurnId else { throw ClientCommandError(message: "此请求已处理或所属轮次已变化，请刷新。") }
        let feature: String
        switch request.kind {
        case .command: feature = "approvals"
        case .file: feature = "fileApprovals"
        case .question: feature = "questions"
        case .permission: feature = "permissions"
        case .mcp: feature = "mcp"
        }
        guard features[feature] == true, case .object(let body) = response, case .object(let options) = request.options, options["readOnly"] != .bool(true) else {
            throw ClientCommandError(message: "请在 Windows CLI 中处理此请求。")
        }
        if request.kind == .command {
            guard Set(body.keys) == ["decision"], let decision = body["decision"], case .array(let offered) = options["availableDecisions"], offered.contains(decision) else { throw ClientCommandError(message: "请选择此请求提供的选项。") }
        } else if request.kind == .file {
            guard Set(body.keys) == ["decision"], let decision = body["decision"], [JSONValue.string("accept"), .string("decline"), .string("cancel")].contains(decision) else { throw ClientCommandError(message: "文件审批选项无效。") }
        } else if request.kind == .question {
            guard Set(body.keys) == ["answers"], case .object(let answers) = body["answers"], case .array(let questions) = options["questions"] else { throw ClientCommandError(message: "请完成所有问题。") }
            var ids = Set<String>()
            for raw in questions {
                guard case .object(let question) = raw, case .string(let id) = question["id"], ids.insert(id).inserted,
                      case .object(let answer) = answers[id], Set(answer.keys) == ["answers"], case .array(let values) = answer["answers"], !values.isEmpty else { throw ClientCommandError(message: "回答与当前问题不匹配。") }
                for value in values {
                    guard case .string(let text) = value, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ClientCommandError(message: "请完成所有问题。") }
                    if case .array(let choices) = question["options"], question["isOther"] != .bool(true) {
                        guard choices.contains(where: { if case .object(let option) = $0 { return option["label"] == .string(text) }; return false }) else { throw ClientCommandError(message: "请选择问题提供的选项。") }
                    }
                }
            }
            guard Set(answers.keys) == ids else { throw ClientCommandError(message: "回答与当前问题不匹配。") }
        } else if request.kind == .permission {
            guard Set(body.keys) == ["permissions", "scope"], body["scope"] == .string("turn"), case .object = body["permissions"] else { throw ClientCommandError(message: "只能授予本轮请求的权限。") }
        } else {
            guard options["mode"] == .string("form"), Set(body.keys) == ["action", "content", "_meta"], body["_meta"] == .null,
                  [.string("accept"), .string("decline"), .string("cancel")].contains(body["action"] ?? .null) else { throw ClientCommandError(message: "请在 Windows CLI 中处理此表单。") }
        }
        return ["requestId": .string(request.id), "threadId": .string(request.threadId), "turnId": .string(request.turnId), "response": response]
    }
}
