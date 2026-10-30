import ReadiumShared
import SwiftData
import SwiftUI

struct NativeContinuousCanvas: View {
    let book: SearchBook
    let chapters: [BookChapter]
    let source: BookSourceDefinition
    let initial: ContinuousReadingPosition
    let theme: String
    let fontSize: Double
    let typography: [String: Any]
    let scrolled: () -> Void
    let changed: (ContinuousReadingPosition) -> Void
    let installNavigation: (@escaping (ContinuousReadingPosition) -> Void) -> Void
    @Environment(\.modelContext) private var context
    @State private var publication: Publication?
    @State private var error: String?
    var body: some View {
        Group {
            if let publication {
                ContinuousPublicationView(publication: publication, initial: initial, theme: theme,
                    publisherStyles: false, fontSize: fontSize / 18 * 100, typography: typography, scrolled: scrolled, changed: changed,
                    tapped: {}, ready: {}, failure: { error = $0 }, installNavigation: installNavigation)
            } else { ProgressView("正在展开连续正文…") }
        }
        .task {
            guard publication == nil else { return }
            publication = SourceChapterRepository(book: book, chapters: chapters, source: source, context: context).publication()
        }
        .overlay(alignment: .bottom) {
            if let error { InlineErrorView(message: error).padding(20).onTapGesture { self.error = nil } }
        }
    }
}
