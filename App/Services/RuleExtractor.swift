import Foundation
import SwiftSoup

enum RuleNode {
    case html(Element, URL)
    case json(Any, URL)
    case text(String, URL)

    var baseURL: URL {
        switch self {
        case .html(_, let url), .json(_, let url), .text(_, let url): url
        }
    }
}

struct RuleExtractor {
    func root(from resource: FetchedResource) throws -> RuleNode {
        let text = resource.text
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = trimmed.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) {
            return .json(object, resource.finalURL)
        }
        if trimmed.contains("<") && trimmed.contains(">") {
            let document = try SwiftSoup.parse(text, resource.finalURL.absoluteString)
            return .html(document, resource.finalURL)
        }
        return .text(text, resource.finalURL)
    }

    func list(_ rule: String?, in root: RuleNode) throws -> [RuleNode] {
        guard let rule = rule?.nilIfBlank else { return [root] }
        try validate(rule)
        if rule.contains("||") {
            for fallback in rule.components(separatedBy: "||") {
                let values = try list(fallback, in: root)
                if !values.isEmpty { return values }
            }
            return []
        }
        if rule.hasPrefix("-") { return try list(String(rule.dropFirst()), in: root).reversed() }
        let spec = RuleSpec(rule)
        switch root {
        case .html(let element, let baseURL):
            let elements = try selectedElements(spec, from: element)
            return elements.map { .html($0, baseURL) }
        case .json(let object, let baseURL):
            return try JSONPath.values(at: spec.selector, in: object).map { .json($0, baseURL) }
        case .text:
            return [root]
        }
    }

    func string(_ rule: String?, in node: RuleNode, asURL: Bool = false) throws -> String {
        guard let rule = rule?.nilIfBlank else { return "" }
        try validate(rule)
        if rule.contains("&&") { return try rule.components(separatedBy: "&&").map { try string($0, in: node, asURL: false) }.joined() }
        for fallback in rule.components(separatedBy: "||") {
            let result = fallback.contains("{{")
                ? try interpolate(fallback, from: node)
                : try extract(RuleSpec(fallback), from: node)
            if let value = result.nilIfBlank {
                return asURL ? URLTemplateRenderer.absoluteURL(value, relativeTo: node.baseURL) : value
            }
        }
        return ""
    }

    /// Content extraction keeps the selected DOM instead of flattening paragraphs,
    /// inline colors, alignment, ruby, tables and pictures into a single string.
    func chapterHTML(_ rule: String?, in node: RuleNode) throws -> String {
        try validate(rule ?? "")
        guard case .html(let element, _) = node else { return try string(rule, in: node) }
        for fallback in (rule?.nilIfBlank ?? "@text").components(separatedBy: "||") {
            if fallback.contains("{{") { return try string(fallback, in: node) }
            let spec = RuleSpec(fallback)
            let targets = try selectedElements(spec, from: element)
            if !targets.isEmpty {
                let html = try targets.map { try $0.outerHtml() }.joined(separator: "\n")
                return applyReplacement(html, pattern: spec.replacePattern, replacement: spec.replacement)
            }
        }
        return ""
    }

    private func extract(_ spec: RuleSpec, from node: RuleNode) throws -> String {
        let value: String
        switch node {
        case .html(let element, _):
            let target = try selectedElements(spec, from: element).first
            guard let target else { return "" }
            switch spec.attribute.lowercased() {
            case "html": value = try target.html()
            case "outerhtml", "all": value = try target.outerHtml()
            case "owntext": value = try target.ownText()
            case "textnodes": value = try target.text()
            case "text", "": value = try target.text()
            default: value = try target.attr(spec.attribute)
            }
        case .json(let object, _):
            value = try JSONPath.string(at: spec.selector, in: object)
        case .text(let text, _):
            value = text
        }
        return applyReplacement(value, pattern: spec.replacePattern, replacement: spec.replacement)
    }

    private func interpolate(_ template: String, from node: RuleNode) throws -> String {
        let regex = try NSRegularExpression(pattern: #"\{\{([^{}]+)\}\}"#)
        var result = template
        let matches = regex.matches(
            in: template,
            range: NSRange(template.startIndex..., in: template)
        )

        for match in matches.reversed() {
            guard let expressionRange = Range(match.range(at: 1), in: template),
                  let fullRange = Range(match.range(at: 0), in: result) else {
                continue
            }
            let value = try extract(RuleSpec(String(template[expressionRange])), from: node)
            result.replaceSubrange(fullRange, with: value)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func selectedElements(_ spec: RuleSpec, from element: Element) throws -> [Element] {
        if spec.selector.hasPrefix("/") || spec.selector.hasPrefix("./") {
            return try DeclarativeXPath.select(spec.selector, in: element)
        }
        if spec.steps.count > 1 {
            var current = [element]
            for step in spec.steps {
                current = try current.flatMap { parent -> [Element] in
                    let matches = try parent.select(step.selector).array()
                    guard let index = step.index else { return matches }
                    let actual = index < 0 ? matches.count + index : index
                    return matches.indices.contains(actual) ? [matches[actual]] : []
                }
            }
            return current
        }
        let elements: [Element]
        if spec.selector.nilIfBlank == nil {
            elements = [element]
        } else {
            elements = try element.select(spec.selector).array()
        }

        guard let index = spec.selectionIndex else { return elements }
        let resolvedIndex = index >= 0 ? index : elements.count + index
        guard elements.indices.contains(resolvedIndex) else { return [] }
        return [elements[resolvedIndex]]
    }
    private func validate(_ rule: String) throws {
        if rule.lowercased().contains("@js:") || rule.lowercased().contains("<js>") {
            throw SourceEngineError.requestFailed("此书源依赖尚未支持的脚本规则。可使用声明式 CSS、JSONPath、基础 XPath 或原生 LOFTER 书源。")
        }
    }

    private func applyReplacement(_ value: String, pattern: String?, replacement: String) -> String {
        guard let pattern = pattern?.nilIfBlank,
              let regex = try? NSRegularExpression(pattern: pattern) else {
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let range = NSRange(value.startIndex..., in: value)
        return regex.stringByReplacingMatches(
            in: value,
            range: range,
            withTemplate: replacement
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct RuleSpec {
    var selector: String
    var attribute: String
    var selectionIndex: Int?
    var replacePattern: String?
    var replacement: String
    var steps: [(selector: String, index: Int?)] = []

    init(_ rawRule: String) {
        let parts = rawRule.components(separatedBy: "##")
        var extraction = parts.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        replacePattern = parts.count > 1 ? parts[1] : nil
        replacement = parts.count > 2 ? parts[2] : ""

        if extraction.lowercased().hasPrefix("@xpath:") { extraction.removeFirst(7) }
        else if extraction.lowercased().hasPrefix("xpath:") { extraction.removeFirst(6) }
        else if extraction.lowercased().hasPrefix("@json:") { extraction.removeFirst(6) }
        else if extraction.lowercased().hasPrefix("json:") { extraction.removeFirst(5) }
        else if extraction.hasPrefix("@css:") {
            extraction.removeFirst("@css:".count)
        } else if extraction.hasPrefix("css:") {
            extraction.removeFirst("css:".count)
        }

        let tokens = extraction.components(separatedBy: "@")
        if tokens.count > 1, let last = tokens.last, Self.isAttribute(last) {
            selector = tokens.dropLast().joined(separator: "@")
            attribute = Self.normalizedAttribute(last)
        } else if Self.isAttribute(extraction) {
            selector = ""
            attribute = Self.normalizedAttribute(extraction)
        } else {
            selector = extraction
            attribute = "text"
        }

        if !selector.hasPrefix("/"), !selector.hasPrefix("./"), !selector.hasPrefix("$") {
            steps = selector.components(separatedBy: "@").map {
                let parsed = Self.normalizeSelector($0)
                return (parsed.0, parsed.1)
            }
        }
        if selector.hasPrefix("/") || selector.hasPrefix("./") {
            if selector.hasSuffix("/text()") { selector.removeLast(7) }
            while selector.hasSuffix("/") { selector.removeLast() }
            if selector == "." { selector = "" }
            selectionIndex = nil
        } else { (selector, selectionIndex) = Self.normalizeSelector(selector) }
    }

    private static func isAttribute(_ value: String) -> Bool {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let known = ["text", "owntext", "textnodes", "html", "outerhtml", "all",
                     "href", "src", "_src", "onclick", "title", "value"]
        return known.contains(normalized)
            || normalized.hasPrefix("data-")
            || normalized.hasPrefix("aria-")
    }

    private static func normalizedAttribute(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizeSelector(_ rawValue: String) -> (String, Int?) {
        var rawValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawValue.isEmpty, !rawValue.hasPrefix("$") else { return (rawValue, nil) }

        var index: Int?
        if let match = rawValue.range(
            of: #"\.(-?\d+)$"#,
            options: .regularExpression
        ) {
            index = Int(rawValue[match].dropFirst())
            rawValue.removeSubrange(match)
        }

        let selector = rawValue
            .components(separatedBy: "@")
            .map(normalizeLegacySelectorSegment)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return (selector, index)
    }

    private static func normalizeLegacySelectorSegment(_ value: String) -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("class.") {
            return value.dropFirst("class.".count)
                .split(whereSeparator: \.isWhitespace)
                .map { ".\($0)" }
                .joined()
        }
        if value.hasPrefix("id.") {
            return "#" + String(value.dropFirst("id.".count))
        }
        if value.hasPrefix("tag.") {
            return String(value.dropFirst("tag.".count))
        }
        if value.hasPrefix("text.") {
            let text = value.dropFirst("text.".count)
            return "*:containsOwn(\(text))"
        }
        return value
    }
}
