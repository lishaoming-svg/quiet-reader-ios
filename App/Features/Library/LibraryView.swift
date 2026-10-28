import SwiftData
import SwiftUI

struct BookshelfView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject private var importer: BookImportCoordinator
    @Query(sort: \BookRecord.lastReadAt, order: .reverse) private var books: [BookRecord]
    @Query private var sources: [BookSourceRecord]
    @Query private var progresses: [ReadingProgressRecord]
    @AppStorage("library.grid.v2") private var grid = false
    @State private var searching = false
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
                    Text("书库").font(.largeTitle.bold())
                    Spacer()
                    sortMenu
                    optionsMenu
                }.padding(.top, 4).padding(.bottom, 2)
                if filter != .all { HStack {
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
                }.padding(.top, 6) }
                if visibleBooks.isEmpty {
                    libraryEmpty
                } else if grid && !dynamicTypeSize.isAccessibilitySize {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 100, maximum: 170), spacing: 22)], alignment: .leading, spacing: 30) {
                        ForEach(visibleBooks) { book in libraryItem(book, compact: false) }
                    }
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(visibleBooks) { book in
                            libraryItem(book, compact: true).padding(.vertical, 15)
                            Divider()
                        }
                    }
                }
            }.padding(.horizontal, 28).padding(.bottom, 32)
        }
        .background(AppTheme.paperLight)
        .navigationTitle("书库")
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $searching, onDismiss: { query = "" }) {
            NavigationStack {
                List(visibleBooks) { book in libraryItem(book, compact: true) }
                    .searchable(text: $query, prompt: "书名或作者")
                    .navigationTitle("搜索书库").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { searching = false } } }
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

    private var sortMenu: some View {
        Menu {
            Picker("排序", selection: $order) { ForEach(LibraryOrder.allCases) { Text($0.rawValue).tag($0) } }
            Button(grid ? "列表视图" : "网格视图", systemImage: grid ? "list.bullet" : "square.grid.3x3") { grid.toggle() }
            Picker("藏书集", selection: $filter) { ForEach(LibraryFilter.allCases) { Text($0.rawValue).tag($0) } }
        } label: { Image(systemName: grid ? "square.grid.2x2" : "line.3.horizontal.decrease").font(.title3.bold()).frame(width: 44, height: 44).background(.regularMaterial, in: Circle()).overlay { Circle().stroke(.quaternary, lineWidth: 0.5) } }
            .accessibilityLabel("排序与显示")
    }
    private var optionsMenu: some View {
        Menu {
            Button("导入图书", systemImage: "square.and.arrow.down") { importer.showingPicker = true }
                .accessibilityIdentifier("library.import")
            Button("搜索书库", systemImage: "magnifyingglass") { searching = true }
        } label: { Image(systemName: "ellipsis").font(.title3.bold()).frame(width: 44, height: 44).background(.regularMaterial, in: Circle()).overlay { Circle().stroke(.quaternary, lineWidth: 0.5) } }
            .accessibilityLabel("书库选项")
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
                Text("EPUB · TXT · DOCX · DOC\nMOBI · AZW · AZW3")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.top, 4)
            }
        }.frame(maxWidth: .infinity).padding(.vertical, 86)
    }

    private func libraryItem(_ book: BookRecord, compact: Bool) -> some View {
        HStack(spacing: 12) {
            LibraryBookLink(book: book, sources: sources) {
                LibraryBookCard(book: book, progress: progresses.first { $0.bookID == book.bookID }, compact: compact)
            }
            if compact {
                Menu {
                    Button("移除图书", systemImage: "trash", role: .destructive) { deleting = book }
                } label: { Image(systemName: "ellipsis").font(.headline).foregroundStyle(.secondary).frame(width: 44, height: 44) }
                    .accessibilityLabel("\(book.name)的选项")
            }
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
    var compactCoverHeight: CGFloat = 70
    var body: some View {
        Group {
            if compact {
                HStack(spacing: 18) {
                    BookCoverView(urlString: book.resolvedCoverURL, title: book.name, width: compactCoverHeight * 0.686, height: compactCoverHeight).accessibilityHidden(true)
                    details
                    Spacer(minLength: 0)
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
            Text(book.author.nilIfBlank ?? "未知作者")
                .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            if let progress {
                if let fraction = progress.bookProgress {
                    Text(fraction >= 0.995 ? "✓ 已读完" : "\(Int(fraction * 100))%")
                        .font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                } else { Text(progress.chapterTitle).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            } else {
                Text("新增").font(.caption.weight(.bold)).foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 2).background(Color(red: 0.04, green: 0.28, blue: 0.55), in: Capsule())
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ReadingHomeView: View {
    @EnvironmentObject private var importer: BookImportCoordinator
    @Query(sort: \BookRecord.lastReadAt, order: .reverse) private var books: [BookRecord]
    @Query private var sources: [BookSourceRecord]
    @Query private var progresses: [ReadingProgressRecord]
    @Query private var sessions: [ReadingSessionRecord]
    @AppStorage("reading.dailyGoal") private var goal = 5
    @State private var showingAccount = false
    @State private var showingGoal = false
    private var readingBooks: [BookRecord] { books.filter { book in progresses.contains { $0.bookID == book.bookID } } }
    private var secondsToday: Int {
        Int(sessions.filter { Calendar.current.isDateInToday($0.startedAt) }.reduce(0) { $0 + $1.activeSeconds })
    }
    private var fraction: Double { min(1, Double(secondsToday) / Double(max(1, goal) * 60)) }
    private var completed: [BookRecord] {
        books.filter { book in progresses.contains { $0.bookID == book.bookID && ($0.bookProgress ?? 0) >= 0.995 && Calendar.current.isDate($0.updatedAt, equalTo: .now, toGranularity: .year) } }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                homeHeader
                if readingBooks.isEmpty {
                    Label("你还没有正在阅读的图书。可将 EPUB、文档和其他本地内容添加到书库。", systemImage: "books.vertical")
                        .font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
                }
                if !books.isEmpty {
                    HStack(spacing: 6) {
                        Text(readingBooks.isEmpty ? "最近加入" : "之前读过").font(.title2.bold())
                        Image(systemName: "chevron.right").font(.title3.bold()).foregroundStyle(.tertiary)
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 16) {
                            ForEach((readingBooks.isEmpty ? books : readingBooks).prefix(8)) { book in
                                LibraryBookLink(book: book, sources: sources) {
                                    LibraryBookCard(book: book, progress: progresses.first { $0.bookID == book.bookID }, compact: true, compactCoverHeight: 58)
                                        .padding(12).frame(width: 260, alignment: .leading)
                                        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 12))
                                        .shadow(color: .black.opacity(0.09), radius: 14, y: 6)
                                }
                            }
                        }.padding(.vertical, 14).padding(.horizontal, 4)
                    }.padding(.top, -20)
                }
                VStack(spacing: 14) {
                    Text("阅读目标").font(.title2.bold())
                    Text("找一本好书，设定一个目标，养成每天阅读的习惯。")
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    ZStack(alignment: .bottom) {
                        GoalArc().stroke(Color(.secondarySystemBackground), style: StrokeStyle(lineWidth: 8, lineCap: .round))
                        GoalArc().trim(from: 0, to: fraction).stroke(Color.cyan, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                        VStack(spacing: 4) {
                            Text("今日阅读进度").font(.subheadline.bold())
                            Text("\(secondsToday / 60):\(String(format: "%02d", secondsToday % 60))")
                                .font(.system(size: 64, weight: .bold, design: .rounded)).monospacedDigit().minimumScaleFactor(0.6)
                            Button { showingGoal = true } label: {
                                Text("（目标 \(goal) 分钟） ›").font(.subheadline.weight(.medium)).frame(minHeight: 44)
                            }
                        }.offset(y: 18)
                    }.frame(height: 170).padding(.horizontal, 18).padding(.top, 22)
                    Button("导入图书") { importer.showingPicker = true }
                        .font(.headline).frame(maxWidth: .infinity, minHeight: 48)
                        .foregroundStyle(Color(.systemBackground)).background(Color.primary, in: Capsule())
                        .padding(.top, 12).accessibilityIdentifier("home.import")
                    HStack(spacing: 10) {
                        ForEach(0..<7) { offset in
                            let date = weekDate(offset)
                            let today = Calendar.current.isDateInToday(date)
                            let done = seconds(on: date) >= goal * 60
                            Text(["日", "一", "二", "三", "四", "五", "六"][Calendar.current.component(.weekday, from: date) - 1])
                                .font(.caption.bold()).frame(maxWidth: .infinity).frame(height: 32)
                                .background(done ? Color.cyan.opacity(0.2) : Color.clear, in: Circle())
                                .overlay { Circle().stroke(today ? Color.primary : Color(.systemGray4), lineWidth: today ? 2 : 1) }
                                .foregroundStyle(today || done ? Color.primary : Color.secondary)
                                .accessibilityLabel("\(date.formatted(date: .abbreviated, time: .omitted))，\(done ? "目标已完成" : "目标未完成")")
                        }
                    }.padding(.top, 16)
                    NavigationLink { ReadingHistoryView() } label: {
                        VStack(spacing: 4) {
                            Text("查看阅读记录 ›").font(.subheadline.weight(.medium))
                            Text("每一次翻页，都值得记录。").font(.subheadline).foregroundStyle(.secondary)
                        }.frame(minHeight: 50)
                    }
                    Divider().padding(.vertical, 12)
                    Text("今年读过的图书").font(.headline)
                    if completed.isEmpty {
                        Text("读完的图书会出现在这里。").font(.subheadline).foregroundStyle(.secondary).padding(.bottom, 20)
                    } else {
                        HStack(alignment: .bottom, spacing: 10) {
                            ForEach(completed.prefix(4)) { book in
                                LibraryBookLink(book: book, sources: sources) {
                                    BookCoverView(urlString: book.resolvedCoverURL, title: book.name, width: 60, height: 88)
                                }
                            }
                        }
                    }
                }.frame(maxWidth: .infinity).padding(.top, 10)
            }.padding(.horizontal, 28).padding(.top, 10).padding(.bottom, 32)
        }
        .background(AppTheme.paperLight).navigationTitle("主页")
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showingAccount) { LibrarySettingsView() }
        .sheet(isPresented: $showingGoal) {
            NavigationStack {
                Form { Stepper("每日阅读 \(goal) 分钟", value: $goal, in: 1...120) }
                    .navigationTitle("阅读目标").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showingGoal = false } } }
            }.presentationDetents([.medium])
        }
    }
    private var homeHeader: some View {
        HStack(spacing: 12) {
            Text("主页").font(.largeTitle.bold())
            Spacer()
            Button { showingGoal = true } label: {
                ZStack {
                    Circle().stroke(Color.cyan.opacity(0.2), lineWidth: 3)
                    Circle().trim(from: 0, to: fraction).stroke(Color.cyan, lineWidth: 3).rotationEffect(.degrees(-90))
                    Text("\(secondsToday / 60)").font(.caption.bold()).foregroundStyle(.cyan)
                }.frame(width: 30, height: 30).padding(7).background(.regularMaterial, in: Circle())
            }.accessibilityLabel("今天已阅读 \(secondsToday / 60) 分钟，目标 \(goal) 分钟")
            Button { showingAccount = true } label: {
                Image(systemName: "person.crop.circle").font(.system(size: 30)).frame(width: 44, height: 44).background(.regularMaterial, in: Circle())
            }.accessibilityLabel("阅读与设置")
        }.padding(.top, 4).padding(.bottom, 2)
    }
    private func weekDate(_ offset: Int) -> Date {
        let calendar = Calendar.current
        let weekday = calendar.component(.weekday, from: .now) - 1
        return calendar.date(byAdding: .day, value: offset - weekday, to: calendar.startOfDay(for: .now)) ?? .now
    }
    private func seconds(on date: Date) -> Int {
        Int(sessions.filter { Calendar.current.isDate($0.startedAt, inSameDayAs: date) }.reduce(0) { $0 + $1.activeSeconds })
    }
}

private struct GoalArc: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addArc(center: CGPoint(x: rect.midX, y: rect.maxY), radius: min(rect.width / 2, rect.height), startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
        return path
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
                    Text("支持 EPUB、TXT、DOCX、DOC、MOBI、AZW、AZW3。单文件上限 256 MB，Kindle 解析上限 64 MB。")
                    Text("EPUB 保留原书精排、插图、字体与 CSS。Word 提取正文和表格文字；Kindle 支持未加密 KF7 / KF8 的文字阅读。所有文件均在本机解析。")
                }.font(.subheadline)
                Section("开源许可") {
                    NavigationLink("Readium EPUB 阅读引擎许可") { LicenseTextView(filename: "Readium") }
                    NavigationLink("ZIPFoundation 许可") { LicenseTextView(filename: "ZIPFoundation") }
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
