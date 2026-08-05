import SwiftData
import SwiftUI

struct SourceManagerView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \BookSourceRecord.sourceName) private var sources: [BookSourceRecord]
    @Query private var bookshelfBooks: [BookRecord]
    @State private var showingImporter = false
    @State private var loginSource: BookSourceDefinition?
    @State private var cleanupCandidateIDs = Set<String>()
    @State private var showingCleanupAlert = false
    @State private var isAtBottom = false

    var body: some View {
        ZStack {
            PaperBackground()
            if sources.isEmpty {
                EmptyStateView(
                    icon: "point.3.connected.trianglepath.dotted",
                    title: "还没有书源",
                    message: "可以粘贴 JSON、输入远程地址，或导入内置的精选书源。"
                )
            } else {
                ScrollViewReader { proxy in
                    List {
                        Color.clear
                            .frame(height: 0)
                            .listRowInsets(EdgeInsets())
                            .listRowSeparator(.hidden)
                            .id(ListAnchor.top)
                            .onAppear { isAtBottom = false }

                        Section {
                            ForEach(sources) { source in
                                SourceRow(
                                    source: source,
                                    onChange: { try? modelContext.save() },
                                    onLogin: { loginSource = source.definition }
                                )
                                .listRowBackground(AppTheme.paperLight.opacity(0.92))
                            }
                            .onDelete(perform: delete)
                        } header: {
                            Text("共 \(sources.count) 个书源")
                                .foregroundStyle(AppTheme.inkSoft)
                        }

                        Color.clear
                            .frame(height: 1)
                            .listRowInsets(EdgeInsets())
                            .listRowSeparator(.hidden)
                            .id(ListAnchor.bottom)
                            .onAppear { isAtBottom = true }
                    }
                    .scrollContentBackground(.hidden)
                    .overlay(alignment: .bottomTrailing) {
                        jumpButton(proxy: proxy)
                    }
                }
            }
        }
        .navigationTitle("书源")
        .toolbarBackground(AppTheme.paperLight, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItemGroup(placement: .topBarLeading) {
                NavigationLink {
                    BundledSourceLibraryView()
                } label: {
                    Label("内置源库", systemImage: "tray.full")
                }
                Button(action: prepareCleanup) {
                    Label("一键清理", systemImage: "paintbrush")
                }
                .disabled(sources.isEmpty)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingImporter = true
                } label: {
                    Label("导入", systemImage: "square.and.arrow.down")
                }
            }
        }
        .sheet(isPresented: $showingImporter) {
            SourceImportView()
        }
        .sheet(item: $loginSource) { source in
            SourceLoginView(source: source)
        }
        .alert("一键清理书源", isPresented: $showingCleanupAlert) {
            Button("取消", role: .cancel) {}
            if !cleanupCandidateIDs.isEmpty {
                Button("清理 \(cleanupCandidateIDs.count) 个", role: .destructive) {
                    cleanSources()
                }
            }
        } message: {
            Text(cleanupMessage)
        }
    }

    private var cleanupMessage: String {
        if cleanupCandidateIDs.isEmpty {
            return "没有可清理的冗余书源。已启用、内置精选和书架正在使用的书源都会保留。"
        }
        return "将删除 \(cleanupCandidateIDs.count) 个未启用且未被书架使用的书源；已启用、内置精选和书架用源会保留。"
    }

    private func jumpButton(proxy: ScrollViewProxy) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.35)) {
                proxy.scrollTo(
                    isAtBottom ? ListAnchor.top : ListAnchor.bottom,
                    anchor: isAtBottom ? .top : .bottom
                )
            }
            isAtBottom.toggle()
        } label: {
            Image(systemName: isAtBottom ? "arrow.up.to.line" : "arrow.down.to.line")
                .font(.headline.bold())
                .foregroundStyle(.white)
                .frame(width: 46, height: 46)
                .background(AppTheme.vermilion, in: Circle())
                .shadow(color: AppTheme.ink.opacity(0.18), radius: 8, y: 4)
        }
        .accessibilityLabel(isAtBottom ? "回到顶部" : "前往底部")
        .padding(18)
    }

    private func prepareCleanup() {
        let curatedDefinitions = (try? BundledSourceUpdater.bundledDefinitions()) ?? []
        cleanupCandidateIDs = SourceCleanupPlanner.removableSourceIDs(
            allSourceIDs: Set(sources.map(\.sourceID)),
            enabledSourceIDs: Set(sources.filter(\.enabled).map(\.sourceID)),
            curatedSourceIDs: Set(curatedDefinitions.map(\.id)),
            bookshelfSourceIDs: Set(bookshelfBooks.map(\.sourceID))
        )
        showingCleanupAlert = true
    }

    private func cleanSources() {
        for source in sources where cleanupCandidateIDs.contains(source.sourceID) {
            modelContext.delete(source)
        }
        try? modelContext.save()
        cleanupCandidateIDs.removeAll()
    }

    private func delete(at offsets: IndexSet) {
        offsets.forEach { modelContext.delete(sources[$0]) }
        try? modelContext.save()
    }
}

private enum ListAnchor: Hashable {
    case top
    case bottom
}

private struct SourceRow: View {
    @Bindable var source: BookSourceRecord
    let onChange: () -> Void
    let onLogin: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(source.enabled ? AppTheme.jade : AppTheme.line)
                Image(systemName: "network")
                    .foregroundStyle(.white)
            }
            .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 4) {
                Text(source.sourceName)
                    .font(.system(size: 17, weight: .semibold, design: .serif))
                    .foregroundStyle(AppTheme.ink)
                Text("\(source.sourceGroup) · \(source.sourceURL)")
                    .font(.caption)
                    .foregroundStyle(AppTheme.inkSoft)
                    .lineLimit(1)
            }
            Spacer()
            VStack(spacing: 8) {
                Toggle("启用", isOn: $source.enabled)
                    .labelsHidden()
                    .tint(AppTheme.vermilion)
                    .onChange(of: source.enabled) { _, _ in onChange() }
                if source.definition?.loginUrl?.nilIfBlank != nil {
                    Button("登录", action: onLogin)
                        .font(.caption.bold())
                        .buttonStyle(.bordered)
                        .tint(AppTheme.vermilion)
                }
                if let definition = source.definition,
                   definition.enabledExplore != false,
                   !SourceExploreParser.categories(from: definition.exploreUrl).isEmpty {
                    NavigationLink {
                        SourceExploreView(source: definition)
                    } label: {
                        Label("榜单", systemImage: "list.number")
                            .font(.caption.bold())
                    }
                    .buttonStyle(.bordered)
                    .tint(AppTheme.jade)
                }
            }
        }
        .padding(.vertical, 5)
    }
}
