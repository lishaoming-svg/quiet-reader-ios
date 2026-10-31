import Foundation

enum JSONPath {
    private enum Token {
        case key(String)
        case index(Int)
        case wildcard
        case recursive(String)
        case slice(Int?, Int?)
        case union([Int])
    }

    static func values(at path: String, in root: Any) throws -> [Any] {
        var trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("@json:") { trimmed.removeFirst(6) }
        else if trimmed.lowercased().hasPrefix("json:") { trimmed.removeFirst(5) }
        if trimmed.isEmpty || trimmed == "$" || trimmed == "@" { return [root] }
        let tokens = try tokenize(trimmed)
        return try tokens.reduce([root]) { current, token in
            try current.flatMap { try apply(token, to: $0) }
        }
    }

    static func string(at path: String, in root: Any) throws -> String {
        let values = try values(at: path, in: root)
        if values.count == 1 { return stringify(values[0]) }
        return values.map(stringify).filter { !$0.isEmpty }.joined(separator: "、")
    }

    private static func tokenize(_ path: String) throws -> [Token] {
        let characters = Array(path)
        var index = 0
        var tokens: [Token] = []

        if characters.first == "$" || characters.first == "@" { index += 1 }
        while index < characters.count {
            if characters[index] == "." {
                index += 1
                if index < characters.count, characters[index] == "." {
                    index += 1; let start = index
                    while index < characters.count, characters[index] != ".", characters[index] != "[" { index += 1 }
                    guard start < index else { throw JSONPathError.invalidPath(path) }
                    tokens.append(.recursive(String(characters[start..<index]))); continue
                }
                if index < characters.count, characters[index] == "*" {
                    tokens.append(.wildcard)
                    index += 1
                    continue
                }
                let start = index
                while index < characters.count,
                      characters[index] != ".",
                      characters[index] != "[" {
                    index += 1
                }
                guard start < index else { throw JSONPathError.invalidPath(path) }
                tokens.append(.key(String(characters[start..<index])))
                continue
            }

            if characters[index] == "[" {
                guard let close = characters[(index + 1)...].firstIndex(of: "]") else {
                    throw JSONPathError.invalidPath(path)
                }
                let raw = String(characters[(index + 1)..<close])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if raw == "*" {
                    tokens.append(.wildcard)
                } else if raw.contains(":"), !raw.contains("'") && !raw.contains("\"") {
                    let parts = raw.split(separator: ":", omittingEmptySubsequences: false)
                    guard parts.count == 2, parts.allSatisfy({ $0.isEmpty || Int($0) != nil }) else { throw JSONPathError.invalidPath(path) }
                    tokens.append(.slice(Int(parts[0]), Int(parts[1])))
                } else if raw.contains(","), !raw.contains("'") && !raw.contains("\"") {
                    let values = raw.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                    guard values.count == raw.split(separator: ",").count else { throw JSONPathError.invalidPath(path) }
                    tokens.append(.union(values))
                } else if let value = Int(raw) {
                    tokens.append(.index(value))
                } else {
                    guard !raw.hasPrefix("?(") else { throw JSONPathError.invalidPath(path) }
                    let key = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                    guard !key.isEmpty else { throw JSONPathError.invalidPath(path) }
                    tokens.append(.key(key))
                }
                index = close + 1
                continue
            }

            let start = index
            while index < characters.count,
                  characters[index] != ".",
                  characters[index] != "[" {
                index += 1
            }
            guard start < index else { throw JSONPathError.invalidPath(path) }
            tokens.append(.key(String(characters[start..<index])))
        }
        return tokens
    }

    private static func apply(_ token: Token, to value: Any) throws -> [Any] {
        switch token {
        case .key(let key):
            if let dictionary = value as? [String: Any], let result = dictionary[key] {
                return [result]
            }
        case .index(let index):
            if let array = value as? [Any] {
                let actual = index < 0 ? array.count + index : index
                if array.indices.contains(actual) { return [array[actual]] }
            }
        case .wildcard:
            if let array = value as? [Any] { return array }
            if let dictionary = value as? [String: Any] { return Array(dictionary.values) }
        case .recursive(let key):
            var result: [Any] = [], pending: [Any] = [value], visited = 0
            while let item = pending.popLast() {
                visited += 1
                guard visited <= 100_000 else { throw JSONPathError.invalidPath("递归路径结果过大，请缩小选择范围") }
                if let dictionary = item as? [String: Any] {
                    if key == "*" { result += dictionary.values }
                    else if let found = dictionary[key] { result.append(found) }
                    pending += dictionary.keys.sorted().reversed().compactMap { dictionary[$0] }
                } else if let array = item as? [Any] { pending += array.reversed() }
            }
            return result
        case .slice(let start, let end):
            guard let array = value as? [Any] else { return [] }
            let low = min(array.count, max(0, (start ?? 0) < 0 ? array.count + (start ?? 0) : (start ?? 0)))
            let high = min(array.count, max(0, (end ?? array.count) < 0 ? array.count + (end ?? array.count) : (end ?? array.count)))
            return low < high ? Array(array[low..<high]) : []
        case .union(let indices):
            guard let array = value as? [Any] else { return [] }
            return indices.compactMap { index in let actual = index < 0 ? array.count + index : index; return array.indices.contains(actual) ? array[actual] : nil }
        }
        return []
    }

    private static func stringify(_ value: Any) -> String {
        if value is NSNull { return "" }
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        if let array = value as? [Any] {
            return array.map(stringify).filter { !$0.isEmpty }.joined(separator: "、")
        }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
           let string = String(data: data, encoding: .utf8) {
            return string
        }
        return String(describing: value)
    }
}

enum JSONPathError: LocalizedError {
    case invalidPath(String)

    var errorDescription: String? {
        switch self {
        case .invalidPath(let path): "JSONPath 格式不正确：\(path)"
        }
    }
}
