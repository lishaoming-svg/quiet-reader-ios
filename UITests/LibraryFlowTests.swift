import XCTest

final class LibraryFlowTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func launch(empty: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"] + (empty ? ["--empty-library"] : [])
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
        app.buttons["library.import"].tap()
        let cancel = app.buttons["取消"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 10))
        cancel.tap()
        XCTAssertTrue(app.buttons["library.emptyImport"].waitForExistence(timeout: 10))
    }

    func testAccessibilityAcrossLibraryAndReader() throws {
        let app = launch()
        let book = app.buttons["book.山海之间"]
        XCTAssertTrue(book.waitForExistence(timeout: 20))
        audit(app, page: "书库")
        book.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "海边的清晨")).firstMatch.waitForExistence(timeout: 20))
        audit(app, page: "阅读页")
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
    private func audit(_ app: XCUIApplication, page: String) {
        do {
            try app.performAccessibilityAudit { issue in
                XCTFail("Accessibility audit（\(page)）：\(issue.compactDescription)")
                return true
            }
        } catch { XCTFail("Accessibility audit（\(page)）：\(error.localizedDescription)") }
    }
}
