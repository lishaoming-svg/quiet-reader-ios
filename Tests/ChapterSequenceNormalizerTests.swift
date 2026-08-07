import XCTest
@testable import QuietReader

final class ChapterSequenceNormalizerTests: XCTestCase {
    func testKeepsLastOccurrenceWhenLatestSectionPrecedesMainDirectory() {
        let chapters = [
            BookChapter(title: "最终章（最新区域）", url: "https://example.com/3", index: 0),
            BookChapter(title: "第一章", url: "https://example.com/1", index: 1),
            BookChapter(title: "第二章", url: "https://example.com/2", index: 2),
            BookChapter(title: "最终章", url: "https://example.com/3", index: 3),
        ]

        let normalized = ChapterSequenceNormalizer.normalize(chapters)

        XCTAssertEqual(normalized.map(\.title), ["第一章", "第二章", "最终章"])
        XCTAssertEqual(normalized.map(\.index), [0, 1, 2])
    }

    func testPreservesVolumeOrderWhenChapterNumbersRestart() {
        let chapters = [
            BookChapter(title: "第一卷 第一章", url: "https://example.com/1", index: 0),
            BookChapter(title: "第一卷 第二章", url: "https://example.com/2", index: 1),
            BookChapter(title: "第二卷 第一章", url: "https://example.com/3", index: 2),
        ]

        let normalized = ChapterSequenceNormalizer.normalize(chapters)

        XCTAssertEqual(normalized.map(\.title), chapters.map(\.title))
        XCTAssertEqual(normalized.map(\.index), [0, 1, 2])
    }
}
