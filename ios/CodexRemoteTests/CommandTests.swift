import XCTest
@testable import CodexRemote

final class CommandTests: XCTestCase {
    @MainActor
    func testSteerPinsTurnAndClearsOnlyConfirmedDraft() async throws {
        let f = try fixture(), drafts = DraftStore(root: f.root.appendingPathComponent("drafts"))
        let composer = ComposerModel(serverID: f.serverID, threadID: "thread", drafts: drafts)
        composer.text = "中文;&$ private-input-marker"
        let result = await composer.submitInput(using: f.sender, snapshot: active(), mode: .steer, features: ["steer": true])
        XCTAssertEqual(result?.state, .accepted)
        let posts = await f.transport.posts
        XCTAssertEqual(posts.count, 1)
        XCTAssertEqual(posts[0].params["expectedTurnId"], .string("turn"))
        XCTAssertEqual(posts[0].params["text"], .string("中文;&$ private-input-marker"))
        XCTAssertEqual(composer.text, "")
        XCTAssertEqual(try drafts.read(serverID: f.serverID, threadID: "thread"), "")
    }

    @MainActor
    func testTimeoutQueriesWithoutRepost() async throws {
        let f = try fixture(behavior: .timeout)
        let result = await f.sender.submit(method: .input, params: ["threadId": .string("thread"), "text": .string("once"), "mode": .string("start")])
        XCTAssertEqual(result.state, .unknown)
        let reads = await f.transport.reads, posts = await f.transport.posts
        XCTAssertEqual(posts.count, 1); XCTAssertEqual(reads, 1)
        let checked = await f.sender.reconcile(id: result.id)
        XCTAssertEqual(checked.state, .unknown)
        let repeatedPosts = await f.transport.posts
        XCTAssertEqual(repeatedPosts.count, 1)
    }

    @MainActor
    func testResolvedApprovalIsDisabled() async throws {
        let f = try fixture()
        let result = await f.sender.respond(request: pending(state: .resolved), snapshot: active(), response: .object(["decision": .string("accept")]), features: ["approvals": true])
        XCTAssertEqual(result.state, .failed)
        let posts = await f.transport.posts
        XCTAssertTrue(posts.isEmpty)
    }

    @MainActor
    func testExactOfferedApprovalInCurrentSnapshotPostsOnce() async throws {
        let f = try fixture()
        let result = await f.sender.respond(request: pending(), snapshot: active(), response: .object(["decision": .string("accept")]), features: ["approvals": true])
        XCTAssertEqual(result.state, .accepted)
        let posts = await f.transport.posts
        XCTAssertEqual(posts.count, 1)
        XCTAssertEqual(posts.first?.params["requestId"], .string("request"))
        XCTAssertEqual(posts.first?.params["response"], .object(["decision": .string("accept")]))
    }

    @MainActor
    func testApprovalRejectsUnrequestedDecision() async throws {
        let f = try fixture()
        let result = await f.sender.respond(request: pending(), snapshot: active(), response: .object(["decision": .string("acceptForSession")]), features: ["approvals": true])
        XCTAssertEqual(result.state, .failed)
        let posts = await f.transport.posts
        XCTAssertTrue(posts.isEmpty)
    }

    @MainActor
    func testUnsupportedQueueKeepsDraft() async throws {
        let f = try fixture(), drafts = DraftStore(root: f.root.appendingPathComponent("drafts"))
        let composer = ComposerModel(serverID: f.serverID, threadID: "thread", drafts: drafts)
        composer.text = "中文\n下一步"
        let result = await composer.submitInput(using: f.sender, snapshot: active(), mode: .queue, features: ["queue": false])
        XCTAssertNil(result)
        XCTAssertEqual(composer.text, "中文\n下一步")
        XCTAssertEqual(try drafts.read(serverID: f.serverID, threadID: "thread"), composer.text)
        let posts = await f.transport.posts
        XCTAssertTrue(posts.isEmpty)
    }

