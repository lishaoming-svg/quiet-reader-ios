import SwiftData
import SwiftUI

struct BookshelfView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \BookRecord.lastReadAt, order: .reverse) private var books: [BookRecord]
    @Query private var sourceRecords: [BookSourceRecord]
    @Query private var progresses: [ReadingProgressRecord]
    @AppStorage("bookshelf.layout") private var layoutValue = BookshelfLayout.list.rawValue

    private var layout: BookshelfLayout {
        BookshelfLayout(rawValue: layoutValue) ?? .list
    }

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
                    bookshelfContent
                    .padding(16)
                }
            }
        }
        .navigationTitle("墨阅")
        .toolbarBackground(AppTheme.paperLight, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("书架布局", selection: $layoutValue) {
                        ForEach(BookshelfLayout.allCases) { item in
                            Label(item.title, systemImage: item.systemImage).tag(item.rawValue)
                        }
                    }
                } label: {
                    Label("书架布局", systemImage: layout.systemImage)
                }
            }
        }
    }

    @ViewBuilder
    private var bookshelfContent: some View {
        if layout == .grid {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 130), spacing: 16)],
                spacing: 20
            ) {
                ForEach(books) { book in
                    bookshelfItem(book, grid: true)
                }
            }
        } else {
            LazyVStack(spacing: 14) {
                ForEach(books) { book in
                    bookshelfItem(book, grid: false)
                }
            }
        }
    }

    @ViewBuilder
    private func bookshelfItem(_ book: BookRecord, grid: Bool) -> some View {
        if let source = source(for: book) {
            NavigationLink {
                BookDetailView(book: book.searchBook, source: source)
            } label: {
                if grid {
                    BookshelfGridCard(book: book, progress: progress(for: book.bookID))
                } else {
                    BookshelfRow(book: book, progress: progress(for: book.bookID))
                }
            }
            .buttonStyle(.plain)
            .contextMenu { removeButton(book) }
        } else if grid {
            BookshelfGridCard(
                book: book,
                progress: progress(for: book.bookID),
                sourceMissing: true
            )
            .contextMenu { removeButton(book) }
        } else {
            BookshelfRow(
                book: book,
                progress: progress(for: book.bookID),
                sourceMissing: true
            )
            .contextMenu { removeButton(book) }
        }
    }

    private func removeButton(_ book: BookRecord) -> some View {
        Button("移出书架", role: .destructive) {
            modelContext.delete(book)
            try? modelContext.save()
        }
    }

    private func source(for book: BookRecord) -> BookSourceDefinition? {
        sourceRecords.first(where: { $0.sourceID == book.sourceID })?.definition
    }

    private func progress(for bookID: String) -> ReadingProgressRecord? {
        progresses.first { $0.bookID == bookID }
    }
}

private enum BookshelfLayout: String, CaseIterable, Identifiable {
    case list
    case grid

    var id: String { rawValue }
    var title: String { self == .list ? "列表" : "网格" }
    var systemImage: String { self == .list ? "list.bullet" : "square.grid.2x2" }
}

private struct BookshelfGridCard: View {
    let book: BookRecord
    let progress: ReadingProgressRecord?
    var sourceMissing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            BookCoverView(
                urlString: book.coverURL,
                title: book.name,
                width: 112,
                height: 158
            )
            .frame(maxWidth: .infinity)
            Text(book.name)
                .font(.system(size: 16, weight: .semibold, design: .serif))
                .foregroundStyle(AppTheme.ink)
                .lineLimit(1)
            Text(progress?.chapterTitle ?? (sourceMissing ? "原书源已删除" : "尚未阅读"))
                .font(.caption2)
                .foregroundStyle(sourceMissing ? AppTheme.vermilion : AppTheme.inkSoft)
                .lineLimit(1)
            if let progress {
                ProgressView(value: progress.chapterProgress)
                    .tint(AppTheme.vermilion)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
