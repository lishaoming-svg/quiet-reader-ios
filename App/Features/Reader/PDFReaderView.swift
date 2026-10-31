import PDFKit
import SwiftData
import SwiftUI

struct PDFReaderView: View {
    let book: SearchBook
    let chapters: [BookChapter]
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @State private var document: PDFDocument?
    @State private var visible = false
    @State private var showingNotes = false
    @State private var showingToolbox = false
    @State private var showingContents = false
    @State private var showingSearch = false
    @State private var showingSettings = false
    @State private var editingAnnotation: BookmarkRecord?
    @State private var pendingNote = false
    @State private var error: String?
    @State private var page = 0
    @State private var session: ReadingSessionRecord?
    @State private var lastTick = Date.now
    @State private var lastActivity = Date.now
    @State private var sessionWasActive = true
    @AppStorage("pdf.scroll") private var scroll = false
    @AppStorage("reader.lineGuideEnabled") private var lineGuide = false
    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            if let document {
                PDFCanvas(document: document, scroll: scroll, initialPage: page) { index in
                    page = index; lastActivity = .now; visible = false; save()
                }.simultaneousGesture(SpatialTapGesture().onEnded { event in
                    // PDF links retain their own interaction. A center tap reveals tools.
                    if event.location.x > 70 { visible.toggle(); lastActivity = .now }
                })
            } else if error == nil { ProgressView("正在打开 PDF…") }
            if lineGuide { ReaderLineGuide(paper: Color(.systemBackground), lineHeight: 28) }
            if visible {
                VStack {
                    HStack {
                        Spacer(minLength: 56)
                        Text(book.name).font(.subheadline.weight(.semibold)).lineLimit(1).padding(.horizontal, 16).padding(.vertical, 9).background(.regularMaterial, in: Capsule())
                        Spacer(minLength: 12)
                        Button("关闭图书", systemImage: "xmark") { tick(); save(); dismiss() }.labelStyle(.iconOnly).frame(width: 48, height: 48)
                            .background(.regularMaterial, in: Circle()).accessibilityIdentifier("reader.close")
                    }
                    Spacer()
                    HStack {
                        Spacer(minLength: 56)
                        Text("\(page + 1) / \(document?.pageCount ?? 1)").font(.subheadline.weight(.semibold)).monospacedDigit().padding(.horizontal, 14).padding(.vertical, 8).background(.regularMaterial, in: Capsule())
                        Spacer(minLength: 12)
                        Button("阅读菜单", systemImage: "line.3.horizontal.decrease") { showingToolbox.toggle() }.labelStyle(.iconOnly).frame(width: 48, height: 48)
                            .background(.regularMaterial, in: Circle()).accessibilityIdentifier("reader.menu")
                    }
                }.padding(.horizontal, 24).padding(.top, 4).padding(.bottom, 16)
            }
            if visible && showingToolbox {
                VStack { Spacer(); HStack { Spacer(minLength: 0)
                    ReaderToolbox(contents: { showingToolbox = false; showingContents = true },
                        search: { showingToolbox = false; showingSearch = true }, settings: { showingToolbox = false; showingSettings = true },
                        direction: {}, scroll: { scroll.toggle(); showingToolbox = false },
                        bookmark: { if let mark = makeNote() { context.insert(mark); try? context.save() }; showingToolbox = false },
                        shareURL: try? LocalBookStorage.pdfURL(for: book.bookURL),
                        lineGuide: { lineGuide.toggle(); visible = false; showingToolbox = false },
                        notes: { showingToolbox = false; showingNotes = true })
                }.padding(.horizontal, 24).padding(.bottom, 72) }
            }
            if let error { ContentUnavailableView("无法打开 PDF", systemImage: "doc", description: Text(error)) }
        }
        .statusBarHidden(!visible).toolbar(.hidden, for: .navigationBar, .tabBar).navigationBarBackButtonHidden()
        .accessibilityAction(named: "显示阅读菜单") { visible = true }
        .accessibilityAction(.escape) { save(); dismiss() }
        .onChange(of: visible) { _, value in if !value { showingToolbox = false } }
        .sheet(isPresented: $showingContents) {
            NativeReaderContentsView(chapters: chapters, currentIndex: page) { page = $0; showingContents = false }
        }
        .sheet(isPresented: $showingSettings) {
            NavigationStack {
                Form {
                    Section { Toggle("上下滚动", isOn: $scroll); Toggle("逐行导读", isOn: $lineGuide) }
                    Text("PDF 按原始页面显示，可双指缩放查看；字号和页面中的字体由原文件决定。").font(.footnote).foregroundStyle(.secondary)
                }.navigationTitle("主题与设置").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showingSettings = false } } }
            }
        }
        .sheet(isPresented: $showingSearch) {
            NavigationStack {
                EPUBTextSearchView(book: book, chapters: chapters, source: nil) { index, _ in page = index; showingSearch = false }
                    .navigationTitle("在图书中搜索").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showingSearch = false } } }
            }
        }
        .sheet(item: $editingAnnotation) { AnnotationEditorView(bookmark: $0) }
        .sheet(isPresented: $showingNotes, onDismiss: {
            if pendingNote { pendingNote = false; editingAnnotation = makeNote() }
        }) {
            BookmarkListView(bookID: book.id, addNote: { pendingNote = true; showingNotes = false }) { mark in
                page = min(max(0, mark.chapterIndex), max(0, (document?.pageCount ?? 1) - 1))
                showingNotes = false
            }
        }
        .task {
            do {
                let id = book.id
                let saved = try context.fetch(FetchDescriptor<ReadingProgressRecord>(predicate: #Predicate { $0.bookID == id })).first
                page = saved?.chapterIndex ?? 0
                guard let pdf = PDFDocument(url: try LocalBookStorage.pdfURL(for: book.bookURL)) else { throw LocalBookError.invalid }
                document = pdf
                let reading = ReadingSessionRecord(sessionID: UUID().uuidString, bookID: book.id, bookName: book.name, sourceID: book.sourceID)
                context.insert(reading); session = reading; try context.save()
            } catch { self.error = error.localizedDescription }
        }
        .task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(15)) } catch { break }
                tick()
            }
        }
        .onChange(of: phase) { _, _ in tick() }
        .onDisappear { tick(); save() }
    }
    private func makeNote() -> BookmarkRecord? {
        guard chapters.indices.contains(page) else { return nil }
        return BookmarkRecord(book: book, chapter: chapters[page], locatorOffset: 0, chapterProgress: 0,
            excerpt: String((document?.page(at: page)?.string ?? "").prefix(200)))
    }
    private func tick() {
        let now = Date.now
        if sessionWasActive, now.timeIntervalSince(lastActivity) <= 300 { session?.activeSeconds += min(30, max(0, now.timeIntervalSince(lastTick))) }
        sessionWasActive = phase == .active
        session?.endedAt = now; lastTick = now; try? context.save()
    }
    private func save() {
        guard !chapters.isEmpty else { return }
        let id = book.id, chapter = chapters[min(max(page, 0), chapters.count - 1)]
        do {
            let progress = try context.fetch(FetchDescriptor<ReadingProgressRecord>(predicate: #Predicate { $0.bookID == id })).first ?? ReadingProgressRecord(bookID: id, chapter: chapter)
            if progress.modelContext == nil { context.insert(progress) }
            progress.update(chapter: chapter, readingMode: "pdf")
            progress.bookProgress = Double(page + 1) / Double(max(1, chapters.count))
            if let record = try context.fetch(FetchDescriptor<BookRecord>(predicate: #Predicate { $0.bookID == id })).first { record.lastReadAt = .now }
            try context.save()
        } catch { self.error = "位置保存失败：" + error.localizedDescription }
    }
}
private struct PDFCanvas: UIViewRepresentable {
    let document: PDFDocument
    let scroll: Bool
    let initialPage: Int
    let changed: (Int) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(changed: changed) }
    func makeUIView(context: Context) -> PDFView {
        let view = PDFView(); view.document = document; view.autoScales = true
        view.displayBox = .cropBox; view.displaysAsBook = false
        configure(view)
        if let page = document.page(at: min(max(initialPage, 0), document.pageCount - 1)) { view.go(to: page) }
        context.coordinator.observe(view)
        return view
    }
    func updateUIView(_ view: PDFView, context: Context) {
        if view.displayMode != (scroll ? .singlePageContinuous : .singlePage) { configure(view) }
        if let target = document.page(at: initialPage), target !== view.currentPage { view.go(to: target) }
    }
    private func configure(_ view: PDFView) {
        view.usePageViewController(!scroll, withViewOptions: nil)
        view.displayMode = scroll ? .singlePageContinuous : .singlePage
        view.displayDirection = scroll ? .vertical : .horizontal
        view.autoScales = true
    }
    final class Coordinator: NSObject {
        let changed: (Int) -> Void
        init(changed: @escaping (Int) -> Void) { self.changed = changed }
        func observe(_ view: PDFView) { NotificationCenter.default.addObserver(self, selector: #selector(pageChanged(_:)), name: .PDFViewPageChanged, object: view) }
        @objc func pageChanged(_ notification: Notification) {
            guard let view = notification.object as? PDFView, let page = view.currentPage, let document = view.document else { return }
            changed(document.index(for: page))
        }
        deinit { NotificationCenter.default.removeObserver(self) }
    }
}
