import XCTest
@testable import QuietReader

final class CuratedSourcesLiveIntegrationTests: XCTestCase {
    private let keyword = "异悚"

    func testFiveCuratedSourcesCanSearchAndRead() async throws {
        let sourceURL = try XCTUnwrap(
            Bundle.main.url(forResource: "community-sources", withExtension: "json")
        )
        let sourceData = try Data(contentsOf: sourceURL)
        let sources = try JSONDecoder().decode([BookSourceDefinition].self, from: sourceData)
        XCTAssertEqual(sources.count, 5)
        XCTAssertTrue(sources.allSatisfy { $0.loginUrl?.nilIfBlank == nil })

        let outcomes = await withTaskGroup(of: SourceOutcome.self) { group in
            for source in sources {
                group.addTask { [keyword] in
                    do {
                        let engine = SourceEngine()
                        guard let category = SourceExploreParser.categories(
                            from: source.exploreUrl
                        ).first else {
                            throw LiveSourceError.noExploreCategory
                        }
                        let exploreBooks = try await engine.explore(
                            category: category,
                            source: source
                        )
                        guard !exploreBooks.isEmpty else {
                            throw LiveSourceError.noExploreBooks
                        }
                        let books = try await engine.search(keyword: keyword, source: source)
                        let matchingBooks = books.filter { $0.name.contains(keyword) }
                        let ranked = SearchResultRanker.rank(matchingBooks, keyword: keyword)
                        guard let book = ranked.first else {
                            throw LiveSourceError.noMatchingBook
                        }
                        let detailedBook = try await engine.loadDetails(book: book, source: source)
                        let chapters = try await engine.loadChapters(
                            book: detailedBook,
                            source: source
                        )
                        guard let firstChapter = chapters.first else {
                            throw LiveSourceError.noChapters
                        }
                        let content = try await engine.loadContent(
                            chapter: firstChapter,
                            source: source
                        )
                        guard content.count >= 200 else {
                            throw LiveSourceError.contentTooShort(content.count)
                        }
                        return SourceOutcome(
                            source: source,
                            title: book.name,
                            exactMatch: book.name == keyword,
                            bookCount: books.count,
                            exploreBookCount: exploreBooks.count,
                            chapterCount: chapters.count,
                            contentCharacters: content.count,
                            error: nil
                        )
                    } catch {
                        return SourceOutcome(
                            source: source,
                            title: nil,
                            exactMatch: false,
                            bookCount: 0,
                            exploreBookCount: 0,
                            chapterCount: 0,
                            contentCharacters: 0,
                            error: error.localizedDescription
                        )
                    }
                }
            }

            var values: [SourceOutcome] = []
            for await outcome in group { values.append(outcome) }
            return values.sorted { $0.source.bookSourceName < $1.source.bookSourceName }
        }

        for outcome in outcomes {
            if let error = outcome.error {
                print(
                    "CURATED_SOURCE_FAIL id=\(outcome.source.id) "
                        + "name=\(outcome.source.bookSourceName) error=\(error)"
                )
            } else {
                print(
                    "CURATED_SOURCE_OK id=\(outcome.source.id) "
                        + "name=\(outcome.source.bookSourceName) "
                        + "title=\(outcome.title ?? "") exact=\(outcome.exactMatch) "
                        + "books=\(outcome.bookCount) exploreBooks=\(outcome.exploreBookCount) "
                        + "chapters=\(outcome.chapterCount) "
                        + "contentCharacters=\(outcome.contentCharacters)"
                )
            }
        }

        XCTAssertTrue(outcomes.allSatisfy { $0.error == nil })
        XCTAssertGreaterThanOrEqual(outcomes.filter(\.exactMatch).count, 4)
    }
}

private struct SourceOutcome: Sendable {
    var source: BookSourceDefinition
    var title: String?
    var exactMatch: Bool
    var bookCount: Int
    var exploreBookCount: Int
    var chapterCount: Int
    var contentCharacters: Int
    var error: String?
}

private enum LiveSourceError: LocalizedError {
    case noMatchingBook
    case noExploreCategory
    case noExploreBooks
    case noChapters
    case contentTooShort(Int)

    var errorDescription: String? {
        switch self {
        case .noMatchingBook: "没有搜索到包含关键字的书名"
        case .noExploreCategory: "没有可用的榜单分类"
        case .noExploreBooks: "榜单没有解析到书籍"
        case .noChapters: "没有解析到章节"
        case .contentTooShort(let count): "正文过短：\(count) 字符"
        }
    }
}
