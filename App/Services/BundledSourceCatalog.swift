import Foundation

struct BundledSourceCatalogIndex: Decodable, Sendable {
    var version: Int
    var sourceCount: Int
    var shardCount: Int
    var entries: [BundledSourceCatalogEntry]
}

struct BundledSourceCatalogEntry: Decodable, Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var group: String
    var url: String
    var host: String
    var sourceType: Int
    var status: BundledSourceCompatibility
    var issues: [BundledSourceIssue]
    var shard: Int
    var lastUpdateTime: Int64
    var origin: String

    var isImportable: Bool { status != .unsupported }
    var requiresLogin: Bool { issues.contains(.login) }
}

enum BundledSourceCompatibility: String, Decodable, Hashable, Sendable {
    case compatible
    case partial
    case unsupported

    var title: String {
        switch self {
        case .compatible: "兼容"
        case .partial: "部分兼容"
        case .unsupported: "暂不支持"
        }
    }
}

enum BundledSourceIssue: String, Decodable, Hashable, Sendable {
    case invalidUrl
    case javascript
    case login
    case missingSearch
    case nonText
    case post
    case xpath

    var title: String {
        switch self {
        case .invalidUrl: "地址无效"
        case .javascript: "含 JavaScript"
        case .login: "可能需要登录"
        case .missingSearch: "缺少搜索规则"
        case .nonText: "非小说类型"
        case .post: "含复杂 POST"
        case .xpath: "含 XPath"
        }
    }
}

actor BundledSourceCatalog {
    static let shared = BundledSourceCatalog()

    private let bundle: Bundle
    private var cachedIndex: BundledSourceCatalogIndex?

    init(bundle: Bundle = .main) {
        self.bundle = bundle
    }

    func loadIndex() throws -> BundledSourceCatalogIndex {
        if let cachedIndex { return cachedIndex }
        let data = try loadCompressedResource(named: "source-catalog-index")
        let index = try JSONDecoder().decode(BundledSourceCatalogIndex.self, from: data)
        guard index.entries.count == index.sourceCount else {
            throw BundledSourceCatalogError.invalidIndex
        }
        cachedIndex = index
        return index
    }

    func loadDefinitions(ids: Set<String>) throws -> [BookSourceDefinition] {
        guard !ids.isEmpty else { return [] }
        let index = try loadIndex()
        let entries = index.entries.filter { ids.contains($0.id) }
        let shards = Set(entries.map(\.shard))
        var definitionsByID: [String: BookSourceDefinition] = [:]

        for shard in shards {
            let definitions = try loadShard(shard)
            for definition in definitions where ids.contains(definition.id) {
                definitionsByID[definition.id] = definition
            }
        }
        return entries.compactMap { definitionsByID[$0.id] }
    }

    private func loadShard(_ number: Int) throws -> [BookSourceDefinition] {
        let name = String(format: "source-catalog-%02d", number)
        let data = try loadCompressedResource(named: name)
        return try JSONDecoder().decode([BookSourceDefinition].self, from: data)
    }

    private func loadCompressedResource(named name: String) throws -> Data {
        guard let url = bundle.url(forResource: name, withExtension: "zlib") else {
            throw BundledSourceCatalogError.missingResource(name)
        }
        let compressed = try Data(contentsOf: url, options: .mappedIfSafe)
        do {
            return try (compressed as NSData).decompressed(using: .zlib) as Data
        } catch {
            throw BundledSourceCatalogError.decompressionFailed(name)
        }
    }
}

enum BundledSourceCatalogError: LocalizedError {
    case missingResource(String)
    case decompressionFailed(String)
    case invalidIndex

    var errorDescription: String? {
        switch self {
        case .missingResource(let name): "内置源库资源缺失：\(name)"
        case .decompressionFailed(let name): "内置源库解压失败：\(name)"
        case .invalidIndex: "内置源库索引不完整"
        }
    }
}
