import SwiftData
import SwiftUI

struct BookMetadataEditor: View {
    let book: BookRecord
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var title: String
    @State private var author: String
    @State private var error: String?
    init(book: BookRecord) {
        self.book = book; _title = State(initialValue: book.name); _author = State(initialValue: book.author)
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("图书信息") {
                    TextField("书名", text: $title).accessibilityIdentifier("metadata.title")
                    TextField("作者", text: $author)
                }
                if let error { Text(error).foregroundStyle(.red) }
            }.navigationTitle("编辑图书").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") {
                            let oldTitle = book.name, oldAuthor = book.author, oldState = book.libraryState
                            book.name = title.trimmingCharacters(in: .whitespacesAndNewlines)
                            book.author = author.trimmingCharacters(in: .whitespacesAndNewlines)
                            var state = book.libraryState; state.customTitle = book.name; state.customAuthor = book.author; book.libraryState = state
                            do { try context.save(); dismiss() }
                            catch { book.name = oldTitle; book.author = oldAuthor; book.libraryState = oldState; self.error = error.localizedDescription }
                        }.disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
        }
    }
}
