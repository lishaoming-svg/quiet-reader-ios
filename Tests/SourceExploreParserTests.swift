import XCTest
@testable import QuietReader

final class SourceExploreParserTests: XCTestCase {
    func testParsesNewlineAndAmpersandCategories() {
        let categories = SourceExploreParser.categories(
            from: "热门::/top/{{page}}\n都市::/city/{{page}}&&科幻::/sci-fi/{{page}}"
        )

        XCTAssertEqual(categories.map(\.title), ["热门", "都市", "科幻"])
        XCTAssertEqual(categories[2].address, "/sci-fi/{{page}}")
    }

    func testParsesJSONAndSkipsSectionHeaders() {
        let categories = SourceExploreParser.categories(
            from: #"[{"title":"排行榜","url":""},{"title":"月榜","url":"/month/{{page}}",}]"#
        )

        XCTAssertEqual(categories, [
            SourceExploreCategory(title: "月榜", address: "/month/{{page}}")
        ])
    }

    func testRemovesDuplicateCategories() {
        let categories = SourceExploreParser.categories(from: "热门::/top\n热门::/top")

        XCTAssertEqual(categories.count, 1)
    }
}
