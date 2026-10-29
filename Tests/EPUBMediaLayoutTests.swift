import ReadiumNavigator
import ReadiumShared
import ReadiumStreamer
import UIKit
import WebKit
import XCTest
import ZIPFoundation
@testable import QuietReader

final class EPUBMediaLayoutTests: XCTestCase {
    @MainActor
    func testTallIllustrationFitsSinglePageAtTabletPortraitAndLandscapeSizes() async throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "precision", withExtension: "epub", subdirectory: "Fixtures"))
        let archive = try ZIPFoundation.Archive(data: Data(contentsOf: fixture), accessMode: .update)
        let path = "OEBPS/Text/chapter 1.xhtml"
        try archive.remove(try XCTUnwrap(archive[path]))
        let html = Data("<html xmlns='http://www.w3.org/1999/xhtml'><head><title>完整插图</title><style>body{margin:0}img{width:1000px;height:2000px}</style></head><body><div><img src='../Images/cover.svg'/></div></body></html>".utf8)
        try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(html.count)) { offset, count in html.subdata(in: Int(offset)..<min(Int(offset) + count, html.count)) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let imported = try LocalBookImporter.prepare(data: XCTUnwrap(archive.data), filename: "插图.epub", root: root)
        let file = try XCTUnwrap(FileURL(url: LocalBookStorage.publicationURL(for: imported.book.bookURL, root: root)))
        let asset = try await AssetRetriever(httpClient: DefaultHTTPClient()).retrieve(url: file).get()
        let publication = try await PublicationOpener(parser: EPUBParser()).open(asset: asset, allowUserInteraction: false).get()
        for size in [CGSize(width: 820, height: 1180), CGSize(width: 1180, height: 820)] {
            let preferences = EPUBReadingLayout.preferences(publisherStyles: true, fontSizePercent: 100, scroll: false, theme: "light")
            let navigator = try EPUBNavigatorViewController(publication: publication, initialLocation: nil, config: .init(preferences: preferences))
            let ready = expectation(description: "插图页面已排版 \(size)")
            let probe = MediaProbe(ready: ready); navigator.delegate = probe
            let container = UIViewController()
            let window: UIWindow
            if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first { window = UIWindow(windowScene: scene) }
            else { window = UIWindow(frame: CGRect(origin: .zero, size: size)) }
            window.frame = CGRect(origin: .zero, size: size)
            window.rootViewController = container
            container.addChild(navigator); container.view.addSubview(navigator.view)
            container.setOverrideTraitCollection(UITraitCollection(horizontalSizeClass: .regular), forChild: navigator)
            navigator.view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                navigator.view.leadingAnchor.constraint(equalTo: container.view.leadingAnchor),
                navigator.view.topAnchor.constraint(equalTo: container.view.topAnchor),
                navigator.view.widthAnchor.constraint(equalToConstant: size.width),
                navigator.view.heightAnchor.constraint(equalToConstant: size.height)
            ])
            navigator.didMove(toParent: container); window.makeKeyAndVisible()
            window.layoutIfNeeded(); container.view.layoutIfNeeded()
            navigator.view.setNeedsLayout(); navigator.view.layoutIfNeeded()
            await fulfillment(of: [ready], timeout: 30)
            guard probe.sent else {
                // The unmet expectation remains a test failure. Do not then call
                // Readium's API that waits indefinitely for a missing spread.
                navigator.delegate = nil; window.isHidden = true
                return
            }
            let result = try await navigator.evaluateJavaScript("""
            (() => {
              const image = document.querySelector('img');
              const r=image.getBoundingClientRect(); return JSON.stringify({left:r.left,top:r.top,right:r.right,bottom:r.bottom,width:innerWidth,height:innerHeight,complete:image.complete,natural:image.naturalWidth});
            })()
            """).get()
            let json = try XCTUnwrap(result as? String)
            let dimensions = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
            func number(_ key: String) throws -> Double { try XCTUnwrap(dimensions[key] as? NSNumber).doubleValue }
            XCTAssertGreaterThan(try number("width"), 500, "必须在有效平板视口中验证插图")
            XCTAssertGreaterThan(try number("height"), 500)
            XCTAssertEqual(dimensions["complete"] as? Bool, true)
            XCTAssertGreaterThan(try number("natural"), 0)
            XCTAssertGreaterThanOrEqual(try number("left"), -1)
            XCTAssertLessThanOrEqual(try number("right"), try number("width") + 1)
            XCTAssertLessThanOrEqual(try number("bottom"), try number("height") + 1, "插图不能跨页或被裁掉")
            XCTAssertTrue(probe.errors.isEmpty)
            navigator.delegate = nil; window.isHidden = true
        }
    }
}
@MainActor
private final class MediaProbe: NSObject, EPUBNavigatorDelegate {
    let ready: XCTestExpectation
    var sent = false
    var errors: [String] = []
    init(ready: XCTestExpectation) { self.ready = ready }
    func navigator(_ navigator: EPUBNavigatorViewController, setupUserScripts content: WKUserContentController) {
        content.addUserScript(WKUserScript(source: EPUBReadingLayout.imageScript, injectionTime: .atDocumentStart, forMainFrameOnly: false))
    }
    func navigator(_ navigator: any ViewportObservingNavigator, viewportDidChange viewport: NavigatorViewport?) {
        if viewport != nil, !sent { sent = true; ready.fulfill() }
    }
    func navigator(_ navigator: Navigator, presentError error: NavigatorError) { errors.append(String(describing: error)) }
    func navigator(_ navigator: Navigator, didFailToLoadResourceAt href: RelativeURL, withError error: ReadError) { errors.append(href.string) }
}
