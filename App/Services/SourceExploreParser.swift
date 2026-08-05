import Foundation

enum SourceExploreParser {
    static func categories(from rawValue: String?) -> [SourceExploreCategory] {
        guard let rawValue = rawValue?.nilIfBlank else { return [] }
        let jsonCategories = parseJSON(rawValue)
        return deduplicated(jsonCategories.isEmpty ? parseText(rawValue) : jsonCategories)
    }

    private static func parseJSON(_ rawValue: String) -> [SourceExploreCategory] {
        let sanitized = rawValue.replacingOccurrences(
            of: #",\s*([}\]])"#,
            with: "$1",
            options: .regularExpression
        )
        guard let data = sanitized.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return []
        }

        let items: [[String: Any]]
        if let array = object as? [[String: Any]] {
            items = array
        } else if let item = object as? [String: Any] {
            items = [item]
        } else {
            return []
        }

        return items.compactMap { item in
            guard let title = (item["title"] as? String)?.nilIfBlank,
                  let address = (item["url"] as? String)?.nilIfBlank else {
                return nil
            }
            return SourceExploreCategory(title: title, address: address)
        }
    }

    private static func parseText(_ rawValue: String) -> [SourceExploreCategory] {
        rawValue
            .replacingOccurrences(of: "&&", with: "\n")
            .components(separatedBy: .newlines)
            .compactMap { line in
                guard let separator = line.range(of: "::") else { return nil }
                let title = String(line[..<separator.lowerBound]).nilIfBlank
                let address = String(line[separator.upperBound...]).nilIfBlank
                guard let title, let address else { return nil }
                return SourceExploreCategory(title: title, address: address)
            }
    }

    private static func deduplicated(
        _ categories: [SourceExploreCategory]
    ) -> [SourceExploreCategory] {
        var seen = Set<String>()
        return categories.filter { seen.insert($0.id).inserted }
    }
}