    @MainActor
    func testPartialCreateIsNotPostedAgainUntilExplicitlyReviewed() async throws {
        let f = try fixture(behavior: .partial)
        let params: [String: JSONValue] = ["projectId": .string("project"), "text": .string("once")]
        let first = await f.sender.submit(method: .create, params: params)
        let second = await f.sender.submit(method: .create, params: params)
        XCTAssertEqual(first.state, .unknown)
        XCTAssertEqual(first.result, .object(["threadId": .string("created-thread")]))
        XCTAssertEqual(second.id, first.id)
        let posts = await f.transport.posts
        XCTAssertEqual(posts.count, 1)
    }

    @MainActor
    func testRestartKeepsUnknownAndOnlyQueriesTheOriginalUUID() async throws {
        let f = try fixture(behavior: .timeout)
        let first = await f.sender.submit(method: .create, params: ["projectId": .string("project"), "text": .string("once")])
        let reopened = CommandSender(serverID: f.serverID, transport: f.transport, journal: OperationJournal(root: f.root.appendingPathComponent("operations")))
        let checked = await reopened.reconcile(id: first.id)
        XCTAssertEqual(checked.id, first.id); XCTAssertEqual(checked.state, .unknown)
        let posts = await f.transport.posts
        XCTAssertEqual(posts.count, 1)
    }

    @MainActor
    func testJournalFailurePreventsPost() async throws {
        let f = try fixture(write: { _, _ in throw CocoaError(.fileWriteNoPermission) })
        let result = await f.sender.submit(method: .create, params: ["projectId": .string("project"), "text": .string("do not send")])
        XCTAssertEqual(result.state, .failed)
        let posts = await f.transport.posts
        XCTAssertTrue(posts.isEmpty)
    }

    @MainActor
    func testReadinessGatePreventsWrites() async throws {
        let f = try fixture(ready: false)
        let result = await f.sender.submit(method: .interrupt, params: ["threadId": .string("thread"), "turnId": .string("turn")])
        XCTAssertEqual(result.state, .failed)
        let posts = await f.transport.posts
        XCTAssertTrue(posts.isEmpty)
    }

    @MainActor
    func testJournalNeverPersistsInputBodyEvenBeforeAcknowledgement() async throws {
        var writes: [String] = []
        let f = try fixture(write: { data, url in writes.append(String(decoding: data, as: UTF8.self)); try data.write(to: url, options: .atomic) })
        _ = await f.sender.submit(method: .create, params: ["projectId": .string("project"), "text": .string("private-input-marker")])
        XCTAssertFalse(writes.isEmpty)
        XCTAssertTrue(writes.allSatisfy { !$0.contains("private-input-marker") })
    }

    @MainActor
    func testAcknowledgementFromOldComposerCannotEraseANewerPersistedDraft() async throws {
        let f = try fixture(behavior: .held), drafts = DraftStore(root: f.root.appendingPathComponent("drafts"))
        let composer = ComposerModel(serverID: f.serverID, threadID: "thread", drafts: drafts)
        composer.text = "original input"
        let sending = Task { await composer.submitInput(using: f.sender, snapshot: active(), mode: .steer, features: ["steer": true]) }
        let posted = await f.transport.waitForPost()
        XCTAssertTrue(posted)
        try drafts.write("edited in a newer screen", serverID: f.serverID, threadID: "thread")
        await f.transport.releaseAccepted()
        _ = await sending.value
        XCTAssertEqual(try drafts.read(serverID: f.serverID, threadID: "thread"), "edited in a newer screen")
    }

