import ReadiumShared
import SwiftUI
import UIKit
import WebKit
import XCTest
@testable import QuietReader

final class ContinuousPublicationTests: XCTestCase {
    @MainActor
    func testRichChaptersShareOneVerticalViewportAndRestoreSecondChapter() async throws {
        let source = try JSONDecoder().decode(BookSourceDefinition.self, from: Data(#"{"bookSourceUrl":"https://example.org","bookSourceName":"离线测试"}"#.utf8))
        let chapters = [BookChapter(title: "清晨来信", url: "https://example.org/one", index: 0), BookChapter(title: "灯下回信", url: "https://example.org/two", index: 1)]
        let bodies = [SourceChapterDocument(text: "清晨来信", html: "<p style='color:rgb(200,0,0)'>红色来信</p>" + String(repeating: "<p>清晨，海面泛起微光。翻开书，记下今天的故事。</p>", count: 30)),
            SourceChapterDocument(text: "灯下回信", html: "<p style='text-align:right;background-color:rgb(160,206,101);border-radius:12px'>灯下回信</p>" + String(repeating: "<p>夜色落在窗台上，灯照亮了书页。</p>", count: 25))]
        let container = SourcePublicationContainer(chapters: chapters, source: source) { index in bodies[index] }
        let links = chapters.enumerated().map { ReadiumShared.Link(href: "chapter\($0.offset).xhtml", mediaType: .xhtml, title: $0.element.title) }
        let publication = Publication(manifest: Manifest(metadata: Metadata(title: "连续阅读测试"), readingOrder: links), container: container)
        let ready = expectation(description: "连续阅读首章已排版")
        var initialReady = false, navigate: ((ContinuousReadingPosition) -> Void)?, latest = ContinuousReadingPosition(index: 0)
        var failures: [String] = []
        let view = ContinuousPublicationView(publication: publication, initial: .init(index: 0), theme: "sepia", publisherStyles: true, fontSize: 100,
            changed: { latest = $0 }, tapped: {}, ready: { if !initialReady { initialReady = true; ready.fulfill() } },
            failure: { failures.append($0) }, installNavigation: { navigate = $0 })
        let controller = UIHostingController(rootView: view)
        let previousWindow = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first { $0.isKeyWindow }
        let size = CGSize(width: 820, height: 1180)
        let window: UIWindow
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first { window = UIWindow(windowScene: scene) }
        else { window = UIWindow(frame: CGRect(origin: .zero, size: size)) }
        window.frame = CGRect(origin: .zero, size: size); window.rootViewController = controller; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previousWindow?.makeKeyAndVisible() }
        controller.view.frame = window.bounds; controller.view.layoutIfNeeded()
        await fulfillment(of: [ready], timeout: 30)
        guard initialReady else { return }
        func findWeb(_ parent: UIView) -> WKWebView? { (parent as? WKWebView) ?? parent.subviews.compactMap { findWeb($0) }.first }
        let web = try XCTUnwrap(findWeb(controller.view))
        try await waitFor(web, condition: "document.querySelectorAll('iframe').length===2 && [...document.querySelectorAll('iframe')].every(f=>f.contentDocument?.querySelector('p'))")
        let css = try await web.evaluateJavaScript("getComputedStyle(document.querySelectorAll('iframe')[0].contentDocument.querySelector('p')).color") as? String
        XCTAssertEqual(css, "rgb(200, 0, 0)")
        let secondColor = try await web.evaluateJavaScript("getComputedStyle(document.querySelectorAll('iframe')[1].contentDocument.querySelector('p')).backgroundColor") as? String
        XCTAssertEqual(secondColor, "rgb(160, 206, 101)")
        _ = try await web.evaluateJavaScript("scrollTo(0,document.querySelectorAll('iframe')[1].parentElement.offsetTop+120)")
        try await waitFor(web, condition: "scrollY > document.querySelectorAll('iframe')[1].parentElement.offsetTop")
        let changed = expectation(for: NSPredicate { _, _ in latest.index == 1 }, evaluatedWith: web)
        await fulfillment(of: [changed], timeout: 10)
        XCTAssertEqual(latest.index, 1, "向上滑动应直接进入下一章，无需横向切换")
        let horizontalOffset = try await web.evaluateJavaScript("scrollX") as? Int
        XCTAssertEqual(horizontalOffset, 0)
        navigate?(.init(index: 1, fraction: 0.5))
        try await waitFor(web, condition: "Math.abs((scrollY-document.querySelectorAll('iframe')[1].parentElement.offsetTop)/(document.querySelectorAll('iframe')[1].offsetHeight-innerHeight)-.5)<.03")
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }
    func testViewportUnitsUseOuterViewportInsteadOfGrowingIframe() {
        let result = ContinuousPublicationScript.prepareHTML("<html><head><style>img{height:100vh;max-height:90vh}</style></head><body>正文</body></html>")
        XCTAssertTrue(result.contains("calc(var(--ibooks-vh, 8px) * 100)"))
        XCTAssertTrue(result.contains("script-src 'none'"))
        XCTAssertTrue(result.contains("frame-src 'none'"))
    }
    @MainActor
    private func waitFor(_ web: WKWebView, condition: String) async throws {
        let deadline = Date.now.addingTimeInterval(20)
        while Date.now < deadline {
            if (try? await web.evaluateJavaScript("Boolean(\(condition))")) as? Bool == true { return }
            await Task.yield()
        }
        XCTFail("连续阅读视图未达到条件：\(condition)")
    }
}
