import SwiftData
import SwiftUI

struct ReaderView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("reader.fontSize") private var fontSize = 19.0
    @AppStorage("reader.lineSpacing") private var lineSpacing = 8.0
    @AppStorage("reader.paper") private var paperValue = ReaderPaper.warm.rawValue
    @AppStorage("reader.serif") private var usesSerif = true
    @AppStorage("reader.mode") private var modeValue = ReaderMode.scroll.rawValue

    let book: SearchBook
    let chapters: [BookChapter]
    let source: BookSourceDefinition

    @State private var currentIndex: Int
    @State private var content = ""
    @State private var blocks: [ReaderBlock] = []
    @State private var pages: [ReaderPage] = []
    @State private var pageIndex = 0
    @State private var scrollBlockID: Int?
    @State private var pendingLocatorOffset: Int?
    @State private var pendingChapterFraction: Double?
    @State private var layoutSize = CGSize.zero
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var authenticationRequired = false
    @State private var showingSourceLogin = false
    @State private var controlsVisible = true
    @State private var showingSettings = false
    @State private var showingBookmarks = false
    @State private var currentBookmarkID: String?
    @State private var scrubProgress = 0.0
    @State private var isScrubbing = false

    @State private var sessionID: String?
    @State private var sessionStartedAt = Date.now
    @State private var sessionActiveSeconds = 0.0
    @State private var lastSessionTick = Date.now
    @State private var lastActivityAt = Date.now
    @State private var sessionPaused = false

    init(
        book: SearchBook,
        chapters: [BookChapter],
        initialIndex: Int,
        source: BookSourceDefinition
    ) {
        self.book = book
        self.chapters = chapters
        self.source = source
        _currentIndex = State(initialValue: min(max(initialIndex, 0), max(0, chapters.count - 1)))
    }

    private var chapter: BookChapter { chapters[currentIndex] }
    private var paper: ReaderPaper { ReaderPaper(rawValue: paperValue) ?? .warm }
    private var readerMode: ReaderMode { ReaderMode(rawValue: modeValue) ?? .scroll }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                paper.background.ignoresSafeArea()
                readerContent
            }
            .onAppear {
                layoutSize = proxy.size
                rebuildPages(keeping: currentLocatorOffset)
            }
            .onChange(of: proxy.size) { _, newSize in
                let locator = currentLocatorOffset
                layoutSize = newSize
                rebuildPages(keeping: locator)
            }
            .simultaneousGesture(
                SpatialTapGesture().onEnded { value in
                    handleTap(at: value.location, width: proxy.size.width)
                }
            )
        }
        .navigationTitle(book.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(controlsVisible ? .visible : .hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .toolbarBackground(paper.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar { readerToolbar }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if controlsVisible { readerControls }
        }
        .sheet(isPresented: $showingSettings) { ReaderSettingsView() }
        .sheet(isPresented: $showingSourceLogin) {
            SourceLoginView(source: source) {
                authenticationRequired = false
                Task { await loadChapter(forceRefresh: true) }
            }
        }
        .sheet(isPresented: $showingBookmarks) {
            BookmarkListView(bookID: book.id) { bookmark in
                showingBookmarks = false
                goToChapter(bookmark.chapterIndex, locatorOffset: bookmark.locatorOffset)
            }
        }
        .task(id: currentIndex) { await loadChapter() }
        .task { await runSessionTimer() }
        .onDisappear {
            tickSession()
            persistSession()
            saveProgress()
        }
        .onChange(of: scenePhase) { _, phase in
            handleScenePhase(phase)
        }
        .onChange(of: modeValue) { oldValue, _ in
            let oldMode = ReaderMode(rawValue: oldValue) ?? .scroll
            let locator = locatorOffset(for: oldMode)
            rebuildPages(keeping: locator)
            applyLocator(locator)
            saveProgress()
        }
        .onChange(of: fontSize) { _, _ in repaginateForSettingsChange() }
        .onChange(of: lineSpacing) { _, _ in repaginateForSettingsChange() }
        .onChange(of: usesSerif) { _, _ in repaginateForSettingsChange() }
    }

    @ViewBuilder
    private var readerContent: some View {
        if isLoading {
            VStack(spacing: 12) {
                ProgressView().tint(AppTheme.vermilion)
                Text("正在展开书页…").foregroundStyle(paper.secondaryText)
            }
        } else if let errorMessage {
            VStack(spacing: 16) {
                InlineErrorView(message: errorMessage)
                if authenticationRequired, source.loginUrl?.nilIfBlank != nil {
                    Button("登录书源后继续") { showingSourceLogin = true }
                        .buttonStyle(.borderedProminent)
                        .tint(AppTheme.vermilion)
                }
                Button("重新加载") { Task { await loadChapter(forceRefresh: true) } }
                    .buttonStyle(.borderedProminent)
                    .tint(AppTheme.vermilion)
                if currentIndex < chapters.count - 1 {
                    Button("跳过本章，阅读下一章") {
                        goToChapter(currentIndex + 1, locatorOffset: 0)
                    }
                    .buttonStyle(.bordered)
                    .tint(AppTheme.vermilion)
                }
            }
            .padding(24)
        } else if readerMode == .scroll {
            scrollingReader
        } else {
            pagedReader
        }
    }

    private var scrollingReader: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                Text(chapter.title)
                    .font(.system(size: fontSize + 5, weight: .bold, design: .serif))
                    .padding(.bottom, 4)
                Rectangle()
                    .fill(AppTheme.vermilion)
                    .frame(width: 34, height: 2)
                    .padding(.bottom, 4)
                ForEach(blocks) { block in
                    Text(block.text)
                        .font(readerFont)
                        .lineSpacing(lineSpacing)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id(block.id)
                }
            }
            .foregroundStyle(paper.primaryText)
            .textSelection(.enabled)
            .scrollTargetLayout()
            .frame(maxWidth: 720, alignment: .leading)
            .padding(.horizontal, 22)
            .padding(.top, 26)
            .padding(.bottom, controlsVisible ? 34 : 90)
        }
        .scrollPosition(id: $scrollBlockID, anchor: .top)
        .onChange(of: scrollBlockID) { _, _ in
            recordActivity()
            locationDidChange()
        }
    }

    @ViewBuilder
    private var pagedReader: some View {
        if pages.isEmpty {
            ProgressView().tint(AppTheme.vermilion)
        } else if readerMode == .pageSlide {
            TabView(selection: $pageIndex) {
                ForEach(pages) { page in
                    pageView(page).tag(page.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .onChange(of: pageIndex) { _, _ in
                recordActivity()
                locationDidChange()
            }
        } else {
            pageView(pages[safe: pageIndex] ?? pages[0])
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 34)
                        .onEnded { value in
                            if value.translation.width < -44 {
                                turnPage(1)
                            } else if value.translation.width > 44 {
                                turnPage(-1)
                            }
                        }
                )
        }
    }

    private func pageView(_ page: ReaderPage) -> some View {
        Text(page.text)
            .font(readerFont)
            .lineSpacing(lineSpacing)
            .foregroundStyle(paper.primaryText)
            .textSelection(.enabled)
            .frame(maxWidth: 720, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 22)
            .padding(.top, 26)
            .padding(.bottom, 22)
            .clipped()
    }

    private var readerFont: Font {
        .system(
            size: fontSize,
            weight: .regular,
            design: usesSerif ? .serif : .default
        )
    }

    @ToolbarContentBuilder
    private var readerToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Menu {
                ForEach(chapters) { item in
                    Button(item.title) { goToChapter(item.index, locatorOffset: 0) }
                }
            } label: {
                Image(systemName: "list.bullet")
            }
            Button {
                toggleBookmark()
            } label: {
                Image(systemName: currentBookmarkID == nil ? "bookmark" : "bookmark.fill")
            }
            Button {
                showingSettings = true
            } label: {
                Image(systemName: "textformat.size")
            }
        }
    }

    private var readerControls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Text("\(currentIndex + 1)/\(chapters.count)")
                    .font(.caption.monospacedDigit())
                    .frame(width: 48, alignment: .leading)
                Slider(
                    value: $scrubProgress,
                    in: 0...1,
                    onEditingChanged: { editing in
                        isScrubbing = editing
                        if !editing { jumpToFullProgress(scrubProgress) }
                    }
                )
                .tint(AppTheme.vermilion)
                Text(progressLabel)
                    .font(.caption.monospacedDigit())
                    .frame(width: 52, alignment: .trailing)
            }
            HStack {
                Button { goToChapter(currentIndex - 1, locatorOffset: .max) } label: {
                    Label("上一章", systemImage: "chevron.left")
                }
                .disabled(currentIndex == 0)
                Spacer()
                Button { showingBookmarks = true } label: {
                    Label("书签", systemImage: "bookmark")
                }
                Spacer()
                Menu {
                    Picker("翻页方式", selection: $modeValue) {
                        ForEach(ReaderMode.allCases) { mode in
                            Label(mode.title, systemImage: mode.systemImage).tag(mode.rawValue)
                        }
                    }
                } label: {
                    Label(readerMode.title, systemImage: readerMode.systemImage)
                }
                Spacer()
                Button { goToChapter(currentIndex + 1, locatorOffset: 0) } label: {
                    Label("下一章", systemImage: "chevron.right")
                }
                .disabled(currentIndex >= chapters.count - 1)
            }
            .font(.subheadline.bold())
        }
        .foregroundStyle(paper.primaryText)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Divider() }
    }

    private var progressLabel: String {
        if readerMode.usesPages, !pages.isEmpty {
            return "\(pageIndex + 1)/\(pages.count)"
        }
        return "\(Int(chapterProgress * 100))%"
    }

    private var currentLocatorOffset: Int { locatorOffset(for: readerMode) }

    private func locatorOffset(for mode: ReaderMode) -> Int {
        if mode.usesPages {
            return pages[safe: pageIndex]?.locatorOffset ?? pendingLocatorOffset ?? 0
        }
        guard let scrollBlockID,
              let block = blocks.first(where: { $0.id == scrollBlockID }) else {
            return pendingLocatorOffset ?? 0
        }
        return block.locatorOffset
    }

    private var chapterProgress: Double {
        if readerMode.usesPages, pages.count > 1 {
            return Double(pageIndex) / Double(pages.count - 1)
        }
        let length = max(1, (content as NSString).length)
        return min(max(Double(currentLocatorOffset) / Double(length), 0), 1)
    }

    private var fullBookProgress: Double {
        guard !chapters.isEmpty else { return 0 }
        return min(
            max((Double(currentIndex) + chapterProgress) / Double(chapters.count), 0),
            1
        )
    }

    private func handleTap(at location: CGPoint, width: CGFloat) {
        recordActivity()
        let fraction = location.x / max(width, 1)
        if fraction < 0.28 {
            if readerMode == .scroll { moveScroll(by: -3) } else { turnPage(-1) }
        } else if fraction > 0.72 {
            if readerMode == .scroll { moveScroll(by: 3) } else { turnPage(1) }
        } else {
            withAnimation(.easeInOut(duration: 0.18)) { controlsVisible.toggle() }
        }
    }

    private func turnPage(_ direction: Int) {
        recordActivity()
        let target = pageIndex + direction
        if pages.indices.contains(target) {
            if readerMode == .pageSlide {
                withAnimation(.easeOut(duration: 0.22)) { pageIndex = target }
            } else {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { pageIndex = target }
                locationDidChange()
            }
        } else if direction > 0, currentIndex < chapters.count - 1 {
            goToChapter(currentIndex + 1, locatorOffset: 0)
        } else if direction < 0, currentIndex > 0 {
            goToChapter(currentIndex - 1, locatorOffset: .max)
        }
    }

    private func moveScroll(by amount: Int) {
        guard !blocks.isEmpty else { return }
        let current = blocks.firstIndex(where: { $0.id == scrollBlockID }) ?? 0
        let target = min(max(current + amount, 0), blocks.count - 1)
        withAnimation(.easeOut(duration: 0.22)) { scrollBlockID = blocks[target].id }
    }

    private func goToChapter(_ index: Int, locatorOffset: Int) {
        guard chapters.indices.contains(index) else { return }
        recordActivity()
        pendingChapterFraction = nil
        pendingLocatorOffset = locatorOffset
        if index == currentIndex {
            applyLocator(locatorOffset)
        } else {
            currentIndex = index
        }
    }

    private func jumpToFullProgress(_ progress: Double) {
        guard !chapters.isEmpty else { return }
        let scaled = min(max(progress, 0), 0.999_999) * Double(chapters.count)
        let targetChapter = min(Int(scaled), chapters.count - 1)
        let fraction = scaled - Double(targetChapter)
        pendingChapterFraction = fraction
        pendingLocatorOffset = nil

        if targetChapter == currentIndex {
            let locator = Int(fraction * Double((content as NSString).length))
            pendingChapterFraction = nil
            applyLocator(locator)
        } else {
            currentIndex = targetChapter
        }
    }

    private func locationDidChange() {
        if !isScrubbing { scrubProgress = fullBookProgress }
        refreshBookmarkState()
        saveProgress()
    }

    private func repaginateForSettingsChange() {
        let locator = currentLocatorOffset
        rebuildPages(keeping: locator)
        applyLocator(locator)
    }

    private func rebuildPages(keeping locatorOffset: Int) {
        guard !content.isEmpty else { return }
        let pageSize = CGSize(
            width: max(120, layoutSize.width - 44),
            height: max(180, layoutSize.height - 62)
        )
        pages = ReaderPaginator.paginate(
            chapterTitle: chapter.title,
            content: content,
            size: pageSize,
            fontSize: fontSize,
            lineSpacing: lineSpacing,
            usesSerif: usesSerif
        )
        pageIndex = ReaderPaginator.pageIndex(for: locatorOffset, in: pages)
    }

    private func applyLocator(_ rawLocator: Int) {
        let length = (content as NSString).length
        let locator = rawLocator == .max ? length : min(max(rawLocator, 0), length)
        pendingLocatorOffset = locator

        if readerMode.usesPages {
            pageIndex = ReaderPaginator.pageIndex(for: locator, in: pages)
        } else if let block = blocks.last(where: { $0.locatorOffset <= locator }) ?? blocks.first {
            DispatchQueue.main.async { scrollBlockID = block.id }
        }
        DispatchQueue.main.async {
            pendingLocatorOffset = nil
            locationDidChange()
        }
    }

    private func loadChapter(forceRefresh: Bool = false) async {
        let requestedIndex = currentIndex
        let currentChapter = chapters[requestedIndex]
        isLoading = true
        errorMessage = nil
        authenticationRequired = false
        content = ""
        blocks = []
        pages = []
        pageIndex = 0
        scrollBlockID = nil

        if !forceRefresh, let cached = cachedChapter(url: currentChapter.url) {
            if SourceEngine.authenticationMessage(in: cached.content) == nil {
                guard !Task.isCancelled, currentIndex == requestedIndex else { return }
                prepareDocument(cached.content, chapter: currentChapter)
                isLoading = false
                return
            }
            modelContext.delete(cached)
            try? modelContext.save()
        }

        do {
            let value = try await SourceEngine().loadContent(chapter: currentChapter, source: source)
            guard !Task.isCancelled, currentIndex == requestedIndex else { return }
            cache(currentChapter, content: value)
            prepareDocument(value, chapter: currentChapter)
        } catch is CancellationError {
            return
        } catch let error as URLError where error.code == .cancelled {
            return
        } catch {
            guard currentIndex == requestedIndex else { return }
            errorMessage = error.localizedDescription
            authenticationRequired = (error as? SourceEngineError)?.requiresAuthentication == true
        }
        guard currentIndex == requestedIndex else { return }
        isLoading = false
    }

    private func prepareDocument(_ value: String, chapter: BookChapter) {
        content = value
        blocks = ReaderDocumentBuilder.blocks(from: value)

        let targetLocator: Int
        if let fraction = pendingChapterFraction {
            targetLocator = Int(fraction * Double((value as NSString).length))
        } else if let pendingLocatorOffset {
            targetLocator = pendingLocatorOffset
        } else {
            targetLocator = storedLocator(for: chapter)
        }
        pendingChapterFraction = nil
        pendingLocatorOffset = nil
        rebuildPages(keeping: targetLocator)
        applyLocator(targetLocator)
        saveProgress(locatorOffset: targetLocator)
    }

    private func storedLocator(for chapter: BookChapter) -> Int {
        let bookID = book.id
        let descriptor = FetchDescriptor<ReadingProgressRecord>(
            predicate: #Predicate { $0.bookID == bookID }
        )
        guard let progress = try? modelContext.fetch(descriptor).first,
              progress.chapterIndex == chapter.index || progress.chapterURL == chapter.url else {
            return 0
        }
        return progress.locatorOffset
    }

    private func cachedChapter(url: String) -> ChapterCacheRecord? {
        let key = "\(source.id)::\(url)"
        let descriptor = FetchDescriptor<ChapterCacheRecord>(
            predicate: #Predicate { $0.cacheKey == key }
        )
        return try? modelContext.fetch(descriptor).first
    }

    private func cache(_ chapter: BookChapter, content: String) {
        if let existing = cachedChapter(url: chapter.url) {
            existing.content = content
            existing.cachedAt = .now
        } else {
            modelContext.insert(
                ChapterCacheRecord(
                    sourceID: source.id,
                    bookID: book.id,
                    chapter: chapter,
                    content: content
                )
            )
        }
        try? modelContext.save()
    }

    private func saveProgress(locatorOffset: Int? = nil) {
        guard !content.isEmpty else { return }
        let offset = locatorOffset ?? currentLocatorOffset
        let progressValue = chapterProgress
        let bookID = book.id
        let descriptor = FetchDescriptor<ReadingProgressRecord>(
            predicate: #Predicate { $0.bookID == bookID }
        )
        if let progress = try? modelContext.fetch(descriptor).first {
            progress.update(
                chapter: chapter,
                locatorOffset: offset,
                chapterProgress: progressValue,
                pageIndex: pageIndex,
                readingMode: readerMode.rawValue
            )
        } else {
            let progress = ReadingProgressRecord(bookID: bookID, chapter: chapter)
            progress.update(
                chapter: chapter,
                locatorOffset: offset,
                chapterProgress: progressValue,
                pageIndex: pageIndex,
                readingMode: readerMode.rawValue
            )
            modelContext.insert(progress)
        }

        let bookDescriptor = FetchDescriptor<BookRecord>(
            predicate: #Predicate { $0.bookID == bookID }
        )
        if let storedBook = try? modelContext.fetch(bookDescriptor).first {
            storedBook.lastReadAt = .now
        }
        try? modelContext.save()
        if !isScrubbing { scrubProgress = fullBookProgress }
    }

    private func toggleBookmark() {
        recordActivity()
        if let currentBookmarkID {
            let identifier = currentBookmarkID
            let descriptor = FetchDescriptor<BookmarkRecord>(
                predicate: #Predicate { $0.bookmarkID == identifier }
            )
            if let bookmark = try? modelContext.fetch(descriptor).first {
                modelContext.delete(bookmark)
            }
        } else {
            let locator = currentLocatorOffset
            modelContext.insert(
                BookmarkRecord(
                    book: book,
                    chapter: chapter,
                    locatorOffset: locator,
                    chapterProgress: chapterProgress,
                    excerpt: ReaderDocumentBuilder.excerpt(from: content, locatorOffset: locator)
                )
            )
        }
        try? modelContext.save()
        refreshBookmarkState()
    }

    private func refreshBookmarkState() {
        let bookID = book.id
        let chapterIndex = chapter.index
        let locator = currentLocatorOffset
        let descriptor = FetchDescriptor<BookmarkRecord>(
            predicate: #Predicate {
                $0.bookID == bookID && $0.chapterIndex == chapterIndex
            }
        )
        let nearby = try? modelContext.fetch(descriptor).first(where: {
            abs($0.locatorOffset - locator) <= 24
        })
        currentBookmarkID = nearby?.bookmarkID
    }

    private func startSessionIfNeeded() {
        guard sessionID == nil else { return }
        let now = Date.now
        let identifier = UUID().uuidString
        sessionID = identifier
        sessionStartedAt = now
        sessionActiveSeconds = 0
        lastSessionTick = now
        lastActivityAt = now
        sessionPaused = scenePhase != .active
        modelContext.insert(
            ReadingSessionRecord(
                sessionID: identifier,
                bookID: book.id,
                bookName: book.name,
                sourceID: source.id,
                startedAt: now,
                endedAt: now
            )
        )
        try? modelContext.save()
    }

    private func recordActivity() {
        lastActivityAt = .now
    }

    private func tickSession() {
        startSessionIfNeeded()
        let now = Date.now
        defer { lastSessionTick = now }
        guard !sessionPaused else { return }

        let elapsed = max(0, now.timeIntervalSince(lastSessionTick))
        let idleDuration = now.timeIntervalSince(lastActivityAt)
        if idleDuration <= 300 {
            sessionActiveSeconds += min(elapsed, 30)
        }
    }

    private func persistSession() {
        guard let sessionID else { return }
        let identifier = sessionID
        let descriptor = FetchDescriptor<ReadingSessionRecord>(
            predicate: #Predicate { $0.sessionID == identifier }
        )
        if let session = try? modelContext.fetch(descriptor).first {
            session.update(endedAt: .now, activeSeconds: sessionActiveSeconds)
            try? modelContext.save()
        }
    }

    private func runSessionTimer() async {
        startSessionIfNeeded()
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled else { break }
            tickSession()
            persistSession()
        }
    }

    private func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            lastSessionTick = .now
            lastActivityAt = .now
            sessionPaused = false
        case .inactive, .background:
            tickSession()
            persistSession()
            saveProgress()
            sessionPaused = true
        @unknown default:
            break
        }
    }
}

