import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct SourceImportView: View {
    var file: ImportedFileAccess? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var existingSources: [BookSourceRecord]

    @State private var input = ""
    @State private var previewItems: [ImportPreviewItem] = []
    @State private var warnings: [String] = []
    @State private var errorMessage: String?
    @State private var isLoading = false
    @State private var showingFileImporter = false
    @State private var preserveLocalSettings = true

    var body: some View {
        NavigationStack {
            ZStack {
                PaperBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        introduction
                        TextEditor(text: $input)
                            .font(.system(.callout, design: .monospaced))
                            .frame(minHeight: 150)
                            .padding(10)
                            .scrollContentBackground(.hidden)
                            .background(.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 14))
                            .overlay {
                                RoundedRectangle(cornerRadius: 14)
                                    .stroke(AppTheme.line, lineWidth: 0.8)
                            }

                        inputActions

                        if isLoading { ProgressView("正在读取并校验书源…").frame(maxWidth: .infinity) }

                        if let errorMessage { InlineErrorView(message: errorMessage) }
                        if !warnings.isEmpty { warningList }
                        if !previewItems.isEmpty { previewList }
                    }
                    .padding(18)
                }
            }
            .navigationTitle("导入书源")
            .task { if let file { parseFile(file) } }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("确认导入", action: applyImport)
                        .disabled(!previewItems.contains(where: \.isSelected))
                }
            }
            .sheet(isPresented: $showingFileImporter) {
                DocumentImportPicker(multiple: false) { result in
                    switch result {
                    case .success(let urls): if let url = urls.first { parseFile(ImportedFileAccess(url)) }
                    case .failure(let error): errorMessage = error.localizedDescription
                    }
                    showingFileImporter = false
                }
            }
        }
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("粘贴 JSON 或书源地址")
                .font(AppTheme.sectionFont)
                .foregroundStyle(AppTheme.ink)
            Text("这里只导入 JSON / TXT 书源。EPUB、TXT、Word 和 Kindle 图书请到“书库”导入。支持部分 Legado CSS、JSONPath 与正则规则。")
                .font(.callout)
                .foregroundStyle(AppTheme.inkSoft)
        }
    }

    private var inputActions: some View {
        HStack {
            Button("选取文件") { showingFileImporter = true }
                .buttonStyle(.bordered)
            Button("载入精选源", action: loadCuratedSources)
                .buttonStyle(.bordered)
            Spacer()
            Button {
                parseText()
            } label: {
                if isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Label("解析预览", systemImage: "checkmark.magnifyingglass")
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(AppTheme.vermilion)
            .disabled(isLoading || input.nilIfBlank == nil)
        }
    }

    private var warningList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("导入提示", systemImage: "info.circle")
                .font(.headline)
                .foregroundStyle(AppTheme.ochre)
            ForEach(warnings, id: \.self) { warning in
                Text("· \(warning)")
                    .font(.caption)
                    .foregroundStyle(AppTheme.inkSoft)
            }
        }
        .inkCard()
    }

    private var previewList: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("更新时保留本地名称、分组和启用状态", isOn: $preserveLocalSettings)
                .font(.callout)
                .tint(AppTheme.vermilion)
            ForEach($previewItems) { $item in
                Toggle(isOn: $item.isSelected) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.source.bookSourceName)
                            .font(.headline)
                            .foregroundStyle(AppTheme.ink)
                        Text(item.status.title)
                            .font(.caption)
                            .foregroundStyle(item.status.color)
                    }
                }
                .tint(AppTheme.vermilion)
                .padding(.vertical, 5)
            }
        }
        .inkCard()
    }

    private func parseText() {
        isLoading = true
        errorMessage = nil
        Task {
            do {
                let result = try await SourceImporter().importText(input)
                await MainActor.run { applyPreview(result) }
            } catch {
                await MainActor.run { errorMessage = error.localizedDescription }
            }
            await MainActor.run { isLoading = false }
        }
    }

    private func parseFile(_ access: ImportedFileAccess) {
        isLoading = true
        errorMessage = nil
        Task {
            do {
                let result = try await SourceImporter().importFile(access.url)
                await MainActor.run { applyPreview(result) }
            } catch {
                await MainActor.run { errorMessage = error.localizedDescription }
            }
            await MainActor.run { isLoading = false }
        }
    }

    private func applyPreview(_ result: ImportedSources) {
        let existing = Dictionary(uniqueKeysWithValues: existingSources.map { ($0.sourceID, $0) })
        previewItems = result.sources.map { source in
            let status: ImportStatus
            if let local = existing[source.id] {
                status = source.updateTimestamp > local.lastUpdateTime ? .update : .existing
            } else {
                status = .new
            }
            return ImportPreviewItem(source: source, status: status, isSelected: status != .existing)
        }
        warnings = result.warnings
    }

    private func applyImport() {
        let existing = Dictionary(uniqueKeysWithValues: existingSources.map { ($0.sourceID, $0) })
        do {
            for item in previewItems where item.isSelected {
                if let local = existing[item.source.id] {
                    try local.apply(item.source, preserveLocalSettings: preserveLocalSettings)
                } else {
                    modelContext.insert(try BookSourceRecord(definition: item.source))
                }
            }
            try modelContext.save()
            dismiss()
        } catch {
            errorMessage = "写入书源失败：\(error.localizedDescription)"
        }
    }

    private func loadCuratedSources() {
        guard let url = Bundle.main.url(forResource: "community-sources", withExtension: "json"),
              let value = try? String(contentsOf: url, encoding: .utf8) else {
            errorMessage = "内置精选书源缺失"
            return
        }
        input = value
        parseText()
    }
}

private struct ImportPreviewItem: Identifiable {
    var source: BookSourceDefinition
    var status: ImportStatus
    var isSelected: Bool
    var id: String { source.id }
}

private enum ImportStatus: Equatable {
    case new
    case update
    case existing

    var title: String {
        switch self {
        case .new: "新增书源"
        case .update: "可更新"
        case .existing: "本地已有"
        }
    }

    var color: Color {
        switch self {
        case .new: AppTheme.jade
        case .update: AppTheme.vermilion
        case .existing: AppTheme.inkSoft
        }
    }
}
