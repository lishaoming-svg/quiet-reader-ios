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
            for source in sources {
                group.addTask {
                    do {
                        let books = try await SourceEngine().search(keyword: keyword, source: source)
                        return SourceSearchOutcome(books: books, error: nil)
                    } catch {
                        return SourceSearchOutcome(
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

        var seen = Set<String>()
        results = outcomes
            .flatMap(\.books)
            .filter { seen.insert($0.id).inserted }
            .sorted {
                $0.sourceName == $1.sourceName
                    ? $0.name.localizedStandardCompare($1.name) == .orderedAscending
                    : $0.sourceName.localizedStandardCompare($1.sourceName) == .orderedAscending
            }
        let failures = outcomes.compactMap(\.error)
        if results.isEmpty {
            errorMessage = failures.isEmpty
                ? "没有找到“\(keyword)”"
                : failures.prefix(3).joined(separator: "\n")
        }
        isSearching = false
    }
}

private struct SourceSearchOutcome: Sendable {
    var books: [SearchBook]
    var error: String?
}
