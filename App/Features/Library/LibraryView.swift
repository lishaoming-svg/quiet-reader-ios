import SwiftData
import SwiftUI

struct BookshelfView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject private var importer: BookImportCoordinator
    @Query(sort: \BookRecord.lastReadAt, order: .reverse) private var books: [BookRecord]
    @Query private var sources: [BookSourceRecord]
    @Query private var progresses: [ReadingProgressRecord]
    @AppStorage("library.grid") private var grid = true
    @State private var filter = LibraryFilter.all
    @State private var order = LibraryOrder.recent
    @State private var query = ""
    @State private var deleting: BookRecord?
    @State private var errorMessage: String?

    private var visibleBooks: [BookRecord] {
        books.filter { book in
            (filter == .all || (filter == .local && book.isLocal) || (filter == .online && !book.isLocal))
                && (query.isEmpty || book.name.localizedStandardContains(query) || book.author.localizedStandardContains(query))
        }.sorted { left, right in
            switch order {
            case .recent: left.lastReadAt > right.lastReadAt
            case .added: left.addedAt > right.addedAt
            case .title: left.name.localizedStandardCompare(right.name) == .orderedAscending
            case .author: left.author.localizedStandardCompare(right.author) == .orderedAscending
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    Menu {
                        Picker("藏书集", selection: $filter) {
                            ForEach(LibraryFilter.allCases) { item in Text(item.rawValue).tag(item) }
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Text(filter.rawValue).font(.title2.bold())
                            Image(systemName: "chevron.down").font(.caption.bold())
                        }.foregroundStyle(.primary)
                    }
                    Spacer()
                    Text("\(visibleBooks.count) 本").font(.subheadline).foregroundStyle(.secondary)
                }.padding(.top, 6)
                if visibleBooks.isEmpty {
                    libraryEmpty
                } else if grid && !dynamicTypeSize.isAccessibilitySize {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 100, maximum: 170), spacing: 22)], alignment: .leading, spacing: 30) {
                        ForEach(visibleBooks) { book in libraryItem(book, compact: false) }
                    }
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(visibleBooks) { book in
                            libraryItem(book, compact: true).padding(.vertical, 14)
                            Divider().padding(.leading, 80)
                        }
                    }
                }
            }.padding(.horizontal, 24).padding(.bottom, 32)
        }
        .background(AppTheme.paperLight)
        .navigationTitle("书库")
        .searchable(text: $query, prompt: "书名或作者")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { importer.showingPicker = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("导入图书").accessibilityIdentifier("library.import")
                    .disabled(importer.isImporting)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("排序", selection: $order) {
                        ForEach(LibraryOrder.allCases) { item in Text(item.rawValue).tag(item) }
                    }
                    Button { grid.toggle() } label: {
                        Label(grid ? "列表视图" : "网格视图", systemImage: grid ? "list.bullet" : "square.grid.3x3")
                    }
                    Button("导入图书", systemImage: "square.and.arrow.down") { importer.showingPicker = true }
                } label: { Image(systemName: "ellipsis.circle") }
                .accessibilityLabel("书库选项")
            }
        }
        .confirmationDialog("从书库移除这本书？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("移除图书", role: .destructive) {
                if let deleting {
                    do { try LocalBookLibrary.remove(deleting, in: modelContext) }
                    catch { errorMessage = error.localizedDescription }
                }
                deleting = nil
            }
        } message: {
            Text(deleting?.isLocal == true ? "将删除本机副本、阅读位置和书签，原始文件保持不变。" : "图书将从书架移除。")
        }
        .alert("无法完成操作", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private var libraryEmpty: some View {
        VStack(spacing: 18) {
            Image(systemName: query.isEmpty ? "books.vertical" : "magnifyingglass")
                .font(.system(size: 52, weight: .ultraLight)).foregroundStyle(.tertiary)
            Text(query.isEmpty ? "你的书库，从这里开始" : "没有找到图书").font(.title3.bold())
            Text(query.isEmpty ? "把喜欢的文字带在身边。\n从“文件”导入，即可离线阅读。" : "试试其他书名或作者。")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if query.isEmpty {
                Button("导入图书") { importer.showingPicker = true }
                    .buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
                    .controlSize(.large).accessibilityIdentifier("library.emptyImport")
                Text("TXT · DOCX · DOC · MOBI · AZW · AZW3")
                    .font(.caption2).foregroundStyle(.tertiary).padding(.top, 4)
            }
        }.frame(maxWidth: .infinity).padding(.vertical, 86)
    }

    private func libraryItem(_ book: BookRecord, compact: Bool) -> some View {
        LibraryBookLink(book: book, sources: sources) {
            LibraryBookCard(book: book, progress: progresses.first { $0.bookID == book.bookID }, compact: compact)
        }.contextMenu {
            Button("移除图书", systemImage: "trash", role: .destructive) { deleting = book }
        }
    }
}