private struct ReaderSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("reader.fontSize") private var fontSize = 19.0
    @AppStorage("reader.lineSpacing") private var lineSpacing = 8.0
    @AppStorage("reader.paper") private var paperValue = ReaderPaper.warm.rawValue
    @AppStorage("reader.serif") private var usesSerif = true
    @AppStorage("reader.mode") private var modeValue = ReaderMode.scroll.rawValue

    var body: some View {
        NavigationStack {
            Form {
                Section("翻页") {
                    Picker("翻页方式", selection: $modeValue) {
                        ForEach(ReaderMode.allCases) { mode in
                            Label(mode.title, systemImage: mode.systemImage).tag(mode.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                Section("文字") {
                    LabeledContent("字号", value: "\(Int(fontSize))")
                    Slider(value: $fontSize, in: 15...30, step: 1)
                        .tint(AppTheme.vermilion)
                    LabeledContent("行距", value: "\(Int(lineSpacing))")
                    Slider(value: $lineSpacing, in: 3...16, step: 1)
                        .tint(AppTheme.vermilion)
                    Toggle("使用衬线字体", isOn: $usesSerif)
                        .tint(AppTheme.vermilion)
                }
                Section("纸张") {
                    Picker("阅读主题", selection: $paperValue) {
                        ForEach(ReaderPaper.allCases) { paper in
                            Text(paper.title).tag(paper.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                Section {
                    Text("轻点屏幕左侧或右侧翻页，轻点中央显示或隐藏阅读菜单。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("阅读设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

private enum ReaderPaper: String, CaseIterable, Identifiable {
    case warm
    case white
    case green
    case night

    var id: String { rawValue }
    var title: String {
        switch self {
        case .warm: "暖纸"
        case .white: "净白"
        case .green: "青笺"
        case .night: "夜读"
        }
    }
    var background: Color {
        switch self {
        case .warm: AppTheme.paper
        case .white: Color(red: 0.98, green: 0.98, blue: 0.97)
        case .green: Color(red: 0.87, green: 0.92, blue: 0.86)
        case .night: Color(red: 0.08, green: 0.10, blue: 0.11)
        }
    }
    var primaryText: Color { self == .night ? Color(red: 0.78, green: 0.78, blue: 0.73) : AppTheme.ink }
    var secondaryText: Color { self == .night ? Color(red: 0.58, green: 0.60, blue: 0.58) : AppTheme.inkSoft }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
