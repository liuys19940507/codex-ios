import XCTest
@testable import CodexRemote

final class PinnedThreadTests: XCTestCase {
    @MainActor
    func testMultiplePinsUseLatestPinFirstWithoutDuplicatingRegularRows() async throws {
        let folder = temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let model = ThreadListModel(transport: PinTransport(), serverID: UUID(), pinStore: PinnedThreadStore(url: folder.appendingPathComponent("pins.json")))
        await model.reload(projectID: nil, query: "")
        model.togglePin(pinThread("one", "One")); model.togglePin(pinThread("two", "Two"))
        XCTAssertEqual(model.visiblePinnedThreads.map(\.id), ["two", "one"])
        XCTAssertEqual(model.unpinnedThreads.map(\.id), ["three"])
        model.togglePin(pinThread("one", "One"))
        XCTAssertEqual(model.visiblePinnedThreads.map(\.id), ["two"])
        XCTAssertEqual(model.unpinnedThreads.map(\.id), ["one", "three"])
        model.togglePin(pinThread("one", "One"))
        XCTAssertEqual(model.visiblePinnedThreads.map(\.id), ["one", "two"])
    }

    @MainActor
    func testPinsSurviveRestartAndStayScopedToTheConnection() throws {
        let folder = temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let store = PinnedThreadStore(url: folder.appendingPathComponent("pins.json")), first = UUID(), second = UUID()
        let model = ThreadListModel(transport: PinTransport(), serverID: first, pinStore: store)
        model.togglePin(pinThread("one", "中文😀")); model.togglePin(pinThread("two", "第二项"))
        let reopened = ThreadListModel(transport: PinTransport(), serverID: first, pinStore: PinnedThreadStore(url: store.url))
        XCTAssertEqual(reopened.pinnedThreads.map(\.title), ["第二项", "中文😀"])
        let other = ThreadListModel(transport: PinTransport(), serverID: second, pinStore: store)
        XCTAssertTrue(other.pinnedThreads.isEmpty)
        other.togglePin(pinThread("one", "Other connection"))
        XCTAssertEqual(try store.load(serverID: first).map(\.title), ["第二项", "中文😀"])
        XCTAssertEqual(try store.load(serverID: second).map(\.title), ["Other connection"])
    }

    @MainActor
    func testOlderPinsRemainAboveTheFirstPageAndRespectSearchAndProjectFilters() async throws {
        let folder = temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let store = PinnedThreadStore(url: folder.appendingPathComponent("pins.json")), server = UUID(), transport = PinTransport()
        try store.save([pinThread("older", "Old title"), pinThread("elsewhere", "Other", project: "other-project")], serverID: server)
        let model = ThreadListModel(transport: transport, serverID: server, pinStore: store)
        await model.reload(projectID: "project", query: "")
        XCTAssertEqual(model.visiblePinnedThreads.map(\.id), ["older"])
        XCTAssertEqual(model.visiblePinnedThreads.first?.title, "Updated 中文😀")
        XCTAssertEqual(model.visiblePinnedThreads.first?.status, "active")
        XCTAssertEqual(model.unpinnedThreads.map(\.id), ["one", "two", "three"])
        let reads = await transport.snapshotReads
        XCTAssertEqual(reads, ["older"])
        await model.reload(projectID: "project", query: "中文😀")
        XCTAssertEqual(model.visiblePinnedThreads.map(\.id), ["older"])
        XCTAssertTrue(model.unpinnedThreads.isEmpty)
        await model.reload(projectID: "other-project", query: "")
        XCTAssertEqual(model.visiblePinnedThreads.map(\.id), ["elsewhere"])
        let commands = await transport.commandCount
        XCTAssertEqual(commands, 0, "Pin refresh must not attach, send input, or acquire control")
    }

    @MainActor
    func testPaginationRefreshesPinMetadataWithoutChangingPinOrderOrDuplicatingRows() async throws {
        let folder = temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let store = PinnedThreadStore(url: folder.appendingPathComponent("pins.json")), server = UUID()
        try store.save([pinThread("two", "Stale two"), pinThread("one", "Stale one")], serverID: server)
        let model = ThreadListModel(transport: PinTransport(paginated: true), serverID: server, pinStore: store)
        await model.reload(projectID: nil, query: "")
        await model.loadMore()
        XCTAssertEqual(model.visiblePinnedThreads.map(\.id), ["two", "one"])
        XCTAssertEqual(model.visiblePinnedThreads.map(\.title), ["Fresh two", "Fresh one"])
        XCTAssertEqual(model.unpinnedThreads.map(\.id), ["three"])
        XCTAssertEqual(Set(model.threads.map(\.id)).count, 3)
        XCTAssertNil(model.nextCursor)
    }

    @MainActor
    func testTemporaryReadFailureKeepsThePinWhileNotFoundRemovesIt() async throws {
        let folder = temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let store = PinnedThreadStore(url: folder.appendingPathComponent("pins.json")), server = UUID()
        try store.save([pinThread("offline", "Keep me"), pinThread("deleted", "Gone")], serverID: server)
        let model = ThreadListModel(transport: PinTransport(), serverID: server, pinStore: store)
        await model.reload(projectID: nil, query: "")
        XCTAssertEqual(model.pinnedThreads.map(\.id), ["offline"])
        XCTAssertEqual(try store.load(serverID: server).map(\.id), ["offline"])
        XCTAssertNotNil(model.pinMessage)
    }

