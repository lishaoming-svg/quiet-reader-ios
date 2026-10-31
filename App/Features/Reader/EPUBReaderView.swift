import ReadiumNavigator
import ReadiumShared
import ReadiumStreamer
import SwiftData
import SwiftUI
import WebKit

@MainActor
final class EPUBReaderModel: NSObject, ObservableObject, EPUBNavigatorDelegate {
    @Published var navigator: EPUBNavigatorViewController?
    @Published var errorMessage: String?
    @Published var controlsVisible = false
    var readingMode = ReaderMode.pageCurl
    var requestTurn: ((Int) -> Void)?
    @Published var progress = 0.0
    @Published var locationTitle = ""
    @Published var bookmarkAdded = false
    @Published var tocLinks: [ReadiumShared.Link] = []
    @Published var isRestoring = false
    @Published var noteToEdit: BookmarkRecord?
    private(set) var publication: Publication?
    private var tapToken: InputObservableToken?
    private var context: ModelContext?
    private var book: SearchBook?
    private var chapters: [BookChapter] = []
    private var session: ReadingSessionRecord?
    private var lastTick = Date.now
    private var lastActivity = Date.now
    private var active = true
    var continuousNavigation: ((ContinuousReadingPosition) -> Void)?
    var continuousActive = false
    private var currentLocator: Locator?

    var continuousPosition: ContinuousReadingPosition {
        guard let publication, !publication.readingOrder.isEmpty else { return .init(index: 0) }
        let locator = currentLocator ?? navigator?.currentLocation
        let href = locator?.href.string.components(separatedBy: "#")[0] ?? ""
        let index = publication.readingOrder.firstIndex { $0.href.components(separatedBy: "#")[0] == href } ?? 0
        return .init(index: index, fraction: locator?.locations.progression ?? 0,
            fragment: locator?.href.string.components(separatedBy: "#").dropFirst().joined(separator: "#") ?? "",
            quote: locator?.text.highlight ?? "")
    }

    static func preferences(publisherStyles: Bool, fontSizePercent: Double, scroll: Bool, theme: String,
                            direction: EPUBTextDirection = .publisher) -> EPUBPreferences {
        EPUBReadingLayout.preferences(publisherStyles: publisherStyles, fontSizePercent: fontSizePercent,
                                      scroll: scroll, theme: theme, direction: direction)
    }

