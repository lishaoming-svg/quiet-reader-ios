import Foundation
import SwiftData

struct ReedenMigrationReport {
    var books = 0, notes = 0, fonts = 0, sessions = 0
    var failures: [String] = []
    var summary: String { "已迁移 \(books) 本图书、\(notes) 条笔记与书签、\(fonts) 个字体、\(sessions) 条阅读时长。主题和排版设置未导入。" }
}
enum ReedenDate {
    static func parse(_ value: String?) -> Date? {
        guard let value else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: value) { return date }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: value) { return date }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        for pattern in ["yyyy-MM-dd'T'HH:mm:ss.SSSSSS", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd"] {
            formatter.dateFormat = pattern
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }
}
@MainActor
enum ReedenMigration {
    static func restore(url: URL, context: ModelContext, root: URL = LocalBookStorage.root,
                        progress: (Int, Int, String) -> Void) async throws -> ReedenMigrationReport {
        let archive = try ReedenBackupArchive(url: url)
        let plan = try await archive.plan()
        var report = ReedenMigrationReport()
        let books = plan.books.filter { ($0.is_deleted ?? 0) == 0 }
        let total = books.count + plan.fonts.count
        var mapping: [String: String] = [:]
        let receipts = try context.fetch(FetchDescriptor<MigrationReceiptRecord>())
        for receipt in receipts where receipt.externalID.hasPrefix("reeden.book.") {
            mapping[String(receipt.externalID.dropFirst("reeden.book.".count))] = receipt.bookID
        }
        for (index, book) in books.enumerated() {
            try Task.checkCancellation()
            progress(index, total, book.title)
            do {
                let prepared = try await archive.prepare(book, root: root)
                let duplicate = try LocalBookLibrary.save(prepared.imported, in: context)
                let id = prepared.imported.book.id
                mapping[book.id] = id
                let progressRecord = try context.fetch(FetchDescriptor<ReadingProgressRecord>(predicate: #Predicate { $0.bookID == id })).first
                // A second restore cannot move an actively read book back in time.
                if !duplicate || progressRecord == nil {
                    let chapters = prepared.imported.chapters
                    let index = min(max(book.last_read_section_index ?? 0, 0), chapters.count - 1)
                    let record = progressRecord ?? ReadingProgressRecord(bookID: id, chapter: chapters[index])
                    if record.modelContext == nil { context.insert(record) }
                    record.update(chapter: chapters[index], locatorOffset: book.last_read_element_index ?? 0)
                    record.bookProgress = book.progress
                    record.importedSectionURI = prepared.sectionURI
                    record.importedParagraphIndex = max(0, book.last_read_para_index ?? 0)
                    record.updatedAt = ReedenDate.parse(book.last_read_time) ?? .now
                }
                let externalID = "reeden.book." + book.id
                if let receipt = receipts.first(where: { $0.externalID == externalID }) { receipt.bookID = id }
                else { context.insert(MigrationReceiptRecord(externalID: externalID, bookID: id)) }
                if let record = try context.fetch(FetchDescriptor<BookRecord>(predicate: #Predicate { $0.bookID == id })).first,
                   !duplicate, let date = ReedenDate.parse(book.last_read_time) { record.lastReadAt = date }
                try context.save()
                report.books += 1
            } catch is CancellationError { throw CancellationError()
            } catch {
                context.rollback()
                report.failures.append(book.title + "：" + error.localizedDescription)
            }
        }
        for (index, font) in plan.fonts.enumerated() {
            try Task.checkCancellation()
            progress(books.count + index, total, "字体 · " + (font.display_name ?? font.name))
            do { try await archive.installFont(font); report.fonts += 1 }
            catch { report.failures.append("字体“\(font.name)”：" + error.localizedDescription) }
        }
        report.notes = try restoreNotes(plan.notes, books: plan.books, mapping: mapping, context: context)
        report.sessions = try restoreSessions(plan.records, books: plan.books, mapping: mapping, context: context)
        progress(total, total, "迁移完成")
        return report
    }
    static func restoreNotes(_ notes: [ReedenNote], books: [ReedenBook], mapping: [String: String], context: ModelContext) throws -> Int {
        var seen = Set(try context.fetch(FetchDescriptor<BookmarkRecord>()).map(\.bookmarkID))
        let titles = Dictionary(books.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        let lists = Dictionary(try context.fetch(FetchDescriptor<ChapterListCacheRecord>()).map { ($0.bookID, $0.chapters) }, uniquingKeysWith: { first, _ in first })
        var count = 0
        for note in notes {
            try Task.checkCancellation()
            let noteID = "reeden.note." + note.id
            guard seen.insert(noteID).inserted else { continue }
            let id = mapping[note.book_id] ?? "reeden.unavailable::" + note.book_id
            let index = max(0, note.section_index ?? 0)
            let chapter = lists[id].flatMap { $0.indices.contains(index) ? $0[index] : nil }
                ?? BookChapter(title: note.section_name?.nilIfBlank ?? "导入的笔记", url: "", index: index)
            let placeholder = SearchBook(sourceID: LocalBookStorage.sourceID, sourceName: "Reeden 迁移", name: titles[note.book_id] ?? "原图书未在备份中", author: "", intro: "", kind: "", lastChapter: "", updateTime: "", bookURL: "", coverURL: "", tocURL: "")
            let mark = BookmarkRecord(book: placeholder, chapter: chapter, locatorOffset: note.start_index ?? 0, chapterProgress: 0, excerpt: note.description ?? "")
            mark.bookmarkID = noteID; mark.bookID = id; mark.note = note.comment ?? ""; mark.noteKind = note.type ?? "underline"
            mark.importedParagraphIndex = note.paragraph_index
            mark.importedEndParagraphIndex = note.end_paragraph_index; mark.importedEndOffset = note.end_index
            mark.createdAt = ReedenDate.parse(note.create_at) ?? .now
            context.insert(mark); count += 1
        }
        do { try context.save() } catch { context.rollback(); throw error }
        return count
    }
    static func restoreSessions(_ records: [ReedenReadRecord], books: [ReedenBook], mapping: [String: String], context: ModelContext) throws -> Int {
        var seen = Set(try context.fetch(FetchDescriptor<ReadingSessionRecord>()).map(\.sessionID))
        let titles = Dictionary(books.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        var count = 0
        for record in records {
            try Task.checkCancellation()
            let id = "reeden.read." + record.id
            guard record.read_seconds.isFinite, record.read_seconds > 0, let day = ReedenDate.parse(record.date), seen.insert(id).inserted else { continue }
            context.insert(ReadingSessionRecord(sessionID: id, bookID: mapping[record.book_id] ?? "reeden.unavailable::" + record.book_id,
                bookName: titles[record.book_id] ?? "Reeden 图书", sourceID: LocalBookStorage.sourceID,
                startedAt: day, endedAt: day.addingTimeInterval(min(86_399, record.read_seconds)), activeSeconds: record.read_seconds))
            count += 1
        }
        do { try context.save() } catch { context.rollback(); throw error }
        return count
    }
}
