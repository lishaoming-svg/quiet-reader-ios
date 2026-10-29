import Foundation
import ReadiumNavigator
import ReadiumShared

enum EPUBTextDirection: String, CaseIterable, Identifiable {
    case publisher, horizontal, vertical
    var id: String { rawValue }
    var title: String {
        switch self { case .publisher: "原书方向"; case .horizontal: "横排"; case .vertical: "竖排（从右向左）" }
    }
}

enum EPUBReadingLayout {
    static func preferences(publisherStyles: Bool, fontSizePercent: Double, scroll: Bool,
                            theme: String, direction: EPUBTextDirection = .publisher) -> EPUBPreferences {
        var result = EPUBPreferences()
        result.publisherStyles = publisherStyles
        result.fontSize = publisherStyles ? nil : fontSizePercent / 100
        result.scroll = scroll
        result.theme = Theme(rawValue: theme) ?? .sepia
        // A landscape iPad must not split a cover or illustration across two columns.
        result.columnCount = .one
        result.spread = .never
        result.fit = .page
        switch direction {
        case .publisher: break
        case .horizontal: result.verticalText = false; result.readingProgression = .ltr
        case .vertical: result.verticalText = true; result.readingProgression = .rtl
        }
        return result
    }

    // Only constrain media dimensions and fragmentation; keep publisher typography,
    // inline illustrations, chat bubbles, ruby and ornaments intact.
    static let imageStyles = """
    img, svg, video { max-width: 100% !important; max-height: 85vh !important; object-fit: contain; }
    img, svg, video, .ibooks-illustration { break-inside: avoid; page-break-inside: avoid; }
    .ibooks-illustration > img, .ibooks-illustration > svg { object-fit: contain; }
    """

    static var imageScript: String {
        let literal = String(data: try! JSONEncoder().encode(imageStyles), encoding: .utf8)!
        return """
        (() => {
          const install = () => {
            if (!document.getElementById('ibooks-image-fit')) {
              const style = document.createElement('style'); style.id = 'ibooks-image-fit';
              style.textContent = \(literal); (document.head || document.documentElement).appendChild(style);
            }
            document.querySelectorAll('img, svg').forEach(media => {
              const parent = media.parentElement;
              if (parent && parent !== document.body && parent.childElementCount === 1 && !parent.textContent.trim()) {
                parent.classList.add('ibooks-illustration');
              }
            });
          };
          if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', install, {once:true});
          else install();
        })();
        """
    }
}
