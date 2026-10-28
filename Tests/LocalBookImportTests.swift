import CoreFoundation
import Foundation
import SwiftData
import XCTest
@testable import QuietReader

final class LocalBookImportTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func fixture(_ name: String, _ ext: String) throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: ext, subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    func testChineseTextEncodingAndChapterDetection() throws {
        let value = try LocalBookImporter.prepare(data: fixture("多编码文本", "txt"), filename: "多编码文本.TXT", root: root)
        XCTAssertEqual(value.book.name, "多编码文本")
        XCTAssertEqual(value.book.kind, "TXT")
        XCTAssertEqual(value.chapters.map(\.title), ["前言", "第一章初见", "第二章 归途"])
        XCTAssertTrue(try LocalBookStorage.content(at: value.chapters[1].url, root: root).contains("窗外下着雨"))
    }

    func testUnicodeBOMsAndLiteralTextArePreserved() throws {
        let text = "第一章 文本\n1 < 2 && 3 > 2\n保留 A*B、拼音 shi 和表情🌊。"
        let formats: [(Data, String.Encoding)] = [(Data([0xEF, 0xBB, 0xBF]), .utf8),
            (Data([0xFF, 0xFE]), .utf16LittleEndian), (Data([0xFE, 0xFF]), .utf16BigEndian),
            (Data([0xFF, 0xFE, 0, 0]), .utf32LittleEndian)]
        for (bom, encoding) in formats {
            let bytes = bom + (try XCTUnwrap(text.data(using: encoding)))
            XCTAssertEqual(try LocalTextDecoder.decode(bytes), text)
        }
    }

    func testDOCXMetadataHeadingsRunsAndTables() throws {
        let value = try LocalBookImporter.prepare(data: fixture("sample", "docx"), filename: "sample.docx", root: root)
        XCTAssertEqual(value.book.name, "来自 Word 的书")
        XCTAssertEqual(value.book.author, "墨阅测试")
        XCTAssertEqual(value.chapters.map(\.title), ["清晨", "夜晚"])
        let first = try LocalBookStorage.content(at: value.chapters[0].url, root: root)
        XCTAssertTrue(first.contains("第一段 连续文字。\n换行之后。"))
        XCTAssertTrue(first.contains("表格左列"))
        XCTAssertTrue(first.contains("表格右列"))
        XCTAssertFalse(first.contains("删除的内容"))
    }

    func testBinaryWordPieceTableReconstructsChineseAndTableText() throws {
        let value = try LocalBookImporter.prepare(data: fixture("sample", "doc"), filename: "旧文档.doc", root: root)
        XCTAssertEqual(value.chapters.count, 2)
        let first = try LocalBookStorage.content(at: value.chapters[0].url, root: root)
        let second = try LocalBookStorage.content(at: value.chapters[1].url, root: root)
        XCTAssertTrue(first.contains("旧版 Word 正文。"))
        XCTAssertTrue(second.contains("保留中文与表格\t下一格。"))
    }

    func testKindleHybridKF8PalmDOCAndHuffmanSamplesForAllExtensions() throws {
        for name in ["sample-ncx", "sample-unicode-huffdic"] {
            let data = try fixture(name, "mobi")
            for ext in ["mobi", "azw", "azw3"] {
                let value = try LocalBookImporter.prepare(data: data, filename: "sample.\(ext)", root: root)
                XCTAssertFalse(value.chapters.isEmpty, "\(name).\(ext)")
                let text = try LocalBookStorage.content(at: value.chapters[0].url, root: root)
                XCTAssertGreaterThan(text.count, 100, "\(name).\(ext)")
                XCTAssertFalse(text.contains("<html"))
                XCTAssertEqual(value.book.kind, ext.uppercased())
            }
        }
    }

    func testEncryptedWordAndKindleFilesReportEncryption() throws {
        var word = try fixture("sample", "doc")
        // MS-CFB sector 2 contains WordDocument; FIB bit 8 declares encryption.
        word[(2 + 1) * 512 + 11] |= 1
        assertError(.encrypted) { try LocalBookImporter.prepare(data: word, filename: "locked.doc", root: root) }
        var mobi = try fixture("sample-ncx", "mobi")
        let offset = mobi[78..<82].reduce(0) { ($0 << 8) | Int($1) }
        mobi[offset + 12] = 0; mobi[offset + 13] = 2
        assertError(.encrypted) { try LocalBookImporter.prepare(data: mobi, filename: "locked.azw3", root: root) }
        assertError(.encrypted) {
            try LocalBookImporter.prepare(data: Data([0xD0, 0xCF, 0x11, 0xE0]), filename: "locked.docx", root: root)
        }
    }

    func testInvalidEmptyAndUnsupportedFilesDoNotCreateBooks() throws {
        assertError(.empty) { try LocalBookImporter.prepare(data: Data(), filename: "empty.txt", root: root) }
        assertError(.unsupported) { try LocalBookImporter.prepare(data: Data("hello".utf8), filename: "image.png", root: root) }
        for ext in ["doc", "docx", "mobi", "azw", "azw3"] {
            assertError(.invalid) { try LocalBookImporter.prepare(data: Data("broken".utf8), filename: "broken.\(ext)", root: root) }
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    func testCorruptCompoundDocumentCannotLoopThroughCyclicFAT() throws {
        var data = try fixture("sample", "doc")
        // Directory's FAT entry points back to itself.
        data.replaceSubrange(1024..<1028, with: [0, 0, 0, 0])
        assertError(.invalid) { try LocalBookImporter.prepare(data: data, filename: "cycle.doc", root: root) }
    }

    func testReimportRestoresMissingChapterAndKeepsStableIdentifiers() throws {
        let bytes = Data("第一章 归来\n相同的书籍，保留阅读位置。".utf8)
        let first = try LocalBookImporter.prepare(data: bytes, filename: "归来.txt", root: root)
        let folder = root.appendingPathComponent(try XCTUnwrap(URL(string: first.book.bookURL)?.host))
        try FileManager.default.removeItem(at: folder.appendingPathComponent("0.txt"))
        assertError(.missing) { try LocalBookStorage.content(at: first.chapters[0].url, root: root) }
        let again = try LocalBookImporter.prepare(data: bytes, filename: "归来.txt", root: root)
        XCTAssertEqual(first.book.id, again.book.id)
        XCTAssertEqual(first.chapters, again.chapters)
        XCTAssertTrue(try LocalBookStorage.content(at: again.chapters[0].url, root: root).contains("保留阅读位置"))
    }

    func testFileImportStillReadsAfterOriginalFileIsMoved() throws {
        let source = root.appendingPathComponent("原始文件.txt")
        try Data("第一章 离线\n原文件移动后仍可阅读。".utf8).write(to: source)
        let value = try LocalBookImporter.prepare(url: source, root: root.appendingPathComponent("library"))
        try FileManager.default.removeItem(at: source)
        let content = try LocalBookStorage.content(at: value.chapters[0].url, root: root.appendingPathComponent("library"))
        XCTAssertTrue(content.contains("原文件移动后仍可阅读"))
    }

    func testOversizedFileIsRejectedBeforeParsingOrWriting() {
        let bytes = Data(repeating: 0, count: LocalBookImporter.maximumFileSize + 1)
        assertError(.tooLarge) { try LocalBookImporter.prepare(data: bytes, filename: "huge.txt", root: root) }
    }

    func testLocalAddressesCannotEscapeStorageDirectory() {
        for address in ["file:///etc/passwd", "quietreader-local://../1", "quietreader-local://abc/0"] {
            assertError(.missing) { try LocalBookStorage.content(at: address, root: root) }
        }
    }

    func testLongUnbrokenTextIsSplitWithoutLosingCharacters() throws {
        let text = String(repeating: "海🌊风", count: 20_000)
        let chapters = try LocalChapterSplitter.split(text, title: "长文")
        XCTAssertGreaterThan(chapters.count, 1)
        XCTAssertEqual(chapters.map(\.content).joined(), text)
        XCTAssertTrue(chapters.allSatisfy { $0.content.utf16.count <= 24_000 })
    }

    func testReaderAndAudiobookPreparationKeepsLiteralLocalText() {
        let text = "爱情的写法是爱*情。数学表达式 1 < 2，原文保留 shi 和🌊。"
        XCTAssertEqual(ReadingTextPreparation.prepare(text, sourceID: LocalBookStorage.sourceID), text)
    }

    private func assertError<T>(_ expected: LocalBookError, _ operation: () throws -> T,
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            XCTAssertEqual((error as? LocalBookError)?.localizedDescription, expected.localizedDescription, file: file, line: line)
        }
    }
}

