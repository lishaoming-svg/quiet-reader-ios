import XCTest
@testable import QuietReader

final class RuleExtractorTests: XCTestCase {
    func testCSSExtractionAndRelativeURL() throws {
        let html = """
        <html><body>
          <article class="book"><h2>???</h2><a href="/book/1">??</a></article>
        </body></html>
        """
        let resource = FetchedResource(
            data: Data(html.utf8),
            finalURL: URL(string: "https://example.com/search")!,
            contentType: "text/html; charset=utf-8"
        )
        let extractor = RuleExtractor()
        let root = try extractor.root(from: resource)
        let node = try XCTUnwrap(extractor.list("article.book", in: root).first)

        XCTAssertEqual(try extractor.string("h2@text", in: node), "???")
        XCTAssertEqual(
            try extractor.string("a@href", in: node, asURL: true),
            "https://example.com/book/1"
        )
    }

    func testRegexReplacement() throws {
        let html = "<p class='intro'>????????</p>"
        let resource = FetchedResource(
            data: Data(html.utf8),
            finalURL: URL(string: "https://example.com")!,
            contentType: "text/html"
        )
        let root = try RuleExtractor().root(from: resource)
        XCTAssertEqual(
            try RuleExtractor().string(".intro@text##^???##", in: root),
            "?????"
        )
    }

    func testLegadoCSSChainAndCurrentNodeAttributes() throws {
        let html = """
        <ul class="book-list">
          <li><a href="/book/1">???</a></li>
          <li><a href="/book/2">???</a></li>
        </ul>
        """
        let resource = FetchedResource(
            data: Data(html.utf8),
            finalURL: URL(string: "https://example.com/search")!,
            contentType: "text/html"
        )
        let extractor = RuleExtractor()
        let root = try extractor.root(from: resource)
        let nodes = try extractor.list("class.book-list@tag.li", in: root)

        XCTAssertEqual(nodes.count, 2)
        XCTAssertEqual(try extractor.string("tag.a@text", in: nodes[0]), "???")
        XCTAssertEqual(
            try extractor.string("tag.a@href", in: nodes[0], asURL: true),
            "https://example.com/book/1"
        )
        XCTAssertEqual(try extractor.string("a.1@text", in: root), "???")
    }

    func testCSSPrefix() throws {
        let html = "<div class='chapter-card'><h3>???</h3></div>"
        let resource = FetchedResource(
            data: Data(html.utf8),
            finalURL: URL(string: "https://example.com")!,
            contentType: "text/html"
        )
        let extractor = RuleExtractor()
        let root = try extractor.root(from: resource)
        let node = try XCTUnwrap(extractor.list("@css:div.chapter-card", in: root).first)
        XCTAssertEqual(try extractor.string("@css:h3@text", in: node), "???")
    }

}
