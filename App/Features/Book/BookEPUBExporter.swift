import Foundation
import UniformTypeIdentifiers
import SwiftUI
import ZIPFoundation
import CryptoKit
import SwiftSoup

struct ExportBookChapter: Sendable {
    let title: String
    let content: String
    var html: String? = nil
}

struct ExportBookAsset: Sendable {
    let path: String
    let data: Data
    let mediaType: String
}

enum BookEPUBExporter {
    static let maximumTextBytes = 64 * 1024 * 1024
    static let maximumMediaBytes = 128 * 1024 * 1024
    static func prepare(book: SearchBook, chapters: [ExportBookChapter], source: BookSourceDefinition) async throws -> Data {
        var urls: [URL] = [], seen = Set<String>()
        for chapter in chapters {
            guard let html = chapter.html else { continue }
            let document = try SwiftSoup.parseBodyFragment(html)
            for image in try document.select("img[src]").array() {
                guard let url = URL(string: try image.attr("src")), ["http", "https"].contains(url.scheme ?? ""),
                      seen.insert(url.absoluteString).inserted else { continue }
                urls.append(url)
            }
        }
        guard urls.count <= 2000 else { throw BookExportError.media("插图超过 2000 幅，请分卷导出。") }
        var assets: [String: ExportBookAsset] = [:], size = 0
        try await withThrowingTaskGroup(of: (String, ExportBookAsset).self) { group in
            var next = 0
            func enqueue(_ index: Int) {
                let url = urls[index]
                group.addTask {
                    let data = try await SourceMediaStore.shared.data(url, source: source)
                    let digest = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
                    let ext: String
                    if data.starts(with: [137,80,78,71]) { ext = "png" }
                    else if data.starts(with: [71,73,70]) { ext = "gif" }
                    else if String(decoding: data.prefix(256), as: UTF8.self).contains("<svg") { ext = "svg" }
                    else if data.count > 12 && String(decoding: data[8..<12], as: UTF8.self) == "WEBP" { ext = "webp" }
                    else { ext = "jpg" }
                    return (url.absoluteString, ExportBookAsset(path: "images/\(digest).\(ext)", data: data, mediaType: PublicationSchemeHandler.mime(ext)))
                }
            }
            while next < min(3, urls.count) { enqueue(next); next += 1 }
            for try await (url, asset) in group {
                size += asset.data.count
                guard size <= maximumMediaBytes else { group.cancelAll(); throw BookExportError.media("全书插图超过 128 MB，请分卷导出。") }
                assets[url] = asset
                if next < urls.count { enqueue(next); next += 1 }
            }
        }
        let exported = try chapters.map { chapter -> ExportBookChapter in
            var value = chapter
            if let html = chapter.html {
                value.html = try SourcePublicationContainer.rewriteImages(html) { assets[$0.absoluteString]?.path ?? $0.absoluteString }
            }
            return value
        }
        let payload = assets.values.sorted { $0.path < $1.path }
        return try await Task.detached(priority: .userInitiated) { try build(book: book, chapters: exported, assets: payload) }.value
    }
    static func filename(_ title: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:").union(.controlCharacters)
        var name = title.components(separatedBy: invalid).filter { !$0.isEmpty }.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        while name.utf8.count > 200 { name.removeLast() }
        return name.nilIfBlank ?? "图书"
    }

