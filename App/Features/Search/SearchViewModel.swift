import Combine
import Foundation

@MainActor
final class SearchViewModel: ObservableObject {
    @Published var results: [SearchBook] = []
    @Published var isSearching = false
    @Published var errorMessage: String?
    @Published var searchedKeyword = ""

    func search(keyword: String, sources: [BookSourceDefinition]) async {
        let keyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return }
        guard !sources.isEmpty else {
            errorMessage = "没有可用于搜索的启用书源"
            return
        }

        searchedKeyword = keyword
        isSearching = true
        errorMessage = nil
        results = []

        let outcomes = await withTaskGroup(of: SourceSearchOutcome.self) { group in
            for (sourceOrder, source) in sources.enumerated() {
                group.addTask {
                    do {
                        let books = try await SourceEngine().search(keyword: keyword, source: source)
                        return SourceSearchOutcome(
                            sourceOrder: sourceOrder,
                            books: books,
                            error: nil
                        )
                    } catch {
                        return SourceSearchOutcome(
                            sourceOrder: sourceOrder,
                            books: [],
                            error: "\(source.bookSourceName)：\(error.localizedDescription)"
                        )
                    }
                }
            }

            var values: [SourceSearchOutcome] = []
            for await outcome in group { values.append(outcome) }
            return values
        }

        let orderedOutcomes = outcomes.sorted { $0.sourceOrder < $1.sourceOrder }
        var seen = Set<String>()
        let uniqueBooks = orderedOutcomes
            .flatMap(\.books)
            .filter { seen.insert($0.id).inserted }
        results = SearchResultRanker.rank(uniqueBooks, keyword: keyword)
        let failures = orderedOutcomes.compactMap(\.error)
        if results.isEmpty {
            errorMessage = failures.isEmpty
                ? "没有找到“\(keyword)”"
                : failures.prefix(3).joined(separator: "\n")
        }
        isSearching = false
    }
}

private struct SourceSearchOutcome: Sendable {
    var sourceOrder: Int
    var books: [SearchBook]
    var error: String?
}
