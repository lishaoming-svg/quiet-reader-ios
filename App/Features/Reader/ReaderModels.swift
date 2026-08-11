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
    let isParagraphStart: Bool
}

struct ReaderPage: Identifiable, Equatable {
    let id: Int
    let locatorOffset: Int
    let text: String
    let showsChapterTitle: Bool
}

enum ReaderMargin: String, CaseIterable, Identifiable {
    case compact
    case comfortable
    case spacious

    var id: String { rawValue }

    var title: String {
        switch self {
        case .compact: "紧凑"
        case .comfortable: "舒适"
        case .spacious: "宽松"
        }
    }

    var horizontalPadding: CGFloat {
        switch self {
        case .compact: 18
        case .comfortable: 26
        case .spacious: 36
        }
    }

    var maximumContentWidth: CGFloat {
        switch self {
        case .compact: 720
        case .comfortable: 660
        case .spacious: 600
        }
    }
}

enum ReaderLayoutMetrics {
    static func contentWidth(containerWidth: CGFloat, margin: ReaderMargin) -> CGFloat {
        let available = max(1, containerWidth - margin.horizontalPadding * 2)
        return min(margin.maximumContentWidth, available)
    }
}

enum ReaderResumeResolver {
    static func chapterIndex(
        in chapters: [BookChapter],
        chapterURL: String?,
        fallbackIndex: Int?
    ) -> Int {
        guard !chapters.isEmpty else { return 0 }
        if let chapterURL,
           let matched = chapters.firstIndex(where: { $0.url == chapterURL }) {
            return matched
        }
        if let fallbackIndex, chapters.indices.contains(fallbackIndex) {
            return fallbackIndex
        }
        return 0
    }
}

enum ReaderLineBreakRules {
    static let forbiddenLineStart = Set("，。！？；：、）》】」』〉〕］）,.!?;:%％…—")
    static let forbiddenLineEnd = Set("《【「『〈〔［（")
}

enum ReaderTypography {
    static let letterSpacing: CGFloat = 0.18
    static let chapterHeadingHeight: CGFloat = 108
    static let pageVerticalPadding: CGFloat = 12
    static let pageHeaderHeight: CGFloat = 22
    static let pageHeaderBottomSpacing: CGFloat = 14
    static let pageFooterHeight: CGFloat = 22
    static let pageFooterTopSpacing: CGFloat = 12
    static let pageChromeHeight = pageVerticalPadding * 2
        + pageHeaderHeight
        + pageHeaderBottomSpacing
        + pageFooterHeight
        + pageFooterTopSpacing

    static func paragraphSpacing(for lineSpacing: CGFloat) -> CGFloat {
        min(max(lineSpacing * 0.68, 5), 8)
    }

    static func bodyUIFont(size: CGFloat, usesSerif: Bool) -> UIFont {
        if usesSerif {
            if let songti = UIFont(name: "STSongti-SC-Regular", size: size) {
                return songti
            }
            let fallback = UIFont.systemFont(ofSize: size, weight: .regular)
            if let descriptor = fallback.fontDescriptor.withDesign(.serif) {
                return UIFont(descriptor: descriptor, size: size)
            }
            return fallback
        }
        return UIFont(name: "PingFangSC-Regular", size: size)
            ?? UIFont.systemFont(ofSize: size, weight: .regular)
    }

    static func titleUIFont(size: CGFloat) -> UIFont {
        UIFont(name: "STSongti-SC-Bold", size: size)
            ?? UIFont.systemFont(ofSize: size, weight: .semibold)
    }

    static func titleSize(for bodySize: CGFloat) -> CGFloat {
        min(max(bodySize + 7, 25), 32)
    }

    static func pageRenderSafetyInset(font: UIFont, lineSpacing: CGFloat) -> CGFloat {
        ceil((font.lineHeight + max(lineSpacing, 0)) * 2)
    }
}

enum ReaderPageTextStyle {
    static func attributes(
        fontSize: CGFloat,
        lineSpacing: CGFloat,
        usesSerif: Bool,
        textColor: UIColor = .label
    ) -> [NSAttributedString.Key: Any] {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = lineSpacing
        paragraphStyle.alignment = .justified
        paragraphStyle.lineBreakMode = .byWordWrapping
        paragraphStyle.lineBreakStrategy = [.pushOut]

        return [
            .font: ReaderTypography.bodyUIFont(size: fontSize, usesSerif: usesSerif),
            .foregroundColor: textColor,
            .paragraphStyle: paragraphStyle,
            .kern: ReaderTypography.letterSpacing,
        ]
    }

    static func attributedString(
        text: String,
        fontSize: CGFloat,
        lineSpacing: CGFloat,
        usesSerif: Bool,
        textColor: UIColor = .label,
        highlightedText: String? = nil
    ) -> NSAttributedString {
        let result = NSMutableAttributedString(
            string: text,
            attributes: attributes(
                fontSize: fontSize,
                lineSpacing: lineSpacing,
                usesSerif: usesSerif,
                textColor: textColor
            )
        )
        if let highlightedText,
           !highlightedText.isEmpty {
            let range = (text as NSString).range(of: highlightedText)
            if range.location != NSNotFound {
                result.addAttributes(
                    [
                        .backgroundColor: UIColor.systemYellow.withAlphaComponent(0.22),
                        .foregroundColor: UIColor.label,
                    ],
                    range: range
                )
            }
        }
        return result
    }
}

