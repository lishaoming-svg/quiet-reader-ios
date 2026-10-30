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
                        Text(book.name).font(.subheadline).lineLimit(1); Spacer()
                        Button("关闭", systemImage: "xmark") { tick(); save(); dismiss() }.labelStyle(.iconOnly).frame(width: 44, height: 44)
                    }.padding(12).background(.regularMaterial, in: Capsule())
                    Spacer()
                    HStack {
                        Text("\(page + 1) / \(document?.pageCount ?? 1)").monospacedDigit(); Spacer()
                        Button("笔记", systemImage: "note.text") { showingNotes = true }.labelStyle(.iconOnly).frame(width: 44, height: 44)
                        Button("逐行导读", systemImage: "line.3.horizontal") { lineGuide.toggle(); visible = false }
                            .labelStyle(.iconOnly).frame(width: 44, height: 44)
                        Toggle("上下滚动", isOn: $scroll).fixedSize()
                    }.padding(16).background(.regularMaterial, in: Capsule())
                }.padding(20)
            }
            if let error { ContentUnavailableView("无法打开 PDF", systemImage: "doc", description: Text(error)) }
        }
        .statusBarHidden(!visible).toolbar(.hidden, for: .navigationBar, .tabBar).navigationBarBackButtonHidden()
        .accessibilityAction(named: "显示阅读菜单") { visible = true }
        .accessibilityAction(.escape) { save(); dismiss() }
        .sheet(isPresented: $showingNotes) {
            BookmarkListView(bookID: book.id) { mark in
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
