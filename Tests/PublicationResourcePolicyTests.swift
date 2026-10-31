import Foundation
import ReadiumShared
import XCTest
@testable import QuietReader

final class PublicationResourcePolicyTests: XCTestCase {
    func testEncodedArchiveNamesDoNotBecomeURLDelimiters() throws {
        for path in ["Text/chapter%231.xhtml", "Text/a%3Fb.xhtml", "Images/100%2520.png", "Text/%E6%B5%B7%20%E8%BE%B9.xhtml"] {
            let url = try XCTUnwrap(URL(string: "ibooks-stream://publication/" + path))
            XCTAssertEqual(PublicationResourcePolicy.href(for: url)?.string, path)
        }
        XCTAssertNil(PublicationResourcePolicy.href(for: URL(string: "https://example.org/book.xhtml")!))
    }
    func testMissingOptionalAssetsAreNotReportedAsMissingBooks() throws {
        let source = try JSONDecoder().decode(BookSourceDefinition.self, from: Data(#"{"bookSourceUrl":"https://example.org","bookSourceName":"测试"}"#.utf8))
        let container = SourcePublicationContainer(chapters: [], source: source) { _ in SourceChapterDocument(text: "") }
        let publication = Publication(manifest: Manifest(metadata: Metadata(title: "本地书"),
            readingOrder: [Link(href: "Text/chapter%231.xhtml", mediaType: .xhtml)]), container: container)
        for path in ["Images/missing.png", "fonts/missing.ttf", "style/missing.css", "favicon.ico"] {
            XCTAssertFalse(PublicationResourcePolicy.isReadingResource(URL(string: "ibooks-stream://publication/" + path)!, in: publication))
        }
        let chapter = URL(string: "ibooks-stream://publication/Text/chapter%231.xhtml")!
        XCTAssertTrue(PublicationResourcePolicy.isReadingResource(chapter, in: publication))
        XCTAssertTrue(PublicationResourcePolicy.readingFailure(chapter).contains("本章正文无法读取"))
        XCTAssertFalse(PublicationResourcePolicy.readingFailure(chapter).contains("文件已丢失"))
    }
}
