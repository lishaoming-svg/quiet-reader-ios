import Foundation
import SwiftSoup

struct SourceEngine {
    private static let maximumTocPageCount = 100
    private static let maximumContentPageCount = 20
    private static let pageTitleRegex = try? NSRegularExpression(
        pattern: #"^\s*第?\s*\d+\s*页\s*$"#
    )
    private let client = SourceHTTPClient.shared
    private let extractor = RuleExtractor()

    func search(
        keyword: String,
        page: Int = 1,
        source: BookSourceDefinition
    ) async throws -> [SearchBook] {
        if NativeLofterAdapter.accepts(source) { return try await NativeLofterAdapter(source: source).search(keyword: keyword, page: page) }
        guard let template = source.searchUrl?.nilIfBlank,
              let rules = source.ruleSearch,
              rules.bookList?.nilIfBlank != nil else {
            return []
        }

        let url = try URLTemplateRenderer.render(
            template,
            keyword: keyword,
            page: page,
            relativeTo: source.bookSourceUrl
        )
        return try await loadBooks(at: url, rules: rules, source: source)
    }

    func explore(
        category: SourceExploreCategory,
        page: Int = 1,
        source: BookSourceDefinition
    ) async throws -> [SearchBook] {
        guard let rules = source.ruleExplore ?? source.ruleSearch,
              rules.bookList?.nilIfBlank != nil else {
            return []
        }

        let url = try URLTemplateRenderer.render(
            category.address,
            page: page,
            relativeTo: source.bookSourceUrl
        )
        return try await loadBooks(at: url, rules: rules, source: source)
    }

    private func loadBooks(
        at url: URL,
        rules: SearchRuleDefinition,
        source: BookSourceDefinition
    ) async throws -> [SearchBook] {
        guard let listRule = rules.bookList?.nilIfBlank else { return [] }
        let resource = try await client.fetch(url, source: source)
        let root = try extractor.root(from: resource)
        let nodes = try extractor.list(listRule, in: root)

        return try nodes.compactMap { node in
            let name = try extractor.string(rules.name, in: node)
            let bookURL = try extractor.string(rules.bookUrl, in: node, asURL: true)
            guard !name.isEmpty, !bookURL.isEmpty else { return nil }
            return SearchBook(
                sourceID: source.id,
                sourceName: source.bookSourceName,
                name: name,
                author: try extractor.string(rules.author, in: node),
                intro: try extractor.string(rules.intro, in: node),
                kind: try extractor.string(rules.kind, in: node),
                lastChapter: try extractor.string(rules.lastChapter, in: node),
                updateTime: try extractor.string(rules.updateTime, in: node),
                bookURL: bookURL,
                coverURL: try extractor.string(rules.coverUrl, in: node, asURL: true),
                tocURL: ""
            )
        }
    }

    func loadDetails(
        book: SearchBook,
        source: BookSourceDefinition
    ) async throws -> SearchBook {
        if NativeLofterAdapter.accepts(source) { return try await NativeLofterAdapter(source: source).details(book) }
        guard let rules = source.ruleBookInfo else { return book }
        let url = try URLTemplateRenderer.render(book.bookURL)
        let resource = try await client.fetch(url, source: source)
        let root = try extractor.root(from: resource)
        var result = book

        result.name = try extractor.string(rules.name, in: root).nilIfBlank ?? result.name
        result.author = try extractor.string(rules.author, in: root).nilIfBlank ?? result.author
        result.intro = try extractor.string(rules.intro, in: root).nilIfBlank ?? result.intro
        result.kind = try extractor.string(rules.kind, in: root).nilIfBlank ?? result.kind
        result.lastChapter = try extractor.string(rules.lastChapter, in: root).nilIfBlank
            ?? result.lastChapter
        result.updateTime = try extractor.string(rules.updateTime, in: root).nilIfBlank
            ?? result.updateTime
        result.coverURL = try extractor.string(rules.coverUrl, in: root, asURL: true).nilIfBlank
            ?? result.coverURL
        result.tocURL = try extractor.string(rules.tocUrl, in: root, asURL: true).nilIfBlank
            ?? result.tocURL
        return result
    }

