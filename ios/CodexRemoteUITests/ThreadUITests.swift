import XCTest

final class ThreadUITests: XCTestCase {
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
