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
        var lastError: Error?

        for attempt in 1...SourceRequestRetryPolicy.maximumAttemptCount {
            try Task.checkCancellation()
            do {
                return try await performFetch(url, source: source)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch {
                lastError = error
                guard attempt < SourceRequestRetryPolicy.maximumAttemptCount,
                      SourceRequestRetryPolicy.shouldRetry(error) else {
                    throw SourceRequestRetryPolicy.userFacingError(for: error)
                }
                try await Task.sleep(
                    nanoseconds: UInt64(attempt) * SourceRequestRetryPolicy.retryDelayNanoseconds
                )
            }
        }

        throw SourceRequestRetryPolicy.userFacingError(
            for: lastError ?? SourceEngineError.invalidResponse
        )
    }

    private func performFetch(
        _ url: URL,
        source: BookSourceDefinition
    ) async throws -> FetchedResource {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) "
                + "AppleWebKit/605.1.15 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
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

    func installCookies(_ cookies: [HTTPCookie], for sourceID: String) {
        for cookie in cookies {
            HTTPCookieStorage.shared.setCookie(cookie)
        }
        if let session = sessions.removeValue(forKey: sourceID) {
            session.invalidateAndCancel()
        }
    }

    private func session(for sourceID: String) -> URLSession {
        if let session = sessions[sourceID] { return session }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = true
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpCookieStorage = .shared
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 25
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

enum SourceRequestRetryPolicy {
    static let maximumAttemptCount = 3
    static let retryDelayNanoseconds: UInt64 = 400_000_000

    static func shouldRetry(_ error: Error) -> Bool {
        if let error = error as? URLError {
            return retryableURLCodes.contains(error.code)
        }
        if let sourceError = error as? SourceEngineError,
           case .httpStatus(let code) = sourceError {
            return retryableHTTPStatusCodes.contains(code)
        }
        return false
    }

    static func userFacingError(for error: Error) -> Error {
        guard let error = error as? URLError else { return error }
        switch error.code {
        case .timedOut:
            return SourceEngineError.requestTimedOut
        case .networkConnectionLost, .cannotConnectToHost, .resourceUnavailable:
            return SourceEngineError.connectionInterrupted
        case .notConnectedToInternet, .cannotFindHost, .dnsLookupFailed:
            return SourceEngineError.networkUnavailable
        case .cancelled:
            return CancellationError()
        default:
            return SourceEngineError.requestFailed(error.localizedDescription)
        }
    }

    private static let retryableURLCodes: Set<URLError.Code> = [
        .timedOut,
        .networkConnectionLost,
        .cannotConnectToHost,
        .cannotFindHost,
        .dnsLookupFailed,
        .notConnectedToInternet,
        .resourceUnavailable,
        .badServerResponse,
        .secureConnectionFailed
    ]

    private static let retryableHTTPStatusCodes: Set<Int> = [
        408, 425, 429, 500, 502, 503, 504
    ]
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
