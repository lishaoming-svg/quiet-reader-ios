import SwiftData
import SwiftUI

@MainActor
final class BookImportCoordinator: ObservableObject {
    struct ResultItem: Identifiable {
        let id = UUID()
        let filename: String
        let message: String
        let succeeded: Bool
    }
    @Published var showingPicker = false
    @Published var showingResults = false
    @Published private(set) var isImporting = false
    @Published private(set) var currentFilename = ""
    @Published private(set) var completed = 0
    @Published private(set) var total = 0
    @Published private(set) var results: [ResultItem] = []
    private var operation: Task<Void, Never>?
    private var queue: [ImportedFileAccess] = []
    private var picked: Result<[URL], Error>?
    private var pickedAccess: [ImportedFileAccess] = []

    func pickedDocuments(_ selection: Result<[URL], Error>) {
        if case .success(let urls) = selection { pickedAccess = urls.map(ImportedFileAccess.init) }
        picked = selection
        showingPicker = false
    }

    func pickerDidDismiss(context: ModelContext) {
        defer { picked = nil; pickedAccess = [] }
        if let picked { accept(picked, context: context) }
    }

    func accept(_ selection: Result<[URL], Error>, context: ModelContext) {
        switch selection {
        case .success(let urls): start(urls, context: context)
        case .failure(let error):
            guard (error as NSError).code != NSUserCancelledError else { return }
            results = [.init(filename: "无法打开文件", message: error.localizedDescription, succeeded: false)]
            showingResults = true
        }
    }

    func start(_ urls: [URL], context: ModelContext) {
        guard !urls.isEmpty else { return }
        let files = urls.map(ImportedFileAccess.init)
        if isImporting { queue += files; total += urls.count; showingResults = true; return }
        results = []; completed = 0; total = urls.count; isImporting = true; showingResults = true
        queue = files
        operation = Task {
            defer { isImporting = false; currentFilename = ""; operation = nil }
            while !queue.isEmpty {
                if Task.isCancelled { break }
                let access = queue.removeFirst()
                let url = access.url
                currentFilename = url.lastPathComponent
                do {
                    let worker = Task.detached(priority: .userInitiated) {
                        try withExtendedLifetime(access) { try LocalBookImporter.prepare(url: access.url) }
                    }
                    let imported = try await withTaskCancellationHandler {
                        try await worker.value
                    } onCancel: { worker.cancel() }
                    try Task.checkCancellation()
                    let duplicate = try LocalBookLibrary.save(imported, in: context)
                    results.append(.init(filename: url.lastPathComponent,
                                         message: duplicate ? "已在书库中，已恢复本地文件并保留阅读进度" : "已加入书库 · \(imported.chapters.count) 章",
                                         succeeded: true))
                } catch is CancellationError { break
                } catch {
                    results.append(.init(filename: url.lastPathComponent, message: error.localizedDescription, succeeded: false))
                }
                completed += 1
            }
        }
    }
    func cancel() { queue = []; operation?.cancel() }
}

enum LocalBookLibrary {
    @MainActor @discardableResult
    static func save(_ imported: LocalBookImport, in context: ModelContext) throws -> Bool {
        let id = imported.book.id
        let descriptor = FetchDescriptor<BookRecord>(predicate: #Predicate { $0.bookID == id })
        let existing = try context.fetch(descriptor).first
        if let existing { existing.update(from: imported.book) }
        else { context.insert(BookRecord(book: imported.book)) }
        // The complete document lives on disk; only the directory is stored in SwiftData.
        if let list = ChapterListCacheStore.record(bookID: id, in: context) {
            try list.update(sourceID: imported.book.sourceID, chapters: imported.chapters)
        } else {
            context.insert(try ChapterListCacheRecord(bookID: id, sourceID: imported.book.sourceID, chapters: imported.chapters))
        }
        do { try context.save() } catch { context.rollback(); throw error }
        return existing != nil
    }

    @MainActor
    static func remove(_ book: BookRecord, in context: ModelContext) throws {
        let id = book.bookID
        let address = book.bookURL
        let local = book.isLocal
        if local {
            for value in try context.fetch(FetchDescriptor<ChapterCacheRecord>(predicate: #Predicate { $0.bookID == id })) { context.delete(value) }
            for value in try context.fetch(FetchDescriptor<ChapterListCacheRecord>(predicate: #Predicate { $0.bookID == id })) { context.delete(value) }
            for value in try context.fetch(FetchDescriptor<ReadingProgressRecord>(predicate: #Predicate { $0.bookID == id })) { context.delete(value) }
            for value in try context.fetch(FetchDescriptor<BookmarkRecord>(predicate: #Predicate { $0.bookID == id })) { context.delete(value) }
        }
        context.delete(book)
        do { try context.save() } catch { context.rollback(); throw error }
        if local { try LocalBookStorage.remove(address: address) }
    }
}

struct BookImportResultsView: View {
    @ObservedObject var importer: BookImportCoordinator
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                if importer.isImporting {
                    Section {
                        VStack(alignment: .leading, spacing: 14) {
                            ProgressView(value: Double(importer.completed), total: Double(max(1, importer.total)))
                            Text("正在导入 \(importer.currentFilename)").font(.subheadline)
                            Text("\(importer.completed) / \(importer.total)").font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 8)
                    }
                }
                ForEach(importer.results) { result in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: result.succeeded ? "checkmark.circle.fill" : "exclamationmark.circle")
                            .foregroundStyle(result.succeeded ? Color.green : Color.orange)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(result.filename).font(.headline)
                            Text(result.message).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 5)
                }
                if !importer.isImporting, importer.results.isEmpty { Text("导入已取消") }
            }
            .navigationTitle(importer.isImporting ? "正在导入" : "导入结果")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    if importer.isImporting { Button("取消") { importer.cancel() } }
                    else { Button("完成") { dismiss() }.accessibilityIdentifier("import.done") }
                }
            }
            .interactiveDismissDisabled(importer.isImporting)
        }
    }
}
