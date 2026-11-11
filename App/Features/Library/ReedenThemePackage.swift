import Foundation
import ImageIO
import ZIPFoundation

enum ReedenThemeError: LocalizedError {
    case unsupported, invalid, tooLarge

    var errorDescription: String? {
        switch self {
        case .unsupported: "请选择 Reeden 导出的应用主题或封面图集（RED 或主题 JSON）。"
        case .invalid: "主题包已损坏，或使用了暂不支持的格式。"
        case .tooLarge: "主题包超过 1 GB，无法导入。"
        }
    }
}

struct ReedenThemePackage {
    enum Kind: String, Codable, Sendable {
        case theme, gallery, privateTheme
    }

    struct Palette: Decodable {
        var backgroundColor: String?
        var foregroundColor: String?
        var cardColor: String?
        var primaryColor: String?
        var accentColor: String?
    }

    struct Panel {
        var title: String
        var palette: Palette? = nil
        var image: CGImage? = nil
        var isDark = false
    }

    private struct Theme: Decodable {
        let name: String
        var light: Palette?
        var dark: Palette?
    }

    private struct PrivateHeader: Decodable {
        let version: Int
        let resourceType: String
        let assetMode: String
        let manifestLength: Int
    }

    static let maximumSize = 1_024 * 1_024 * 1_024
    private static let metadataLimit = 1_024 * 1_024
    private static let imageLimit = 16 * 1_024 * 1_024

    let name: String
    let creator: String?
    let kind: Kind
    let panels: [Panel]

    static func read(_ data: Data, filename: String) throws -> Self {
        guard data.count <= maximumSize else { throw ReedenThemeError.tooLarge }
        let filenameInfo = parseFilename(filename)
        let prefix = Array(data.prefix(4))
        switch prefix {
        case [0x52, 0x45, 0x44, 0x10]:
            return try readPrivate(data, filenameInfo: filenameInfo)
        case [0x52, 0x45, 0x44, 0x04], [0x52, 0x45, 0x44, 0x02]:
            let archive = try Archive(data: Data(data.dropFirst(4)), accessMode: .read)
            if prefix.last == 0x04 {
                return try readTheme(extract("theme.json", from: archive, limit: metadataLimit),
                                     archive: archive, filenameInfo: filenameInfo)
            }
            return try readGallery(archive, filenameInfo: filenameInfo)
        default:
            guard (filename as NSString).pathExtension.lowercased() == "json", data.count <= metadataLimit else {
                throw ReedenThemeError.unsupported
            }
            return try readTheme(data, archive: nil, filenameInfo: filenameInfo)
        }
    }

    private static func readTheme(_ data: Data, archive: Archive?, filenameInfo: FilenameInfo) throws -> Self {
        guard let theme = try? JSONDecoder().decode(Theme.self, from: data),
              theme.light != nil || theme.dark != nil else { throw ReedenThemeError.unsupported }
        var panels: [Panel] = []
        if let light = theme.light {
            panels.append(Panel(title: "浅色", palette: light, image: thumbnail("light/theme_bg.img", in: archive)))
        }
        if let dark = theme.dark {
            panels.append(Panel(title: "深色", palette: dark, image: thumbnail("dark/theme_bg.img", in: archive), isDark: true))
        }
        return Self(name: clean(theme.name) ?? filenameInfo.name, creator: filenameInfo.creator, kind: .theme, panels: panels)
    }

    private static func readGallery(_ archive: Archive, filenameInfo: FilenameInfo) throws -> Self {
        struct Gallery: Decodable { var name: String? }
        let metadata = try JSONDecoder().decode(Gallery.self, from: extract("meta.json", from: archive, limit: metadataLimit))
        var panels: [Panel] = []
        for entry in archive.prefix(256) {
            let ext = (entry.path as NSString).pathExtension.lowercased()
            guard !entry.path.contains("/"), ["jpg", "jpeg", "png", "webp", "gif"].contains(ext),
                  let image = thumbnail(entry.path, in: archive) else { continue }
            panels.append(Panel(title: "封面 \(panels.count + 1)", image: image))
            if panels.count == 4 { break }
        }
        return Self(name: clean(metadata.name) ?? filenameInfo.name, creator: filenameInfo.creator, kind: .gallery, panels: panels)
    }