    static func build(book: SearchBook, chapters: [ExportBookChapter], assets: [ExportBookAsset] = []) throws -> Data {
        guard assets.reduce(0, { $0 + $1.data.count }) <= maximumMediaBytes else { throw BookExportError.media("全书插图超过 128 MB。") }
        guard !chapters.isEmpty, chapters.allSatisfy({ !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw BookExportError.empty
        }
        var size = 0
        for chapter in chapters {
            size += (chapter.html ?? chapter.content).utf8.count + chapter.title.utf8.count
            guard size <= maximumTextBytes else { throw BookExportError.tooLarge }
        }
        let archive = try ZIPFoundation.Archive(data: Data(), accessMode: .create)
        func add(_ path: String, _ text: String, compressed: Bool = true) throws {
            let bytes = Data(text.utf8)
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(bytes.count),
                                 compressionMethod: compressed ? .deflate : .none) { position, count in
                bytes.subdata(in: Int(position)..<min(Int(position) + count, bytes.count))
            }
        }
        try add("mimetype", "application/epub+zip", compressed: false)
        try add("META-INF/container.xml", """
        <?xml version="1.0" encoding="UTF-8"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="EPUB/book.opf" media-type="application/oebps-package+xml"/></rootfiles></container>
        """)
        var manifest = "<item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/><item id=\"style\" href=\"style.css\" media-type=\"text/css\"/>"
        var spine = ""
        var links = ""
        for (index, asset) in assets.enumerated() {
            guard asset.path.hasPrefix("images/"), !asset.path.contains(".."), !asset.path.contains("\\") else { throw BookExportError.empty }
            manifest += "<item id=\"image\(index)\" href=\"\(xml(asset.path))\" media-type=\"\(xml(asset.mediaType))\"/>"
            let data = asset.data
            try archive.addEntry(with: "EPUB/" + asset.path, type: .file, uncompressedSize: Int64(data.count), compressionMethod: .deflate) { position, count in
                data.subdata(in: Int(position)..<min(Int(position) + count, data.count))
            }
        }
        for (index, chapter) in chapters.enumerated() {
            let id = "chapter\(index)"
            let title = xml(chapter.title)
            manifest += "<item id=\"\(id)\" href=\"\(id).xhtml\" media-type=\"application/xhtml+xml\"/>"
            spine += "<itemref idref=\"\(id)\"/>"
            links += "<li><a href=\"\(id).xhtml\">\(title)</a></li>"
            let paragraphs = chapter.html ?? chapter.content.components(separatedBy: .newlines)
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                .map { "<p>\(xml($0))</p>" }.joined()
            try add("EPUB/\(id).xhtml", """
            <?xml version="1.0" encoding="UTF-8"?><html xmlns="http://www.w3.org/1999/xhtml" xml:lang="zh-CN"><head><title>\(title)</title><link rel="stylesheet" href="style.css"/></head><body><h1>\(title)</h1>\(paragraphs)</body></html>
            """)
        }
        let modified = ISO8601DateFormatter().string(from: .now)
        try add("EPUB/book.opf", """
        <?xml version="1.0" encoding="UTF-8"?><package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="id">urn:uuid:\(UUID().uuidString)</dc:identifier><dc:title>\(xml(book.name))</dc:title><dc:creator>\(xml(book.author))</dc:creator><dc:language>zh-CN</dc:language><dc:source>\(xml(book.bookURL))</dc:source><meta property="dcterms:modified">\(modified)</meta></metadata><manifest>\(manifest)</manifest><spine>\(spine)</spine></package>
        """)
        try add("EPUB/nav.xhtml", """
        <?xml version="1.0" encoding="UTF-8"?><html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>目录</title></head><body><nav epub:type="toc"><h1>目录</h1><ol>\(links)</ol></nav></body></html>
        """)
        try add("EPUB/style.css", SourceChapterDocument.style)
        guard let data = archive.data else { throw BookExportError.empty }
        return data
    }

    static func xml(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}

enum BookExportError: LocalizedError {
    case empty, tooLarge, missing(Int), media(String)
    var errorDescription: String? {
        switch self {
        case .empty: "没有完整正文可导出，请先下载全书。"
        case .tooLarge: "全书正文超过 64 MB，暂时无法导出。"
        case .missing(let count): "还有 \(count) 章尚未下载，请先下载全书，完成后再导出。"
        case .media(let reason): "插图导出未完成：\(reason)"
        }
    }
}

struct EPUBExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.epub] }
    let data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw BookExportError.empty }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
