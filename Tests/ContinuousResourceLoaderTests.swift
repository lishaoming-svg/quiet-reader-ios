import Foundation
import ReadiumShared
import ReadiumStreamer
import WebKit
import XCTest
import ZIPFoundation
@testable import QuietReader

final class ContinuousResourceLoaderTests: XCTestCase {
    @MainActor func testImportedEPUBLoadsEncodedAssetAndDoesNotFailBookForMissingPicture() async throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "precision", withExtension: "epub", subdirectory: "Fixtures"))
        let archive = try Archive(data: Data(contentsOf: fixture), accessMode: .update)
        let picture = Data("encoded-resource-test".utf8)
        let filename = "OEBPS/Images/picture#100%.png"
        try archive.addEntry(with: filename, type: .file, uncompressedSize: Int64(picture.count)) { offset, count in
            picture.subdata(in: Int(offset)..<min(Int(offset) + count, picture.count))
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let imported = try LocalBookImporter.prepare(data: XCTUnwrap(archive.data), filename: "精排测试.epub", root: root)
        let file = try XCTUnwrap(FileURL(url: LocalBookStorage.publicationURL(for: imported.book.bookURL, root: root)))
        let asset = try await AssetRetriever(httpClient: DefaultHTTPClient()).retrieve(url: file).get()
        let publication = try await PublicationOpener(parser: EPUBParser()).open(asset: asset, allowUserInteraction: false).get()
        var failures: [String] = []
        let handler = PublicationSchemeHandler(publication: publication) { failures.append($0) }
        defer { handler.stopAll() }
        let encoded = ResourceTask(url: URL(string: "ibooks-stream://publication/OEBPS/Images/picture%23100%25.png")!, done: expectation(description: "编码图片读取完成"))
        handler.webView(WKWebView(), start: encoded)
        await fulfillment(of: [encoded.done], timeout: 15)
        XCTAssertNil(encoded.error); XCTAssertEqual(encoded.bytes, picture)
        let missing = ResourceTask(url: URL(string: "ibooks-stream://publication/OEBPS/Images/missing.png")!, done: expectation(description: "可选插图错误已局部处理"))
        handler.webView(WKWebView(), start: missing)
        await fulfillment(of: [missing.done], timeout: 15)
        XCTAssertNotNil(missing.error)
        XCTAssertTrue(failures.isEmpty, "插图缺失不能显示整本书丢失：\(failures)")
        XCTAssertNoThrow(try LocalBookStorage.publicationURL(for: imported.book.bookURL, root: root))
    }
    @MainActor func testMissingSpineStillReportsAnActionableReadingFailure() async throws {
        let source = try JSONDecoder().decode(BookSourceDefinition.self, from: Data(#"{"bookSourceUrl":"https://example.org","bookSourceName":"测试"}"#.utf8))
        let container = SourcePublicationContainer(chapters: [], source: source) { _ in SourceChapterDocument(text: "") }
        let publication = Publication(manifest: Manifest(metadata: Metadata(title: "测试"),
            readingOrder: [Link(href: "missing.xhtml", mediaType: .xhtml)]), container: container)
        var failures: [String] = []
        let handler = PublicationSchemeHandler(publication: publication) { failures.append($0) }
        defer { handler.stopAll() }
        let task = ResourceTask(url: URL(string: "ibooks-stream://publication/missing.xhtml")!, done: expectation(description: "正文缺失已报告"))
        handler.webView(WKWebView(), start: task)
        await fulfillment(of: [task.done], timeout: 15)
        XCTAssertNotNil(task.error); XCTAssertEqual(failures.count, 1)
        XCTAssertTrue(failures.first?.contains("重新加载本章") == true)
    }
}

private final class ResourceTask: NSObject, WKURLSchemeTask {
    let request: URLRequest
    let done: XCTestExpectation
    var bytes = Data()
    var error: Error?
    init(url: URL, done: XCTestExpectation) { request = URLRequest(url: url); self.done = done }
    func didReceive(_ response: URLResponse) {}
    func didReceive(_ data: Data) { bytes.append(data) }
    func didFinish() { done.fulfill() }
    func didFailWithError(_ error: Error) { self.error = error; done.fulfill() }
}
