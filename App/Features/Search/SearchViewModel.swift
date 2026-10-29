import Combine
import Foundation

@MainActor
final class SearchViewModel: ObservableObject {
    @Published var results: [SearchBook] = []
    @Published var resultGroups: [SearchBookGroup] = []
    @Published var isSearching = false
    @Published var errorMessage: String?
    @Published var searchedKeyword = ""
    @Published private(set) var completedSources = 0
    @Published private(set) var totalSources = 0
    private var operation: Task<Void, Never>?
    private var generation = UUID()
    private let lookup: @Sendable (String, BookSourceDefinition) async throws -> [SearchBook]

    init(lookup: @escaping @Sendable (String, BookSourceDefinition) async throws -> [SearchBook] = {
        try await SourceEngine().search(keyword: $0, source: $1)
    }) { self.lookup = lookup }

    func cancel() {
        generation = UUID()
        operation?.cancel()
        operation = nil
        isSearching = false
    }

    func search(keyword: String, sources: [BookSourceDefinition]) async {
        let keyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return }
        cancel()
        guard !sources.isEmpty else {
            errorMessage = "没有可用于搜索的启用书源"
            return
        }

        searchedKeyword = keyword
        isSearching = true
        errorMessage = nil
        results = []
        resultGroups = []
        completedSources = 0
        totalSources = sources.count
        let request = generation
        let lookup = self.lookup
        operation = Task {
          await withTaskGroup(of: SourceSearchOutcome.self) { group in
            var next = 0
            func enqueue(_ index: Int) {
                let source = sources[index]
                group.addTask {
                    do {
                        try Task.checkCancellation()
                        let books = try await lookup(keyword, source)
                        return SourceSearchOutcome(
                            sourceOrder: index,
                            books: books,
                            error: nil
                        )
                    } catch {
                        return SourceSearchOutcome(
                            sourceOrder: index,
                            books: [],
                            error: "\(source.bookSourceName)：\(error.localizedDescription)"
                        )
                    }
                }
            }
            // Keep sockets available for opening a book while searching large catalogs.
            while next < min(8, sources.count) { enqueue(next); next += 1 }
            var values: [SourceSearchOutcome] = []
            for await outcome in group {
                guard !Task.isCancelled, generation == request else { group.cancelAll(); break }
                values.append(outcome)
                completedSources = values.count
                publish(values, keyword: keyword)
                if next < sources.count { enqueue(next); next += 1 }
            }
          }
          if generation == request { isSearching = false }
        }
        await operation?.value
    }

    private func publish(_ outcomes: [SourceSearchOutcome], keyword: String) {
        let orderedOutcomes = outcomes.sorted { $0.sourceOrder < $1.sourceOrder }
        var seen = Set<String>()
        let uniqueBooks = orderedOutcomes
            .flatMap(\.books)
            .filter { seen.insert($0.id).inserted }
        results = SearchResultRanker.rank(uniqueBooks, keyword: keyword)
        resultGroups = SearchResultGrouper.group(results)
        let failures = orderedOutcomes.compactMap(\.error)
        if results.isEmpty {
            errorMessage = failures.isEmpty
                ? "没有找到“\(keyword)”"
                : failures.prefix(3).joined(separator: "\n")
        }
    }
}

private struct SourceSearchOutcome: Sendable {
    var sourceOrder: Int
    var books: [SearchBook]
    var error: String?
}
