import XCTest
@testable import CodexRemote

final class SyncTests: XCTestCase {
    @MainActor
    func testDeltaAppliedOnceAndCanonicalCompletionReplacesPartial() async throws {
        let f = try await fixture()
        f.bridge.feed.send(delta(1, "ha")); f.bridge.feed.send(delta(1, "ha")); f.bridge.feed.send(delta(2, "ha"))
        await eventually { f.store.cursor?.seq == 2 }
        XCTAssertEqual(f.store.snapshot?.items.first?.text, "haha")
        let item = Item(id: "item", turnId: "turn", kind: "agentMessage", text: "canonical haha", data: .object(["prefixComplete": .bool(true), "completed": .bool(true)]))
        let value = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(item))
        f.bridge.feed.send(Envelope(cursor: Cursor(epoch: "epoch", seq: 3), threadId: "thread", type: "item/upsert", data: value))
        await eventually { f.store.cursor?.seq == 3 }
        XCTAssertEqual(f.store.snapshot?.items.map(\.id), ["item"])
        XCTAssertEqual(f.store.snapshot?.items.first?.text, "canonical haha")
        await f.store.disconnect()
    }

    @MainActor
    func testOtherThreadAdvancesGlobalCursorBeforeFiltering() async throws {
        let f = try await fixture()
        f.bridge.feed.send(delta(1, "other", thread: "other")); f.bridge.feed.send(delta(2, "ha"))
        await eventually { f.store.cursor?.seq == 2 }
        XCTAssertEqual(f.store.snapshot?.items.first?.text, "ha")
        XCTAssertEqual(f.store.snapshot?.cursor.seq, 2)
        let reads = await f.bridge.reads
        XCTAssertEqual(reads, 1)
        await f.store.disconnect()
    }

    @MainActor
    func testSequenceGapRequestsSnapshotWithoutSendingAnyCommand() async throws {
        let f = try await fixture()
        await f.bridge.setSnapshot(base(text: "authoritative", seq: 3))
        f.bridge.feed.send(delta(3, "must not append"))
        await eventually { f.store.cursor?.seq == 3 && f.store.connectionState == .connected }
        XCTAssertEqual(f.store.snapshot?.items.first?.text, "authoritative")
        let reads = await f.bridge.reads, writes = await f.bridge.writes
        XCTAssertEqual(reads, 2); XCTAssertEqual(writes, 0)
        await f.store.disconnect()
    }

    @MainActor
    func testEpochMismatchResyncsAndStartsANewStream() async throws {
        let f = try await fixture()
        await f.bridge.setSnapshot(base(text: "new epoch", seq: 8, epoch: "new-epoch"))
        f.bridge.feed.send(Envelope(cursor: Cursor(epoch: "new-epoch", seq: 1), threadId: "thread", type: "pending/resolved", data: .object(["id": .string("old-request")])))
        await eventually { f.store.cursor?.epoch == "new-epoch" && f.store.connectionState == .connected }
        XCTAssertEqual(f.store.snapshot?.items.first?.text, "new epoch")
        XCTAssertEqual(f.bridge.feed.lastCursor?.seq, 8)
        await f.store.disconnect()
    }

    @MainActor
    func testOldConnectionCannotMutateNewServerEvenWithSameThreadID() async throws {
        let f = try await fixture()
        await f.bridge.holdNextSnapshot()
        let old = Task { await f.store.selectThread("thread") }
        let waiting = await f.bridge.waitForReads(2)
        XCTAssertTrue(waiting)
        let other = try ServerConfiguration(name: "Other", address: "https://other.example")
        let next = SyncTransport(snapshot: base(text: "other server", epoch: "other-epoch"))
        await f.store.connect(server: other, transport: next)
        await f.store.selectThread("thread")
        await f.bridge.release(base(text: "late previous server", seq: 90))
        await old.value
        f.bridge.feed.send(delta(91, "late old event"))
        await Task.yield()
        XCTAssertEqual(f.store.currentServerID, other.id)
        XCTAssertEqual(f.store.snapshot?.items.first?.text, "other server")
        XCTAssertEqual(f.store.cursor?.epoch, "other-epoch")
        await f.store.disconnect()
    }

    @MainActor
    func testSnapshotDoesNotLoseConcurrentDelta() async throws {
        let f = try await fixture(initial: base(text: "ha", seq: 1))
        await f.bridge.holdNextSnapshot()
        let reload = Task { await f.store.selectThread("thread") }
        let waiting = await f.bridge.waitForReads(2)
        XCTAssertTrue(waiting)
        f.bridge.feed.send(delta(2, "ha"))
        await eventually { f.store.cursor?.seq == 2 }
        await f.bridge.release(base(text: "ha", seq: 1))
        await reload.value
        XCTAssertEqual(f.store.snapshot?.items.first?.text, "haha")
        XCTAssertEqual(f.store.connectionState, .connected)
        await f.store.disconnect()
    }

    @MainActor
    func testCursorPersistenceIsScopedToServer() async throws {
        let f = try await fixture()
        f.bridge.feed.send(delta(1, "saved"))
        await eventually { f.store.cursor?.seq == 1 }
        let restored = CursorStore(url: f.cursorURL)
        XCTAssertEqual(try restored.load(serverID: f.server.id), Cursor(epoch: "epoch", seq: 1))
        XCTAssertNil(try restored.load(serverID: UUID()))
        await f.store.disconnect()
    }

    func testUnknownEventRemainsReadable() {
        let event = Envelope(cursor: Cursor(epoch: "epoch", seq: 1), threadId: "thread", type: "future/tool", data: .object([:]))
        let snapshot = reduce(snapshot: base(), event: event)
        XCTAssertEqual(snapshot.items.last?.kind, "unknown")
        XCTAssertTrue(snapshot.items.last?.text.contains("future/tool") == true)
    }

    @MainActor
    private func fixture(initial: Snapshot = base()) async throws -> (store: SessionStore, bridge: SyncTransport, server: ServerConfiguration, cursorURL: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("cursors.json")
        let bridge = SyncTransport(snapshot: initial)
        let store = SessionStore(makeTransport: { _ in bridge }, cursors: CursorStore(url: url))
        let server = try ServerConfiguration(name: "Windows", address: "http://10.147.21.2:8391")
        await store.connect(server: server)
        await store.selectThread("thread")
        await eventually { bridge.feed.streamCount > 0 }
        return (store, bridge, server, url)
    }

    @MainActor
    private func eventually(_ predicate: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(3)
        while !predicate() && Date() < deadline { try? await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertTrue(predicate(), "Timed out waiting for synchronization")
    }
}

