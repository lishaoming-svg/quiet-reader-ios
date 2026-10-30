#if DEBUG
import SwiftData
import Foundation

/// UI tests get an in-memory database and original sample text, never the user's library.
enum LibraryTestSeed {
    static var pickerDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// Finish fixture creation before showing any UI. The system File Provider
    /// can index the app's published Documents root without resolving a new
    /// nested-folder bookmark during the picker presentation.
    static func preparePickerFiles() throws {
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
            for key in ["reader.lineGuideEnabled", "reader.lineGuidePosition", "reader.mode", "reader.family", "reader.bold", "reader.importedFont", "reader.serif", "reader.fontSize", "reader.lineSpacing", "reader.paper", "local.reader.preset", "library.collections.v1", "epub.mode", "epub.direction", "epub.publisherStyles", "epub.theme"] {
                UserDefaults.standard.removeObject(forKey: key)
            }
            if ProcessInfo.processInfo.arguments.contains("--rich-source-fixture") { UserDefaults.standard.set(ReaderMode.scroll.rawValue, forKey: "epub.mode") }
        }
        guard ProcessInfo.processInfo.arguments.contains("--picker-fixtures") else { return }
        let folder = pickerDirectory
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let textFile = folder.appendingPathComponent("从文件导入.txt")
        if !FileManager.default.fileExists(atPath: textFile.path) {
            try Data("第一章 文件导入\n这段文字来自系统文件选择器，而非预先加入的书库。".utf8).write(to: textFile, options: .atomic)
        }
        if let sample = Bundle.main.url(forResource: "precision", withExtension: "epub", subdirectory: "ImportExamples")
            ?? Bundle.main.url(forResource: "precision", withExtension: "epub") {
            let epubFile = folder.appendingPathComponent("精排示例.epub")
            if !FileManager.default.fileExists(atPath: epubFile.path) { try Data(contentsOf: sample).write(to: epubFile, options: .atomic) }
        }
    }

    @MainActor static func populate(context: ModelContext) throws {
        guard !ProcessInfo.processInfo.arguments.contains("--empty-library") else { return }
        guard try context.fetchCount(FetchDescriptor<BookRecord>()) == 0 else { return }
        if ProcessInfo.processInfo.arguments.contains("--rich-source-fixture") {
            let source = try JSONDecoder().decode(BookSourceDefinition.self, from: Data(#"{"sourceId":"rich-ui-test","bookSourceName":"精排测试书源","bookSourceUrl":"https://example.org"}"#.utf8))
            let book = SearchBook(sourceID: source.id, sourceName: source.bookSourceName, name: "连续精排示例", author: "测试作者", intro: "", kind: "", lastChapter: "", updateTime: "", bookURL: "https://example.org/book", coverURL: "", tocURL: "")
            let chapters = [BookChapter(title: "清晨来信", url: "https://example.org/one", index: 0), BookChapter(title: "灯下回信", url: "https://example.org/two", index: 1)]
            context.insert(try BookSourceRecord(definition: source)); context.insert(BookRecord(book: book))
            let bodies = ["<p style='color:#c00;text-align:center'>你有一封新来信</p><p style='border:1px solid #332619;border-radius:12px;text-indent:0;padding:8px'>谢谢你的来信。</p>" + String(repeating: "<p>清晨，海面泛起微光，风把远处的钟声送到窗前。</p>", count: 7),
                "<p style='text-align:right'>海边的朋友</p><p style='text-align:right;background-color:#a0ce65;border-radius:12px;text-indent:0;padding:8px'>灯下的回信已经寄出。</p>" + String(repeating: "<p>夜色落在窗台上，一盏灯照亮尚未读完的书页。</p>", count: 12)]
            for (index, chapter) in chapters.enumerated() {
                context.insert(ChapterCacheRecord(sourceID: source.id, bookID: book.id, chapter: chapter, content: ReadableContentFormatter.plainText(from: bodies[index]), htmlContent: bodies[index]))
            }
            try ChapterListCacheStore.save(chapters: chapters, bookID: book.id, sourceID: source.id, in: context)
            return
        }
        let titles = ["山海之间", "漫长的午后", "雨停之后", "远方来信", "小岛散步", "时间的纹理"]
        for (index, title) in titles.enumerated() {
            let text = "第一章 海边的清晨\n" + String(repeating: "清晨，海面泛起微光。沿着小路慢慢向前走，风把远处的钟声送到窗前。我们停下脚步，翻开书，记下今天的第一个故事。\n\n", count: 24)
                + "第二章 灯下的书页\n夜色落在窗台上，一盏灯照亮尚未读完的书页。\n"
            let payload = text + (index == 0 ? "" : "\n" + title)
            let value = try LocalBookImporter.prepare(data: Data(payload.utf8), filename: "\(title).txt")
            try LocalBookLibrary.save(value, in: context)
            let id = value.book.id
            if let record = try context.fetch(FetchDescriptor<BookRecord>(predicate: #Predicate { $0.bookID == id })).first {
                record.addedAt = Date(timeIntervalSince1970: 1_700_000_000 - Double(index * 1000))
                record.lastReadAt = record.addedAt
                try context.save()
            }
        }
    }
}
#endif
