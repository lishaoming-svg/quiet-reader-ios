import CryptoKit
import Foundation
import ZIPFoundation

struct AudiobookPackageManifest: Decodable {
    let format: String
    let formatVersion: Int
    let protocolVersion: Int
    let createdAt: String
    let bookID: String
    let bookTitle: String
    let author: String
    let voice: String
    let generationSpeed: Double
    let chapterCount: Int
    let packageFingerprint: String
    let chapters: [AudiobookPackageChapter]

    enum CodingKeys: String, CodingKey {
        case format
        case formatVersion = "format_version"
        case protocolVersion = "protocol_version"
        case createdAt = "created_at"
        case bookID = "book_id"
        case bookTitle = "book_title"
        case author
        case voice
        case generationSpeed = "generation_speed"
        case chapterCount = "chapter_count"
        case packageFingerprint = "package_fingerprint"
        case chapters
    }
}

struct AudiobookPackageChapter: Decodable {
    let chapterID: String
    let chapterURL: String
    let chapterIndex: Int
    let chapterTitle: String
    let fileName: String
    let fileSize: Int64
    let audioSHA256: String
    let textSHA256: String
    let segments: [AudiobookTimedSegment]

    enum CodingKeys: String, CodingKey {
        case chapterID = "chapter_id"
        case chapterURL = "chapter_url"
        case chapterIndex = "chapter_index"
        case chapterTitle = "chapter_title"
        case fileName = "file_name"
        case fileSize = "file_size"
        case audioSHA256 = "audio_sha256"
        case textSHA256 = "text_sha256"
        case segments
    }
}

struct AudiobookPackageImportResult: Sendable {
    let chapterCount: Int
    let bookTitle: String
    let voice: String
    let generationSpeed: Double
}

enum AudiobookPackageError: LocalizedError {
    case invalidArchive
    case invalidManifest(String)
    case wrongBook(String)
    case missingAudio(String)
    case corruptAudio(String)

    var errorDescription: String? {
        switch self {
        case .invalidArchive:
            "听书包无法打开或缺少 manifest.json"
        case let .invalidManifest(message):
            "听书包清单无效：\(message)"
        case let .wrongBook(title):
            "这个听书包属于《\(title)》，请在对应书籍中导入"
        case let .missingAudio(title):
            "听书包缺少《\(title)》的章节音频"
        case let .corruptAudio(title):
            "《\(title)》的章节音频校验失败"
        }
    }
}

enum AudiobookPackageValidator {
    static func validate(_ manifest: AudiobookPackageManifest, expectedBookID: String) throws {
        guard manifest.format == "quietreader-readaloud", manifest.formatVersion == 1 else {
            throw AudiobookPackageError.invalidManifest("格式版本不受支持")
        }
        guard (3...AudiobookProtocol.version).contains(manifest.protocolVersion) else {
            throw AudiobookPackageError.invalidManifest("生成器协议版本不受支持")
        }
        guard manifest.bookID == expectedBookID else {
            throw AudiobookPackageError.wrongBook(manifest.bookTitle)
        }
        guard !manifest.voice.isEmpty,
              (0.5...2).contains(manifest.generationSpeed),
              manifest.packageFingerprint.count == 64,
              !manifest.chapters.isEmpty,
              manifest.chapterCount == manifest.chapters.count else {
            throw AudiobookPackageError.invalidManifest("章节数量不一致")
        }
        guard Set(manifest.chapters.map(\.chapterID)).count == manifest.chapters.count else {
            throw AudiobookPackageError.invalidManifest("包含重复章节")
        }
        for chapter in manifest.chapters {
            try validate(chapter)
        }
    }

    private static func validate(_ chapter: AudiobookPackageChapter) throws {
        guard chapter.chapterID == AudiobookIdentifier.chapterID(for: chapter.chapterURL),
              chapter.fileName == "chapters/\(chapter.chapterID).m4a",
              chapter.fileSize > 0,
              chapter.audioSHA256.count == 64,
              chapter.textSHA256.count == 64,
              !chapter.segments.isEmpty else {
            throw AudiobookPackageError.invalidManifest("\(chapter.chapterTitle) 的标识不完整")
        }
        var previousEndOffset = 0
        var previousEndTime = 0.0
        for segment in chapter.segments {
            guard segment.startOffset == previousEndOffset,
                  segment.endOffset > segment.startOffset,
                  segment.startTime >= previousEndTime - 0.001,
                  segment.endTime > segment.startTime else {
                throw AudiobookPackageError.invalidManifest("\(chapter.chapterTitle) 的时间轴不连续")
            }
            previousEndOffset = segment.endOffset
            previousEndTime = segment.endTime
        }
        let completeText = chapter.segments.map(\.text).joined()
        guard AudiobookIdentifier.sha256(completeText) == chapter.textSHA256 else {
            throw AudiobookPackageError.invalidManifest("\(chapter.chapterTitle) 的正文校验失败")
        }
    }
}

enum AudiobookPackageImporter {
    private static let maximumManifestBytes: UInt64 = 64 * 1024 * 1024

    static func importPackage(
        at sourceURL: URL,
        for book: SearchBook
    ) throws -> AudiobookPackageImportResult {
        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessed { sourceURL.stopAccessingSecurityScopedResource() }
        }
        let archive: Archive
        do {
            archive = try Archive(url: sourceURL, accessMode: .read)
        } catch {
            throw AudiobookPackageError.invalidArchive
        }
        guard let manifestEntry = archive["manifest.json"],
              manifestEntry.type == .file,
              manifestEntry.uncompressedSize <= maximumManifestBytes else {
            throw AudiobookPackageError.invalidArchive
        }
        var manifestData = Data()
        _ = try archive.extract(manifestEntry) { data in
            manifestData.append(data)
        }
        let manifest: AudiobookPackageManifest
        do {
            manifest = try JSONDecoder().decode(AudiobookPackageManifest.self, from: manifestData)
        } catch {
            throw AudiobookPackageError.invalidManifest(error.localizedDescription)
        }
        try AudiobookPackageValidator.validate(manifest, expectedBookID: book.id)

        let manager = FileManager.default
        let stagingDirectory = manager.temporaryDirectory.appending(
            path: "quietreader-import-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try manager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: stagingDirectory) }

        for chapter in manifest.chapters {
            guard let entry = archive[chapter.fileName],
                  entry.type == .file,
                  Int64(entry.uncompressedSize) == chapter.fileSize else {
                throw AudiobookPackageError.missingAudio(chapter.chapterTitle)
            }
            let destination = stagingDirectory.appending(path: "\(chapter.chapterID).m4a")
            _ = try archive.extract(entry, to: destination)
            let values = try destination.resourceValues(forKeys: [.fileSizeKey])
            guard Int64(values.fileSize ?? 0) == chapter.fileSize,
                  try fileSHA256(destination) == chapter.audioSHA256 else {
                throw AudiobookPackageError.corruptAudio(chapter.chapterTitle)
            }
        }
        try AudiobookStorage.installPackage(
            manifest,
            stagedIn: stagingDirectory,
            for: book
        )
        return AudiobookPackageImportResult(
            chapterCount: manifest.chapters.count,
            bookTitle: manifest.bookTitle,
            voice: manifest.voice,
            generationSpeed: manifest.generationSpeed
        )
    }

    private static func fileSHA256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
