import SwiftUI
import UIKit
import WebKit
import XCTest
@testable import QuietReader

final class ReaderLineGuideTests: XCTestCase {
    func testRulerUsesMeasuredRowInsteadOfEstimatedFontPercentage() {
        let row = CGRect(x: 26, y: 320, width: 280, height: 35)
        let frame = ReaderLineGuideGeometry.window(height: 800, lineHeight: 100, fraction: 0.1, measuredLine: row)
        XCTAssertEqual(frame.midY, row.midY); XCTAssertEqual(frame.height, 41)
        let rows = [CGRect(x: 20, y: -80, width: 300, height: 24), row, CGRect(x: 20, y: 500, width: 300, height: 18)]
        XCTAssertEqual(ReaderLineGuideGeometry.closestLine(rows, to: 340, viewport: CGRect(x: 0, y: 0, width: 400, height: 800)), row)
    }
    @MainActor func testNativeRulerReadsActualTextKitLineRects() {
        let canvas = ReaderPageTextCanvas(frame: CGRect(x: 0, y: 0, width: 240, height: 500))
        canvas.setAttributedText(ReaderPageTextStyle.attributedString(text: String(repeating: "海面泛起微光，我们翻开书。", count: 12),
            fontSize: 24, lineSpacing: 10, usesSerif: false))
        canvas.setNeedsLayout(); canvas.layoutIfNeeded()
        let rows = canvas.renderedLineRects()
        XCTAssertGreaterThan(rows.count, 3)
        XCTAssertTrue(rows.allSatisfy { $0.height >= 24 && $0.width <= 241 })
        XCTAssertLessThan(rows[0].midY, rows[1].midY)
    }
    @MainActor func testWebRulerMeasuresWrappedLinesInsideIframeAtDifferentFontSizes() async throws {
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 420, height: 700))
        web.loadHTMLString("<html><head><meta name='viewport' content='width=device-width,initial-scale=1'></head><body style='margin:0'><iframe style='position:absolute;left:20px;top:80px;width:340px;height:550px;border:0'></iframe></body></html>", baseURL: nil)
        try await waitFor(web, "document.readyState==='complete' && !!document.querySelector('iframe')")
        let html = "<html><body style='margin:20px'><p id='text' style='margin:0;font-family:sans-serif;line-height:1.8'>" + String(repeating: "海边来信，翻开书页，记下此刻。", count: 12) + "</p></body></html>"
        _ = try await web.evaluateJavaScript("document.querySelector('iframe').srcdoc=\(try ContinuousPublicationScript.literal(html))")
        try await waitFor(web, "!!document.querySelector('iframe').contentDocument?.querySelector('#text')")
        for size in [14, 32] {
            _ = try await web.evaluateJavaScript("document.querySelector('iframe').contentDocument.querySelector('#text').style.fontSize='\(size)px'")
            let expectedValue = try await web.evaluateJavaScript("""
            (()=>{const f=document.querySelector('iframe'),d=f.contentDocument,r=d.createRange();r.selectNodeContents(d.querySelector('#text'));const line=r.getClientRects()[1],o=f.getBoundingClientRect();return {x:o.left+line.left,y:o.top+line.top,width:line.width,height:line.height}})()
            """)
            let expected = try XCTUnwrap(expectedValue as? [String: Double])
            let y = try XCTUnwrap(expected["y"]), height = try XCTUnwrap(expected["height"])
            let measuredValue = try await web.evaluateJavaScript(ReaderLineGuideScript.measure(at: CGPoint(x: 100, y: y + height / 2)))
            let measured = try XCTUnwrap(measuredValue as? [String: Double])
            XCTAssertEqual(try XCTUnwrap(measured["y"]), y, accuracy: 1)
            XCTAssertEqual(try XCTUnwrap(measured["height"]), height, accuracy: 1)
        }
    }
    @MainActor private func waitFor(_ web: WKWebView, _ condition: String) async throws {
        let deadline = Date.now.addingTimeInterval(20)
        while Date.now < deadline {
            if (try? await web.evaluateJavaScript("Boolean(\(condition))")) as? Bool == true { return }
            await Task.yield()
        }
        XCTFail("导读排版未达到条件：\(condition)")
    }
}
