import Combine
import Foundation
import SwiftData

@MainActor
final class AudiobookGenerationCoordinator: ObservableObject {
    static let shared = AudiobookGenerationCoordinator()

    @Published private(set) var activeBookID: String?
    @Published private(set) var isWorking = false
    @Published private(set) var currentTaskTitle = ""
    @Published private(set) var currentTaskProgress = 0.0
    @Published private(set) var completedCount = 0
    @Published private(set) var targetCount = 0
    @Published private(set) var preparedAheadCount = 0
    @Published private(set) var statusMessage = ""
    @Published private(set) var errorMessage: String?
    @Published private(set) var downloadedRevision = 0

    private struct Plan {
        let book: SearchBook
        let chapters: [BookChapter]
        let source: BookSourceDefinition
        let modelContext: ModelContext
        let configuration: AudiobookPairingConfiguration?
        let voice: String
        let generationSpeed: Double
        let playbackStartIndex: Int
        var seedTextByURL: [String: String]
    }

    private let player = AudiobookPlayer.shared
    private var plan: Plan?
    private var desiredIndices: Set<Int> = []
    private var autoplayPending = false
    private var workerTask: Task<Void, Never>?
    private var workerID: UUID?
    private var cancellables: Set<AnyCancellable> = []

    private init() {
        player.$currentChapterIndex
            .removeDuplicates()
            .sink { [weak self] index in
                Task { @MainActor [weak self] in
                    self?.playbackDidMove(to: index)
                }
            }
            .store(in: &cancellables)
    }

