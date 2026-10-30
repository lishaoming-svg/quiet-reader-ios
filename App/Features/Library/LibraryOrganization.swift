import Foundation
import SwiftData

struct LibraryBookState: Codable, Equatable {
    var wantToRead = false
    var finishedAt: Date?
    var isFinished: Bool?
    var collectionIDs: [String] = []
    var customTitle: String?
    var customAuthor: String?
}

struct LibraryCollection: Codable, Identifiable, Equatable {
    let id: String
    var title: String
    init(title: String) { id = UUID().uuidString; self.title = title.trimmingCharacters(in: .whitespacesAndNewlines) }
}

enum LibraryOrganization {
    static func collections(from data: Data) -> [LibraryCollection] {
        (try? JSONDecoder().decode([LibraryCollection].self, from: data)) ?? []
    }
    static func data(_ values: [LibraryCollection]) -> Data { (try? JSONEncoder().encode(values)) ?? Data() }
    static func completed(_ book: BookRecord, progress: ReadingProgressRecord?) -> Bool {
        book.libraryState.isFinished ?? (book.libraryState.finishedAt != nil || (progress?.bookProgress ?? 0) >= 0.995)
    }
    @MainActor static func setFinished(_ finished: Bool, book: BookRecord, context: ModelContext) throws {
        var state = book.libraryState
        state.isFinished = finished
        state.finishedAt = finished ? .now : nil
        book.libraryState = state
        try context.save()
    }
}
