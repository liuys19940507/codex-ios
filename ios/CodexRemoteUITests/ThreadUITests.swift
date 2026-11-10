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
        let process = app.buttons["查看处理过程"]
        reveal(process, in: app, up: false)
        let anchor = process.frame.minY
        let position = draft.frame.minY
        swipeConversation(app, up: true)
        XCTAssertTrue(!process.exists || abs(process.frame.minY - anchor) > 2)
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
        let process = app.buttons["查看处理过程"]
        reveal(process, in: app, up: false)
        XCTAssertTrue(process.exists)
        let heading = app.staticTexts["任务已完成"]
        XCTAssertTrue(heading.waitForExistence(timeout: 5))
        XCTAssertLessThan(heading.frame.height, 200, "Markdown should scale once at the largest text size")
        let largeText = XCTAttachment(screenshot: app.screenshot())
        largeText.name = "conversation-largest-text"; largeText.lifetime = .keepAlways; add(largeText)
        process.tap()
        let copy = app.buttons["复制全部输出"]
        XCTAssertTrue(copy.waitForExistence(timeout: 5))
        reveal(copy, in: app, up: true)
        copy.tap()
        XCTAssertTrue(app.staticTexts["已复制"].waitForExistence(timeout: 5))
        let draft = app.textViews["任务草稿"]
        XCTAssertTrue(draft.isHittable)
        draft.tap(); draft.typeText("parent draft stays")
        XCTAssertGreaterThan(draft.frame.height, 70, "The largest text size needs a complete line and editor insets")
        if app.buttons["收起键盘"].exists { app.buttons["收起键盘"].tap() }
        let largeDraft = XCTAttachment(screenshot: app.screenshot())
        largeDraft.name = "composer-largest-text"; largeDraft.lifetime = .keepAlways; add(largeDraft)
        let child = app.buttons["打开子任务"]
        reveal(child, in: app, up: true)
        child.tap()
        XCTAssertTrue(app.navigationBars["Child fixture task"].waitForExistence(timeout: 10))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["Fixture task"].waitForExistence(timeout: 10))
        XCTAssertTrue(draft.isHittable)
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
        let submit = app.navigationBars["新任务"].buttons["创建并发送"]
        XCTAssertTrue(submit.exists, "Create must stay in the navigation bar while editing")
        let before = XCTAttachment(string: "enabled=\(submit.isEnabled), hittable=\(submit.isHittable)\n" + app.debugDescription)
        before.name = "create-before-tap"; before.lifetime = .keepAlways; add(before)
        XCTAssertTrue(submit.isEnabled)
        submit.tap()
        let opened = app.navigationBars["Created fixture task"].waitForExistence(timeout: 10)
        if !opened {
            let state = XCTAttachment(string: app.debugDescription)
            state.name = "create-task-navigation-state"; state.lifetime = .keepAlways; add(state)
        }
        XCTAssertTrue(opened)
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication, up: Bool) {
        for _ in 0..<14 {
            let top = app.navigationBars.firstMatch.frame.maxY + 8
            let bottom = app.textViews["任务草稿"].frame.minY - 8
            if element.exists {
                let frame = element.frame
                if frame.minY >= top, frame.maxY <= bottom, element.isHittable { return }
                swipeConversation(app, up: frame.minY > top)
            } else { swipeConversation(app, up: up) }
        }
        XCTFail("Control did not become visible above the fixed composer")
    }
    private func swipeConversation(_ app: XCUIApplication, up: Bool) {
        let top = app.navigationBars.firstMatch.frame.maxY + 20
        let bottom = max(top + 80, app.textViews["任务草稿"].frame.minY - 20)
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let upper = origin.withOffset(CGVector(dx: app.frame.width / 2, dy: top))
        let lower = origin.withOffset(CGVector(dx: app.frame.width / 2, dy: bottom))
        (up ? lower : upper).press(forDuration: 0.05, thenDragTo: up ? upper : lower)
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
