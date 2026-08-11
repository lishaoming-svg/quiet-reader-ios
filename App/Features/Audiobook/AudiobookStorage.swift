import Foundation

struct LocalAudiobookChapter: Codable, Hashable, Identifiable {
    let chapterID: String
    let chapterURL: String
    let chapterIndex: Int
    let chapterTitle: String
    let fileName: String
    let textSHA256: String
    let voice: String
    let generationSpeed: Double?
    let segments: [AudiobookTimedSegment]?
    let downloadedAt: Date

    var id: String { chapterID }
}

struct LocalAudiobookManifest: Codable {
    let bookID: String
    var bookTitle: String
    var author: String
    var chapters: [LocalAudiobookChapter]
    var updatedAt: Date
}

enum AudiobookStorage {
    static var rootDirectory: URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        return applicationSupport.appending(path: "Audiobooks", directoryHint: .isDirectory)
    }

    static func chapterFileURL(bookID: String, chapterURL: String) -> URL {
        bookDirectory(bookID: bookID)
            .appending(path: "\(AudiobookIdentifier.chapterID(for: chapterURL)).m4a")
    }

    static func hasAudio(
        bookID: String,
        chapterURL: String,
        matchingVoice voice: String? = nil,
        matchingSpeed speed: Double? = nil
    ) -> Bool {
        guard FileManager.default.fileExists(
            atPath: chapterFileURL(bookID: bookID, chapterURL: chapterURL).path
        ) else { return false }
        guard voice != nil || speed != nil else { return true }
        guard let local = loadManifest(bookID: bookID)?.chapters.first(where: {
            $0.chapterURL == chapterURL
        }) else { return false }
        if let voice, local.voice != voice { return false }
        if let speed, abs((local.generationSpeed ?? 1) - speed) > 0.001 { return false }
        return true
    }

    static func saveChapter(
        book: SearchBook,
        chapter: BookChapter,
        textSHA256: String,
        voice: String,
        generationSpeed: Double = 1,
        segments: [AudiobookTimedSegment] = []
    ) throws {
        let directory = bookDirectory(bookID: book.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let localChapter = LocalAudiobookChapter(
            chapterID: AudiobookIdentifier.chapterID(for: chapter.url),
            chapterURL: chapter.url,
            chapterIndex: chapter.index,
            chapterTitle: chapter.title,
            fileName: chapterFileURL(bookID: book.id, chapterURL: chapter.url).lastPathComponent,
            textSHA256: textSHA256,
            voice: voice,
            generationSpeed: generationSpeed,
            segments: segments,
            downloadedAt: .now
        )
        var manifest = loadManifest(bookID: book.id) ?? LocalAudiobookManifest(
            bookID: book.id,
            bookTitle: book.name,
            author: book.author,
            chapters: [],
            updatedAt: .now
        )
        manifest.bookTitle = book.name
        manifest.author = book.author
        manifest.chapters.removeAll { $0.chapterID == localChapter.chapterID }
        manifest.chapters.append(localChapter)
        manifest.chapters.sort { $0.chapterIndex < $1.chapterIndex }
        manifest.updatedAt = .now
        try saveManifest(manifest)
    }

    static func loadManifest(bookID: String) -> LocalAudiobookManifest? {
        let url = manifestURL(bookID: bookID)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(LocalAudiobookManifest.self, from: data)
    }

    static func downloadedCount(bookID: String) -> Int {
        loadManifest(bookID: bookID)?.chapters.filter {
            FileManager.default.fileExists(
                atPath: bookDirectory(bookID: bookID).appending(path: $0.fileName).path
            )
        }.count ?? 0
    }

    static func timedSegments(bookID: String, chapterURL: String) -> [AudiobookTimedSegment] {
        loadManifest(bookID: bookID)?.chapters.first {
            $0.chapterURL == chapterURL
        }?.segments ?? []
    }

    static func storageSize(bookID: String) -> Int64 {
        let directory = bookDirectory(bookID: bookID)
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        return enumerator.compactMap { item -> Int64? in
            guard let url = item as? URL,
                  let values = try? url.resourceValues(forKeys: [.fileSizeKey]) else { return nil }
            return values.fileSize.map(Int64.init)
        }.reduce(0, +)
    }

    static func deleteBook(bookID: String) throws {
        let directory = bookDirectory(bookID: bookID)
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    static func formatByteCount(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    private static func bookDirectory(bookID: String) -> URL {
        rootDirectory.appending(
            path: AudiobookIdentifier.bookDirectoryID(for: bookID),
            directoryHint: .isDirectory
        )
    }

    private static func manifestURL(bookID: String) -> URL {
        bookDirectory(bookID: bookID).appending(path: "manifest.json")
    }

    private static func saveManifest(_ manifest: LocalAudiobookManifest) throws {
        let url = manifestURL(bookID: manifest.bookID)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(manifest)
        try data.write(to: url, options: .atomic)
    }
}
