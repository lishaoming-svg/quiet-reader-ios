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
}