    func testStaleJournalWriterPreservesOtherOperationsAndConfirmedReceipts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = OperationJournal(root: root), serverID = UUID(), firstID = UUID().uuidString, secondID = UUID().uuidString
        func entry(_ id: String, _ state: CodexRemote.Operation.State, reviewed: Bool = false) -> CommandRecord {
            CommandRecord(method: .input, context: "task/input:\(id)", createdAt: "2026-11-09T00:00:00Z", receipt: CodexRemote.Operation(id: id, state: state, result: .null, message: nil), reviewed: reviewed)
        }
        try journal.save([entry(firstID, .unknown, reviewed: true)], serverID: serverID)
        try journal.save([entry(firstID, .unknown, reviewed: true), entry(secondID, .pending)], serverID: serverID)
        try journal.save([entry(firstID, .accepted)], serverID: serverID)
        try journal.save([entry(firstID, .unknown)], serverID: serverID)
        let saved = try journal.load(serverID: serverID)
        XCTAssertEqual(Set(saved.map(\.id)), Set([firstID, secondID]))
        XCTAssertEqual(saved.first(where: { $0.id == firstID })?.receipt.state, .accepted)
        XCTAssertEqual(saved.first(where: { $0.id == firstID })?.reviewed, true)
    }

    @MainActor
    private func fixture(behavior: CommandTransport.Behavior = .accepted, ready: Bool = true, write: ((Data, URL) throws -> Void)? = nil) throws -> (sender: CommandSender, transport: CommandTransport, serverID: UUID, root: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), serverID = UUID()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let transport = CommandTransport(behavior: behavior), journal: OperationJournal
        if let write { journal = OperationJournal(root: root.appendingPathComponent("operations"), write: write) }
        else { journal = OperationJournal(root: root.appendingPathComponent("operations")) }
        return (CommandSender(serverID: serverID, transport: transport, journal: journal, canSend: { _ in ready }), transport, serverID, root)
    }
}

private func active() -> Snapshot {
    Snapshot(cursor: Cursor(epoch: "epoch", seq: 0), thread: ThreadSummary(id: "thread", projectId: "project", title: "Controlled", status: "active", activeTurnId: "turn", parentId: nil),
             items: [], itemsCursor: nil, pending: [pending()], policy: Snapshot.Policy(approvalPolicy: nil, sandbox: nil))
}
private func pending(state: Pending.State = .pending) -> Pending {
    Pending(id: "request", threadId: "thread", turnId: "turn", kind: .command, prompt: "Controlled", options: .object(["availableDecisions": .array([.string("accept"), .string("cancel")])]), state: state)
}
private actor CommandTransport: BridgeTransport {
    enum Behavior { case accepted, timeout, partial, held }
    let behavior: Behavior
    var posts: [Command] = []
    var reads = 0
    private var pending: CheckedContinuation<CodexRemote.Operation, Never>?
    init(behavior: Behavior) { self.behavior = behavior }
    func command(_ command: Command) async throws -> CodexRemote.Operation {
        posts.append(command)
        if behavior == .held { return await withCheckedContinuation { pending = $0 } }
        if behavior == .timeout { throw URLError(.timedOut) }
        return CodexRemote.Operation(id: command.id, state: behavior == .partial ? .unknown : .accepted,
                                     result: behavior == .partial ? .object(["threadId": .string("created-thread")]) : .null, message: nil)
    }
    func waitForPost() async -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while posts.isEmpty && Date() < deadline { try? await Task.sleep(nanoseconds: 5_000_000) }
        return !posts.isEmpty
    }
    func releaseAccepted() {
        if let command = posts.first { pending?.resume(returning: CodexRemote.Operation(id: command.id, state: .accepted, result: .null, message: nil)) }
        pending = nil
    }
    func get<T: Decodable & Sendable>(_ path: String, as: T.Type) async throws -> T {
        reads += 1
        return CodexRemote.Operation(id: String(path.split(separator: "/").last!), state: .unknown, result: .null, message: nil) as! T
    }
    nonisolated func events(after: Cursor?) -> AsyncThrowingStream<EventFrame, Error> { AsyncThrowingStream { $0.finish() } }
    func close() async { }
}
