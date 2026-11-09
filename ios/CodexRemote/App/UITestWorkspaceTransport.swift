#if DEBUG
import Foundation

actor UITestWorkspaceTransport: BridgeTransport {
    private var threads = [ThreadSummary(id: "fixture-thread", projectId: "fixture-project", title: "Fixture task", status: "idle", activeTurnId: nil, parentId: nil)]
    func get<T: Decodable & Sendable>(_ path: String, as: T.Type) async throws -> T {
        let components = URLComponents(string: "https://fixture.invalid" + path)!
        switch components.path {
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
            return Snapshot(cursor: Cursor(epoch: "fixture", seq: 0), thread: thread,
                            items: [Item(id: "reply", turnId: "fixture-turn", kind: "agentMessage", text: "Fixture reply", data: .object(["completed": .bool(true), "prefixComplete": .bool(true)]))],
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
