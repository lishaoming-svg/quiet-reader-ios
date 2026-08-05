import XCTest
@testable import QuietReader

final class CuratedSourcesLiveIntegrationTests: XCTestCase {
    private let keyword = "??"
    private let candidateIDs: Set<String> = [
        "archive.f5b48e99e8b9cacdc8ea71e7",
        "archive.79837eac8d2e7a7ec846ab12",
        "archive.5d79cc1ae351dd6201f795df",
        "archive.c951076108ab20a86c676a88",
        "archive.b2a8b0a5a4943bf125ec3b8a",
        "archive.f26fddee5db49879634838f3",
        "archive.f7fa03d55fca42ba83bc2f80",
        "archive.b51e15e903884b0b2a033288",
        "archive.1cc9d3cb71d5905ef69180a3",
        "archive.0e12f30e88f0744dea7fc074",
        "archive.c1f4d100ecf45011a91b6892",
        "archive.82dd69bd8e8580392f1afbdb",
        "archive.44166c418c49b2b578b57654",
        "archive.9991a827e1fe7988d8489753",
        "archive.cb22d2bac74469e2ed2521e7"
    ]

    func testCatalogCandidatesCanSearchExactTitle() async throws {
        let sources = try await BundledSourceCatalog.shared.loadDefinitions(ids: candidateIDs)
        XCTAssertEqual(sources.count, candidateIDs.count)

        let outcomes = await withTaskGroup(of: SearchOutcome.self) { group in
            for source in sources {
                group.addTask { [keyword] in
                    do {
                        let books = try await SourceEngine().search(
                            keyword: keyword,
                            source: source
                        )
                        let ranked = SearchResultRanker.rank(books, keyword: keyword)
                        return SearchOutcome(
                            source: source,
                            bookCount: books.count,
                            firstTitle: ranked.first?.name,
                            exactMatch: books.contains { $0.name == keyword },
                            error: nil
                        )
                    } catch {
                        return SearchOutcome(
                            source: source,
                            bookCount: 0,
                            firstTitle: nil,
                            exactMatch: false,
                            error: error.localizedDescription
                        )
                    }
                }
            }

            var values: [SearchOutcome] = []
            for await outcome in group { values.append(outcome) }
            return values.sorted { $0.source.bookSourceName < $1.source.bookSourceName }
        }

        for outcome in outcomes {
            if outcome.exactMatch {
                print(
                    "CANDIDATE_OK id=\(outcome.source.id) "
                        + "name=\(outcome.source.bookSourceName) books=\(outcome.bookCount) "
                        + "first=\(outcome.firstTitle ?? "")"
                )
            } else {
                print(
                    "CANDIDATE_FAIL id=\(outcome.source.id) "
                        + "name=\(outcome.source.bookSourceName) books=\(outcome.bookCount) "
                        + "first=\(outcome.firstTitle ?? "") "
                        + "error=\(outcome.error ?? "????????")"
                )
            }
        }

        XCTAssertGreaterThanOrEqual(outcomes.filter(\.exactMatch).count, 5)
    }
}

private struct SearchOutcome: Sendable {
    var source: BookSourceDefinition
    var bookCount: Int
    var firstTitle: String?
    var exactMatch: Bool
    var error: String?
}
