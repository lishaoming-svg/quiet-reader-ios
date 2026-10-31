import Foundation
import SwiftSoup

/// The common HTML XPath subset used by book sources. This deliberately rejects
/// executable/unknown functions instead of returning an incorrect chapter list.
enum DeclarativeXPath {
    static func select(_ xpath: String, in element: Element) throws -> [Element] {
        var value = xpath
        if value.hasPrefix(".") { value.removeFirst() }
        var parts: [(String, Bool)] = [], token = "", nesting = 0, quote: Character?, descendant = true
        for character in value {
            if let active = quote {
                token.append(character); if character == active { quote = nil }; continue
            }
            if character == "'" || character == "\"" { quote = character; token.append(character); continue }
            if character == "[" { nesting += 1 }
            if character == "]" { nesting -= 1 }
            if character == "/", nesting == 0 {
                if !token.isEmpty { parts.append((token, descendant)); token = ""; descendant = false }
                else { descendant = true }
            } else { token.append(character) }
        }
        if !token.isEmpty { parts.append((token, descendant)) }
        guard nesting == 0, quote == nil, parts.count <= 32 else { throw SourceEngineError.requestFailed("XPath 规则格式不受支持。") }
        var nodes = [element]
        for (raw, deep) in parts {
            let tag = String(raw.prefix { $0 != "[" })
            guard tag.range(of: #"^[A-Za-z_][\w:.-]*$|^\*$"#, options: .regularExpression) != nil else {
                throw SourceEngineError.requestFailed("暂不支持此 XPath 轴或函数。")
            }
            let regex = try NSRegularExpression(pattern: #"\[([^\]]+)\]"#)
            let predicates = regex.matches(in: raw, range: NSRange(raw.startIndex..., in: raw)).compactMap { Range($0.range(at: 1), in: raw).map { String(raw[$0]) } }
            var selector = tag, index: Int?
            for predicate in predicates {
                if let number = Int(predicate), number > 0 { index = number - 1; continue }
                if predicate.range(of: #"^@[A-Za-z_][\w:-]*(\s*=\s*(['"]).*\2)?$"#, options: .regularExpression) != nil {
                    selector += "[" + predicate.dropFirst() + "]"; continue
                }
                let contains = try NSRegularExpression(pattern: #"^contains\(\s*@([\w:-]+)\s*,\s*(['"])(.*?)\2\s*\)$"#)
                if let match = contains.firstMatch(in: predicate, range: NSRange(predicate.startIndex..., in: predicate)),
                   let key = Range(match.range(at: 1), in: predicate), let val = Range(match.range(at: 3), in: predicate) {
                    selector += "[" + predicate[key] + "*=\"" + predicate[val].replacingOccurrences(of: "\"", with: "\\\"") + "\"]"; continue
                }
                throw SourceEngineError.requestFailed("暂不支持此 XPath 条件，请使用 CSS 或 JSONPath 规则。")
            }
            let css = selector
            nodes = try nodes.flatMap { parent -> [Element] in
                let selected = try parent.select(css).array().filter { deep || $0.parent() === parent }
                guard let index else { return selected }
                return selected.indices.contains(index) ? [selected[index]] : []
            }
        }
        return nodes
    }
}
