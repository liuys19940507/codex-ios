import XCTest

final class ThreadUITests: XCTestCase {
    func testCreateTaskFromConfiguredProjectOpensTheReturnedThread() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-workspace"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Fixture task"].waitForExistence(timeout: 10))
        let create = app.buttons["新任务"]
        XCTAssertTrue(create.waitForExistence(timeout: 5))
        create.tap()
        let draft = app.textViews["任务草稿"]
        XCTAssertTrue(draft.waitForExistence(timeout: 5))
        draft.tap(); draft.typeText("controlled create")
        app.buttons["创建并发送"].tap()
        XCTAssertTrue(app.navigationBars["Created fixture task"].waitForExistence(timeout: 10))
    }

    func testRenameAndArchiveFromThreadMenu() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-workspace"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Fixture task"].waitForExistence(timeout: 10))
        app.staticTexts["Fixture task"].press(forDuration: 1)
        app.buttons["重命名"].tap()
        let title = app.alerts.textFields.firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.tap(); title.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "Fixture task".count) + "Renamed fixture task")
        app.alerts.buttons["保存"].tap()
        XCTAssertTrue(app.staticTexts["Renamed fixture task"].waitForExistence(timeout: 10))
        app.staticTexts["Renamed fixture task"].press(forDuration: 1)
        app.buttons["归档"].tap()
        XCTAssertTrue(app.staticTexts["归档此会话？"].waitForExistence(timeout: 5))
        app.buttons["确认归档"].tap()
        XCTAssertTrue(app.staticTexts["暂无会话"].waitForExistence(timeout: 10))
    }
    func testSearchOpenConversationAndKeepDraftAtLargeType() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-workspace", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Fixture task"].waitForExistence(timeout: 10))
        let search = app.searchFields.firstMatch
        search.tap(); search.typeText("Fixture")
        XCTAssertTrue(app.staticTexts["Fixture task"].waitForExistence(timeout: 5))
        app.staticTexts["Fixture task"].tap()
        let draft = app.textViews["任务草稿"]
        XCTAssertTrue(draft.waitForExistence(timeout: 5))
        for _ in 0..<4 where !draft.isHittable { app.swipeUp() }
        draft.tap(); draft.typeText("draft survives navigation")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.staticTexts["Fixture task"].waitForExistence(timeout: 5))
        app.staticTexts["Fixture task"].tap()
        XCTAssertTrue(draft.waitForExistence(timeout: 5))
        XCTAssertEqual(draft.value as? String, "draft survives navigation")
    }
}
