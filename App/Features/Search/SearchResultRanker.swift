import Foundation

enum SearchResultRanker {
    static func rank(_ books: [SearchBook], keyword: String) -> [SearchBook] {
        let keyword = normalized(keyword)
        guard !keyword.isEmpty else { return books.filter { !isPromotion($0) } }

        return books.enumerated()
            .filter { !isPromotion($0.element) }
            .sorted { left, right in
                let leftScore = relevance(of: left.element, to: keyword)
                let rightScore = relevance(of: right.element, to: keyword)
                return leftScore == rightScore ? left.offset < right.offset : leftScore < rightScore
            }
            .map(\.element)
    }

    private static func relevance(of book: SearchBook, to keyword: String) -> Int {
        let name = normalized(book.name)
        let author = normalized(book.author)
        let intro = normalized(book.intro)

        if name == keyword || author == keyword { return 0 }
        if name.hasPrefix(keyword) || author.hasPrefix(keyword) { return 1 }
        if name.contains(keyword) || author.contains(keyword) { return 2 }
        if intro.contains(keyword) { return 3 }
        return 4
    }

    private static func isPromotion(_ book: SearchBook) -> Bool {
        let text = normalized("\(book.name) \(book.intro)")
        return text.contains("打赏后获取更多搜索资源")
            || (text.contains("打赏") && text.contains("搜索资源") && text.contains("@vip"))
    }

    private static func normalized(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: .current
            )
    }
}

struct SearchBookGroup: Identifiable, Sendable {
    let id: String
    var books: [SearchBook]

    var primary: SearchBook { books[0] }
    var sourceCount: Int { Set(books.map(\.sourceID)).count }
    var sourceNames: String { books.map(\.sourceName).joined(separator: "、") }
}

enum SearchResultGrouper {
    static func group(_ rankedBooks: [SearchBook]) -> [SearchBookGroup] {
        var groupIndexes: [String: Int] = [:]
        var groups: [SearchBookGroup] = []

        for book in rankedBooks {
            let key = identityKey(for: book)
            if let index = groupIndexes[key] {
                groups[index].books.append(book)
            } else {
                groupIndexes[key] = groups.count
                groups.append(SearchBookGroup(id: key, books: [book]))
            }
        }
        return groups
    }

    private static func identityKey(for book: SearchBook) -> String {
        "\(canonicalName(book.name))::\(canonicalAuthor(book.author))"
    }

    private static func canonicalName(_ value: String) -> String {
        let base = value.components(separatedBy: "_").first ?? value
        return canonical(base.replacingOccurrences(
            of: "【(?:完结|全集)】|\\((?:完结|全集)\\)",
            with: "",
            options: .regularExpression
        ))
    }

    private static func canonicalAuthor(_ value: String) -> String {
        canonical(value.replacingOccurrences(of: "作者", with: ""))
    }

    private static func canonical(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: .current
            )
            .replacingOccurrences(
                of: "[\\s\\p{P}\\p{S}]",
                with: "",
                options: .regularExpression
            )
    }
}
