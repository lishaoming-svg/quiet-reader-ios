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
    private(set) var publication: Publication?
    private var tapToken: InputObservableToken?
    private var context: ModelContext?
    private var book: SearchBook?
    private var chapters: [BookChapter] = []
    private var session: ReadingSessionRecord?
    private var lastTick = Date.now
    private var lastActivity = Date.now
    private var active = true

    static func preferences(publisherStyles: Bool, fontSizePercent: Double, scroll: Bool, theme: String,
                            direction: EPUBTextDirection = .publisher) -> EPUBPreferences {
        EPUBReadingLayout.preferences(publisherStyles: publisherStyles, fontSizePercent: fontSizePercent,
                                      scroll: scroll, theme: theme, direction: direction)
    }

    func open(book: SearchBook, chapters: [BookChapter], context: ModelContext, preferences: EPUBPreferences) async {
        guard navigator == nil else { return }
        self.book = book; self.chapters = chapters; self.context = context; errorMessage = nil
        do {
            let url = try LocalBookStorage.publicationURL(for: book.bookURL)
            guard let fileURL = FileURL(url: url) else { throw LocalBookError.missing }
            let client = DefaultHTTPClient()
            let retriever = AssetRetriever(httpClient: client)
            let asset = try await retriever.retrieve(url: fileURL).get()
            let publication = try await PublicationOpener(parser: EPUBParser()).open(asset: asset, allowUserInteraction: false).get()
            let contents = (try? await publication.tableOfContents().get()) ?? []
            tocLinks = contents.isEmpty ? publication.readingOrder : contents
            try Task.checkCancellation()
            let id = book.id
            let saved = try context.fetch(FetchDescriptor<ReadingProgressRecord>(predicate: #Predicate { $0.bookID == id })).first
            var locator = saved?.publicationLocator.flatMap { try? Locator(jsonString: $0) }
            if locator == nil, let saved, saved.importedSectionURI != nil, !publication.readingOrder.isEmpty {
                let uri = saved.importedSectionURI?.removingPercentEncoding ?? saved.importedSectionURI ?? ""
                let index = publication.readingOrder.firstIndex { uri.hasSuffix($0.href.string.components(separatedBy: "#")[0]) }
                    ?? min(max(saved.chapterIndex, 0), publication.readingOrder.count - 1)
                let link = publication.readingOrder[index]
                let body = chapters.indices.contains(index) ? (try? LocalBookStorage.content(at: chapters[index].url)) ?? "" : ""
                let paragraphs = body.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                let paragraph = saved.importedParagraphIndex ?? 0
                let quote = paragraphs.indices.contains(paragraph) ? String(paragraphs[paragraph].prefix(80)) : nil
                locator = Locator(href: link.href, mediaType: .xhtml, title: link.title,
                    locations: .init(progression: saved.bookProgress == 1 ? 1 : nil, totalProgression: saved.bookProgress), text: .init(highlight: quote))
            }
            isRestoring = locator != nil
            var config = EPUBNavigatorViewController.Configuration(preferences: preferences)
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
            progress = saved?.bookProgress ?? 0
            let session = ReadingSessionRecord(sessionID: UUID().uuidString, bookID: id, bookName: book.name, sourceID: book.sourceID)
            context.insert(session); self.session = session; lastTick = .now; lastActivity = .now
            active = true
            try context.save()
        } catch is CancellationError { return
        } catch { errorMessage = "无法打开 EPUB：\(error.localizedDescription)\n请重新导入未加密、完整的原文件。" }
    }

    func navigator(_ navigator: Navigator, locationDidChange locator: Locator) {
        guard !isRestoring, let controller = navigator as? EPUBNavigatorViewController,
              controller.viewport != nil else { return }
        guard let context, let book, let publication, !chapters.isEmpty else { return }
        let id = book.id
        let index = publication.readingOrder.firstIndex { $0.href.components(separatedBy: "#")[0] == locator.href.string.components(separatedBy: "#")[0] } ?? 0
        let chapter = chapters[min(index, chapters.count - 1)]
        progress = min(1, max(0, locator.locations.totalProgression ?? Double(index) / Double(chapters.count)))
        locationTitle = locator.title ?? chapter.title
        controlsVisible = false
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
    func navigator(_ navigator: any ViewportObservingNavigator, viewportDidChange viewport: NavigatorViewport?) {
        guard isRestoring, viewport != nil, let controller = self.navigator,
              let current = controller.currentLocation else { return }
        isRestoring = false
        self.navigator(controller, locationDidChange: current)
    }

    func finish() {
        if let navigator, let locator = navigator.currentLocation { self.navigator(navigator, locationDidChange: locator) }
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
    }
    func navigator(_ navigator: EPUBNavigatorViewController, setupUserScripts userContentController: WKUserContentController) {
        userContentController.addUserScript(WKUserScript(source: EPUBReadingLayout.imageScript,
            injectionTime: .atDocumentStart, forMainFrameOnly: false))
    }
    func navigator(_ navigator: Navigator, presentError error: NavigatorError) { errorMessage = "暂时无法完成这个阅读操作，请重试。" }
    func navigator(_ navigator: Navigator, didFailToLoadResourceAt href: RelativeURL, withError error: ReadError) {
        errorMessage = "原书资源无法读取：\(href.string)。请检查原 EPUB 是否完整。"
    }

    func go(_ link: ReadiumShared.Link) { Task { _ = await navigator?.go(to: link) } }
    func go(index: Int, excerpt: String) {
        guard let publication, publication.readingOrder.indices.contains(index) else { return }
        let locator = Locator(href: publication.readingOrder[index].href, mediaType: .xhtml, text: .init(highlight: excerpt))
        Task { _ = await navigator?.go(to: locator) }
    }
    func bookmark() {
        guard let context, let book, let locator = navigator?.currentLocation, !chapters.isEmpty else { return }
        do {
            let index = publication?.readingOrder.firstIndex { $0.href == locator.href.string } ?? 0
            let mark = BookmarkRecord(book: book, chapter: chapters[min(index, chapters.count - 1)], locatorOffset: 0,
                chapterProgress: locator.locations.progression ?? 0, excerpt: locator.text.highlight ?? locationTitle)
            mark.publicationLocator = try locator.jsonString()
            context.insert(mark); try context.save(); bookmarkAdded = true
        } catch { errorMessage = "书签保存失败：\(error.localizedDescription)" }
    }
    func go(bookmark: BookmarkRecord) {
        let imported = publication.flatMap { publication -> Locator? in
            guard publication.readingOrder.indices.contains(bookmark.chapterIndex) else { return nil }
            return Locator(href: publication.readingOrder[bookmark.chapterIndex].href, mediaType: .xhtml,
                locations: .init(progression: bookmark.chapterProgress), text: .init(highlight: bookmark.excerpt.nilIfBlank))
        }
        guard let locator = bookmark.publicationLocator.flatMap({ try? Locator(jsonString: $0) }) ?? imported else { return }
        Task { _ = await navigator?.go(to: locator) }
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
    @State private var showingMenu = false
    @State private var showingToolbox = false
    @State private var menuSection = "主题与设置"
    @Query private var bookmarks: [BookmarkRecord]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var readingMode: ReaderMode {
        let selected = ReaderMode(rawValue: modeValue) ?? .pageCurl
        return reduceMotion && selected == .pageCurl ? .pageNone : selected
    }
    private var background: SwiftUI.Color {
        theme == "dark" ? .black : theme == "sepia" ? SwiftUI.Color(red: 250/255, green: 244/255, blue: 232/255) : .white
    }
    private var preferences: EPUBPreferences {
        EPUBReaderModel.preferences(publisherStyles: publisherStyles, fontSizePercent: fontSize, scroll: readingMode == .scroll,
                                    theme: theme, direction: EPUBTextDirection(rawValue: directionValue) ?? .publisher)
    }

    var body: some View {
        ZStack {
            background.ignoresSafeArea()
            if let navigator = model.navigator {
                EPUBPageCurlHost(navigator: navigator, mode: readingMode, paper: UIColor(background),
                    onTurn: { model.controlsVisible = false }, installTurnHandler: { model.requestTurn = $0 })
                    .ignoresSafeArea(edges: .bottom)
            }
            else if model.errorMessage == nil { ProgressView("正在展开原书精排…") }
            if model.isRestoring {
                background.ignoresSafeArea()
                ProgressView("正在恢复阅读位置…").accessibilityIdentifier("epub.restoring")
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
                        bookmark: { model.bookmark(); showingToolbox = false }, shareURL: try? LocalBookStorage.publicationURL(for: book.bookURL))
                }.padding(.horizontal, 24).padding(.bottom, 72) }
            }
        }
        .foregroundStyle(theme == "dark" ? SwiftUI.Color.white : SwiftUI.Color.black)
        .environment(\.colorScheme, theme == "dark" ? .dark : .light)
        .navigationBarBackButtonHidden().toolbar(.hidden, for: .navigationBar, .tabBar)
        .statusBarHidden(!model.controlsVisible)
        .accessibilityAction(named: "显示阅读菜单") { model.controlsVisible = true }
        .accessibilityAction(.escape) { model.close(); dismiss() }
        .task {
            if UserDefaults.standard.object(forKey: "epub.mode") == nil, legacyScroll { modeValue = ReaderMode.scroll.rawValue }
            model.readingMode = readingMode
            await model.open(book: book, chapters: chapters, context: context, preferences: preferences)
        }
        .task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(15)) } catch { break }
                model.tick(isActive: scenePhase == .active)
            }
        }
        .onDisappear { if showingMenu { model.finish() } else { model.close() } }
        .onChange(of: scenePhase) { _, phase in model.tick(isActive: phase == .active) }
        .onChange(of: publisherStyles) { _, _ in updatePreferences() }
        .onChange(of: fontSize) { _, _ in updatePreferences() }
        .onChange(of: modeValue) { _, _ in updatePreferences() }
        .onChange(of: directionValue) { _, _ in updatePreferences() }
        .onChange(of: reduceMotion) { _, _ in updatePreferences() }
        .onChange(of: theme) { _, _ in updatePreferences() }
        .onChange(of: model.controlsVisible) { _, visible in if !visible { showingToolbox = false } }
        .sheet(isPresented: $showingMenu) { menu.presentationDetents([.medium, .large]).presentationDragIndicator(.visible) }
        .alert("阅读提示", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            if model.navigator == nil {
                Button("重新打开") { Task { await model.open(book: book, chapters: chapters, context: context, preferences: preferences) } }
            } else {
                Button("继续阅读") { model.errorMessage = nil }
            }
            Button("返回书库", role: .cancel) { model.close(); dismiss() }
        } message: { Text(model.errorMessage ?? "") }
    }

    private func updatePreferences() { model.readingMode = readingMode; model.navigator?.submitPreferences(preferences) }
    private func openMenu(_ section: String) { menuSection = section; showingToolbox = false; showingMenu = true }
    private var menu: some View {
        NavigationStack {
          Group {
            if menuSection == "在图书中搜索" {
                EPUBTextSearchView(chapters: chapters) { index, excerpt in showingMenu = false; model.go(index: index, excerpt: excerpt) }
            } else {
            List {
              if menuSection == "主题与设置" {
                Section("主题与排版") {
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
                    Button(model.bookmarkAdded ? "书签已添加" : "添加书签", systemImage: "bookmark") { model.bookmark() }
                        .disabled(model.bookmarkAdded)
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

private struct EPUBTextSearchView: View {
    let chapters: [BookChapter]
    let select: (Int, String) -> Void
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
