import SwiftUI

struct ReaderView: View {
    let book: SearchBook
    let chapters: [BookChapter]
    let initialIndex: Int
    let source: BookSourceDefinition
    var body: some View {
        if source.id == LocalBookStorage.sourceID {
            NativeTextReaderView(book: book, chapters: chapters, initialIndex: initialIndex, source: source)
        } else {
            EPUBReaderView(book: book, chapters: chapters, source: source, initialIndex: initialIndex)
        }
    }
}
