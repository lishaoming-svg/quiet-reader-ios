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

    func testBatchRequestEncodesAllJobsInOneEnvelope() throws {
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
        let jobs = (0..<3).map { index in
            AudiobookJobRequest(
                book: book,
                chapter: BookChapter(
                    title: "第\(index + 1)章",
                    url: "https://example.test/chapter/\(index + 1)",
                    index: index
                ),
                text: "第\(index + 1)章正文。",
                voice: "multi-role",
                speed: 1
            )
        }

        let data = try JSONEncoder().encode(AudiobookBatchJobRequest(jobs: jobs))
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(payload["protocol_version"] as? Int, 4)
        XCTAssertEqual((payload["jobs"] as? [[String: Any]])?.count, 3)
    }

    func testPlaybackQueueKeepsThreeReadableChaptersAhead() {
        let chapters = [
            BookChapter(title: "第一章", url: "chapter-1", index: 0),
            BookChapter(title: "第二卷", url: "volume-2", index: 1, isVolume: true),
            BookChapter(title: "第二章", url: "chapter-2", index: 2),
            BookChapter(title: "第三章", url: "chapter-3", index: 3),
            BookChapter(title: "第四章", url: "chapter-4", index: 4),
            BookChapter(title: "第五章", url: "chapter-5", index: 5)
        ]

        XCTAssertEqual(
            AudiobookQueuePlanner.targetIndices(chapters: chapters, currentIndex: 0),
            [0, 2, 3, 4]
        )
        XCTAssertEqual(
            AudiobookQueuePlanner.targetIndices(chapters: chapters, currentIndex: 4),
            [4, 5]
        )
        XCTAssertEqual(
            AudiobookQueuePlanner.unreadIndices(chapters: chapters, currentIndex: 2),
            [2, 3, 4, 5]
        )
        XCTAssertEqual(
            AudiobookQueuePlanner.unreadIndices(chapters: chapters, currentIndex: 1),
            [2, 3, 4, 5]
        )
    }

    func testTimelineResolverMovesAcrossRoleSegments() {
        let timeline = [
            AudiobookTimedSegment(
                text: "夜色渐深。",
                role: "narrator",
                startTime: 0,
                endTime: 2.5,
                startOffset: 0,
                endOffset: 6
            ),
            AudiobookTimedSegment(
                text: "“我们走。”",
                role: "protagonist",
                startTime: 2.5,
                endTime: 4.8,
                startOffset: 6,
                endOffset: 12
            )
        ]

        XCTAssertEqual(AudiobookTimelineResolver.segment(at: 0.5, in: timeline)?.role, "narrator")
        XCTAssertEqual(AudiobookTimelineResolver.segment(at: 3, in: timeline)?.role, "protagonist")
        XCTAssertEqual(AudiobookTimelineResolver.segment(at: 8, in: timeline)?.startOffset, 6)
    }

    func testJobStatusDecodesMultiRoleTimeline() throws {
        let data = Data(
            """
            {
              "protocol_version": 4,
              "job_id": "job",
              "status": "completed",
              "progress": 1,
              "completed_segments": 1,
              "total_segments": 1,
              "error": null,
              "file_size": 1000,
              "chapter_index": 0,
              "chapter_id": "chapter",
              "chapter_url": "https://example.test/chapter/1",
              "chapter_title": "第一章",
              "audio_path": "/audio",
              "segments": [{
                "text": "你好。",
                "role": "female",
                "start_time": 0,
                "end_time": 1.2,
                "start_offset": 0,
                "end_offset": 3
              }]
            }
            """.utf8
        )
        let status = try JSONDecoder().decode(AudiobookJobStatus.self, from: data)
        XCTAssertEqual(status.segments?.first?.roleName, "女性角色")
        XCTAssertEqual(status.segments?.first?.endOffset, 3)
    }

    func testReadaloudPackageValidatorRequiresContinuousCompleteTimeline() throws {
        let text = "第一段。\n第二段。"
        let chapterURL = "https://example.test/chapter/1"
        let chapter = AudiobookPackageChapter(
            chapterID: AudiobookIdentifier.chapterID(for: chapterURL),
            chapterURL: chapterURL,
            chapterIndex: 0,
            chapterTitle: "第一章",
            fileName: "chapters/\(AudiobookIdentifier.chapterID(for: chapterURL)).m4a",
            fileSize: 1024,
            audioSHA256: String(repeating: "a", count: 64),
            textSHA256: AudiobookIdentifier.sha256(text),
            segments: [
                AudiobookTimedSegment(
                    text: "第一段。\n",
                    role: "narrator",
                    startTime: 0,
                    endTime: 1,
                    startOffset: 0,
                    endOffset: 5
                ),
                AudiobookTimedSegment(
                    text: "第二段。",
                    role: "female",
                    startTime: 1,
                    endTime: 2,
                    startOffset: 5,
                    endOffset: 9
                )
            ]
        )
        let manifest = AudiobookPackageManifest(
            format: "quietreader-readaloud",
            formatVersion: 1,
            protocolVersion: AudiobookProtocol.version,
            createdAt: "2026-08-11T00:00:00Z",
            bookID: "book",
            bookTitle: "测试书",
            author: "作者",
            voice: "multi-role",
            generationSpeed: 1,
            chapterCount: 1,
            packageFingerprint: String(repeating: "b", count: 64),
            chapters: [chapter]
        )
        XCTAssertNoThrow(try AudiobookPackageValidator.validate(manifest, expectedBookID: "book"))
    }
}
