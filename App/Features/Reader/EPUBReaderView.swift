import ReadiumNavigator
import ReadiumShared
import ReadiumStreamer
import SwiftData
import SwiftUI

@MainActor
final class EPUBReaderModel: NSObject, ObservableObject, EPUBNavigatorDelegate {
    @Published var navigator: EPUBNavigatorViewController?
    @Published var errorMessage: String?
    @Published var controlsVisible = true
    @Published var progress = 0.0
    @Published var locationTitle = ""
    @Published var bookmarkAdded = false
    @Published var tocLinks: [ReadiumShared.Link] = []
    @Published var isRestoring = false
    private(set) var publication: Publication?
    private var navigationAdapter: DirectionalNavigationAdapter?
    private var tapToken: InputObservableToken?
    private var context: ModelContext?
    private var book: SearchBook?
    private var chapters: [BookChapter] = []
    private var session: ReadingSessionRecord?
    private var lastTick = Date.now
    private var lastActivity = Date.now
    private var active = true

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
            let locator = saved?.publicationLocator.flatMap { try? Locator(jsonString: $0) }
            isRestoring = locator != nil
            var config = EPUBNavigatorViewController.Configuration(preferences: preferences)
            config.contentInset = [.compact: (top: 80, bottom: 72), .regular: (top: 80, bottom: 72)]
            // Each opening owns a fresh controller. Let Readium lay out the saved
            // resource directly instead of jumping while its first spread loads.
            let navigator = try EPUBNavigatorViewController(publication: publication, initialLocation: locator, config: config)
            navigator.delegate = self
            let adapter = DirectionalNavigationAdapter(animatedTransition: true) { [weak self] in self?.lastActivity = .now }
            adapter.bind(to: navigator)
            // Readium handles links, text selection and edge taps before this center-tap observer.
            tapToken = navigator.addObserver(.tap { [weak self] _ in
                self?.controlsVisible.toggle(); self?.lastActivity = .now; return true
            })
            navigationAdapter = adapter
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
        navigationAdapter = nil
        navigator = nil
        publication = nil
        isRestoring = false
    }
    func navigator(_ navigator: Navigator, presentError error: NavigatorError) { errorMessage = "暂时无法完成这个阅读操作，请重试。" }
    func navigator(_ navigator: Navigator, didFailToLoadResourceAt href: RelativeURL, withError error: ReadError) {
        errorMessage = "原书资源无法读取：\(href.string)。请检查原 EPUB 是否完整。"
    }

    func go(_ link: ReadiumShared.Link) { Task { _ = await navigator?.go(to: link) } }
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
        guard let json = bookmark.publicationLocator, let locator = try? Locator(jsonString: json) else { return }
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
    @AppStorage("epub.scroll") private var scroll = false
    @AppStorage("epub.theme") private var theme = "sepia"
    @State private var showingMenu = false
    @Query private var bookmarks: [BookmarkRecord]
    private var background: SwiftUI.Color {
        theme == "dark" ? .black : theme == "sepia" ? SwiftUI.Color(red: 250/255, green: 244/255, blue: 232/255) : .white
    }
    private var preferences: EPUBPreferences {
        var prefs = EPUBPreferences()
        prefs.publisherStyles = publisherStyles; prefs.fontSize = fontSize
        prefs.scroll = scroll; prefs.theme = Theme(rawValue: theme) ?? .sepia
        return prefs
    }

    var body: some View {
        ZStack {
            background.ignoresSafeArea()
            if let navigator = model.navigator { EPUBNavigatorHost(navigator: navigator).ignoresSafeArea(edges: .bottom) }
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
                        Button { showingMenu = true } label: { Image(systemName: "line.3.horizontal.decrease").font(.title2.bold()).frame(width: 48, height: 48) }
                            .background(.regularMaterial, in: Circle()).accessibilityLabel("阅读菜单").accessibilityIdentifier("reader.menu")
                            .disabled(model.isRestoring)
                    }
                }.padding(.horizontal, 24).padding(.top, 4).padding(.bottom, 16)
            }
        }
        .foregroundStyle(theme == "dark" ? SwiftUI.Color.white : SwiftUI.Color.black)
        .environment(\.colorScheme, theme == "dark" ? .dark : .light)
        .navigationBarBackButtonHidden().toolbar(.hidden, for: .navigationBar, .tabBar)
        .accessibilityAction(named: "显示阅读菜单") { model.controlsVisible = true }
        .accessibilityAction(.escape) { model.close(); dismiss() }
        .task { await model.open(book: book, chapters: chapters, context: context, preferences: preferences) }
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
        .onChange(of: scroll) { _, _ in updatePreferences() }
        .onChange(of: theme) { _, _ in updatePreferences() }
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

    private func updatePreferences() { model.navigator?.submitPreferences(preferences) }
    private var menu: some View {
        NavigationStack {
            List {
                Section("主题与排版") {
                    Toggle("原书精排", isOn: $publisherStyles).accessibilityIdentifier("epub.publisherStyles")
                    Text("保留原书插图、字体、标题装饰、注音和 CSS。关闭后可统一正文字号；固定版式遵循原书布局。")
                        .font(.footnote).foregroundStyle(.secondary)
                    if !publisherStyles { Slider(value: $fontSize, in: 75...200, step: 5) { Text("字号") } }
                    Picker("纸张", selection: $theme) { Text("白色").tag("light"); Text("暖色").tag("sepia"); Text("夜间").tag("dark") }
                    Toggle("连续滚动", isOn: $scroll)
                    Button(model.bookmarkAdded ? "书签已添加" : "添加书签", systemImage: "bookmark") { model.bookmark() }
                        .disabled(model.bookmarkAdded)
                }
                if !model.tocLinks.isEmpty {
                    Section("目录") { toc(model.tocLinks, depth: 0) }
                }
                let marks = bookmarks.filter { $0.bookID == book.id && $0.publicationLocator != nil }
                if !marks.isEmpty {
                    Section("书签") {
                        ForEach(marks) { mark in
                            Button { showingMenu = false; model.go(bookmark: mark) } label: { Text(mark.chapterTitle).lineLimit(2) }
                                .contextMenu { Button("删除书签", role: .destructive) { context.delete(mark); try? context.save() } }
                        }
                    }
                }
            }
            .navigationTitle("阅读菜单").navigationBarTitleDisplayMode(.inline)
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

private struct EPUBNavigatorHost: UIViewControllerRepresentable {
    let navigator: EPUBNavigatorViewController
    func makeUIViewController(context: Context) -> EPUBNavigatorViewController { navigator }
    func updateUIViewController(_ controller: EPUBNavigatorViewController, context: Context) {}
}
