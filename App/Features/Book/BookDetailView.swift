import SwiftData
import SwiftUI

struct BookDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \BookSourceRecord.sourceName) private var sourceRecords: [BookSourceRecord]

    let alternatives: [SearchBook]
    @State private var source: BookSourceDefinition
    @State private var book: SearchBook
    @State private var chapters: [BookChapter] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var isInBookshelf = false
    @State private var resumeIndex: Int?
    @State private var cacheTask: Task<Void, Never>?
    @State private var cacheProgress: BatchCacheProgress?

    init(
        book: SearchBook,
        source: BookSourceDefinition,
        alternatives: [SearchBook] = []
    ) {
        self.alternatives = alternatives.isEmpty ? [book] : alternatives
        _source = State(initialValue: source)
        _book = State(initialValue: book)
    }

    var body: some View {
        ZStack {
            PaperBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    if let intro = book.intro.nilIfBlank {
                        section(title: "简介") {
                            Text(intro)
                                .font(.body)
                                .foregroundStyle(AppTheme.inkSoft)
                                .lineSpacing(5)
                        }
                    }
                    if let errorMessage { InlineErrorView(message: errorMessage) }
                    chapterSection
                }
                .padding(18)
            }
        }
        .navigationTitle(book.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(AppTheme.paperLight, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .task { await loadBook() }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 18) {
            BookCoverView(urlString: book.coverURL, title: book.name, width: 104, height: 148)
            VStack(alignment: .leading, spacing: 8) {
                Text(book.name)
                    .font(.system(size: 24, weight: .bold, design: .serif))
                    .foregroundStyle(AppTheme.ink)
                Text(book.author.nilIfBlank ?? "作者未知")
                    .font(.headline)
                    .foregroundStyle(AppTheme.inkSoft)
                if let kind = book.kind.nilIfBlank {
                    Text(kind)
                        .font(.caption)
                        .foregroundStyle(AppTheme.jade)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(AppTheme.jade.opacity(0.10), in: Capsule())
                }
                Label(book.sourceName, systemImage: "network")
                    .font(.caption)
                    .foregroundStyle(AppTheme.inkSoft)
                if availableAlternatives.count > 1 {
                    Menu {
                        ForEach(availableAlternatives) { choice in
                            Button {
                                switchSource(to: choice.book, source: choice.source)
                            } label: {
                                if choice.source.id == source.id {
                                    Label(choice.source.bookSourceName, systemImage: "checkmark")
                                } else {
                                    Text(choice.source.bookSourceName)
                                }
                            }
                        }
                    } label: {
                        Label(
                            "换源 · \(availableAlternatives.count) 个可用来源",
                            systemImage: "arrow.triangle.swap"
                        )
                        .font(.caption.bold())
                    }
                    .tint(AppTheme.jade)
                }
                Spacer(minLength: 4)
                Button(action: toggleBookshelf) {
                    Label(
                        isInBookshelf ? "已在书架" : "加入书架",
                        systemImage: isInBookshelf ? "checkmark" : "plus"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(isInBookshelf ? AppTheme.jade : AppTheme.vermilion)
            }
        }
        .inkCard()
    }

    private var availableAlternatives: [BookSourceChoice] {
        alternatives.compactMap { candidate in
            guard let definition = sourceRecords.first(where: {
                $0.sourceID == candidate.sourceID && $0.enabled
            })?.definition else { return nil }
            return BookSourceChoice(book: candidate, source: definition)
        }
    }

    private func switchSource(to candidate: SearchBook, source definition: BookSourceDefinition) {
        guard definition.id != source.id || candidate.bookURL != book.bookURL else { return }
        cacheTask?.cancel()
        source = definition
        book = candidate
        chapters = []
        resumeIndex = nil
        cacheProgress = nil
        errorMessage = nil
        isLoading = true
        refreshBookshelfState()
        Task { await loadBook() }
    }

    @ViewBuilder
    private var chapterSection: some View {
        section(title: "目录") {
            cacheControls
            if isLoading {
                HStack {
                    ProgressView().tint(AppTheme.vermilion)
                    Text("正在读取目录…")
                        .foregroundStyle(AppTheme.inkSoft)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 18)
            } else {
                if let resumeIndex, chapters.indices.contains(resumeIndex) {
                    NavigationLink {
                        ReaderView(
                            book: book,
                            chapters: chapters,
                            initialIndex: resumeIndex,
                            source: source
                        )
                    } label: {
                        Label(
                            "继续阅读 · \(chapters[resumeIndex].title)",
                            systemImage: "bookmark.fill"
                        )
                        .font(.subheadline.bold())
                        .foregroundStyle(AppTheme.vermilion)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                    Divider().overlay(AppTheme.line.opacity(0.5))
                }
                ForEach(chapters) { chapter in
                    NavigationLink {
                        ReaderView(
                            book: book,
                            chapters: chapters,
                            initialIndex: chapter.index,
                            source: source
                        )
                    } label: {
                        HStack {
                            Text(chapter.title)
                                .font(.system(.body, design: .serif))
                                .foregroundStyle(AppTheme.ink)
                                .lineLimit(2)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.bold())
                                .foregroundStyle(AppTheme.line)
                        }
                        .padding(.vertical, 9)
                    }
                    .buttonStyle(.plain)
                    if chapter.id != chapters.last?.id {
                        Divider().overlay(AppTheme.line.opacity(0.5))
                    }
                }
            }
        }
    }

    private var cacheControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("共 \(chapters.count) 章", systemImage: "list.number")
                    .font(.caption)
                    .foregroundStyle(AppTheme.inkSoft)
                Spacer()
                if cacheProgress?.isRunning == true {
                    Button("取消") { cacheTask?.cancel() }
                        .font(.caption.bold())
                        .foregroundStyle(AppTheme.vermilion)
                } else {
                    Menu {
                        Button("缓存后续 20 章") { startCaching(maximumCount: 20) }
                        Button("缓存全书") { startCaching(maximumCount: nil) }
                    } label: {
                        Label("批量缓存", systemImage: "arrow.down.circle")
                            .font(.caption.bold())
                    }
                    .disabled(chapters.isEmpty || isLoading)
                }
            }
            if let progress = cacheProgress {
                ProgressView(value: Double(progress.completed), total: Double(max(progress.total, 1)))
                    .tint(AppTheme.vermilion)
                Text(progress.statusText)
                    .font(.caption)
                    .foregroundStyle(progress.failed > 0 ? AppTheme.vermilion : AppTheme.inkSoft)
                    .lineLimit(2)
            }
            Divider().overlay(AppTheme.line.opacity(0.5))
        }
    }

    private func section<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(AppTheme.sectionFont)
                .foregroundStyle(AppTheme.ink)
            content()
        }
        .inkCard()
    }

    private func loadBook() async {
        refreshBookshelfState()
        do {
            let detailed = try await SourceEngine().loadDetails(book: book, source: source)
            book = detailed
            chapters = try await SourceEngine().loadChapters(book: detailed, source: source)
            loadReadingProgress()
            if isInBookshelf { updateStoredBook() }
        } catch {
            errorMessage = error.localizedDescription
            if chapters.isEmpty {
                chapters = [BookChapter(title: "全文", url: book.bookURL, index: 0)]
            }
            loadReadingProgress()
        }
        isLoading = false
    }

    private func refreshBookshelfState() {
        let bookID = book.id
        let descriptor = FetchDescriptor<BookRecord>(
            predicate: #Predicate { $0.bookID == bookID }
        )
        isInBookshelf = ((try? modelContext.fetchCount(descriptor)) ?? 0) > 0
    }

    private func toggleBookshelf() {
        let bookID = book.id
        let descriptor = FetchDescriptor<BookRecord>(
            predicate: #Predicate { $0.bookID == bookID }
        )
        if let stored = try? modelContext.fetch(descriptor).first {
            modelContext.delete(stored)
            isInBookshelf = false
        } else {
            modelContext.insert(BookRecord(book: book))
            isInBookshelf = true
        }
        try? modelContext.save()
    }

    private func updateStoredBook() {
        let bookID = book.id
        let descriptor = FetchDescriptor<BookRecord>(
            predicate: #Predicate { $0.bookID == bookID }
        )
        if let stored = try? modelContext.fetch(descriptor).first {
            stored.update(from: book)
            try? modelContext.save()
        }
    }

    private func loadReadingProgress() {
        let bookID = book.id
        let descriptor = FetchDescriptor<ReadingProgressRecord>(
            predicate: #Predicate { $0.bookID == bookID }
        )
        guard let progress = try? modelContext.fetch(descriptor).first else { return }
        resumeIndex = chapters.indices.contains(progress.chapterIndex)
            ? progress.chapterIndex
            : chapters.firstIndex(where: { $0.url == progress.chapterURL })
    }

    private func startCaching(maximumCount: Int?) {
        guard !chapters.isEmpty else { return }
        let startIndex = min(max(resumeIndex ?? 0, 0), chapters.count - 1)
        let remaining = chapters.dropFirst(startIndex)
        let targets = maximumCount.map { Array(remaining.prefix($0)) } ?? Array(remaining)
        cacheTask?.cancel()
        cacheProgress = BatchCacheProgress(total: targets.count)
        cacheTask = Task { await cache(targets) }
    }

    private func cache(_ targets: [BookChapter]) async {
        var completed = 0
        var failed = 0

        for chapter in targets {
            if Task.isCancelled { break }
            cacheProgress?.currentTitle = chapter.title

            let key = "\(source.id)::\(chapter.url)"
            let descriptor = FetchDescriptor<ChapterCacheRecord>(
                predicate: #Predicate { $0.cacheKey == key }
            )
            if ((try? modelContext.fetchCount(descriptor)) ?? 0) == 0 {
                do {
                    let content = try await SourceEngine().loadContent(chapter: chapter, source: source)
                    modelContext.insert(
                        ChapterCacheRecord(
                            sourceID: source.id,
                            bookID: book.id,
                            chapter: chapter,
                            content: content
                        )
                    )
                    try modelContext.save()
                } catch {
                    failed += 1
                }
            }
            completed += 1
            cacheProgress?.completed = completed
            cacheProgress?.failed = failed
        }

        cacheProgress?.isRunning = false
        cacheProgress?.wasCancelled = Task.isCancelled
    }
}

private struct BookSourceChoice: Identifiable {
    var book: SearchBook
    var source: BookSourceDefinition

    var id: String { book.id }
}

private struct BatchCacheProgress {
    let total: Int
    var completed = 0
    var failed = 0
    var currentTitle = ""
    var isRunning = true
    var wasCancelled = false

    var statusText: String {
        if isRunning {
            return "正在缓存 \(completed)/\(total)：\(currentTitle)"
        }
        if wasCancelled {
            return "已取消，完成 \(completed)/\(total)，失败 \(failed) 章"
        }
        return "缓存完成 \(completed)/\(total)，失败 \(failed) 章"
    }
}
