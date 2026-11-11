import XCTest

final class WorkspaceNavigationUITests: XCTestCase {
    func testOverflowMenuReplacesTabsAndNavigatesEverySection() {
        let app = launch(largest: true)
        XCTAssertEqual(app.tabBars.count, 0)
        let menu = app.buttons["更多"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(menu.frame.midX, app.frame.width / 2)
        XCTAssertLessThan(menu.frame.midY, app.frame.height / 4)
        menu.tap()
        XCTAssertTrue(app.buttons["workspace.settings"].waitForExistence(timeout: 5))
        capture("overflow-navigation", app)
        app.buttons["workspace.connections"].tap()
        XCTAssertTrue(app.staticTexts["Fixture Windows"].waitForExistence(timeout: 5))
        app.buttons["更多"].tap(); app.buttons["workspace.settings"].tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 5))
        app.buttons["更多"].tap(); app.buttons["workspace.tasks"].tap()
        XCTAssertTrue(app.staticTexts["Fixture task"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.tabBars.count, 0)
    }
    func testConversationMenuKeepsDraftWhenReturningToTaskList() {
        let app = launch()
        app.staticTexts["Fixture task"].tap()
        let draft = app.textViews["任务草稿"]
        XCTAssertTrue(draft.waitForExistence(timeout: 5)); draft.tap(); draft.typeText("menu retains draft")
        app.buttons["更多"].tap()
        XCTAssertTrue(app.buttons["workspace.settings"].waitForExistence(timeout: 5))
        capture("conversation-overflow", app)
        app.buttons["workspace.settings"].tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 5))
        app.buttons["更多"].tap(); app.buttons["workspace.tasks"].tap()
        XCTAssertTrue(app.staticTexts["Fixture task"].waitForExistence(timeout: 5)); app.staticTexts["Fixture task"].tap()
        XCTAssertEqual(draft.value as? String, "menu retains draft")
        XCTAssertEqual(app.tabBars.count, 0)
    }
    private func launch(largest: Bool = false) -> XCUIApplication {
        let app = XCUIApplication(); app.launchArguments = ["--ui-test-workspace"]
        if largest { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch()
        XCTAssertTrue(app.staticTexts["Fixture task"].waitForExistence(timeout: 10)); return app
    }
    private func capture(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
