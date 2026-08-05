import SwiftData
import SwiftUI

struct SourceManagerView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \BookSourceRecord.sourceName) private var sources: [BookSourceRecord]
    @State private var showingImporter = false
    @State private var loginSource: BookSourceDefinition?

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
                List {
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
                }
                .scrollContentBackground(.hidden)
            }
        }
        .navigationTitle("书源")
        .toolbarBackground(AppTheme.paperLight, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                NavigationLink {
                    BundledSourceLibraryView()
                } label: {
                    Label("内置源库", systemImage: "tray.full")
                }
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
    }

    private func delete(at offsets: IndexSet) {
        offsets.forEach { modelContext.delete(sources[$0]) }
        try? modelContext.save()
    }
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
            }
        }
        .padding(.vertical, 5)
    }
}
