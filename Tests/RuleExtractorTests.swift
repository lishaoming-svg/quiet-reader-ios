import XCTest
@testable import QuietReader

final class RuleExtractorTests: XCTestCase {
    func testCSSExtractionAndRelativeURL() throws {
        let html = """
        <html><body>
          <article class="book"><h2>山海经</h2><a href="/book/1">阅读</a></article>
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

        XCTAssertEqual(try extractor.string("h2@text", in: node), "山海经")
        XCTAssertEqual(
            try extractor.string("a@href", in: node, asURL: true),
            "https://example.com/book/1"
        )
    }

    func testRegexReplacement() throws {
        let html = "<p class='intro'>简介：一部公版书</p>"
        let resource = FetchedResource(
            data: Data(html.utf8),
            finalURL: URL(string: "https://example.com")!,
            contentType: "text/html"
        )
        let root = try RuleExtractor().root(from: resource)
        XCTAssertEqual(
            try RuleExtractor().string(".intro@text##^简介：##", in: root),
            "一部公版书"
        )
    }

    func testLegadoCSSChainAndCurrentNodeAttributes() throws {
        let html = """
        <ul class="book-list">
          <li><a href="/book/1">第一本</a></li>
          <li><a href="/book/2">第二本</a></li>
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
        XCTAssertEqual(try extractor.string("tag.a@text", in: nodes[0]), "第一本")
        XCTAssertEqual(
            try extractor.string("tag.a@href", in: nodes[0], asURL: true),
            "https://example.com/book/1"
        )
        XCTAssertEqual(try extractor.string("a.1@text", in: root), "第二本")
    }

    func testCSSPrefix() throws {
        let html = "<div class='chapter-card'><h3>第一章</h3></div>"
        let resource = FetchedResource(
            data: Data(html.utf8),
            finalURL: URL(string: "https://example.com")!,
            contentType: "text/html"
        )
        let extractor = RuleExtractor()
        let root = try extractor.root(from: resource)
        let node = try XCTUnwrap(extractor.list("@css:div.chapter-card", in: root).first)
        XCTAssertEqual(try extractor.string("@css:h3@text", in: node), "第一章")
    }

    func testPaginationAndFollowingSiblingSelectors() throws {
        let html = """
        <div class="listpage"><a href="/toc/2">下一页</a></div>
        <div class="section-opt"><a href="/chapter/1_2">下一页</a></div>
        <div class="box_con">
          <dl>
            <dd><a href="/latest">最新章节</a></dd>
            <dt>正文</dt>
            <dd><a href="/one">第一章</a></dd>
            <dd><a href="/two">第二章</a></dd>
          </dl>
        </div>
        """
        let resource = FetchedResource(
            data: Data(html.utf8),
            finalURL: URL(string: "https://example.com/book/")!,
            contentType: "text/html"
        )
        let extractor = RuleExtractor()
        let root = try extractor.root(from: resource)

        XCTAssertEqual(
            try extractor.string(
                ".listpage a:containsOwn(下一页)@href",
                in: root,
                asURL: true
            ),
            "https://example.com/toc/2"
        )
        XCTAssertEqual(
            try extractor.string(
                ".section-opt a:containsOwn(下一页)@href",
                in: root,
                asURL: true
            ),
            "https://example.com/chapter/1_2"
        )
        let chapters = try extractor.list(
            ".box_con dt:containsOwn(正文) ~ dd a",
            in: root
        )
        XCTAssertEqual(chapters.count, 2)
        XCTAssertEqual(try extractor.string("text", in: chapters[0]), "第一章")
    }

    func testSelectsMainDirectoryWithoutLatestChapterSection() throws {
        let html = """
        <div class="row-section">
          <h2>《山海录》最新章节</h2>
          <div class="section-box">
            <ul class="section-list"><li><a href="/last">最终章</a></li></ul>
          </div>
          <h2>《山海录》正文</h2>
          <div class="section-box">
            <ul class="section-list">
              <li><a href="/one">第一章</a></li>
              <li><a href="/two">第二章</a></li>
            </ul>
          </div>
        </div>
        """
        let resource = FetchedResource(
            data: Data(html.utf8),
            finalURL: URL(string: "https://example.com/book/")!,
            contentType: "text/html"
        )
        let extractor = RuleExtractor()
        let root = try extractor.root(from: resource)
        let chapters = try extractor.list(
            ".row-section h2:containsOwn(正文) + .section-box .section-list li a",
            in: root
        )

        XCTAssertEqual(chapters.count, 2)
        XCTAssertEqual(try extractor.string("text", in: chapters[0]), "第一章")
        XCTAssertEqual(try extractor.string("text", in: chapters[1]), "第二章")
    }

}
