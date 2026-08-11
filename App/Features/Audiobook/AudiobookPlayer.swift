import AVFoundation
import Combine
import MediaPlayer

@MainActor
final class AudiobookPlayer: NSObject, ObservableObject {
    static let shared = AudiobookPlayer()

    @Published private(set) var currentBookID: String?
    @Published private(set) var currentChapterIndex: Int?
    @Published private(set) var currentChapterTitle = ""
    @Published private(set) var isPlaying = false
    @Published private(set) var isWaitingForNextChapter = false
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var duration: Double = 0
    @Published var playbackRate: Double = 1 {
        didSet {
            playbackRate = min(max(playbackRate, 0.5), 2)
            if isPlaying { player.playImmediately(atRate: Float(playbackRate)) }
            updateNowPlaying()
        }
    }

    private struct Entry {
        let bookID: String
        let bookTitle: String
        let author: String
        let chapterIndex: Int
        let chapterTitle: String
        let fileURL: URL
    }

    private let player = AVPlayer()
    private var entries: [Entry] = []
    private var entryPosition = 0
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var didConfigureRemoteCommands = false

    override private init() {
        super.init()
        configureAudioSession()
        configureRemoteCommands()
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self else { return }
                elapsed = max(0, time.seconds.isFinite ? time.seconds : 0)
                let itemDuration = player.currentItem?.duration.seconds ?? 0
                duration = itemDuration.isFinite ? max(0, itemDuration) : 0
                updateNowPlaying()
            }
        }
    }

    func play(book: SearchBook, chapters: [BookChapter], startingAt startIndex: Int) throws {
        let targetIndices = AudiobookQueuePlanner.targetIndices(
            chapters: chapters,
            currentIndex: startIndex,
            lookAhead: chapters.count
        )
        guard let firstIndex = targetIndices.first,
              AudiobookStorage.hasAudio(bookID: book.id, chapterURL: chapters[firstIndex].url) else {
            throw AudiobookClientError.audioUnavailable
        }

        var playable: [Entry] = []
        for index in targetIndices {
            let chapter = chapters[index]
            guard AudiobookStorage.hasAudio(bookID: book.id, chapterURL: chapter.url) else {
                break
            }
            playable.append(
                Entry(
                    bookID: book.id,
                    bookTitle: book.name,
                    author: book.author,
                    chapterIndex: index,
                    chapterTitle: chapter.title,
                    fileURL: AudiobookStorage.chapterFileURL(
                        bookID: book.id,
                        chapterURL: chapter.url
                    )
                )
            )
        }
        guard !playable.isEmpty else { throw AudiobookClientError.audioUnavailable }
        entries = playable
        entryPosition = 0
        loadCurrentEntry(autoplay: true)
    }

    func extendQueue(book: SearchBook, chapters: [BookChapter]) {
        guard currentBookID == book.id,
              let currentChapterIndex,
              !entries.isEmpty else { return }
        let lastIndex = entries.last?.chapterIndex ?? currentChapterIndex
        let existingIndices = Set(entries.map(\.chapterIndex))
        for index in chapters.indices where index > lastIndex && !chapters[index].isVolume {
            let chapter = chapters[index]
            guard AudiobookStorage.hasAudio(bookID: book.id, chapterURL: chapter.url) else {
                break
            }
            guard !existingIndices.contains(index) else { continue }
            entries.append(
                Entry(
                    bookID: book.id,
                    bookTitle: book.name,
                    author: book.author,
                    chapterIndex: index,
                    chapterTitle: chapter.title,
                    fileURL: AudiobookStorage.chapterFileURL(
                        bookID: book.id,
                        chapterURL: chapter.url
                    )
                )
            )
        }
        if isWaitingForNextChapter, entryPosition + 1 < entries.count {
            entryPosition += 1
            loadCurrentEntry(autoplay: true)
        }
    }

    func togglePlayback() {
        guard player.currentItem != nil else { return }
        if isPlaying {
            pause()
        } else {
            resume()
        }
    }

    func pause() {
        player.pause()
        isPlaying = false
        updateNowPlaying()
    }

    func resume() {
        guard player.currentItem != nil else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        player.playImmediately(atRate: Float(playbackRate))
        isPlaying = true
        updateNowPlaying()
    }

    func seek(by seconds: Double) {
        let target = min(max(elapsed + seconds, 0), max(duration, 0))
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
    }

    func seek(to progress: Double) {
        guard duration > 0 else { return }
        let target = min(max(progress, 0), 1) * duration
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
    }

    func playNext() {
        guard entryPosition + 1 < entries.count else {
            pause()
            isWaitingForNextChapter = true
            return
        }
        entryPosition += 1
        loadCurrentEntry(autoplay: true)
    }

    func playPrevious() {
        if elapsed > 5 {
            seek(to: 0)
            return
        }
        guard entryPosition > 0 else { return }
        entryPosition -= 1
        loadCurrentEntry(autoplay: true)
    }

    func stop(bookID: String? = nil) {
        if let bookID, currentBookID != bookID { return }
        player.pause()
        player.replaceCurrentItem(with: nil)
        entries = []
        entryPosition = 0
        currentBookID = nil
        currentChapterIndex = nil
        currentChapterTitle = ""
        elapsed = 0
        duration = 0
        isPlaying = false
        isWaitingForNextChapter = false
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    private func loadCurrentEntry(autoplay: Bool) {
        guard entries.indices.contains(entryPosition) else { return }
        let entry = entries[entryPosition]
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        let item = AVPlayerItem(url: entry.fileURL)
        player.replaceCurrentItem(with: item)
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.playNext() }
        }
        currentBookID = entry.bookID
        currentChapterIndex = entry.chapterIndex
        currentChapterTitle = entry.chapterTitle
        isWaitingForNextChapter = false
        elapsed = 0
        duration = 0
        updateNowPlaying()
        if autoplay { resume() }
    }

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(
            .playback,
            mode: .spokenAudio,
            options: [.allowAirPlay, .allowBluetoothA2DP]
        )
    }

    private func configureRemoteCommands() {
        guard !didConfigureRemoteCommands else { return }
        didConfigureRemoteCommands = true
        let commands = MPRemoteCommandCenter.shared()
        commands.playCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.resume() }
            return .success
        }
        commands.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.pause() }
            return .success
        }
        commands.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.togglePlayback() }
            return .success
        }
        commands.skipForwardCommand.preferredIntervals = [15]
        commands.skipForwardCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.seek(by: 15) }
            return .success
        }
        commands.skipBackwardCommand.preferredIntervals = [15]
        commands.skipBackwardCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.seek(by: -15) }
            return .success
        }
        commands.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.playNext() }
            return .success
        }
        commands.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.playPrevious() }
            return .success
        }
        commands.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            Task { @MainActor [weak self] in
                guard let self, duration > 0 else { return }
                seek(to: event.positionTime / duration)
            }
            return .success
        }
    }

    private func updateNowPlaying() {
        guard entries.indices.contains(entryPosition) else { return }
        let entry = entries[entryPosition]
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: entry.chapterTitle,
            MPMediaItemPropertyAlbumTitle: entry.bookTitle,
            MPMediaItemPropertyArtist: entry.author,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? playbackRate : 0
        ]
    }
}
