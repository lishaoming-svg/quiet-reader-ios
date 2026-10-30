import SwiftUI

struct NativeReaderContentsView: View {
    let chapters: [BookChapter]
    let currentIndex: Int
    let selected: (Int) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    var body: some View {
        NavigationStack {
            List(chapters.filter { query.isEmpty || $0.title.localizedStandardContains(query) }) { chapter in
                Button { selected(chapter.index) } label: {
                    HStack { Text(chapter.title); Spacer(); if chapter.index == currentIndex { Image(systemName: "checkmark") } }
                }.foregroundStyle(.primary)
            }.searchable(text: $query, prompt: "搜索章节")
                .navigationTitle("目录").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}