    private static func readPrivate(_ data: Data, filenameInfo: FilenameInfo) throws -> Self {
        guard data.count >= 8 else { throw ReedenThemeError.invalid }
        let length = data[4..<8].reduce(0) { ($0 << 8) | Int($1) }
        guard length > 0, length <= metadataLimit, length <= data.count - 8,
              let header = try? JSONDecoder().decode(PrivateHeader.self, from: data[8..<(8 + length)]),
              header.version == 2, header.resourceType == "themeBundle",
              header.manifestLength > 0, header.manifestLength <= data.count - 8 - length else {
            throw ReedenThemeError.invalid
        }
        // The public header identifies plaintext assets after the opaque manifest.
        let images = header.assetMode == "plain-sequential"
            ? try plaintextImages(data, start: 8 + length + header.manifestLength) : []
        let panels = images.enumerated().map { Panel(title: "素材 \($0.offset + 1)", image: $0.element) }
        return Self(name: filenameInfo.name, creator: filenameInfo.creator, kind: .privateTheme, panels: panels)
    }

    private struct FilenameInfo {
        let name: String
        var creator: String? = nil
    }

    private static func parseFilename(_ filename: String) -> FilenameInfo {
        let stem = (filename as NSString).deletingPathExtension
        let prefixes = ["应用主题", "應用主題", "封面图集", "封面圖集"]
        let stripped = prefixes.first { stem.hasPrefix($0 + " - ") || stem.hasPrefix($0 + "-") }
        let payload = stripped.map { prefix in
            let separator = stem.hasPrefix(prefix + " - ") ? " - " : "-"
            return String(stem.dropFirst(prefix.count + separator.count))
        } ?? stem
        let parts = payload.components(separatedBy: " - ")
        if parts.count >= 2, let creator = clean(parts.first),
           let title = clean(parts.dropFirst().joined(separator: " - ")) {
            return FilenameInfo(name: title, creator: creator)
        }
        // Some exports use a compact separator after the theme maker.
        if stripped.map({ stem.hasPrefix($0 + " - ") }) == true,
           let divider = payload.firstIndex(of: "-"),
           let creator = clean(String(payload[..<divider])),
           let title = clean(String(payload[payload.index(after: divider)...])) {
            return FilenameInfo(name: title, creator: creator)
        }
        return FilenameInfo(name: clean(payload) ?? stem)
    }

    private static func plaintextImages(_ data: Data, start: Int) throws -> [CGImage] {
        let signatures: [[UInt8]] = [
            [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A], [0xFF, 0xD8, 0xFF],
            Array("RIFF".utf8), Array("GIF87a".utf8), Array("GIF89a".utf8)
        ]
        var candidates: [Int] = []
        for signature in signatures {
            let marker = Data(signature)
            var cursor = start
            for _ in 0..<32 {
                try Task.checkCancellation()
                guard let match = data.range(of: marker, in: cursor..<data.count) else { break }
                cursor = match.upperBound
                if signature == Array("RIFF".utf8) {
                    guard match.lowerBound + 12 <= data.count,
                          data[(match.lowerBound + 8)..<(match.lowerBound + 12)].elementsEqual("WEBP".utf8) else { continue }
                }
                candidates.append(match.lowerBound)
            }
        }
        var images: [(image: CGImage, area: Int)] = []
        for offset in candidates.sorted().prefix(48) {
            try Task.checkCancellation()
            let end = min(data.count, offset + imageLimit)
            guard let source = imageSource(data[offset..<end]),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  (160...16_384).contains(width), (160...16_384).contains(height), width * height <= 80_000_000,
                  let image = thumbnail(source) else { continue }
            images.append((image, width * height))
        }
        return images.sorted { $0.area > $1.area }.map(\.image)
    }

    private static func thumbnail(_ path: String, in archive: Archive?) -> CGImage? {
        guard let archive, let data = try? extract(path, from: archive, limit: imageLimit),
              let source = imageSource(data) else { return nil }
        return thumbnail(source)
    }

    private static func imageSource(_ data: Data) -> CGImageSource? {
        CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
    }

    private static func thumbnail(_ source: CGImageSource) -> CGImage? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              (1...16_384).contains(width), (1...16_384).contains(height), width * height <= 80_000_000 else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: 480
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func extract(_ path: String, from archive: Archive, limit: Int) throws -> Data {
        guard let entry = archive[path], entry.type == .file, entry.uncompressedSize <= limit else {
            throw ReedenThemeError.invalid
        }
        var result = Data()
        let crc = try archive.extract(entry) { chunk in
            try Task.checkCancellation()
            guard chunk.count <= limit - result.count else { throw ReedenThemeError.invalid }
            result.append(chunk)
        }
        guard crc == entry.checksum else { throw ReedenThemeError.invalid }
        return result
    }

    private static func clean(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return String(value.prefix(200))
    }
}
