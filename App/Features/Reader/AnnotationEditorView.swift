import SwiftData
import SwiftUI

enum AnnotationColor: String, CaseIterable, Identifiable {
    case yellow, green, blue, pink, purple
    var id: String { rawValue }
    var title: String { switch self { case .yellow: "黄色"; case .green: "绿色"; case .blue: "蓝色"; case .pink: "粉色"; case .purple: "紫色" } }
    var color: Color { switch self { case .yellow: .yellow; case .green: .green; case .blue: .blue; case .pink: .pink; case .purple: .purple } }
}

enum AnnotationTextExporter {
    static func text(_ marks: [BookmarkRecord]) -> String {
        marks.map { mark in
            [mark.bookName, mark.chapterTitle, mark.excerpt.isEmpty ? nil : "> " + mark.excerpt,
             mark.note.isEmpty ? nil : mark.note, mark.createdAt.formatted(date: .abbreviated, time: .omitted)]
                .compactMap { $0 }.joined(separator: "\n\n")
        }.joined(separator: "\n\n---\n\n")
    }
}

struct AnnotationEditorView: View {
    let bookmark: BookmarkRecord
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var note: String
    @State private var color: String
    @State private var error: String?
    @State private var saved = false
    private let newRecord: Bool
    init(bookmark: BookmarkRecord) {
        self.bookmark = bookmark
        newRecord = bookmark.modelContext == nil
        _note = State(initialValue: bookmark.note)
        _color = State(initialValue: bookmark.annotationColor ?? "yellow")
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text(bookmark.bookName).font(.headline)
                    Text(bookmark.chapterTitle).font(.subheadline).foregroundStyle(.secondary)
                    if !bookmark.excerpt.isEmpty {
                        Text(bookmark.excerpt).font(.body).lineSpacing(7).textSelection(.enabled)
                            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                            .background((AnnotationColor(rawValue: color) ?? .yellow).color.opacity(0.18), in: RoundedRectangle(cornerRadius: 12))
                    }
                    HStack(spacing: 18) {
                        ForEach(AnnotationColor.allCases) { item in
                            Button { color = item.rawValue } label: {
                                Circle().fill(item.color.opacity(0.7)).frame(width: 36, height: 36)
                                    .overlay { if color == item.rawValue { Image(systemName: "checkmark").font(.headline).foregroundStyle(.black) } }
                            }.accessibilityLabel(item.title).accessibilityAddTraits(color == item.rawValue ? .isSelected : [])
                        }
                    }
                    TextEditor(text: $note).frame(minHeight: 180).padding(8)
                        .scrollContentBackground(.hidden).background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                        .accessibilityLabel("笔记内容").accessibilityIdentifier("annotation.note")
                    if let error { Text(error).foregroundStyle(.red) }
                }.padding(24)
            }.navigationTitle("笔记").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") {
                            let oldNote = bookmark.note, oldColor = bookmark.annotationColor, oldKind = bookmark.noteKind
                            bookmark.note = note.trimmingCharacters(in: .whitespacesAndNewlines); bookmark.annotationColor = color
                            if bookmark.noteKind == "bookmark", !bookmark.note.isEmpty { bookmark.noteKind = "note" }
                            if bookmark.modelContext == nil { context.insert(bookmark) }
                            do { try context.save(); saved = true; dismiss() }
                            catch { bookmark.note = oldNote; bookmark.annotationColor = oldColor; bookmark.noteKind = oldKind; self.error = error.localizedDescription }
                        }.accessibilityIdentifier("annotation.save")
                    }
                }
        }
        .onDisappear {
            if newRecord && !saved && bookmark.modelContext != nil { context.delete(bookmark) }
        }
    }
}
