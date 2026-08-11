import CryptoKit
import Foundation
import Security

enum AudiobookProtocol {
    static let version = 2
    static let defaultPort = 8765
}

struct AudiobookVoice: Codable, Hashable, Identifiable {
    let id: String
    let name: String
}

struct AudiobookTimedSegment: Codable, Hashable, Identifiable {
    let text: String
    let role: String
    let startTime: Double
    let endTime: Double
    let startOffset: Int
    let endOffset: Int

    var id: String { "\(startOffset)-\(endOffset)-\(role)" }

    var roleName: String {
        switch role {
        case "protagonist": "主角"
        case "male": "男性角色"
        case "female": "女性角色"
        default: "旁白"
        }
    }

    enum CodingKeys: String, CodingKey {
        case text
        case role
        case startTime = "start_time"
        case endTime = "end_time"
        case startOffset = "start_offset"
        case endOffset = "end_offset"
    }
}

enum AudiobookTimelineResolver {
    static func segment(
        at elapsed: Double,
        in timeline: [AudiobookTimedSegment]
    ) -> AudiobookTimedSegment? {
        guard !timeline.isEmpty else { return nil }
        if let active = timeline.last(where: { segment in
            segment.startTime <= elapsed && elapsed < segment.endTime
        }) {
            return active
        }
        return elapsed >= (timeline.last?.endTime ?? .infinity)
            ? timeline.last
            : timeline.first
    }
}

struct AudiobookServerHealth: Decodable {
    let protocolVersion: Int
    let service: String
    let serverVersion: String
    let status: String
    let engine: String
    let engineName: String
    let voices: [AudiobookVoice]

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case service
        case serverVersion = "server_version"
        case status
        case engine
        case engineName = "engine_name"
        case voices
    }
}

struct AudiobookJobRequest: Encodable {
    let protocolVersion = AudiobookProtocol.version
    let bookID: String
    let bookTitle: String
    let author: String
    let chapterID: String
    let chapterIndex: Int
    let chapterTitle: String
    let text: String
    let textSHA256: String
    let voice: String
    let speed: Double

    init(
        book: SearchBook,
        chapter: BookChapter,
        text rawText: String,
        voice: String,
        speed: Double
    ) {
        let normalized = AudiobookTextNormalizer.normalize(rawText)
        bookID = book.id
        bookTitle = book.name
        author = book.author
        chapterID = AudiobookIdentifier.chapterID(for: chapter.url)
        chapterIndex = chapter.index
        chapterTitle = chapter.title
        text = normalized
        textSHA256 = AudiobookIdentifier.sha256(normalized)
        self.voice = voice
        self.speed = min(max(speed, 0.5), 2)
    }

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case bookID = "book_id"
        case bookTitle = "book_title"
        case author
        case chapterID = "chapter_id"
        case chapterIndex = "chapter_index"
        case chapterTitle = "chapter_title"
        case text
        case textSHA256 = "text_sha256"
        case voice
        case speed
    }
}

struct AudiobookJobStatus: Decodable {
    let protocolVersion: Int
    let jobID: String
    let status: String
    let progress: Double
    let completedSegments: Int
    let totalSegments: Int
    let error: String?
    let fileSize: Int
    let chapterIndex: Int
    let chapterID: String
    let chapterTitle: String
    let audioPath: String?
    let segments: [AudiobookTimedSegment]?

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case jobID = "job_id"
        case status
        case progress
        case completedSegments = "completed_segments"
        case totalSegments = "total_segments"
        case error
        case fileSize = "file_size"
        case chapterIndex = "chapter_index"
        case chapterID = "chapter_id"
        case chapterTitle = "chapter_title"
        case audioPath = "audio_path"
        case segments
    }

    var isFinished: Bool { status == "completed" || status == "failed" }
}

struct AudiobookPairingConfiguration: Equatable {
    var baseURL: URL
    var token: String

    init?(baseURLString: String, token: String) {
        let cleanedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        var cleanedAddress = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanedAddress.contains("://") {
            cleanedAddress = "http://\(cleanedAddress)"
        }
        while cleanedAddress.hasSuffix("/") { cleanedAddress.removeLast() }
        guard let url = URL(string: cleanedAddress),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil,
              cleanedToken.count >= 16 else {
            return nil
        }
        baseURL = url
        self.token = cleanedToken
    }

    init?(pairingCode: String) {
        guard let components = URLComponents(string: pairingCode.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme == "quietreader",
              components.host == "audiobook-pair",
              let address = components.queryItems?.first(where: { $0.name == "url" })?.value,
              let token = components.queryItems?.first(where: { $0.name == "token" })?.value else {
            return nil
        }
        self.init(baseURLString: address, token: token)
    }

    var pairingCode: String {
        var components = URLComponents()
        components.scheme = "quietreader"
        components.host = "audiobook-pair"
        components.queryItems = [
            URLQueryItem(name: "url", value: baseURL.absoluteString),
            URLQueryItem(name: "token", value: token)
        ]
        return components.string ?? ""
    }
}

enum AudiobookTextNormalizer {
    static func normalize(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

enum AudiobookQueuePlanner {
    static let defaultLookAhead = 3

    static func targetIndices(
        chapters: [BookChapter],
        currentIndex: Int,
        lookAhead: Int = defaultLookAhead
    ) -> [Int] {
        guard !chapters.isEmpty else { return [] }
        let start = min(max(currentIndex, 0), chapters.count - 1)
        let readable = chapters.indices.dropFirst(start).filter { !chapters[$0].isVolume }
        return Array(readable.prefix(max(0, lookAhead) + 1))
    }
}

enum AudiobookIdentifier {
    static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func chapterID(for chapterURL: String) -> String {
        String(sha256(chapterURL).prefix(32))
    }

    static func bookDirectoryID(for bookID: String) -> String {
        String(sha256(bookID).prefix(24))
    }
}

enum AudiobookCredentialsStore {
    private static let baseURLKey = "audiobook.server.baseURL"
    private static let keychainService = "com.quietreader.audiobook"
    private static let keychainAccount = "pairing-token"

    static func load() -> AudiobookPairingConfiguration? {
        guard let baseURL = UserDefaults.standard.string(forKey: baseURLKey),
              let token = keychainToken() else {
            return nil
        }
        return AudiobookPairingConfiguration(baseURLString: baseURL, token: token)
    }

    static func save(_ configuration: AudiobookPairingConfiguration) throws {
        UserDefaults.standard.set(configuration.baseURL.absoluteString, forKey: baseURLKey)
        let data = Data(configuration.token.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        SecItemDelete(query as CFDictionary)
        var insertion = query
        insertion[kSecValueData as String] = data
        let status = SecItemAdd(insertion as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw AudiobookClientError.credentials("无法保存配对令牌（\(status)）")
        }
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: baseURLKey)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        SecItemDelete(query as CFDictionary)
    }

    private static func keychainToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}

enum AudiobookClientError: LocalizedError {
    case invalidResponse
    case server(Int, String)
    case protocolMismatch
    case credentials(String)
    case generation(String)
    case audioUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "听书生成器返回了无法识别的数据"
        case let .server(code, message): "生成器错误（\(code)）：\(message)"
        case .protocolMismatch: "App 与听书生成器的协议版本不一致"
        case let .credentials(message): message
        case let .generation(message): message
        case .audioUnavailable: "章节音频尚未生成完成"
        }
    }
}
