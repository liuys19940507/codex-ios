import XCTest
import MarkdownUI
@testable import CodexRemote

final class MarkdownTableTests: XCTestCase {
    func testLibraryGeneratedTablePreservesCellsAndAlignments() throws {
        let markdown = "| 左 | 中 | 右 |\r\n| :--- | :---: | ---: |\r\n| 中文😀 | 竖\\|线 | e\u{301} |"
        let canonical = MarkdownContent(markdown).renderMarkdown()
        let table = try XCTUnwrap(MarkdownTableDocument.parse(markdown: canonical), canonical)
        XCTAssertEqual(table.columnCount, 3)
        XCTAssertEqual(table.rows.count, 2)
        XCTAssertTrue(table.rows[0].isHeader)
        XCTAssertFalse(table.rows[1].isHeader)
        XCTAssertEqual(table.rows[0].cells.map(\.text), ["左", "中", "右"])
        XCTAssertEqual(table.rows[1].cells.map(\.text), ["中文😀", "竖|线", "e\u{301}"])
        XCTAssertEqual(table.rows[1].cells.map(\.alignment), [.leading, .center, .trailing])
        XCTAssertEqual(MessageDocument.parse(markdown).map(\.raw).joined(), markdown)
    }

    func testCellRunsPreserveNestedFormattingAndLineBreaks() throws {
        let markdown = "| 格式 |\n| --- |\n| **粗*斜***<br />`a\\|b`~~删~~ |"
        let canonical = MarkdownContent(markdown).renderMarkdown()
        let table = try XCTUnwrap(MarkdownTableDocument.parse(markdown: canonical), canonical)
        let cell = table.rows[1].cells[0]
        XCTAssertEqual(cell.text, "粗斜\na|b删")
        XCTAssertTrue(try XCTUnwrap(cell.runs.first { $0.text == "斜" }).styles.contains([.strong, .emphasis]))
        XCTAssertTrue(try XCTUnwrap(cell.runs.first { $0.text == "a|b" }).styles.contains(.code))
        XCTAssertTrue(try XCTUnwrap(cell.runs.first { $0.text == "删" }).styles.contains(.strikethrough))
    }

    func testLinksKeepOnlyExplicitHTTPSTargets() throws {
        let markdown = "| 链接 |\n| --- |\n| [安全](https://example.com/a?x=1&y=2) [普通](http://example.com) [脚本](javascript:alert(1)) [文件](file:///private/test) [相对](/relative) |"
        let canonical = MarkdownContent(markdown).renderMarkdown()
        let cell = try XCTUnwrap(MarkdownTableDocument.parse(markdown: canonical), canonical).rows[1].cells[0]
        XCTAssertEqual(cell.text, "安全 普通 脚本 文件 相对")
        XCTAssertEqual(cell.runs.compactMap { $0.link?.absoluteString }, ["https://example.com/a?x=1&y=2", "http://example.com"])
    }

    func testImageIsAPlaceholderWithoutDiscardingSurroundingText() throws {
        let markdown = "| 图像 |\n| --- |\n| before ![图😀](https://example.com/image.png) after |"
        let canonical = MarkdownContent(markdown).renderMarkdown()
        let table = try XCTUnwrap(MarkdownTableDocument.parse(markdown: canonical), canonical)
        XCTAssertEqual(table.rows[1].cells[0].text, "before [图片：图😀] after")
        XCTAssertTrue(table.rows[1].cells[0].runs.allSatisfy { $0.link == nil })
    }

    func testUnsupportedOrMalformedTablesFallBackAsAWhole() {
        for markdown in [
            "not a table",
            "| one | two |",
            "| one |\n| --- |\n| <unknown>content</unknown> |",
            "| one |\n| --- |\n| content |\n\noutside content",
            "| one |\n| --- |\n| content |\n\n| two |\n| --- |\n| second |"
        ] { XCTAssertNil(MarkdownTableDocument.parse(markdown: markdown), markdown) }
    }

    func testDTDAndExternalEntityDeclarationsAreRejected() {
        let document = "<!DOCTYPE table [<!ENTITY external SYSTEM \"file:///no-such-codex-test-entity\">]><table><tr><td>&external;</td></tr></table>"
        XCTAssertNil(MarkdownTableDocument.parse(markdown: document))
        XCTAssertNil(MarkdownTableDocument.parse(markdown: "| declaration |\n| --- |\n| <!DOCTYPE table> |"))
    }
}
