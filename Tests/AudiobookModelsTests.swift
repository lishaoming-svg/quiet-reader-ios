import Foundation
import XCTest
@testable import QuietReader

final class AudiobookModelsTests: XCTestCase {
    func testNarrationNormalizationMatchesWindowsProtocol() {
        let value = " 第一段。 \r\n\r\n 第二段。 \n   \n第三段。"
        XCTAssertEqual(
            AudiobookTextNormalizer.normalize(value),
            "第一段。\n第二段。\n第三段。"
        )
    }

    func testPairingCodeRoundTripsWithoutLosingToken() throws {
        let original = try XCTUnwrap(
            AudiobookPairingConfiguration(
                baseURLString: "http://192.168.1.20:8765/",
                token: "a-secure-pairing-token"
            )
        )
        let parsed = try XCTUnwrap(
            AudiobookPairingConfiguration(pairingCode: original.pairingCode)
        )
        XCTAssertEqual(parsed, original)
        XCTAssertEqual(parsed.baseURL.absoluteString, "http://192.168.1.20:8765")
    }

    func testChapterIdentifierIsStableAndFilesystemSafe() {
        let first = AudiobookIdentifier.chapterID(for: "https://example.test/book/第一章?id=1")
        let second = AudiobookIdentifier.chapterID(for: "https://example.test/book/第一章?id=1")
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.count, 32)
        XCTAssertNotNil(first.range(of: "^[0-9a-f]{32}$", options: .regularExpression))
    }

    func testJobRequestUsesNormalizedTextHash() {
        let book = SearchBook(
            sourceID: "source",
            sourceName: "测试源",
            name: "测试书",
            author: "作者",
            intro: "",
            kind: "",
            lastChapter: "",
            updateTime: "",
            bookURL: "https://example.test/book",
            coverURL: "",
            tocURL: ""
        )
        let chapter = BookChapter(
            title: "第一章",
            url: "https://example.test/chapter/1",
            index: 0
        )
        let request = AudiobookJobRequest(
            book: book,
            chapter: chapter,
            text: " 正文。 \r\n\r\n 第二段。 ",
            voice: "default",
            speed: 1
        )
        XCTAssertEqual(request.text, "正文。\n第二段。")
        XCTAssertEqual(request.textSHA256, AudiobookIdentifier.sha256(request.text))
    }
}
