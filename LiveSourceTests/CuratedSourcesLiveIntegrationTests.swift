import XCTest
@testable import QuietReader

final class CuratedSourcesLiveIntegrationTests: XCTestCase {
    private let keyword = "异悚"

    func testEnabledCuratedSourcesCanSearchAndRead() async throws {
        let sourceURL = try XCTUnwrap(
            Bundle.main.url(forResource: "community-sources", withExtension: "json")
        )
        let sourceData = try Data(contentsOf: sourceURL)
        let bundledSources = try JSONDecoder().decode([BookSourceDefinition].self, from: sourceData)
        let sources = bundledSources.filter(\.isEnabled)
        XCTAssertEqual(bundledSources.count, 5)
        XCTAssertEqual(sources.count, 4)
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
                        let firstContent = try await engine.loadContent(
                            chapter: firstChapter,
                            source: source
                        )
                        guard firstContent.count >= 200 else {
                            throw LiveSourceError.contentTooShort(firstContent.count)
                        }
                        let probeIndex = min(9, chapters.count - 1)
                        let probeContent = try await engine.loadContent(
                            chapter: chapters[probeIndex],
                            source: source
                        )
                        guard probeContent.count >= 200 else {
                            throw LiveSourceError.contentTooShort(probeContent.count)
                        }
                        return SourceOutcome(
                            source: source,
                            title: book.name,
                            exactMatch: book.name == keyword,
                            bookCount: books.count,
                            exploreBookCount: exploreBooks.count,
                            chapterCount: chapters.count,
                            contentCharacters: firstContent.count,
                            probeChapter: probeIndex + 1,
                            probeCharacters: probeContent.count,
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
                            probeChapter: 0,
                            probeCharacters: 0,
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
                        + "contentCharacters=\(outcome.contentCharacters) "
                        + "probeChapter=\(outcome.probeChapter) "
                        + "probeCharacters=\(outcome.probeCharacters)"
                )
            }
        }

        XCTAssertTrue(outcomes.allSatisfy { $0.error == nil })
        XCTAssertGreaterThanOrEqual(outcomes.filter(\.exactMatch).count, 3)
    }

    func testPagedSourcesReturnCompleteYiSongFirstChapter() async throws {
        let sourceURL = try XCTUnwrap(
            Bundle.main.url(forResource: "community-sources", withExtension: "json")
        )
        let sourceData = try Data(contentsOf: sourceURL)
        let sources = try JSONDecoder().decode([BookSourceDefinition].self, from: sourceData)
            .filter { ["饿狼小说", "森林文学"].contains($0.bookSourceName) }
        XCTAssertEqual(sources.count, 2)

        let outcomes = await withTaskGroup(of: CompletenessOutcome.self) { group in
            for source in sources {
                group.addTask { [keyword] in
                    do {
                        let engine = SourceEngine()
                        let books = try await engine.search(keyword: keyword, source: source)
                        guard let book = books.first(where: { $0.name == keyword }) else {
                            throw LiveSourceError.noMatchingBook
                        }
                        let detailed = try await engine.loadDetails(book: book, source: source)
                        let chapters = try await engine.loadChapters(book: detailed, source: source)
                        guard chapters.count >= 190 else {
                            throw LiveSourceError.chapterListTooShort(chapters.count)
                        }
                        guard let firstChapter = chapters.first(where: {
                            $0.title.contains("第一章") && $0.title.contains("第一个人")
                        }) else {
                            throw LiveSourceError.noExpectedChapter
                        }
                        let content = try await engine.loadContent(
                            chapter: firstChapter,
                            source: source
                        )
                        guard content.count >= 3_200 else {
                            throw LiveSourceError.contentTooShort(content.count)
                        }
                        guard content.contains("多么让人恐惧和绝望") else {
                            throw LiveSourceError.missingChapterEnding
                        }
                        return CompletenessOutcome(
                            sourceName: source.bookSourceName,
                            chapterCount: chapters.count,
                            contentCharacters: content.count,
                            error: nil
                        )
                    } catch {
                        return CompletenessOutcome(
                            sourceName: source.bookSourceName,
                            chapterCount: 0,
                            contentCharacters: 0,
                            error: error.localizedDescription
                        )
                    }
                }
            }

            var values: [CompletenessOutcome] = []
            for await value in group { values.append(value) }
            return values.sorted { $0.sourceName < $1.sourceName }
        }

        outcomes.forEach { outcome in
            print(
                "YISONG_COMPLETENESS source=\(outcome.sourceName) "
                    + "chapters=\(outcome.chapterCount) "
                    + "contentCharacters=\(outcome.contentCharacters) "
                    + "error=\(outcome.error ?? "none")"
            )
        }
        XCTAssertTrue(outcomes.allSatisfy { $0.error == nil })
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
    var probeChapter: Int
    var probeCharacters: Int
    var error: String?
}

private struct CompletenessOutcome: Sendable {
    var sourceName: String
    var chapterCount: Int
    var contentCharacters: Int
    var error: String?
}

private enum LiveSourceError: LocalizedError {
    case noMatchingBook
    case noExploreCategory
    case noExploreBooks
    case noChapters
    case chapterListTooShort(Int)
    case noExpectedChapter
    case contentTooShort(Int)
    case missingChapterEnding

    var errorDescription: String? {
        switch self {
        case .noMatchingBook: "没有搜索到包含关键字的书名"
        case .noExploreCategory: "没有可用的榜单分类"
        case .noExploreBooks: "榜单没有解析到书籍"
        case .noChapters: "没有解析到章节"
        case .chapterListTooShort(let count): "目录不完整：仅解析到 \(count) 章"
        case .noExpectedChapter: "目录中没有找到第一章《第一个人》"
        case .contentTooShort(let count): "正文过短：\(count) 字符"
        case .missingChapterEnding: "正文缺少第一章结尾"
        }
    }
}
