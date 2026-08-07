import Foundation
import SwiftSoup

enum ReadableContentFormatter {
    private static let lineBreakMarker = "\u{E000}"
    private static let paragraphAwareBundledSourceIDs: Set<String> = [
        "archive.0e12f30e88f0744dea7fc074",
        "archive.c1c2db7490999e4d53855df9",
        "archive.1e94ef54501668df21018322"
    ]

    private static let breakRegex = try? NSRegularExpression(
        pattern: #"(?i)<br\s*/?>"#
    )
    private static let blockEndRegex = try? NSRegularExpression(
        pattern: #"(?i)</(?:p|div|li|blockquote|h[1-6]|section|article|tr|pre)>"#
    )
    private static let horizontalWhitespaceRegex = try? NSRegularExpression(
        pattern: #"[ \t\u00A0\u2007\u202F\u3000]+"#
    )

    static func plainText(from value: String) -> String {
        guard !value.isEmpty else { return value }
        let extracted: String
        if value.contains("<"), value.contains(">"), let htmlText = textFromHTML(value) {
            extracted = htmlText
        } else {
            extracted = value
        }
        return normalizeLines(extracted)
    }

    static func removingMatches(in value: String, rule rawRule: String) -> String {
        let pattern = normalizedReplacementPattern(rawRule)
        guard !pattern.isEmpty,
              let regex = try? NSRegularExpression(pattern: pattern) else {
            return normalizeLines(value)
        }
        let result = regex.stringByReplacingMatches(
            in: value,
            range: NSRange(value.startIndex..., in: value),
            withTemplate: ""
        )
        return normalizeLines(result)
    }

    static func shouldRefreshLegacyCache(_ value: String, sourceID: String) -> Bool {
        guard paragraphAwareBundledSourceIDs.contains(sourceID) else { return false }
        let length = (value as NSString).length
        let paragraphCount = value.split(whereSeparator: \.isNewline).count
        if paragraphCount <= 1 { return length >= 320 }
        return length >= 800 && paragraphCount <= 5
    }

    private static func textFromHTML(_ value: String) -> String? {
        var markedHTML = value
        if let breakRegex {
            markedHTML = replace(markedHTML, using: breakRegex, with: lineBreakMarker)
        }
        if let blockEndRegex {
            markedHTML = replace(
                markedHTML,
                using: blockEndRegex,
                with: "\(lineBreakMarker)$0"
            )
        }

        guard let document = try? SwiftSoup.parseBodyFragment(markedHTML),
              let body = document.body() else {
            return nil
        }
        if let unwanted = try? body.select(
            "script, style, noscript, template, #center_tip, .readinline, .contentadv, .ad"
        ) {
            try? unwanted.remove()
        }
        guard let text = try? body.text() else { return nil }
        return text.replacingOccurrences(of: lineBreakMarker, with: "\n")
    }

    private static func normalizeLines(_ value: String) -> String {
        value
            .precomposedStringWithCanonicalMapping
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
            .compactMap { rawLine in
                let line: String
                if let horizontalWhitespaceRegex {
                    line = replace(rawLine, using: horizontalWhitespaceRegex, with: " ")
                } else {
                    line = rawLine
                }
                return line.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
            }
            .joined(separator: "\n")
    }

    private static func normalizedReplacementPattern(_ value: String) -> String {
        var pattern = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if pattern.hasPrefix("##") { pattern.removeFirst(2) }
        return pattern
    }

    private static func replace(
        _ value: String,
        using regex: NSRegularExpression,
        with replacement: String
    ) -> String {
        regex.stringByReplacingMatches(
            in: value,
            range: NSRange(value.startIndex..., in: value),
            withTemplate: replacement
        )
    }
}