@MainActor
final class LocalBookPersistenceTests: XCTestCase {
    func testDuplicateImportPreservesProgressAndDeletingOneBookKeepsTheOther() throws {
        let container = try ModelContainer(for: BookRecord.self, ChapterListCacheRecord.self,
            ReadingProgressRecord.self, ChapterCacheRecord.self, BookmarkRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try LocalBookImporter.prepare(data: Data("第一章 海风\n正文一。".utf8), filename: "甲.txt", root: root)
        let other = try LocalBookImporter.prepare(data: Data("第一章 星光\n正文二。".utf8), filename: "乙.txt", root: root)
        XCTAssertFalse(try LocalBookLibrary.save(first, in: context))
        XCTAssertFalse(try LocalBookLibrary.save(other, in: context))
        let progress = ReadingProgressRecord(bookID: first.book.id, chapter: first.chapters[0])
        progress.locatorOffset = 7
        context.insert(progress)
        try context.save()
        XCTAssertTrue(try LocalBookLibrary.save(first, in: context))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<BookRecord>()), 2)
        XCTAssertEqual(try context.fetch(FetchDescriptor<ReadingProgressRecord>()).first?.locatorOffset, 7)
        let record = try XCTUnwrap(context.fetch(FetchDescriptor<BookRecord>()).first { $0.bookID == first.book.id })
        try LocalBookLibrary.remove(record, in: context)
        XCTAssertEqual(try context.fetch(FetchDescriptor<BookRecord>()).map(\.bookID), [other.book.id])
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ReadingProgressRecord>()), 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<ChapterListCacheRecord>()).map(\.bookID), [other.book.id])
    }
}
