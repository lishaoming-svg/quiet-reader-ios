import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct AudiobookView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @ObservedObject private var player = AudiobookPlayer.shared
    @AppStorage("audiobook.voice") private var selectedVoice = "multi-role"
    @AppStorage("audiobook.generationSpeed") private var generationSpeed = 1.0
    @AppStorage("audiobook.didMigrateMultiRoleDefault") private var didMigrateMultiRoleDefault = false

    let book: SearchBook
    let chapters: [BookChapter]
    let source: BookSourceDefinition
    let currentIndex: Int

    @State private var configuration = AudiobookCredentialsStore.load()
    @State private var health: AudiobookServerHealth?
    @State private var connectionError: String?
    @State private var showingPairing = false
    @State private var showingDeleteConfirmation = false
    @State private var showingPackageImporter = false
    @State private var isWorking = false
    @State private var workTask: Task<Void, Never>?
    @State private var completedCount = 0
    @State private var targetCount = 0
    @State private var currentTaskTitle = ""
    @State private var currentTaskProgress = 0.0
    @State private var workError: String?
    @State private var workMessage: String?
    @State private var remoteBookStatus: AudiobookBookStatus?
    @State private var downloadedCount = 0
    @State private var storageSize: Int64 = 0

    var body: some View {
        NavigationStack {
            Form {
                playerSection
                voiceSection
                generationSection
                connectionSection
                storageSection
            }
            .scrollContentBackground(.hidden)
            .background(PaperBackground())
            .navigationTitle("听书")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .task {
                refreshLocalState()
                if !didMigrateMultiRoleDefault {
                    selectedVoice = "multi-role"
                    didMigrateMultiRoleDefault = true
                }
                if configuration != nil {
                    await testConnection()
                } else if !currentChapterHasAudio {
                    showingPairing = true
                }
            }
            .onChange(of: selectedVoice) { oldVoice, newVoice in
                guard oldVoice != newVoice,
                      health?.voices.contains(where: { $0.id == newVoice }) == true else { return }
                workTask?.cancel()
                player.stop(bookID: book.id)
                Task { await refreshRemoteBookStatus() }
            }
            .onChange(of: generationSpeed) { oldSpeed, newSpeed in
                guard oldSpeed != newSpeed, health != nil else { return }
                workTask?.cancel()
                player.stop(bookID: book.id)
                Task { await refreshRemoteBookStatus() }
            }
            .sheet(isPresented: $showingPairing) {
                AudiobookPairingView { newConfiguration, newHealth in
                    configuration = newConfiguration
                    health = newHealth
                    selectedVoice = preferredVoice(in: newHealth.voices)
                    connectionError = nil
                    Task { await refreshRemoteBookStatus() }
                }
            }
            .confirmationDialog(
                "删除《\(book.name)》的全部听书音频？",
                isPresented: $showingDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("删除全部音频", role: .destructive) { deleteBookAudio() }
            }
            .fileImporter(
                isPresented: $showingPackageImporter,
                allowedContentTypes: [UTType("com.quietreader.readaloud-package") ?? .zip],
                allowsMultipleSelection: false
            ) { result in
                do {
                    guard let url = try result.get().first else { return }
                    importPackage(at: url)
                } catch {
                    workError = error.localizedDescription
                }
            }
        }
    }

    @ViewBuilder
    private var voiceSection: some View {
        Section("声音与角色") {
            if let health, !health.voices.isEmpty {
                Picker("朗读模式", selection: $selectedVoice) {
                    ForEach(health.voices) { voice in
                        Text(voice.name).tag(voice.id)
                    }
                }
                if selectedVoice == "multi-role" {
                    Text("自动识别引号内台词，并为旁白、主角、男性和女性角色分配不同表达。")
                        .font(.caption)
                        .foregroundStyle(AppTheme.inkSoft)
                }
            } else {
                LabeledContent("朗读模式", value: "连接生成器后可切换")
                    .foregroundStyle(AppTheme.inkSoft)
            }
            Picker("生成语速", selection: $generationSpeed) {
                ForEach([0.8, 1.0, 1.2], id: \.self) { speed in
                    Text("\(speed, specifier: "%g") 倍").tag(speed)
                }
            }
        }
    }

    @ViewBuilder
    private var playerSection: some View {
        Section("正在播放") {
            if player.currentBookID == book.id {
                Text(player.currentChapterTitle)
                    .font(.headline)
                    .foregroundStyle(AppTheme.ink)
                Slider(
                    value: Binding(
                        get: { player.duration > 0 ? player.elapsed / player.duration : 0 },
                        set: { player.seek(to: $0) }
                    ),
                    in: 0...1
                )
                .tint(AppTheme.vermilion)
                HStack {
                    Text(timeText(player.elapsed))
                    Spacer()
                    Text(timeText(player.duration))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(AppTheme.inkSoft)
                HStack {
                    Button { player.seek(by: -15) } label: {
                        Image(systemName: "gobackward.15")
                    }
                    Spacer()
                    Button { player.playPrevious() } label: {
                        Image(systemName: "backward.end.fill")
                    }
                    Spacer()
                    Button { player.togglePlayback() } label: {
                        Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 42))
                    }
                    Spacer()
                    Button { player.playNext() } label: {
                        Image(systemName: "forward.end.fill")
                    }
                    Spacer()
                    Button { player.seek(by: 15) } label: {
                        Image(systemName: "goforward.15")
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(AppTheme.vermilion)
                Picker("播放速度", selection: $player.playbackRate) {
                    ForEach([0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { rate in
                        Text("\(rate, specifier: "%g") 倍").tag(rate)
                    }
                }
                if player.isWaitingForNextChapter {
                    Label("本地缺少下一章音频，请同步最新伴读包", systemImage: "arrow.down.doc")
                        .font(.caption)
                        .foregroundStyle(AppTheme.inkSoft)
                }
                if let segment = player.currentSegment {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(segment.roleName)
                            .font(.caption.bold())
                            .foregroundStyle(AppTheme.vermilion)
                        Text(segment.text)
                            .font(.subheadline)
                            .foregroundStyle(AppTheme.ink)
                            .lineLimit(3)
                    }
                    .padding(.vertical, 4)
                }
            } else if currentChapterHasAudio {
                Button {
                    startPlayback()
                } label: {
                    Label("从本章开始播放", systemImage: "play.fill")
                }
            } else {
                ContentUnavailableView(
                    "本章还没有音频",
                    systemImage: "headphones",
                    description: Text("先在电脑生成整本伴读包，再同步到本机")
                )
            }
        }
    }

    @ViewBuilder
    private var generationSection: some View {
        Section("电脑预生成与同步") {
            if isWorking {
                ProgressView(
                    value: Double(completedCount) + currentTaskProgress,
                    total: Double(max(targetCount, 1))
                )
                .tint(AppTheme.vermilion)
                Text("正在处理 \(min(completedCount + 1, targetCount))/\(targetCount)：\(currentTaskTitle)")
                    .font(.caption)
                    .foregroundStyle(AppTheme.inkSoft)
                Button("取消本次传输", role: .destructive) { workTask?.cancel() }
            } else {
                Button {
                    cacheFullBookAndSubmit()
                } label: {
                    Label("缓存全书并提交电脑", systemImage: "books.vertical.fill")
                }
                .disabled(configuration == nil || readableChapters.isEmpty)

                if !cachedTargets.isEmpty {
                    Button {
                        startCachedChapterGeneration()
                    } label: {
                        Label(
                            "只提交已有缓存（\(cachedTargets.count) 章）",
                            systemImage: "desktopcomputer.and.arrow.down"
                        )
                    }
                    .disabled(configuration == nil)
                }

                if let remoteBookStatus {
                    LabeledContent(
                        "电脑生成进度",
                        value: "\(remoteBookStatus.completedCount)/\(remoteBookStatus.totalCount) 章"
                    )
                    if remoteBookStatus.runningCount + remoteBookStatus.queuedCount > 0 {
                        Text("电脑仍在生成 \(remoteBookStatus.runningCount + remoteBookStatus.queuedCount) 章，可以关闭手机页面。")
                            .font(.caption)
                            .foregroundStyle(AppTheme.inkSoft)
                    }
                    if remoteBookStatus.failedCount > 0 {
                        Text("有 \(remoteBookStatus.failedCount) 章生成失败，重新提交会自动重试。")
                            .font(.caption)
                            .foregroundStyle(AppTheme.vermilion)
                    }
                }

                Button("刷新电脑生成进度") {
                    Task { await refreshRemoteBookStatus() }
                }
                .disabled(health == nil)

                Button {
                    syncCompletedPackage()
                } label: {
                    Label("同步电脑已完成伴读包", systemImage: "arrow.down.doc.fill")
                }
                .disabled(
                    configuration == nil
                        || remoteBookStatus?.hasCompletedAudio != true
                )

                Button {
                    showingPackageImporter = true
                } label: {
                    Label("导入 .qraudio 伴读包", systemImage: "cable.connector")
                }

                Text("已缓存正文 \(cachedTargets.count)/\(readableChapters.count) 章。主按钮会自动补齐正文并一次提交全书任务，提交结束后电脑可以独立生成。")
                    .font(.caption)
                    .foregroundStyle(AppTheme.inkSoft)
                Text("数据线传输时，在 Windows Apple Devices 的“文件”中把 .qraudio 添加到墨阅，再从这里导入。")
                    .font(.caption)
                    .foregroundStyle(AppTheme.inkSoft)
            }

            if let workMessage {
                Label(workMessage, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(AppTheme.jade)
            }
            if let workError {
                InlineErrorView(message: workError)
            }
        }
    }

    private var connectionSection: some View {
        Section("Windows 生成器") {
            if let health {
                Label("已连接 · \(health.engineName)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(AppTheme.jade)
                if let configuration {
                    Text(configuration.baseURL.absoluteString)
                        .font(.caption.monospaced())
                        .foregroundStyle(AppTheme.inkSoft)
                }
            } else if let connectionError {
                InlineErrorView(message: connectionError)
            } else {
                Label("尚未连接", systemImage: "desktopcomputer.trianglebadge.exclamationmark")
                    .foregroundStyle(AppTheme.inkSoft)
            }
            Button {
                showingPairing = true
            } label: {
                Label(configuration == nil ? "连接电脑" : "更换或测试连接", systemImage: "qrcode.viewfinder")
            }
        }
    }

    private var storageSection: some View {
        Section("本地音频") {
            LabeledContent("已下载", value: "\(downloadedCount) 章")
            LabeledContent("占用空间", value: AudiobookStorage.formatByteCount(storageSize))
            if downloadedCount > 0 {
                Button("删除本书全部音频", role: .destructive) {
                    showingDeleteConfirmation = true
                }
            }
        }
    }

    private var currentChapterHasAudio: Bool {
        guard chapters.indices.contains(currentIndex) else { return false }
        return AudiobookStorage.hasAudio(
            bookID: book.id,
            chapterURL: chapters[currentIndex].url,
            matchingVoice: selectedVoice,
            matchingSpeed: generationSpeed
        )
    }

    private var cachedTargets: [(chapter: BookChapter, text: String)] {
        let bookID = book.id
        let descriptor = FetchDescriptor<ChapterCacheRecord>(
            predicate: #Predicate { $0.bookID == bookID }
        )
        let records = (try? modelContext.fetch(descriptor)) ?? []
        let contentByURL = Dictionary(uniqueKeysWithValues: records.map { ($0.chapterURL, $0.content) })
        return chapters.compactMap { chapter in
            guard let text = contentByURL[chapter.url]?.nilIfBlank else { return nil }
            return (chapter, text)
        }
    }

    private var readableChapters: [BookChapter] {
        chapters.filter { !$0.isVolume }
    }

    private func startCachedChapterGeneration() {
        submitCachedChapters()
    }

    private func cacheFullBookAndSubmit() {
        guard let configuration else { return }
        let targets = readableChapters
        guard !targets.isEmpty else { return }
        let generationVoice = selectedVoice
        let requestedSpeed = generationSpeed
        workTask?.cancel()
        workError = nil
        workMessage = nil
        completedCount = 0
        targetCount = targets.count
        currentTaskProgress = 0
        isWorking = true
        workTask = Task {
            defer { isWorking = false }
            let client = AudiobookServerClient(configuration: configuration)
            var cachedContent = cachedContentByURL()
            var submitted = 0
            var failed = 0
            do {
                for chapter in targets {
                    try Task.checkCancellation()
                    currentTaskTitle = "读取 \(chapter.title)"
                    let text: String
                    if let cached = cachedContent[chapter.url]?.nilIfBlank {
                        text = cached
                    } else {
                        do {
                            let loaded = try await SourceEngine().loadContent(
                                chapter: chapter,
                                source: source
                            )
                            let normalized = ReadableTextNormalizer.normalize(loaded)
                            guard let value = normalized.nilIfBlank else {
                                throw AudiobookClientError.generation("\(chapter.title) 没有可缓存的正文")
                            }
                            try saveChapterCache(chapter, content: value)
                            cachedContent[chapter.url] = value
                            text = value
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            failed += 1
                            completedCount += 1
                            continue
                        }
                    }

                    currentTaskTitle = "提交 \(chapter.title)"
                    let request = AudiobookJobRequest(
                        book: book,
                        chapter: chapter,
                        text: text,
                        voice: generationVoice,
                        speed: requestedSpeed
                    )
                    _ = try await client.submit(request)
                    submitted += 1
                    completedCount += 1
                }
                remoteBookStatus = try await client.bookStatus(
                    bookID: book.id,
                    voice: generationVoice,
                    speed: requestedSpeed
                )
                if failed == 0 {
                    workMessage = "全书 \(submitted) 章已交给电脑，可以离开听书页面。"
                } else {
                    workMessage = "已提交 \(submitted) 章，\(failed) 章正文下载失败；再次点击会继续补齐。"
                }
                refreshLocalState()
            } catch is CancellationError {
                workError = "全文缓存和提交已暂停，电脑会继续处理已经收到的章节。"
            } catch {
                workError = error.localizedDescription
            }
        }
    }

    private func submitCachedChapters() {
        guard let configuration else { return }
        let targets = cachedTargets
        guard !targets.isEmpty else { return }
        let generationVoice = selectedVoice
        let requestedSpeed = generationSpeed
        workTask?.cancel()
        workError = nil
        workMessage = nil
        completedCount = 0
        targetCount = targets.count
        currentTaskProgress = 0
        isWorking = true
        workTask = Task {
            defer { isWorking = false }
            let client = AudiobookServerClient(configuration: configuration)
            do {
                for target in targets {
                    try Task.checkCancellation()
                    currentTaskTitle = "提交 \(target.chapter.title)"
                    let request = AudiobookJobRequest(
                        book: book,
                        chapter: target.chapter,
                        text: target.text,
                        voice: generationVoice,
                        speed: requestedSpeed
                    )
                    _ = try await client.submit(request)
                    completedCount += 1
                    currentTaskProgress = 0
                }
                remoteBookStatus = try await client.bookStatus(
                    bookID: book.id,
                    voice: generationVoice,
                    speed: requestedSpeed
                )
                workMessage = "已把 \(targets.count) 章交给电脑，后续生成无需停留在手机页面。"
            } catch is CancellationError {
                workError = "章节提交已暂停，电脑会继续处理已经收到的任务。"
            } catch {
                workError = error.localizedDescription
            }
        }
    }

    private func cachedContentByURL() -> [String: String] {
        let bookID = book.id
        let descriptor = FetchDescriptor<ChapterCacheRecord>(
            predicate: #Predicate { $0.bookID == bookID }
        )
        let records = (try? modelContext.fetch(descriptor)) ?? []
        return Dictionary(uniqueKeysWithValues: records.map { ($0.chapterURL, $0.content) })
    }

    private func saveChapterCache(_ chapter: BookChapter, content: String) throws {
        let cacheKey = "\(source.id)::\(chapter.url)"
        let descriptor = FetchDescriptor<ChapterCacheRecord>(
            predicate: #Predicate { $0.cacheKey == cacheKey }
        )
        if let existing = try modelContext.fetch(descriptor).first {
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
        try modelContext.save()
    }

    private func syncCompletedPackage() {
        guard let configuration else { return }
        let generationVoice = selectedVoice
        let requestedSpeed = generationSpeed
        let temporary = FileManager.default.temporaryDirectory.appending(
            path: "\(UUID().uuidString).qraudio"
        )
        workTask?.cancel()
        workError = nil
        workMessage = nil
        completedCount = 0
        targetCount = max(remoteBookStatus?.completedCount ?? 1, 1)
        currentTaskTitle = "下载并校验整本伴读包"
        currentTaskProgress = 0
        isWorking = true
        workTask = Task {
            defer {
                isWorking = false
                try? FileManager.default.removeItem(at: temporary)
            }
            do {
                let client = AudiobookServerClient(configuration: configuration)
                try await client.downloadPackage(
                    bookID: book.id,
                    voice: generationVoice,
                    speed: requestedSpeed,
                    to: temporary
                )
                let result = try await Task.detached {
                    try AudiobookPackageImporter.importPackage(at: temporary, for: book)
                }.value
                completedCount = result.chapterCount
                refreshLocalState()
                player.extendQueue(
                    book: book,
                    chapters: chapters,
                    matchingVoice: generationVoice,
                    matchingSpeed: requestedSpeed
                )
                workMessage = "已同步《\(result.bookTitle)》\(result.chapterCount) 章，播放时会逐句高亮。"
                remoteBookStatus = try? await client.bookStatus(
                    bookID: book.id,
                    voice: generationVoice,
                    speed: requestedSpeed
                )
            } catch is CancellationError {
                workError = "伴读包同步已取消，可以稍后重新同步。"
            } catch {
                workError = error.localizedDescription
            }
        }
    }

    private func importPackage(at url: URL) {
        workTask?.cancel()
        workError = nil
        workMessage = nil
        completedCount = 0
        targetCount = 1
        currentTaskTitle = "校验并导入伴读包"
        isWorking = true
        workTask = Task {
            defer { isWorking = false }
            do {
                let result = try await Task.detached {
                    try AudiobookPackageImporter.importPackage(at: url, for: book)
                }.value
                selectedVoice = result.voice
                generationSpeed = result.generationSpeed
                completedCount = result.chapterCount
                refreshLocalState()
                player.extendQueue(
                    book: book,
                    chapters: chapters,
                    matchingVoice: result.voice,
                    matchingSpeed: result.generationSpeed
                )
                workMessage = "已导入《\(result.bookTitle)》\(result.chapterCount) 章，播放时会逐句高亮。"
            } catch {
                workError = error.localizedDescription
            }
        }
    }

    private func testConnection() async {
        guard let configuration else { return }
        do {
            let value = try await AudiobookServerClient(configuration: configuration).health()
            health = value
            connectionError = nil
            if !value.voices.contains(where: { $0.id == selectedVoice }) {
                selectedVoice = preferredVoice(in: value.voices)
            }
            await refreshRemoteBookStatus()
        } catch {
            health = nil
            remoteBookStatus = nil
            connectionError = error.localizedDescription
        }
    }

    private func preferredVoice(in voices: [AudiobookVoice]) -> String {
        voices.first(where: { $0.id == "multi-role" })?.id
            ?? voices.first?.id
            ?? "multi-role"
    }

    private func refreshRemoteBookStatus() async {
        guard let configuration, health != nil else {
            remoteBookStatus = nil
            return
        }
        remoteBookStatus = try? await AudiobookServerClient(
            configuration: configuration
        ).bookStatus(bookID: book.id, voice: selectedVoice, speed: generationSpeed)
    }

    private func startPlayback() {
        do {
            try player.play(
                book: book,
                chapters: chapters,
                startingAt: currentIndex,
                matchingVoice: selectedVoice,
                matchingSpeed: generationSpeed
            )
            workError = nil
        } catch {
            workError = error.localizedDescription
        }
    }

    private func deleteBookAudio() {
        player.stop(bookID: book.id)
        do {
            try AudiobookStorage.deleteBook(bookID: book.id)
            refreshLocalState()
        } catch {
            workError = error.localizedDescription
        }
    }

    private func refreshLocalState() {
        downloadedCount = AudiobookStorage.downloadedCount(bookID: book.id)
        storageSize = AudiobookStorage.storageSize(bookID: book.id)
    }

    private func timeText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00" }
        let total = Int(seconds)
        let hours = total / 3_600
        let minutes = total % 3_600 / 60
        let remainder = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainder)
        }
        return String(format: "%02d:%02d", minutes, remainder)
    }
}

private struct AudiobookPairingView: View {
    @Environment(\.dismiss) private var dismiss
    let onConnected: (AudiobookPairingConfiguration, AudiobookServerHealth) -> Void

    @State private var address = AudiobookCredentialsStore.load()?.baseURL.absoluteString ?? ""
    @State private var token = AudiobookCredentialsStore.load()?.token ?? ""
    @State private var isTesting = false
    @State private var errorMessage: String?
    @State private var showingScanner = false

    var body: some View {
        NavigationStack {
            Form {
                Section("扫码配对") {
                    Button {
                        showingScanner = true
                    } label: {
                        Label("扫描电脑上的二维码", systemImage: "qrcode.viewfinder")
                    }
                    Text("电脑启动生成器后，在浏览器打开终端显示的配对页面。")
                        .font(.caption)
                        .foregroundStyle(AppTheme.inkSoft)
                }
                Section("手工输入") {
                    TextField("例如 http://192.168.1.20:8765", text: $address)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    SecureField("配对码", text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                if let errorMessage {
                    InlineErrorView(message: errorMessage)
                }
                Section {
                    Button {
                        connect()
                    } label: {
                        HStack {
                            if isTesting { ProgressView() }
                            Text("测试并保存连接")
                        }
                    }
                    .disabled(isTesting)
                    if AudiobookCredentialsStore.load() != nil {
                        Button("清除已有连接", role: .destructive) {
                            AudiobookCredentialsStore.clear()
                            address = ""
                            token = ""
                        }
                    }
                }
            }
            .navigationTitle("连接电脑")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .sheet(isPresented: $showingScanner) {
                NavigationStack {
                    QRCodeScannerView { code in
                        guard let configuration = AudiobookPairingConfiguration(pairingCode: code) else {
                            errorMessage = "二维码内容无效"
                            return
                        }
                        address = configuration.baseURL.absoluteString
                        token = configuration.token
                        showingScanner = false
                        connect()
                    }
                    .ignoresSafeArea()
                    .navigationTitle("扫描配对二维码")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("取消") { showingScanner = false }
                        }
                    }
                }
            }
        }
    }

    private func connect() {
        guard let configuration = AudiobookPairingConfiguration(
            baseURLString: address,
            token: token
        ) else {
            errorMessage = "请检查电脑地址和配对码"
            return
        }
        isTesting = true
        errorMessage = nil
        Task {
            defer { isTesting = false }
            do {
                let health = try await AudiobookServerClient(configuration: configuration).health()
                try AudiobookCredentialsStore.save(configuration)
                onConnected(configuration, health)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
