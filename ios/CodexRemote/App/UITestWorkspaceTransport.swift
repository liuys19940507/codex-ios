#if DEBUG
import Foundation

actor UITestWorkspaceTransport: BridgeTransport {
    private var threads = [ThreadSummary(id: "fixture-thread", projectId: "fixture-project", title: "Fixture task", status: "idle", activeTurnId: nil, parentId: nil)]
    private let activity: Bool
    init(activity: Bool = false) {
        self.activity = activity
        if activity { threads.append(ThreadSummary(id: "fixture-child", projectId: "fixture-project", title: "Child fixture task", status: "idle", activeTurnId: nil, parentId: "fixture-thread")) }
    }
    func get<T: Decodable & Sendable>(_ path: String, as: T.Type) async throws -> T {
        let components = URLComponents(string: "https://fixture.invalid" + path)!
        switch components.path {
        case "/v1/info":
            return ServerInfo(apiVersion: 1, serverId: "fixture", codexVersion: "0.167.0", features: ["steer": true, "interrupt": true, "approvals": true]) as! T
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
            guard parts[3] == "snapshot" else { throw ConnectionError.invalidPath }
            var items = [Item(id: "reply", turnId: "fixture-turn", kind: "agentMessage", text: "Fixture reply", data: .object(["completed": .bool(true), "prefixComplete": .bool(true)]))]
            if activity && thread.parentId == nil {
                items = [Item(id: "user", turnId: "fixture-turn", kind: "userMessage", text: "检查任务渲染与跨端接管，保留中文和 emoji 😀", data: .object([:])),
                         Item(id: "reasoning", turnId: "fixture-turn", kind: "reasoning", text: "**检查会话状态**\n确认历史、草稿与控制权保持一致。", data: .object([:])),
                         Item(id: "command", turnId: "fixture-turn", kind: "commandExecution", text: String(repeating: "Long Unicode output 中文😀\r\n", count: 400), data: .object(["command": .string("controlled fixture command"), "status": .string("completed"), "exitCode": .number(0), "durationMs": .number(1234)])),
                         Item(id: "child", turnId: "fixture-turn", kind: "collabAgentToolCall", text: "", data: .object(["tool": .string("spawnAgent"), "status": .string("completed"), "childThreadIds": .array([.string("fixture-child")])])),
                         Item(id: "reply", turnId: "fixture-turn", kind: "agentMessage", text: "## 任务已完成\n\n支持 **Markdown**、列表与代码。\n\n| 检查 | 结果 |\n| --- | --- |\n| 历史同步 | 已完成 |\n| 草稿保留 | 中文😀 |\n\n```swift\nlet greeting = \"你好，Codex 😀\"\nprint(greeting)\n```\n\n" + String(repeating: "这是一段用于检查长回复滚动的内容。阅读历史时输入框应始终可见，不应被新输出推走。\n\n", count: 12), data: .object(["completed": .bool(true), "prefixComplete": .bool(true), "phase": .string("final_answer")]))]
            }
            return Snapshot(cursor: Cursor(epoch: "fixture", seq: 0), thread: thread,
                            items: items,
                            itemsCursor: nil, pending: [], policy: Snapshot.Policy(approvalPolicy: nil, sandbox: nil)) as! T
        }
    }
    func command(_ command: Command) async throws -> Operation {
        var result = JSONValue.null
        if command.method == .create {
            guard command.params["projectId"] == .string("fixture-project") else { throw ConnectionError.server(404, "Unknown project") }
            let thread = ThreadSummary(id: "created-fixture", projectId: "fixture-project", title: "Created fixture task", status: "idle", activeTurnId: nil, parentId: nil)
            threads.append(thread); result = .object(["threadId": .string(thread.id)])
        } else if case .string(let id) = command.params["threadId"], let index = threads.firstIndex(where: { $0.id == id }) {
            if command.method == .rename, case .string(let title) = command.params["title"] { threads[index].title = title }
            if command.method == .archive { threads.remove(at: index) }
        }
        return Operation(id: command.id, state: .accepted, result: result, message: nil)
    }
    nonisolated func events(after: Cursor?) -> AsyncThrowingStream<EventFrame, Error> { AsyncThrowingStream { _ in } }
    func close() async { }
}
#endif
