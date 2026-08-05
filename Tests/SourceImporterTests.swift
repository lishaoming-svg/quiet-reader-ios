import XCTest
@testable import QuietReader

final class SourceImporterTests: XCTestCase {
    func testBundledSourcesContainFiveNoLoginCuratedSources() throws {
        let url = try XCTUnwrap(
            Bundle.main.url(forResource: "community-sources", withExtension: "json")
        )
        let data = try Data(contentsOf: url)
        let sources = try JSONDecoder().decode([BookSourceDefinition].self, from: data)

        XCTAssertEqual(sources.count, 5)
        XCTAssertEqual(
            Set(sources.map(\.id)),
            [
                "archive.0e12f30e88f0744dea7fc074",
                "archive.c1c2db7490999e4d53855df9",
                "archive.870ca07aea94fc8c54d0ef9e",
                "archive.a184d924d4a2bcfac86e52a8",
                "archive.1e94ef54501668df21018322"
            ]
        )
        XCTAssertTrue(sources.allSatisfy { $0.loginUrl?.nilIfBlank == nil })
        XCTAssertTrue(sources.allSatisfy(\.isEnabled))
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
