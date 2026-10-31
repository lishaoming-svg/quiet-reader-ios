import Foundation
import CryptoKit
import ZIPFoundation

// Only these five metadata tables are decoded. Theme/layout/settings, per-book
// configuration, backgrounds and UI assets never enter the migration plan.
struct ReedenBackupPlan: Sendable {
    var books: [ReedenBook]
    var notes: [ReedenNote]
    var records: [ReedenReadRecord]
    var fonts: [ReedenFont]
}
struct ReedenBook: Decodable, Sendable {
    let id: String
    let title: String
    let author: String?
    let type: String
    let description: String?
    let read_progress: Int?
    let last_read_section_index: Int?
    let last_read_para_index: Int?
    let last_read_element_index: Int?
    let last_read_time: String?
    let update_at: String?
    let is_deleted: Int?
    var progress: Double { min(1, max(0, Double(read_progress ?? 0) / 10_000)) }
}
struct ReedenNote: Decodable, Sendable {
    let id: String
    let book_id: String
    let section_index: Int?
    let section_name: String?
    let paragraph_index: Int?
    let start_index: Int?
    let end_paragraph_index: Int?
    let end_index: Int?
    let description: String?
    let comment: String?
    let type: String?
    let create_at: String?
}
struct ReedenReadRecord: Decodable, Sendable {
    let id: String
    let book_id: String
    let date: String
    let read_seconds: Double
}
struct ReedenFont: Decodable, Sendable {
    let id: String
    let name: String
    let display_name: String?
}
struct ReedenPreparedBook: Sendable {
    let imported: LocalBookImport
    let sectionURI: String?
    let chapterIndex: Int
    let locatorOffset: Int
}

