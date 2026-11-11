import XCTest

final class AttachmentUITests: XCTestCase {
    func testNativeTextPasteKeepsEditorHeightAndUnicode() {
        let app = launch("--ui-test-paste-text")
        app.staticTexts["Fixture task"].tap()
        let draft = app.textViews["任务草稿"]
        XCTAssertTrue(draft.waitForExistence(timeout: 5)); draft.tap()
        let height = draft.frame.height
        paste(into: draft, in: app)
        XCTAssertTrue((draft.value as? String)?.contains("native clipboard 中文😀") == true)
        draft.typeText("\nsecond\nthird\nfourth\nfifth\nlast")
        XCTAssertEqual(draft.frame.height, height, accuracy: 1)
        capture("native-text-paste", app)
    }

    func testImagePasteCanPreviewPersistRemoveAndSendWithoutText() {
        let app = launch("--ui-test-paste-image")
        app.staticTexts["Fixture task"].tap()
        let draft = app.textViews["任务草稿"]
        XCTAssertTrue(draft.waitForExistence(timeout: 5)); draft.tap()
        let height = draft.frame.height
        paste(into: draft, in: app)
        let preview = firstPreview(in: app)
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        XCTAssertEqual(draft.frame.height, height, accuracy: 1)
        preview.tap()
        XCTAssertTrue(app.buttons["关闭预览"].waitForExistence(timeout: 5)); app.buttons["关闭预览"].tap()
        capture("attachment-image-paste", app)
        app.terminate(); app.launch()
        XCTAssertTrue(app.staticTexts["Fixture task"].waitForExistence(timeout: 10)); app.staticTexts["Fixture task"].tap()
        XCTAssertTrue(firstPreview(in: app).waitForExistence(timeout: 5))
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "移除附件：")).firstMatch.tap()
        XCTAssertFalse(firstPreview(in: app).exists)
        let reopenedDraft = app.textViews["任务草稿"]; reopenedDraft.tap()
        paste(into: reopenedDraft, in: app)
        XCTAssertTrue(firstPreview(in: app).waitForExistence(timeout: 5))
        let send = app.buttons["发送指令"]
        XCTAssertTrue(send.isEnabled); send.tap()
        XCTAssertTrue(app.staticTexts["ATTACHMENTS_ACCEPTED_1"].waitForExistence(timeout: 10))
        XCTAssertFalse(firstPreview(in: app).exists)
    }

    func testFilePasteCanBePreviewedAndSentFromNewTaskForm() {
        let app = launch("--ui-test-paste-file")
        app.buttons["新任务"].tap()
        let draft = app.textViews["任务草稿"]
        XCTAssertTrue(draft.waitForExistence(timeout: 5)); draft.tap()
        paste(into: draft, in: app)
        let preview = firstPreview(in: app)
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        preview.tap()
        XCTAssertTrue(app.buttons["关闭预览"].waitForExistence(timeout: 5)); app.buttons["关闭预览"].tap()
        capture("attachment-file-new-task", app)
        let submit = app.navigationBars["新任务"].buttons["创建并发送"]
        XCTAssertTrue(submit.isEnabled); submit.tap()
        XCTAssertTrue(app.navigationBars["Created fixture task"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["ATTACHMENTS_ACCEPTED_1"].waitForExistence(timeout: 10))
    }

    private func launch(_ clipboard: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-workspace", clipboard]
        app.launch()
        XCTAssertTrue(app.staticTexts["Fixture task"].waitForExistence(timeout: 10))
        return app
    }
    private func paste(into draft: XCUIElement, in app: XCUIApplication) {
        draft.press(forDuration: 1)
        let paste = app.descendants(matching: .any).matching(NSPredicate(format: "label IN %@", ["Paste", "粘贴"])).firstMatch
        XCTAssertTrue(paste.waitForExistence(timeout: 5), "Keep the native long-press editing menu")
        paste.tap()
    }
    private func firstPreview(in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "预览附件：")).firstMatch
    }
    private func capture(_ name: String, _ app: XCUIApplication) {
        let keyboardTutorial = app.buttons["Continue"]
        if keyboardTutorial.exists && keyboardTutorial.isHittable { keyboardTutorial.tap() }
        let dismiss = app.buttons["收起键盘"]
        if dismiss.waitForExistence(timeout: 3) && dismiss.isHittable { dismiss.tap() }
        let preview = firstPreview(in: app)
        if preview.exists {
            let visible = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: preview)
            XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: 5), .completed)
        }
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
