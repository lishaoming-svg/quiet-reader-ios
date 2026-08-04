import Foundation

enum URLTemplateRenderer {
    static func render(
        _ template: String,
        keyword: String = "",
        page: Int = 1
    ) throws -> URL {
        let allowed = CharacterSet.urlQueryAllowed
            .subtracting(CharacterSet(charactersIn: "&+=?#"))
        let encodedKeyword = keyword.addingPercentEncoding(withAllowedCharacters: allowed) ?? keyword
        let rendered = template
            .replacingOccurrences(of: "{{key}}", with: encodedKeyword)
            .replacingOccurrences(of: "{{keyword}}", with: encodedKeyword)
            .replacingOccurrences(of: "{{page}}", with: String(page))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let url = URL(string: rendered),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw SourceEngineError.invalidURL(rendered)
        }
        return url
    }

    static func absoluteURL(_ value: String, relativeTo baseURL: URL) -> String {
        guard let trimmed = value.nilIfBlank else { return "" }
        return URL(string: trimmed, relativeTo: baseURL)?.absoluteURL.absoluteString ?? trimmed
    }
}
