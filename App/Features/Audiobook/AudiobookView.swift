import SwiftData
import SwiftUI

struct AudiobookView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @ObservedObject private var player = AudiobookPlayer.shared
    @ObservedObject private var coordinator = AudiobookGenerationCoordinator.shared
    @AppStorage("audiobook.voice") private var selectedVoice = "default"
    @AppStorage("audiobook.generationSpeed") private var generationSpeed = 1.0

    let book: SearchBook
    let chapters: [BookChapter]
    let source: BookSourceDefinition
    let currentIndex: Int
    let currentText: String

    @State private var configuration = AudiobookCredentialsStore.load()
    @State private var health: AudiobookServerHealth?
    @State private var connectionError: String?
    @State private var showingPairing = false
    @State private var showingDeleteConfirmation = false
    @State private var isWorking = false
    @State private var workTask: Task<Void, Never>?
    @State private var completedCount = 0
    @State private var targetCount = 0
    @State private var currentTaskTitle = ""
    @State private var currentTaskProgress = 0.0
    @State private var workError: String?
    @State private var downloadedCount = 0
    @State private var storageSize: Int64 = 0

    var body: some View {
        NavigationStack {
            Form {
                playerSection
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
                if currentChapterHasAudio {
                    beginAutomaticListening(allowComputer: false)
                }
                if configuration != nil {
                    await testConnection()
                    beginAutomaticListening(allowComputer: health != nil)
                } else {
                    if !currentChapterHasAudio {
                        beginAutomaticListening(allowComputer: false)
                        showingPairing = true
                    }
                }
            }
            .onDisappear { workTask?.cancel() }
            .onChange(of: coordinator.downloadedRevision) { _, _ in
                refreshLocalState()
            }
            .sheet(isPresented: $showingPairing) {
                AudiobookPairingView { newConfiguration, newHealth in
                    configuration = newConfiguration
                    health = newHealth
                    selectedVoice = newHealth.voices.first?.id ?? "default"
                    connectionError = nil
                    beginAutomaticListening(allowComputer: true)
                }
            }
            .confirmationDialog(
                "删除《\(book.name)》的全部听书音频？",
                isPresented: $showingDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("删除全部音频", role: .destructive) { deleteBookAudio() }
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
                    Label("下一章正在生成，完成后自动续播", systemImage: "hourglass")
                        .font(.caption)
                        .foregroundStyle(AppTheme.inkSoft)
                }
            } else if currentChapterHasAudio {
                Button {
                    startPlayback()
                } label: {
                    Label("从本章开始播放", systemImage: "play.fill")
                }
            } else if coordinator.activeBookID == book.id && coordinator.isWorking {
                ContentUnavailableView(
                    "正在生成本章",
                    systemImage: "waveform",
                    description: Text("生成完成后会自动开始播放")
                )
            } else {
                ContentUnavailableView(
                    "本章还没有音频",
                    systemImage: "headphones",
                    description: Text("连接电脑生成器后即可下载到本机")
                )
            }
        }
    }

    @ViewBuilder
    private var generationSection: some View {
        Section("一键连续听书") {
            if coordinator.activeBookID == book.id {
                if coordinator.isWorking {
                    ProgressView(value: coordinator.currentTaskProgress)
                        .tint(AppTheme.vermilion)
                    Text("正在处理：\(coordinator.currentTaskTitle)")
                        .font(.caption)
                        .foregroundStyle(AppTheme.inkSoft)
                }
                if !coordinator.statusMessage.isEmpty {
                    Text(coordinator.statusMessage)
                        .font(.caption)
                        .foregroundStyle(AppTheme.inkSoft)
                }
                LabeledContent("已提前准备", value: "后续 \(coordinator.preparedAheadCount) 章")
                if let error = coordinator.errorMessage {
                    InlineErrorView(message: error)
                    Button("重试自动听书") {
                        beginAutomaticListening(allowComputer: health != nil)
                    }
                }
                Button("停止自动预生成", role: .destructive) {
                    coordinator.cancelAutomaticGeneration()
                }
            } else {
                Button {
                    beginAutomaticListening(allowComputer: health != nil)
                } label: {
                    Label("开始一键听书", systemImage: "headphones")
                }
            }

            Text("播放时自动保持当前章之后 3 章已生成。关闭此面板后任务仍会继续。")
                .font(.caption)
                .foregroundStyle(AppTheme.inkSoft)
        }

        Section("手工生成") {
            if isWorking {
                ProgressView(
                    value: Double(completedCount) + currentTaskProgress,
                    total: Double(max(targetCount, 1))
                )
                .tint(AppTheme.vermilion)
                Text("正在处理 \(completedCount + 1)/\(targetCount)：\(currentTaskTitle)")
                    .font(.caption)
                    .foregroundStyle(AppTheme.inkSoft)
                Button("取消本次传输", role: .destructive) { workTask?.cancel() }
            } else {
                Button {
                    startCurrentChapterGeneration()
                } label: {
                    Label(
                        currentChapterHasAudio ? "重新生成本章" : "生成并下载本章",
                        systemImage: "waveform.badge.plus"
                    )
                }
                .disabled(
                    configuration == nil
                        || currentText.nilIfBlank == nil
                        || coordinator.isManaging(bookID: book.id)
                )

                Button {
                    startCachedChapterGeneration()
                } label: {
                    Label("生成已缓存章节", systemImage: "books.vertical")
                }
                .disabled(
                    configuration == nil
                        || cachedTargets.isEmpty
                        || coordinator.isManaging(bookID: book.id)
                )

                Text("已缓存正文 \(cachedTargets.count) 章。需要整本生成时，先在书籍详情中选择“缓存全书”。")
                    .font(.caption)
                    .foregroundStyle(AppTheme.inkSoft)
            }

            if let workError {
                InlineErrorView(message: workError)
            }
            if let health, !health.voices.isEmpty {
                Picker("生成音色", selection: $selectedVoice) {
                    ForEach(health.voices) { voice in
                        Text(voice.name).tag(voice.id)
                    }
                }
            }
            Picker("生成语速", selection: $generationSpeed) {
                ForEach([0.8, 1.0, 1.2], id: \.self) { speed in
                    Text("\(speed, specifier: "%g") 倍").tag(speed)
                }
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
        return AudiobookStorage.hasAudio(bookID: book.id, chapterURL: chapters[currentIndex].url)
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

    private func startCurrentChapterGeneration() {
        guard chapters.indices.contains(currentIndex) else { return }
        startGeneration([(chapters[currentIndex], currentText)])
    }

    private func startCachedChapterGeneration() {
        startGeneration(cachedTargets)
    }

    private func startGeneration(_ targets: [(chapter: BookChapter, text: String)]) {
        guard let configuration, !targets.isEmpty else { return }
        workTask?.cancel()
        workError = nil
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
                    currentTaskTitle = target.chapter.title
                    currentTaskProgress = 0
                    let request = AudiobookJobRequest(
                        book: book,
                        chapter: target.chapter,
                        text: target.text,
                        voice: selectedVoice,
                        speed: generationSpeed
                    )
                    var job = try await client.submit(request)
                    while !job.isFinished {
                        try Task.checkCancellation()
                        currentTaskProgress = job.progress
                        try await Task.sleep(for: .seconds(1))
                        job = try await client.status(jobID: job.jobID)
                    }
                    if job.status == "failed" {
                        throw AudiobookClientError.generation(job.error ?? "生成失败")
                    }
                    let destination = AudiobookStorage.chapterFileURL(
                        bookID: book.id,
                        chapterURL: target.chapter.url
                    )
                    try await client.download(jobID: job.jobID, to: destination)
                    try AudiobookStorage.saveChapter(
                        book: book,
                        chapter: target.chapter,
                        textSHA256: request.textSHA256,
                        voice: selectedVoice
                    )
                    player.extendQueue(book: book, chapters: chapters)
                    completedCount += 1
                    currentTaskProgress = 0
                    refreshLocalState()
                }
            } catch is CancellationError {
                workError = "本次传输已取消，电脑上已完成的任务会保留，重新提交时可直接复用。"
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
                selectedVoice = value.voices.first?.id ?? "default"
            }
        } catch {
            health = nil
            connectionError = error.localizedDescription
        }
    }

    private func startPlayback() {
        do {
            try player.play(book: book, chapters: chapters, startingAt: currentIndex)
            workError = nil
        } catch {
            workError = error.localizedDescription
        }
    }

    private func beginAutomaticListening(allowComputer: Bool) {
        coordinator.startAutomaticListening(
            book: book,
            chapters: chapters,
            source: source,
            currentIndex: currentIndex,
            currentText: currentText,
            modelContext: modelContext,
            configuration: allowComputer ? configuration : nil,
            voice: selectedVoice,
            generationSpeed: generationSpeed
        )
    }

    private func deleteBookAudio() {
        if coordinator.isManaging(bookID: book.id) {
            coordinator.cancelAutomaticGeneration()
        }
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
