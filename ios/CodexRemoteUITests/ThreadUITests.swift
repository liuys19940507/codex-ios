import XCTest

final class ThreadUITests: XCTestCase {
    func testDraftIsVisibleWhileReadingLongTaskOutput() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-workspace", "--ui-test-activity"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Fixture task"].waitForExistence(timeout: 10))
        app.staticTexts["Fixture task"].tap()
        let draft = app.textViews["任务草稿"]
        XCTAssertTrue(draft.waitForExistence(timeout: 5))
        XCTAssertTrue(draft.isHittable)
        let position = draft.frame.minY
        app.swipeUp()
        XCTAssertEqual(draft.frame.minY, position, accuracy: 2)
    }
    func testConversationHasRefreshAndRetainsDraftAfterRefresh() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-workspace"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Fixture task"].waitForExistence(timeout: 10))
        app.staticTexts["Fixture task"].tap()
        let refresh = app.buttons["刷新历史并重新连接"]
        XCTAssertTrue(refresh.waitForExistence(timeout: 5))
        let draft = app.textViews["任务草稿"]
        for _ in 0..<6 where !draft.isHittable { app.swipeUp() }
        draft.tap(); draft.typeText("refresh preserves draft")
        refresh.tap()
        XCTAssertEqual(draft.value as? String, "refresh preserves draft")
    }
    func testLongActivityCanCopyAndChildNavigationPreservesParentDraft() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-workspace", "--ui-test-activity", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Fixture task"].waitForExistence(timeout: 10))
        app.staticTexts["Fixture task"].tap()
        let copy = app.buttons["复制全部输出"]
        XCTAssertTrue(copy.waitForExistence(timeout: 5))
        for _ in 0..<5 where !copy.isHittable { app.swipeUp() }
        copy.tap()
        XCTAssertTrue(app.staticTexts["已复制"].waitForExistence(timeout: 5))
        let draft = app.textViews["任务草稿"]
        for _ in 0..<8 where !draft.isHittable { app.swipeUp() }
        draft.tap(); draft.typeText("parent draft stays")
        let child = app.buttons["打开子任务"]
        for _ in 0..<8 where !child.isHittable { app.swipeDown() }
        child.tap()
        XCTAssertTrue(app.navigationBars["Child fixture task"].waitForExistence(timeout: 10))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["Fixture task"].waitForExistence(timeout: 10))
        for _ in 0..<8 where !draft.isHittable { app.swipeUp() }
        XCTAssertEqual(draft.value as? String, "parent draft stays")
    }
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
