import Combine
import Foundation
import ReadiumShared
import ReadiumStreamer
import ZIPFoundation
import SwiftData
import XCTest
@testable import QuietReader

final class EPUBImportTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
    private func bytes(_ name: String = "precision") throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "epub", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    func testEPUBMetadataSpineEncodedPathsAndOriginalStylesArePreserved() throws {
        let original = try bytes()
        let result = try LocalBookImporter.prepare(data: original, filename: "书籍.EPUB", root: root)
        XCTAssertEqual(result.book.name, "精排示例")
        XCTAssertEqual(result.book.author, "iBooks 示例")
        XCTAssertEqual(result.book.kind, "EPUB")
        XCTAssertEqual(result.chapters.map(\.title), ["海边的清晨", "灯下的书页"])
        XCTAssertTrue(try LocalBookStorage.content(at: result.chapters[1].url, root: root).contains("尚未读完"))
        let retained = try LocalBookStorage.publicationURL(for: result.book.bookURL, root: root)
        XCTAssertEqual(try Data(contentsOf: retained), original, "精排必须使用原始 EPUB，包括 CSS、字体、图片和锚点")
        try FileManager.default.removeItem(at: retained)
        _ = try LocalBookImporter.prepare(data: original, filename: "书籍.epub", root: root)
        XCTAssertEqual(try Data(contentsOf: retained), original)
    }

    func testReadiumOpensReflowableAndFixedLayoutWithNavigationAndLocators() async throws {
        for fixture in ["precision", "fixed-layout"] {
            let result = try LocalBookImporter.prepare(data: bytes(fixture), filename: "\(fixture).epub", root: root)
            let file = try XCTUnwrap(FileURL(url: LocalBookStorage.publicationURL(for: result.book.bookURL, root: root)))
            let retriever = AssetRetriever(httpClient: DefaultHTTPClient())
            let asset = try await retriever.retrieve(url: file).get()
            let publication = try await PublicationOpener(parser: EPUBParser()).open(asset: asset, allowUserInteraction: false).get()
            XCTAssertEqual(publication.readingOrder.count, 2)
            XCTAssertEqual(publication.tableOfContents.map(\.title), ["海边的清晨", "灯下的书页"])
            let positions = try await publication.positions().get()
            let locator = try XCTUnwrap(positions.last)
            XCTAssertEqual(try Locator(jsonString: locator.jsonString()), locator)
        }
    }

    func testEPUBResourcePathsCannotEscapeArchive() {
        for href in ["../../../outside.xhtml", "/private/outside.xhtml", "https://example.com/book", "%2e%2e/%2e%2e/outside"] {
            XCTAssertThrowsError(try EPUBDocumentParser.path(href, relativeTo: "OEBPS"))
        }
        XCTAssertEqual(try EPUBDocumentParser.path("../Text/chapter%201.xhtml#start", relativeTo: "OEBPS/Nav"), "OEBPS/Text/chapter 1.xhtml")
    }

    func testImageOnlyEPUBImportsWithoutPlainText() throws {
        let archive = try ZIPFoundation.Archive(data: bytes(), accessMode: .update)
        for entry in ["OEBPS/Text/chapter 1.xhtml", "OEBPS/Text/chapter2.xhtml"] {
            try archive.remove(try XCTUnwrap(archive[entry]))
            let body = Data("<html><head><title>插图</title></head><body><img src='../Images/cover.svg'/></body></html>".utf8)
            try archive.addEntry(with: entry, type: .file, uncompressedSize: Int64(body.count)) { position, size in
                body.subdata(in: Int(position)..<min(Int(position) + size, body.count))
            }
        }
        let result = try LocalBookImporter.prepare(data: XCTUnwrap(archive.data), filename: "画册.epub", root: root)
        XCTAssertEqual(result.chapters.count, 2)
        XCTAssertNoThrow(try LocalBookStorage.publicationURL(for: result.book.bookURL, root: root))
    }
}

@MainActor
final class DocumentImportFlowTests: XCTestCase {
    func testPickerDismissesBeforeResultsAndSelectedDocumentIsSaved() async throws {
        let container = try ModelContainer(for: BookRecord.self, ChapterListCacheRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("实际选取-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("第一章 文件\n真实选取回调进入导入队列并保存书库。".utf8).write(to: file)
        let coordinator = BookImportCoordinator()
        coordinator.showingPicker = true
        coordinator.pickedDocuments(.success([file]))
        XCTAssertFalse(coordinator.showingPicker)
        XCTAssertFalse(coordinator.showingResults, "文件选择器关闭前不能弹出结果页")
        coordinator.pickerDidDismiss(context: context)
        XCTAssertTrue(coordinator.showingResults)
        let finished = expectation(description: "导入完成")
        let observation = coordinator.$isImporting.filter { !$0 }.first().sink { _ in finished.fulfill() }
        await fulfillment(of: [finished], timeout: 20)
        observation.cancel()
        XCTAssertEqual(coordinator.results.count, 1)
        XCTAssertEqual(coordinator.results.first?.succeeded, true)
        let records = try context.fetch(FetchDescriptor<BookRecord>())
        XCTAssertEqual(records.count, 1)
        let record = try XCTUnwrap(records.first)
        defer { try? LocalBookStorage.remove(address: record.bookURL) }
        let directory = try LocalBookStorage.book(at: record.bookURL)
        XCTAssertTrue(try LocalBookStorage.content(at: directory.chapters[0].url).contains("真实选取回调"))
    }

    func testCancellingPickerDoesNotPresentResultsOrWriteLibrary() throws {
        let container = try ModelContainer(for: BookRecord.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let coordinator = BookImportCoordinator()
        coordinator.showingPicker = true
        coordinator.pickedDocuments(.success([]))
        coordinator.pickerDidDismiss(context: container.mainContext)
        XCTAssertFalse(coordinator.showingResults)
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<BookRecord>()), 0)
    }
}