private enum LibraryFilter: String, Identifiable, CaseIterable {
    case all = "全部图书", local = "本地图书", online = "网络书籍"
    var id: String { rawValue }
}
private enum LibraryOrder: String, Identifiable, CaseIterable {
    case recent = "最近阅读", added = "最近加入", title = "书名", author = "作者"
    var id: String { rawValue }
}

struct LibraryBookLink<Content: View>: View {
    let book: BookRecord
    let sources: [BookSourceRecord]
    @ViewBuilder var content: () -> Content
    @Query private var lists: [ChapterListCacheRecord]
    @Query private var progresses: [ReadingProgressRecord]
    var body: some View {
        let source = book.isLocal ? LocalBookStorage.source : sources.first { $0.sourceID == book.sourceID }?.definition
        Group {
            if let source {
                NavigationLink {
                    let progress = progresses.first { $0.bookID == book.bookID }
                    BookshelfReaderDestination(book: book.searchBook, source: source,
                        cachedChapters: lists.first { $0.bookID == book.bookID }?.chapters ?? [],
                        resumeChapterURL: progress?.chapterURL, resumeChapterIndex: progress?.chapterIndex)
                } label: { content() }
            } else {
                VStack(alignment: .leading) {
                    content()
                    Text("请恢复原书源").font(.caption).foregroundStyle(.secondary)
                }
            }
        }.buttonStyle(.plain).accessibilityIdentifier("book.\(book.name)")
    }
}

