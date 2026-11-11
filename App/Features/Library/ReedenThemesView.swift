import SwiftUI
import UIKit
import UniformTypeIdentifiers

@MainActor
final class ReedenThemesModel: ObservableObject {
    @Published private(set) var records: [ReedenThemeRecord] = []
    @Published private(set) var progress: String?
    @Published var message: String?
    let library = ReedenThemeLibrary.shared
    private var pending: [ImportedFileAccess] = []

    func reload() async {
        do { records = try await library.records() }
        catch { message = "读取主题失败：\(error.localizedDescription)" }
    }

    func enqueue(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        pending.append(contentsOf: urls.map(ImportedFileAccess.init))
        guard progress == nil else { return }
        progress = "准备导入"
        Task {
            var duplicates = 0
            var imported = 0
            var errors: [String] = []
            while !pending.isEmpty {
                let file = pending.removeFirst()
                progress = file.url.lastPathComponent
                do {
                    if try await library.importFile(file) { imported += 1 }
                    else { duplicates += 1 }
                } catch {
                    errors.append("\(file.url.lastPathComponent)：\(error.localizedDescription)")
                }
            }
            progress = nil
            await reload()
            if !errors.isEmpty || duplicates > 0 {
                message = (["已导入 \(imported) 个，重复 \(duplicates) 个，失败 \(errors.count) 个。"]
                           + Array(errors.prefix(5))).joined(separator: "\n")
            }
        }
    }

    func remove(_ record: ReedenThemeRecord) {
        Task {
            do {
                try await library.remove(record)
                await reload()
            } catch { message = "删除失败：\(error.localizedDescription)" }
        }
    }
}

struct ReedenThemesView: View {
    @ObservedObject var model: ReedenThemesModel
    @State private var choosingFiles = false
    @State private var deleting: ReedenThemeRecord?

    private struct CreatorGroup: Identifiable {
        let id: String?
        let records: [ReedenThemeRecord]
        var name: String { id ?? "未署名" }
    }

    private var groups: [CreatorGroup] {
        let sorted = model.records.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return Dictionary(grouping: sorted, by: \.creator)
            .map { CreatorGroup(id: $0.key, records: $0.value) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        Group {
            if model.records.isEmpty && model.progress == nil {
                ContentUnavailableView {
                    Label("还没有 Reeden 主题", systemImage: "paintpalette")
                } description: {
                    Text("导入 RED 主题、封面图集或主题 JSON，按制作人整理并生成预览。")
                } actions: {
                    Button("导入主题") { choosingFiles = true }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("reeden.emptyImport")
                }
            } else {
                List {
                    if let progress = model.progress {
                        ProgressView { Text("正在导入 \(progress)").lineLimit(2) }
                    }
                    ForEach(groups) { group in
                        Section(group.name) {
                            ForEach(group.records) { record in
                                NavigationLink {
                                    ReedenThemeDetail(record: record, library: model.library)
                                } label: {
                                    HStack(spacing: 12) {
                                        ReedenThemeImage(url: model.library.preview(record))
                                            .frame(width: 72, height: 60)
                                            .clipShape(.rect(cornerRadius: 8))
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(record.name)
                                            Text(record.kind == .privateTheme ? "加密主题" : record.kind == .gallery ? "封面图集" : "应用主题")
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                .swipeActions(allowsFullSwipe: false) {
                                    Button("删除", systemImage: "trash", role: .destructive) { deleting = record }
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Reeden 主题")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("导入主题", systemImage: "plus") { choosingFiles = true }
                    .labelStyle(.iconOnly)
                    .accessibilityIdentifier("reeden.import")
            }
        }
        .sheet(isPresented: $choosingFiles) {
            DocumentImportPicker(contentTypes: [.data, .json, .reedenTheme]) { result in
                choosingFiles = false
                switch result {
                case .success(let urls): model.enqueue(urls)
                case .failure(let error): model.message = error.localizedDescription
                }
            }
        }
        .alert("主题导入结果", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button("好") { model.message = nil }
        } message: { Text(model.message ?? "") }
        .confirmationDialog("删除此主题？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { record in
            Button("删除", role: .destructive) { model.remove(record) }
        }
        .task { await model.reload() }
    }
}

private struct ReedenThemeDetail: View {
    let record: ReedenThemeRecord
    let library: ReedenThemeLibrary
    @State private var choosingExport = false
    @State private var exportFiles = false
    @State private var showingFiles = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ReedenThemeImage(url: library.preview(record))
                    .aspectRatio(1.2, contentMode: .fit)
                    .clipShape(.rect(cornerRadius: 14))
                    .accessibilityHidden(true)
                Text(record.name).font(.title2.bold())
                LabeledContent("制作人", value: record.creator ?? "未署名")
                if record.kind == .privateTheme {
                    Text(record.hasArtwork ? "预览展示包内图片素材。主题配色配置已加密。" : "主题配色配置已加密，包内没有可预览的图片。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Button("上传到网盘", systemImage: "icloud.and.arrow.up") { choosingExport = true }
                    .buttonStyle(.borderedProminent)
            }
            .padding()
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("主题预览")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $choosingExport, onDismiss: {
            if exportFiles { exportFiles = false; showingFiles = true }
        }) {
            NavigationStack {
                List {
                    Section {
                        ShareLink(item: library.original(record)) { Label("分享原文件", systemImage: "square.and.arrow.up") }
                        ShareLink(item: library.preview(record)) { Label("分享预览图", systemImage: "photo") }
                        Button("原文件和预览图存入“文件”", systemImage: "folder") {
                            exportFiles = true
                            choosingExport = false
                        }
                    } footer: {
                        Text("若分享面板提供百度网盘或夸克网盘，可直接交给网盘客户端。也可先存入“文件”，再到已登录的网盘中选取并上传。")
                    }
                }
                .navigationTitle("上传到网盘")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("关闭") { choosingExport = false } }
                }
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showingFiles) {
            ReedenThemeExportPicker(urls: [library.original(record), library.preview(record)])
        }
    }
}

private struct ReedenThemeImage: View {
    let url: URL

    var body: some View {
        Group {
            if let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image).resizable().scaledToFit().accessibilityHidden(true)
            } else {
                Image(systemName: "photo").foregroundStyle(.secondary)
            }
        }
    }
}

private struct ReedenThemeExportPicker: UIViewControllerRepresentable {
    @Environment(\.dismiss) private var dismiss
    let urls: [URL]

    func makeCoordinator() -> Coordinator { Coordinator(dismiss: dismiss) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let controller = UIDocumentPickerViewController(forExporting: urls, asCopy: true)
        controller.delegate = context.coordinator
        return controller
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let dismiss: DismissAction
        init(dismiss: DismissAction) { self.dismiss = dismiss }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { dismiss() }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { dismiss() }
    }
}

extension UTType {
    static let reedenTheme = UTType(importedAs: "com.quietreader.reeden-theme", conformingTo: .data)
}
