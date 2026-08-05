import XCTest
@testable import QuietReader

final class DalanglangLiveIntegrationTests: XCTestCase {
    func testLiveSearchDetailCatalogAndFirstChapter() async throws {
        let sourceURL = try XCTUnwrap(
            Bundle.main.url(forResource: "community-sources", withExtension: "json")
        )
        let sourceData = try Data(contentsOf: sourceURL)
        let sources = try JSONDecoder().decode([BookSourceDefinition].self, from: sourceData)
        let source = try XCTUnwrap(
            sources.first { $0.sourceId == "cf.langge.novel.quiet-reader" }
        )
        let engine = SourceEngine()

        let books = try await engine.search(keyword: "三体", source: source)
        let book = try XCTUnwrap(books.first)
        XCTAssertFalse(book.name.isEmpty)
        XCTAssertTrue(book.bookURL.hasPrefix("https://api.langge.cf/detail?book_id="))

        let detailedBook = try await engine.loadDetails(book: book, source: source)
        XCTAssertFalse(detailedBook.author.isEmpty)
        XCTAssertTrue(detailedBook.tocURL.hasPrefix("https://api.langge.cf/catalog?book_id="))

        let chapters = try await engine.loadChapters(book: detailedBook, source: source)
        let firstChapter = try XCTUnwrap(chapters.first)
        XCTAssertTrue(firstChapter.url.contains("/content?version=4.6.29&item_id="))

        let content = try await engine.loadContent(chapter: firstChapter, source: source)
        XCTAssertGreaterThan(content.count, 200)
        XCTAssertFalse(content.contains("免登录访问次数已达上限"))
        XCTAssertFalse(content.contains("书源版本过低"))

        print(
            "LIVE_SOURCE_OK books=\(books.count) chapters=\(chapters.count) "
                + "contentCharacters=\(content.count)"
        )
    }
}
