import XCTest
import UIKit

final class LibraryFlowTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func launch(empty: Bool = false, files: Bool = false, rich: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
            + (empty ? ["--empty-library"] : []) + (files ? ["--picker-fixtures"] : []) + (rich ? ["--rich-source-fixture"] : [])
        app.launch()
        // A cold runner can finish launch before the scene receives its first
        // foreground event. Activate it before asking AX for the tab hierarchy.
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
        app.activate()
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
        app.buttons["reader.menu"].tap()
        app.buttons["目录"].tap()
        app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "灯下的书页")).firstMatch.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "灯下的书页")).firstMatch.waitForExistence(timeout: 10))
        if !app.buttons["reader.close"].exists { revealControls(app) }
        app.buttons["reader.menu"].tap()
        XCTAssertTrue(app.buttons["添加书签"].waitForExistence(timeout: 5))
        app.buttons["添加书签"].tap()
        XCTAssertTrue(app.buttons["移除书签"].waitForExistence(timeout: 5))
        app.buttons["reader.close"].tap()
        XCTAssertTrue(book.waitForExistence(timeout: 10))
        book.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "灯下的书页")).firstMatch.waitForExistence(timeout: 15))
        revealControls(app)
        app.buttons["reader.menu"].tap()
        XCTAssertTrue(app.buttons["移除书签"].waitForExistence(timeout: 5))
        app.buttons["reader.settings"].tap()
        XCTAssertTrue(app.navigationBars["主题与设置"].waitForExistence(timeout: 5))
        capture(app, "03-reading-settings")
    }

    func testLocalCollectionsAndNotesRemainAvailable() {
        executionTimeAllowance = 300
        let app = launch()
        let book = app.buttons["book.山海之间"]
        XCTAssertTrue(book.waitForExistence(timeout: 10))
        book.press(forDuration: 1)
        app.buttons["加入想读"].tap()
        app.buttons["library.collections"].tap()
        XCTAssertTrue(app.buttons["collection.want"].waitForExistence(timeout: 5))
        app.buttons["collection.want"].tap()
        XCTAssertTrue(book.waitForExistence(timeout: 5))
        capture(app, "11-want-to-read-collection")
        book.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "海边的清晨")).firstMatch.waitForExistence(timeout: 20))
        revealControls(app); app.buttons["reader.menu"].tap(); app.buttons["笔记与书签"].tap()
        XCTAssertTrue(app.buttons["添加笔记"].waitForExistence(timeout: 5)); app.buttons["添加笔记"].tap()
        let note = app.textViews["annotation.note"]
        XCTAssertTrue(note.waitForExistence(timeout: 10)); note.tap(); note.typeText("Reading note 2026")
        app.buttons["annotation.save"].tap()
        if !app.buttons["reader.close"].waitForExistence(timeout: 5) { revealControls(app) }
        app.buttons["reader.menu"].tap(); app.buttons["笔记与书签"].tap()
        XCTAssertTrue(app.staticTexts["Reading note 2026"].waitForExistence(timeout: 10))
        capture(app, "12-local-reading-note")
    }

    func testEmptyLibraryOffersImportAndPickerCanBeCancelled() {
        executionTimeAllowance = 300
        let app = launch(empty: true)
        XCTAssertTrue(app.buttons["library.emptyImport"].waitForExistence(timeout: 10))
        capture(app, "04-empty-library")
        app.buttons["library.emptyImport"].tap()
        // During File Provider startup the system exposes its close control as
        // an accessibility container before classifying it as a Button.
        let cancel = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "取消")).firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 40))
        cancel.tap()
        XCTAssertTrue(app.buttons["library.emptyImport"].waitForExistence(timeout: 10))
    }

    func testRichSourceContinuousScrollAndMovableLineGuide() {
        executionTimeAllowance = 300
        let app = launch(rich: true)
        let book = app.buttons["book.连续精排示例"]
        XCTAssertTrue(book.waitForExistence(timeout: 10)); book.tap()
        let first = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "你有一封新来信")).firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 30))
        XCTAssertFalse(app.buttons["reader.menu"].exists)
        capture(app, "09-source-rich-dialogue")
        // The next chapter belongs to the same scroll view, with no chapter button.
        let second = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "灯下的回信已经寄出")).firstMatch
        for _ in 0..<6 {
            if second.exists && second.isHittable { break }
            app.swipeUp()
        }
        let secondVisible = expectation(for: NSPredicate { _, _ in second.exists && second.isHittable }, evaluatedWith: app)
        wait(for: [secondVisible], timeout: 10)
        revealControls(app); app.buttons["reader.menu"].tap(); app.buttons["主题与设置"].tap()
        let toggle = app.switches["reader.lineGuide"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "0", "逐行导读默认关闭")
        // SwiftUI exposes the entire labelled List row as a Switch. Its centre
        // is the label, outside the UISwitch's touch target on iOS 26. Tap the
        // trailing control and verify its value before dismissing settings.
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        let enabled = expectation(for: NSPredicate(format: "value == %@", "1"), evaluatedWith: toggle)
        wait(for: [enabled], timeout: 5)
        capture(app, "10-line-guide-enabled-settings")
        app.buttons["完成"].tap()
        let guide = app.descendants(matching: .any).matching(identifier: "reader.lineGuideWindow").firstMatch
        XCTAssertTrue(guide.waitForExistence(timeout: 10))
        let before = guide.frame.midY
        guide.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1,
            thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)))
        XCTAssertGreaterThan(guide.frame.midY, before + 20)
        capture(app, "10-movable-line-guide")
    }

    func testSystemPickerActuallyImportsAndReadsSelectedTXT() {
        executionTimeAllowance = 300
        let app = launch(empty: true, files: true)
        importFile(app, name: "从文件导入")
        let book = app.buttons["book.从文件导入"]
        XCTAssertTrue(book.waitForExistence(timeout: 10))
        book.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "这段文字来自系统文件选择器")).firstMatch.waitForExistence(timeout: 15))
        capture(app, "05-imported-txt-reader")
    }

    func testEPUBImportsRendersPublisherContentAndResumesChapter() {
        executionTimeAllowance = 300
        let app = launch(empty: true, files: true)
        importFile(app, name: "精排示例")
        let book = app.buttons["book.精排示例"]
        XCTAssertTrue(book.waitForExistence(timeout: 10))
        book.tap()
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 30))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "海边的清晨")).firstMatch.waitForExistence(timeout: 30))
        capture(app, "06-epub-publisher-layout")
        XCTAssertFalse(app.buttons["reader.menu"].exists, "阅读默认隐藏浮动按钮")
        revealControls(app)
        app.buttons["reader.menu"].tap()
        app.buttons["主题与设置"].tap()
        let publisherStyles = app.switches["epub.publisherStyles"]
        // Theme cards and font controls precede the original-style switch.
        // Scroll the actual settings list, which also expands the medium sheet.
        for _ in 0..<6 {
            if publisherStyles.exists && publisherStyles.isHittable { break }
            app.collectionViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(publisherStyles.waitForExistence(timeout: 5))
        XCTAssertTrue(publisherStyles.isHittable)
        capture(app, "07-epub-reading-menu")
        app.buttons["完成"].tap()
        if !app.buttons["reader.menu"].exists { revealControls(app) }
        app.buttons["reader.menu"].tap()
        app.buttons["目录"].tap()
        let chapter = app.buttons["灯下的书页"]
        app.swipeUp()
        XCTAssertTrue(chapter.waitForExistence(timeout: 5))
        chapter.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "夜色落在窗台上")).firstMatch.waitForExistence(timeout: 20))
        let progress = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "全书进度")).firstMatch
        revealControls(app)
        let chapterPosition = expectation(for: NSPredicate { _, _ in progress.label == "全书进度 50%" }, evaluatedWith: app)
        wait(for: [chapterPosition], timeout: 15)
        waitForVisibleEPUBBody(app)
        capture(app, "08-epub-chapter-before-close")
        let savedPosition = progress.label
        app.buttons["reader.close"].tap()
        XCTAssertTrue(book.waitForExistence(timeout: 10))
        book.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "夜色落在窗台上")).firstMatch.waitForExistence(timeout: 20))
        let restoring = app.descendants(matching: .any).matching(identifier: "epub.restoring").firstMatch
        let restored = expectation(for: NSPredicate { _, _ in !restoring.exists }, evaluatedWith: app)
        wait(for: [restored], timeout: 20)
        revealControls(app)
        XCTAssertEqual(progress.label, savedPosition)
        waitForVisibleEPUBBody(app)
        capture(app, "08-epub-restored-location")
    }

    private func waitForVisibleEPUBBody(_ app: XCUIApplication) {
        let body = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "夜色落在窗台上")).firstMatch
        let visible = expectation(for: NSPredicate { _, _ in
            guard body.exists, body.isHittable else { return false }
            // WebKit can expose preloaded text while its page is still blank.
            // Check rendered ink in the reading area, excluding floating controls.
            guard let image = app.screenshot().image.cgImage else { return false }
            let rect = CGRect(x: CGFloat(image.width) * 0.1, y: CGFloat(image.height) * 0.2,
                              width: CGFloat(image.width) * 0.8, height: CGFloat(image.height) * 0.55)
            guard let crop = image.cropping(to: rect) else { return false }
            var pixels = [UInt8](repeating: 0, count: 160 * 240 * 4)
            let darkPixels = pixels.withUnsafeMutableBytes { buffer -> Int in
                guard let context = CGContext(data: buffer.baseAddress, width: 160, height: 240,
                    bitsPerComponent: 8, bytesPerRow: 160 * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
                context.draw(crop, in: CGRect(x: 0, y: 0, width: 160, height: 240))
                let bytes = buffer.bindMemory(to: UInt8.self)
                var count = 0
                for offset in stride(from: 0, to: bytes.count, by: 4) {
                    let red = Int(bytes[offset])
                    let green = Int(bytes[offset + 1])
                    let blue = Int(bytes[offset + 2])
                    if red + green + blue < 450 { count += 1 }
                }
                return count
            }
            return darkPixels > 100
        }, evaluatedWith: app)
        wait(for: [visible], timeout: 30)
    }

    private func importFile(_ app: XCUIApplication, name: String) {
        app.buttons["library.emptyImport"].tap()
        // Use one query per poll. On a cold simulator, querying five element
        // types for both a file and a folder consumed the entire 45s timeout
        // before the provider finished resolving directoryURL. Files exposes
        // grid/list items as different types, but their labels start with the
        // filename. Fixtures now live directly in the published Documents root.
        let file = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
        let ready = expectation(for: NSPredicate { _, _ in
            file.exists && file.isHittable
        }, evaluatedWith: app)
        let result = XCTWaiter.wait(for: [ready], timeout: 90)
        if result != .completed {
            capture(app, "picker-not-ready-\(name)")
            // XCUIElementSnapshot does not expose XCUIElement.debugDescription.
            // Convert the public snapshot value instead of calling that member.
            let tree = (try? String(describing: app.snapshot())) ?? app.debugDescription
            let attachment = XCTAttachment(string: tree)
            attachment.name = "picker-hierarchy-\(name)"; attachment.lifetime = .keepAlways
            add(attachment)
        }
        XCTAssertEqual(result, .completed, "系统文件选择器中的 \(name) 应可见且可点击")
        capture(app, "picker-selected-file-\(name)")
        file.tap()
        let open = app.buttons["打开"]
        if open.waitForExistence(timeout: 3) { open.tap() }
        capture(app, "picker-return-\(name)")
        XCTAssertTrue(app.navigationBars["导入结果"].waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "已加入书库")).firstMatch.exists)
        capture(app, "import-result-\(name)")
        app.buttons["import.done"].tap()
    }

    // Audits can spend two minutes per screen inside the system AX service.
    // Run them after functional flows and allow both screens to finish, so an
    // audit timeout cannot restart the runner before a document-picker test.
    func testZZAccessibilityAcrossLibraryAndReader() throws {
        executionTimeAllowance = 300
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
