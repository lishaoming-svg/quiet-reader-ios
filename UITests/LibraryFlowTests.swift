import XCTest

final class LibraryFlowTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func launch(empty: Bool = false, files: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
            + (empty ? ["--empty-library"] : []) + (files ? ["--picker-fixtures"] : [])
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["书库"].waitForExistence(timeout: 20))
        app.tabBars.buttons["书库"].tap()
        return app
    }

    func testLocalBookReadsOfflineKeepsChapterAndBookmark() throws {
        let app = launch()
        let book = app.buttons["book.山海之间"]
        XCTAssertTrue(book.waitForExistence(timeout: 20))
        capture(app, "01-library")
        app.tabBars.buttons["主页"].tap()
        XCTAssertTrue(app.staticTexts["阅读目标"].waitForExistence(timeout: 5))
        capture(app, "01-home-reading-goal")
        app.tabBars.buttons["书库"].tap()
        book.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "海边的清晨")).firstMatch.waitForExistence(timeout: 20))
        capture(app, "02-reader")
        revealControls(app)
        app.buttons["下一章"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "灯下的书页")).firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["添加书签"].waitForExistence(timeout: 5))
        app.buttons["添加书签"].tap()
        XCTAssertTrue(app.buttons["移除书签"].waitForExistence(timeout: 5))
        app.buttons["reader.close"].tap()
        XCTAssertTrue(book.waitForExistence(timeout: 10))
        book.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "灯下的书页")).firstMatch.waitForExistence(timeout: 15))
        revealControls(app)
        XCTAssertTrue(app.buttons["移除书签"].waitForExistence(timeout: 5))
        app.buttons["reader.settings"].tap()
        XCTAssertTrue(app.navigationBars["主题与设置"].waitForExistence(timeout: 5))
        capture(app, "03-reading-settings")
    }

    func testEmptyLibraryOffersImportAndPickerCanBeCancelled() {
        let app = launch(empty: true)
        XCTAssertTrue(app.buttons["library.emptyImport"].waitForExistence(timeout: 10))
        capture(app, "04-empty-library")
        app.buttons["library.emptyImport"].tap()
        let cancel = app.buttons["取消"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 10))
        cancel.tap()
        XCTAssertTrue(app.buttons["library.emptyImport"].waitForExistence(timeout: 10))
    }

    func testSystemPickerActuallyImportsAndReadsSelectedTXT() {
        let app = launch(empty: true, files: true)
        importFile(app, name: "从文件导入")
        let book = app.buttons["book.从文件导入"]
        XCTAssertTrue(book.waitForExistence(timeout: 10))
        book.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "这段文字来自系统文件选择器")).firstMatch.waitForExistence(timeout: 15))
        capture(app, "05-imported-txt-reader")
    }

    func testEPUBImportsRendersPublisherContentAndResumesChapter() {
        let app = launch(empty: true, files: true)
        importFile(app, name: "精排示例")
        let book = app.buttons["book.精排示例"]
        XCTAssertTrue(book.waitForExistence(timeout: 10))
        book.tap()
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 30))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "海边的清晨")).firstMatch.waitForExistence(timeout: 30))
        capture(app, "06-epub-publisher-layout")
        app.buttons["reader.menu"].tap()
        XCTAssertTrue(app.switches["epub.publisherStyles"].waitForExistence(timeout: 5))
        capture(app, "07-epub-reading-menu")
        let chapter = app.buttons["灯下的书页"]
        app.swipeUp()
        XCTAssertTrue(chapter.waitForExistence(timeout: 5))
        chapter.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "夜色落在窗台上")).firstMatch.waitForExistence(timeout: 20))
        app.buttons["reader.close"].tap()
        XCTAssertTrue(book.waitForExistence(timeout: 10))
        book.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "夜色落在窗台上")).firstMatch.waitForExistence(timeout: 20))
        capture(app, "08-epub-restored-location")
    }

    private func importFile(_ app: XCUIApplication, name: String) {
        app.buttons["library.emptyImport"].tap()
        let file = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", name)).firstMatch
        XCTAssertTrue(file.waitForExistence(timeout: 20), app.debugDescription)
        file.tap()
        let open = app.buttons["打开"]
        if open.waitForExistence(timeout: 3) { open.tap() }
        capture(app, "picker-return-\(name)")
        XCTAssertTrue(app.navigationBars["导入结果"].waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "已加入书库")).firstMatch.exists)
        capture(app, "import-result-\(name)")
        app.buttons["import.done"].tap()
    }

    func testAccessibilityAcrossLibraryAndReader() throws {
        let app = launch()
        let book = app.buttons["book.山海之间"]
        XCTAssertTrue(book.waitForExistence(timeout: 20))
        var issues = audit(app, page: "书库")
        book.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "海边的清晨")).firstMatch.waitForExistence(timeout: 20))
        issues += audit(app, page: "阅读页")
        if !issues.isEmpty { XCTFail(issues.joined(separator: "\n")) }
    }

    private func revealControls(_ app: XCUIApplication) {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).tap()
        XCTAssertTrue(app.buttons["reader.close"].waitForExistence(timeout: 5))
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
    }
    private func audit(_ app: XCUIApplication, page: String) -> [String] {
        var issues: [String] = []
        do {
            try app.performAccessibilityAudit { issue in
                let element = issue.element?.label ?? "无具体元素"
                issues.append("Accessibility audit（\(page)）：\(issue.compactDescription) — \(element.prefix(120))")
                return true
            }
        } catch { issues.append("Accessibility audit（\(page)）：\(error.localizedDescription)") }
        return issues
    }
}
