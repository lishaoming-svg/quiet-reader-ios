import SwiftUI

struct SourceExploreView: View {
    let source: BookSourceDefinition

    @State private var selectedCategory: SourceExploreCategory?
    @State private var books: [SearchBook] = []
    @State private var page = 1
    @State private var isLoading = false
    @State private var canLoadMore = true
    @State private var errorMessage: String?

    private var categories: [SourceExploreCategory] {
        SourceExploreParser.categories(from: source.exploreUrl)
    }

    var body: some View {
        ZStack {
            PaperBackground()
            VStack(spacing: 0) {
                categoryBar
                content
            }
        }
        .navigationTitle(source.bookSourceName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(AppTheme.paperLight, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .task {
            guard selectedCategory == nil, let first = categories.first else { return }
            selectedCategory = first
            await load(first, page: 1, replacing: true)
        }
    }

    private var categoryBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 9) {
                ForEach(categories) { category in
                    Button {
                        guard category != selectedCategory else { return }
                        selectedCategory = category
                        Task { await load(category, page: 1, replacing: true) }
                    } label: {
                        Text(category.title)
                            .font(.callout.bold())
                            .foregroundStyle(category == selectedCategory ? Color.white : AppTheme.ink)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(
                                category == selectedCategory ? AppTheme.vermilion : AppTheme.paperLight,
                                in: Capsule()
                            )
                            .overlay {
                                Capsule().stroke(
                                    AppTheme.line.opacity(category == selectedCategory ? 0 : 0.7)
                                )
                            }
                    }
                    .buttonStyle(.plain)
                    .disabled(isLoading)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(AppTheme.paperLight.opacity(0.88))
    }

    @ViewBuilder
    private var content: some View {
        if categories.isEmpty {
            EmptyStateView(
                icon: "list.number",
                title: "该书源没有榜单",
                message: "可以继续使用搜索；导入包含 exploreUrl 的书源后会在这里显示分类。"
            )
        } else if isLoading && books.isEmpty {
            Spacer()
            ProgressView("正在读取榜单…")
                .tint(AppTheme.vermilion)
            Spacer()
        } else if let errorMessage, books.isEmpty {
            Spacer()
            EmptyStateView(icon: "wifi.exclamationmark", title: "榜单读取失败", message: errorMessage)
            Spacer()
        } else {
            ScrollView {
                LazyVStack(spacing: 13) {
                    ForEach(books) { book in
                        NavigationLink {
                            BookDetailView(book: book, source: source)
                        } label: {
                            SearchResultRow(book: book)
                        }
                        .buttonStyle(.plain)
                    }

                    if canLoadMore {
                        Button {
                            guard let selectedCategory else { return }
                            Task { await load(selectedCategory, page: page + 1, replacing: false) }
                        } label: {
                            if isLoading {
                                ProgressView().tint(AppTheme.vermilion)
                            } else {
                                Label("加载下一页", systemImage: "arrow.down.circle")
                            }
                        }
                        .buttonStyle(.bordered)
                        .tint(AppTheme.vermilion)
                        .disabled(isLoading)
                        .padding(.vertical, 8)
                    }

                    if let errorMessage, !books.isEmpty {
                        InlineErrorView(message: errorMessage)
                    }
                }
                .padding(16)
            }
            .refreshable {
                guard let selectedCategory else { return }
                await load(selectedCategory, page: 1, replacing: true)
            }
        }
    }

    @MainActor
    private func load(
        _ category: SourceExploreCategory,
        page requestedPage: Int,
        replacing: Bool
    ) async {
        guard !isLoading else { return }
        if replacing {
            books = []
            canLoadMore = true
            page = 1
        }
        isLoading = true
        errorMessage = nil
        do {
            let loaded = try await SourceEngine().explore(
                category: category,
                page: requestedPage,
                source: source
            )
            guard selectedCategory == category else {
                isLoading = false
                return
            }
            if replacing {
                books = loaded
                canLoadMore = !loaded.isEmpty
            } else {
                let existingIDs = Set(books.map(\.id))
                let newBooks = loaded.filter { !existingIDs.contains($0.id) }
                books.append(contentsOf: newBooks)
                canLoadMore = !newBooks.isEmpty
            }
            page = requestedPage
            if books.isEmpty { errorMessage = "该分类暂时没有解析到书籍" }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}