struct ReaderPageTextView: UIViewRepresentable {
    let text: String
    let fontSize: CGFloat
    let lineSpacing: CGFloat
    let usesSerif: Bool
    let textColor: UIColor
    let highlightedText: String?

    init(
        text: String,
        fontSize: CGFloat,
        lineSpacing: CGFloat,
        usesSerif: Bool,
        textColor: UIColor,
        highlightedText: String? = nil
    ) {
        self.text = text
        self.fontSize = fontSize
        self.lineSpacing = lineSpacing
        self.usesSerif = usesSerif
        self.textColor = textColor
        self.highlightedText = highlightedText
    }

    func makeUIView(context: Context) -> ReaderPageTextCanvas {
        ReaderPageTextCanvas()
    }

    func updateUIView(_ uiView: ReaderPageTextCanvas, context: Context) {
        uiView.setAttributedText(
            ReaderPageTextStyle.attributedString(
                text: text,
                fontSize: fontSize,
                lineSpacing: lineSpacing,
                usesSerif: usesSerif,
                textColor: textColor,
                highlightedText: highlightedText
            )
        )
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: ReaderPageTextCanvas,
        context: Context
    ) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        return CGSize(width: width, height: uiView.measuredHeight(for: width))
    }
}

final class ReaderPageTextCanvas: UIView {
    private let textStorage = NSTextStorage()
    private let layoutManager = NSLayoutManager()
    private let textContainer = NSTextContainer(size: .zero)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
        clipsToBounds = true
        isAccessibilityElement = true
        accessibilityTraits = .staticText

        layoutManager.usesFontLeading = true
        textContainer.lineFragmentPadding = 0
        textContainer.maximumNumberOfLines = 0
        textContainer.lineBreakMode = .byWordWrapping
        textStorage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(textContainer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setAttributedText(_ text: NSAttributedString) {
        guard !textStorage.isEqual(to: text) else { return }
        textStorage.setAttributedString(text)
        accessibilityLabel = text.string
        invalidateIntrinsicContentSize()
        setNeedsDisplay()
    }

    func measuredHeight(for width: CGFloat) -> CGFloat {
        guard width > 0, textStorage.length > 0 else { return 0 }
        textContainer.size = CGSize(width: width, height: 100_000)
        layoutManager.ensureLayout(for: textContainer)
        return ceil(layoutManager.usedRect(for: textContainer).height)
    }

    func renderedLines(for width: CGFloat) -> [String] {
        guard width > 0, textStorage.length > 0 else { return [] }
        textContainer.size = CGSize(width: width, height: 100_000)
        layoutManager.ensureLayout(for: textContainer)
        let nsText = textStorage.string as NSString
        let glyphRange = layoutManager.glyphRange(for: textContainer)
        var lines: [String] = []
        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) {
            _, _, _, lineGlyphRange, _ in
            let characterRange = self.layoutManager.characterRange(
                forGlyphRange: lineGlyphRange,
                actualGlyphRange: nil
            )
            let line = nsText.substring(with: characterRange)
                .trimmingCharacters(in: .newlines)
            if !line.isEmpty { lines.append(line) }
        }
        return lines
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = CGSize(width: max(bounds.width, 0), height: max(bounds.height, 0))
        guard textContainer.size != size else { return }
        textContainer.size = size
        layoutManager.ensureLayout(for: textContainer)
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        super.draw(rect)
        guard bounds.width > 0, bounds.height > 0 else { return }
        let glyphRange = layoutManager.glyphRange(for: textContainer)
        layoutManager.drawBackground(forGlyphRange: glyphRange, at: .zero)
        layoutManager.drawGlyphs(forGlyphRange: glyphRange, at: .zero)
    }
}

struct ReaderDisplayDocument {
    let text: String
    fileprivate let spans: [ReaderLocatorSpan]
    fileprivate let originalLength: Int

    func locatorOffset(forDisplayedUTF16Offset rawOffset: Int) -> Int {
        guard !spans.isEmpty else { return 0 }
        let displayLength = (text as NSString).length
        let offset = min(max(rawOffset, 0), displayLength)
        if offset == displayLength { return originalLength }

        if let span = spans.first(where: { NSLocationInRange(offset, $0.displayRange) }) {
            if span.tracksCharacters {
                return min(originalLength, span.originalOffset + offset - span.displayRange.location)
            }
            return min(originalLength, span.originalOffset)
        }
        return min(
            originalLength,
            spans.first(where: { $0.displayRange.location > offset })?.originalOffset ?? originalLength
        )
    }
}

