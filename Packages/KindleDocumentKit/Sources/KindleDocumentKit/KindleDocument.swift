import CLibmobi
import Darwin
import Foundation

public struct KindleDocument: Sendable {
    public let title: String?
    public let author: String?
    public let htmlParts: [String]
    public let cover: Data?

    public enum ReadError: Error { case encrypted, invalid, tooLarge }

    /// libmobi handles PalmDOC, HUFF/CDIC, KF7, hybrid and KF8 containers.
    /// Reject encryption before parsing; no DRM keys or decryption APIs are used.
    public static func read(at url: URL) throws -> KindleDocument {
        guard let mobi = mobi_init() else { throw ReadError.invalid }
        defer { mobi_free(mobi) }
        let status = url.withUnsafeFileSystemRepresentation { path in
            mobi_load_filename(mobi, path)
        }
        if status == MOBI_FILE_ENCRYPTED || mobi_is_encrypted(mobi) { throw ReadError.encrypted }
        guard status == MOBI_SUCCESS else { throw ReadError.invalid }
        guard mobi_get_text_maxsize(mobi) <= 64 * 1_024 * 1_024 else { throw ReadError.tooLarge }
        guard let raw = mobi_init_rawml(mobi) else { throw ReadError.invalid }
        defer { mobi_free_rawml(raw) }
        guard mobi_parse_rawml(raw, mobi) == MOBI_SUCCESS else { throw ReadError.invalid }
        var parts: [String] = []
        var part = raw.pointee.markup
        var total = 0
        while let current = part {
            try Task.checkCancellation()
            let value = current.pointee
            guard value.size <= 32 * 1_024 * 1_024, total <= 64 * 1_024 * 1_024 - value.size,
                  parts.count < 10_000 else { throw ReadError.tooLarge }
            total += value.size
            if let bytes = value.data {
                let data = Data(bytes: bytes, count: value.size)
                guard let html = String(data: data, encoding: .utf8)
                    ?? String(data: data, encoding: .windowsCP1252) else { throw ReadError.invalid }
                parts.append(html)
            }
            part = value.next
        }
        var cover: Data?
        if let record = mobi_get_exthrecord_by_tag(mobi, EXTH_COVEROFFSET), let bytes = record.pointee.data {
            let id = mobi_decode_exthvalue(bytes.assumingMemoryBound(to: UInt8.self), Int(record.pointee.size))
            if let part = mobi_get_resource_by_uid(raw, Int(id)), part.pointee.size <= 8 * 1_024 * 1_024,
               let bytes = part.pointee.data {
                cover = Data(bytes: bytes, count: part.pointee.size)
            }
        }
        var resource = raw.pointee.resources
        var count = 0
        while cover == nil, let current = resource, count < 10_000 {
            let value = current.pointee
            if [T_JPG, T_PNG, T_GIF].contains(value.type), value.size <= 8 * 1_024 * 1_024,
               let bytes = value.data {
                cover = Data(bytes: bytes, count: value.size)
                break
            }
            count += 1
            resource = value.next
        }
        return KindleDocument(title: metadata(mobi_meta_get_title(mobi)),
                              author: metadata(mobi_meta_get_author(mobi)),
                              htmlParts: parts, cover: cover)
    }

    private static func metadata(_ value: UnsafeMutablePointer<CChar>?) -> String? {
        guard let value else { return nil }
        defer { free(value) }
        return String(validatingUTF8: value)
    }
}
