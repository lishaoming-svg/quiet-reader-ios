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
            let selector = spec.selector.nilIfBlank ?? "*"
            return try element.select(selector).array().map { .html($0, baseURL) }
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
            let target: Element?
            if spec.selector.nilIfBlank == nil {
                target = element
            } else {
                target = try element.select(spec.selector).first()
            }
            guard let target else { return "" }
            switch spec.attribute.lowercased() {
            case "html": value = try target.html()
            case "outerhtml": value = try target.outerHtml()
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
    var replacePattern: String?
    var replacement: String

    init(_ rawRule: String) {
        let parts = rawRule.components(separatedBy: "##")
        let extraction = parts.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        replacePattern = parts.count > 1 ? parts[1] : nil
        replacement = parts.count > 2 ? parts[2] : ""

        if let split = extraction.range(of: "@", options: .backwards) {
            selector = String(extraction[..<split.lowerBound])
            attribute = String(extraction[split.upperBound...])
        } else {
            selector = extraction
            attribute = "text"
        }
    }
}
