import Foundation
import PDFKit
import SwiftData
import UIKit
import XCTest
import ZIPFoundation
@testable import QuietReader

final class ReedenMigrationTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
    private func zip(_ files: [String: Data]) throws -> Data {
        let archive = try ZIPFoundation.Archive(data: Data(), accessMode: .create)
        for (path, data) in files {
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count), compressionMethod: .deflate) { offset, count in
                data.subdata(in: Int(offset)..<min(Int(offset) + count, data.count))
            }
        }
        return try XCTUnwrap(archive.data)
    }
    private func backup(version: Int = 1) throws -> URL {
        let metadata = try zip([
            "book.json": Data(#"[{"id":"B1","title":"迁移测试书","type":"txt","read_progress":7500,"last_read_section_index":0,"last_read_para_index":1,"last_read_time":"2026-10-23T12:11:17.119733"}]"#.utf8),
            "book_notes.json": Data(#"[{"id":"N1","book_id":"B1","section_index":0,"paragraph_index":1,"start_index":2,"end_paragraph_index":1,"end_index":8,"description":"测试摘录","comment":"我的笔记","type":"underline","create_at":"2026-10-22T08:00:00"},{"id":"N2","book_id":"missing","description":"缺书仍保留笔记","comment":"","type":"bookmark"}]"#.utf8),
            "read_record.json": Data(#"[{"id":"R1","book_id":"B1","date":"2026-10-22","read_seconds":120}]"#.utf8),
            "read_record_hourly.json": Data(#"[{"id":"H1","book_id":"B1","date":"2026-10-22","read_seconds":120}]"#.utf8),
            "settings.json": Data("这不是 JSON，迁移不应读取主题设置".utf8),
            "reader_color_schema.json": Data("不应读取排版表".utf8)
        ])
        let data = try zip(["manifest.json": Data("{\"format\":\"reeden_full_backup\",\"version\":\(version)}".utf8), "metadata.zip": metadata,
            "books/B1/B1": Data("第一章 海风\n清晨翻开书页。\n在海边继续阅读。".utf8),
            "books/B1/sections.json": Data(#"[{"uri":"Text/chapter1.xhtml"}]"#.utf8),
            "books/B1/book_config.json": Data("不应导入字号主题方向".utf8),
            "reader_bg_images/ignore": Data("不能迁移背景".utf8)])
        let url = root.appendingPathComponent("backup.zip"); try data.write(to: url); return url
    }
    @MainActor
    func testRestoreBooksNotesProgressAndTimeIsIdempotentAndExcludesAllSettings() async throws {
        let container = try ModelContainer(for: BookRecord.self, ChapterListCacheRecord.self, ReadingProgressRecord.self,
            BookmarkRecord.self, ReadingSessionRecord.self, MigrationReceiptRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container), url = try backup()
        let settingsBefore = UserDefaults.standard.dictionaryRepresentation()
        let report = try await ReedenMigration.restore(url: url, context: context, root: root) { _, _, _ in }
        XCTAssertEqual(report.books, 1); XCTAssertEqual(report.notes, 2); XCTAssertEqual(report.sessions, 1)
        XCTAssertTrue(report.failures.isEmpty)
        let book = try XCTUnwrap(context.fetch(FetchDescriptor<BookRecord>()).first)
        XCTAssertEqual(book.name, "迁移测试书")
        let progress = try XCTUnwrap(context.fetch(FetchDescriptor<ReadingProgressRecord>()).first)
        XCTAssertEqual(progress.bookProgress, 0.75)
        XCTAssertEqual(progress.importedParagraphIndex, 1)
        let marks = try context.fetch(FetchDescriptor<BookmarkRecord>())
        let note = try XCTUnwrap(marks.first { $0.bookmarkID == "reeden.note.N1" })
        XCTAssertEqual(note.note, "我的笔记"); XCTAssertEqual(note.excerpt, "测试摘录")
        XCTAssertEqual(note.importedEndOffset, 8)
        XCTAssertTrue(marks.contains { $0.excerpt == "缺书仍保留笔记" })
        XCTAssertEqual(try context.fetch(FetchDescriptor<ReadingSessionRecord>()).reduce(0) { $0 + $1.activeSeconds }, 120)
        progress.bookProgress = 0.9; try context.save()
        let repeated = try await ReedenMigration.restore(url: url, context: context, root: root) { _, _, _ in }
        XCTAssertEqual(repeated.notes, 0); XCTAssertEqual(repeated.sessions, 0)
        XCTAssertEqual(progress.bookProgress, 0.9, "恢复不能覆盖新进度")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<BookRecord>()), 1)
        for (key, value) in settingsBefore where key.hasPrefix("reader.") || key.hasPrefix("epub.") {
            XCTAssertEqual(String(describing: UserDefaults.standard.object(forKey: key)), String(describing: Optional(value)))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("reader_bg_images").path))
    }
    func testRejectsFutureBackupAndUnsafeIDs() async throws {
        let url = try backup(version: 99)
        do { _ = try await ReedenBackupArchive(url: url).plan(); XCTFail("应拒绝新版本") }
        catch { XCTAssertTrue(error is ReedenBackupError) }
        XCTAssertFalse(ReedenBackupArchive.validIdentifier("../outside"))
        XCTAssertFalse(ReedenBackupArchive.validIdentifier("a/b"))
        XCTAssertTrue(ReedenBackupArchive.validIdentifier("ABC123-def"))
    }
    func testPDFPreservesOriginalAndIndexesPages() throws {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 400, height: 600))
        let data = renderer.pdfData { context in
            context.beginPage(); ("第一页" as NSString).draw(at: CGPoint(x: 20, y: 20), withAttributes: [.font: UIFont.systemFont(ofSize: 20)])
            context.beginPage(); ("第二页" as NSString).draw(at: CGPoint(x: 20, y: 20), withAttributes: [.font: UIFont.systemFont(ofSize: 20)])
        }
        let book = try LocalBookImporter.prepare(data: data, filename: "原版.pdf", root: root)
        XCTAssertEqual(book.book.kind, "PDF"); XCTAssertEqual(book.chapters.count, 2)
        XCTAssertEqual(try Data(contentsOf: LocalBookStorage.pdfURL(for: book.book.bookURL, root: root)), data)
    }
    func testEPUBExportRoundTripsLiteralTextAndFullDirectory() throws {
        let source = SearchBook(sourceID: "test", sourceName: "测试", name: "书名 & <标题>", author: "作者", intro: "", kind: "", lastChapter: "", updateTime: "", bookURL: "https://example.org/book?a=1&b=2", coverURL: "", tocURL: "")
        let data = try BookEPUBExporter.build(book: source, chapters: [.init(title: "章节一", content: "1 < 2 && 3 > 2"), .init(title: "章节二", content: "完整正文。")])
        let document = try EPUBDocumentParser.parse(data, fallbackTitle: "导出书")
        XCTAssertEqual(document.title, source.name)
        XCTAssertEqual(document.chapters.map(\.title), ["章节一", "章节二"])
        XCTAssertTrue(document.chapters[0].content.contains("1 < 2 && 3 > 2"))
        XCTAssertThrowsError(try BookEPUBExporter.build(book: source, chapters: []))
    }
}
