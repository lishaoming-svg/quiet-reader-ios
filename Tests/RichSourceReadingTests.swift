import Foundation
import SwiftData
import SwiftSoup
import XCTest
import ZIPFoundation
@testable import QuietReader

final class RichSourceReadingTests: XCTestCase {
    private func source() throws -> BookSourceDefinition {
        try JSONDecoder().decode(BookSourceDefinition.self, from: Data(#"{"sourceId":"rich-test","bookSourceName":"测试书源","bookSourceUrl":"https://example.org"}"#.utf8))
    }
    private func book() -> SearchBook {
        SearchBook(sourceID: "rich-test", sourceName: "测试书源", name: "海边来信", author: "测试作者", intro: "", kind: "", lastChapter: "", updateTime: "", bookURL: "https://example.org/book", coverURL: "", tocURL: "")
    }
    func testLofterEmptyContentFallsBackToLongTextAndKeepsFormatting() throws {
        for empty in ["" as Any, NSNull()] {
            let root: [String: Any] = ["response": ["posts": [["postData": ["post": ["content": empty,
                "longInfo": ["content": "<p style='color:red;text-align:center'>新的来信</p><p style='border:1px solid black;border-radius:12px'>你好。</p>"]]]]]]]
            let value = try NativeLofterAdapter.document(from: root)
            XCTAssertTrue(value.text.contains("新的来信"))
            XCTAssertTrue(value.html.contains("color:red"))
            XCTAssertTrue(value.html.contains("border-radius:12px"))
        }
    }
    func testImageOnlyLofterPostsAndReturnContentAreValidChapters() throws {
        let root: [String: Any] = ["response": ["posts": [["postView": ["content": "", "photoLinks": [],
            "photoPostView": ["photoLinks": [["orign": "//img.example.org/one.png"]]],
            "returnContent": [["content": "", "images": [["url": "https://img.example.org/two.png"]]]]]]]]]
        let value = try NativeLofterAdapter.document(from: root)
        XCTAssertEqual(value.text, "[插图]")
        let images = try SwiftSoup.parseBodyFragment(value.html).select("img").array()
        XCTAssertEqual(images.count, 2)
        XCTAssertEqual(try images[0].attr("src"), "https://img.example.org/one.png")
    }
    func testSanitizerKeepsDialogueColorsRubyTablesAndLazyPictures() throws {
        let html = """
        <script>window.stolen=1</script><iframe src='https://bad.example'></iframe>
        <p onclick='steal()' style='text-align:right;color:#c00;position:fixed;background:url(https://bad.example)'>来信</p>
        <p style='border:1px solid black;border-radius:12px;background-color:#a0ce65'>你好<ruby>海<rt>hǎi</rt></ruby></p>
        <table><tr><td>表格</td></tr></table><img data-src='/cover.png' src='javascript:bad()' onerror='bad()'>
        """
        let result = try SourceChapterDocument.sanitized(html, baseURL: XCTUnwrap(URL(string: "https://example.org/book/")))
        let dom = try SwiftSoup.parseBodyFragment(result.html)
        XCTAssertTrue(try dom.select("script,iframe,[onclick],[onerror]").isEmpty())
        XCTAssertTrue(result.html.contains("text-align:right"))
        XCTAssertTrue(result.html.contains("background-color:#a0ce65"))
        XCTAssertFalse(result.html.contains("position:fixed"))
        XCTAssertFalse(result.html.contains("url("))
        XCTAssertEqual(try dom.select("ruby rt").text(), "hǎi")
        XCTAssertEqual(try dom.select("td").text(), "表格")
        XCTAssertEqual(try dom.select("img").attr("src"), "https://example.org/cover.png")
    }
    func testFailedAttemptsAreNeverReportedAsSuccessfulDownloads() {
        let progress = BatchCacheProgress(total: 89, completed: 89, failed: 22, isRunning: false)
        XCTAssertEqual(progress.succeeded, 67)
        XCTAssertEqual(progress.remaining, 0)
        XCTAssertTrue(progress.statusText.contains("成功 67/89"))
        XCTAssertTrue(progress.statusText.contains("失败 22"))
        XCTAssertFalse(progress.statusText.contains("已完整下载"))
    }
    @MainActor
    func testCachedRichChapterSurvivesReloadWithoutAnyNetworkRequest() async throws {
        let container = try ModelContainer(for: ChapterCacheRecord.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let chapter = BookChapter(title: "第一章", url: "https://example.org/unreachable", index: 0)
        let record = ChapterCacheRecord(sourceID: "rich-test", bookID: book().id, chapter: chapter, content: "你好", htmlContent: "<p style='color:red'>你好</p>")
        container.mainContext.insert(record); try container.mainContext.save()
        let context = ModelContext(container)
        let loaded = try await SourceChapterRepository(book: book(), chapters: [chapter], source: source(), context: context).load(0)
        XCTAssertEqual(loaded.html, "<p style='color:red'>你好</p>")
        XCTAssertEqual(loaded.text, "你好")
        XCTAssertNil(try context.fetch(FetchDescriptor<ChapterCacheRecord>()).first?.downloadError)
    }
    func testRichEPUBContainsOfflineImageAndDialogueMarkup() throws {
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a0ZkAAAAASUVORK5CYII=")!
        let data = try BookEPUBExporter.build(book: book(), chapters: [ExportBookChapter(title: "来信", content: "你好", html: "<p style='color:red;border-radius:12px'>你好</p><img src='images/one.png' />")],
            assets: [ExportBookAsset(path: "images/one.png", data: png, mediaType: "image/png")])
        let archive = try ZIPFoundation.Archive(data: data, accessMode: .read)
        func read(_ path: String) throws -> Data {
            var bytes = Data()
            _ = try archive.extract(XCTUnwrap(archive[path])) { bytes.append($0) }
            return bytes
        }
        XCTAssertEqual(try read("EPUB/images/one.png"), png)
        let opf = String(decoding: try read("EPUB/book.opf"), as: UTF8.self)
        XCTAssertTrue(opf.contains("images/one.png")); XCTAssertTrue(opf.contains("image/png"))
        let html = String(decoding: try read("EPUB/chapter0.xhtml"), as: UTF8.self)
        XCTAssertTrue(html.contains("color:red;border-radius:12px"))
        XCTAssertTrue(html.contains("src='images/one.png'"))
        XCTAssertThrowsError(try BookEPUBExporter.build(book: book(), chapters: [ExportBookChapter(title: "未下载", content: "")]))
    }
    func testImageResourceURLRoundTripsSignedURLAndRejectsLocalScheme() throws {
        let url = try XCTUnwrap(URL(string: "https://img.example.org/a.png?token=a%2Bb&size=900"))
        XCTAssertEqual(SourcePublicationContainer.imageURL(SourcePublicationContainer.imagePath(url)), url)
        let local = URL(fileURLWithPath: "/private/book")
        XCTAssertNil(SourcePublicationContainer.imageURL(SourcePublicationContainer.imagePath(local)))
    }
    func testReadingRulerClampsToScreenAndMaintainsOneLineHeight() {
        for fraction in [-2.0, 0, 0.22, 1, 4] {
            let frame = ReaderLineGuideGeometry.window(height: 800, lineHeight: 29, fraction: fraction)
            XCTAssertEqual(frame.height, 29)
            XCTAssertGreaterThanOrEqual(frame.minY, 0)
            XCTAssertLessThanOrEqual(frame.maxY, 800)
        }
    }
}
