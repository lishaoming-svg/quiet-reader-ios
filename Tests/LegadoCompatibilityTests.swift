import XCTest
@testable import QuietReader

final class LegadoCompatibilityTests: XCTestCase {
    func testDeclarativePostRequestGBKEncodingAndArithmeticPagination() throws {
        let url = try URLTemplateRenderer.render(#"/search,{"method":"POST","body":"q={{key}}&offset={{(page-1)*20}}","headers":{"X-Test":"yes"},"charset":"gbk"}"#,
            keyword: "中文", page: 3, relativeTo: "https://example.org")
        let request = try LegadoRequest.parse(url)
        XCTAssertEqual(request.url.absoluteString, "https://example.org/search")
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(String(decoding: try XCTUnwrap(request.body), as: UTF8.self), "q=%D6%D0%CE%C4&offset=40")
        XCTAssertEqual(request.headers["X-Test"], "yes")
    }
    func testRejectsScriptExpressionsWebViewAndInvalidArithmetic() throws {
        for value in ["page/0", "999999999999999999999*20", "java.get(1)", "(page+2"] {
            XCTAssertThrowsError(try URLTemplateRenderer.render("https://example.org/{{\(value)}}"))
        }
        XCTAssertThrowsError(try URLTemplateRenderer.render(#"https://example.org,{"webView":true}"#))
        XCTAssertThrowsError(try URLTemplateRenderer.render("file:///private/book"))
        let url = try URLTemplateRenderer.render(#"https://example.org,{"method":"DELETE"}"#)
        XCTAssertThrowsError(try LegadoRequest.parse(url))
    }
    func testLegacyCSSStepIndexAndBasicXPathWorkOnSameHTML() throws {
        let html = "<div class='books'><a href='/one'>甲</a></div><div class='books featured'><a href='/two'>乙</a><a href='/three'>丙</a></div>"
        let extractor = RuleExtractor()
        let root = try extractor.root(from: FetchedResource(data: Data(html.utf8), finalURL: XCTUnwrap(URL(string: "https://example.org")), contentType: "text/html"))
        XCTAssertEqual(try extractor.string("class.books.1@tag.a.0@text", in: root), "乙")
        XCTAssertEqual(try extractor.string("@xpath://div[contains(@class,'featured')]/a[2]/text()", in: root), "丙")
        XCTAssertEqual(try extractor.string("@xpath://div[@class='books']/a/@href", in: root, asURL: true), "https://example.org/one")
        XCTAssertEqual(try extractor.string(".missing@text||a@text", in: root), "甲")
        XCTAssertEqual(try extractor.list("-a", in: root).count, 3)
        XCTAssertThrowsError(try extractor.string("@js:java.ajax('x')", in: root))
        XCTAssertThrowsError(try extractor.list("@xpath://div[unsupported()]", in: root))
    }
    func testJSONPathRecursiveSlicesUnionsAndNegativeIndex() throws {
        let root: [String: Any] = ["items": [["name":"甲"], ["name":"乙"], ["name":"丙"]]]
        XCTAssertEqual(try JSONPath.string(at: "@json:$.items[-1].name", in: root), "丙")
        XCTAssertEqual(try JSONPath.string(at: "$.items[0:2].name", in: root), "甲、乙")
        XCTAssertEqual(try JSONPath.string(at: "$.items[0,2].name", in: root), "甲、丙")
        XCTAssertEqual(try JSONPath.string(at: "$..name", in: root), "甲、乙、丙")
        XCTAssertThrowsError(try JSONPath.values(at: "$.items[?(@.name)]", in: root))
    }
    func testMixedSourceArrayPreservesValidRowsAndDisabledFlags() throws {
        let data = Data(#"[{"bookSourceName":"兼容源","bookSourceUrl":"https://example.org","enabled":"false","enabledExplore":0,"bookSourceType":"0","header":{"Referer":"https://example.org"}},42,{"bookSourceName":"错误标记","bookSourceUrl":"https://example.net","enabled":"maybe"}]"#.utf8)
        let result = try SourceImporter().decodeSources(data)
        XCTAssertEqual(result.sources.count, 1)
        XCTAssertFalse(result.sources[0].isEnabled)
        XCTAssertEqual(result.sources[0].enabledExplore, false)
        XCTAssertTrue(result.sources[0].header?.contains("Referer") == true)
        XCTAssertFalse(result.warnings.isEmpty)
    }
}
