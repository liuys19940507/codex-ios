import XCTest
@testable import CodexRemote

final class LifecycleTests: XCTestCase {
    @MainActor
    func testForegroundResyncsBeforeWritesAndNeverReplaysCommands() async throws {
        let f = try await fixture()
        XCTAssertFalse(f.lifecycle.canWrite(.input))
        await f.lifecycle.setActive(true)
        XCTAssertTrue(f.lifecycle.canWrite(.input))
        await f.lifecycle.setActive(false)
        XCTAssertFalse(f.lifecycle.canWrite(.respond))
        await f.transport.holdNextSnapshot()
        let foreground = Task { await f.lifecycle.setActive(true) }
        let waiting = await f.transport.waitForHeldRead()
        XCTAssertTrue(waiting)
        XCTAssertFalse(f.lifecycle.canWrite(.input))
        let sender = CommandSender(serverID: f.server.id, transport: f.transport, journal: OperationJournal(root: f.root.appendingPathComponent("ops")), canSend: { f.lifecycle.canWrite($0) })
        let rejected = await sender.submit(method: .input, params: ["threadId": .string("thread"), "text": .string("must not send")])
        XCTAssertEqual(rejected.state, .failed)
        await f.transport.releaseSnapshot(lifecycleSnapshot(epoch: "fresh", pending: []))
        await foreground.value
        XCTAssertTrue(f.lifecycle.canWrite(.input))
        XCTAssertEqual(f.session.cursor?.epoch, "fresh")
        let posts = await f.transport.posts
        XCTAssertEqual(posts, 0)
        await f.session.disconnect()
    }

    @MainActor
    func testStaleApprovalAfterBackgroundIsDisabled() async throws {
        let f = try await fixture()
        await f.lifecycle.setActive(true)
        let old = try XCTUnwrap(f.session.snapshot?.pending.first)
        await f.lifecycle.setActive(false)
        await f.transport.setSnapshot(lifecycleSnapshot(pending: []))
        await f.lifecycle.setActive(true)
        XCTAssertTrue(f.session.snapshot?.pending.isEmpty == true)
        XCTAssertThrowsError(try CommandParameters.response(request: old, snapshot: XCTUnwrap(f.session.snapshot), response: .object(["decision": .string("accept")]), features: ["approvals": true]))
        let posts = await f.transport.posts
        XCTAssertEqual(posts, 0)
        await f.session.disconnect()
    }

    @MainActor
    func testUnsupportedApiCannotWriteAndLateForegroundCannotReactivateBackground() async throws {
        let f = try await fixture()
        await f.transport.setAPI(2)
        await f.lifecycle.setActive(true)
        XCTAssertFalse(f.lifecycle.canWrite(.create))
        XCTAssertNotNil(f.lifecycle.message)
        await f.transport.setAPI(1)
        await f.transport.holdNextSnapshot()
        let foreground = Task { await f.lifecycle.setActive(true) }
        let waiting = await f.transport.waitForHeldRead()
        XCTAssertTrue(waiting)
        await f.lifecycle.setActive(false)
        await f.transport.releaseSnapshot(lifecycleSnapshot())
        await foreground.value
        XCTAssertFalse(f.lifecycle.canWrite(.respond))
        await f.session.disconnect()
    }

    @MainActor
    private func fixture() async throws -> (session: SessionStore, lifecycle: LifecycleController, transport: LifecycleTransport, server: ServerConfiguration, root: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let server = try ServerConfiguration(name: "Fixture", address: "https://fixture.invalid")
        let transport = LifecycleTransport(), session = SessionStore(cursors: CursorStore(url: root.appendingPathComponent("cursor")))
        await session.connect(server: server, transport: transport)
        await session.selectThread("thread")
        return (session, LifecycleController(session: session, server: server, transport: transport), transport, server, root)
    }
}

private func lifecycleSnapshot(epoch: String = "epoch", pending: [Pending]? = nil) -> Snapshot {
    Snapshot(cursor: Cursor(epoch: epoch, seq: 0), thread: ThreadSummary(id: "thread", projectId: "project", title: "Fixture", status: "active", activeTurnId: "turn", parentId: nil), items: [], itemsCursor: nil,
             pending: pending ?? [Pending(id: "request", threadId: "thread", turnId: "turn", kind: .command, prompt: "Controlled", options: .object(["availableDecisions": .array([.string("accept")])]), state: .pending)],
             policy: Snapshot.Policy(approvalPolicy: nil, sandbox: nil))
}

private actor LifecycleTransport: BridgeTransport {
    private var api = 1, held = false
    private var continuation: CheckedContinuation<Snapshot, Never>?
    private var snapshot = lifecycleSnapshot()
    var posts = 0
    func setAPI(_ value: Int) { api = value }
    func setSnapshot(_ value: Snapshot) { snapshot = value }
    func holdNextSnapshot() { held = true }
    func waitForHeldRead() async -> Bool {
        let until = Date().addingTimeInterval(3)
        while continuation == nil && Date() < until { try? await Task.sleep(nanoseconds: 5_000_000) }
        return continuation != nil
    }
    func releaseSnapshot(_ value: Snapshot) { snapshot = value; continuation?.resume(returning: value); continuation = nil }
    func get<T: Decodable & Sendable>(_ path: String, as: T.Type) async throws -> T {
        if path == "/v1/info" { return ServerInfo(apiVersion: api, serverId: "fixture", codexVersion: "0.167.0", features: ["approvals": true]) as! T }
        if held { held = false; return await withCheckedContinuation { continuation = $0 } as! T }
        return snapshot as! T
    }
    func command(_ command: Command) async throws -> CodexRemote.Operation { posts += 1; throw ConnectionError.invalidPath }
    nonisolated func events(after: Cursor?) -> AsyncThrowingStream<EventFrame, Error> { AsyncThrowingStream { _ in } }
    func close() async { }
}
