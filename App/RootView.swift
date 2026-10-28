import SwiftData
import SwiftUI

struct RootView: View {
    @Environment(\.modelContext) private var modelContext
    @StateObject private var importer = BookImportCoordinator()
    @State private var didRefreshBundledSources = false
    @State private var selectedTab = 0
    @State private var sourceFile: SourceFile?
    private struct SourceFile: Identifiable { let id = UUID(); let access: ImportedFileAccess }
    private var importFlow: Binding<Bool> {
        Binding(get: { importer.showingPicker || importer.showingResults }, set: { presented in
            if !presented { importer.showingPicker = false; importer.showingResults = false }
        })
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack { ReadingHomeView() }
                .tabItem { Label("主页", systemImage: "house") }.tag(0)
            NavigationStack { BookshelfView() }
                .tabItem { Label("书库", systemImage: "books.vertical") }.tag(1)
            NavigationStack {
                SearchView()
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            NavigationLink { SourceManagerView() } label: { Image(systemName: "network") }
                                .accessibilityLabel("书源管理")
                        }
                    }
            }.tabItem { Label("搜索", systemImage: "magnifyingglass") }.tag(2)
        }
        .environmentObject(importer)
        .tint(AppTheme.vermilion)
        .sheet(isPresented: importFlow) {
            BookImportFlowView(importer: importer)
        }
        .sheet(item: $sourceFile) { SourceImportView(file: $0.access) }
        .onOpenURL { url in
            if url.pathExtension.lowercased() == "json" {
                selectedTab = 2; sourceFile = SourceFile(access: ImportedFileAccess(url))
            } else { selectedTab = 1; importer.start([url], context: modelContext) }
        }
        .task {
            guard !didRefreshBundledSources else { return }
            didRefreshBundledSources = true
            try? BundledSourceUpdater.refreshExistingSources(in: modelContext)
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
                try? LibraryTestSeed.populate(context: modelContext)
            }
            #endif
        }
    }
}
