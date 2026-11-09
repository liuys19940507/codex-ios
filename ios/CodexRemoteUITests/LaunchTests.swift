import XCTest

final class LaunchTests: XCTestCase {
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
