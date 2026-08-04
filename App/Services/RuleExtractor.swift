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
        for fallback in rule.components(separatedBy: "||") {
            let result = try extract(RuleSpec(fallback), from: node)
            if let value = result.nilIfBlank {
                return asURL ? URLTemplateRenderer.absoluteURL(value, relativeTo: node.baseURL) : value
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

    private func selectedElements(_ spec: RuleSpec, from element: Element) throws -> [Element] {
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

    init(_ rawRule: String) {
        let parts = rawRule.components(separatedBy: "##")
        var extraction = parts.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        replacePattern = parts.count > 1 ? parts[1] : nil
        replacement = parts.count > 2 ? parts[2] : ""

        if extraction.hasPrefix("@css:") {
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

        (selector, selectionIndex) = Self.normalizeSelector(selector)
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
