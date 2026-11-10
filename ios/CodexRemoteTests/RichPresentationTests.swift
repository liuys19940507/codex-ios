import XCTest
@testable import CodexRemote

final class RichPresentationTests: XCTestCase {
    func testFencedCodeKeepsRawUnicodeAndCRLFForCopying() throws {
        let raw = "正文 **中文**\r\n```swift\r\nlet emoji = \"😀\"\r\n```\r\n结束\r\n"
        let blocks = MessageDocument.parse(raw)
        XCTAssertEqual(blocks.map(\.raw).joined(), raw)
        let code = try XCTUnwrap(blocks.first { $0.kind == .code })
        XCTAssertEqual(code.language, "swift")
        XCTAssertEqual(code.content, "let emoji = \"😀\"\r\n")
        XCTAssertTrue(code.complete)
    }
    func testStreamingFenceAndLongerClosingFenceDoNotLoseText() throws {
        let streaming = "~~~powershell\nWrite-Output '中文😀'"
        let code = try XCTUnwrap(MessageDocument.parse(streaming).first)
        XCTAssertEqual(code.kind, .code)
        XCTAssertFalse(code.complete)
        XCTAssertEqual(code.content, "Write-Output '中文😀'")
        let raw = "````text\n```\ninline `tick`\n`````\n"
        let complete = try XCTUnwrap(MessageDocument.parse(raw).first)
        XCTAssertEqual(complete.content, "```\ninline `tick`\n")
        XCTAssertEqual(complete.raw, raw)
        XCTAssertTrue(complete.complete)
    }
    func testHunkContentBeginningWithTriplePlusIsAnAdditionAndNotAFileHeader() throws {
        let raw = "diff --git a/中文.txt b/中文.txt\r\n--- a/中文.txt\r\n+++ b/中文.txt\r\n@@ -1 +1,2 @@\r\n-old\r\n+++ literal code\r\n+new😀\r\n"
        let document = DiffDocument.parse(raw, path: "fallback")
        let file = try XCTUnwrap(document.files.first)
        XCTAssertEqual(file.path, "中文.txt")
        XCTAssertEqual(file.added, 2); XCTAssertEqual(file.removed, 1)
        XCTAssertFalse(file.partial)
        XCTAssertEqual(file.lines.first { $0.text.hasPrefix("+++ literal") }?.kind, .add)
        XCTAssertEqual(document.files.map(\.raw).joined(), raw)
    }
    func testMultipleFileRenameBinaryAndTruncatedPatchRemainReadable() {
        let raw = "diff --git a/old b/new\nrename from old\nrename to new\ndiff --git a/b.png b/b.png\nBinary files a/b.png and b/b.png differ\ndiff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1,2 +1,2 @@\n-a\n+b\n"
        let files = DiffDocument.parse(raw, path: "fallback").files
        XCTAssertEqual(files.count, 3)
        XCTAssertEqual(files.first?.path, "new")
        XCTAssertEqual(files[1].binary, true)
        XCTAssertEqual(files[2].partial, true)
        XCTAssertEqual(files.map(\.raw).joined(), raw)
    }
    func testKnownEmptyMessagesNeverDisplayInternalMetadata() {
        for kind in ["agentMessage", "userMessage", "reasoning", "plan"] {
            let item = Item(id: kind, turnId: "turn", kind: kind, text: "", data: .object(["completed": .bool(false), "prefixComplete": .bool(false)]))
            XCTAssertEqual(ActivityPresentation.make(item: item).body, "")
        }
        let summary = ReasoningSummary.make("**检查文件**\n<!-- -->\n只显示服务提供的摘要😀")
        XCTAssertEqual(summary.title, "检查文件")
        XCTAssertEqual(summary.body, "只显示服务提供的摘要😀")
    }
    func testTurnTimelineKeepsFinalAnswerInlineAndGroupsProgressAndTools() {
        func item(_ id: String, _ kind: String, _ text: String = "text", _ phase: String? = nil) -> Item {
            Item(id: id, turnId: "turn", kind: kind, text: text, data: .object(phase.map { ["phase": .string($0)] } ?? [:]))
        }
        let source = [item("u", "userMessage"), item("progress", "agentMessage", "working", "commentary"), item("r", "reasoning"), item("tool", "commandExecution"), item("final", "agentMessage", "## Done", "final_answer")]
        let rows = ConversationTimeline.make(source)
        XCTAssertEqual(rows.map(\.kind), [.message, .process, .message])
        XCTAssertEqual(rows[1].items.map(\.id), ["progress", "r", "tool"])
        XCTAssertEqual(rows[2].items.first?.id, "final")
        XCTAssertEqual(Set(rows.map(\.id)).count, rows.count)
        let paged = ConversationTimeline.make(source + [source.last!])
        XCTAssertEqual(paged, rows)
    }
}