struct ReedenSection: Decodable, Sendable {
    let uri: String?
    let startOffset: Int?
    let endOffset: Int?
    let title: String?
}
enum ReedenTextPosition {
    static func offset(in text: String, paragraph: Int, element: Int) -> Int {
        var paragraphs: [NSRange] = []
        text.enumerateSubstrings(in: text.startIndex..., options: [.byParagraphs]) { value, range, _, _ in
            if value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false { paragraphs.append(NSRange(range, in: text)) }
        }
        guard !paragraphs.isEmpty else { return 0 }
        let target = paragraphs[min(max(0, paragraph), paragraphs.count - 1)]
        return target.location + min(max(0, element), target.length)
    }
}
enum ReedenBackupError: LocalizedError {
    case invalid, missingBook, unsupportedVersion, unsafeEntry
    var errorDescription: String? {
        switch self {
        case .invalid: "不是有效的 Reeden 完整备份。请选择原始 reeden_full_backup.zip。"
        case .missingBook: "备份中缺少该书原文件；笔记和时长仍会保留。"
        case .unsupportedVersion: "备份版本暂不支持，请从 Reeden 重新导出完整备份。"
        case .unsafeEntry: "备份包含不安全或过大的文件路径，已停止读取。"
        }
    }
}
actor ReedenBackupArchive {
    private let archive: Archive
    init(url: URL) throws { archive = try Archive(url: url, accessMode: .read) }
    func plan() throws -> ReedenBackupPlan {
        struct Manifest: Decodable { let format: String; let version: Int }
        let manifest = try JSONDecoder().decode(Manifest.self, from: read("manifest.json", limit: 64 * 1_024))
        guard manifest.format == "reeden_full_backup" else { throw ReedenBackupError.invalid }
        guard manifest.version == 1 else { throw ReedenBackupError.unsupportedVersion }
        let data = try read("metadata.zip", limit: 64 * 1_024 * 1_024)
        let metadata = try Archive(data: data, accessMode: .read)
        func table<T: Decodable>(_ type: T.Type, _ path: String) throws -> [T] {
            guard metadata[path] != nil else { return [] }
            return try JSONDecoder().decode([T].self, from: Self.read(path, archive: metadata, limit: 32 * 1_024 * 1_024))
        }
        return ReedenBackupPlan(books: try table(ReedenBook.self, "book.json"),
            notes: try table(ReedenNote.self, "book_notes.json"),
            // Daily records already contain hourly totals: importing both would double count.
            records: try table(ReedenReadRecord.self, "read_record.json"),
            fonts: try table(ReedenFont.self, "fonts.json"))
    }
    func prepare(_ book: ReedenBook, root: URL = LocalBookStorage.root) throws -> ReedenPreparedBook {
        guard Self.validIdentifier(book.id) else { throw ReedenBackupError.unsafeEntry }
        let base = "books/" + book.id + "/"
        guard archive[base + book.id] != nil else { throw ReedenBackupError.missingBook }
        let sections = (try? JSONDecoder().decode([ReedenSection].self, from: read(base + "sections.json", limit: 8 * 1_024 * 1_024))) ?? []
        var imported: LocalBookImport
        if book.type.lowercased() == "pdf" {
            imported = try preparePDF(base + book.id, root: root)
        } else {
        let data = try read(base + book.id, limit: LocalBookImporter.maximumFileSize)
        if book.type.lowercased() == "txt", !sections.isEmpty,
           sections.allSatisfy({ ($0.startOffset ?? -1) >= 0 && ($0.endOffset ?? -1) > ($0.startOffset ?? 0) && ($0.endOffset ?? Int.max) <= data.count }) {
            struct Toc: Decodable { let title: String; let sectionIndex: Int }
            let toc = (try? JSONDecoder().decode([Toc].self, from: read(base + "toc.json", limit: 8 * 1_024 * 1_024))) ?? []
            let labels = Dictionary(toc.map { ($0.sectionIndex, $0.title) }, uniquingKeysWith: { first, _ in first })
            var chapters: [LocalBookDocument.Chapter] = []
            var textBytes = 0
            for (index, section) in sections.enumerated() {
                try Task.checkCancellation()
                let text = try LocalTextDecoder.decode(data.subdata(in: section.startOffset!..<section.endOffset!))
                textBytes += text.utf8.count
                guard textBytes <= 64 * 1_024 * 1_024 else { throw LocalBookError.tooLarge }
                let title = labels[index]?.nilIfBlank ?? section.title?.nilIfBlank ?? "第 \(index + 1) 节"
                chapters.append(.init(title: title, content: text.nilIfBlank ?? title))
            }
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            imported = try LocalBookStorage.save(LocalBookDocument(title: book.title, author: book.author ?? "", format: "TXT", chapters: chapters), digest: digest, root: root)
        } else {
            imported = try LocalBookImporter.prepare(data: data, filename: "reeden." + book.type.lowercased(), root: root)
        }
        }
        // Reeden metadata can contain corrections absent from the original file.
        imported = LocalBookImport(book: SearchBook(sourceID: imported.book.sourceID, sourceName: imported.book.sourceName,
            name: book.title, author: book.author?.nilIfBlank ?? imported.book.author,
            intro: book.description ?? imported.book.intro, kind: imported.book.kind, lastChapter: "", updateTime: "",
            bookURL: imported.book.bookURL, coverURL: imported.book.coverURL, tocURL: imported.book.tocURL), chapters: imported.chapters)
        var sectionURI: String?
        let originalIndex = max(0, book.last_read_section_index ?? 0)
        if sections.indices.contains(originalIndex) { sectionURI = sections[originalIndex].uri }
        let count = imported.chapters.count
        let restoredIndex = sections.count == count || book.type.lowercased() == "epub" || book.type.lowercased() == "pdf"
            ? min(originalIndex, count - 1) : min(Int(book.progress * Double(count)), count - 1)
        let index = book.progress == 1 ? count - 1 : restoredIndex
        if book.progress == 1 { sectionURI = sections.last?.uri }
        let body = try LocalBookStorage.content(at: imported.chapters[index].url, root: root)
        let offset = book.progress == 1 ? (body as NSString).length
            : ReedenTextPosition.offset(in: body, paragraph: book.last_read_para_index ?? 0, element: book.last_read_element_index ?? 0)
        return ReedenPreparedBook(imported: imported, sectionURI: sectionURI, chapterIndex: index, locatorOffset: offset)
    }
    func installFont(_ font: ReedenFont) throws {
        guard Self.validIdentifier(font.id) else { throw ReedenBackupError.unsafeEntry }
        try ImportedFontStore.install(read("fonts/" + font.id, limit: 48 * 1_024 * 1_024), name: font.display_name?.nilIfBlank ?? font.name)
    }
    private func preparePDF(_ path: String, root: URL) throws -> LocalBookImport {
        guard let entry = archive[path], entry.type == .file else { throw ReedenBackupError.invalid }
        guard entry.uncompressedSize <= LocalBookImporter.maximumPDFSize else { throw LocalBookError.tooLarge }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else { throw LocalBookError.invalid }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let handle = try FileHandle(forWritingTo: temporary)
        defer { try? handle.close() }
        var size = 0
        let crc = try archive.extract(entry) { chunk in
            try Task.checkCancellation()
            size += chunk.count
            guard size <= LocalBookImporter.maximumPDFSize else { throw LocalBookError.tooLarge }
            try handle.write(contentsOf: chunk)
        }
        try handle.close()
        guard crc == entry.checksum else { throw ReedenBackupError.invalid }
        return try LocalBookImporter.preparePDF(url: temporary, root: root)
    }
    static func validIdentifier(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 128 && id.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_" )).contains($0) }
    }
    private func read(_ path: String, limit: Int) throws -> Data { try Self.read(path, archive: archive, limit: limit) }
    private static func read(_ path: String, archive: Archive, limit: Int) throws -> Data {
        guard let entry = archive[path], entry.type == .file else { throw ReedenBackupError.invalid }
        guard entry.uncompressedSize <= limit, !entry.path.hasPrefix("/"), !entry.path.contains("\\"),
              !entry.path.split(separator: "/").contains("..") else { throw ReedenBackupError.unsafeEntry }
        var data = Data()
        let crc = try archive.extract(entry) { chunk in
            try Task.checkCancellation()
            guard chunk.count <= limit - data.count else { throw ReedenBackupError.unsafeEntry }
            data.append(chunk)
        }
        guard crc == entry.checksum else { throw ReedenBackupError.invalid }
        return data
    }
}
