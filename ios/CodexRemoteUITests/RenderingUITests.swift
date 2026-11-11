import XCTest

final class RenderingUITests: XCTestCase {
    func testCodeViewerAndLightAppearance() { verify(dark: false) }
    func testCodeViewerAndDarkAppearance() { verify(dark: true) }
    private func verify(dark: Bool) {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-workspace", "--ui-test-activity", "--ui-test-rendering"] + (dark ? ["--ui-test-dark"] : [])
        app.launch()
        XCTAssertTrue(app.staticTexts["Fixture task"].waitForExistence(timeout: 10))
        app.staticTexts["Fixture task"].tap()
        XCTAssertTrue(app.textViews["任务草稿"].waitForExistence(timeout: 5))
        let process = app.buttons["查看处理过程"]
        reveal(process, in: app, up: false)
        XCTAssertTrue(process.isHittable)
        capture(app, "conversation-\(dark ? "dark" : "light")")
        let fullCode = app.buttons["查看完整代码"]
        reveal(fullCode, in: app, up: true)
        XCTAssertTrue(fullCode.isHittable)
        fullCode.tap()
        XCTAssertTrue(app.navigationBars["swift"].waitForExistence(timeout: 5))
        let viewer = app.scrollViews["raw-output-scroll"]
        XCTAssertTrue(viewer.waitForExistence(timeout: 5))
        // The same code also exists in the conversation behind the sheet.
        let code = viewer.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "print(greeting)")).firstMatch
        XCTAssertTrue(code.exists)
        XCTAssertLessThan(code.frame.minY, app.navigationBars["swift"].frame.maxY + 80, "Short code should start at the top of the viewer")
        app.buttons["复制全部"].tap()
        XCTAssertTrue(app.buttons["已复制"].exists)
        capture(app, "code-viewer-\(dark ? "dark" : "light")")
        app.buttons["完成"].tap()
        XCTAssertTrue(app.textViews["任务草稿"].exists)
    }
    private func reveal(_ element: XCUIElement, in app: XCUIApplication, up: Bool) {
        var observations: [String] = []
        for _ in 0..<14 {
            let top = app.navigationBars.firstMatch.frame.maxY + 8
            let bottom = app.textViews["任务草稿"].frame.minY - 8
            if element.exists {
                let frame = element.frame
                observations.append("band=\(top)...\(bottom) frame=\(frame) hittable=\(element.isHittable)")
                if frame.minY >= top, frame.maxY <= bottom, element.isHittable { return }
                swipeConversation(app, up: frame.minY > top)
            } else { swipeConversation(app, up: up) }
        }
        let trace = XCTAttachment(string: observations.joined(separator: "\n"))
        trace.name = "rendering-scroll-coordinates"; trace.lifetime = .keepAlways; add(trace)
        XCTFail("Control did not become visible above the fixed composer")
    }
    private func swipeConversation(_ app: XCUIApplication, up: Bool) {
        let top = app.navigationBars.firstMatch.frame.maxY + 20
        let bottom = max(top + 80, app.textViews["任务草稿"].frame.minY - 20)
        let middle = (top + bottom) / 2
        let halfDistance = min(75, (bottom - top) / 4)
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let upper = origin.withOffset(CGVector(dx: app.frame.width / 2, dy: middle - halfDistance))
        let lower = origin.withOffset(CGVector(dx: app.frame.width / 2, dy: middle + halfDistance))
        (up ? lower : upper).press(forDuration: 0.05, thenDragTo: up ? upper : lower,
                                  withVelocity: .slow, thenHoldForDuration: 0.2)
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
    }
}
