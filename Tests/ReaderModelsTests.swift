import SwiftUI
import UIKit
import XCTest
@testable import QuietReader

final class ReaderModelsTests: XCTestCase {
    func testResumeResolverPrefersChapterURLAndFallsBackToIndex() {
        let chapters = [
            BookChapter(title: "第一章", url: "https://example.test/1", index: 0),
            BookChapter(title: "第二章", url: "https://example.test/2", index: 1),
            BookChapter(title: "第三章", url: "https://example.test/3", index: 2),
        ]

        XCTAssertEqual(
            ReaderResumeResolver.chapterIndex(
                in: chapters,
                chapterURL: chapters[2].url,
                fallbackIndex: 0
            ),
            2
        )
        XCTAssertEqual(
            ReaderResumeResolver.chapterIndex(
                in: chapters,
                chapterURL: "https://example.test/missing",
                fallbackIndex: 1
            ),
            1
        )
    }

    func testReaderContentWidthProducesEqualSideMargins() {
        let containerWidths: [CGFloat] = [320, 390, 430, 768, 1_024]
        for containerWidth in containerWidths {
            for margin in ReaderMargin.allCases {
                let contentWidth = ReaderLayoutMetrics.contentWidth(
                    containerWidth: containerWidth,
                    margin: margin
                )
                let leading = (containerWidth - contentWidth) / 2
                let trailing = containerWidth - contentWidth - leading

                XCTAssertEqual(leading, trailing, accuracy: 0.001)
                XCTAssertGreaterThanOrEqual(leading, margin.horizontalPadding - 0.001)
                XCTAssertLessThanOrEqual(contentWidth, margin.maximumContentWidth)
            }
        }
    }

    func testPagedTextUsesJustifiedChineseLayout() {
        let attributes = ReaderPageTextStyle.attributes(
            fontSize: 24,
            lineSpacing: 10,
            usesSerif: true
        )
        let paragraphStyle = attributes[.paragraphStyle] as? NSParagraphStyle

        XCTAssertEqual(paragraphStyle?.alignment, .justified)
        XCTAssertEqual(paragraphStyle?.lineBreakMode, .byWordWrapping)
    }

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

    @MainActor
    func testChinesePunctuationDoesNotOccupyForbiddenLineEdges() {
        let canvas = ReaderPageTextCanvas()
        canvas.setAttributedText(
            ReaderPageTextStyle.attributedString(
                text: String(
                    repeating: "山窗听雨，灯下翻书。《旧城》里的人问：你还好吗？当然很好！",
                    count: 24
                ),
                fontSize: 19,
                lineSpacing: 9,
                usesSerif: true
            )
        )

        let widths = stride(from: CGFloat(86), through: CGFloat(190), by: CGFloat(7))
        for width in widths {
            let lines = canvas.renderedLines(for: width)
            XCTAssertGreaterThan(lines.count, 2)
            for line in lines {
                if let first = line.first {
                    XCTAssertFalse(
                        ReaderLineBreakRules.forbiddenLineStart.contains(first),
                        "宽度 \(width) 的行首出现禁排标点：\(line)"
                    )
                }
                if let last = line.last {
                    XCTAssertFalse(
                        ReaderLineBreakRules.forbiddenLineEnd.contains(last),
                        "宽度 \(width) 的行尾出现禁排标点：\(line)"
                    )
                }
            }
        }

        let pagedText = String(
            repeating: "长街尽头亮着灯，归人推开门。《旧城》里的故事还在继续！",
            count: 80
        )
        let pages = ReaderPaginator.paginate(
            chapterTitle: "标点分页",
            content: pagedText,
            size: CGSize(width: 180, height: 300),
            fontSize: 19,
            lineSpacing: 9,
            usesSerif: true
        )
        XCTAssertGreaterThan(pages.count, 2)
        for page in pages {
            let visible = page.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let first = visible.first {
                XCTAssertFalse(ReaderLineBreakRules.forbiddenLineStart.contains(first))
            }
            if let last = visible.last {
                XCTAssertFalse(ReaderLineBreakRules.forbiddenLineEnd.contains(last))
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