struct LibraryBookCard: View {
    let book: BookRecord
    let progress: ReadingProgressRecord?
    var compact = false
    var body: some View {
        Group {
            if compact {
                HStack(spacing: 18) {
                    BookCoverView(urlString: book.resolvedCoverURL, title: book.name, width: 62, height: 90)
                    details
                    Spacer(minLength: 0)
                    Image(systemName: "ellipsis").foregroundStyle(.secondary)
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    GeometryReader { proxy in
                        BookCoverView(urlString: book.resolvedCoverURL, title: book.name,
                                      width: proxy.size.width, height: proxy.size.width * 1.48)
                    }.aspectRatio(1 / 1.48, contentMode: .fit)
                    details
                }
            }
        }.accessibilityElement(children: .combine)
    }
    private var details: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(book.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(2)
            Text(book.author.nilIfBlank ?? (book.isLocal ? "\(book.kind) 文档" : book.sourceName))
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            if let progress {
                Text(progress.chapterTitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            } else { Text("新加入").font(.caption2).foregroundStyle(AppTheme.vermilion) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ReadingHomeView: View {
    @EnvironmentObject private var importer: BookImportCoordinator
    @Query(sort: \BookRecord.lastReadAt, order: .reverse) private var books: [BookRecord]
    @Query private var sources: [BookSourceRecord]
    @Query private var progresses: [ReadingProgressRecord]
    @Query private var sessions: [ReadingSessionRecord]
    @State private var showingAccount = false
    private var readingBooks: [BookRecord] { books.filter { book in progresses.contains { $0.bookID == book.bookID } } }
    private var minutesToday: Int {
        Int(sessions.filter { Calendar.current.isDateInToday($0.startedAt) }.reduce(0) { $0 + $1.activeSeconds } / 60)
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                if readingBooks.isEmpty {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("翻开一本好书").font(.system(.largeTitle, design: .serif).weight(.bold))
                        Text("你的下一段旅程，就在书页之间。")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Button("导入你的第一本书", systemImage: "plus") { importer.showingPicker = true }
                            .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).controlSize(.large)
                    }.frame(maxWidth: .infinity, minHeight: 190, alignment: .leading)
                    .padding(24).background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
                } else {
                    Text("继续阅读").font(.title2.bold())
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 22) {
                            ForEach(readingBooks.prefix(8)) { book in
                                LibraryBookLink(book: book, sources: sources) {
                                    LibraryBookCard(book: book, progress: progresses.first { $0.bookID == book.bookID })
                                        .frame(width: 150)
                                }
                            }
                        }.padding(.bottom, 8)
                    }
                }
                Divider()
                if !books.isEmpty {
                    Text("最近加入").font(.title2.bold())
                    ForEach(books.sorted { $0.addedAt > $1.addedAt }.prefix(3)) { book in
                        LibraryBookLink(book: book, sources: sources) {
                            LibraryBookCard(book: book, progress: progresses.first { $0.bookID == book.bookID }, compact: true)
                        }
                    }
                    Divider()
                }
                NavigationLink { ReadingHistoryView() } label: {
                    HStack(spacing: 18) {
                        ZStack {
                            Circle().stroke(AppTheme.vermilion.opacity(0.15), lineWidth: 5)
                            Circle().trim(from: 0, to: min(Double(minutesToday) / 20, 1))
                                .stroke(AppTheme.vermilion, style: StrokeStyle(lineWidth: 5, lineCap: .round)).rotationEffect(.degrees(-90))
                            Image(systemName: "book.fill").foregroundStyle(AppTheme.vermilion)
                        }.frame(width: 52, height: 52)
                        VStack(alignment: .leading, spacing: 5) {
                            Text("阅读目标").font(.headline)
                            Text("今天已阅读 \(minutesToday) 分钟 · 目标 20 分钟").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                    }.foregroundStyle(.primary)
                }.buttonStyle(.plain)
            }.padding(24)
        }
        .background(AppTheme.paperLight)
        .navigationTitle("主页")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingAccount = true } label: { Image(systemName: "person.crop.circle").font(.title2) }
                    .accessibilityLabel("阅读与设置")
            }
        }
        .sheet(isPresented: $showingAccount) { LibrarySettingsView() }
    }
}

struct LibrarySettingsView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink { ReadingHistoryView() } label: { Label("阅读记录", systemImage: "clock") }
                    NavigationLink { SourceManagerView() } label: { Label("书源管理", systemImage: "network") }
                }
                Section("本地图书") {
                    Text("支持 TXT、DOCX、DOC、MOBI、AZW、AZW3，单文件不超过 64 MB。")
                    Text("文件在本机解析。Word 提取正文和表格文字，Kindle 文件支持未加密的 KF7 / KF8；复杂页面布局将转为适合阅读的文字排版。")
                }.font(.subheadline)
                Section("开源许可") {
                    NavigationLink("LGPL 3.0 许可全文") { LicenseTextView(filename: "LGPL-3.0") }
                    NavigationLink("GPL 3.0 许可全文") { LicenseTextView(filename: "GPL-3.0") }
                    Link("libmobi · LGPL 3.0 或更新版本", destination: URL(string: "https://github.com/bfabiszewski/libmobi")!)
                    Link("Kindle 解析组件源码与构建说明", destination: URL(string: "https://github.com/lishaoming-svg/quiet-reader-ios/tree/codex/apple-books-import/Packages/KindleDocumentKit")!)
                }
            }
            .navigationTitle("阅读与设置").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}

private struct LicenseTextView: View {
    let filename: String
    private var text: String {
        let url = Bundle.main.url(forResource: filename, withExtension: "txt", subdirectory: "ThirdPartyLicenses")
            ?? Bundle.main.url(forResource: filename, withExtension: "txt")
        return url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "请通过开源组件源码链接查看许可。"
    }
    var body: some View {
        ScrollView { Text(text).font(.system(.caption, design: .monospaced)).textSelection(.enabled).padding(20) }
            .navigationTitle(filename).navigationBarTitleDisplayMode(.inline)
    }
}
