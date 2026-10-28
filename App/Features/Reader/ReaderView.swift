import SwiftData
import SwiftUI

struct ReaderView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("reader.fontSize") private var fontSize = 19.0
    @AppStorage("reader.lineSpacing") private var lineSpacing = 9.0
    @AppStorage("reader.paper") private var paperValue = ReaderPaper.white.rawValue
    @AppStorage("reader.serif") private var usesSerif = true
    @AppStorage("reader.mode") private var modeValue = ReaderMode.pageCurl.rawValue
    @AppStorage("reader.margin") private var marginValue = ReaderMargin.comfortable.rawValue
    @AppStorage("reader.paragraphIndent") private var paragraphIndent = true
    @ObservedObject private var audiobookPlayer = AudiobookPlayer.shared

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
    @State private var controlsVisible = false
    @State private var showingSettings = false
    @State private var showingBookmarks = false
    @State private var showingAudiobook = false
    @State private var audiobookSegments: [AudiobookTimedSegment] = []
    @State private var sentencePlaybackMode = false
    @State private var playbackError: String?
    @State private var currentBookmarkID: String?
    @State private var scrubProgress = 0.0
    @State private var isScrubbing = false
    @State private var prefetchTask: Task<Void, Never>?

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
    private var readerMode: ReaderMode {
        let selected = ReaderMode(rawValue: modeValue) ?? .pageCurl
        return reduceMotion && selected == .pageCurl ? .pageNone : selected
    }
    private var readerMargin: ReaderMargin {
        ReaderMargin(rawValue: marginValue) ?? .comfortable
    }
    private var readerContentWidth: CGFloat {
        ReaderLayoutMetrics.contentWidth(
            containerWidth: layoutSize.width,
            margin: readerMargin
        )
    }
    private var activeAudiobookSegment: AudiobookTimedSegment? {
        guard audiobookPlayer.currentBookID == book.id,
              audiobookPlayer.currentChapterIndex == currentIndex else { return nil }
        return audiobookPlayer.currentSegment
    }
    private var activeAudiobookBlockID: Int? {
        guard let locator = audiobookPlayer.currentLocatorOffset else { return nil }
        return blocks.last(where: { $0.locatorOffset <= locator })?.id
    }

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
        .navigationBarBackButtonHidden()
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityAction(named: "显示阅读菜单") { controlsVisible = true }
        .accessibilityAction(.escape) { dismiss() }
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .toolbarBackground(paper.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(paper == .night ? .dark : .light, for: .navigationBar)
        .environment(\.colorScheme, paper == .night ? .dark : .light)
        .overlay(alignment: .top) { if controlsVisible { floatingHeader } }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if sentencePlaybackMode, !audiobookSegments.isEmpty {
                sentencePlaybackControls
            } else {
                VStack(spacing: 8) {
                    if controlsVisible { floatingActions; readerControls }
                    HStack {
                        Spacer(minLength: 56)
                        Text(readerMode.usesPages ? "\(progressLabel) 页" : progressLabel)
                            .font(.subheadline.weight(.semibold)).monospacedDigit()
                            .padding(.horizontal, 14).frame(minHeight: 36).background(.regularMaterial, in: Capsule())
                            .accessibilityLabel(readerMode.usesPages ? "本章第 \(progressLabel) 页" : "本章进度 \(progressLabel)")
                        Spacer(minLength: 12)
                        Button { controlsVisible.toggle() } label: {
                            Image(systemName: "line.3.horizontal.decrease").font(.title2.bold()).frame(width: 48, height: 48)
                        }.background(.regularMaterial, in: Circle()).accessibilityLabel("阅读菜单")
                    }.foregroundStyle(paper.primaryText).padding(.horizontal, 24).padding(.bottom, 8)
                }
            }
        }
        .sheet(isPresented: $showingSettings) {
            ReaderSettingsView().presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showingSourceLogin) {
            SourceLoginView(source: source) {
                authenticationRequired = false
                Task { await loadChapter(forceRefresh: true) }
            }
        }
        .sheet(isPresented: $showingBookmarks) {
            BookmarkListView(bookID: book.id) { bookmark in
                showingBookmarks = false
                let targetIndex = chapters.firstIndex(where: { $0.url == bookmark.chapterURL })
                    ?? bookmark.chapterIndex
                goToChapter(targetIndex, locatorOffset: bookmark.locatorOffset)
            }
        }
        .sheet(isPresented: $showingAudiobook, onDismiss: {
            refreshChapterAudiobook()
        }) {
            AudiobookView(
                book: book,
                chapters: chapters,
                source: source,
                currentIndex: currentIndex
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .task(id: currentIndex) { await loadChapter() }
        .task { await runSessionTimer() }
        .onDisappear {
            prefetchTask?.cancel()
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
        .onChange(of: marginValue) { _, _ in repaginateForSettingsChange() }
        .onChange(of: paragraphIndent) { _, _ in repaginateForSettingsChange() }
        .onChange(of: audiobookPlayer.currentChapterIndex) { _, targetIndex in
            guard audiobookPlayer.currentBookID == book.id,
                  let targetIndex,
                  chapters.indices.contains(targetIndex) else { return }
            sentencePlaybackMode = true
            if targetIndex != currentIndex {
                goToChapter(targetIndex, locatorOffset: 0)
            } else {
                refreshChapterAudiobook()
            }
        }
        .onChange(of: audiobookPlayer.currentLocatorOffset) { _, _ in
            followAudiobookText()
        }
    }

    private var floatingHeader: some View {
        HStack {
            Spacer(minLength: 56)
            Text(book.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                .padding(.horizontal, 16).padding(.vertical, 9).background(.regularMaterial, in: Capsule())
            Spacer(minLength: 12)
            Button { dismiss() } label: { Image(systemName: "xmark").font(.title2.weight(.semibold)).frame(width: 48, height: 48) }
                .background(.regularMaterial, in: Circle()).accessibilityLabel("关闭图书").accessibilityIdentifier("reader.close")
        }.foregroundStyle(paper.primaryText).padding(.horizontal, 24).padding(.top, 4)
    }

    private var floatingActions: some View {
        HStack(spacing: 24) {
            Menu {
                ForEach(chapters) { item in Button(item.title) { goToChapter(item.index, locatorOffset: 0) } }
            } label: { Image(systemName: "list.bullet").frame(width: 44, height: 44) }
                .accessibilityLabel("目录").accessibilityIdentifier("reader.toc")
            Button { toggleBookmark() } label: { Image(systemName: currentBookmarkID == nil ? "bookmark" : "bookmark.fill").frame(width: 44, height: 44) }
                .accessibilityLabel(currentBookmarkID == nil ? "添加书签" : "移除书签")
            Button { showingAudiobook = true } label: { Image(systemName: "headphones").frame(width: 44, height: 44) }
                .accessibilityLabel("听书")
            Button { showingSettings = true } label: { Image(systemName: "textformat.size").frame(width: 44, height: 44) }
                .accessibilityLabel("主题与设置").accessibilityIdentifier("reader.settings")
        }.font(.title3).foregroundStyle(paper.primaryText).padding(.horizontal, 12).background(.regularMaterial, in: Capsule())
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
        } else if sentencePlaybackMode, !audiobookSegments.isEmpty {
            sentencePlaybackReader
        } else if readerMode == .scroll {
            scrollingReader
        } else {
            pagedReader
        }
    }

    private var scrollingReader: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                chapterHeading
                    .padding(.bottom, 30)
                ForEach(blocks) { block in
                    Text(displayText(for: block))
                        .font(readerFont)
                        .lineSpacing(lineSpacing)
                        .tracking(ReaderTypography.letterSpacing)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .foregroundStyle(
                            block.id == activeAudiobookBlockID
                                ? AppTheme.vermilion
                                : paper.primaryText
                        )
                        .background(
                            block.id == activeAudiobookBlockID
                                ? AppTheme.vermilion.opacity(0.09)
                                : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6)
                        )
                        .padding(
                            .top,
                            block.id > 0 && block.isParagraphStart
                                ? ReaderTypography.paragraphSpacing(for: lineSpacing)
                                : 0
                        )
                        .id(block.id)
                }
                chapterEnding
                    .padding(.top, 42)
            }
            .textSelection(.enabled)
            .scrollTargetLayout()
            .frame(width: readerContentWidth, alignment: .leading)
            .padding(.top, 36)
            .padding(.bottom, controlsVisible ? 36 : 84)
            .frame(maxWidth: .infinity)
        }
        .scrollPosition(id: $scrollBlockID, anchor: .top)
        .onChange(of: scrollBlockID) { _, _ in
            recordActivity()
            locationDidChange()
        }
    }

    private var sentencePlaybackReader: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("逐句点播")
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .tracking(1)
                                .foregroundStyle(AppTheme.vermilion)
                            Text(chapter.title)
                                .font(chapterTitleFont)
                                .foregroundStyle(paper.primaryText)
                        }
                        Spacer(minLength: 16)
                        Button("返回排版") { exitSentencePlaybackMode() }
                            .font(.caption.bold())
                            .foregroundStyle(AppTheme.vermilion)
                    }
                    .padding(.bottom, 24)

                    if let playbackError {
                        InlineErrorView(message: playbackError)
                            .padding(.bottom, 14)
                    }

                    ForEach(audiobookSegments) { segment in
                        let isActive = activeAudiobookSegment?.id == segment.id
                        HStack(alignment: .top, spacing: 12) {
                            Button {
                                playSentence(segment)
                            } label: {
                                Image(systemName: isActive ? "play.circle.fill" : "play.circle")
                                    .font(.system(size: 23, weight: .medium))
                                    .foregroundStyle(
                                        isActive ? AppTheme.vermilion : paper.secondaryText
                                    )
                                    .frame(width: 28, height: 32, alignment: .top)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("从这句话开始播放")

                            VStack(alignment: .leading, spacing: 6) {
                                Text(sentenceDisplayText(segment))
                                    .font(readerFont)
                                    .lineSpacing(lineSpacing)
                                    .tracking(ReaderTypography.letterSpacing)
                                    .foregroundStyle(
                                        isActive ? AppTheme.vermilion : paper.primaryText
                                    )
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text(segment.roleAndVoiceName)
                                    .font(.system(size: 10, weight: .medium, design: .rounded))
                                    .tracking(0.6)
                                    .foregroundStyle(paper.secondaryText.opacity(0.78))
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 11)
                        .background(
                            isActive ? AppTheme.vermilion.opacity(0.09) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 10)
                        )
                        .padding(.top, segment.text.hasPrefix("\n") ? 8 : 0)
                        .id(segment.id)
                    }
                    chapterEnding.padding(.top, 36)
                }
                .textSelection(.enabled)
                .frame(width: readerContentWidth, alignment: .leading)
                .padding(.top, 28)
                .padding(.bottom, 56)
                .frame(maxWidth: .infinity)
            }
            .onAppear {
                guard let id = activeAudiobookSegment?.id else { return }
                DispatchQueue.main.async { proxy.scrollTo(id, anchor: .center) }
            }
            .onChange(of: activeAudiobookSegment?.id) { _, id in
                guard let id else { return }
                withAnimation(.easeInOut(duration: 0.28)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
    }

    @ViewBuilder
    private var pagedReader: some View {
        if pages.isEmpty {
            ProgressView().tint(AppTheme.vermilion)
        } else if readerMode == .pageCurl {
            ReaderPageCurlView(count: pages.count,
                revision: "\(chapter.url)-\(layoutSize)-\(fontSize)-\(lineSpacing)-\(usesSerif)-\(marginValue)-\(paragraphIndent)-\(paperValue)",
                background: UIColor(paper.background), index: $pageIndex) { index in
                    pageView(pages[index]).background(paper.background)
                }
                .onChange(of: pageIndex) { _, _ in recordActivity(); locationDidChange() }
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
        VStack(alignment: .leading, spacing: 0) {
            pageHeader
                .frame(height: ReaderTypography.pageHeaderHeight)
                .padding(.bottom, ReaderTypography.pageHeaderBottomSpacing)

            if page.showsChapterTitle {
                chapterHeading
                    .frame(
                        maxWidth: .infinity,
                        alignment: .topLeading
                    )
                    .frame(height: ReaderTypography.chapterHeadingHeight, alignment: .topLeading)
            }

            ReaderPageTextView(
                text: page.text,
                fontSize: fontSize,
                lineSpacing: lineSpacing,
                usesSerif: usesSerif,
                textColor: UIColor(paper.primaryText),
                highlightedText: activeAudiobookSegment?.text
            )
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipped()

            pageFooter(page)
                .frame(height: ReaderTypography.pageFooterHeight)
                .padding(.top, ReaderTypography.pageFooterTopSpacing)
        }
        .frame(width: readerContentWidth)
        .frame(maxHeight: .infinity)
        .padding(.vertical, ReaderTypography.pageVerticalPadding)
        .frame(maxWidth: .infinity)
    }

    private var readerFont: Font {
        Font(
            ReaderTypography.bodyUIFont(
                size: fontSize,
                usesSerif: usesSerif
            )
        )
    }

    private var chapterTitleFont: Font {
        Font(
            ReaderTypography.titleUIFont(
                size: ReaderTypography.titleSize(for: fontSize)
            )
        )
    }

    private var chapterHeading: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text("第 \(currentIndex + 1) 章 · 共 \(chapters.count) 章")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .tracking(1.2)
                .foregroundStyle(paper.secondaryText)
            Text(chapter.title)
                .font(chapterTitleFont)
                .lineSpacing(4)
                .foregroundStyle(paper.primaryText)
                .lineLimit(2)
        }
        .accessibilityElement(children: .combine)
    }

    private var chapterEnding: some View {
        HStack(spacing: 12) {
            Rectangle().fill(paper.secondaryText.opacity(0.22)).frame(height: 0.5)
            Text("本章完")
                .font(.caption)
                .tracking(1)
                .foregroundStyle(paper.secondaryText)
            Rectangle().fill(paper.secondaryText.opacity(0.22)).frame(height: 0.5)
        }
    }

    private var pageHeader: some View {
        HStack(spacing: 12) {
            Text(book.name)
                .lineLimit(1)
            Spacer(minLength: 12)
            Text("第 \(currentIndex + 1) 章")
        }
        .font(.system(size: 11, weight: .medium, design: .rounded))
        .tracking(0.5)
        .foregroundStyle(paper.secondaryText.opacity(0.82))
    }

    private func pageFooter(_ page: ReaderPage) -> some View {
        HStack {
            Text("全书 \(Int(fullBookProgress * 100))%")
            Spacer()
            Text("\(page.id + 1) / \(pages.count)")
                .monospacedDigit()
        }
        .font(.system(size: 11, weight: .regular, design: .rounded))
        .foregroundStyle(paper.secondaryText.opacity(0.78))
    }

    private func displayText(for block: ReaderBlock) -> String {
        if paragraphIndent && block.isParagraphStart {
            return "　　\(block.text)"
        }
        return block.text
    }

    private func sentenceDisplayText(_ segment: AudiobookTimedSegment) -> String {
        let trimmed = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? segment.text : trimmed
    }

    private func playSentence(_ segment: AudiobookTimedSegment) {
        guard let metadata = AudiobookStorage.chapterMetadata(
            bookID: book.id,
            chapterURL: chapter.url
        ) else {
            playbackError = "本章音频文件已经移除，请重新同步电脑伴读包。"
            return
        }
        playbackError = nil
        sentencePlaybackMode = true
        do {
            let isCurrentChapter = audiobookPlayer.currentBookID == book.id
                && audiobookPlayer.currentChapterIndex == currentIndex
            if !isCurrentChapter {
                try audiobookPlayer.play(
                    book: book,
                    chapters: chapters,
                    startingAt: currentIndex,
                    matchingVoice: metadata.voice,
                    matchingSpeed: metadata.generationSpeed ?? 1,
                    autoplay: false
                )
            }
            audiobookPlayer.seek(toTime: segment.startTime, autoplay: true)
        } catch {
            playbackError = error.localizedDescription
        }
    }

    private func toggleSentencePlayback() {
        if audiobookPlayer.currentBookID == book.id,
           audiobookPlayer.currentChapterIndex == currentIndex {
            audiobookPlayer.togglePlayback()
        } else if let first = audiobookSegments.first {
            playSentence(first)
        }
    }

    private func moveSentence(by amount: Int) {
        let current = audiobookPlayer.currentBookID == book.id
            && audiobookPlayer.currentChapterIndex == currentIndex
            ? audiobookPlayer.currentSegment
            : nil
        guard let target = AudiobookSentenceNavigator.target(
            from: current,
            movingBy: amount,
            in: audiobookSegments
        ) else { return }
        playSentence(target)
    }

    private func exitSentencePlaybackMode() {
        sentencePlaybackMode = false
        if audiobookPlayer.currentBookID == book.id,
           audiobookPlayer.currentChapterIndex == currentIndex,
           let locator = audiobookPlayer.currentLocatorOffset {
            applyLocator(locator)
        }
    }

    private func refreshChapterAudiobook() {
        guard chapters.indices.contains(currentIndex) else {
            audiobookSegments = []
            sentencePlaybackMode = false
            return
        }
        audiobookSegments = AudiobookStorage.timedSegments(
            bookID: book.id,
            chapterURL: chapter.url
        )
        if audiobookSegments.isEmpty {
            sentencePlaybackMode = false
        } else if audiobookPlayer.currentBookID == book.id,
                  audiobookPlayer.currentChapterIndex == currentIndex {
            sentencePlaybackMode = true
        }
    }

    @ToolbarContentBuilder
    private var readerToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button { dismiss() } label: { Image(systemName: "xmark") }
                .accessibilityLabel("关闭图书").accessibilityIdentifier("reader.close")
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Menu {
                ForEach(chapters) { item in
                    Button(item.title) { goToChapter(item.index, locatorOffset: 0) }
                }
            } label: {
                Image(systemName: "list.bullet")
            }
            .accessibilityLabel("目录").accessibilityIdentifier("reader.toc")
            Button {
                toggleBookmark()
            } label: {
                Image(systemName: currentBookmarkID == nil ? "bookmark" : "bookmark.fill")
            }
            .accessibilityLabel(currentBookmarkID == nil ? "添加书签" : "移除书签")
            if !audiobookSegments.isEmpty {
                Button {
                    if sentencePlaybackMode {
                        exitSentencePlaybackMode()
                    } else {
                        sentencePlaybackMode = true
                    }
                } label: {
                    Image(systemName: sentencePlaybackMode
                        ? "list.bullet.circle.fill"
                        : "list.bullet.circle")
                }
                .accessibilityLabel(sentencePlaybackMode ? "退出逐句点播" : "进入逐句点播")
            }
            Button {
                showingAudiobook = true
            } label: {
                Image(systemName: audiobookPlayer.currentBookID == book.id && audiobookPlayer.isPlaying
                    ? "headphones.circle.fill"
                    : "headphones")
            }
            Button {
                showingSettings = true
            } label: {
                Image(systemName: "textformat.size")
            }
            .accessibilityLabel("主题与设置").accessibilityIdentifier("reader.settings")
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

    private var sentencePlaybackControls: some View {
        HStack(spacing: 28) {
            Button { moveSentence(by: -1) } label: {
                Image(systemName: "backward.end.fill")
            }
            Button { toggleSentencePlayback() } label: {
                Image(systemName: audiobookPlayer.isPlaying
                    ? "pause.circle.fill"
                    : "play.circle.fill")
                    .font(.system(size: 38))
            }
            Button { moveSentence(by: 1) } label: {
                Image(systemName: "forward.end.fill")
            }
            Divider().frame(height: 26)
            Button { exitSentencePlaybackMode() } label: {
                Image(systemName: "textformat")
            }
            .accessibilityLabel("返回正常排版")
        }
        .font(.system(size: 19, weight: .semibold))
        .foregroundStyle(AppTheme.vermilion)
        .frame(maxWidth: .infinity)
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
        guard !sentencePlaybackMode else { return }
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
            if readerMode == .pageSlide || readerMode == .pageCurl {
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
            width: max(120, readerContentWidth),
            height: max(180, layoutSize.height - ReaderTypography.pageChromeHeight)
        )
        pages = ReaderPaginator.paginate(
            chapterTitle: chapter.title,
            content: content,
            size: pageSize,
            fontSize: fontSize,
            lineSpacing: lineSpacing,
            usesSerif: usesSerif,
            paragraphIndent: paragraphIndent
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

    private func followAudiobookText() {
        guard audiobookPlayer.currentBookID == book.id,
              audiobookPlayer.currentChapterIndex == currentIndex,
              let locator = audiobookPlayer.currentLocatorOffset,
              !content.isEmpty else { return }
        guard !sentencePlaybackMode else { return }
        if readerMode.usesPages {
            let target = ReaderPaginator.pageIndex(for: locator, in: pages)
            guard pages.indices.contains(target), target != pageIndex else { return }
            withAnimation(.easeInOut(duration: 0.28)) {
                pageIndex = target
            }
        } else if let block = blocks.last(where: { $0.locatorOffset <= locator }),
                  scrollBlockID != block.id {
            withAnimation(.easeInOut(duration: 0.32)) {
                scrollBlockID = block.id
            }
        }
    }

    private func loadChapter(forceRefresh: Bool = false) async {
        prefetchTask?.cancel()
        let requestedIndex = currentIndex
        let currentChapter = chapters[requestedIndex]
        isLoading = true
        errorMessage = nil
        authenticationRequired = false
        content = ""
        blocks = []
        pages = []
        audiobookSegments = []
        playbackError = nil
        pageIndex = 0
        scrollBlockID = nil

        if !forceRefresh, let cached = cachedChapter(url: currentChapter.url) {
            let requiresRefresh = source.id != LocalBookStorage.sourceID && (SourceEngine.authenticationMessage(in: cached.content) != nil
                || ReadableContentFormatter.shouldRefreshLegacyCache(
                    cached.content,
                    sourceID: source.id
                ))
            if !requiresRefresh {
                guard !Task.isCancelled, currentIndex == requestedIndex else { return }
                prepareDocument(cached.content, chapter: currentChapter)
                isLoading = false
                schedulePrefetch(after: requestedIndex)
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
            schedulePrefetch(after: requestedIndex)
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

    private func schedulePrefetch(after index: Int) {
        let targets = Array(chapters.dropFirst(index + 1).prefix(2))
        guard !targets.isEmpty else { return }
        prefetchTask?.cancel()
        prefetchTask = Task {
            for target in targets {
                guard !Task.isCancelled else { return }
                if cachedChapter(url: target.url) != nil { continue }
                do {
                    let value = try await SourceEngine().loadContent(
                        chapter: target,
                        source: source
                    )
                    guard !Task.isCancelled else { return }
                    cache(target, content: ReadingTextPreparation.prepare(value, sourceID: source.id))
                } catch is CancellationError {
                    return
                } catch let error as URLError where error.code == .cancelled {
                    return
                } catch {
                    continue
                }
            }
        }
    }

    private func prepareDocument(_ value: String, chapter: BookChapter) {
        let normalized = ReadingTextPreparation.prepare(value, sourceID: source.id)
        content = normalized
        blocks = ReaderDocumentBuilder.blocks(from: normalized)
        refreshChapterAudiobook()
        if normalized != value {
            cache(chapter, content: normalized)
        }

        let targetLocator: Int
        if audiobookPlayer.currentBookID == book.id,
           audiobookPlayer.currentChapterIndex == currentIndex,
           let spokenLocator = audiobookPlayer.currentLocatorOffset {
            targetLocator = spokenLocator
        } else if let fraction = pendingChapterFraction {
            targetLocator = Int(fraction * Double((normalized as NSString).length))
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
              progress.chapterURL == chapter.url else {
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
            progress.bookProgress = fullBookProgress
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
            progress.bookProgress = fullBookProgress
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
        let chapterURL = chapter.url
        let locator = currentLocatorOffset
        let descriptor = FetchDescriptor<BookmarkRecord>(
            predicate: #Predicate {
                $0.bookID == bookID && $0.chapterURL == chapterURL
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
    @AppStorage("reader.lineSpacing") private var lineSpacing = 9.0
    @AppStorage("reader.paper") private var paperValue = ReaderPaper.white.rawValue
    @AppStorage("reader.serif") private var usesSerif = true
    @AppStorage("reader.mode") private var modeValue = ReaderMode.pageCurl.rawValue
    @AppStorage("reader.margin") private var marginValue = ReaderMargin.comfortable.rawValue
    @AppStorage("reader.paragraphIndent") private var paragraphIndent = true

    private var previewFont: Font {
        Font(
            ReaderTypography.bodyUIFont(
                size: fontSize,
                usesSerif: usesSerif
            )
        )
    }

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
                    Text("　　山窗听雨，灯下翻书。字有疏密，行有呼吸。")
                        .font(previewFont)
                        .lineSpacing(lineSpacing)
                        .tracking(ReaderTypography.letterSpacing)
                        .padding(.vertical, 8)
                    LabeledContent("字号", value: "\(Int(fontSize))")
                    Slider(value: $fontSize, in: 15...30, step: 1)
                        .tint(AppTheme.vermilion)
                    LabeledContent("行距", value: "\(Int(lineSpacing))")
                    Slider(value: $lineSpacing, in: 3...16, step: 1)
                        .tint(AppTheme.vermilion)
                    Toggle("使用宋体正文", isOn: $usesSerif)
                        .tint(AppTheme.vermilion)
                }
                Section("版式") {
                    Picker("页面留白", selection: $marginValue) {
                        ForEach(ReaderMargin.allCases) { margin in
                            Text(margin.title).tag(margin.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    Toggle("段首缩进两格", isOn: $paragraphIndent)
                        .tint(AppTheme.vermilion)
                    Button("恢复舒适默认版式") {
                        fontSize = 19
                        lineSpacing = 9
                        usesSerif = true
                        marginValue = ReaderMargin.comfortable.rawValue
                        paragraphIndent = true
                    }
                    .foregroundStyle(AppTheme.vermilion)
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
            .navigationTitle("主题与设置")
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
        case .warm: Color(red: 0.97, green: 0.94, blue: 0.87)
        case .white: Color(red: 0.98, green: 0.98, blue: 0.97)
        case .green: Color(red: 0.87, green: 0.92, blue: 0.86)
        case .night: Color(red: 0.08, green: 0.10, blue: 0.11)
        }
    }
    var primaryText: Color {
        self == .night ? Color(red: 0.78, green: 0.78, blue: 0.73) : Color(red: 0.12, green: 0.12, blue: 0.13)
    }
    var secondaryText: Color {
        self == .night ? Color(red: 0.58, green: 0.60, blue: 0.58) : Color(red: 0.43, green: 0.43, blue: 0.45)
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
