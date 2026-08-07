import SwiftUI
import UIKit
import XCTest
@testable import QuietReader

final class ReaderModelsTests: XCTestCase {
    func testBlocksPreserveIncreasingLocatorsForLongContent() {
        let content = String(repeating: "山海之间有一座城。", count: 180) + "\n第二段"
        let blocks = ReaderDocumentBuilder.blocks(from: content, maximumUTF16Length: 120)

        XCTAssertGreaterThan(blocks.count, 2)
        XCTAssertEqual(blocks.first?.locatorOffset, 0)
        XCTAssertEqual(blocks.map(\.locatorOffset), blocks.map(\.locatorOffset).sorted())
        XCTAssertEqual(blocks.filter(\.isParagraphStart).count, 2)
        XCTAssertTrue(blocks.first?.isParagraphStart == true)
    }

    func testDisplayDocumentNormalizesChineseParagraphIndentAndMapsLocator() {
        let content = "  第一段。  \n\n　　第二段。"
        let document = ReaderDocumentBuilder.displayDocument(
            from: content,
            paragraphIndent: true
        )

        XCTAssertEqual(document.text, "　　第一段。\n　　第二段。")
        let displayedOffset = (document.text as NSString).range(of: "第二段").location
        let originalOffset = (content as NSString).range(of: "第二段").location
        XCTAssertEqual(
            document.locatorOffset(forDisplayedUTF16Offset: displayedOffset),
            originalOffset
        )
    }

    func testPaginatorProducesPagesAndMapsLocator() {
        let content = String(repeating: "这是用于验证分页与位置映射的正文。", count: 240)
        let document = ReaderDocumentBuilder.displayDocument(
            from: content,
            paragraphIndent: true
        )
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
        XCTAssertEqual(pages.first?.showsChapterTitle, true)
        XCTAssertFalse(pages.dropFirst().contains(where: \.showsChapterTitle))
        XCTAssertFalse(pages.map(\.text).joined().contains("第一章"))
        XCTAssertTrue(pages.map(\.text).joined().hasPrefix("　　"))
        XCTAssertEqual(pages.map(\.text).joined(), document.text)
        XCTAssertEqual(
            ReaderPaginator.pageIndex(for: pages.last?.locatorOffset ?? 0, in: pages),
            pages.count - 1
        )
    }

    func testPaginatorPreservesEveryCharacterAcrossPageBoundaries() {
        let content = [
            String(repeating: "长句跨过页面边界时每一个字都必须出现在下一页并继续完整显示，", count: 80),
            String(repeating: "第二段包含标点、数字123和复合字符👨‍👩‍👧‍👦，用于检查字符范围。", count: 65),
        ].joined(separator: "\n")
        let document = ReaderDocumentBuilder.displayDocument(
            from: content,
            paragraphIndent: true
        )
        let pages = ReaderPaginator.paginate(
            chapterTitle: "分页连续性",
            content: content,
            size: CGSize(width: 280, height: 420),
            fontSize: 19,
            lineSpacing: 9,
            usesSerif: true
        )

        XCTAssertGreaterThan(pages.count, 5)
        XCTAssertEqual(pages.map(\.text).joined(), document.text)
        XCTAssertEqual(
            (pages.map(\.text).joined() as NSString).length,
            (document.text as NSString).length
        )
    }

    @MainActor
    func testPaginatedTextFitsSwiftUIRenderingHeight() {
        let scenarios: [(size: CGSize, fontSize: CGFloat, lineSpacing: CGFloat, usesSerif: Bool)] = [
            (CGSize(width: 332, height: 520), 14, 4, false),
            (CGSize(width: 280, height: 420), 19, 9, true),
            (CGSize(width: 230, height: 350), 27, 14, true),
        ]

        for scenario in scenarios {
            let content = String(
                repeating: "最后一行必须完整显示，下一页从紧邻的后续文字继续。",
                count: 100
            )
            let document = ReaderDocumentBuilder.displayDocument(
                from: content,
                paragraphIndent: true
            )
            let pages = ReaderPaginator.paginate(
                chapterTitle: "分页高度",
                content: content,
                size: scenario.size,
                fontSize: scenario.fontSize,
                lineSpacing: scenario.lineSpacing,
                usesSerif: scenario.usesSerif
            )
            XCTAssertEqual(pages.map(\.text).joined(), document.text)

            for page in pages {
                let pageText = ReaderPageTextView(
                    text: page.text,
                    fontSize: scenario.fontSize,
                    lineSpacing: scenario.lineSpacing,
                    usesSerif: scenario.usesSerif,
                    textColor: .label
                )
                    .fixedSize(horizontal: false, vertical: true)
                let controller = UIHostingController(rootView: pageText)
                let measured = controller.sizeThatFits(
                    in: CGSize(width: scenario.size.width, height: 10_000)
                )
                let availableHeight = page.showsChapterTitle
                    ? scenario.size.height - ReaderTypography.chapterHeadingHeight
                    : scenario.size.height

                XCTAssertLessThanOrEqual(
                    measured.height,
                    availableHeight + 0.5,
                    "字号 \(scenario.fontSize) 的第 \(page.id + 1) 页正文高度超出可视区域"
                )
            }
        }
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
