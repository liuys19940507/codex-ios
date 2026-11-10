import XCTest

final class RenderingUITests: XCTestCase {
    func testCodeViewerAndLightAppearance() { verify(dark: false) }
    func testCodeViewerAndDarkAppearance() { verify(dark: true) }
    private func verify(dark: Bool) {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-workspace", "--ui-test-activity", "--ui-test-rendering"] + (dark ? ["--ui-test-dark"] : [])
        app.launch()
        XCTAssertTrue(app.staticTexts["Fixture task"].waitForExistence(timeout: 10))
        app.staticTexts["Fixture task"].tap()
        XCTAssertTrue(app.textViews["任务草稿"].waitForExistence(timeout: 5))
        let process = app.buttons["查看处理过程"]
        for _ in 0..<12 where !process.isHittable { app.swipeDown() }
        XCTAssertTrue(process.isHittable)
        capture(app, "conversation-\(dark ? "dark" : "light")")
        let fullCode = app.buttons["查看完整代码"]
        for _ in 0..<8 where !fullCode.isHittable { app.swipeUp() }
        XCTAssertTrue(fullCode.isHittable)
        fullCode.tap()
        XCTAssertTrue(app.navigationBars["swift"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "print(greeting)")).firstMatch.exists)
        app.buttons["复制全部"].tap()
        XCTAssertTrue(app.buttons["已复制"].exists)
        capture(app, "code-viewer-\(dark ? "dark" : "light")")
        app.buttons["完成"].tap()
        XCTAssertTrue(app.textViews["任务草稿"].exists)
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
    }
}
