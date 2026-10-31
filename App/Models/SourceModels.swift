import Foundation

struct BookSourceDefinition: Codable, Hashable, Identifiable, Sendable {
    var sourceId: String?
    var bookSourceUrl: String
    var bookSourceName: String
    var bookSourceGroup: String?
    var bookSourceType: Int?
    var enabled: Bool?
    var enabledExplore: Bool?
    var lastUpdateTime: Int64?
    var header: String?
    var loginUrl: String?
    var searchUrl: String?
    var exploreUrl: String?
    var ruleSearch: SearchRuleDefinition?
    var ruleExplore: SearchRuleDefinition?
    var ruleBookInfo: BookInfoRuleDefinition?
    var ruleToc: TocRuleDefinition?
    var ruleContent: ContentRuleDefinition?

    var id: String {
        let explicitId = sourceId?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let explicitId, !explicitId.isEmpty { return explicitId }
        return normalizedSourceURL
    }

    var normalizedSourceURL: String {
        bookSourceUrl.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    var isEnabled: Bool { enabled ?? true }
    var groupName: String { bookSourceGroup?.nilIfBlank ?? "未分组" }
    var updateTimestamp: Int64 { lastUpdateTime ?? 0 }

    enum CodingKeys: String, CodingKey {
        case sourceId, bookSourceUrl, bookSourceName, bookSourceGroup, bookSourceType
        case enabled, enabledExplore, lastUpdateTime, header, loginUrl, searchUrl, exploreUrl
        case ruleSearch, ruleExplore, ruleBookInfo, ruleToc, ruleContent
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sourceId = try container.decodeIfPresent(String.self, forKey: .sourceId)
        bookSourceUrl = try container.decodeIfPresent(String.self, forKey: .bookSourceUrl) ?? ""
        bookSourceName = try container.decodeIfPresent(String.self, forKey: .bookSourceName) ?? ""
        bookSourceGroup = try container.decodeIfPresent(String.self, forKey: .bookSourceGroup)
        bookSourceType = (try? container.decode(Int.self, forKey: .bookSourceType))
            ?? (try? container.decode(String.self, forKey: .bookSourceType)).flatMap { Int($0) }
        enabled = try container.decodeFlexibleBool(forKey: .enabled)
        enabledExplore = try container.decodeFlexibleBool(forKey: .enabledExplore)
        lastUpdateTime = try container.decodeIfPresent(Int64.self, forKey: .lastUpdateTime)
        if let value = try? container.decode(String.self, forKey: .header) { header = value }
        else if let value = try? container.decode([String: String].self, forKey: .header) {
            header = String(data: try JSONEncoder().encode(value), encoding: .utf8)
        } else { header = nil }
        loginUrl = try container.decodeIfPresent(String.self, forKey: .loginUrl)
        searchUrl = try container.decodeIfPresent(String.self, forKey: .searchUrl)
        exploreUrl = try container.decodeIfPresent(String.self, forKey: .exploreUrl)
        ruleSearch = try container.decodeFlexibleRule(SearchRuleDefinition.self, forKey: .ruleSearch)
        ruleExplore = try container.decodeFlexibleRule(
            SearchRuleDefinition.self,
            forKey: .ruleExplore
        )
        ruleBookInfo = try container.decodeFlexibleRule(
            BookInfoRuleDefinition.self,
            forKey: .ruleBookInfo
        )
        ruleToc = try container.decodeFlexibleRule(TocRuleDefinition.self, forKey: .ruleToc)
        ruleContent = try container.decodeFlexibleRule(
            ContentRuleDefinition.self,
            forKey: .ruleContent
        )
    }
}

struct SourceExploreCategory: Hashable, Identifiable, Sendable {
    var title: String
    var address: String

    var id: String { "\(title)::\(address)" }
}

struct SearchRuleDefinition: Codable, Hashable, Sendable {
    var bookList: String?
    var name: String?
    var author: String?
    var intro: String?
    var kind: String?
    var lastChapter: String?
    var updateTime: String?
    var bookUrl: String?
    var coverUrl: String?
    var wordCount: String?
}

struct BookInfoRuleDefinition: Codable, Hashable, Sendable {
    var initRule: String?
    var name: String?
    var author: String?
    var intro: String?
    var kind: String?
    var lastChapter: String?
    var updateTime: String?
    var coverUrl: String?
    var tocUrl: String?
    var wordCount: String?

    enum CodingKeys: String, CodingKey {
        case initRule = "init"
        case name, author, intro, kind, lastChapter, updateTime, coverUrl, tocUrl, wordCount
    }
}

struct TocRuleDefinition: Codable, Hashable, Sendable {
    var chapterList: String?
    var chapterName: String?
    var chapterUrl: String?
    var isVolume: String?
    var isVip: String?
    var updateTime: String?
    var nextTocUrl: String?
}

struct ContentRuleDefinition: Codable, Hashable, Sendable {
    var content: String?
    var title: String?
    var nextContentUrl: String?
    var sourceRegex: String?
    var replaceRegex: String?
}

struct SearchBook: Hashable, Identifiable, Sendable {
    var sourceID: String
    var sourceName: String
    var name: String
    var author: String
    var intro: String
    var kind: String
    var lastChapter: String
    var updateTime: String
    var bookURL: String
    var coverURL: String
    var tocURL: String

    var id: String { "\(sourceID)::\(bookURL)" }
}

struct BookChapter: Codable, Hashable, Identifiable, Sendable {
    var title: String
    var url: String
    var index: Int
    var isVolume: Bool = false

    var id: String { "\(index)::\(url)" }
}

struct ImportedSources: Sendable {
    var sources: [BookSourceDefinition]
    var warnings: [String]
}

extension String {
    var nilIfBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

private extension KeyedDecodingContainer {
    func decodeFlexibleBool(forKey key: Key) throws -> Bool? {
        guard contains(key) else { return nil }
        if try decodeNil(forKey: key) { return nil }
        if let value = try? decode(Bool.self, forKey: key) { return value }
        if let value = try? decode(Int.self, forKey: key), value == 0 || value == 1 { return value == 1 }
        if let value = try? decode(String.self, forKey: key) {
            switch value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) {
            case "true", "1", "yes", "on": return true
            case "false", "0", "no", "off": return false
            default: break
            }
        }
        throw DecodingError.dataCorruptedError(forKey: key, in: self, debugDescription: "开关字段必须为 true/false 或 1/0")
    }
    func decodeFlexibleRule<T: Decodable>(
        _ type: T.Type,
        forKey key: Key
    ) throws -> T? {
        if let value = try? decodeIfPresent(T.self, forKey: key) { return value }
        guard let rawValue = try decodeIfPresent(String.self, forKey: key),
              let data = rawValue.data(using: .utf8) else {
            return nil
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