    func startAutomaticListening(
        book: SearchBook,
        chapters: [BookChapter],
        source: BookSourceDefinition,
        currentIndex: Int,
        currentText: String,
        modelContext: ModelContext,
        configuration: AudiobookPairingConfiguration?,
        voice: String,
        generationSpeed: Double
    ) {
        let initialTargets = AudiobookQueuePlanner.targetIndices(
            chapters: chapters,
            currentIndex: currentIndex
        )
        guard let playbackStartIndex = initialTargets.first else {
            errorMessage = "目录中没有可听的正文章节"
            statusMessage = "自动听书无法启动"
            return
        }

        let replacingPlan = plan?.book.id != book.id
            || plan?.source.id != source.id
            || plan?.playbackStartIndex != playbackStartIndex
            || plan?.voice != voice
            || plan?.generationSpeed != generationSpeed
        if replacingPlan {
            stopWorker()
            desiredIndices.removeAll()
        }

        var seeds = replacingPlan ? [:] : (plan?.seedTextByURL ?? [:])
        if chapters.indices.contains(currentIndex),
           let normalized = currentText.nilIfBlank.map(AudiobookTextNormalizer.normalize),
           !normalized.isEmpty {
            seeds[chapters[currentIndex].url] = normalized
        }
        plan = Plan(
            book: book,
            chapters: chapters,
            source: source,
            modelContext: modelContext,
            configuration: configuration,
            voice: voice,
            generationSpeed: generationSpeed,
            playbackStartIndex: playbackStartIndex,
            seedTextByURL: seeds
        )
        activeBookID = book.id
        errorMessage = nil
        desiredIndices.formUnion(initialTargets)
        refreshQueueState()

        let startChapter = chapters[playbackStartIndex]
        if AudiobookStorage.hasAudio(
            bookID: book.id,
            chapterURL: startChapter.url,
            matchingVoice: voice,
            matchingSpeed: generationSpeed
        ) {
            if player.currentBookID == book.id,
               player.currentChapterIndex == playbackStartIndex {
                player.extendQueue(
                    book: book,
                    chapters: chapters,
                    matchingVoice: voice,
                    matchingSpeed: generationSpeed
                )
            } else {
                do {
                    try player.play(
                        book: book,
                        chapters: chapters,
                        startingAt: playbackStartIndex,
                        matchingVoice: voice,
                        matchingSpeed: generationSpeed
                    )
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
            autoplayPending = false
        } else {
            autoplayPending = true
        }

        guard configuration != nil else {
            if autoplayPending {
                errorMessage = "请先连接电脑听书生成器"
                statusMessage = "等待连接电脑"
            } else {
                statusMessage = "正在播放本地音频，连接电脑后可自动准备后续章节"
            }
            return
        }
        launchWorkerIfNeeded()
    }

    func cancelAutomaticGeneration() {
        stopWorker()
        plan = nil
        desiredIndices.removeAll()
        activeBookID = nil
        autoplayPending = false
        isWorking = false
        currentTaskProgress = 0
        preparedAheadCount = 0
        statusMessage = "自动预生成已停止，当前音频仍可继续播放"
    }

    func isManaging(bookID: String) -> Bool {
        activeBookID == bookID && plan != nil
    }

    private func playbackDidMove(to index: Int?) {
        guard let index,
              let plan,
              player.currentBookID == plan.book.id else { return }
        desiredIndices.formUnion(
            AudiobookQueuePlanner.targetIndices(
                chapters: plan.chapters,
                currentIndex: index
            )
        )
        refreshQueueState()
        launchWorkerIfNeeded()
    }

    private func launchWorkerIfNeeded() {
        guard workerTask == nil,
              let plan,
              plan.configuration != nil,
              nextMissingIndex(in: plan) != nil else {
            refreshQueueState()
            return
        }
        let identifier = UUID()
        workerID = identifier
        isWorking = true
        workerTask = Task { [weak self] in
            await self?.runWorker(identifier: identifier)
        }
    }

    private func runWorker(identifier: UUID) async {
        defer { finishWorker(identifier: identifier) }
        do {
            while !Task.isCancelled {
                guard let plan,
                      let configuration = plan.configuration,
                      let index = nextMissingIndex(in: plan) else {
                    refreshQueueState()
                    return
                }
                let chapter = plan.chapters[index]
                currentTaskTitle = chapter.title
                currentTaskProgress = 0
                statusMessage = index == plan.playbackStartIndex
                    ? "正在生成本章，完成后自动播放"
                    : "正在提前生成：\(chapter.title)"

                let text = try await narrationText(for: chapter, in: plan)
                try Task.checkCancellation()
                let request = AudiobookJobRequest(
                    book: plan.book,
                    chapter: chapter,
                    text: text,
                    voice: plan.voice,
                    speed: plan.generationSpeed
                )
                let client = AudiobookServerClient(configuration: configuration)
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
                    bookID: plan.book.id,
                    chapterURL: chapter.url
                )
                try await client.download(jobID: job.jobID, to: destination)
                try AudiobookStorage.saveChapter(
                    book: plan.book,
                    chapter: chapter,
                    textSHA256: request.textSHA256,
                    voice: plan.voice,
                    generationSpeed: plan.generationSpeed,
                    segments: job.segments ?? []
                )
                downloadedRevision += 1
                currentTaskProgress = 1
                player.extendQueue(
                    book: plan.book,
                    chapters: plan.chapters,
                    matchingVoice: plan.voice,
                    matchingSpeed: plan.generationSpeed
                )
                startPlaybackIfPending(plan: plan)
                refreshQueueState()
            }
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = "自动生成已暂停，可点击重试"
        }
    }

    private func narrationText(for chapter: BookChapter, in plan: Plan) async throws -> String {
        if let seed = plan.seedTextByURL[chapter.url]?.nilIfBlank {
            return seed
        }

        let cacheKey = "\(plan.source.id)::\(chapter.url)"
        let descriptor = FetchDescriptor<ChapterCacheRecord>(
            predicate: #Predicate { $0.cacheKey == cacheKey }
        )
        if let cached = try? plan.modelContext.fetch(descriptor).first {
            let requiresRefresh = SourceEngine.authenticationMessage(in: cached.content) != nil
                || ReadableContentFormatter.shouldRefreshLegacyCache(
                    cached.content,
                    sourceID: plan.source.id
                )
            if !requiresRefresh,
               let normalized = ReadableTextNormalizer.normalize(cached.content).nilIfBlank {
                return normalized
            }
            plan.modelContext.delete(cached)
            try? plan.modelContext.save()
        }

        statusMessage = "正在读取正文：\(chapter.title)"
        let loaded = try await SourceEngine().loadContent(chapter: chapter, source: plan.source)
        try Task.checkCancellation()
        guard let normalized = ReadableTextNormalizer.normalize(loaded).nilIfBlank else {
            throw AudiobookClientError.generation("\(chapter.title) 没有可生成的正文")
        }
        plan.modelContext.insert(
            ChapterCacheRecord(
                sourceID: plan.source.id,
                bookID: plan.book.id,
                chapter: chapter,
                content: normalized
            )
        )
        try plan.modelContext.save()
        return normalized
    }

    private func startPlaybackIfPending(plan: Plan) {
        guard autoplayPending else { return }
        let chapter = plan.chapters[plan.playbackStartIndex]
        guard AudiobookStorage.hasAudio(
            bookID: plan.book.id,
            chapterURL: chapter.url,
            matchingVoice: plan.voice,
            matchingSpeed: plan.generationSpeed
        ) else {
            return
        }
        do {
            try player.play(
                book: plan.book,
                chapters: plan.chapters,
                startingAt: plan.playbackStartIndex,
                matchingVoice: plan.voice,
                matchingSpeed: plan.generationSpeed
            )
            autoplayPending = false
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func nextMissingIndex(in plan: Plan) -> Int? {
        desiredIndices.sorted().first { index in
            plan.chapters.indices.contains(index)
                && !plan.chapters[index].isVolume
                && !AudiobookStorage.hasAudio(
                    bookID: plan.book.id,
                    chapterURL: plan.chapters[index].url,
                    matchingVoice: plan.voice,
                    matchingSpeed: plan.generationSpeed
                )
        }
    }

    private func refreshQueueState() {
        guard let plan else { return }
        completedCount = desiredIndices.filter { index in
            plan.chapters.indices.contains(index)
                && AudiobookStorage.hasAudio(
                    bookID: plan.book.id,
                    chapterURL: plan.chapters[index].url,
                    matchingVoice: plan.voice,
                    matchingSpeed: plan.generationSpeed
                )
        }.count
        targetCount = desiredIndices.count

        let current = player.currentBookID == plan.book.id
            ? (player.currentChapterIndex ?? plan.playbackStartIndex)
            : plan.playbackStartIndex
        let upcoming = AudiobookQueuePlanner.targetIndices(
            chapters: plan.chapters,
            currentIndex: current
        ).dropFirst()
        preparedAheadCount = upcoming.prefix { index in
            AudiobookStorage.hasAudio(
                bookID: plan.book.id,
                chapterURL: plan.chapters[index].url,
                matchingVoice: plan.voice,
                matchingSpeed: plan.generationSpeed
            )
        }.count
        if nextMissingIndex(in: plan) == nil, !isWorking {
            statusMessage = "已准备当前章和后续 \(preparedAheadCount) 章"
        }
    }

    private func finishWorker(identifier: UUID) {
        guard workerID == identifier else { return }
        workerID = nil
        workerTask = nil
        isWorking = false
        currentTaskProgress = 0
        refreshQueueState()
    }

    private func stopWorker() {
        workerTask?.cancel()
        workerTask = nil
        workerID = nil
        isWorking = false
        currentTaskProgress = 0
    }
}
