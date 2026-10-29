import SwiftData
import SwiftUI

struct ImportedNotesView: View {
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \BookmarkRecord.createdAt, order: .reverse) private var notes: [BookmarkRecord]
    @State private var query = ""
    var body: some View {
        NavigationStack {
            List {
                if notes.isEmpty { ContentUnavailableView("还没有笔记", systemImage: "note.text", description: Text("导入 Reeden 完整备份后，笔记和书签会显示在这里。")) }
                ForEach(notes.filter { query.isEmpty || $0.bookName.localizedStandardContains(query) || $0.excerpt.localizedStandardContains(query) || $0.note.localizedStandardContains(query) }) { mark in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(mark.bookName).font(.headline)
                        Text(mark.chapterTitle).font(.caption).foregroundStyle(.secondary)
                        if !mark.excerpt.isEmpty { Text(mark.excerpt).font(.body).textSelection(.enabled) }
                        if !mark.note.isEmpty { Label(mark.note, systemImage: "pencil.line").font(.subheadline).textSelection(.enabled) }
                        Text(mark.createdAt.formatted(date: .abbreviated, time: .omitted)).font(.caption2).foregroundStyle(.secondary)
                    }.padding(.vertical, 10)
                }
            }.navigationTitle("笔记与书签").searchable(text: $query, prompt: "书名、摘录或笔记")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}
struct ImportedFontsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("reader.importedFont") private var selected = ""
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if ImportedFontStore.fonts.isEmpty { Text("从书库导入 Reeden 完整备份，即可迁移字体文件。字体不会自动替换当前阅读设置。") }
                    else {
                        Picker("文字阅读字体", selection: $selected) {
                            Text("系统字体").tag("")
                            ForEach(ImportedFontStore.fonts) { font in Text(font.name).tag(font.postScriptName) }
                        }
                        Text("字体文件已保存在本机。原书精排仍使用 EPUB 自带字体。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }.navigationTitle("已导入的字体").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}
