import XCTest

final class LaunchTests: XCTestCase {
    func testDeletingActiveConnectionReturnsToPairingScreen() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-workspace"]
        app.launch()
        XCTAssertTrue(app.buttons["更多"].waitForExistence(timeout: 10))
        app.buttons["更多"].tap(); app.buttons["workspace.connections"].tap()
        XCTAssertTrue(app.staticTexts["Fixture Windows"].waitForExistence(timeout: 5))
        app.staticTexts["Fixture Windows"].press(forDuration: 1)
        app.buttons["删除连接"].tap()
        XCTAssertTrue(app.staticTexts["删除此连接？"].waitForExistence(timeout: 5))
        app.buttons["确认删除"].tap()
        XCTAssertTrue(app.buttons["添加连接"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Fixture Windows"].exists)
        XCTAssertFalse(app.buttons["更多"].exists)
    }
    func testConnectAndEditHaveIndependentTapTargets() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-saved-connection"]
        app.launch()
        XCTAssertTrue(app.buttons["连接"].waitForExistence(timeout: 10))
        app.buttons["连接"].tap()
        XCTAssertFalse(app.navigationBars["编辑连接"].waitForExistence(timeout: 2))
        app.buttons["编辑 Fixture Windows"].tap()
        XCTAssertTrue(app.navigationBars["编辑连接"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.secureTextFields["配对令牌"].exists)
    }
    func testAppLaunches() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["添加连接"].waitForExistence(timeout: 10))
        app.buttons["添加连接"].tap()
        XCTAssertTrue(app.textFields["服务地址"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.secureTextFields["配对令牌"].exists)
        XCTAssertFalse(app.buttons["保存并连接"].isEnabled)
        app.secureTextFields["配对令牌"].tap()
        app.secureTextFields["配对令牌"].typeText("test-token")
        XCTAssertTrue(app.buttons["保存并连接"].isEnabled)
    }
}
