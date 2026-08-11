import SwiftData
import XCTest
@testable import QuietReader

@MainActor
final class ChapterListCacheTests: XCTestCase {
    func testChapterListPersistsAndUpdatesByBook() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: ChapterListCacheRecord.self,
            configurations: configuration
        )
        let context = ModelContext(container)
        let initial = [
            BookChapter(title: "第一章", url: "https://example.test/1", index: 0),
            BookChapter(title: "第二章", url: "https://example.test/2", index: 1),
        ]

        try ChapterListCacheStore.save(
            chapters: initial,
            bookID: "source::book",
            sourceID: "source",
            in: context
        )

        let stored = try XCTUnwrap(
            ChapterListCacheStore.record(bookID: "source::book", in: context)
        )
        XCTAssertEqual(stored.chapters, initial)

        let updated = initial + [
            BookChapter(title: "第三章", url: "https://example.test/3", index: 2)
        ]
        try ChapterListCacheStore.save(
            chapters: updated,
            bookID: "source::book",
            sourceID: "source",
            in: context
        )

        let descriptor = FetchDescriptor<ChapterListCacheRecord>()
        let records = try context.fetch(descriptor)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.chapters, updated)
    }
}
