import XCTest
@testable import QuietReader

final class ReadableContentFormatterTests: XCTestCase {
    func testPreservesBRSeparatedNovelParagraphs() {
        let html = """
        第一章 第一个人 (第1/3页)<br><br>
        &nbsp;&nbsp;&nbsp;&nbsp;黑暗的房间内。<br />
        <br />
        　　睁开眼睛的时候，他还以为自己依旧在梦境中。
        """

        XCTAssertEqual(
            ReadableContentFormatter.plainText(from: html),
            "第一章 第一个人 (第1/3页)\n黑暗的房间内。\n睁开眼睛的时候，他还以为自己依旧在梦境中。"
        )
    }

    func testPreservesBlockParagraphsAndRemovesPageNoise() {
        let html = """
        <div id="center_tip">最新网址：www.example.com</div>
        <p>第一段。</p><p>第二段，<strong>保留行内文字</strong>。</p>
        <script>read3()</script>
        """

        XCTAssertEqual(
            ReadableContentFormatter.plainText(from: html),
            "第一段。\n第二段，保留行内文字。"
        )
    }

    func testAppliesLegadoReplacementAfterParagraphExtraction() {
        let text = "第一章 第一个人 (第1/3页)\n第一段。\n（本章未完，请点击下一页继续阅读）\n欢迎广大书友光临阅读。"

        XCTAssertEqual(
            ReadableContentFormatter.removingMatches(
                in: text,
                rule: "##.*第[0-9]+/[0-9]+页.*|[（(]本章未完.*[）)]|欢迎广大书友.*"
            ),
            "第一段。"
        )
    }

    func testDetectsSparseLegacyCacheOnlyForAffectedBundledSources() {
        let flattened = String(repeating: "这是一段已经丢失换行的旧缓存正文。", count: 80)
        let formatted = (1...20).map { "第\($0)段正文。" }.joined(separator: "\n")

        XCTAssertTrue(
            ReadableContentFormatter.shouldRefreshLegacyCache(
                flattened,
                sourceID: "archive.0e12f30e88f0744dea7fc074"
            )
        )
        XCTAssertFalse(
            ReadableContentFormatter.shouldRefreshLegacyCache(
                formatted,
                sourceID: "archive.0e12f30e88f0744dea7fc074"
            )
        )
        XCTAssertFalse(
            ReadableContentFormatter.shouldRefreshLegacyCache(
                flattened,
                sourceID: "imported.custom"
            )
        )
    }
}
