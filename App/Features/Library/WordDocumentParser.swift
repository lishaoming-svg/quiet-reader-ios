import Foundation
import ZIPFoundation

enum WordDocumentParser {
    static func parseDOCX(_ data: Data) throws -> (text: String, title: String?, author: String?, headings: [String]) {
        guard let archive = try? Archive(data: data, accessMode: .read) else { throw LocalBookError.invalid }
        if archive["EncryptedPackage"] != nil { throw LocalBookError.encrypted }
        guard let entry = archive["word/document.xml"] else { throw LocalBookError.invalid }
        let document = try extract(entry, from: archive)
        let delegate = WordXMLText()
        let parser = XMLParser(data: document)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse() else { throw LocalBookError.invalid }
        var title: String?
        var author: String?
        if let core = archive["docProps/core.xml"] {
            let metadata = WordXMLText(metadata: true)
            let xml = XMLParser(data: try extract(core, from: archive))
            xml.shouldResolveExternalEntities = false; xml.delegate = metadata
            if xml.parse() { title = metadata.title.nilIfBlank; author = metadata.author.nilIfBlank }
        }
        return (delegate.text, title, author, delegate.headings)
    }

    private static func extract(_ entry: Entry, from archive: Archive) throws -> Data {
        let limit = 32 * 1_024 * 1_024
        guard entry.type == .file else { throw LocalBookError.invalid }
        guard entry.uncompressedSize <= limit else { throw LocalBookError.tooLarge }
        var result = Data()
        let checksum = try archive.extract(entry) { chunk in
            guard result.count <= limit - chunk.count else { throw LocalBookError.tooLarge }
            result.append(chunk)
        }
        guard checksum == entry.checksum else { throw LocalBookError.invalid }
        return result
    }
}

private final class WordXMLText: NSObject, XMLParserDelegate {
    private var paragraph = ""
    private var inText = false
    private var deletedDepth = 0
    private var element = ""
    private let metadata: Bool
    private var isHeading = false
    var headings: [String] = []
    var text = ""
    var title = ""
    var author = ""
    init(metadata: Bool = false) { self.metadata = metadata }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        element = name.components(separatedBy: ":").last ?? name
        if element == "del" { deletedDepth += 1 }
        guard !metadata else { return }
        if element == "p" { isHeading = false }
        if element == "pStyle", let value = attributes.first(where: { $0.key == "w:val" || $0.key == "val" })?.value {
            isHeading = value.lowercased().hasPrefix("heading") || value.hasPrefix("标题")
        }
        if element == "t", deletedDepth == 0 { inText = true }
        if element == "tab" { paragraph += "\t" }
        if element == "br" || element == "cr" { paragraph += "\n" }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if metadata {
            if element == "title" { title += string }
            if element == "creator" { author += string }
        } else if inText { paragraph += string }
    }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let local = name.components(separatedBy: ":").last ?? name
        if local == "t" { inText = false }
        if local == "del" { deletedDepth = max(0, deletedDepth - 1) }
        if local == "p" {
            if isHeading, let heading = paragraph.nilIfBlank { headings.append(heading) }
            text += paragraph + "\n"; paragraph = ""
        }
        if local == "tc" { text += "\t" }
        if local == "tr" { text += "\n" }
        element = ""
    }
    func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? { nil }
}
