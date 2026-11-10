import XCTest

final class PinningUITests: XCTestCase {
    func testMultiplePinnedTasksKeepOrderAfterRelaunchAndCanBeUnpinned() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-workspace", "--ui-test-pins"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Pin task one"].waitForExistence(timeout: 10))
        pin("Pin task one", in: app)
        pin("Pin task two", in: app)
        assertOrder(app)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "multiple-pinned-tasks"; screenshot.lifetime = .keepAlways; add(screenshot)
        app.terminate(); app.launch()
        XCTAssertTrue(app.staticTexts["Pin task two"].waitForExistence(timeout: 10))
        assertOrder(app)
        app.staticTexts["Pin task two"].press(forDuration: 1)
        app.buttons["取消置顶"].tap()
        XCTAssertEqual(app.buttons["thread-row-pin-two"].value as? String, "")
        app.staticTexts["Pin task one"].press(forDuration: 1)
        app.buttons["取消置顶"].tap()
        XCTAssertFalse(app.staticTexts["置顶任务"].exists)
    }
    private func pin(_ title: String, in app: XCUIApplication) {
        app.staticTexts[title].press(forDuration: 1)
        app.buttons["置顶"].tap()
        XCTAssertTrue(app.staticTexts["置顶任务"].waitForExistence(timeout: 5))
    }
    private func assertOrder(_ app: XCUIApplication) {
        let one = app.buttons["thread-row-pin-one"], two = app.buttons["thread-row-pin-two"]
        XCTAssertEqual(one.value as? String, "已置顶")
        XCTAssertEqual(two.value as? String, "已置顶")
        XCTAssertLessThan(two.frame.minY, one.frame.minY)
        XCTAssertLessThan(one.frame.minY, app.buttons["thread-row-fixture-thread"].frame.minY)
        XCTAssertEqual(app.buttons.matching(identifier: "thread-row-pin-one").count, 1)
        XCTAssertEqual(app.buttons.matching(identifier: "thread-row-pin-two").count, 1)
    }
}
