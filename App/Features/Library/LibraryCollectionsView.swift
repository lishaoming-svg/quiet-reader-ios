import SwiftData
import SwiftUI

struct LibraryCollectionsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query private var books: [BookRecord]
    @Query private var progresses: [ReadingProgressRecord]
    @Binding var selection: String
    @AppStorage("library.collections.v1") private var collectionData = Data()
    @State private var creating = false
    @State private var title = ""
    @State private var error: String?
    private var collections: [LibraryCollection] { LibraryOrganization.collections(from: collectionData) }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    smart("全部图书", "books.vertical", "all", count: books.count)
                    smart("想读", "bookmark", "want", count: books.filter { $0.libraryState.wantToRead }.count)
                    smart("已读完", "checkmark.circle", "finished", count: books.filter { book in LibraryOrganization.completed(book, progress: progresses.first { $0.bookID == book.bookID }) }.count)
                    smart("图书", "book.closed", "books", count: books.filter { $0.kind != "PDF" }.count)
                    smart("PDF", "doc.richtext", "pdf", count: books.filter { $0.kind == "PDF" }.count)
                    smart("本地图书", "arrow.down.circle", "local", count: books.filter(\.isLocal).count)
                }
                Section("我的藏书集") {
                    ForEach(collections) { item in
                        smart(item.title, "folder", item.id, count: books.filter { $0.libraryState.collectionIDs.contains(item.id) }.count)
                    }.onDelete { offsets in
                        let ids = Set(offsets.map { collections[$0].id })
                        do {
                            for book in books {
                                var state = book.libraryState; state.collectionIDs.removeAll { ids.contains($0) }; book.libraryState = state
                            }
                            try context.save()
                            collectionData = LibraryOrganization.data(collections.filter { !ids.contains($0.id) })
                            if ids.contains(selection) { selection = "all" }
                        } catch { self.error = error.localizedDescription }
                    }
                    Button("新建藏书集", systemImage: "plus") { title = ""; creating = true }
                }
            }
            .navigationTitle("藏书集").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .alert("新建藏书集", isPresented: $creating) {
                TextField("名称", text: $title)
                Button("取消", role: .cancel) {}
                Button("添加") {
                    let value = LibraryCollection(title: title)
                    if !value.title.isEmpty { collectionData = LibraryOrganization.data(collections + [value]) }
                }
            }
            .alert("无法保存藏书集", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("好", role: .cancel) {}
            } message: { Text(error ?? "") }
        }
    }
    private func smart(_ title: String, _ icon: String, _ id: String, count: Int) -> some View {
        Button { selection = id; dismiss() } label: {
            HStack { Label(title, systemImage: icon); Spacer(); Text("\(count)").foregroundStyle(.secondary); if selection == id { Image(systemName: "checkmark") } }
                .frame(minHeight: 36)
        }.foregroundStyle(.primary).accessibilityIdentifier("collection.\(id)")
    }
}

struct AddToCollectionView: View {
    let book: BookRecord
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @AppStorage("library.collections.v1") private var collectionData = Data()
    @State private var error: String?
    var body: some View {
        NavigationStack {
            List {
                if LibraryOrganization.collections(from: collectionData).isEmpty {
                    Text("先在书库的“藏书集”中新建一个藏书集。").foregroundStyle(.secondary)
                }
                ForEach(LibraryOrganization.collections(from: collectionData)) { item in
                    Button {
                        var state = book.libraryState
                        if state.collectionIDs.contains(item.id) { state.collectionIDs.removeAll { $0 == item.id } }
                        else { state.collectionIDs.append(item.id) }
                        book.libraryState = state
                        do { try context.save() } catch { self.error = error.localizedDescription }
                    } label: {
                        HStack { Text(item.title); Spacer(); if book.libraryState.collectionIDs.contains(item.id) { Image(systemName: "checkmark") } }
                    }.foregroundStyle(.primary)
                }
                if let error { Text(error).foregroundStyle(.red) }
            }.navigationTitle("加入藏书集").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }.presentationDetents([.medium, .large])
    }
}