fileprivate struct ReaderLocatorSpan {
    let displayRange: NSRange
    let originalOffset: Int
    let tracksCharacters: Bool
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
                                text: text,
                                isParagraphStart: localOffset == 0
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
            return [ReaderBlock(id: 0, locatorOffset: 0, text: content, isParagraphStart: true)]
        }
        return result
    }

    static func displayDocument(
        from content: String,
        paragraphIndent: Bool
    ) -> ReaderDisplayDocument {
        let nsContent = content as NSString
        guard nsContent.length > 0 else {
            return ReaderDisplayDocument(text: "", spans: [], originalLength: 0)
        }

        var result = ""
        var spans: [ReaderLocatorSpan] = []
        var originalLineOffset = 0
        var hasParagraph = false
        let visibleCharacters = CharacterSet.whitespacesAndNewlines.inverted

        for line in content.components(separatedBy: "\n") {
            let nsLine = line as NSString
            let lineLength = nsLine.length
            let first = nsLine.rangeOfCharacter(from: visibleCharacters)
            if first.location != NSNotFound {
                let last = nsLine.rangeOfCharacter(from: visibleCharacters, options: .backwards)
                let paragraphRange = NSRange(
                    location: first.location,
                    length: NSMaxRange(last) - first.location
                )
                let originalParagraphOffset = originalLineOffset + paragraphRange.location

                if hasParagraph {
                    let separatorOffset = (result as NSString).length
                    result.append("\n")
                    spans.append(
                        ReaderLocatorSpan(
                            displayRange: NSRange(location: separatorOffset, length: 1),
                            originalOffset: originalParagraphOffset,
                            tracksCharacters: false
                        )
                    )
                }

                if paragraphIndent {
                    let indentOffset = (result as NSString).length
                    result.append("　　")
                    spans.append(
                        ReaderLocatorSpan(
                            displayRange: NSRange(location: indentOffset, length: 2),
                            originalOffset: originalParagraphOffset,
                            tracksCharacters: false
                        )
                    )
                }

                let textOffset = (result as NSString).length
                result.append(nsLine.substring(with: paragraphRange))
                spans.append(
                    ReaderLocatorSpan(
                        displayRange: NSRange(location: textOffset, length: paragraphRange.length),
                        originalOffset: originalParagraphOffset,
                        tracksCharacters: true
                    )
                )
                hasParagraph = true
            }
            originalLineOffset += lineLength + 1
        }

        return ReaderDisplayDocument(
            text: result,
            spans: spans,
            originalLength: nsContent.length
        )
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
        usesSerif: Bool,
        paragraphIndent: Bool = true,
        firstPageTitleHeight: CGFloat = ReaderTypography.chapterHeadingHeight
    ) -> [ReaderPage] {
        guard !content.isEmpty, size.width > 80, size.height > 120 else { return [] }

        _ = chapterTitle
        let document = ReaderDocumentBuilder.displayDocument(
            from: content,
            paragraphIndent: paragraphIndent
        )
        guard !document.text.isEmpty else { return [] }
        let nsDisplayText = document.text as NSString
        let font = ReaderTypography.bodyUIFont(size: fontSize, usesSerif: usesSerif)
        let renderSafetyInset = ReaderTypography.pageRenderSafetyInset(
            font: font,
            lineSpacing: lineSpacing
        )

        let storage = NSTextStorage(
            string: document.text,
            attributes: ReaderPageTextStyle.attributes(
                fontSize: fontSize,
                lineSpacing: lineSpacing,
                usesSerif: usesSerif
            )
        )
        let layoutManager = NSLayoutManager()
        layoutManager.usesFontLeading = true
        storage.addLayoutManager(layoutManager)

        var pages: [ReaderPage] = []
        var lastGlyphEnd = 0

        while lastGlyphEnd < layoutManager.numberOfGlyphs {
            let isFirstPage = pages.isEmpty
            let pageBodyHeight = isFirstPage
                ? max(80, size.height - firstPageTitleHeight)
                : size.height
            let minimumTextHeight = ceil(font.lineHeight * 2 + max(lineSpacing, 0))
            let availableHeight = max(
                minimumTextHeight,
                pageBodyHeight - renderSafetyInset
            )
            let container = NSTextContainer(
                size: CGSize(width: size.width, height: availableHeight)
            )
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
                    locatorOffset: document.locatorOffset(
                        forDisplayedUTF16Offset: characterRange.location
                    ),
                    text: nsDisplayText.substring(with: characterRange),
                    showsChapterTitle: isFirstPage
                )
            )
            lastGlyphEnd = NSMaxRange(glyphRange)
        }

        if pages.isEmpty {
            return [
                ReaderPage(
                    id: 0,
                    locatorOffset: 0,
                    text: document.text,
                    showsChapterTitle: true
                )
            ]
        }
        return pages
    }

    static func pageIndex(for locatorOffset: Int, in pages: [ReaderPage]) -> Int {
        guard !pages.isEmpty else { return 0 }
        return pages.lastIndex(where: { $0.locatorOffset <= locatorOffset }) ?? 0
    }
}
