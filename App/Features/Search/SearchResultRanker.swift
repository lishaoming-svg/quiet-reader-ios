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
