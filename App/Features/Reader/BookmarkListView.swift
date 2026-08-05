import SwiftData
import SwiftUI

struct BookmarkListView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \BookmarkRecord.createdAt, order: .reverse) private var allBookmarks: [BookmarkRecord]

    let bookID: String
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
                                }
                                .padding(.vertical, 5)
                            }
                            .buttonStyle(.plain)
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
            .navigationTitle("书签")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
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
    }
}
