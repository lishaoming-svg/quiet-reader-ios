import SwiftUI
import UIKit

enum ReaderMode: String, CaseIterable, Identifiable {
    case scroll
    case pageSlide
    case pageNone

    var id: String { rawValue }

    var title: String {
        switch self {
        case .scroll: "滚动"
        case .pageSlide: "滑动"
        case .pageNone: "无动画"
        }
    }

    var systemImage: String {
        switch self {
        case .scroll: "scroll"
        case .pageSlide: "rectangle.portrait.on.rectangle.portrait"
        case .pageNone: "rectangle.portrait"
        }
    }

    var usesPages: Bool { self != .scroll }
}

struct ReaderBlock: Identifiable, Equatable {
    let id: Int
    let locatorOffset: Int
    let text: String
}

struct ReaderPage: Identifiable, Equatable {
    let id: Int
    let locatorOffset: Int
    let text: String
}

enum ReaderDocumentBuilder {
    static func blocks(from content: String, maximumUTF16Length: Int = 520) -> [ReaderBlock] {
        guard !content.isEmpty else { return [] }

        var result: [ReaderBlock] = []
        var documentOffset = 0
        var identifier = 0

        for line in content.components(separatedBy: "\n") {
            let lineLength = (line as NSString).length
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

            if !trimmed.isEmpty {
                let nsLine = line as NSString
                var localOffset = 0
                while localOffset < lineLength {
                    let proposedLength = min(maximumUTF16Length, lineLength - localOffset)
                    let proposedRange = NSRange(location: localOffset, length: proposedLength)
                    let safeRange = nsLine.rangeOfComposedCharacterSequences(for: proposedRange)
                    let text = nsLine.substring(with: safeRange)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty {
                        result.append(
                            ReaderBlock(
                                id: identifier,
                                locatorOffset: documentOffset + safeRange.location,
                                text: text
                            )
                        )
                        identifier += 1
                    }
                    localOffset = NSMaxRange(safeRange)
                }
            }
            documentOffset += lineLength + 1
        }

        if result.isEmpty {
            return [ReaderBlock(id: 0, locatorOffset: 0, text: content)]
        }
        return result
    }

    static func excerpt(from content: String, locatorOffset: Int, length: Int = 90) -> String {
        let nsContent = content as NSString
        guard nsContent.length > 0 else { return "" }
        let start = min(max(0, locatorOffset), nsContent.length - 1)
        let proposed = NSRange(location: start, length: min(length, nsContent.length - start))
        let range = nsContent.rangeOfComposedCharacterSequences(for: proposed)
        return nsContent.substring(with: range)
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum ReaderPaginator {
    static func paginate(
        chapterTitle: String,
        content: String,
        size: CGSize,
        fontSize: CGFloat,
        lineSpacing: CGFloat,
        usesSerif: Bool
    ) -> [ReaderPage] {
        guard !content.isEmpty, size.width > 80, size.height > 120 else { return [] }

        let prefix = "\(chapterTitle)\n\n"
        let combined = prefix + content
        let prefixLength = (prefix as NSString).length
        let nsCombined = combined as NSString

        let systemFont = UIFont.systemFont(ofSize: fontSize)
        let font: UIFont
        if usesSerif,
           let descriptor = systemFont.fontDescriptor.withDesign(.serif) {
            font = UIFont(descriptor: descriptor, size: fontSize)
        } else {
            font = systemFont
        }

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = lineSpacing
        paragraphStyle.paragraphSpacing = max(5, lineSpacing * 0.7)
        paragraphStyle.lineBreakMode = .byWordWrapping

        let storage = NSTextStorage(
            string: combined,
            attributes: [
                .font: font,
                .foregroundColor: UIColor.label,
                .paragraphStyle: paragraphStyle
            ]
        )
        let layoutManager = NSLayoutManager()
        layoutManager.usesFontLeading = true
        storage.addLayoutManager(layoutManager)

        var pages: [ReaderPage] = []
        var lastGlyphEnd = 0

        while lastGlyphEnd < layoutManager.numberOfGlyphs {
            let container = NSTextContainer(size: size)
            container.lineFragmentPadding = 0
            container.maximumNumberOfLines = 0
            container.lineBreakMode = .byWordWrapping
            layoutManager.addTextContainer(container)
            layoutManager.ensureLayout(for: container)

            let glyphRange = layoutManager.glyphRange(for: container)
            guard glyphRange.length > 0, NSMaxRange(glyphRange) > lastGlyphEnd else { break }
            let characterRange = layoutManager.characterRange(
                forGlyphRange: glyphRange,
                actualGlyphRange: nil
            )
            guard characterRange.length > 0 else { break }

            pages.append(
                ReaderPage(
                    id: pages.count,
                    locatorOffset: max(0, characterRange.location - prefixLength),
                    text: nsCombined.substring(with: characterRange)
                )
            )
            lastGlyphEnd = NSMaxRange(glyphRange)
        }

        if pages.isEmpty {
            return [ReaderPage(id: 0, locatorOffset: 0, text: combined)]
        }
        return pages
    }

    static func pageIndex(for locatorOffset: Int, in pages: [ReaderPage]) -> Int {
        guard !pages.isEmpty else { return 0 }
        return pages.lastIndex(where: { $0.locatorOffset <= locatorOffset }) ?? 0
    }
}
