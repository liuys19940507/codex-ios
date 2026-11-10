import XCTest
@testable import CodexRemote

final class ActivityTests: XCTestCase {
    func testUnknownActivityIsReadableAndPreservesPayload() {
        let item = Item(id: "unknown", turnId: "turn", kind: "futureTool", text: "", data: .object(["message": .string("保留🧑🏽‍💻未知工具")]))
        let presentation = ActivityPresentation.make(item: item)
        XCTAssertFalse(presentation.title.isEmpty)
        XCTAssertTrue(presentation.body.contains("保留🧑🏽‍💻未知工具"))
        XCTAssertEqual(presentation.kind, "futureTool")
    }
    func testDiffPreservesContentAndLineEndings() {
        let text = "diff --git a/中文.txt b/中文.txt\r\n--- a/中文.txt\r\n+++ b/中文.txt\r\n@@ -1 +1 @@\r\n-旧内容🧑🏽‍💻\r\n+新内容😀\r\n\\ No newline at end of file"
        let lines = DiffPresentation.parse(text)
        XCTAssertEqual(lines.map(\.text).joined(), text)
        XCTAssertEqual(lines.map(\.kind), [.header, .header, .header, .header, .remove, .add, .context])
        XCTAssertTrue(DiffPresentation.parse("").isEmpty)
        XCTAssertEqual(DiffPresentation.parse("+单行").first?.text, "+单行")
        XCTAssertEqual(DiffPresentation.parse(" a\n").count, 1)
    }
    func testLongUnicodeOutputChunksRejoinWithoutLoss() {
        let text = String(repeating: "中文e\u{301}🧑🏽‍💻\r\n", count: 6000)
        let chunks = ActivityPresentation.chunks(text, limit: 2048)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 2048 })
        XCTAssertEqual(chunks.joined(), text)
    }
    func testChildNavigationKeepsParentDraftAndFiltersInvalidIDs() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let drafts = DraftStore(root: root), server = UUID()
        try drafts.write("父任务\n未提交😀", serverID: server, threadID: "parent")
        let item = Item(id: "tool", turnId: "turn", kind: "collabAgentToolCall", text: "", data: .object(["childThreadIds": .array([.string("child"), .string("child"), .number(1), .string("")])]))
        XCTAssertEqual(ActivityPresentation.make(item: item).childThreadIDs, ["child"])
        try drafts.write("child draft", serverID: server, threadID: "child")
        XCTAssertEqual(try drafts.read(serverID: server, threadID: "parent"), "父任务\n未提交😀")
    }
}
