import Foundation

enum JSONPath {
    private enum Token {
        case key(String)
        case index(Int)
        case wildcard
    }

    static func values(at path: String, in root: Any) throws -> [Any] {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "$" || trimmed == "@" { return [root] }
        let tokens = try tokenize(trimmed)
        return tokens.reduce([root]) { current, token in
            current.flatMap { apply(token, to: $0) }
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
                } else if let value = Int(raw) {
                    tokens.append(.index(value))
                } else {
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

    private static func apply(_ token: Token, to value: Any) -> [Any] {
        switch token {
        case .key(let key):
            if let dictionary = value as? [String: Any], let result = dictionary[key] {
                return [result]
            }
        case .index(let index):
            if let array = value as? [Any], array.indices.contains(index) {
                return [array[index]]
            }
        case .wildcard:
            if let array = value as? [Any] { return array }
            if let dictionary = value as? [String: Any] { return Array(dictionary.values) }
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
