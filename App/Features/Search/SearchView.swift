import SwiftData
import SwiftUI

struct SearchView: View {
    @Query(sort: \BookSourceRecord.sourceName) private var sourceRecords: [BookSourceRecord]
    @StateObject private var viewModel = SearchViewModel()
    @State private var keyword = ""

    private var enabledSources: [BookSourceDefinition] {
        sourceRecords.filter(\.enabled).compactMap(\.definition)
    }

    var body: some View {
        ZStack {
            PaperBackground()
            VStack(spacing: 0) {
                searchHeader
                content
            }
        }
        .navigationTitle("寻书")
        .toolbarBackground(AppTheme.paperLight, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
    }

    private var searchHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("在 \(enabledSources.count) 个书源中搜索")
                .font(.caption)
                .foregroundStyle(AppTheme.inkSoft)
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
                    .disabled(viewModel.isSearching || keyword.nilIfBlank == nil)
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
        if viewModel.isSearching {
            Spacer()
            VStack(spacing: 12) {
                ProgressView().tint(AppTheme.vermilion)
                Text("正在逐一询问书源…")
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
                    : "输入书名或作者，墨阅会同时搜索所有启用书源。"
            )
            Spacer()
        } else {
            ScrollView {
                LazyVStack(spacing: 13) {
                    ForEach(viewModel.results) { book in
                        if let source = enabledSources.first(where: { $0.id == book.sourceID }) {
                            NavigationLink {
                                BookDetailView(book: book, source: source)
                            } label: {
                                SearchResultRow(book: book)
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
        Task { await viewModel.search(keyword: keyword, sources: enabledSources) }
    }
}

private struct SearchResultRow: View {
    let book: SearchBook

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            BookCoverView(urlString: book.coverURL, title: book.name, width: 64, height: 92)
            VStack(alignment: .leading, spacing: 5) {
                Text(book.name)
                    .font(.system(size: 18, weight: .semibold, design: .serif))
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
                Label(book.sourceName, systemImage: "network")
                    .font(.caption2)
                    .foregroundStyle(AppTheme.jade)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .inkCard()
    }
}
