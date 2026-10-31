import CryptoKit
import Foundation
import ReadiumShared
import SwiftData
import SwiftSoup

@MainActor
final class SourceChapterRepository {
    let book: SearchBook
    let chapters: [BookChapter]
    let source: BookSourceDefinition
    let context: ModelContext
    var failure: (String) -> Void = { _ in }
    private var pending: [Int: Task<SourceChapterDocument, Error>] = [:]

    init(book: SearchBook, chapters: [BookChapter], source: BookSourceDefinition, context: ModelContext) {
        self.book = book; self.chapters = chapters; self.source = source; self.context = context
    }

    func load(_ index: Int) async throws -> SourceChapterDocument {
        guard chapters.indices.contains(index) else { throw SourceEngineError.emptyContent }
        let chapter = chapters[index], key = "\(source.id)::\(chapters[index].url)"
        var query = FetchDescriptor<ChapterCacheRecord>(predicate: #Predicate { $0.cacheKey == key })
        query.fetchLimit = 1
        let cached = try context.fetch(query).first
        if let cached, let html = cached.htmlContent {
            return SourceChapterDocument(text: cached.content, html: html)
        }
        if let task = pending[index] { return try await task.value }
        let source = self.source
        let task = Task { try await SourceEngine().loadDocument(chapter: chapter, source: source) }
        pending[index] = task
        defer { pending.removeValue(forKey: index) }
        do {
            let document = try await task.value
            let record = cached ?? ChapterCacheRecord(sourceID: source.id, bookID: book.id, chapter: chapter, content: document.text)
            record.content = document.text; record.htmlContent = document.html; record.cachedAt = .now; record.downloadError = nil
            if record.modelContext == nil { context.insert(record) }
            try context.save()
            return document
        } catch is CancellationError { throw CancellationError() }
        catch {
            if let cached, !cached.content.isEmpty { return SourceChapterDocument(text: cached.content) }
            failure("\(chapter.title)：\(error.localizedDescription)")
            throw error
        }
    }

    func publication() -> Publication {
        let links = chapters.enumerated().map { index, chapter in
            ReadiumShared.Link(href: "chapter\(index).xhtml", mediaType: .xhtml, title: chapter.title)
        }
        let manifest = Manifest(metadata: Metadata(identifier: book.id, conformsTo: [.epub], title: book.name,
            languages: ["zh-CN"], layout: .reflowable, readingProgression: .ltr),
            readingOrder: links, resources: [ReadiumShared.Link(href: "reader.css", mediaType: .css)], tableOfContents: links)
        let container = SourcePublicationContainer(chapters: chapters, source: source) { [self] index in try await load(index) }
        return Publication(manifest: manifest, container: container,
            servicesBuilder: PublicationServicesBuilder(positions: PerResourcePositionsService.makeFactory(fallbackMediaType: .xhtml)))
    }
}

/// Readium requests only the current/adjacent chapter. Its resource server also
/// serves cached images, so online books use the same renderer as imported EPUB.
final class SourcePublicationContainer: Container {
    let sourceURL: AbsoluteURL? = nil
    let entries: Set<AnyURL>
    private let chapters: [BookChapter]
    private let source: BookSourceDefinition
    private let load: @Sendable (Int) async throws -> SourceChapterDocument

    init(chapters: [BookChapter], source: BookSourceDefinition,
         load: @escaping @Sendable (Int) async throws -> SourceChapterDocument) {
        self.chapters = chapters; self.source = source; self.load = load
        entries = Set((chapters.indices.map { "chapter\($0).xhtml" } + ["reader.css"]).compactMap { AnyURL(string: $0) })
    }