    @MainActor
    func testDelayedMetadataCannotResurrectAnUnpinnedTask() async throws {
        let folder = temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let store = PinnedThreadStore(url: folder.appendingPathComponent("pins.json")), server = UUID(), transport = PinTransport()
        let older = pinThread("older", "Old title")
        try store.save([older], serverID: server)
        await transport.holdOlder()
        let model = ThreadListModel(transport: transport, serverID: server, pinStore: store)
        let loading = Task { await model.reload(projectID: nil, query: "") }
        let held = await transport.waitForHeldRequest(); XCTAssertTrue(held)
        model.togglePin(older)
        await transport.releaseOlder(); await loading.value
        XCTAssertTrue(model.pinnedThreads.isEmpty)
        XCTAssertTrue(try store.load(serverID: server).isEmpty)
    }

    @MainActor
    func testFailedWritePreservesThePreviousPinOrder() throws {
        let folder = temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("pins.json"), server = UUID()
        try PinnedThreadStore(url: url).save([pinThread("one", "One")], serverID: server)
        let store = PinnedThreadStore(url: url, write: { _, _ in throw CocoaError(.fileWriteNoPermission) })
        let model = ThreadListModel(transport: PinTransport(), serverID: server, pinStore: store)
        model.togglePin(pinThread("two", "Two"))
        XCTAssertEqual(model.pinnedThreads.map(\.id), ["one"])
        XCTAssertEqual(try PinnedThreadStore(url: url).load(serverID: server).map(\.id), ["one"])
        XCTAssertNotNil(model.pinMessage)
    }

    @MainActor
    func testDamagedPinPreferencesDoNotHideOrdinaryTasks() async throws {
        let folder = temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("pins.json")
        try Data("{broken".utf8).write(to: url)
        let model = ThreadListModel(transport: PinTransport(), serverID: UUID(), pinStore: PinnedThreadStore(url: url))
        await model.reload(projectID: nil, query: "")
        XCTAssertEqual(model.unpinnedThreads.map(\.id), ["one", "two", "three"])
        XCTAssertNotNil(model.pinMessage)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "{broken")
    }
}

private func temporaryFolder() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
private func pinThread(_ id: String, _ title: String, project: String = "project", active: Bool = false) -> ThreadSummary {
    ThreadSummary(id: id, projectId: project, title: title, status: active ? "active" : "notLoaded", activeTurnId: active ? "turn" : nil, parentId: nil)
}

private actor PinTransport: BridgeTransport {
    let paginated: Bool
    private(set) var snapshotReads: [String] = []
    private(set) var commandCount = 0
    private var shouldHold = false
    private var pending: CheckedContinuation<Void, Never>?
    init(paginated: Bool = false) { self.paginated = paginated }
    func holdOlder() { shouldHold = true }
    func waitForHeldRequest() async -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while pending == nil && Date() < deadline { try? await Task.sleep(nanoseconds: 5_000_000) }
        return pending != nil
    }
    func releaseOlder() { pending?.resume(); pending = nil }
    func get<T: Decodable & Sendable>(_ path: String, as: T.Type) async throws -> T {
        let url = URLComponents(string: "https://fixture.invalid" + path)!
        if url.path == "/v1/threads" {
            let query = url.queryItems?.first(where: { $0.name == "query" })?.value ?? ""
            let project = url.queryItems?.first(where: { $0.name == "projectId" })?.value
            let cursor = url.queryItems?.first(where: { $0.name == "cursor" })?.value
            let page = cursor == nil ? [pinThread("one", "One"), pinThread("two", "Two"), pinThread("three", "Three")] : [pinThread("one", "Fresh one"), pinThread("two", "Fresh two")]
            let selected = (paginated && cursor == nil ? [page[0], page[2]] : page).filter {
                (project == nil || $0.projectId == project) && (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query))
            }
            return ThreadPage(data: selected, nextCursor: paginated && cursor == nil ? "next" : nil) as! T
        }
        let parts = url.path.split(separator: "/")
        guard parts.count == 4, parts[3] == "snapshot" else { throw ConnectionError.invalidPath }
        let id = String(parts[2]); snapshotReads.append(id)
        if id == "deleted" { throw ConnectionError.server(404, "Not found") }
        if id == "offline" { throw URLError(.networkConnectionLost) }
        if id == "older", shouldHold { shouldHold = false; await withCheckedContinuation { pending = $0 } }
        let thread = id == "older" ? pinThread(id, "Updated 中文😀", active: true) : pinThread(id, "Fresh " + id, project: id == "elsewhere" ? "other-project" : "project")
        return Snapshot(cursor: Cursor(epoch: "fixture", seq: 0), thread: thread, items: [], itemsCursor: nil, pending: [], policy: Snapshot.Policy(approvalPolicy: nil, sandbox: nil)) as! T
    }
    func command(_ command: Command) async throws -> CodexRemote.Operation { commandCount += 1; throw ConnectionError.invalidPath }
    nonisolated func events(after: Cursor?) -> AsyncThrowingStream<EventFrame, Error> { AsyncThrowingStream { _ in } }
    func close() async { }
}
