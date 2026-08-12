import CryptoKit
import Foundation
import Security

enum AudiobookProtocol {
    static let version = 5
    static let defaultPort = 8765
}

struct AudiobookVoice: Codable, Hashable, Identifiable {
    let id: String
    let name: String
    let group: String?
    let description: String?
    let roleTags: [String]?

    var groupName: String {
        switch group {
        case "automatic": "自动分配"
        case "narrator": "旁白"
        case "male": "男声"
        case "female": "女声"
        default: "其他"
        }
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case group
        case description
        case roleTags = "role_tags"
    }
}

struct AudiobookTimedSegment: Codable, Hashable, Identifiable {
    let text: String
    let role: String
    let speaker: String?
    let voiceID: String?
    let startTime: Double
    let endTime: Double
    let startOffset: Int
    let endOffset: Int

    var id: String { "\(startOffset)-\(endOffset)-\(role)" }

    var roleName: String {
        if let speaker, !speaker.isEmpty { return speaker }
        switch role {
        case "protagonist": return "主角"
        case "male": return "男性角色"
        case "female": return "女性角色"
        default: return "旁白"
        }
    }

    var voiceName: String? {
        guard let voiceID else { return nil }
        return [
            "narrator-demo": "自然悬疑旁白",
            "male-uncle-fu": "低沉成熟男声",
            "male-young-south": "自然青年男声",
            "male-calm-young": "冷静青年男声",
            "male-refined-middle": "儒雅中年男声",
            "male-rugged-adult": "硬朗成年男声",
            "female-serena": "温柔自然女声",
            "female-cool-young": "清冷青年女声",
            "female-lively-young": "活泼少女声",
            "female-intellectual-mature": "成熟知性女声",
            "female-commanding-middle": "强势中年女声"
        ][voiceID] ?? voiceID
    }

    var roleAndVoiceName: String {
        guard let voiceName else { return roleName }
        return "\(roleName) · \(voiceName)"
    }

    init(
        text: String,
        role: String,
        speaker: String? = nil,
        voiceID: String? = nil,
        startTime: Double,
        endTime: Double,
        startOffset: Int,
        endOffset: Int
    ) {
        self.text = text
        self.role = role
        self.speaker = speaker
        self.voiceID = voiceID
        self.startTime = startTime
        self.endTime = endTime
        self.startOffset = startOffset
        self.endOffset = endOffset
    }

    enum CodingKeys: String, CodingKey {
        case text
        case role
        case speaker
        case voiceID = "voice_id"
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

enum AudiobookSentenceNavigator {
    static func target(
        from current: AudiobookTimedSegment?,
        movingBy amount: Int,
        in segments: [AudiobookTimedSegment]
    ) -> AudiobookTimedSegment? {
        guard !segments.isEmpty else { return nil }
        guard let current,
              let currentIndex = segments.firstIndex(where: { $0.id == current.id }) else {
            return segments.first
        }
        let targetIndex = min(max(currentIndex + amount, 0), segments.count - 1)
        return segments[targetIndex]
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
    let defaultVoiceAssignment: [String: String]?
    let queue: AudiobookServerQueueSummary?

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case service
        case serverVersion = "server_version"
        case status
        case engine
        case engineName = "engine_name"
        case voices
        case defaultVoiceAssignment = "default_voice_assignment"
        case queue
    }
}

struct AudiobookServerQueueSummary: Decodable {
    let runningCount: Int
    let queuedCount: Int
    let failedCount: Int

    enum CodingKeys: String, CodingKey {
        case runningCount = "running_count"
        case queuedCount = "queued_count"
        case failedCount = "failed_count"
    }

    var pendingCount: Int { runningCount + queuedCount }
}

struct AudiobookJobRequest: Encodable {
    let protocolVersion = AudiobookProtocol.version
    let bookID: String
    let bookTitle: String
    let author: String
    let chapterID: String
    let chapterURL: String
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
        chapterURL = chapter.url
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
        case chapterURL = "chapter_url"
        case chapterIndex = "chapter_index"
        case chapterTitle = "chapter_title"
        case text
        case textSHA256 = "text_sha256"
        case voice
        case speed
    }
}

struct AudiobookBatchJobRequest: Encodable {
    let protocolVersion = AudiobookProtocol.version
    let jobs: [AudiobookJobRequest]

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case jobs
    }
}

struct AudiobookBatchSubmission: Decodable {
    let protocolVersion: Int
    let acceptedCount: Int
    let discardedCount: Int?

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case acceptedCount = "accepted_count"
        case discardedCount = "discarded_count"
    }
}

struct AudiobookBookStatus: Decodable {
    let protocolVersion: Int
    let bookID: String
    let voice: String
    let generationSpeed: Double
    let totalCount: Int
    let completedCount: Int
    let runningCount: Int
    let queuedCount: Int
    let failedCount: Int
    let completedBytes: Int64
    let jobs: [AudiobookBookJobSummary]?

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case bookID = "book_id"
        case voice
        case generationSpeed = "generation_speed"
        case totalCount = "total_count"
        case completedCount = "completed_count"
        case runningCount = "running_count"
        case queuedCount = "queued_count"
        case failedCount = "failed_count"
        case completedBytes = "completed_bytes"
        case jobs
    }

    var hasCompletedAudio: Bool { completedCount > 0 }
    var isComplete: Bool { totalCount > 0 && completedCount == totalCount }
    var completedJobs: [AudiobookBookJobSummary] {
        (jobs ?? []).filter { $0.status == "completed" }
    }
    var runningJobs: [AudiobookBookJobSummary] {
        (jobs ?? []).filter { $0.status == "running" }
    }
    var failedJobs: [AudiobookBookJobSummary] {
        (jobs ?? []).filter { $0.status == "failed" }
    }
}

struct AudiobookBookJobSummary: Decodable, Identifiable {
    let jobID: String
    let chapterID: String
    let chapterIndex: Int
    let chapterTitle: String
    let status: String
    let progress: Double
    let fileSize: Int64

    var id: String { jobID }

    enum CodingKeys: String, CodingKey {
        case jobID = "job_id"
        case chapterID = "chapter_id"
        case chapterIndex = "chapter_index"
        case chapterTitle = "chapter_title"
        case status
        case progress
        case fileSize = "file_size"
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

    static func unreadIndices(
        chapters: [BookChapter],
        currentIndex: Int
    ) -> [Int] {
        guard !chapters.isEmpty else { return [] }
        let start = min(max(currentIndex, 0), chapters.count - 1)
        return chapters.indices.dropFirst(start).filter { !chapters[$0].isVolume }
    }

    static func targetIndices(
        chapters: [BookChapter],
        currentIndex: Int,
        lookAhead: Int = defaultLookAhead
    ) -> [Int] {
        let readable = unreadIndices(chapters: chapters, currentIndex: currentIndex)
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
    case connection(String)
    case credentials(String)
    case generation(String)
    case audioUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "听书生成器返回了无法识别的数据"
        case let .server(code, message): "生成器错误（\(code)）：\(message)"
        case .protocolMismatch: "电脑仍在运行旧版生成器。请关闭旧的听书窗口，再双击桌面的“启动墨阅听书”"
        case let .connection(message): message
        case let .credentials(message): message
        case let .generation(message): message
        case .audioUnavailable: "章节音频尚未生成完成"
        }
    }
}