    subscript(url: any URLConvertible) -> Resource? {
        let path = url.anyURL.removingQuery().removingFragment().string.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path == "reader.css" { return DataResource(string: SourceChapterDocument.style) }
        if path == "reader-font.ttf", let name = UserDefaults.standard.string(forKey: "reader.importedFont"),
           let font = ImportedFontStore.fonts.first(where: { $0.postScriptName == name }) {
            let file = ImportedFontStore.root.appendingPathComponent(font.id + ".font")
            return DataResource { do { return .success(try Data(contentsOf: file)) } catch { return .failure(.decoding(error)) } }
        }
        if path.hasPrefix("image-"), let remote = Self.imageURL(path) {
            let source = self.source
            return DataResource {
                do { return .success(try await SourceMediaStore.shared.data(remote, source: source)) }
                catch { return .failure(ReadError.wrap(error) ?? .decoding(error)) }
            }
        }
        guard path.hasPrefix("chapter"), path.hasSuffix(".xhtml"),
              let index = Int(path.dropFirst(7).dropLast(6)), chapters.indices.contains(index) else { return nil }
        let title = chapters[index].title, load = self.load
        return DataResource {
            do {
                let document = try await load(index)
                let html = try Self.rewriteImages(document.html) { Self.imagePath($0) }
                return .success(Data(Self.page(title: title, body: html).utf8))
            } catch { return .failure(ReadError.wrap(error) ?? .decoding(error)) }
        }
    }

    static func page(title: String, body: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?><html xmlns="http://www.w3.org/1999/xhtml" lang="zh-CN"><head><meta name="viewport" content="width=device-width,initial-scale=1"/><meta http-equiv="Content-Security-Policy" content="default-src 'none';style-src 'self' 'unsafe-inline';img-src 'self' data:;font-src 'self' data:;"/><title>\(BookEPUBExporter.xml(title))</title><link rel="stylesheet" href="reader.css"/></head><body><h1>\(BookEPUBExporter.xml(title))</h1>\(body)</body></html>
        """
    }
    static func imagePath(_ url: URL) -> String {
        let token = Data(url.absoluteString.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "=", with: "")
        let ext = ["png", "gif", "webp", "avif", "svg", "jpeg", "jpg"].contains(url.pathExtension.lowercased()) ? url.pathExtension.lowercased() : "jpg"
        return "image-\(token).\(ext)"
    }
    static func imageURL(_ path: String) -> URL? {
        let token = String(path.dropFirst(6).split(separator: ".").first ?? "")
        let base64 = token.replacingOccurrences(of: "_", with: "/").replacingOccurrences(of: "-", with: "+")
        guard let data = Data(base64Encoded: base64 + String(repeating: "=", count: (4 - base64.count % 4) % 4)),
              let text = String(data: data, encoding: .utf8), let url = URL(string: text),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }
    static func rewriteImages(_ html: String, path: (URL) -> String) throws -> String {
        let document = try SwiftSoup.parseBodyFragment(html)
        for image in try document.select("img[src]").array() {
            if let url = URL(string: try image.attr("src")), ["http", "https"].contains(url.scheme ?? "") {
                try image.attr("src", path(url))
            }
        }
        document.outputSettings().syntax(syntax: .xml).escapeMode(.xhtml).prettyPrint(pretty: false)
        return try document.body()?.html() ?? html
    }
}

actor SourceMediaStore {
    static let shared = SourceMediaStore()
    func data(_ url: URL, source: BookSourceDefinition) async throws -> Data {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("SourceMedia")
        let key = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        let file = root.appendingPathComponent(key)
        if FileManager.default.fileExists(atPath: file.path) { return try Data(contentsOf: file) }
        var imageSource = source
        // Source credentials must never be forwarded to an unrelated image host.
        if url.host != URL(string: source.bookSourceUrl)?.host { imageSource.header = nil }
        let result = try await SourceHTTPClient.shared.fetch(url, source: imageSource,
            headers: ["Referer": NativeLofterAdapter.accepts(source) ? "https://www.lofter.com/" : source.bookSourceUrl])
        guard result.contentType.lowercased().hasPrefix("image/"), result.data.count <= 20 * 1024 * 1024 else {
            throw SourceEngineError.requestFailed("插图无法读取，请检查图片地址与访问权限。")
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try result.data.write(to: file, options: .atomic)
        return result.data
    }
}
