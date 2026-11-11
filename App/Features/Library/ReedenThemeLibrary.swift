import CryptoKit
import Foundation

struct ReedenThemeRecord: Codable, Identifiable, Sendable {
    let id: String
    let filename: String
    let name: String
    let creator: String?
    let kind: ReedenThemePackage.Kind
    let hasArtwork: Bool

    var previewFilename: String {
        let stem = (filename as NSString).deletingPathExtension
        return String(stem.prefix(48)) + "-预览.png"
    }
}

actor ReedenThemeLibrary {
    static let shared = ReedenThemeLibrary(root: defaultRoot)

    private static var defaultRoot: URL {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
            return FileManager.default.temporaryDirectory.appendingPathComponent("ReedenThemes-" + UUID().uuidString)
        }
        #endif
        return URL.applicationSupportDirectory.appendingPathComponent("ReedenThemes", isDirectory: true)
    }

    nonisolated let root: URL
    private let files = FileManager.default

    init(root: URL) { self.root = root }

    nonisolated func original(_ record: ReedenThemeRecord) -> URL {
        folder(record.id).appendingPathComponent("original", isDirectory: true).appendingPathComponent(record.filename)
    }

    nonisolated func preview(_ record: ReedenThemeRecord) -> URL {
        folder(record.id).appendingPathComponent("preview").appendingPathComponent(record.previewFilename)
    }

    func records() throws -> [ReedenThemeRecord] {
        guard files.fileExists(atPath: root.path) else { return [] }
        return try files.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
            .compactMap { try? record(in: $0) }
    }

    func importFile(_ access: ImportedFileAccess) throws -> Bool {
        let filename = access.url.lastPathComponent
        guard ["red", "reeden", "json"].contains(access.url.pathExtension.lowercased()) else {
            throw ReedenThemeError.unsupported
        }
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        let staging = root.appendingPathComponent("." + UUID().uuidString, isDirectory: true)
        let originals = staging.appendingPathComponent("original", isDirectory: true)
        try files.createDirectory(at: originals, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: staging) }
        let original = originals.appendingPathComponent(filename)

        try CoordinatedFileReader.withReadingAccess(to: access.url) { url in
            let info = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard info.isRegularFile == true else { throw ReedenThemeError.unsupported }
            guard let size = info.fileSize, size <= ReedenThemePackage.maximumSize else { throw ReedenThemeError.tooLarge }
            try files.copyItem(at: url, to: original)
        }

        let data = try Data(contentsOf: original, options: .mappedIfSafe)
        guard data.count <= ReedenThemePackage.maximumSize else { throw ReedenThemeError.tooLarge }
        let id = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let destination = folder(id)
        if files.fileExists(atPath: destination.path) { return false }
        let package = try ReedenThemePackage.read(data, filename: filename)
        let record = ReedenThemeRecord(id: id, filename: filename, name: package.name, creator: package.creator,
                                       kind: package.kind,
                                       hasArtwork: package.panels.contains { $0.image != nil })
        let previews = staging.appendingPathComponent("preview", isDirectory: true)
        try files.createDirectory(at: previews, withIntermediateDirectories: false)
        try ReedenThemePreview.png(for: package).write(to: previews.appendingPathComponent(record.previewFilename))
        try JSONEncoder().encode(record).write(to: staging.appendingPathComponent("record.json"))
        try files.moveItem(at: staging, to: destination)
        return true
    }

    func remove(_ record: ReedenThemeRecord) throws {
        try files.removeItem(at: folder(record.id))
    }

    private func record(in directory: URL) throws -> ReedenThemeRecord {
        try JSONDecoder().decode(ReedenThemeRecord.self, from: Data(contentsOf: directory.appendingPathComponent("record.json")))
    }

    private nonisolated func folder(_ id: String) -> URL {
        root.appendingPathComponent(id, isDirectory: true)
    }
}
