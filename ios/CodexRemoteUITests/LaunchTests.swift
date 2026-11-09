import XCTest

final class LaunchTests: XCTestCase {
    func testAppLaunches() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["添加连接"].waitForExistence(timeout: 10))
        app.buttons["添加连接"].tap()
        XCTAssertTrue(app.textFields["服务地址"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.secureTextFields["配对令牌"].exists)
        XCTAssertFalse(app.buttons["保存并连接"].isEnabled)
    }
}
