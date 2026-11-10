import XCTest

final class ComposerUITests: XCTestCase {
    func testMultilineDraftKeepsTheComposerHeight() { verifyFixedHeight(largest: false) }
    func testMultilineDraftKeepsTheComposerHeightAtLargestType() { verifyFixedHeight(largest: true) }
    private func verifyFixedHeight(largest: Bool) {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-workspace"]
        if largest { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch()
        XCTAssertTrue(app.staticTexts["Fixture task"].waitForExistence(timeout: 10))
        app.staticTexts["Fixture task"].tap()
        let draft = app.textViews["任务草稿"]
        XCTAssertTrue(draft.waitForExistence(timeout: 5))
        draft.tap()
        let height = draft.frame.height
        draft.typeText("first line\nsecond line\nthird line\nfourth line\nfifth line\nlast line")
        XCTAssertEqual(draft.frame.height, height, accuracy: 1, "Typing must scroll inside the editor instead of resizing the conversation")
        XCTAssertTrue((draft.value as? String)?.contains("last line") == true)
        if largest { XCTAssertGreaterThan(height, 70, "Keep a complete accessible text line") }
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = largest ? "fixed-composer-largest" : "fixed-composer-normal"
        screenshot.lifetime = .keepAlways; add(screenshot)
    }
}
