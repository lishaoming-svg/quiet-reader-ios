import CoreFoundation
import Foundation

/// Declarative Legado URL options. No JavaScript, WebView or native bridge runs.
struct LegadoRequest {
    static let fragmentPrefix = "ibooks-request="
    var url: URL
    var method = "GET"
    var body: Data?
    var headers: [String: String] = [:]

    static func split(_ value: String) -> (String, String?) {
        guard let range = value.range(of: #",\s*\{"#, options: .regularExpression) else { return (value, nil) }
        let brace = value[range].firstIndex(of: "{")!
        return (String(value[..<range.lowerBound]), String(value[brace...]))
    }
    static func options(_ text: String?) throws -> [String: Any] {
        guard let text else { return [:] }
        guard let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw SourceEngineError.requestFailed("书源请求参数不是有效 JSON。")
        }
        if object["webView"] as? Bool == true || object["js"] != nil || object["webJs"] != nil {
            throw SourceEngineError.requestFailed("此请求依赖网页脚本；当前书源引擎尚不支持该脚本规则。")
        }
        return object
    }
    static func encoding(_ charset: String?) throws -> String.Encoding {
        switch charset?.lowercased().replacingOccurrences(of: "-", with: "") ?? "utf8" {
        case "utf8": return .utf8
        case "gbk", "gb2312", "gb18030":
            return .init(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        case "big5": return .init(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.big5.rawValue)))
        case "utf16", "unicode": return .utf16
        default: throw SourceEngineError.requestFailed("此书源使用了尚不支持的请求编码：\(charset ?? "")")
        }
    }
    static func encodedKeyword(_ key: String, options: [String: Any]) throws -> String {
        let encoding = try encoding(options["charset"] as? String)
        guard let data = key.data(using: encoding) else { throw SourceEngineError.invalidResponse }
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~".utf8)
        return data.map { allowed.contains($0) ? String(UnicodeScalar($0)) : String(format: "%%%02X", $0) }.joined()
    }
    static func parse(_ address: URL) throws -> LegadoRequest {
        guard let fragment = URLComponents(url: address, resolvingAgainstBaseURL: true)?.fragment,
              fragment.hasPrefix(fragmentPrefix) else { return LegadoRequest(url: address) }
        let token = String(fragment.dropFirst(fragmentPrefix.count))
        guard let data = Data(base64Encoded: token), let text = String(data: data, encoding: .utf8) else { throw SourceEngineError.invalidResponse }
        let values = try options(text)
        var components = URLComponents(url: address, resolvingAgainstBaseURL: true)!
        components.fragment = nil
        guard let url = components.url else { throw SourceEngineError.invalidURL(address.absoluteString) }
        let method = (values["method"] as? String ?? "GET").uppercased()
        guard ["GET", "POST", "HEAD"].contains(method) else {
            throw SourceEngineError.requestFailed("不支持的请求方法：\(method)")
        }
        var headers: [String: String] = [:]
        var rawHeaders = values["headers"] ?? values["header"]
        if let string = rawHeaders as? String { rawHeaders = try JSONSerialization.jsonObject(with: Data(string.utf8)) }
        for (key, value) in rawHeaders as? [String: Any] ?? [:] {
            guard !key.contains("\r"), !key.contains("\n") else { continue }
            let value = String(describing: value)
            if !value.contains("\r") && !value.contains("\n") { headers[key] = value }
        }
        let body: Data?
        if let string = values["body"] as? String { body = string.data(using: try encoding(values["charset"] as? String)) }
        else if let value = values["body"], !(value is NSNull) {
            body = try JSONSerialization.data(withJSONObject: value)
            headers["Content-Type"] = headers["Content-Type"] ?? "application/json; charset=utf-8"
        } else { body = nil }
        if body != nil && headers["Content-Type"] == nil { headers["Content-Type"] = "application/x-www-form-urlencoded; charset=" + (values["charset"] as? String ?? "utf-8") }
        return LegadoRequest(url: url, method: method, body: body, headers: headers)
    }
}

/// A small integer expression parser for {{(page-1)*20}} pagination templates.
/// It accepts arithmetic only and rejects script identifiers and overflow.
struct PaginationExpression {
    private var chars: [Character]
    private var cursor = 0
    private var depth = 0
    init(_ value: String, page: Int) throws {
        let text = value.replacingOccurrences(of: "page", with: String(page)).filter { !$0.isWhitespace }
        guard text.count <= 80, !text.isEmpty, text.allSatisfy({ $0.isNumber || "+-*/%()".contains($0) }) else { throw SourceEngineError.requestFailed("不支持此书源的分页脚本表达式。") }
        chars = Array(text)
    }
    mutating func value() throws -> Int {
        let value = try expression()
        guard cursor == chars.count else { throw SourceEngineError.invalidResponse }
        return value
    }
    private mutating func expression() throws -> Int {
        var result = try term()
        while cursor < chars.count, chars[cursor] == "+" || chars[cursor] == "-" {
            let op = chars[cursor]; cursor += 1
            let right = try term()
            let calculation = op == "+" ? result.addingReportingOverflow(right) : result.subtractingReportingOverflow(right)
            guard !calculation.overflow else { throw SourceEngineError.invalidResponse }; result = calculation.partialValue
        }
        return result
    }
    private mutating func term() throws -> Int {
        var result = try factor()
        while cursor < chars.count, "*/%".contains(chars[cursor]) {
            let op = chars[cursor]; cursor += 1; let right = try factor()
            if op == "*" {
                let calculation = result.multipliedReportingOverflow(by: right)
                guard !calculation.overflow else { throw SourceEngineError.invalidResponse }; result = calculation.partialValue
            } else {
                guard right != 0, !(result == Int.min && right == -1) else { throw SourceEngineError.invalidResponse }
                result = op == "/" ? result / right : result % right
            }
        }
        return result
    }
    private mutating func factor() throws -> Int {
        depth += 1; defer { depth -= 1 }
        guard depth < 16, cursor < chars.count else { throw SourceEngineError.invalidResponse }
        if chars[cursor] == "-" { cursor += 1; let number = try factor(); guard number != Int.min else { throw SourceEngineError.invalidResponse }; return -number }
        if chars[cursor] == "+" { cursor += 1; return try factor() }
        if chars[cursor] == "(" {
            cursor += 1; let number = try expression()
            guard cursor < chars.count, chars[cursor] == ")" else { throw SourceEngineError.invalidResponse }
            cursor += 1; return number
        }
        let start = cursor
        while cursor < chars.count, chars[cursor].isNumber { cursor += 1 }
        guard let number = Int(String(chars[start..<cursor])) else { throw SourceEngineError.invalidResponse }
        return number
    }
}
