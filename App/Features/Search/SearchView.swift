import SwiftData
import SwiftUI

struct SearchView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \BookSourceRecord.sourceName) private var sourceRecords: [BookSourceRecord]
    @Query(sort: \SearchHistoryRecord.searchedAt, order: .reverse) private var searchHistory: [SearchHistoryRecord]
    @StateObject private var viewModel = SearchViewModel()
    @State private var keyword = ""
    @State private var selectedSource = ""

    private var enabledSources: [BookSourceDefinition] {
        sourceRecords.filter(\.enabled).compactMap(\.definition)
    }
    private var searchSources: [BookSourceDefinition] {
        selectedSource.isEmpty ? enabledSources : enabledSources.filter { $0.id == selectedSource }
    }

    var body: some View {
        ZStack {
            PaperBackground()
            VStack(spacing: 0) {
                searchHeader
                if shouldShowHistory { searchHistoryBar }
                content
            }
        }
        .navigationTitle("搜索")
        .toolbarBackground(AppTheme.paperLight, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .onDisappear { viewModel.cancel() }
        .onChange(of: selectedSource) { _, _ in performSearch() }
    }

    private var shouldShowHistory: Bool {
        !viewModel.isSearching && viewModel.results.isEmpty && !searchHistory.isEmpty
    }

    private var searchHistoryBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("最近搜索")
                    .font(.caption.bold())
                    .foregroundStyle(AppTheme.inkSoft)
                Spacer()
                Button("清空") {
                    searchHistory.forEach(modelContext.delete)
                    try? modelContext.save()
                }
                .font(.caption)
                .foregroundStyle(AppTheme.vermilion)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(searchHistory.prefix(12)) { item in
                        Button(item.keyword) {
                            keyword = item.keyword
                            performSearch()
                        }
                        .font(.callout)
                        .foregroundStyle(AppTheme.ink)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(AppTheme.paperLight, in: Capsule())
                        .overlay { Capsule().stroke(AppTheme.line.opacity(0.7)) }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
    }

    private var searchHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Menu {
                    Button("全部书源") { selectedSource = "" }
                    ForEach(enabledSources) { source in Button(source.bookSourceName) { selectedSource = source.id } }
                } label: {
                    Label(selectedSource.isEmpty ? "全部书源 · \(enabledSources.count)" : searchSources.first?.bookSourceName ?? "选择书源", systemImage: "line.3.horizontal.decrease")
                        .font(.subheadline.weight(.medium))
                }
                Spacer()
                if searchSources.contains(where: NativeLofterAdapter.accepts) {
                    Text("LOFTER：#合集名 · @作者").font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(AppTheme.vermilion)
                TextField("书名或作者", text: $keyword)
                    .textInputAutocapitalization(.never)
                    .submitLabel(.search)
                    .onSubmit(performSearch)
                if !keyword.isEmpty {
                    Button {
                        keyword = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(AppTheme.line)
                    }
                }
                Button("搜索", action: performSearch)
                    .font(.subheadline.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(AppTheme.vermilion, in: Capsule())
                    .disabled(keyword.nilIfBlank == nil)
            }
            .padding(12)
            .background(.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16).stroke(AppTheme.line.opacity(0.8))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isSearching && viewModel.results.isEmpty {
            Spacer()
            VStack(spacing: 12) {
                ProgressView().tint(AppTheme.vermilion)
                Text("正在搜索 · \(viewModel.completedSources)/\(viewModel.totalSources)")
                    .font(.callout)
                    .foregroundStyle(AppTheme.inkSoft)
            }
            Spacer()
        } else if let error = viewModel.errorMessage, viewModel.results.isEmpty {
            Spacer()
            EmptyStateView(icon: "magnifyingglass", title: "没有搜索结果", message: error)
            Spacer()
        } else if viewModel.results.isEmpty {
            Spacer()
            EmptyStateView(
                icon: "text.magnifyingglass",
                title: "从书名开始",
                message: enabledSources.isEmpty
                    ? "请先到“书源”页面导入并启用至少一个书源。"
                    : "输入书名或作者，iBooks 会同时搜索所有启用书源。"
            )
            Spacer()
        } else {
            ScrollView {
                LazyVStack(spacing: 13) {
                    if viewModel.isSearching {
                        HStack { ProgressView(); Text("继续搜索其他书源 · \(viewModel.completedSources)/\(viewModel.totalSources)").font(.caption).foregroundStyle(.secondary); Spacer() }
                    }
                    ForEach(viewModel.resultGroups) { group in
                        let book = group.primary
                        if let source = enabledSources.first(where: { $0.id == book.sourceID }) {
                            NavigationLink {
                                BookDetailView(
                                    book: book,
                                    source: source,
                                    alternatives: group.books
                                )
                            } label: {
                                SearchResultRow(book: book, group: group)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(16)
            }
        }
    }

    private func performSearch() {
        guard let cleaned = keyword.nilIfBlank else { return }
        keyword = cleaned
        saveSearchHistory(cleaned)
        Task { await viewModel.search(keyword: cleaned, sources: searchSources) }
    }

    private func saveSearchHistory(_ value: String) {
        let normalized = value.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
        if let existing = searchHistory.first(where: { $0.normalizedKeyword == normalized }) {
            existing.touch(keyword: value)
        } else {
            modelContext.insert(SearchHistoryRecord(keyword: value))
        }
        try? modelContext.save()
    }
}

struct SearchResultRow: View {
    let book: SearchBook
    let group: SearchBookGroup

    init(book: SearchBook, group: SearchBookGroup? = nil) {
        self.book = book
        self.group = group ?? SearchBookGroup(id: book.id, books: [book])
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            BookCoverView(urlString: book.coverURL, title: book.name, width: 64, height: 92)
            VStack(alignment: .leading, spacing: 5) {
                Text(book.name)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(AppTheme.ink)
                    .lineLimit(2)
                Text(book.author.nilIfBlank ?? "作者未知")
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.inkSoft)
                if let intro = book.intro.nilIfBlank {
                    Text(intro)
                        .font(.caption)
                        .foregroundStyle(AppTheme.inkSoft)
                        .lineLimit(2)
                }
                Label(
                    group.sourceCount > 1 ? "\(group.sourceCount) 个来源可切换" : book.sourceName,
                    systemImage: group.sourceCount > 1 ? "arrow.triangle.swap" : "network"
                )
                    .font(.caption2)
                    .foregroundStyle(AppTheme.jade)
                if group.sourceCount > 1 {
                    Text(group.sourceNames)
                        .font(.caption2)
                        .foregroundStyle(AppTheme.inkSoft)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) { Divider() }
    }
}
