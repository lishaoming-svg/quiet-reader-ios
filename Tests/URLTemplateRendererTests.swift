import XCTest
@testable import QuietReader

final class URLTemplateRendererTests: XCTestCase {
    func testRendersEncodedKeywordAndPage() throws {
        let url = try URLTemplateRenderer.render(
            "https://example.com/search?q={{key}}&page={{page}}",
            keyword: "山 海",
            page: 2
        )
        XCTAssertEqual(url.absoluteString, "https://example.com/search?q=%E5%B1%B1%20%E6%B5%B7&page=2")
    }

    func testRendersRelativeLegadoURL() throws {
        let url = try URLTemplateRenderer.render(
            "/books?q={{key}}&page={{page}}",
            keyword: "山海",
            page: 3,
            relativeTo: "https://example.com/home"
        )
        XCTAssertEqual(
            url.absoluteString,
            "https://example.com/books?q=%E5%B1%B1%E6%B5%B7&page=3"
        )
    }

    func testRendersPageOffsetVariables() throws {
        let url = try URLTemplateRenderer.render(
            "https://example.com/{{page-1}}/{{page}}/{{page+1}}",
            page: 3
        )
        XCTAssertEqual(url.absoluteString, "https://example.com/2/3/4")
    }
}
