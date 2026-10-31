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
    @State private var cacheGeneration = UUID()
    @State private var cacheProgress: BatchCacheProgress?
    @State private var showingLogin = false
    @State private var showingExport = false
    @State private var isExporting = false
    @State private var exportDocument: EPUBExportDocument?
    @State private var chapterQuery = ""
    @State private var downloadFailures: [String: ChapterDownloadFailure] = [:]
    @State private var showingFailures = false
    @State private var exportAfterDownload = false

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
        .sheet(isPresented: $showingLogin) {
            SourceLoginView(source: source) { Task { await loadBook() } }
        }
        .sheet(isPresented: $showingFailures) { failureList }
        .fileExporter(isPresented: $showingExport, document: exportDocument, contentType: .epub,
                      defaultFilename: BookEPUBExporter.filename(book.name)) { result in
            if case .failure(let error) = result, (error as NSError).code != NSUserCancelledError {
                errorMessage = "导出失败：\(error.localizedDescription)"
            }
            exportDocument = nil
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if source.loginUrl?.nilIfBlank != nil {
                    Button("登录书源", systemImage: "person.crop.circle") { showingLogin = true }
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 18) {
            BookCoverView(urlString: book.coverURL, title: book.name, width: 104, height: 148)
            VStack(alignment: .leading, spacing: 8) {
                Text(book.name)
                    .font(.system(size: 28, weight: .bold))
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
                if !switchableAlternatives.isEmpty {
                    Menu {
                        ForEach(switchableAlternatives) { choice in
                            Button {
                                switchSource(to: choice.book, source: choice.source)
                            } label: {
                                Text(choice.source.bookSourceName)
                            }
                        }
                    } label: {
                        Label(
                            "换源 · \(switchableAlternatives.count) 个可用来源",
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
        .padding(.vertical, 12)
    }

    private var availableAlternatives: [BookSourceChoice] {
        alternatives.compactMap { candidate in
            guard let definition = sourceRecords.first(where: {
                $0.sourceID == candidate.sourceID && $0.enabled
            })?.definition else { return nil }
            return BookSourceChoice(book: candidate, source: definition)
        }
    }

    private var switchableAlternatives: [BookSourceChoice] {
        availableAlternatives.filter {
            $0.source.id != source.id || $0.book.bookURL != book.bookURL
        }
    }

    private func switchSource(to candidate: SearchBook, source definition: BookSourceDefinition) {
        guard definition.id != source.id || candidate.bookURL != book.bookURL else { return }
        cacheTask?.cancel()
        cacheGeneration = UUID()
        source = definition
        book = candidate
        chapters = []
        resumeIndex = nil
        cacheProgress = nil
        downloadFailures = [:]
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
                TextField("搜索章节", text: $chapterQuery)
                    .textFieldStyle(.roundedBorder).padding(.vertical, 8)
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
                LazyVStack(spacing: 0) {
                ForEach(chapters.filter { chapterQuery.isEmpty || $0.title.localizedStandardContains(chapterQuery) }) { chapter in
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
                                .font(.body)
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
                        Button("下载全书到书库") { startCaching(maximumCount: nil) }
                        Button("下载全书并导出 EPUB") { startCaching(maximumCount: nil, exportAfter: true) }
                        Button("重试失败章节（\(downloadFailures.count)）") { startCaching(maximumCount: nil, retryOnly: true) }
                            .disabled(downloadFailures.isEmpty)
                        Button(isExporting ? "正在生成 EPUB…" : "导出已下载的全书 EPUB") { exportBook() }
                            .disabled(isExporting)
                    } label: {
                        Label("下载与导出", systemImage: "arrow.down.circle")
                            .font(.caption.bold())
                    }
                    .disabled(chapters.isEmpty || isLoading)
                }
            }
            if let progress = cacheProgress {
                ProgressView(value: Double(progress.succeeded), total: Double(max(progress.total, 1)))
                    .tint(AppTheme.vermilion)
                Text(progress.statusText)
                    .font(.caption)
                    .foregroundStyle(progress.failed > 0 ? AppTheme.vermilion : AppTheme.inkSoft)
                    .lineLimit(2)
            }
            if !downloadFailures.isEmpty {
                Button("查看 \(downloadFailures.count) 章失败原因", systemImage: "exclamationmark.triangle") { showingFailures = true }
                    .font(.subheadline)
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
        .padding(.vertical, 12)
    }

    private func loadBook() async {
        errorMessage = nil
        isLoading = chapters.isEmpty
        refreshBookshelfState()
        do {
            let detailed = try await SourceEngine().loadDetails(book: book, source: source)
            book = detailed
            chapters = try await SourceEngine().loadChapters(book: detailed, source: source)
            restoreDownloadFailures()
            try? ChapterListCacheStore.save(
                chapters: chapters,
                bookID: detailed.id,
                sourceID: source.id,
                in: modelContext
            )
            loadReadingProgress()
            if isInBookshelf { updateStoredBook() }
        } catch {
            errorMessage = error.localizedDescription
            let hasIncompatibleDirectory = (error as? SourceEngineError) == .incompatiblePageDirectory
            if chapters.isEmpty, !hasIncompatibleDirectory {
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
        resumeIndex = ReaderResumeResolver.chapterIndex(
            in: chapters,
            chapterURL: progress.chapterURL,
            fallbackIndex: progress.chapterIndex
        )
    }

    private func startCaching(maximumCount: Int?, retryOnly: Bool = false, exportAfter: Bool = false) {
        guard !chapters.isEmpty else { return }
        if !isInBookshelf { toggleBookshelf() }
        errorMessage = nil
        let startIndex = min(max(resumeIndex ?? 0, 0), chapters.count - 1)
        let remaining = chapters.dropFirst(startIndex)
        let targets = retryOnly ? chapters.filter { downloadFailures[$0.url] != nil }
            : maximumCount.map { Array(remaining.prefix($0)) } ?? chapters
        guard !targets.isEmpty else { return }
        exportAfterDownload = exportAfter || (retryOnly && exportAfterDownload)
        cacheTask?.cancel()
        cacheProgress = BatchCacheProgress(total: targets.count)
        cacheGeneration = UUID()
        let generation = cacheGeneration
        cacheTask = Task { await cache(targets, generation: generation) }
    }

    private func cache(_ targets: [BookChapter], generation: UUID) async {
        let downloadSource = source, downloadBookID = book.id
        var completed = 0
        var failed = 0
        var pending: [BookChapter] = []
        for chapter in targets {
            let key = "\(downloadSource.id)::\(chapter.url)"
            let descriptor = FetchDescriptor<ChapterCacheRecord>(
                predicate: #Predicate { $0.cacheKey == key }
            )
            if let cached = try? modelContext.fetch(descriptor).first, !cached.content.isEmpty, cached.htmlContent != nil, cached.downloadError == nil { completed += 1 }
            else { pending.append(chapter) }
        }
        cacheProgress?.completed = completed
        await withTaskGroup(of: ChapterDownloadOutcome.self) { group in
            var next = 0
            func enqueue(_ index: Int) {
                let chapter = pending[index]
                group.addTask {
                    do {
                        try Task.checkCancellation()
                        let content = try await SourceEngine().loadDocument(chapter: chapter, source: downloadSource)
                        return ChapterDownloadOutcome(chapter: chapter, content: content)
                    } catch {
                        return ChapterDownloadOutcome(chapter: chapter, error: error.localizedDescription,
                            authentication: (error as? SourceEngineError)?.requiresAuthentication == true)
                    }
                }
            }
            let concurrency = NativeLofterAdapter.accepts(downloadSource) ? 2 : 4
            while next < min(concurrency, pending.count) { enqueue(next); next += 1 }
            for await outcome in group {
                guard !Task.isCancelled, cacheGeneration == generation else { group.cancelAll(); break }
                cacheProgress?.currentTitle = outcome.chapter.title
                if let content = outcome.content {
                    do {
                        let key = "\(downloadSource.id)::\(outcome.chapter.url)"
                        let query = FetchDescriptor<ChapterCacheRecord>(predicate: #Predicate { $0.cacheKey == key })
                        let record = try modelContext.fetch(query).first ?? ChapterCacheRecord(sourceID: downloadSource.id,
                            bookID: downloadBookID, chapter: outcome.chapter, content: content.text)
                        record.content = content.text; record.htmlContent = content.html; record.cachedAt = .now; record.downloadError = nil
                        if record.modelContext == nil { modelContext.insert(record) }
                        try modelContext.save()
                        downloadFailures.removeValue(forKey: outcome.chapter.url)
                    } catch {
                        failed += 1
                        downloadFailures[outcome.chapter.url] = ChapterDownloadFailure(chapter: outcome.chapter, reason: "保存失败：" + error.localizedDescription)
                    }
                } else {
                    failed += 1
                    downloadFailures[outcome.chapter.url] = ChapterDownloadFailure(chapter: outcome.chapter, reason: outcome.error ?? "正文加载失败")
                    saveDownloadFailure(outcome.chapter, reason: outcome.error ?? "正文加载失败", sourceID: downloadSource.id, bookID: downloadBookID)
                    if outcome.authentication {
                        errorMessage = "书源需要登录，请点右上角“登录书源”，完成后重新下载。"
                        cacheProgress?.failed = failed
                        cacheProgress?.completed = completed + 1
                        group.cancelAll(); break
                    }
                }
                completed += 1
                cacheProgress?.completed = completed
                cacheProgress?.failed = failed
                if next < pending.count { enqueue(next); next += 1 }
            }
        }

        guard cacheGeneration == generation else { return }
        cacheProgress?.isRunning = false
        cacheProgress?.wasCancelled = Task.isCancelled
        if exportAfterDownload, !Task.isCancelled, failed == 0, completed == targets.count { exportAfterDownload = false; exportBook() }
    }

    private func exportBook() {
        guard !isExporting else { return }
        let exportBookID = book.id
        isExporting = true
        Task {
            defer { isExporting = false }
            do {
                var contents: [ExportBookChapter] = []
                var missing = 0
                var bytes = 0
                for chapter in chapters {
                    let key = "\(source.id)::\(chapter.url)"
                    var query = FetchDescriptor<ChapterCacheRecord>(predicate: #Predicate { $0.cacheKey == key })
                    query.fetchLimit = 1
                    guard let cache = try modelContext.fetch(query).first, !cache.content.isEmpty else {
                        missing += 1; continue
                    }
                    bytes += cache.content.utf8.count
                    guard bytes <= BookEPUBExporter.maximumTextBytes else { throw BookExportError.tooLarge }
                    contents.append(ExportBookChapter(title: chapter.title, content: cache.content, html: cache.htmlContent))
                }
                guard missing == 0 else { throw BookExportError.missing(missing) }
                let exportedBook = book
                let exportedChapters = contents
                let data = try await BookEPUBExporter.prepare(book: exportedBook, chapters: exportedChapters, source: source)
                guard book.id == exportBookID else { return }
                exportDocument = EPUBExportDocument(data: data)
                showingExport = true
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private var failureList: some View {
        NavigationStack {
            List {
                Section {
                    Text("已下载章节会保留。网络中断可以重试；已删除或没有访问权限的文章需要在原站确认，不能当作下载成功。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("重试全部失败章节") { showingFailures = false; startCaching(maximumCount: nil, retryOnly: true) }
                }
                ForEach(downloadFailures.values.sorted { $0.chapter.index < $1.chapter.index }) { failure in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(failure.chapter.title).font(.headline)
                        Text(failure.reason).font(.subheadline).foregroundStyle(.secondary)
                    }.padding(.vertical, 6)
                }
            }.navigationTitle("下载失败章节").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showingFailures = false } } }
        }
    }
    private func restoreDownloadFailures() {
        let id = book.id
        let query = FetchDescriptor<ChapterCacheRecord>(predicate: #Predicate { $0.bookID == id })
        let records = (try? modelContext.fetch(query)) ?? []
        for record in records {
            guard let reason = record.downloadError, let chapter = chapters.first(where: { $0.url == record.chapterURL }) else { continue }
            downloadFailures[chapter.url] = ChapterDownloadFailure(chapter: chapter, reason: reason)
        }
    }
    private func saveDownloadFailure(_ chapter: BookChapter, reason: String, sourceID: String, bookID: String) {
        let key = "\(sourceID)::\(chapter.url)"
        let query = FetchDescriptor<ChapterCacheRecord>(predicate: #Predicate { $0.cacheKey == key })
        do {
            let record = try modelContext.fetch(query).first ?? ChapterCacheRecord(sourceID: sourceID, bookID: bookID, chapter: chapter, content: "")
            record.downloadError = reason
            if record.modelContext == nil { modelContext.insert(record) }
            try modelContext.save()
        } catch { errorMessage = "下载状态保存失败：" + error.localizedDescription }
    }
}

private struct BookSourceChoice: Identifiable {
    var book: SearchBook
    var source: BookSourceDefinition

    var id: String { book.id }
}

struct BatchCacheProgress {
    let total: Int
    var completed = 0
    var failed = 0
    var currentTitle = ""
    var isRunning = true
    var wasCancelled = false
    var succeeded: Int { max(0, completed - failed) }
    var remaining: Int { max(0, total - completed) }

    var statusText: String {
        if isRunning {
            return "已下载 \(succeeded)/\(total)，失败 \(failed) 章，待处理 \(remaining) 章"
        }
        if wasCancelled {
            return "已取消：已下载 \(succeeded)/\(total)，失败 \(failed) 章，待处理 \(remaining) 章"
        }
        return failed == 0 && remaining == 0 ? "已完整下载 \(total) 章" : "下载未完成：成功 \(succeeded)/\(total)，失败 \(failed) 章，待处理 \(remaining) 章"
    }
}

private struct ChapterDownloadOutcome: Sendable {
    let chapter: BookChapter
    var content: SourceChapterDocument? = nil
    var error: String? = nil
    var authentication = false
}

private struct ChapterDownloadFailure: Identifiable {
    let chapter: BookChapter
    let reason: String
    var id: String { chapter.url }
}