    func open(book: SearchBook, chapters: [BookChapter], context: ModelContext, preferences: EPUBPreferences,
              source: BookSourceDefinition? = nil, initialIndex: Int = 0) async {
        guard navigator == nil else { return }
        self.book = book; self.chapters = chapters; self.context = context; errorMessage = nil
        do {
            let publication: Publication
            if let source {
                let repository = SourceChapterRepository(book: book, chapters: chapters, source: source, context: context)
                repository.failure = { [weak self] message in self?.errorMessage = message }
                publication = repository.publication()
            } else {
                let url = try LocalBookStorage.publicationURL(for: book.bookURL)
                guard let fileURL = FileURL(url: url) else { throw LocalBookError.missing }
                let asset = try await AssetRetriever(httpClient: DefaultHTTPClient()).retrieve(url: fileURL).get()
                publication = try await PublicationOpener(parser: EPUBParser()).open(asset: asset, allowUserInteraction: false).get()
            }
            let contents = (try? await publication.tableOfContents().get()) ?? []
            tocLinks = contents.isEmpty ? publication.readingOrder : contents
            try Task.checkCancellation()
            let id = book.id
            let saved = try context.fetch(FetchDescriptor<ReadingProgressRecord>(predicate: #Predicate { $0.bookID == id })).first
            var locator = saved?.publicationLocator.flatMap { try? Locator(jsonString: $0) }
            if source != nil, saved?.chapterIndex != initialIndex { locator = nil }
            if source != nil, let savedLocation = locator, publication.readingOrder.indices.contains(initialIndex),
               savedLocation.href.string.components(separatedBy: "#")[0] != publication.readingOrder[initialIndex].href.components(separatedBy: "#")[0] { locator = nil }
            if source != nil, locator == nil, !publication.readingOrder.isEmpty {
                let index = min(max(initialIndex, 0), publication.readingOrder.count - 1)
                let link = publication.readingOrder[index]
                locator = Locator(href: link.url(), mediaType: .xhtml, title: link.title,
                    locations: .init(progression: saved?.chapterIndex == index ? saved?.chapterProgress ?? 0 : 0))
            }
            if locator == nil, let saved, saved.importedParagraphIndex != nil, !publication.readingOrder.isEmpty {
                let uri = saved.importedSectionURI?.removingPercentEncoding ?? saved.importedSectionURI ?? ""
                let matchedIndex = publication.readingOrder.firstIndex { uri.hasSuffix(($0.href.removingPercentEncoding ?? $0.href).components(separatedBy: "#")[0]) }
                    ?? min(max(saved.chapterIndex, 0), publication.readingOrder.count - 1)
                let index = saved.bookProgress == 1 ? publication.readingOrder.count - 1 : matchedIndex
                let link = publication.readingOrder[index]
                let body = chapters.indices.contains(index) ? (try? LocalBookStorage.content(at: chapters[index].url)) ?? "" : ""
                let paragraphs = body.components(separatedBy: CharacterSet.newlines).filter { !$0.trimmingCharacters(in: CharacterSet.whitespaces).isEmpty }
                let paragraph = saved.importedParagraphIndex ?? 0
                let quote = paragraphs.indices.contains(paragraph) ? String(paragraphs[paragraph].prefix(80)) : nil
                locator = Locator(href: link.url(), mediaType: .xhtml, title: link.title,
                    locations: .init(progression: saved.bookProgress == 1 ? 1 : nil, totalProgression: saved.bookProgress), text: .init(highlight: quote))
            }
            isRestoring = locator != nil
            currentLocator = locator
            var config = EPUBNavigatorViewController.Configuration(preferences: preferences)
            if source == nil {
                config.editingActions += [EditingAction(title: "高亮", action: #selector(EPUBCurlController.highlightSelection)),
                    EditingAction(title: "添加笔记", action: #selector(EPUBCurlController.noteSelection))]
            }
            config.disablePageTurnsWhileScrolling = true
            config.contentInset = [.compact: (top: 12, bottom: 12), .regular: (top: 16, bottom: 16)]
            // Each opening owns a fresh controller. Let Readium lay out the saved
            // resource directly instead of jumping while its first spread loads.
            let navigator = try EPUBNavigatorViewController(publication: publication, initialLocation: locator, config: config)
            navigator.delegate = self
            // Readium consumes links and selection before this observer. Edge taps
            // use the same turn controller as swipe gestures; the center reveals tools.
            tapToken = navigator.addObserver(.tap { [weak self] event in
                guard let self else { return false }
                self.lastActivity = .now
                let width = self.navigator?.view.bounds.width ?? 0
                if self.readingMode != .scroll, width > 0, event.location.x < width * 0.2 || event.location.x > width * 0.8 {
                    let right = event.location.x > width / 2
                    let forward = right == (self.navigator?.settings.readingProgression == .ltr)
                    self.requestTurn?(forward ? 1 : -1)
                } else { self.controlsVisible.toggle() }
                return true
            })
            self.publication = publication; self.navigator = navigator
            reloadHighlights()
            progress = saved?.bookProgress ?? 0
            let session = ReadingSessionRecord(sessionID: UUID().uuidString, bookID: id, bookName: book.name, sourceID: book.sourceID)
            context.insert(session); self.session = session; lastTick = .now; lastActivity = .now
            active = true
            try context.save()
        } catch is CancellationError { return
        } catch { errorMessage = source == nil ? "无法打开 EPUB：\(error.localizedDescription)\n请重新导入未加密、完整的原文件。" : "书籍暂时无法打开：\(error.localizedDescription)" }
    }

    func navigator(_ navigator: Navigator, locationDidChange locator: Locator) {
        guard !continuousActive, !isRestoring, let controller = navigator as? EPUBNavigatorViewController,
              controller.viewport != nil else { return }
        guard let publication else { return }
        let index = publication.readingOrder.firstIndex { $0.href.components(separatedBy: "#")[0] == locator.href.string.components(separatedBy: "#")[0] } ?? 0
        controlsVisible = false
        persist(locator, index: index)
    }
    private func persist(_ locator: Locator, index: Int) {
        guard let context, let book, !chapters.isEmpty else { return }
        currentLocator = locator
        let id = book.id
        let chapter = chapters[min(index, chapters.count - 1)]
        progress = min(1, max(0, locator.locations.totalProgression ?? Double(index) / Double(chapters.count)))
        locationTitle = locator.title ?? chapter.title
        do {
            let record = try context.fetch(FetchDescriptor<ReadingProgressRecord>(predicate: #Predicate { $0.bookID == id })).first
                ?? ReadingProgressRecord(bookID: id, chapter: chapter)
            if record.modelContext == nil { context.insert(record) }
            record.update(chapter: chapter, chapterProgress: locator.locations.progression ?? 0, readingMode: "epub")
            record.publicationLocator = try locator.jsonString()
            record.bookProgress = progress
            if let shelf = try context.fetch(FetchDescriptor<BookRecord>(predicate: #Predicate { $0.bookID == id })).first { shelf.lastReadAt = .now }
            try context.save()
            bookmarkAdded = false; lastActivity = .now
        } catch { errorMessage = "阅读位置保存失败：\(error.localizedDescription)" }
    }
    func continuousChanged(_ position: ContinuousReadingPosition) {
        guard let publication, publication.readingOrder.indices.contains(position.index), !isRestoring else { return }
        let link = publication.readingOrder[position.index]
        let locator = Locator(href: link.url(), mediaType: .xhtml, title: link.title,
            locations: .init(progression: position.fraction,
                totalProgression: (Double(position.index) + position.fraction) / Double(max(1, publication.readingOrder.count))))
        persist(locator, index: position.index)
    }
    func navigator(_ navigator: any ViewportObservingNavigator, viewportDidChange viewport: NavigatorViewport?) {
        guard isRestoring, viewport != nil, let controller = self.navigator,
              let current = controller.currentLocation else { return }
        isRestoring = false
        self.navigator(controller, locationDidChange: current)
    }

    func finish() {
        if !continuousActive, let navigator, let locator = navigator.currentLocation { self.navigator(navigator, locationDidChange: locator) }
        tick(isActive: false)
    }

    func close() {
        finish()
        navigator?.delegate = nil
        tapToken = nil
        requestTurn = nil
        navigator = nil
        publication = nil
        isRestoring = false
        controlsVisible = false
        continuousNavigation = nil; continuousActive = false; currentLocator = nil
    }
    func navigator(_ navigator: EPUBNavigatorViewController, setupUserScripts userContentController: WKUserContentController) {
        guard publication?.metadata.layout != .fixed else { return }
        userContentController.addUserScript(WKUserScript(source: EPUBReadingLayout.imageScript,
            injectionTime: .atDocumentStart, forMainFrameOnly: false))
    }
    func navigator(_ navigator: Navigator, presentError error: NavigatorError) { errorMessage = "暂时无法完成这个阅读操作，请重试。" }
    func navigator(_ navigator: Navigator, didFailToLoadResourceAt href: RelativeURL, withError error: ReadError) {
        guard let publication, let url = URL(string: "ibooks-stream://publication/" + href.string),
              PublicationResourcePolicy.isReadingResource(url, in: publication) else { return }
        if errorMessage == nil { errorMessage = PublicationResourcePolicy.readingFailure(url) }
    }

    func go(_ link: ReadiumShared.Link) {
        if continuousActive, let publication,
           let index = publication.readingOrder.firstIndex(where: { $0.href.components(separatedBy: "#")[0] == link.href.components(separatedBy: "#")[0] }) {
            continuousNavigation?(.init(index: index, fragment: link.href.components(separatedBy: "#").dropFirst().joined(separator: "#")))
        } else { Task { _ = await navigator?.go(to: link) } }
    }
    func go(index: Int, excerpt: String) {
        guard let publication, publication.readingOrder.indices.contains(index) else { return }
        if continuousActive { continuousNavigation?(.init(index: index, quote: excerpt)); return }
        let href = publication.readingOrder[index].url()
        let locator = Locator(href: href, mediaType: .xhtml, text: .init(highlight: excerpt))
        Task { _ = await navigator?.go(to: locator) }
    }
    func bookmark() {
        guard let context, let book, let locator = continuousActive ? currentLocator : navigator?.currentLocation, !chapters.isEmpty else { return }
        do {
            let index = publication?.readingOrder.firstIndex { $0.href == locator.href.string } ?? 0
            let mark = BookmarkRecord(book: book, chapter: chapters[min(index, chapters.count - 1)], locatorOffset: 0,
                chapterProgress: locator.locations.progression ?? 0, excerpt: locator.text.highlight ?? locationTitle)
            mark.publicationLocator = try locator.jsonString()
            context.insert(mark); try context.save(); bookmarkAdded = true
        } catch { errorMessage = "书签保存失败：\(error.localizedDescription)" }
    }
    func makeNote(at selection: Locator? = nil) -> BookmarkRecord? {
        guard let book, let publication, let locator = selection ?? (continuousActive ? currentLocator : navigator?.currentSelection?.locator ?? navigator?.currentLocation),
              !chapters.isEmpty else { return nil }
        let index = publication.readingOrder.firstIndex { $0.href.components(separatedBy: "#")[0] == locator.href.string.components(separatedBy: "#")[0] } ?? 0
        let mark = BookmarkRecord(book: book, chapter: chapters[min(index, chapters.count - 1)], locatorOffset: 0,
            chapterProgress: locator.locations.progression ?? 0, excerpt: locator.text.highlight ?? locator.title ?? locationTitle)
        mark.publicationLocator = try? locator.jsonString()
        return mark
    }
    func annotate(_ locator: Locator, edit: Bool) {
        guard let context, let mark = makeNote(at: locator) else { return }
        mark.noteKind = "highlight"; mark.annotationColor = "yellow"
        if edit { noteToEdit = mark }
        else {
            context.insert(mark)
            do { try context.save(); reloadHighlights() } catch { errorMessage = "笔记保存失败：\(error.localizedDescription)" }
        }
    }
    func reloadHighlights() {
        guard let context, let book, book.sourceID == LocalBookStorage.sourceID else { return }
        let id = book.id
        let records = (try? context.fetch(FetchDescriptor<BookmarkRecord>(predicate: #Predicate { $0.bookID == id }))) ?? []
        let decorations = records.filter { $0.noteKind != "bookmark" }.compactMap { mark -> Decoration? in
            guard let json = mark.publicationLocator, let locator = try? Locator(jsonString: json), locator.text.highlight?.isEmpty == false else { return nil }
            return Decoration(id: mark.bookmarkID, locator: locator, style: .highlight(tint: UIColor((AnnotationColor(rawValue: mark.annotationColor ?? "yellow") ?? .yellow).color)))
        }
        navigator?.apply(decorations: decorations, in: "ibooks.notes")
    }
    func go(bookmark: BookmarkRecord) {
        let imported = publication.flatMap { publication -> Locator? in
            guard publication.readingOrder.indices.contains(bookmark.chapterIndex) else { return nil }
            let href = publication.readingOrder[bookmark.chapterIndex].url()
            return Locator(href: href, mediaType: .xhtml,
                locations: .init(progression: bookmark.chapterProgress), text: .init(highlight: bookmark.excerpt.nilIfBlank))
        }
        guard let locator = bookmark.publicationLocator.flatMap({ try? Locator(jsonString: $0) }) ?? imported else { return }
        if continuousActive, let publication,
           let index = publication.readingOrder.firstIndex(where: { $0.href.components(separatedBy: "#")[0] == locator.href.string.components(separatedBy: "#")[0] }) {
            continuousNavigation?(.init(index: index, fraction: locator.locations.progression ?? 0, quote: locator.text.highlight ?? "")); return
        }
        Task { _ = await navigator?.go(to: locator) }
    }
    func switchFromContinuous() {
        continuousActive = false
        if let currentLocator { Task { _ = await navigator?.go(to: currentLocator, options: .init(animated: false)) } }
    }
    func tick(isActive: Bool) {
        let now = Date.now
        if active, now.timeIntervalSince(lastActivity) <= 300, let session {
            session.activeSeconds += min(30, max(0, now.timeIntervalSince(lastTick)))
            session.endedAt = now
            try? context?.save()
        }
        active = isActive; lastTick = now
    }
}

struct EPUBReaderView: View {
    let book: SearchBook
    let chapters: [BookChapter]
    var source: BookSourceDefinition? = nil
    var initialIndex = 0
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = EPUBReaderModel()
    @AppStorage("epub.publisherStyles") private var publisherStyles = true
    @AppStorage("epub.fontSize") private var fontSize = 100.0
    @AppStorage("epub.scroll") private var legacyScroll = false
    @AppStorage("epub.mode") private var modeValue = ReaderMode.pageCurl.rawValue
    @AppStorage("epub.direction") private var directionValue = EPUBTextDirection.publisher.rawValue
    @AppStorage("epub.theme") private var theme = "sepia"
    @AppStorage("reader.lineGuideEnabled") private var lineGuideEnabled = false
    @AppStorage("reader.family") private var localFamily = BooksFont.pingfang.rawValue
    @AppStorage("reader.bold") private var localBold = false
    @AppStorage("local.reader.preset") private var localPreset = ""
    @State private var showingMenu = false
    @State private var showingToolbox = false
    @State private var menuSection = "主题与设置"
    @State private var showingSourceLogin = false
    @State private var showingAudiobook = false
    @State private var showingSentenceReader = false
    @State private var pendingAudio: String?
    @State private var showingNotes = false
    @State private var pendingNote = false
    @State private var editingAnnotation: BookmarkRecord?
    @State private var audioIndex = 0
    @Query private var bookmarks: [BookmarkRecord]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var readingMode: ReaderMode {
        if directionValue == EPUBTextDirection.vertical.rawValue { return .scroll }
        let selected = ReaderMode(rawValue: modeValue) ?? .pageCurl
        return reduceMotion && selected == .pageCurl ? .pageNone : selected
    }
    private var background: SwiftUI.Color {
        if source == nil, localPreset == BooksThemePreset.calm.rawValue, theme == "light" {
            return SwiftUI.Color(red: 0.87, green: 0.92, blue: 0.86)
        }
        return theme == "dark" ? .black : theme == "sepia" ? SwiftUI.Color(red: 242/255, green: 227/255, blue: 200/255) : .white
    }
    private var preferences: EPUBPreferences {
        var value = EPUBReaderModel.preferences(publisherStyles: publisherStyles, fontSizePercent: fontSize, scroll: readingMode == .scroll,
                                    theme: theme, direction: EPUBTextDirection(rawValue: directionValue) ?? .publisher)
        if source == nil, !publisherStyles {
            if let family = BooksFont(rawValue: localFamily), family != .publisher { value.fontFamily = FontFamily(rawValue: family.family) }
            value.fontWeight = localBold ? 1.5 : 1
            value.lineHeight = localPreset == BooksThemePreset.focus.rawValue ? 1.9 : 1.68
            if localPreset == BooksThemePreset.calm.rawValue, theme == "light" { value.backgroundColor = ReadiumNavigator.Color(hex: "#deebdb") }
        }
        return value
    }
    private var localTypography: [String: Any]? {
        guard source == nil, !publisherStyles else { return nil }
        return ["font": (BooksFont(rawValue: localFamily) ?? .pingfang).family,
            "paper": theme == "dark" ? "#151515" : theme == "sepia" ? "#f2e3c8" : localPreset == BooksThemePreset.calm.rawValue ? "#deebdb" : "#ffffff",
            "embedded": false, "bold": localBold, "margin": 26, "maxWidth": 660,
            "lineSpacing": 18 * fontSize / 100 * (localPreset == BooksThemePreset.focus.rawValue ? 0.9 : 0.68),
            "paragraphSpacing": 16, "indent": true]
    }

    var body: some View {
        lifecycleCanvas
            .sheet(isPresented: $showingMenu, onDismiss: {
                guard let action = pendingAudio else { return }
                pendingAudio = nil
                if action == "audio" { showingAudiobook = true } else { showingSentenceReader = true }
            }) { menu.presentationDetents([.medium, .large]).presentationDragIndicator(.visible) }
            .sheet(isPresented: $showingSourceLogin) {
                if let source { SourceLoginView(source: source) { Task { model.close(); await openBook() } } }
            }
            .sheet(isPresented: $showingNotes, onDismiss: {
                if pendingNote { pendingNote = false; editingAnnotation = model.makeNote() }
            }) {
                BookmarkListView(bookID: book.id, addNote: { pendingNote = true; showingNotes = false }) { mark in
                    showingNotes = false; model.go(bookmark: mark)
                }
            }
            .sheet(item: $editingAnnotation) { AnnotationEditorView(bookmark: $0) }
            .onReceive(model.$noteToEdit.compactMap { $0 }) { mark in editingAnnotation = mark; model.noteToEdit = nil }
            .onChange(of: editingAnnotation == nil) { _, closed in if closed { model.reloadHighlights() } }
            .sheet(isPresented: $showingAudiobook) {
                AudiobookView(book: book, chapters: chapters, source: source ?? LocalBookStorage.source,
                    currentIndex: audioIndex)
            }
            .fullScreenCover(isPresented: $showingSentenceReader) {
                NavigationStack { NativeTextReaderView(book: book, chapters: chapters,
                    initialIndex: audioIndex, source: source ?? LocalBookStorage.source) }
            }
            .alert("阅读提示", isPresented: errorPresented) { errorActions } message: { Text(model.errorMessage ?? "") }
    }
    private var errorPresented: SwiftUI.Binding<Bool> {
        SwiftUI.Binding(get: { model.errorMessage != nil }, set: { visible in if !visible { model.errorMessage = nil } })
    }
    @ViewBuilder private var errorActions: some View {
        if let source, NativeLofterAdapter.accepts(source) || source.loginUrl?.hasPrefix("http") == true {
            Button("登录书源") { showingSourceLogin = true }
        }
        if model.navigator == nil {
            Button("重新打开") { Task { await openBook() } }
        } else {
            Button("重新加载本章") { Task { model.close(); await openBook() } }
            Button("继续阅读") { model.errorMessage = nil }
        }
        Button("返回书库", role: .cancel) { model.close(); dismiss() }
    }
    private var lifecycleCanvas: some View {
        preferenceCanvas
            .task { await openBook() }
            .task { await sessionTimer() }
            .onDisappear { if showingMenu || showingNotes || editingAnnotation != nil || pendingNote || showingAudiobook || showingSentenceReader || showingSourceLogin || pendingAudio != nil { model.finish() } else { model.close() } }
            .onChange(of: scenePhase) { _, phase in model.tick(isActive: phase == .active) }
            .onChange(of: model.controlsVisible) { _, visible in if !visible { showingToolbox = false } }
    }
    private var preferenceCanvas: some View {
        appearanceCanvas
            .onChange(of: publisherStyles) { _, _ in updatePreferences() }
            .onChange(of: fontSize) { _, _ in updatePreferences() }
            .onChange(of: modeValue) { _, _ in updatePreferences() }
            .onChange(of: directionValue) { _, _ in updatePreferences() }
            .onChange(of: reduceMotion) { _, _ in updatePreferences() }
            .onChange(of: theme) { _, _ in updatePreferences() }
            .onChange(of: localFamily) { _, _ in if source == nil { updatePreferences() } }
            .onChange(of: localBold) { _, _ in if source == nil { updatePreferences() } }
            .onChange(of: localPreset) { _, _ in if source == nil { updatePreferences() } }
    }
    private var appearanceCanvas: some View {
        readingCanvas
            .foregroundStyle(theme == "dark" ? SwiftUI.Color.white : SwiftUI.Color.black)
            .environment(\.colorScheme, theme == "dark" ? .dark : .light)
            .navigationBarBackButtonHidden().toolbar(.hidden, for: .navigationBar, .tabBar)
            .statusBarHidden(!model.controlsVisible)
            .accessibilityAction(named: "显示阅读菜单") { model.controlsVisible = true }
            .accessibilityAction(.escape) { model.close(); dismiss() }
    }
    private func openBook() async {
        if UserDefaults.standard.object(forKey: "epub.mode") == nil, legacyScroll { modeValue = ReaderMode.scroll.rawValue }
        model.readingMode = readingMode
        await model.open(book: book, chapters: chapters, context: context, preferences: preferences, source: source, initialIndex: initialIndex)
    }
    private func sessionTimer() async {
        while !Task.isCancelled {
            do { try await Task.sleep(for: .seconds(15)) } catch { break }
            model.tick(isActive: scenePhase == .active)
        }
    }

    private var readingCanvas: some View {
        ZStack {
            background.ignoresSafeArea()
            if readingMode == .scroll, directionValue != EPUBTextDirection.vertical.rawValue,
               model.navigator?.settings.verticalText != true,
               let publication = model.publication, publication.metadata.layout != .fixed {
                ContinuousPublicationView(publication: publication, initial: model.continuousPosition, theme: theme,
                    publisherStyles: publisherStyles, fontSize: fontSize, typography: localTypography,
                    scrolled: { model.controlsVisible = false },
                    changed: { model.continuousChanged($0) }, tapped: { model.controlsVisible.toggle() },
                    ready: { model.isRestoring = false }, failure: { model.errorMessage = $0 },
                    installNavigation: { model.continuousNavigation = $0; model.continuousActive = true })
                    .ignoresSafeArea(edges: .bottom)
            } else if let navigator = model.navigator {
                EPUBPageCurlHost(navigator: navigator, mode: readingMode, paper: UIColor(background),
                    onTurn: { model.controlsVisible = false }, installTurnHandler: { model.requestTurn = $0 },
                    onAnnotation: source == nil ? { locator, edit in model.annotate(locator, edit: edit) } : nil)
                    .ignoresSafeArea(edges: .bottom)
            }
            else if model.errorMessage == nil { ProgressView("正在展开原书精排…") }
            if model.isRestoring {
                background.ignoresSafeArea()
                ProgressView("正在恢复阅读位置…").accessibilityIdentifier("epub.restoring")
            }
            if lineGuideEnabled {
                ReaderLineGuide(paper: background, lineHeight: 27 * fontSize / 100).ignoresSafeArea(edges: .bottom)
            }
            if model.controlsVisible {
                VStack {
                    HStack {
                        Spacer(minLength: 56)
                        Text(book.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                            .padding(.horizontal, 16).padding(.vertical, 9).background(.regularMaterial, in: Capsule())
                        Spacer(minLength: 12)
                        Button { model.close(); dismiss() } label: { Image(systemName: "xmark").font(.title2.weight(.semibold)).frame(width: 48, height: 48) }
                            .background(.regularMaterial, in: Circle()).accessibilityLabel("关闭图书").accessibilityIdentifier("reader.close")
                    }
                    Spacer()
                    HStack {
                        Spacer(minLength: 56)
                        Text("\(Int(model.progress * 100))%")
                            .font(.subheadline.weight(.semibold)).monospacedDigit().padding(.horizontal, 14).padding(.vertical, 8)
                            .background(.regularMaterial, in: Capsule()).accessibilityLabel("全书进度 \(Int(model.progress * 100))%")
                        Spacer(minLength: 12)
                        Button { showingToolbox.toggle() } label: { Image(systemName: "line.3.horizontal.decrease").font(.title2.bold()).frame(width: 48, height: 48) }
                            .background(.regularMaterial, in: Circle()).accessibilityLabel("阅读菜单").accessibilityIdentifier("reader.menu")
                            .disabled(model.isRestoring)
                    }
                }.padding(.horizontal, 24).padding(.top, 4).padding(.bottom, 16)
            }
            if showingToolbox && model.controlsVisible {
                Color.black.opacity(0.03).ignoresSafeArea().onTapGesture { showingToolbox = false }
                VStack { Spacer(); HStack {
                    Spacer(minLength: 0)
                    ReaderToolbox(contents: { openMenu("目录") }, search: { openMenu("在图书中搜索") }, settings: { openMenu("主题与设置") },
                        direction: { directionValue = directionValue == EPUBTextDirection.vertical.rawValue ? EPUBTextDirection.horizontal.rawValue : EPUBTextDirection.vertical.rawValue; showingToolbox = false },
                        scroll: { modeValue = readingMode == .scroll ? ReaderMode.pageCurl.rawValue : ReaderMode.scroll.rawValue; showingToolbox = false },
                        bookmark: { model.bookmark(); showingToolbox = false }, shareURL: try? LocalBookStorage.publicationURL(for: book.bookURL),
                        lineGuide: { lineGuideEnabled.toggle(); showingToolbox = false; model.controlsVisible = false },
                        notes: source == nil ? { showingToolbox = false; showingNotes = true } : nil)
                }.padding(.horizontal, 24).padding(.bottom, 72) }
            }
        }
    }

    private func updatePreferences() {
        let vertical = directionValue == EPUBTextDirection.vertical.rawValue || (directionValue == EPUBTextDirection.publisher.rawValue && model.navigator?.settings.verticalText == true)
        if model.continuousActive, readingMode != .scroll || vertical { model.switchFromContinuous() }
        model.readingMode = readingMode; model.navigator?.submitPreferences(preferences)
    }
    private func openMenu(_ section: String) { menuSection = section; showingToolbox = false; showingMenu = true }
    private var menu: some View {
        NavigationStack {
          Group {
            if menuSection == "在图书中搜索" {
                EPUBTextSearchView(book: book, chapters: chapters, source: source) { index, excerpt in showingMenu = false; model.go(index: index, excerpt: excerpt) }
            } else {
            List {
              if menuSection == "主题与设置" {
                if source == nil { BooksAppearanceControls(epub: true) }
                Section("主题与排版") {
                    Toggle("逐行导读", isOn: $lineGuideEnabled).accessibilityIdentifier("reader.lineGuide")
                    Toggle("原书精排", isOn: $publisherStyles).accessibilityIdentifier("epub.publisherStyles")
                    Text("保留原书插图、字体、标题装饰、注音和 CSS。关闭后可统一正文字号；固定版式遵循原书布局。")
                        .font(.footnote).foregroundStyle(.secondary)
                    if !publisherStyles { Slider(value: $fontSize, in: 75...200, step: 5) { Text("字号") } }
                    Picker("纸张", selection: $theme) { Text("白色").tag("light"); Text("暖色").tag("sepia"); Text("夜间").tag("dark") }
                    Picker("翻页方式", selection: $modeValue) {
                        ForEach(ReaderMode.allCases) { mode in Text(mode.title).tag(mode.rawValue) }
                    }.accessibilityIdentifier("epub.readingMode")
                    Picker("文字方向", selection: $directionValue) {
                        ForEach(EPUBTextDirection.allCases) { direction in Text(direction.title).tag(direction.rawValue) }
                    }.accessibilityIdentifier("epub.textDirection")
                    if directionValue == EPUBTextDirection.vertical.rawValue { Text("竖排文字从右向左横向滚动，保留原书注音与标点方向。").font(.footnote).foregroundStyle(.secondary) }
                    Button(model.bookmarkAdded ? "书签已添加" : "添加书签", systemImage: "bookmark") { model.bookmark() }
                        .disabled(model.bookmarkAdded)
                    Button("听书", systemImage: "headphones") { audioIndex = model.continuousPosition.index; pendingAudio = "audio"; showingMenu = false }
                    Button("逐句点播", systemImage: "play.circle") { audioIndex = model.continuousPosition.index; pendingAudio = "sentence"; showingMenu = false }
                }
              }
                if menuSection == "目录", !model.tocLinks.isEmpty {
                    Section("目录") { toc(model.tocLinks, depth: 0) }
                }
                let marks = bookmarks.filter { $0.bookID == book.id }
                if !marks.isEmpty {
                    Section("书签") {
                        ForEach(marks) { mark in
                            Button { showingMenu = false; model.go(bookmark: mark) } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(mark.chapterTitle).lineLimit(2)
                                    if !mark.excerpt.isEmpty { Text(mark.excerpt).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
                                    if !mark.note.isEmpty { Text(mark.note).font(.subheadline) }
                                }
                            }
                                .contextMenu { Button("删除书签", role: .destructive) { context.delete(mark); try? context.save() } }
                        }
                    }
                }
            }
            }
          }
            .navigationTitle(menuSection).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showingMenu = false } } }
        }
    }
    private func toc(_ links: [ReadiumShared.Link], depth: Int) -> some View {
        let entries = flatten(links, depth: depth)
        return ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
            Button { showingMenu = false; model.go(entry.0) } label: {
                Text(entry.0.title ?? "章节").padding(.leading, CGFloat(entry.1) * 16)
            }
        }
    }
    private func flatten(_ links: [ReadiumShared.Link], depth: Int) -> [(ReadiumShared.Link, Int)] {
        links.flatMap { [($0, depth)] + flatten($0.children, depth: depth + 1) }
    }
}

struct EPUBTextSearchView: View {
    let book: SearchBook
    let chapters: [BookChapter]
    let source: BookSourceDefinition?
    let select: (Int, String) -> Void
    @Environment(\.modelContext) private var context
    @State private var query = ""
    @State private var results: [Hit] = []
    @State private var searching = false
    private struct Hit: Identifiable { let id = UUID(); let index: Int; let title: String; let excerpt: String }
    var body: some View {
        List {
            if searching { ProgressView("正在搜索正文…") }
            if !searching, results.isEmpty { Text(query.isEmpty ? "输入文字搜索原书正文" : "没有找到匹配的文字").foregroundStyle(.secondary) }
            ForEach(results) { hit in
                Button { select(hit.index, hit.excerpt) } label: {
                    VStack(alignment: .leading, spacing: 6) { Text(hit.title).font(.headline); Text(hit.excerpt).font(.subheadline).foregroundStyle(.secondary).lineLimit(3) }
                }
            }
        }.searchable(text: $query, prompt: "在图书中搜索")
        .task(id: query) {
            results = []; guard let keyword = query.nilIfBlank else { searching = false; return }
            searching = true
            do {
                try await Task.sleep(for: .milliseconds(250))
                if let source {
                    let repository = SourceChapterRepository(book: book, chapters: chapters, source: source, context: context)
                    var found: [Hit] = []
                    for index in chapters.indices {
                        try Task.checkCancellation()
                        let body = try await repository.load(index).text
                        for paragraph in body.components(separatedBy: .newlines) where paragraph.localizedStandardContains(keyword) {
                            found.append(Hit(index: index, title: chapters[index].title, excerpt: paragraph))
                            if found.count == 100 { break }
                        }
                        if found.count == 100 { break }
                    }
                    results = found; searching = false; return
                }
                let worker = Task.detached(priority: .userInitiated) { () throws -> [Hit] in
                    var hits: [Hit] = []
                    for (index, chapter) in chapters.enumerated() {
                        try Task.checkCancellation()
                        let body = try LocalBookStorage.content(at: chapter.url)
                        for paragraph in body.components(separatedBy: .newlines) where paragraph.localizedStandardContains(keyword) {
                            hits.append(Hit(index: index, title: chapter.title, excerpt: paragraph))
                            if hits.count == 100 { return hits }
                        }
                    }
                    return hits
                }
                let found = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation(); results = found; searching = false
            } catch { if !Task.isCancelled { searching = false } }
        }
    }
}
