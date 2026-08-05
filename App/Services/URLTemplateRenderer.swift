import Foundation

enum URLTemplateRenderer {
    static func render(
        _ template: String,
        keyword: String = "",
        page: Int = 1,
        relativeTo baseURLString: String? = nil
    ) throws -> URL {
        let allowed = CharacterSet.urlQueryAllowed
            .subtracting(CharacterSet(charactersIn: "&+=?#"))
        let encodedKeyword = keyword.addingPercentEncoding(withAllowedCharacters: allowed) ?? keyword
        let rendered = template
            .replacingOccurrences(of: "{{key}}", with: encodedKeyword)
            .replacingOccurrences(of: "{{keyword}}", with: encodedKeyword)
            .replacingOccurrences(of: "{{page-1}}", with: String(max(0, page - 1)))
            .replacingOccurrences(of: "{{page+1}}", with: String(page + 1))
            .replacingOccurrences(of: "{{page}}", with: String(page))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let baseURL = baseURLString.flatMap(URL.init(string:))
        guard let url = URL(string: rendered, relativeTo: baseURL)?.absoluteURL,
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
