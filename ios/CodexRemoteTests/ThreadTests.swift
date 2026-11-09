import XCTest
@testable import CodexRemote

final class ThreadTests: XCTestCase {
    @MainActor
    func testLatestSearchWins() async throws {
        let transport = ThreadTransport(), model = ThreadListModel(transport: transport)
        let old = Task { await model.reload(projectID: nil, query: "old") }
        let waiting = await transport.waitForHeldRequest()
        XCTAssertTrue(waiting)
        await model.reload(projectID: "project", query: "new")
        await transport.release()
        await old.value
        XCTAssertEqual(model.threads.map(\.title), ["new"])
        XCTAssertFalse(model.loading)
        XCTAssertNil(model.message)
    }

    @MainActor
    func testPaginationDeduplicatesThreadIDs() async {
        let model = ThreadListModel(transport: ThreadTransport())
        await model.reload(projectID: nil, query: "")
        await model.loadMore()
        XCTAssertEqual(model.threads.map(\.id), ["one", "two", "three"])
        XCTAssertNil(model.nextCursor)
    }

    @MainActor
    func testPaginationCannotAppendToANewSearch() async {
        let transport = ThreadTransport(), model = ThreadListModel(transport: transport)
        await model.reload(projectID: nil, query: "")
        await transport.holdPage()
        let page = Task { await model.loadMore() }
        let waiting = await transport.waitForHeldRequest()
        XCTAssertTrue(waiting)
        await model.reload(projectID: nil, query: "new")
        await transport.release()
        await page.value
        XCTAssertEqual(model.threads.map(\.title), ["new"])
        XCTAssertNil(model.nextCursor)
    }

    @MainActor
    func testEmptyResultsAndFailedRequestsHaveDifferentState() async {
        let model = ThreadListModel(transport: ThreadTransport())
        await model.reload(projectID: nil, query: "fail")
        XCTAssertTrue(model.threads.isEmpty)
        XCTAssertNotNil(model.message)
        await model.reload(projectID: nil, query: "empty")
        XCTAssertTrue(model.threads.isEmpty)
        XCTAssertNil(model.message)
    }

    func testHistoryAnchorDeduplicatesAndPreservesCurrentCanonicalItem() {
        let old = historyItem("old", "old"), overlap = historyItem("overlap", "stale partial"), canonical = historyItem("overlap", "canonical"), latest = historyItem("new", "latest")
        let result = mergeHistory(older: [old, overlap], current: [canonical, latest])
        XCTAssertEqual(result.map(\.id), ["old", "overlap", "new"])
        XCTAssertEqual(result[1].text, "canonical")
    }

    func testDraftNamespacesAndRestart() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("drafts")
        let first = UUID(), other = UUID(), store = DraftStore(root: directory)
        try store.write("中文\n第二行", serverID: first, threadID: "same-thread")
        try store.write("Other server", serverID: other, threadID: "same-thread")
        try store.write("New task draft", serverID: first, threadID: "__new__:project")
        try store.write("Path stays local", serverID: first, threadID: "../../escape")
        let reopened = DraftStore(root: directory)
        XCTAssertEqual(try reopened.read(serverID: first, threadID: "same-thread"), "中文\n第二行")
        XCTAssertEqual(try reopened.read(serverID: other, threadID: "same-thread"), "Other server")
        XCTAssertEqual(try reopened.read(serverID: first, threadID: "__new__:project"), "New task draft")
        XCTAssertEqual(try reopened.read(serverID: first, threadID: "../../escape"), "Path stays local")
        XCTAssertEqual(try reopened.read(serverID: first, threadID: "missing"), "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("escape").path))
    }
}

private func historyItem(_ id: String, _ text: String) -> Item {
    Item(id: id, turnId: "turn", kind: "agentMessage", text: text, data: .object([:]))
}

private actor ThreadTransport: BridgeTransport {
    private var holdingPage = false
    private var held = false
    private var pending: CheckedContinuation<ThreadPage, Never>?
    func holdPage() { holdingPage = true }
    func waitForHeldRequest() async -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while !held && Date() < deadline { try? await Task.sleep(nanoseconds: 5_000_000) }
        return held
    }
    func release() {
        pending?.resume(returning: ThreadPage(data: [summary("late-old", "old")], nextCursor: nil))
        pending = nil; held = false
    }
    private func summary(_ id: String, _ title: String) -> ThreadSummary {
        ThreadSummary(id: id, projectId: "project", title: title, status: "notLoaded", activeTurnId: nil, parentId: nil)
    }
    func get<T: Decodable & Sendable>(_ path: String, as: T.Type) async throws -> T {
        let components = URLComponents(string: "https://fixture.example" + path)!
        let query = components.queryItems?.first(where: { $0.name == "query" })?.value ?? ""
        let cursor = components.queryItems?.first(where: { $0.name == "cursor" })?.value
        if query == "fail" { throw ConnectionError.server(503, "Unavailable") }
        if query == "old" || cursor != nil && holdingPage {
            holdingPage = false; held = true
            let page: ThreadPage = await withCheckedContinuation { pending = $0 }
            return page as! T
        }
        if query == "new" { return ThreadPage(data: [summary("new", "new")], nextCursor: nil) as! T }
        if query == "empty" { return ThreadPage(data: [], nextCursor: nil) as! T }
        if cursor != nil { return ThreadPage(data: [summary("two", "two"), summary("three", "three")], nextCursor: nil) as! T }
        return ThreadPage(data: [summary("one", "one"), summary("two", "two")], nextCursor: "next") as! T
    }
    func command(_ command: Command) async throws -> CodexRemote.Operation { throw ConnectionError.invalidPath }
    nonisolated func events(after: Cursor?) -> AsyncThrowingStream<EventFrame, Error> { AsyncThrowingStream { _ in } }
    func close() async { }
}
