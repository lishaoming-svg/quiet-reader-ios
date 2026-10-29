import CryptoKit
import Foundation
import ImageIO
import KindleDocumentKit
import PDFKit
import SwiftSoup
import UniformTypeIdentifiers

struct LocalBookImport: Sendable {
    let book: SearchBook
    let chapters: [BookChapter]
}

enum LocalBookImporter {
    static let supportedExtensions = ["epub", "txt", "docx", "doc", "mobi", "azw", "azw3", "pdf"]
    static let maximumFileSize = 256 * 1_024 * 1_024
    static var contentTypes: [UTType] {
        supportedExtensions.compactMap { UTType(filenameExtension: $0) }
    }

    static func prepare(url: URL, root: URL = LocalBookStorage.root) throws -> LocalBookImport {
        let format = url.pathExtension.lowercased()
        guard supportedExtensions.contains(format) else { throw LocalBookError.unsupported }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?
        var result: Result<Data, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinated in
            result = Result {
                let size = try coordinated.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= maximumFileSize else { throw LocalBookError.tooLarge }
                let data = try Data(contentsOf: coordinated)
                guard data.count <= maximumFileSize else { throw LocalBookError.tooLarge }
                return data
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw LocalBookError.invalid }
        return try prepare(data: result.get(), filename: url.lastPathComponent, root: root)
    }

    static func prepare(data: Data, filename: String, root: URL = LocalBookStorage.root) throws -> LocalBookImport {
        guard data.count <= maximumFileSize else { throw LocalBookError.tooLarge }
        try Task.checkCancellation()
        let format = (filename as NSString).pathExtension.lowercased()
        guard supportedExtensions.contains(format) else { throw LocalBookError.unsupported }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let fallbackTitle = (filename as NSString).deletingPathExtension
        if format == "epub" {
            return try LocalBookStorage.save(EPUBDocumentParser.parse(data, fallbackTitle: fallbackTitle), digest: digest, root: root)
        }
        if format == "pdf" {
            guard let pdf = PDFDocument(data: data), pdf.pageCount > 0 else { throw LocalBookError.invalid }
            guard !pdf.isLocked else { throw LocalBookError.encrypted }
            let chapters = (0..<pdf.pageCount).map { index in
                LocalBookDocument.Chapter(title: "第 \(index + 1) 页", content: pdf.page(at: index)?.string?.nilIfBlank ?? "第 \(index + 1) 页")
            }
            return try LocalBookStorage.save(LocalBookDocument(title: pdf.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String ?? fallbackTitle,
                author: pdf.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String ?? "", format: "PDF", chapters: chapters,
                cover: pdf.page(at: 0)?.thumbnail(of: CGSize(width: 320, height: 480), for: .mediaBox).jpegData(compressionQuality: 0.85), pdfData: data), digest: digest, root: root)
        }
        var title = fallbackTitle
        var author = ""
        var cover: Data?
        var headings: [String] = []
        var text: String
        switch format {
        case "txt": text = try LocalTextDecoder.decode(data)
        case "docx":
            // Office password encryption wraps DOCX in a compound binary container.
            if data.starts(with: [0xD0, 0xCF, 0x11, 0xE0]) { throw LocalBookError.encrypted }
            let word = try WordDocumentParser.parseDOCX(data)
            text = word.text; title = word.title ?? title; author = word.author ?? ""; headings = word.headings
        case "doc": text = try LegacyWordParser.text(from: data)
        default:
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try data.write(to: temporary, options: .atomic)
            defer { try? FileManager.default.removeItem(at: temporary) }
            do {
                let kindle = try KindleDocument.read(at: temporary)
                title = kindle.title?.nilIfBlank ?? title
                author = kindle.author?.nilIfBlank ?? ""
                cover = kindle.cover
                text = try kindle.htmlParts.map { html in
                    let document = try SwiftSoup.parse(html)
                    try document.select("script, style, noscript").remove()
                    return ReadableContentFormatter.plainText(from: try document.body()?.html() ?? "")
                }.joined(separator: "\n\n")
            } catch KindleDocument.ReadError.encrypted { throw LocalBookError.encrypted
            } catch KindleDocument.ReadError.tooLarge { throw LocalBookError.tooLarge
            } catch is CancellationError { throw CancellationError()
            } catch { throw LocalBookError.invalid }
        }
        try Task.checkCancellation()
        title = title.nilIfBlank ?? "未命名图书"
        let chapters = try LocalChapterSplitter.split(text, title: title, headings: headings)
        let document = LocalBookDocument(title: title, author: author, format: format.uppercased(),
                                        chapters: chapters, cover: cover)
        return try LocalBookStorage.save(document, digest: digest, root: root)
    }
}

