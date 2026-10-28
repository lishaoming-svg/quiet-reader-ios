import SwiftData
import SwiftUI

struct BookshelfReaderDestination: View {
    @Environment(\.modelContext) private var modelContext

    let source: BookSourceDefinition
    let resumeChapterURL: String?
    let resumeChapterIndex: Int?

    @State private var book: SearchBook
    @State private var chapters: [BookChapter]
    @State private var initialIndex: Int
    @State private var isLoading: Bool
    @State private var errorMessage: String?

    init(
        book: SearchBook,
        source: BookSourceDefinition,
        cachedChapters: [BookChapter],
        resumeChapterURL: String?,
        resumeChapterIndex: Int?
    ) {
        self.source = source
        self.resumeChapterURL = resumeChapterURL
        self.resumeChapterIndex = resumeChapterIndex
        _book = State(initialValue: book)
        _chapters = State(initialValue: cachedChapters)
        _initialIndex = State(
            initialValue: ReaderResumeResolver.chapterIndex(
                in: cachedChapters,
                chapterURL: resumeChapterURL,
                fallbackIndex: resumeChapterIndex
            )
        )
        _isLoading = State(initialValue: cachedChapters.isEmpty)
    }

    var body: some View {
        Group {
            if book.sourceID == LocalBookStorage.sourceID, book.kind == "EPUB", !chapters.isEmpty {
                EPUBReaderView(book: book, chapters: chapters)
            } else if !chapters.isEmpty {
                ReaderView(
                    book: book,
                    chapters: chapters,
                    initialIndex: initialIndex,
                    source: source
                )
            } else {
                ZStack {
                    PaperBackground()
                    if isLoading {
                        VStack(spacing: 12) {
                            ProgressView().tint(AppTheme.vermilion)
                            Text("首次读取目录，完成后将直接续读")
                                .foregroundStyle(AppTheme.inkSoft)
                        }
                    } else {
                        VStack(spacing: 16) {
                            InlineErrorView(message: errorMessage ?? "目录读取失败")
                            Button("重新读取目录") {
                                Task { await loadDirectory() }
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(AppTheme.vermilion)
                        }
                        .padding(24)
                    }
                }
                .navigationTitle(book.name)
                .navigationBarTitleDisplayMode(.inline)
            }
        }
        .task {
            if chapters.isEmpty { await loadDirectory() }
        }
    }

    private func loadDirectory() async {
        isLoading = true
        errorMessage = nil
        do {
            let detailed = try await SourceEngine().loadDetails(book: book, source: source)
            let loaded = try await SourceEngine().loadChapters(book: detailed, source: source)
            guard !loaded.isEmpty else {
                throw SourceEngineError.emptyChapterList
            }
            guard !Task.isCancelled else { return }
            try? ChapterListCacheStore.save(
                chapters: loaded,
                bookID: detailed.id,
                sourceID: source.id,
                in: modelContext
            )
            book = detailed
            initialIndex = ReaderResumeResolver.chapterIndex(
                in: loaded,
                chapterURL: resumeChapterURL,
                fallbackIndex: resumeChapterIndex
            )
            chapters = loaded
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}
