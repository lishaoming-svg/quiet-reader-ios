import Foundation
import SwiftSoup

struct SourceChapterDocument: Sendable, Equatable {
    var text: String
    var html: String

    init(text: String, html: String? = nil) {
        self.text = text
        self.html = html ?? Self.paragraphs(text)
    }

    static func paragraphs(_ text: String) -> String {
        text.components(separatedBy: .newlines).filter { !$0.isEmpty }
            .map { "<p>\(BookEPUBExporter.xml($0))</p>" }.joined()
    }

    static func sanitized(_ html: String, baseURL: URL) throws -> SourceChapterDocument {
        let markup = html.range(of: #"<[a-zA-Z][^>]*>"#, options: .regularExpression) == nil ? paragraphs(html) : html
        let document = try SwiftSoup.parseBodyFragment(markup, baseURL.absoluteString)
        try document.select("script,style,link,meta,base,iframe,frame,object,embed,form,input,button,textarea,select,svg,math").remove()
        for node in try document.getAllElements().array() {
            if node.tagName() == "img" {
                for key in ["data-src", "data-original", "_src"] {
                    if let value = try node.attr(key).nilIfBlank { try node.attr("src", value); break }
                }
            }
            for attribute in node.getAttributes()?.asList() ?? [] {
                let key = attribute.getKey().lowercased()
                if !["style", "class", "id", "href", "src", "alt", "title", "colspan", "rowspan", "lang", "dir"].contains(key) {
                    try node.removeAttr(attribute.getKey())
                }
            }
            if node.hasAttr("style") {
                try node.attr("style", safeStyle(try node.attr("style")))
            }
            for key in ["href", "src"] where node.hasAttr(key) {
                let value = try node.attr(key)
                if key == "href", value.hasPrefix("#") { continue }
                if key == "src", value.hasPrefix("data:image/"), value.utf8.count < 2_000_000,
                   !value.lowercased().hasPrefix("data:image/svg") { continue }
                guard let url = URL(string: value, relativeTo: baseURL)?.absoluteURL,
                      ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                    try node.removeAttr(key); continue
                }
                try node.attr(key, url.absoluteString)
            }
        }
        document.outputSettings().syntax(syntax: .xml)
        let body = try document.body()?.html() ?? ""
        let text = ReadableTextNormalizer.normalize(ReadableContentFormatter.plainText(from: body))
        let hasImages = !(try document.select("img[src]")).isEmpty()
        guard !text.isEmpty || hasImages else { throw SourceEngineError.emptyContent }
        // Image-only posts are valid chapters; this string is the text index,
        // while the renderer and EPUB exporter retain their actual images.
        return SourceChapterDocument(text: text.isEmpty ? "[插图]" : text, html: body)
    }

    static func safeStyle(_ raw: String) -> String {
        let allowed: Set<String> = ["color", "background", "background-color", "font-family", "font-size", "font-weight", "font-style",
            "text-align", "text-indent", "text-decoration", "line-height", "letter-spacing", "white-space", "word-break",
            "border", "border-color", "border-width", "border-style", "border-radius", "border-top", "border-bottom",
            "margin", "margin-left", "margin-right", "margin-top", "margin-bottom", "padding", "padding-left", "padding-right",
            "padding-top", "padding-bottom", "width", "max-width", "height", "max-height", "display", "vertical-align", "float", "clear"]
        return raw.split(separator: ";").compactMap { declaration -> String? in
            let pair = declaration.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard pair.count == 2, allowed.contains(pair[0].lowercased()), pair[1].count < 256 else { return nil }
            let value = pair[1].lowercased()
            guard !["url", "expression", "javascript", "@", "\\", "<", ">"].contains(where: value.contains) else { return nil }
            return pair[0].lowercased() + ":" + pair[1]
        }.joined(separator: ";")
    }

    static let style = """
    html { -webkit-text-size-adjust:100%; }
    body { font-family:-apple-system,'PingFang SC',sans-serif;font-size:18px;font-weight:300;line-height:1.85;margin:0;padding:30px 26px;color:#3c3328; }
    p { margin:0 0 1em;text-indent:2em;text-align:justify; }
    h1 { font-size:1.4em;font-weight:400;text-align:center;margin:2em 0; }
    blockquote { margin:1em;padding:.5em 1em;border-left:2px solid #aaa; }
    img { display:block;max-width:100%;height:auto;object-fit:contain;margin:1em auto; }
    table { max-width:100%;border-collapse:collapse; } td,th { padding:.4em; }
    a { color:inherit; } ruby { ruby-position:over; }
    """
}
