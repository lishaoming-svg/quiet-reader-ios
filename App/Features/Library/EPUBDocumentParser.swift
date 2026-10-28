import Foundation
import ZIPFoundation
import SwiftSoup

/// Indexes the book for the library. The untouched archive is used by Readium to render
/// publisher CSS, illustrations, embedded/obfuscated fonts, ruby and fixed layouts.
enum EPUBDocumentParser {
    static func parse(_ data: Data, fallbackTitle: String) throws -> LocalBookDocument {
        guard let archive = try? Archive(data: data, accessMode: .read) else { throw LocalBookError.invalid }
        var expanded: UInt64 = 0
        for entry in archive {
            guard !entry.path.hasPrefix("/"), !entry.path.contains("\\"),
                  !entry.path.split(separator: "/").contains(".."), entry.type != .symlink else { throw LocalBookError.invalid }
            expanded += UInt64(entry.uncompressedSize)
            guard expanded <= 512 * 1_024 * 1_024 else { throw LocalBookError.tooLarge }
        }
        // Font obfuscation in encryption.xml is valid EPUB and is handled by Readium.
        if archive["META-INF/license.lcpl"] != nil || archive["META-INF/rights.xml"] != nil { throw LocalBookError.encrypted }
        let container = try xml(read("META-INF/container.xml", in: archive))
        guard let packageName = container.items.first(where: { $0.name == "rootfile" })?.attributes["full-path"] else { throw LocalBookError.invalid }
        let packagePath = try path(packageName, relativeTo: "")
        let package = try xml(read(packagePath, in: archive))
        let base = (packagePath as NSString).deletingLastPathComponent
        let items = package.items.filter { $0.name == "item" }
        let byID = Dictionary(items.compactMap { node -> (String, XMLIndex.Node)? in
            node.attributes["id"].map { ($0, node) }
        }, uniquingKeysWith: { first, _ in first })
        var labels: [String: String] = [:]
        if let nav = items.first(where: { ($0.attributes["properties"] ?? "").split(separator: " ").contains("nav") }),
           let href = nav.attributes["href"] {
            let navPath = try path(href, relativeTo: base)
            let html = try SwiftSoup.parse(String(decoding: read(navPath, in: archive), as: UTF8.self))
            for link in try html.select("nav a[href]") {
                let address = try path(link.attr("href"), relativeTo: (navPath as NSString).deletingLastPathComponent)
                if labels[address] == nil { labels[address] = try link.text() }
            }
        }
        var chapters: [LocalBookDocument.Chapter] = []
        var indexedBytes = 0
        for spine in package.items where spine.name == "itemref" && spine.attributes["linear"] != "no" {
            try Task.checkCancellation()
            guard let id = spine.attributes["idref"], let item = byID[id], let href = item.attributes["href"] else { throw LocalBookError.invalid }
            let address = try path(href, relativeTo: base)
            let chapterData = try read(address, in: archive)
            indexedBytes += chapterData.count
            guard indexedBytes <= 64 * 1_024 * 1_024 else { throw LocalBookError.tooLarge }
            let html = try SwiftSoup.parse(String(decoding: chapterData, as: UTF8.self))
            try html.select("script, style, noscript").remove()
            let htmlTitle = try html.select("h1, h2, title").first()?.text()
            let heading = labels[address]?.nilIfBlank ?? htmlTitle?.nilIfBlank
                ?? "第 \(chapters.count + 1) 节"
            let text = ReadableContentFormatter.plainText(from: try html.body()?.html() ?? "")
            // Image-only and fixed-layout books remain valid and open in the rich navigator.
            chapters.append(.init(title: heading, content: text.nilIfBlank ?? heading))
        }
        guard !chapters.isEmpty else { throw LocalBookError.invalid }
        var cover: Data?
        let coverID = package.items.first(where: { $0.name == "meta" && $0.attributes["name"] == "cover" })?.attributes["content"]
        if let item = items.first(where: { ($0.attributes["properties"] ?? "").split(separator: " ").contains("cover-image") }) ?? coverID.flatMap({ byID[$0] }),
           let href = item.attributes["href"] {
            cover = try read(path(href, relativeTo: base), in: archive, limit: 16 * 1_024 * 1_024)
        }
        return LocalBookDocument(title: package.items.first(where: { $0.name == "title" })?.text.nilIfBlank ?? fallbackTitle,
            author: package.items.filter { $0.name == "creator" }.map(\.text).joined(separator: "、"),
            format: "EPUB", chapters: chapters, cover: cover, publicationData: data)
    }

    static func path(_ href: String, relativeTo base: String) throws -> String {
        let raw = href.components(separatedBy: "#")[0].components(separatedBy: "?")[0]
        let decoded = raw.removingPercentEncoding ?? raw
        guard !decoded.hasPrefix("/"), !decoded.contains(":"), !decoded.contains("\\") else { throw LocalBookError.invalid }
        var parts = base.split(separator: "/").map(String.init)
        for part in decoded.split(separator: "/") {
            if part == "." { continue }
            if part == ".." { guard !parts.isEmpty else { throw LocalBookError.invalid }; parts.removeLast() }
            else { parts.append(String(part)) }
        }
        guard !parts.isEmpty else { throw LocalBookError.invalid }
        return parts.joined(separator: "/")
    }

    private static func read(_ path: String, in archive: Archive, limit: Int = 8 * 1_024 * 1_024) throws -> Data {
        guard let entry = archive[path], entry.type == .file else { throw LocalBookError.invalid }
        guard entry.uncompressedSize <= limit else { throw LocalBookError.tooLarge }
        var data = Data()
        let crc = try archive.extract(entry) { chunk in
            guard chunk.count <= limit - data.count else { throw LocalBookError.tooLarge }
            data.append(chunk)
        }
        guard crc == entry.checksum else { throw LocalBookError.invalid }
        return data
    }
    private static func xml(_ data: Data) throws -> XMLIndex {
        let index = XMLIndex()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = index
        guard parser.parse() else { throw LocalBookError.invalid }
        return index
    }
}

private final class XMLIndex: NSObject, XMLParserDelegate {
    struct Node { let name: String; let attributes: [String: String]; var text = "" }
    var items: [Node] = []
    private var stack: [Int] = []
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        items.append(Node(name: elementName.components(separatedBy: ":").last ?? elementName, attributes: attributes))
        stack.append(items.count - 1)
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { for index in stack { items[index].text += string } }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) { _ = stack.popLast() }
}