private func base(text: String = "", seq: Int = 0, epoch: String = "epoch") -> Snapshot {
    Snapshot(cursor: Cursor(epoch: epoch, seq: seq),
             thread: ThreadSummary(id: "thread", projectId: "project", title: "Controlled", status: "active", activeTurnId: "turn", parentId: nil),
             items: [Item(id: "item", turnId: "turn", kind: "agentMessage", text: text, data: .object(["prefixComplete": .bool(false), "completed": .bool(false)]))],
             itemsCursor: nil, pending: [], policy: Snapshot.Policy(approvalPolicy: nil, sandbox: nil))
}

private func delta(_ seq: Int, _ text: String, thread: String = "thread") -> Envelope {
    Envelope(cursor: Cursor(epoch: "epoch", seq: seq), threadId: thread, type: "item/delta", data: .object(["id": .string("item"), "turnId": .string("turn"), "text": .string(text)]))
}

private actor SyncTransport: BridgeTransport {
    nonisolated let feed = SyncFeed()
    var reads = 0, writes = 0
    private var snapshot: Snapshot
    private var hold = false
    private var pending: CheckedContinuation<Snapshot, Never>?
    init(snapshot: Snapshot) { self.snapshot = snapshot }
    func setSnapshot(_ value: Snapshot) { snapshot = value }
    func holdNextSnapshot() { hold = true }
    func release(_ value: Snapshot) { snapshot = value; pending?.resume(returning: value); pending = nil }
    func waitForReads(_ count: Int) async -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while reads < count && Date() < deadline { try? await Task.sleep(nanoseconds: 5_000_000) }
        return reads >= count
    }
    func get<T: Decodable & Sendable>(_ path: String, as: T.Type) async throws -> T {
        reads += 1
        if hold { hold = false; return await withCheckedContinuation { pending = $0 } as! T }
        return snapshot as! T
    }
    func command(_ command: Command) async throws -> CodexRemote.Operation { writes += 1; throw ConnectionError.invalidPath }
    nonisolated func events(after: Cursor?) -> AsyncThrowingStream<EventFrame, Error> { feed.stream(after: after) }
    func close() async { }
}

private final class SyncFeed: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [AsyncThrowingStream<EventFrame, Error>.Continuation] = []
    private var cursors: [Cursor?] = []
    var streamCount: Int { lock.lock(); defer { lock.unlock() }; return cursors.count }
    var lastCursor: Cursor? { lock.lock(); defer { lock.unlock() }; return cursors.last ?? nil }
    func stream(after: Cursor?) -> AsyncThrowingStream<EventFrame, Error> {
        AsyncThrowingStream { continuation in
            lock.lock(); continuations.append(continuation); cursors.append(after); lock.unlock()
        }
    }
    func send(_ event: Envelope) {
        lock.lock(); let current = continuations; lock.unlock()
        for continuation in current { continuation.yield(.event(event)) }
    }
}
