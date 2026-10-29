#if DEBUG
import SwiftData
import Foundation

/// UI tests get an in-memory database and original sample text, never the user's library.
enum LibraryTestSeed {
    @MainActor static func populate(context: ModelContext) throws {
        if ProcessInfo.processInfo.arguments.contains("--picker-fixtures") {
            let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("导入测试")
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
        guard !ProcessInfo.processInfo.arguments.contains("--empty-library") else { return }
        guard try context.fetchCount(FetchDescriptor<BookRecord>()) == 0 else { return }
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
