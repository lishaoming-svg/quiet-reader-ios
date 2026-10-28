import CoreFoundation
import Foundation

enum LocalBookError: LocalizedError {
    case unsupported, empty, invalid, encrypted, tooLarge, missing, unreadableText
    var errorDescription: String? {
        switch self {
        case .unsupported: "请选择 EPUB、TXT、DOCX、DOC、MOBI、AZW 或 AZW3 图书。JSON 书源请在“搜索 → 书源管理”导入。"
        case .empty: "文件中没有可阅读的正文，请检查文件后重新导入。"
        case .invalid: "文件内容损坏或与扩展名不符，请重新导出后再导入。"
        case .encrypted: "这本书或文档已加密。请使用未加密、无需密码的版本。"
        case .tooLarge: "文件或解压后的内容过大。普通图书上限 256 MB，Kindle 上限 64 MB，压缩包另有展开限制。请压缩图片或拆分文档后重试。"
        case .missing: "本地书籍文件已丢失，请重新导入原文件以恢复阅读。"
        case .unreadableText: "无法识别文字编码。请将文本另存为 UTF-8 后重新导入。"
        }
    }
}

struct LocalBookDocument: Codable, Sendable {
    struct Chapter: Codable, Sendable, Equatable {
        var title: String
        var content: String
    }
    var version = 1
    var title: String
    var author: String
    var format: String
    var chapters: [Chapter]
    var cover: Data?
    var publicationData: Data? = nil
}

enum ReadingTextPreparation {
    static func prepare(_ value: String, sourceID: String) -> String {
        sourceID == LocalBookStorage.sourceID ? value : ReadableTextNormalizer.normalize(value)
    }
}

enum LocalTextDecoder {
    static func decode(_ data: Data) throws -> String {
        guard !data.isEmpty else { throw LocalBookError.empty }
        let bytes = Array(data.prefix(4))
        let value: String?
        if bytes.starts(with: [0xFF, 0xFE, 0, 0]) {
            value = String(data: data.dropFirst(4), encoding: .utf32LittleEndian)
        } else if bytes.starts(with: [0, 0, 0xFE, 0xFF]) {
            value = String(data: data.dropFirst(4), encoding: .utf32BigEndian)
        } else if bytes.starts(with: [0xFF, 0xFE]) {
            value = String(data: data.dropFirst(2), encoding: .utf16LittleEndian)
        } else if bytes.starts(with: [0xFE, 0xFF]) {
            value = String(data: data.dropFirst(2), encoding: .utf16BigEndian)
        } else if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            value = String(data: data.dropFirst(3), encoding: .utf8)
        } else {
            let gb = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
            let big5 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.big5.rawValue)))
            value = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: gb)
                ?? String(data: data, encoding: big5)
                ?? String(data: data, encoding: .windowsCP1252)
        }
        guard let value else { throw LocalBookError.unreadableText }
        let invalid = value.unicodeScalars.filter { $0.value < 32 && ![9, 10, 13].contains($0.value) }.count
        guard invalid == 0 else { throw LocalBookError.unreadableText }
        return value.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }
}

enum LocalChapterSplitter {
    private static let heading = try! NSRegularExpression(
        pattern: #"^(?:第[零〇一二三四五六七八九十百千万两0-9０-９]+[章节卷部回篇]|(?:chapter|part|book)\s+[0-9ivxlcdm]+\b|序章$|楔子$|前言$|后记$|尾声$)"#,
        options: .caseInsensitive)

    static func split(_ text: String, title: String, headings: [String] = []) throws -> [LocalBookDocument.Chapter] {
        let explicitHeadings = Set(headings)
        var result: [LocalBookDocument.Chapter] = []
        var currentTitle = title
        var lines: [String] = []
        var length = 0
        func flush() {
            let content = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !content.isEmpty { result.append(.init(title: currentTitle, content: content)) }
            lines = []; length = 0
        }
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.utf16.count > 24_000 {
                flush()
                var start = line.startIndex
                while start < line.endIndex {
                    let end = line.index(start, offsetBy: 6_000, limitedBy: line.endIndex) ?? line.endIndex
                    result.append(.init(title: "\(title) · \(result.count + 1)", content: String(line[start..<end])))
                    start = end
                }
                currentTitle = "\(title) · \(result.count + 1)"
                continue
            }
            let range = NSRange(line.startIndex..., in: line)
            if line.count <= 80, explicitHeadings.contains(line) || heading.firstMatch(in: line, range: range) != nil {
                flush()
                currentTitle = line
                // Keep headings in the document, including consecutive headings without body text.
                lines = [line]; length = line.utf16.count
            } else {
                if length > 24_000 { flush(); currentTitle = "\(title) · \(result.count + 1)" }
                lines.append(line); length += line.utf16.count + 1
            }
        }
        flush()
        guard !result.isEmpty else { throw LocalBookError.empty }
        return result
    }
}
