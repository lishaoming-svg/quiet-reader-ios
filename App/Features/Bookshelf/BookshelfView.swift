import SwiftData
import SwiftUI

struct BookshelfView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \BookRecord.lastReadAt, order: .reverse) private var books: [BookRecord]
    @Query private var sourceRecords: [BookSourceRecord]
    @Query private var progresses: [ReadingProgressRecord]

    var body: some View {
        ZStack {
            PaperBackground()
            if books.isEmpty {
                EmptyStateView(
                    icon: "books.vertical",
                    title: "书架还没有书",
                    message: "先到“书源”导入规则，再去“寻书”搜索并加入书架。"
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 14) {
                        ForEach(books) { book in
                            if let source = source(for: book) {
                                NavigationLink {
                                    BookDetailView(book: book.searchBook, source: source)
                                } label: {
                                    BookshelfRow(book: book, progress: progress(for: book.bookID))
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button("移出书架", role: .destructive) {
                                        modelContext.delete(book)
                                        try? modelContext.save()
                                    }
                                }
                            } else {
                                BookshelfRow(
                                    book: book,
                                    progress: progress(for: book.bookID),
                                    sourceMissing: true
                                )
                            }
                        }
                    }
                    .padding(16)
                }
            }
        }
        .navigationTitle("墨阅")
        .toolbarBackground(AppTheme.paperLight, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
    }

    private func source(for book: BookRecord) -> BookSourceDefinition? {
        sourceRecords.first(where: { $0.sourceID == book.sourceID })?.definition
    }

    private func progress(for bookID: String) -> ReadingProgressRecord? {
        progresses.first { $0.bookID == bookID }
    }
}

private struct BookshelfRow: View {
    let book: BookRecord
    let progress: ReadingProgressRecord?
    var sourceMissing = false

    var body: some View {
        HStack(spacing: 16) {
            BookCoverView(urlString: book.coverURL, title: book.name)
            VStack(alignment: .leading, spacing: 7) {
                Text(book.name)
                    .font(.system(size: 19, weight: .semibold, design: .serif))
                    .foregroundStyle(AppTheme.ink)
                    .lineLimit(2)
                Text(book.author.nilIfBlank ?? "作者未知")
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.inkSoft)
                Spacer(minLength: 2)
                Label(
                    sourceMissing ? "原书源已删除" : book.sourceName,
                    systemImage: sourceMissing ? "exclamationmark.circle" : "network"
                )
                .font(.caption)
                .foregroundStyle(sourceMissing ? AppTheme.vermilion : AppTheme.jade)
                if let progress {
                    Text("\(progress.chapterTitle) · 本章 \(Int(progress.chapterProgress * 100))%")
                        .font(.caption2)
                        .foregroundStyle(AppTheme.inkSoft)
                        .lineLimit(1)
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.bold())
                .foregroundStyle(AppTheme.line)
        }
        .frame(minHeight: 112)
        .inkCard()
    }
}
