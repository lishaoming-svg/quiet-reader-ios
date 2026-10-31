import Foundation

enum URLTemplateRenderer {
    static func render(
        _ template: String,
        keyword: String = "",
        page: Int = 1,
        relativeTo baseURLString: String? = nil
    ) throws -> URL {
        let original = LegadoRequest.split(template)
        let options = try LegadoRequest.options(original.1)
        let encodedKeyword = try LegadoRequest.encodedKeyword(keyword, options: options)
        var rendered = template
            .replacingOccurrences(of: "{{key}}", with: encodedKeyword)
            .replacingOccurrences(of: "{{keyword}}", with: encodedKeyword)
            .replacingOccurrences(of: "{{page-1}}", with: String(max(0, page - 1)))
            .replacingOccurrences(of: "{{page+1}}", with: String(page + 1))
            .replacingOccurrences(of: "{{page}}", with: String(page))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let expressions = try NSRegularExpression(pattern: #"\{\{([^{}]+)\}\}"#)
        for match in expressions.matches(in: rendered, range: NSRange(rendered.startIndex..., in: rendered)).reversed() {
            guard let content = Range(match.range(at: 1), in: rendered), let whole = Range(match.range, in: rendered) else { continue }
            var expression = try PaginationExpression(String(rendered[content]), page: page)
            rendered.replaceSubrange(whole, with: String(try expression.value()))
        }
        let parts = LegadoRequest.split(rendered)

        let baseURL = baseURLString.flatMap(URL.init(string:))
        guard var url = URL(string: parts.0, relativeTo: baseURL)?.absoluteURL,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw SourceEngineError.invalidURL(rendered)
        }
        if let options = parts.1 {
            _ = try LegadoRequest.options(options)
            var components = URLComponents(url: url, resolvingAgainstBaseURL: true)!
            components.fragment = LegadoRequest.fragmentPrefix + Data(options.utf8).base64EncodedString()
            guard let encoded = components.url else { throw SourceEngineError.invalidURL(rendered) }
            url = encoded
        }
        return url
    }

    static func absoluteURL(_ value: String, relativeTo baseURL: URL) -> String {
        guard let trimmed = value.nilIfBlank else { return "" }
        if LegadoRequest.split(trimmed).1 != nil { return (try? render(trimmed, relativeTo: baseURL.absoluteString))?.absoluteString ?? trimmed }
        return URL(string: trimmed, relativeTo: baseURL)?.absoluteURL.absoluteString ?? trimmed
    }
}
