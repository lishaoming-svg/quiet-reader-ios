import SwiftData
import UIKit
import XCTest
@testable import QuietReader

final class LibraryOrganizationTests: XCTestCase {
    private func book() -> SearchBook {
        SearchBook(sourceID: LocalBookStorage.sourceID, sourceName: "本地", name: "测试图书", author: "作者", intro: "", kind: "TXT", lastChapter: "", updateTime: "", bookURL: "localbook://test/book", coverURL: "", tocURL: "")
    }
    @MainActor func testManualReadingStatusNeverResetsSavedLocator() throws {
        let container = try ModelContainer(for: BookRecord.self, ReadingProgressRecord.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let record = BookRecord(book: book()), chapter = BookChapter(title: "第二章", url: "localbook://test/1", index: 1)
        let progress = ReadingProgressRecord(bookID: record.bookID, chapter: chapter)
        progress.chapterProgress = 0.72; progress.bookProgress = 0.86; progress.publicationLocator = "saved-location"
        container.mainContext.insert(record); container.mainContext.insert(progress); try container.mainContext.save()
        try LibraryOrganization.setFinished(true, book: record, context: container.mainContext)
        XCTAssertTrue(LibraryOrganization.completed(record, progress: progress))
        try LibraryOrganization.setFinished(false, book: record, context: container.mainContext)
        XCTAssertFalse(LibraryOrganization.completed(record, progress: progress))
        XCTAssertEqual(progress.chapterIndex, 1); XCTAssertEqual(progress.chapterProgress, 0.72)
        XCTAssertEqual(progress.bookProgress, 0.86); XCTAssertEqual(progress.publicationLocator, "saved-location")
    }
    func testCollectionMembershipAndCustomMetadataRoundTripWithoutBookIdentityChanges() throws {
        let record = BookRecord(book: book()), identity = record.bookID
        let collection = LibraryCollection(title: "  旅行途中  ")
        XCTAssertEqual(collection.title, "旅行途中")
        var state = record.libraryState
        state.wantToRead = true; state.collectionIDs = [collection.id]; state.customTitle = "我的书名"; state.customAuthor = ""
        record.libraryState = state
        XCTAssertEqual(record.libraryState, state); XCTAssertEqual(record.bookID, identity)
        XCTAssertEqual(LibraryOrganization.collections(from: LibraryOrganization.data([collection])), [collection])
        XCTAssertTrue(LibraryOrganization.collections(from: Data("invalid".utf8)).isEmpty)
    }
    @MainActor func testReimportPreservesEditedTitleAuthorAndCollections() throws {
        let container = try ModelContainer(for: BookRecord.self, ChapterListCacheRecord.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let value = book(), record = BookRecord(book: book())
        var state = record.libraryState; state.customTitle = "手工书名"; state.customAuthor = "手工作者"; state.collectionIDs = ["collection-1"]
        record.libraryState = state; record.name = state.customTitle!; record.author = state.customAuthor!
        container.mainContext.insert(record); try container.mainContext.save()
        let chapter = BookChapter(title: "第一章", url: "localbook://test/0", index: 0)
        XCTAssertTrue(try LocalBookLibrary.save(LocalBookImport(book: value, chapters: [chapter]), in: container.mainContext))
        XCTAssertEqual(record.name, "手工书名"); XCTAssertEqual(record.author, "手工作者")
        XCTAssertEqual(record.libraryState.collectionIDs, ["collection-1"])
    }
    func testAnnotationOffsetsSurviveIndentationAndEmoji() {
        let original = "清晨🌊，海面泛起微光。\n\n灯下翻书。"
        let document = ReaderDocumentBuilder.displayDocument(from: original, paragraphIndent: true)
        let originalRange = (original as NSString).range(of: "🌊，海面")
        let start = document.displayedOffset(forLocatorOffset: originalRange.location)
        let end = document.displayedOffset(forLocatorOffset: NSMaxRange(originalRange))
        XCTAssertEqual((document.text as NSString).substring(with: NSRange(location: start, length: end - start)), "🌊，海面")
        XCTAssertEqual(document.locatorOffset(forDisplayedUTF16Offset: start), originalRange.location)
        XCTAssertEqual(document.locatorOffset(forDisplayedUTF16Offset: end), NSMaxRange(originalRange))
    }
    func testNotesExportKeepsUserTextAndHighlightsHaveValidRanges() {
        let mark = BookmarkRecord(book: book(), chapter: .init(title: "第一章", url: "localbook://test/0", index: 0), locatorOffset: 2, chapterProgress: 0.1, excerpt: "海面泛起微光🌊")
        mark.note = "记住这一刻"; mark.annotationColor = "green"
        let exported = AnnotationTextExporter.text([mark])
        XCTAssertTrue(exported.contains(mark.excerpt)); XCTAssertTrue(exported.contains(mark.note)); XCTAssertTrue(exported.contains(mark.bookName))
        let text = ReaderPageTextStyle.attributedString(text: "海面泛起微光", fontSize: 19, lineSpacing: 9, usesSerif: false,
            highlights: [.init(range: NSRange(location: 0, length: 2), color: .yellow)])
        XCTAssertNotNil(text.attribute(.backgroundColor, at: 0, effectiveRange: nil))
        XCTAssertNil(text.attribute(.backgroundColor, at: 3, effectiveRange: nil))
    }
}
