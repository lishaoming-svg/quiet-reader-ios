import CoreFoundation
import Foundation

struct FetchedResource: Sendable {
    var data: Data
    var finalURL: URL
    var contentType: String

    var text: String {
        TextDecoder.decode(data, contentType: contentType)
    }
}

actor SourceHTTPClient {
    static let shared = SourceHTTPClient()

    private var sessions: [String: URLSession] = [:]

    func fetch(_ url: URL, source: BookSourceDefinition) async throws -> FetchedResource {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("QuietReader/0.1", forHTTPHeaderField: "User-Agent")
        parseHeaders(source.header).forEach { request.setValue($1, forHTTPHeaderField: $0) }

        let (data, response) = try await session(for: source.id).data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SourceEngineError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw SourceEngineError.httpStatus(httpResponse.statusCode)
        }
        guard data.count <= 25_000_000 else {
            throw SourceEngineError.responseTooLarge
        }

        return FetchedResource(
            data: data,
            finalURL: httpResponse.url ?? url,
            contentType: httpResponse.value(forHTTPHeaderField: "Content-Type") ?? ""
        )
    }

    private func session(for sourceID: String) -> URLSession {
        if let session = sessions[sourceID] { return session }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = true
        configuration.httpCookieAcceptPolicy = .always
        configuration.requestCachePolicy = .reloadRevalidatingCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 45
        let session = URLSession(configuration: configuration)
        sessions[sourceID] = session
        return session
    }

    private func parseHeaders(_ rawValue: String?) -> [String: String] {
        guard let rawValue = rawValue?.nilIfBlank,
              let data = rawValue.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return object.reduce(into: [:]) { result, item in
            result[item.key] = String(describing: item.value)
        }
    }
}

enum TextDecoder {
    static func decode(_ data: Data, contentType: String) -> String {
        let charset = contentType
            .lowercased()
            .components(separatedBy: "charset=")
            .dropFirst()
            .first?
            .components(separatedBy: ";")
            .first?
            .trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))

        if let charset, let encoding = encoding(for: charset),
           let value = String(data: data, encoding: encoding) {
            return value
        }
        if let value = String(data: data, encoding: .utf8) { return value }
        if let value = String(data: data, encoding: gb18030) { return value }
        return String(decoding: data, as: UTF8.self)
    }

    private static func encoding(for charset: String) -> String.Encoding? {
        switch charset.replacingOccurrences(of: "_", with: "-") {
        case "utf-8", "utf8": .utf8
        case "gbk", "gb2312", "gb18030": gb18030
        case "iso-8859-1", "latin1": .isoLatin1
        case "windows-1252": .windowsCP1252
        default: nil
        }
    }

    private static var gb18030: String.Encoding {
        let value = CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        )
        return String.Encoding(rawValue: value)
    }
}
