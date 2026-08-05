import XCTest
@testable import QuietReader

final class SourceImporterTests: XCTestCase {
    func testBundledSourcesIncludeCompatibleDalanglangNovelSource() throws {
        let url = try XCTUnwrap(
            Bundle.main.url(forResource: "community-sources", withExtension: "json")
        )
        let data = try Data(contentsOf: url)
        let sources = try JSONDecoder().decode([BookSourceDefinition].self, from: data)
        let source = try XCTUnwrap(
            sources.first { $0.sourceId == "cf.langge.novel.quiet-reader" }
        )

        XCTAssertEqual(source.bookSourceUrl, "https://api.langge.cf")
        XCTAssertEqual(source.ruleSearch?.bookList, "$.data[*]")
        XCTAssertEqual(
            source.ruleSearch?.bookUrl,
            "/detail?book_id={{$.book_id}}&source={{$.source}}&tab={{$.tab}}"
        )
        XCTAssertEqual(
            source.ruleToc?.chapterUrl,
            "/content?item_id={{$.item_id}}&source={{$.source}}"
                + "&tab={{$.tab}}&version=4.6.29"
        )
        XCTAssertEqual(source.ruleContent?.content, "$.content")
    }

    func testDecodesSingleSourceObject() throws {
        let data = Data(
            """
            {
              "sourceId": "demo",
              "bookSourceUrl": "https://example.com",
              "bookSourceName": "示例",
              "searchUrl": "https://example.com/search?q={{key}}",
              "ruleSearch": {"bookList": ".book"}
            }
            """.utf8
        )

        let result = try SourceImporter().decodeSources(data)

        XCTAssertEqual(result.sources.count, 1)
        XCTAssertEqual(result.sources[0].id, "demo")
        XCTAssertEqual(result.sources[0].bookSourceName, "示例")
    }

    func testDeduplicatesByStableIdentifier() throws {
        let data = Data(
            """
            [
              {"sourceId":"same","bookSourceUrl":"https://one.example.com","bookSourceName":"旧"},
              {"sourceId":"same","bookSourceUrl":"https://two.example.com","bookSourceName":"新"}
            ]
            """.utf8
        )

        let result = try SourceImporter().decodeSources(data)

        XCTAssertEqual(result.sources.count, 1)
        XCTAssertEqual(result.sources[0].bookSourceName, "新")
        XCTAssertFalse(result.warnings.isEmpty)
    }

    func testRejectsUnsupportedScheme() throws {
        let data = Data(
            """
            [{"bookSourceUrl":"file:///tmp/source","bookSourceName":"本地"}]
            """.utf8
        )

        XCTAssertThrowsError(try SourceImporter().decodeSources(data))
    }

    func testDecodesRuleStoredAsJSONString() throws {
        let data = Data(
            #"{"bookSourceUrl":"https://example.com","bookSourceName":"兼容源","ruleSearch":"{\"bookList\":\".book\",\"name\":\"h2@text\"}"}"#.utf8
        )

        let result = try SourceImporter().decodeSources(data)

        XCTAssertEqual(result.sources[0].ruleSearch?.bookList, ".book")
        XCTAssertEqual(result.sources[0].ruleSearch?.name, "h2@text")
    }
}
