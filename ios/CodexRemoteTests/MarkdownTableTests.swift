import XCTest
import MarkdownUI
@testable import CodexRemote

final class MarkdownTableTests: XCTestCase {
    func testLibraryGeneratedTablePreservesCellsAndAlignments() throws {
        let markdown = "| 左 | 中 | 右 |\r\n| :--- | :---: | ---: |\r\n| 中文😀 | 竖\\|线 | e\u{301} |"
        let html = MarkdownContent(markdown).renderHTML()
        let table = try XCTUnwrap(MarkdownTableDocument.parse(html: html), html)
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
        let html = "<table><tr><th>格式</th></tr><tr><td><strong>粗<em>斜</em></strong><br /><code>a|b</code><del>删</del></td></tr></table>"
        let table = try XCTUnwrap(MarkdownTableDocument.parse(html: html))
        let cell = table.rows[1].cells[0]
        XCTAssertEqual(cell.text, "粗斜\na|b删")
        XCTAssertTrue(try XCTUnwrap(cell.runs.first { $0.text == "斜" }).styles.contains([.strong, .emphasis]))
        XCTAssertTrue(try XCTUnwrap(cell.runs.first { $0.text == "a|b" }).styles.contains(.code))
        XCTAssertTrue(try XCTUnwrap(cell.runs.first { $0.text == "删" }).styles.contains(.strikethrough))
    }

    func testLinksKeepOnlyExplicitHTTPSTargets() throws {
        let html = "<table><tr><td><a href=\"https://example.com/a?x=1&amp;y=2\">安全</a> <a href=\"http://example.com\">普通</a> <a href=\"javascript:alert(1)\">脚本</a> <a href=\"file:///private/test\">文件</a> <a href=\"/relative\">相对</a></td></tr></table>"
        let cell = try XCTUnwrap(MarkdownTableDocument.parse(html: html)).rows[0].cells[0]
        XCTAssertEqual(cell.text, "安全 普通 脚本 文件 相对")
        XCTAssertEqual(cell.runs.compactMap { $0.link?.absoluteString }, ["https://example.com/a?x=1&y=2", "http://example.com"])
    }

    func testImageIsAPlaceholderWithoutDiscardingSurroundingText() throws {
        let markdown = "| 图像 |\n| --- |\n| before ![图😀](https://example.com/image.png) after |"
        let html = MarkdownContent(markdown).renderHTML()
        let table = try XCTUnwrap(MarkdownTableDocument.parse(html: html), html)
        XCTAssertEqual(table.rows[1].cells[0].text, "before [图片：图😀] after")
        XCTAssertTrue(table.rows[1].cells[0].runs.allSatisfy { $0.link == nil })
    }

    func testUnsupportedOrMalformedTablesFallBackAsAWhole() {
        for html in [
            "<table><tr><td>partial</tr></table>",
            "<table><tr><th>one</th><th>two</th></tr><tr><td>missing</td></tr></table>",
            "<table><tr><td><unknown>content</unknown></td></tr></table>",
            "<table><tr><td><table><tr><td>nested</td></tr></table></td></tr></table>",
            "<table>unplaced content<tr><td>cell</td></tr></table>"
        ] { XCTAssertNil(MarkdownTableDocument.parse(html: html), html) }
    }

    func testDTDAndExternalEntityDeclarationsAreRejected() {
        let document = "<!DOCTYPE table [<!ENTITY external SYSTEM \"file:///no-such-codex-test-entity\">]><table><tr><td>&external;</td></tr></table>"
        XCTAssertNil(MarkdownTableDocument.parse(html: document))
        XCTAssertNil(MarkdownTableDocument.parse(html: "<!DOCTYPE table><table><tr><td>text</td></tr></table>"))
    }
}
