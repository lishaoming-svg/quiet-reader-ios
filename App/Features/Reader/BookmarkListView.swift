import SwiftData
import SwiftUI

struct BookmarkListView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \BookmarkRecord.createdAt, order: .reverse) private var allBookmarks: [BookmarkRecord]
    @State private var editing: BookmarkRecord?

    let bookID: String
    var addNote: (() -> Void)? = nil
    let onSelect: (BookmarkRecord) -> Void

    private var bookmarks: [BookmarkRecord] {
        allBookmarks.filter { $0.bookID == bookID }
    }

    var body: some View {
        NavigationStack {
            Group {
                if bookmarks.isEmpty {
                    EmptyStateView(
                        icon: "bookmark",
                        title: "还没有书签",
                        message: "在阅读页轻点书签按钮，即可保存当前阅读位置。"
                    )
                } else {
                    List {
                        ForEach(bookmarks) { bookmark in
                            Button {
                                onSelect(bookmark)
                            } label: {
                                VStack(alignment: .leading, spacing: 7) {
                                    HStack {
                                        Text(bookmark.chapterTitle)
                                            .font(.headline)
                                            .foregroundStyle(AppTheme.ink)
                                        Spacer()
                                        Text("\(Int(bookmark.chapterProgress * 100))%")
                                            .font(.caption.monospacedDigit())
                                            .foregroundStyle(AppTheme.vermilion)
                                    }
                                    if !bookmark.excerpt.isEmpty {
                                        Text(bookmark.excerpt)
                                            .font(.callout)
                                            .foregroundStyle(AppTheme.inkSoft)
                                            .lineLimit(3)
                                    }
                                    Text(bookmark.createdAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    if !bookmark.note.isEmpty { Text(bookmark.note).font(.callout).foregroundStyle(.primary).textSelection(.enabled) }
                                }
                                .padding(.vertical, 5)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("编辑笔记", systemImage: "pencil") { editing = bookmark }
                                ShareLink(item: AnnotationTextExporter.text([bookmark])) { Label("分享笔记", systemImage: "square.and.arrow.up") }
                            }
                            .swipeActions {
                                Button("删除", role: .destructive) {
                                    modelContext.delete(bookmark)
                                    try? modelContext.save()
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("笔记与书签")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                if let addNote { ToolbarItem(placement: .primaryAction) { Button("添加笔记", systemImage: "square.and.pencil", action: addNote) } }
                if !bookmarks.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button("清空本书书签", role: .destructive) {
                                bookmarks.forEach(modelContext.delete)
                                try? modelContext.save()
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
            }
        }
        .sheet(item: $editing) { AnnotationEditorView(bookmark: $0) }
    }
}