    func loadChapters(
        book: SearchBook,
        source: BookSourceDefinition
    ) async throws -> [BookChapter] {
        if NativeLofterAdapter.accepts(source) { return try await NativeLofterAdapter(source: source).chapters(book) }
        if source.id == LocalBookStorage.sourceID {
            return try LocalBookStorage.book(at: book.bookURL).chapters
        }
        guard let rules = source.ruleToc,
              let chapterListRule = rules.chapterList?.nilIfBlank else {
            return [BookChapter(title: "全文", url: book.bookURL, index: 0)]
        }

        let tocAddress = book.tocURL.nilIfBlank ?? book.bookURL
        var currentURL = try URLTemplateRenderer.render(tocAddress)
        var visitedPages = Set<String>()
        var chapters: [BookChapter] = []

        for pageIndex in 0..<Self.maximumTocPageCount {
            guard visitedPages.insert(currentURL.absoluteString).inserted else { break }
            let resource = try await client.fetch(currentURL, source: source)
            let root = try extractor.root(from: resource)
            let nodes = try extractor.list(chapterListRule, in: root)

            for node in nodes {
                let title = try extractor.string(rules.chapterName, in: node)
                let chapterURL = try extractor.string(rules.chapterUrl, in: node, asURL: true)
                guard !title.isEmpty, !chapterURL.isEmpty else {
                    continue
                }
                chapters.append(BookChapter(title: title, url: chapterURL, index: chapters.count))
            }

            guard let nextRule = rules.nextTocUrl?.nilIfBlank else { break }
            let next = try extractor.string(nextRule, in: root, asURL: true)
            guard let nextURL = URL(string: next), !next.isEmpty else { break }
            guard !visitedPages.contains(nextURL.absoluteString) else { break }
            if pageIndex == Self.maximumTocPageCount - 1 {
                throw SourceEngineError.tocPaginationLimit(Self.maximumTocPageCount)
            }
            currentURL = nextURL
        }
        let normalizedChapters = ChapterSequenceNormalizer.normalize(chapters)
        if normalizedChapters.isEmpty {
            throw SourceEngineError.emptyChapterList
        }
        if Self.isWholeBookPageDirectory(normalizedChapters) {
            throw SourceEngineError.incompatiblePageDirectory
        }
        return normalizedChapters
    }

    func loadContent(
        chapter: BookChapter,
        source: BookSourceDefinition
    ) async throws -> String {
        try await loadDocument(chapter: chapter, source: source).text
    }

    func loadDocument(chapter: BookChapter, source: BookSourceDefinition) async throws -> SourceChapterDocument {
        if NativeLofterAdapter.accepts(source) { return try await NativeLofterAdapter(source: source).document(chapter) }
        if source.id == LocalBookStorage.sourceID {
            return SourceChapterDocument(text: try LocalBookStorage.content(at: chapter.url))
        }
        let rules = source.ruleContent
        var currentURL = try URLTemplateRenderer.render(chapter.url)
        var visited = Set<String>()
        var pages: [String] = []
        var markup: [String] = []

        for pageIndex in 0..<Self.maximumContentPageCount {
            guard visited.insert(currentURL.absoluteString).inserted else { break }
            let resource = try await client.fetch(currentURL, source: source)
            var rawText = resource.text
            if let sourceRegex = rules?.sourceRegex?.nilIfBlank {
                rawText = replace(rawText, pattern: sourceRegex, with: "")
            }
            let adjustedResource = FetchedResource(
                data: rawText.data(using: .utf8) ?? resource.data,
                finalURL: resource.finalURL,
                contentType: "text/html; charset=utf-8"
            )
            let root = try extractor.root(from: adjustedResource)
            let contentRule = rules?.content?.nilIfBlank ?? "@text"
            var content = try extractor.chapterHTML(contentRule, in: root)
            if let replaceRule = rules?.replaceRegex?.nilIfBlank {
                content = ReadableContentFormatter.removingMatches(in: content, rule: replaceRule)
            }
            var cleaned = ReadableContentFormatter.plainText(from: content)
            if let replaceRule = rules?.replaceRegex?.nilIfBlank {
                cleaned = ReadableContentFormatter.removingMatches(
                    in: cleaned,
                    rule: replaceRule
                )
            }
            if let message = Self.authenticationMessage(in: cleaned) {
                throw SourceEngineError.authenticationRequired(message)
            }
            if !cleaned.isEmpty { pages.append(cleaned) }
            if let document = try? SourceChapterDocument.sanitized(content, baseURL: resource.finalURL) {
                markup.append(document.html)
                if cleaned.isEmpty { pages.append(document.text) }
            }

            guard let nextRule = rules?.nextContentUrl?.nilIfBlank else { break }
            let next = try extractor.string(nextRule, in: root, asURL: true)
            guard let nextURL = URL(string: next), !next.isEmpty else { break }
            guard !visited.contains(nextURL.absoluteString) else { break }
            if pageIndex == Self.maximumContentPageCount - 1 {
                throw SourceEngineError.contentPaginationLimit(Self.maximumContentPageCount)
            }
            currentURL = nextURL
        }

        let result = ReadableTextNormalizer.normalize(
            pages.joined(separator: "\n\n")
        )
        guard !result.isEmpty else { throw SourceEngineError.emptyContent }
        return SourceChapterDocument(text: result, html: markup.isEmpty ? nil : markup.joined(separator: "\n"))
    }

