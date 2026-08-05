import SwiftData
import SwiftUI

struct BundledSourceLibraryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var existingSources: [BookSourceRecord]

    @State private var entries: [BundledSourceCatalogEntry] = []
    @State private var searchText = ""
    @State private var filter = CatalogFilter.compatible
    @State private var selectedIDs = Set<String>()
    @State private var isLoading = true
    @State private var isImporting = false
    @State private var message: String?

    private var importedIDs: Set<String> { Set(existingSources.map(\.sourceID)) }

    private var filteredEntries: [BundledSourceCatalogEntry] {
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return entries.filter { entry in
            guard filter.includes(entry) else { return false }
            guard !keyword.isEmpty else { return true }
            return entry.name.localizedCaseInsensitiveContains(keyword)
                || entry.group.localizedCaseInsensitiveContains(keyword)
                || entry.host.localizedCaseInsensitiveContains(keyword)
        }
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView("正在加载内置源库…")
                    .tint(AppTheme.vermilion)
            } else if let message, entries.isEmpty {
                EmptyStateView(icon: "tray.full", title: "源库无法加载", message: message)
            } else {
                sourceList
            }
        }
        .navigationTitle("内置源库")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "书源名称、分组或域名")
        .toolbar { sourceToolbar }
        .task { await loadCatalog() }
        .safeAreaInset(edge: .bottom) {
            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(AppTheme.inkSoft)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(AppTheme.paperLight)
            }
        }
    }

    private var sourceList: some View {
        List {
            Section {
                Picker("兼容性", selection: $filter) {
                    ForEach(CatalogFilter.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)

                HStack {
                    Text("显示 \(filteredEntries.count) / \(entries.count)")
                    Spacer()
                    Text("已选 \(selectedIDs.count)")
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(AppTheme.inkSoft)
            }

            Section {
                ForEach(filteredEntries) { entry in
                    Button {
                        toggle(entry)
                    } label: {
                        CatalogSourceRow(
                            entry: entry,
                            isSelected: selectedIDs.contains(entry.id),
                            isImported: importedIDs.contains(entry.id)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(!entry.isImportable || isImporting)
                }
            } header: {
                Text("合集书源默认不启用，请先选择需要使用的条目")
            }
        }
        .scrollContentBackground(.hidden)
        .background(PaperBackground())
    }

    @ToolbarContentBuilder
    private var sourceToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button("选择当前筛选结果") {
                    selectedIDs.formUnion(filteredEntries.lazy.filter(\.isImportable).map(\.id))
                }
                Button("清空选择", role: .destructive) { selectedIDs.removeAll() }
                Divider()
                Button("导入已选 \(selectedIDs.count) 条") { importSelected() }
                    .disabled(selectedIDs.isEmpty || isImporting)
            } label: {
                if isImporting {
                    ProgressView()
                } else {
                    Image(systemName: "checklist")
                }
            }
        }
    }

    private func loadCatalog() async {
        guard entries.isEmpty else { return }
        do {
            let index = try await BundledSourceCatalog.shared.loadIndex()
            entries = index.entries
        } catch {
            message = error.localizedDescription
        }
        isLoading = false
    }

    private func toggle(_ entry: BundledSourceCatalogEntry) {
        if !selectedIDs.insert(entry.id).inserted { selectedIDs.remove(entry.id) }
    }

    private func importSelected() {
        let ids = selectedIDs
        isImporting = true
        message = "正在读取 \(ids.count) 条书源规则…"
        Task {
            do {
                var definitions = try await BundledSourceCatalog.shared.loadDefinitions(ids: ids)
                let autoEnabled = definitions.count <= 20
                definitions.indices.forEach { definitions[$0].enabled = autoEnabled }
                try await MainActor.run { try apply(definitions) }
                await MainActor.run {
                    selectedIDs.removeAll()
                    message = autoEnabled
                        ? "已导入并启用 \(definitions.count) 条书源"
                        : "已导入 \(definitions.count) 条书源；批量导入默认关闭，请按需启用"
                    isImporting = false
                }
            } catch {
                await MainActor.run {
                    message = "导入失败：\(error.localizedDescription)"
                    isImporting = false
                }
            }
        }
    }

    @MainActor
    private func apply(_ definitions: [BookSourceDefinition]) throws {
        let existing = Dictionary(uniqueKeysWithValues: existingSources.map { ($0.sourceID, $0) })
        for definition in definitions {
            if let record = existing[definition.id] {
                try record.apply(definition, preserveLocalSettings: true)
            } else {
                modelContext.insert(try BookSourceRecord(definition: definition))
            }
        }
        try modelContext.save()
    }
}

private struct CatalogSourceRow: View {
    let entry: BundledSourceCatalogEntry
    let isSelected: Bool
    let isImported: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: selectionIcon)
                .font(.title3)
                .foregroundStyle(selectionColor)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text(entry.name)
                        .font(.system(size: 16, weight: .semibold, design: .serif))
                        .foregroundStyle(AppTheme.ink)
                    Spacer(minLength: 8)
                    Text(isImported ? "已导入" : entry.status.title)
                        .font(.caption2.bold())
                        .foregroundStyle(statusColor)
                }
                Text("\(entry.group) · \(entry.host.nilIfBlank ?? entry.url)")
                    .font(.caption)
                    .foregroundStyle(AppTheme.inkSoft)
                    .lineLimit(1)
                if !entry.issues.isEmpty {
                    Text(entry.issues.map(\.title).joined(separator: " · "))
                        .font(.caption2)
                        .foregroundStyle(entry.isImportable ? AppTheme.ochre : AppTheme.vermilion)
                        .lineLimit(2)
                }
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 4)
    }

    private var selectionIcon: String {
        if isImported { return "checkmark.seal.fill" }
        if !entry.isImportable { return "nosign" }
        return isSelected ? "checkmark.circle.fill" : "circle"
    }

    private var selectionColor: Color {
        if isImported { return AppTheme.jade }
        if !entry.isImportable { return AppTheme.line }
        return isSelected ? AppTheme.vermilion : AppTheme.line
    }

    private var statusColor: Color {
        switch entry.status {
        case .compatible: AppTheme.jade
        case .partial: AppTheme.ochre
        case .unsupported: AppTheme.vermilion
        }
    }
}

private enum CatalogFilter: String, CaseIterable, Identifiable {
    case compatible
    case partial
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .compatible: "兼容"
        case .partial: "部分兼容"
        case .all: "全部"
        }
    }

    func includes(_ entry: BundledSourceCatalogEntry) -> Bool {
        switch self {
        case .compatible: entry.status == .compatible
        case .partial: entry.status == .partial
        case .all: true
        }
    }
}
