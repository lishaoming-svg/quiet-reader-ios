import XCTest
@testable import QuietReader

final class ReaderModelsTests: XCTestCase {
    func testBlocksPreserveIncreasingLocatorsForLongContent() {
        let content = String(repeating: "山海之间有一座城。", count: 180) + "\n第二段"
        let blocks = ReaderDocumentBuilder.blocks(from: content, maximumUTF16Length: 120)

        XCTAssertGreaterThan(blocks.count, 2)
        XCTAssertEqual(blocks.first?.locatorOffset, 0)
        XCTAssertEqual(blocks.map(\.locatorOffset), blocks.map(\.locatorOffset).sorted())
    }

    func testPaginatorProducesPagesAndMapsLocator() {
        let content = String(repeating: "这是用于验证分页与位置映射的正文。", count: 240)
        let pages = ReaderPaginator.paginate(
            chapterTitle: "第一章",
            content: content,
            size: CGSize(width: 280, height: 420),
            fontSize: 19,
            lineSpacing: 8,
            usesSerif: true
        )

        XCTAssertGreaterThan(pages.count, 1)
        XCTAssertEqual(pages.first?.locatorOffset, 0)
        XCTAssertEqual(
            ReaderPaginator.pageIndex(for: pages.last?.locatorOffset ?? 0, in: pages),
            pages.count - 1
        )
    }

    func testExcerptStartsNearLocator() {
        let content = "第一段。\n第二段需要作为书签摘要。"
        let offset = ("第一段。\n" as NSString).length
        XCTAssertTrue(
            ReaderDocumentBuilder.excerpt(from: content, locatorOffset: offset)
                .hasPrefix("第二段")
        )
    }
}
