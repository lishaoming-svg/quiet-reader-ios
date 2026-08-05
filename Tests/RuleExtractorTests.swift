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

    func testDalanglangJSONRulesBuildCompatibleURLs() throws {
        let json = """
        {
          "data": [
            {
              "book_name": "测试小说",
              "book_id": "book-100",
              "item_id": "chapter-200",
              "source": "猫眼",
              "tab": "小说",
              "tags": "悬疑"
            }
          ]
        }
        """
        let resource = FetchedResource(
            data: Data(json.utf8),
            finalURL: URL(string: "https://api.langge.cf/search")!,
            contentType: "application/json; charset=utf-8"
        )
        let extractor = RuleExtractor()
        let root = try extractor.root(from: resource)
        let node = try XCTUnwrap(extractor.list("$.data[*]", in: root).first)

        XCTAssertEqual(try extractor.string("$.book_name", in: node), "测试小说")
        XCTAssertEqual(
            try extractor.string("{{$.source}} {{$.tags}}", in: node),
            "猫眼 悬疑"
        )
        try assertURL(
            extractor.string(
                "/detail?book_id={{$.book_id}}&source={{$.source}}&tab={{$.tab}}",
                in: node,
                asURL: true
            ),
            path: "/detail",
            query: ["book_id": "book-100", "source": "猫眼", "tab": "小说"]
        )
        try assertURL(
            extractor.string(
                "/content?item_id={{$.item_id}}&source={{$.source}}"
                    + "&tab={{$.tab}}&version=4.6.29",
                in: node,
                asURL: true
            ),
            path: "/content",
            query: [
                "item_id": "chapter-200",
                "source": "猫眼",
                "tab": "小说",
                "version": "4.6.29"
            ]
        )
    }

    private func assertURL(
        _ value: String,
        path: String,
        query expectedQuery: [String: String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let components = try XCTUnwrap(URLComponents(string: value), file: file, line: line)
        XCTAssertEqual(components.host, "api.langge.cf", file: file, line: line)
        XCTAssertEqual(components.path, path, file: file, line: line)
        let query = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") }
        )
        XCTAssertEqual(query, expectedQuery, file: file, line: line)
    }
}
