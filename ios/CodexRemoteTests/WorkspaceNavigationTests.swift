import XCTest
import SwiftUI
@testable import CodexRemote

final class WorkspaceNavigationTests: XCTestCase {
    @MainActor
    func testMenuSectionSwitchReleasesOnlyTheSelectedConversationAndPreservesDraft() async throws {
        let f = try await fixture()
        let drafts = DraftStore(root: f.root.appendingPathComponent("drafts"))
        let composer = ComposerModel(serverID: f.server.id, threadID: "thread", drafts: drafts)
        composer.text = "菜单切换草稿😀"
        await f.session.openThread("thread")
        let attachment = try XCTUnwrap(f.session.attachmentID)
        let navigation = WorkspaceNavigator(session: f.session)
        navigation.path.append("thread")
        await navigation.show(.settings)
        XCTAssertEqual(navigation.path.count, 1)
        XCTAssertNil(f.session.selectedThreadID)
        let commands = await f.transport.commands
        XCTAssertEqual(commands.filter { $0.method == .release }.count, 1)
        XCTAssertEqual(commands.last?.params["attachmentId"], .string(attachment.uuidString))
        XCTAssertEqual(try drafts.read(serverID: f.server.id, threadID: "thread"), "菜单切换草稿😀")
        await f.session.disconnect()
    }

    @MainActor
    func testTasksMenuReturnsToListWithoutRepeatedRelease() async throws {
        let f = try await fixture()
        await f.session.openThread("thread")
        let navigation = WorkspaceNavigator(session: f.session)
        navigation.path.append("thread"); navigation.path.append("child")
        await navigation.show(.tasks)
        XCTAssertEqual(navigation.path.count, 0)
        await navigation.show(.connections)
        XCTAssertEqual(navigation.path.count, 1)
        await navigation.show(.tasks)
        XCTAssertEqual(navigation.path.count, 0)
        let commands = await f.transport.commands
        XCTAssertEqual(commands.filter { $0.method == .release }.count, 1)
        await f.session.disconnect()
    }

    @MainActor
    func testHistoryFeedbackCountsOnlyNewRecordsAndReportsExhaustion() async throws {
        let f = try await fixture()
        await f.session.selectThread("thread")
        await f.session.loadMoreHistory()
        XCTAssertEqual(f.session.snapshot?.items.map(\.id), ["older", "recent"])
        XCTAssertEqual(f.session.historyMessage, "已加载较早的1条记录，已到最早记录。")
        XCTAssertNil(f.session.snapshot?.itemsCursor)
        await f.session.disconnect()
    }

    @MainActor
    func testFailedHistoryLoadKeepsCursorAndDraftThenAllowsRetry() async throws {
        let f = try await fixture()
        await f.session.selectThread("thread")
        await f.transport.failNextHistory()
        await f.session.loadMoreHistory()
        XCTAssertEqual(f.session.snapshot?.itemsCursor, "older-page")
        XCTAssertEqual(f.session.snapshot?.items.map(\.id), ["recent"])
        XCTAssertEqual(f.session.historyMessage, "无法加载较早的记录，请重试。")
        await f.session.loadMoreHistory()
        XCTAssertEqual(f.session.snapshot?.items.count, 2)
        XCTAssertEqual(f.session.historyMessage, "已加载较早的1条记录，已到最早记录。")
        await f.session.disconnect()
    }

    @MainActor
    private func fixture() async throws -> (root: URL, server: ServerConfiguration, session: SessionStore, transport: WorkspaceTestTransport) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let server = try ServerConfiguration(name: "Fixture", address: "https://fixture.invalid")
        let transport = WorkspaceTestTransport()
        let session = SessionStore(cursors: CursorStore(url: root.appendingPathComponent("cursor.json")))
        await session.connect(server: server, transport: transport)
        return (root, server, session, transport)
    }
}

private actor WorkspaceTestTransport: BridgeTransport {
    private(set) var commands: [Command] = []
    private var failHistory = false
    func failNextHistory() { failHistory = true }
    func get<T: Decodable & Sendable>(_ path: String, as: T.Type) async throws -> T {
        let recent = Item(id: "recent", turnId: "recent-turn", kind: "agentMessage", text: "recent", data: .object([:]))
        if path.contains("/items?") {
            if failHistory { failHistory = false; throw URLError(.networkConnectionLost) }
            let older = Item(id: "older", turnId: "older-turn", kind: "agentMessage", text: "older", data: .object([:]))
            return ItemPage(data: [older, recent], nextCursor: nil) as! T
        }
        return Snapshot(cursor: Cursor(epoch: "epoch", seq: 0),
                        thread: ThreadSummary(id: "thread", projectId: "project", title: "Fixture", status: "idle", activeTurnId: nil, parentId: nil),
                        items: [recent], itemsCursor: "older-page", pending: [], policy: .init(approvalPolicy: nil, sandbox: nil)) as! T
    }
    func command(_ command: Command) async throws -> CodexRemote.Operation {
        commands.append(command)
        return CodexRemote.Operation(id: command.id, state: .accepted, result: .null, message: nil)
    }
    nonisolated func events(after: Cursor?) -> AsyncThrowingStream<EventFrame, Error> { AsyncThrowingStream { _ in } }
    func close() async { }
}
