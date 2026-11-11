#if DEBUG
import Foundation

actor UITestWorkspaceTransport: BridgeTransport {
    private var threads = [ThreadSummary(id: "fixture-thread", projectId: "fixture-project", title: "Fixture task", status: "idle", activeTurnId: nil, parentId: nil)]
    private let activity: Bool
    private var pending: [Pending] = []
    private var sequence = 0
    private var outputCount = 0
    private var approvalCount = 0
    private var extraItems: [Item] = []
    private var replyOverride: Item?
    private var uploaded: [String: AttachmentUpload] = [:]
    private var createdAttachmentCount = 0
    private var history: [Envelope] = []
    private var subscribers: [UUID: AsyncThrowingStream<EventFrame, Error>.Continuation] = [:]
    init(activity: Bool = false) {
        self.activity = activity
        if ProcessInfo.processInfo.arguments.contains("--ui-test-pins") {
            threads += [ThreadSummary(id: "pin-one", projectId: "fixture-project", title: "Pin task one", status: "idle", activeTurnId: nil, parentId: nil),
                        ThreadSummary(id: "pin-two", projectId: "fixture-project", title: "Pin task two", status: "idle", activeTurnId: nil, parentId: nil)]
        }
        if activity { threads.append(ThreadSummary(id: "fixture-child", projectId: "fixture-project", title: "Child fixture task", status: "idle", activeTurnId: nil, parentId: "fixture-thread")) }
        if ProcessInfo.processInfo.arguments.contains("--ui-test-pending") {
            threads[0].status = "active"; threads[0].activeTurnId = "fixture-turn"
            pending = [Pending(id: "fixture-approval", threadId: "fixture-thread", turnId: "fixture-turn", kind: .command,
                               prompt: "Approve fixture command", options: .object(["itemId": .string("command"), "availableDecisions": .array([.string("accept"), .string("cancel")])]), state: .pending)]
        }
    }
    func get<T: Decodable & Sendable>(_ path: String, as: T.Type) async throws -> T {
        let components = URLComponents(string: "https://fixture.invalid" + path)!
        switch components.path {
        case "/v1/info":
            return ServerInfo(apiVersion: 1, serverId: "fixture", codexVersion: "0.167.0", features: ["steer": true, "interrupt": true, "approvals": true, "threadMetadata": true, "attachments": true]) as! T
        case "/v1/projects":
            return [Project(id: "fixture-project", name: "Fixture Project", path: "C:/fixture")] as! T
        case "/v1/models":
            return [ModelOption(id: "fixture-model", name: "Fixture model", reasoning: ["medium"])] as! T
        case "/v1/threads":
            let query = components.queryItems?.first(where: { $0.name == "query" })?.value ?? ""
            return ThreadPage(data: threads.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }, nextCursor: nil) as! T
        default:
            let parts = components.path.split(separator: "/")
            guard parts.count == 4, parts[1] == "threads", let thread = threads.first(where: { $0.id == parts[2] }) else { throw ConnectionError.invalidPath }
            if parts[3] == "items" { return ItemPage(data: [], nextCursor: nil) as! T }
            if parts[3] == "metadata" { return thread as! T }
            guard parts[3] == "snapshot" else { throw ConnectionError.invalidPath }
            let reply = thread.id == "created-fixture" && createdAttachmentCount > 0 ? "ATTACHMENTS_ACCEPTED_\(createdAttachmentCount)" : "Fixture reply"
            var items = [Item(id: "reply", turnId: "fixture-turn", kind: "agentMessage", text: reply, data: .object(["completed": .bool(true), "prefixComplete": .bool(true)]))]
            if activity && thread.parentId == nil {
                items = [Item(id: "user", turnId: "fixture-turn", kind: "userMessage", text: "检查任务渲染与跨端接管，保留中文和 emoji 😀", data: .object([:])),
                         Item(id: "reasoning", turnId: "fixture-turn", kind: "reasoning", text: "**检查会话状态**\n确认历史、草稿与控制权保持一致。", data: .object([:])),
                         Item(id: "command", turnId: "fixture-turn", kind: "commandExecution", text: String(repeating: "Long Unicode output 中文😀\r\n", count: 400), data: .object(["command": .string("controlled fixture command"), "status": .string("completed"), "exitCode": .number(0), "durationMs": .number(1234)])),
                         Item(id: "child", turnId: "fixture-turn", kind: "collabAgentToolCall", text: "", data: .object(["tool": .string("spawnAgent"), "status": .string("completed"), "childThreadIds": .array([.string("fixture-child")])])),
                         Item(id: "reply", turnId: "fixture-turn", kind: "agentMessage", text: "## 任务已完成\n\n支持 **Markdown**、列表与代码。\n\n| 检查 | 结果 |\n| --- | --- |\n| 历史同步 | 已完成 |\n| 草稿保留 | 中文😀 |\n\n```swift\nlet greeting = \"你好，Codex 😀\"\nprint(greeting)\n```\n\n" + String(repeating: "这是一段用于检查长回复滚动的内容。阅读历史时输入框应始终可见，不应被新输出推走。\n\n", count: 12), data: .object(["completed": .bool(true), "prefixComplete": .bool(true), "phase": .string("final_answer")]))]
            }
            if thread.id == "fixture-thread" {
                if let replacement = replyOverride, let index = items.firstIndex(where: { $0.id == replacement.id }) { items[index] = replacement }
                if !pending.isEmpty, let index = items.firstIndex(where: { $0.id == "command" }) {
                    var data = items[index].data.objectValue
                    data["status"] = .string("inProgress"); data.removeValue(forKey: "exitCode")
                    items[index].data = .object(data)
                }
                items += extraItems
            }
            return Snapshot(cursor: Cursor(epoch: "fixture", seq: sequence), thread: thread,
                            items: items,
                            itemsCursor: nil, pending: pending.filter { $0.threadId == thread.id }, policy: Snapshot.Policy(approvalPolicy: nil, sandbox: nil)) as! T
        }
    }
    func command(_ command: Command) async throws -> Operation {
        var result = JSONValue.null
        let attachmentIDs: [String]
        if case .array(let ids) = command.params["attachments"] {
            attachmentIDs = ids.compactMap { if case .string(let id) = $0 { return id }; return nil }
            guard attachmentIDs.count == ids.count, attachmentIDs.allSatisfy({ uploaded[$0] != nil }) else { throw ConnectionError.invalidResponse }
        } else { attachmentIDs = [] }
        if command.method == .create {
            guard command.params["projectId"] == .string("fixture-project") else { throw ConnectionError.server(404, "Unknown project") }
            let thread = ThreadSummary(id: "created-fixture", projectId: "fixture-project", title: "Created fixture task", status: "idle", activeTurnId: nil, parentId: nil)
            threads.append(thread); createdAttachmentCount = attachmentIDs.count; result = .object(["threadId": .string(thread.id)])
        } else if command.method == .input, !attachmentIDs.isEmpty {
            let reply = Item(id: "attachment-reply", turnId: "fixture-turn", kind: "agentMessage", text: "ATTACHMENTS_ACCEPTED_\(attachmentIDs.count)", data: .object(["completed": .bool(true), "prefixComplete": .bool(true)]))
            extraItems.append(reply); publish("item/upsert", data: Self.json(reply))
        } else if command.method == .respond {
            guard command.params["requestId"] == .string("fixture-approval"), command.params["threadId"] == .string("fixture-thread"),
                  command.params["turnId"] == .string("fixture-turn"), command.params["response"] == .object(["decision": .string("accept")]),
                  pending.first?.state == .pending, approvalCount == 0 else { throw ConnectionError.server(409, "Invalid or duplicate fixture approval") }
            approvalCount += 1; pending = []
            threads[0].status = "idle"; threads[0].activeTurnId = nil
            let reply = Item(id: "reply", turnId: "fixture-turn", kind: "agentMessage", text: "APPROVAL_ACCEPTED_ONCE",
                             data: .object(["completed": .bool(true), "prefixComplete": .bool(true), "phase": .string("final_answer")]))
            replyOverride = reply
            publish("pending/resolved", data: .object(["id": .string("fixture-approval")]))
            publish("item/upsert", data: Self.json(reply))
            publish("thread/upsert", data: Self.json(threads[0]))
            result = .object(["requestId": .string("fixture-approval"), "resolved": .bool(true)])
        } else if case .string(let id) = command.params["threadId"], let index = threads.firstIndex(where: { $0.id == id }) {
            if command.method == .rename, case .string(let title) = command.params["title"] { threads[index].title = title }
            if command.method == .archive { threads.remove(at: index) }
        }
        return Operation(id: command.id, state: .accepted, result: result, message: nil)
    }
    func uploadAttachment(_ upload: AttachmentUpload) async throws -> UploadedAttachment {
        guard upload.projectId == "fixture-project" else { throw ConnectionError.invalidPath }
        uploaded[upload.id] = upload
        return UploadedAttachment(id: upload.id, name: upload.name, kind: upload.kind,
                                  size: upload.base64.flatMap { Data(base64Encoded: $0)?.count } ?? 0)
    }
    func emitNextOutput() {
        outputCount += 1
        let item = Item(id: "live-output-\(outputCount)", turnId: "fixture-turn", kind: "agentMessage", text: "LIVE_OUTPUT_\(outputCount)",
                        data: .object(["completed": .bool(true), "prefixComplete": .bool(true), "phase": .string("final_answer")]))
        extraItems.append(item); publish("item/upsert", data: Self.json(item))
    }
    private func publish(_ type: String, data: JSONValue) {
        sequence += 1
        let event = Envelope(cursor: Cursor(epoch: "fixture", seq: sequence), threadId: "fixture-thread", type: type, data: data)
        history.append(event)
        for continuation in subscribers.values { continuation.yield(.event(event)) }
    }
    private static func json<T: Encodable>(_ value: T) -> JSONValue {
        try! JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }
    nonisolated func events(after: Cursor?) -> AsyncThrowingStream<EventFrame, Error> {
        AsyncThrowingStream { continuation in
            let id = UUID()
            Task { await self.addSubscriber(id, continuation: continuation, after: after) }
            continuation.onTermination = { @Sendable _ in Task { await self.removeSubscriber(id) } }
        }
    }
    private func addSubscriber(_ id: UUID, continuation: AsyncThrowingStream<EventFrame, Error>.Continuation, after: Cursor?) {
        subscribers[id] = continuation
        for event in history where event.cursor.seq > (after?.seq ?? 0) { continuation.yield(.event(event)) }
    }
    private func removeSubscriber(_ id: UUID) { subscribers.removeValue(forKey: id) }
    func close() async { let values = Array(subscribers.values); subscribers = [:]; values.forEach { $0.finish() } }
}
#endif
