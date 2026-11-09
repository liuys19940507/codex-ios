#if DEBUG
import Foundation

actor UITestWorkspaceTransport: BridgeTransport {
    private let thread = ThreadSummary(id: "fixture-thread", projectId: "fixture-project", title: "Fixture task", status: "idle", activeTurnId: nil, parentId: nil)
    func get<T: Decodable & Sendable>(_ path: String, as: T.Type) async throws -> T {
        let components = URLComponents(string: "https://fixture.invalid" + path)!
        switch components.path {
        case "/v1/projects":
            return [Project(id: "fixture-project", name: "Fixture Project", path: "C:/fixture")] as! T
        case "/v1/models":
            return [ModelOption(id: "fixture-model", name: "Fixture model", reasoning: ["medium"])] as! T
        case "/v1/threads":
            let query = components.queryItems?.first(where: { $0.name == "query" })?.value ?? ""
            return ThreadPage(data: query.isEmpty || thread.title.localizedCaseInsensitiveContains(query) ? [thread] : [], nextCursor: nil) as! T
        case "/v1/threads/fixture-thread/snapshot":
            return Snapshot(cursor: Cursor(epoch: "fixture", seq: 0), thread: thread,
                            items: [Item(id: "reply", turnId: "fixture-turn", kind: "agentMessage", text: "Fixture reply", data: .object(["completed": .bool(true), "prefixComplete": .bool(true)]))],
                            itemsCursor: nil, pending: [], policy: Snapshot.Policy(approvalPolicy: nil, sandbox: nil)) as! T
        case "/v1/threads/fixture-thread/items": return ItemPage(data: [], nextCursor: nil) as! T
        default: throw ConnectionError.invalidPath
        }
    }
    func command(_ command: Command) async throws -> Operation { throw ConnectionError.invalidPath }
    nonisolated func events(after: Cursor?) -> AsyncThrowingStream<EventFrame, Error> { AsyncThrowingStream { _ in } }
    func close() async { }
}
#endif
