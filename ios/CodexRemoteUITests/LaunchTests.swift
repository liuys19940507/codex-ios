import XCTest

final class LaunchTests: XCTestCase {
    func testAppLaunches() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["连接尚未配置"].waitForExistence(timeout: 10))
    }
}
