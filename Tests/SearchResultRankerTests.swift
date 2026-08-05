import XCTest
@testable import QuietReader

final class SearchResultRankerTests: XCTestCase {
    func testExactMatchesLeadAndPromotionsAreRemoved() {
        let books = [
            book(name: "（书名 @vip）打赏后获取更多搜索资源，谢谢支持！"),
            book(name: "诡域"),
            book(name: "异悚乐园"),
            book(name: "异悚"),
            book(name: "诡异悚事")
        ]

        let ranked = SearchResultRanker.rank(books, keyword: "异悚")

        XCTAssertEqual(ranked.map(\.name), ["异悚", "异悚乐园", "诡异悚事", "诡域"])
        XCTAssertFalse(ranked.contains { $0.name.contains("打赏") })
    }

    func testExactAuthorMatchIsRelevant() {
        let books = [book(name: "普通书籍"), book(name: "地狱公寓", author: "黑色火种")]

        XCTAssertEqual(
            SearchResultRanker.rank(books, keyword: "黑色火种").first?.name,
            "地狱公寓"
        )
    }

    private func book(name: String, author: String = "") -> SearchBook {
        SearchBook(
            sourceID: "test",
            sourceName: "测试源",
            name: name,
            author: author,
            intro: "",
            kind: "",
            lastChapter: "",
            updateTime: "",
            bookURL: "https://example.com/\(name)",
            coverURL: "",
            tocURL: ""
        )
    }
}