    static func authenticationMessage(in value: String) -> String? {
        let markers = [
            "免登录访问次数已达上限",
            "继续阅读请登录",
            "登录后刷新页面"
        ]
        guard markers.contains(where: value.contains) else { return nil }
        return value.nilIfBlank ?? "该书源需要登录后继续阅读"
    }

    static func isWholeBookPageDirectory(_ chapters: [BookChapter]) -> Bool {
        guard chapters.count >= 20, let pageTitleRegex else { return false }
        let pageTitleCount = chapters.reduce(into: 0) { count, chapter in
            let title = chapter.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let range = NSRange(title.startIndex..., in: title)
            if pageTitleRegex.firstMatch(in: title, range: range)?.range == range {
                count += 1
            }
        }
        return pageTitleCount * 5 >= chapters.count * 4
    }

    private func replace(_ value: String, pattern: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return value }
        return regex.stringByReplacingMatches(
            in: value,
            range: NSRange(value.startIndex..., in: value),
            withTemplate: replacement
        )
    }
}

enum SourceEngineError: LocalizedError, Equatable {
    case invalidURL(String)
    case invalidResponse
    case httpStatus(Int)
    case responseTooLarge
    case emptyChapterList
    case incompatiblePageDirectory
    case emptyContent
    case tocPaginationLimit(Int)
    case contentPaginationLimit(Int)
    case authenticationRequired(String)
    case requestTimedOut
    case connectionInterrupted
    case networkUnavailable
    case requestFailed(String)

    var requiresAuthentication: Bool {
        if case .authenticationRequired = self { return true }
        return false
    }

    var errorDescription: String? {
        switch self {
        case .invalidURL(let value): "地址无效：\(value)"
        case .invalidResponse: "书源没有返回有效的网络响应"
        case .httpStatus(let code): "书源请求失败，状态码 \(code)"
        case .responseTooLarge: "书源响应超过 25 MB 限制"
        case .emptyChapterList: "没有解析到章节目录"
        case .incompatiblePageDirectory:
            "该书源把整本书拆成网页分页，无法识别真实章节，请切换书源或返回寻书重新搜索"
        case .emptyContent: "没有解析到正文内容"
        case .tocPaginationLimit(let count): "目录超过连续 \(count) 页，已停止加载以避免返回不完整章节"
        case .contentPaginationLimit(let count): "本章超过连续 \(count) 页，已停止加载以避免显示不完整正文"
        case .authenticationRequired(let message): message
        case .requestTimedOut: "书源多次请求仍然超时，请稍后重试"
        case .connectionInterrupted: "书源连接中断，多次请求仍未完整返回正文"
        case .networkUnavailable: "当前网络不可用，或无法连接到书源服务器"
        case .requestFailed(let message): "书源网络请求失败：\(message)"
        }
    }
}
