import XCTest
@testable import CodexRemote

final class ConversationAttachmentTests: XCTestCase {
    @MainActor
    func testRefreshGetsNewHistoryAndKeepsTheSameAttachmentUntilLeaving() async throws {
        let (session, bridge) = try await fixture()
        await session.openThread("thread")
        let first = session.attachmentID
        await bridge.setText("电脑新历史 中文😀")
        await session.refreshThread("thread")
        XCTAssertEqual(session.snapshot?.items.first?.text, "电脑新历史 中文😀")
        XCTAssertEqual(session.attachmentID, first)
        XCTAssertTrue(session.canControl)
        await session.leaveThread("thread", attachmentID: first)
        XCTAssertNil(session.snapshot)
        XCTAssertNil(session.attachmentID)
        let commands = await bridge.commands
        XCTAssertEqual(commands.map(\.method.rawValue), ["thread/attach", "thread/attach", "thread/release"])
        XCTAssertEqual(commands.last?.params["attachmentId"], .string(first!.uuidString))
        await session.resumeForeground()
        XCTAssertNil(session.snapshot)
        await session.disconnect()
    }

    @MainActor
    func testAnOldPageCannotReleaseAReopenedConversation() async throws {
        let (session, bridge) = try await fixture()
        await session.openThread("thread")
        let old = session.attachmentID
        await session.leaveThread("thread", attachmentID: old)
        await session.openThread("thread")
        let current = session.attachmentID
        XCTAssertNotEqual(current, old)
        await session.leaveThread("thread", attachmentID: old)
        XCTAssertEqual(session.attachmentID, current)
        XCTAssertEqual(session.snapshot?.thread.id, "thread")
        let releases = await bridge.commands.filter { $0.method.rawValue == "thread/release" }
        XCTAssertEqual(releases.count, 1)
        await session.disconnect()
    }

    @MainActor
    func testExternalWriterIsReadOnlyAndForegroundRefreshOnlyRestoresSubscription() async throws {
        let (session, bridge) = try await fixture()
        await bridge.setReadOnly("电脑 CLI 正在控制，请退出后刷新")
        await session.openThread("thread")
        XCTAssertFalse(session.canControl)
        XCTAssertNotNil(session.snapshot?.readOnlyReason)
        let attachment = session.attachmentID
        await session.suspend()
        await bridge.setReadOnly(nil)
        let resumed = await session.resumeForeground()
        XCTAssertTrue(resumed)
        XCTAssertTrue(session.canControl)
        XCTAssertEqual(session.attachmentID, attachment)
        let commands = await bridge.commands
        XCTAssertTrue(commands.allSatisfy { $0.method.rawValue == "thread/attach" })
        await session.disconnect()
    }

    @MainActor
    func testSwitchingServersReleasesOldAttachmentAndDoesNotRestoreItOnNewServer() async throws {
        let (session, old) = try await fixture()
        await session.openThread("thread")
        let next = AttachmentTransport()
        await session.connect(server: try ServerConfiguration(name: "Other", address: "https://other.example"), transport: next)
        XCTAssertNil(session.attachmentID)
        XCTAssertNil(session.snapshot)
        let resumed = await session.resumeForeground()
        XCTAssertTrue(resumed)
        let oldCommands = await old.commands
        XCTAssertEqual(oldCommands.map(\.method.rawValue), ["thread/attach", "thread/release"])
        let newCommands = await next.commands
        XCTAssertTrue(newCommands.isEmpty)
        await session.disconnect()
    }

    @MainActor
    private func fixture() async throws -> (SessionStore, AttachmentTransport) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let bridge = AttachmentTransport()
        let session = SessionStore(cursors: CursorStore(url: root.appendingPathComponent("cursor.json")))
        await session.connect(server: try ServerConfiguration(name: "Fixture", address: "https://fixture.example"), transport: bridge)
        return (session, bridge)
    }
}

private actor AttachmentTransport: BridgeTransport {
    var commands: [Command] = []
    private var text = "history", reason: String?
    func setText(_ text: String) { self.text = text }
    func setReadOnly(_ reason: String?) { self.reason = reason }
    func get<T: Decodable & Sendable>(_ path: String, as: T.Type) async throws -> T {
        var snapshot = Snapshot(cursor: Cursor(epoch: "epoch", seq: 0), thread: ThreadSummary(id: "thread", projectId: "project", title: "Fixture", status: "idle", activeTurnId: nil, parentId: nil),
                                items: [Item(id: "item", turnId: "turn", kind: "agentMessage", text: text, data: .object([:]))], itemsCursor: nil, pending: [], policy: .init(approvalPolicy: nil, sandbox: nil))
        snapshot.readOnlyReason = reason
        return snapshot as! T
    }
    func command(_ command: Command) async throws -> CodexRemote.Operation {
        commands.append(command)
        return Operation(id: command.id, state: .accepted, result: .null, message: nil)
    }
    nonisolated func events(after: Cursor?) -> AsyncThrowingStream<EventFrame, Error> { AsyncThrowingStream { _ in } }
    func close() async { }
}
