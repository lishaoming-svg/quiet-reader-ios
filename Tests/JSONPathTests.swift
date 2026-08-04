import XCTest
@testable import QuietReader

final class JSONPathTests: XCTestCase {
    private let object: [String: Any] = [
        "results": [
            [
                "title": "第一本书",
                "authors": [["name": "作者甲"]],
                "formats": ["text/plain; charset=utf-8": "https://example.com/book.txt"]
            ],
            ["title": "第二本书"]
        ]
    ]

    func testWildcardList() throws {
        let values = try JSONPath.values(at: "$.results[*]", in: object)
        XCTAssertEqual(values.count, 2)
    }

    func testNestedIndex() throws {
        let first = try JSONPath.values(at: "$.results[0]", in: object)[0]
        XCTAssertEqual(try JSONPath.string(at: "$.authors[0].name", in: first), "作者甲")
    }

    func testQuotedKey() throws {
        let first = try JSONPath.values(at: "$.results[0]", in: object)[0]
        let value = try JSONPath.string(
            at: "$[\"formats\"][\"text/plain; charset=utf-8\"]",
            in: first
        )
        XCTAssertEqual(value, "https://example.com/book.txt")
    }
}
