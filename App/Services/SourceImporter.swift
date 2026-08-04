import Foundation

struct SourceImporter {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func importText(_ input: String) async throws -> ImportedSources {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw SourceImportError.emptyInput
        }

        if let url = URL(string: text), Self.isAllowedRemoteURL(url) {
            let data = try await fetch(url)
            return try await decodeAndResolve(data)
        }

        guard let data = text.data(using: .utf8) else {
            throw SourceImportError.invalidEncoding
        }
        return try await decodeAndResolve(data)
    }

    func importFile(_ url: URL) async throws -> ImportedSources {
        let canAccess = url.startAccessingSecurityScopedResource()
        defer {
            if canAccess { url.stopAccessingSecurityScopedResource() }
        }
        return try await decodeAndResolve(Data(contentsOf: url))
    }

    func decodeSources(_ data: Data) throws -> ImportedSources {
        let object = try JSONSerialization.jsonObject(with: data)
        let decoder = JSONDecoder()
        let sources: [BookSourceDefinition]

        if object is [[String: Any]] {
            sources = try decoder.decode([BookSourceDefinition].self, from: data)
        } else if object is [String: Any] {
            sources = [try decoder.decode(BookSourceDefinition.self, from: data)]
        } else {
            throw SourceImportError.unsupportedRoot
        }

        return try validateAndDeduplicate(sources)
    }

    private func decodeAndResolve(_ data: Data) async throws -> ImportedSources {
        let object = try JSONSerialization.jsonObject(with: data)
        if let subscription = object as? [String: Any],
           let sourceURLs = subscription["sourceUrls"] as? [String] {
            guard !sourceURLs.isEmpty else {
                throw SourceImportError.emptySubscription
            }

            var combined: [BookSourceDefinition] = []
            var warnings: [String] = []
            for value in sourceURLs {
                guard let url = URL(string: value), Self.isAllowedRemoteURL(url) else {
                    warnings.append("已忽略无效订阅地址：\(value)")
                    continue
                }
                do {
                    let data = try await fetch(url)
                    let result = try await decodeAndResolve(data)
                    combined.append(contentsOf: result.sources)
                    warnings.append(contentsOf: result.warnings)
                } catch {
                    warnings.append("订阅加载失败：\(url.host ?? value)")
                }
            }
            let validated = try validateAndDeduplicate(combined)
            return ImportedSources(
                sources: validated.sources,
                warnings: warnings + validated.warnings
            )
        }
        return try decodeSources(data)
    }

    private func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 25
        request.setValue("QuietReader/0.1", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw SourceImportError.remoteRequestFailed
        }
        guard data.count <= 5_000_000 else {
            throw SourceImportError.payloadTooLarge
        }
        return data
    }

    private func validateAndDeduplicate(
        _ sources: [BookSourceDefinition]
    ) throws -> ImportedSources {
        guard !sources.isEmpty else {
            throw SourceImportError.noSources
        }

        var warnings: [String] = []
        var unique: [String: BookSourceDefinition] = [:]
        var order: [String] = []

        for var source in sources {
            source.bookSourceName = source.bookSourceName
                .trimmingCharacters(in: .whitespacesAndNewlines)
            source.bookSourceUrl = source.bookSourceUrl
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard !source.bookSourceName.isEmpty else {
                warnings.append("已忽略一个没有名称的书源")
                continue
            }
            guard let url = URL(string: source.bookSourceUrl), Self.isAllowedRemoteURL(url) else {
                warnings.append("已忽略地址无效的书源：\(source.bookSourceName)")
                continue
            }
            if source.searchUrl?.nilIfBlank == nil || source.ruleSearch == nil {
                warnings.append("\(source.bookSourceName) 没有搜索规则，将不会参与搜索")
            }

            if unique[source.id] == nil {
                order.append(source.id)
            } else {
                warnings.append("检测到重复书源，已保留最后一项：\(source.bookSourceName)")
            }
            unique[source.id] = source
        }

        let result = order.compactMap { unique[$0] }
        guard !result.isEmpty else {
            throw SourceImportError.noValidSources
        }
        return ImportedSources(sources: result, warnings: warnings)
    }

    private static func isAllowedRemoteURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }
}

enum SourceImportError: LocalizedError {
    case emptyInput
    case invalidEncoding
    case unsupportedRoot
    case emptySubscription
    case remoteRequestFailed
    case payloadTooLarge
    case noSources
    case noValidSources

    var errorDescription: String? {
        switch self {
        case .emptyInput: "请粘贴书源 JSON 或远程地址"
        case .invalidEncoding: "书源文本不是有效的 UTF-8"
        case .unsupportedRoot: "书源必须是 JSON 对象或数组"
        case .emptySubscription: "订阅中没有书源地址"
        case .remoteRequestFailed: "远程书源请求失败"
        case .payloadTooLarge: "书源文件超过 5 MB 限制"
        case .noSources: "书源列表为空"
        case .noValidSources: "没有可导入的有效书源"
        }
    }
}