enum LocalBookStorage {
    static let sourceID = "quietreader.local.documents"
    static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalBooks", isDirectory: true)
    }
    static let source: BookSourceDefinition = {
        let json = #"{"sourceId":"quietreader.local.documents","bookSourceUrl":"quietreader-local://library","bookSourceName":"本地图书"}"#
        return try! JSONDecoder().decode(BookSourceDefinition.self, from: Data(json.utf8))
    }()

    private struct Manifest: Codable {
        var version = 1
        let title: String
        let author: String
        let format: String
        let chapterTitles: [String]
        let hasCover: Bool
    }

    static func save(_ document: LocalBookDocument, digest: String, root: URL) throws -> LocalBookImport {
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        let staging = root.appendingPathComponent(".import-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: staging) }
        for (index, chapter) in document.chapters.enumerated() {
            try Task.checkCancellation()
            try Data(bodyText(chapter).utf8).write(to: staging.appendingPathComponent("\(index).txt"), options: .atomic)
        }
        let cover = document.cover.flatMap(thumbnail)
        if let publication = document.publicationData {
            try publication.write(to: staging.appendingPathComponent("publication.epub"), options: .atomic)
        }
        if let pdf = document.pdfData { try pdf.write(to: staging.appendingPathComponent("publication.pdf"), options: .atomic) }
        if let cover { try cover.write(to: staging.appendingPathComponent("cover.jpg"), options: .atomic) }
        let manifest = Manifest(title: document.title, author: document.author, format: document.format,
                                chapterTitles: document.chapters.map(\.title), hasCover: cover != nil)
        try JSONEncoder().encode(manifest).write(to: staging.appendingPathComponent("manifest.json"), options: .atomic)
        let destination = root.appendingPathComponent(digest, isDirectory: true)
        if manager.fileExists(atPath: destination.path) {
            // Restore missing/corrupt files without changing the stable book/locator identifiers.
            let backup = root.appendingPathComponent(".backup-\(UUID().uuidString)")
            try manager.moveItem(at: destination, to: backup)
            do { try manager.moveItem(at: staging, to: destination) }
            catch { try? manager.moveItem(at: backup, to: destination); throw error }
            try? manager.removeItem(at: backup)
        } else { try manager.moveItem(at: staging, to: destination) }
        return makeImport(manifest, digest: digest, root: root)
    }

    static func book(at address: String, root: URL = LocalBookStorage.root) throws -> LocalBookImport {
        let digest = try identifier(from: address)
        let data: Data
        do { data = try Data(contentsOf: root.appendingPathComponent(digest).appendingPathComponent("manifest.json")) }
        catch { throw LocalBookError.missing }
        guard let manifest = try? JSONDecoder().decode(Manifest.self, from: data), manifest.version == 1,
              !manifest.chapterTitles.isEmpty else { throw LocalBookError.missing }
        return makeImport(manifest, digest: digest, root: root)
    }

    static func content(at address: String, root: URL = LocalBookStorage.root) throws -> String {
        let digest = try identifier(from: address)
        guard let url = URL(string: address), let last = url.pathComponents.last,
              let index = Int(last), index >= 0 else { throw LocalBookError.missing }
        let imported = try book(at: address, root: root)
        guard imported.chapters.indices.contains(index) else { throw LocalBookError.missing }
        do { return try String(contentsOf: root.appendingPathComponent(digest).appendingPathComponent("\(index).txt"), encoding: .utf8) }
        catch { throw LocalBookError.missing }
    }

    static func coverURL(for address: String) -> String {
        guard let digest = try? identifier(from: address) else { return "" }
        let url = root.appendingPathComponent(digest).appendingPathComponent("cover.jpg")
        return FileManager.default.fileExists(atPath: url.path) ? url.absoluteString : ""
    }

    static func publicationURL(for address: String, root: URL = LocalBookStorage.root) throws -> URL {
        let url = root.appendingPathComponent(try identifier(from: address)).appendingPathComponent("publication.epub")
        guard FileManager.default.fileExists(atPath: url.path) else { throw LocalBookError.missing }
        return url
    }
    static func pdfURL(for address: String, root: URL = LocalBookStorage.root) throws -> URL {
        let url = root.appendingPathComponent(try identifier(from: address)).appendingPathComponent("publication.pdf")
        guard FileManager.default.fileExists(atPath: url.path) else { throw LocalBookError.missing }
        return url
    }

    static func remove(address: String, root: URL = LocalBookStorage.root) throws {
        let digest = try identifier(from: address)
        let url = root.appendingPathComponent(digest, isDirectory: true)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    private static func identifier(from address: String) throws -> String {
        guard let url = URL(string: address), url.scheme == "quietreader-local", let digest = url.host,
              digest.count == 64, digest.allSatisfy({ "0123456789abcdef".contains($0) }) else { throw LocalBookError.missing }
        return digest
    }

    private static func makeImport(_ manifest: Manifest, digest: String, root: URL) -> LocalBookImport {
        let address = "quietreader-local://\(digest)"
        let cover = manifest.hasCover ? root.appendingPathComponent(digest).appendingPathComponent("cover.jpg").absoluteString : ""
        return LocalBookImport(book: SearchBook(sourceID: sourceID, sourceName: "本地图书", name: manifest.title,
            author: manifest.author, intro: "", kind: manifest.format, lastChapter: "", updateTime: "",
            bookURL: address, coverURL: cover, tocURL: address),
            chapters: manifest.chapterTitles.enumerated().map { BookChapter(title: $0.element, url: "\(address)/\($0.offset)", index: $0.offset) })
    }

    private static func thumbnail(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 640,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    private static func bodyText(_ chapter: LocalBookDocument.Chapter) -> String {
        let lines = chapter.content.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == chapter.title else { return chapter.content }
        let body = lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        // Keep heading-only sections readable; normal chapters render their title in reader chrome.
        return body.isEmpty ? chapter.content : body
    }
}

extension BookRecord {
    var isLocal: Bool { sourceID == LocalBookStorage.sourceID }
    var resolvedCoverURL: String { isLocal ? LocalBookStorage.coverURL(for: bookURL) : coverURL }
}
