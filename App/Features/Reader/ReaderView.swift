import SwiftData
import SwiftUI

struct ReaderView: View {
    @Environment(\.modelContext) private var modelContext
    @AppStorage("reader.fontSize") private var fontSize = 19.0
    @AppStorage("reader.lineSpacing") private var lineSpacing = 8.0
    @AppStorage("reader.paper") private var paperValue = ReaderPaper.warm.rawValue
    @AppStorage("reader.serif") private var usesSerif = true

    let book: SearchBook
    let chapters: [BookChapter]
    let source: BookSourceDefinition

    @State private var currentIndex: Int
    @State private var content = ""
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var showingSettings = false

    init(
        book: SearchBook,
        chapters: [BookChapter],
        initialIndex: Int,
        source: BookSourceDefinition
    ) {
        self.book = book
        self.chapters = chapters
        self.source = source
        _currentIndex = State(initialValue: initialIndex)
    }

    private var chapter: BookChapter { chapters[currentIndex] }
    private var paper: ReaderPaper { ReaderPaper(rawValue: paperValue) ?? .warm }

    var body: some View {
        ZStack {
            paper.background.ignoresSafeArea()
            if isLoading {
                VStack(spacing: 12) {
                    ProgressView().tint(AppTheme.vermilion)
                    Text("正在展开书页…").foregroundStyle(paper.secondaryText)
                }
            } else if let errorMessage {
                VStack(spacing: 16) {
                    InlineErrorView(message: errorMessage)
                    Button("重新加载") { Task { await loadChapter(forceRefresh: true) } }
                        .buttonStyle(.borderedProminent)
                        .tint(AppTheme.vermilion)
                }
                .padding(24)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        Text(chapter.title)
                            .font(.system(size: fontSize + 5, weight: .bold, design: .serif))
                            .foregroundStyle(paper.primaryText)
                        Rectangle()
                            .fill(AppTheme.vermilion)
                            .frame(width: 34, height: 2)
                        Text(content)
                            .font(.system(
                                size: fontSize,
                                weight: .regular,
                                design: usesSerif ? .serif : .default
                            ))
                            .foregroundStyle(paper.primaryText)
                            .lineSpacing(lineSpacing)
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: 720, alignment: .leading)
                    .padding(.horizontal, 22)
                    .padding(.top, 26)
                    .padding(.bottom, 90)
                }
                .id(chapter.url)
            }
        }
        .navigationTitle(book.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(paper.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    ForEach(chapters) { item in
                        Button(item.title) { currentIndex = item.index }
                    }
                } label: {
                    Image(systemName: "list.bullet")
                }
                Button {
                    showingSettings = true
                } label: {
                    Image(systemName: "textformat.size")
                }
            }
        }
        .safeAreaInset(edge: .bottom) { navigationBar }
        .sheet(isPresented: $showingSettings) { ReaderSettingsView() }
        .task(id: currentIndex) { await loadChapter() }
    }

    private var navigationBar: some View {
        HStack {
            Button {
                currentIndex -= 1
            } label: {
                Label("上一章", systemImage: "chevron.left")
            }
            .disabled(currentIndex == 0)
            Spacer()
            Text("\(currentIndex + 1) / \(chapters.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(paper.secondaryText)
            Spacer()
            Button {
                currentIndex += 1
            } label: {
                Label("下一章", systemImage: "chevron.right")
                    .labelStyle(.titleAndIcon)
            }
            .disabled(currentIndex >= chapters.count - 1)
        }
        .font(.subheadline.bold())
        .foregroundStyle(paper.primaryText)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }

    private func loadChapter(forceRefresh: Bool = false) async {
        isLoading = true
        errorMessage = nil
        let currentChapter = chapter

        if !forceRefresh, let cached = cachedChapter(url: currentChapter.url) {
            content = cached.content
            saveProgress(currentChapter)
            isLoading = false
            return
        }

        do {
            let value = try await SourceEngine().loadContent(
                chapter: currentChapter,
                source: source
            )
            content = value
            cache(currentChapter, content: value)
            saveProgress(currentChapter)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
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

    private func saveProgress(_ chapter: BookChapter) {
        let bookID = book.id
        let descriptor = FetchDescriptor<ReadingProgressRecord>(
            predicate: #Predicate { $0.bookID == bookID }
        )
        if let progress = try? modelContext.fetch(descriptor).first {
            progress.update(chapter: chapter)
        } else {
            modelContext.insert(ReadingProgressRecord(bookID: bookID, chapter: chapter))
        }

        let bookDescriptor = FetchDescriptor<BookRecord>(
            predicate: #Predicate { $0.bookID == bookID }
        )
        if let storedBook = try? modelContext.fetch(bookDescriptor).first {
            storedBook.lastReadAt = .now
        }
        try? modelContext.save()
    }
}

private struct ReaderSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("reader.fontSize") private var fontSize = 19.0
    @AppStorage("reader.lineSpacing") private var lineSpacing = 8.0
    @AppStorage("reader.paper") private var paperValue = ReaderPaper.warm.rawValue
    @AppStorage("reader.serif") private var usesSerif = true

    var body: some View {
        NavigationStack {
            Form {
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

    var id: String { rawValue }
    var title: String {
        switch self {
        case .warm: "暖纸"
        case .white: "净白"
        case .green: "青笺"
        }
    }
    var background: Color {
        switch self {
        case .warm: AppTheme.paper
        case .white: Color(red: 0.98, green: 0.98, blue: 0.97)
        case .green: Color(red: 0.87, green: 0.92, blue: 0.86)
        }
    }
    var primaryText: Color { AppTheme.ink }
    var secondaryText: Color { AppTheme.inkSoft }
}
