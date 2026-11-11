import UIKit

enum ReedenThemePreview {
    static func png(for package: ReedenThemePackage) -> Data {
        let bounds = CGRect(x: 0, y: 0, width: 720, height: 600)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        var seen = Set<Data>()
        let panels = Array(package.panels.lazy.filter { panel in
            guard panel.palette == nil, let image = panel.image,
                  let png = UIImage(cgImage: image).pngData() else { return true }
            return seen.insert(png).inserted
        }.prefix(4))

        return UIGraphicsImageRenderer(size: bounds.size, format: format).pngData { renderer in
            let ink = UIColor(red: 0.13, green: 0.15, blue: 0.18, alpha: 1)
            renderer.cgContext.setFillColor(UIColor(white: 0.96, alpha: 1).cgColor)
            renderer.cgContext.fill(bounds)
            draw(package.name, at: CGRect(x: 28, y: 23, width: 664, height: 39), size: 30, color: ink, weight: .semibold)
            draw(package.creator ?? "未署名", at: CGRect(x: 28, y: 66, width: 664, height: 32), size: 20, color: ink)

            let caption: String
            switch package.kind {
            case .theme: caption = "Reeden 配色预览"
            case .gallery: caption = "Reeden 封面图集"
            case .privateTheme: caption = "Reeden 素材预览 · 配色配置已加密"
            }
            draw(caption, at: CGRect(x: 28, y: 556, width: 664, height: 28), size: 17, color: ink)

            guard !panels.isEmpty else {
                draw("包内没有可预览的图片", at: CGRect(x: 28, y: 137, width: 664, height: 38), size: 25, color: ink)
                return
            }
            let columns = min(2, panels.count)
            let rows = (panels.count + columns - 1) / columns
            let width = columns == 1 ? 664.0 : 324.0
            let height = rows == 1 ? 426.0 : 205.0
            for (index, panel) in panels.enumerated() {
                let frame = CGRect(x: 28 + Double(index % columns) * (width + 16),
                                   y: 111 + Double(index / columns) * (height + 16), width: width, height: height)
                drawPanel(panel, in: frame, context: renderer.cgContext)
            }
        }
    }

    private static func drawPanel(_ panel: ReedenThemePackage.Panel, in frame: CGRect, context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }
        UIBezierPath(roundedRect: frame, cornerRadius: 16).addClip()
        let background = color(panel.palette?.backgroundColor, fallback: panel.isDark ? .black : .white)
        context.setFillColor(background.cgColor)
        context.fill(frame)

        if let image = panel.image {
            let scale = panel.palette == nil
                ? min(frame.width / CGFloat(image.width), frame.height / CGFloat(image.height))
                : max(frame.width / CGFloat(image.width), frame.height / CGFloat(image.height))
            let width = CGFloat(image.width) * scale, height = CGFloat(image.height) * scale
            UIImage(cgImage: image).draw(in: CGRect(x: frame.midX - width / 2, y: frame.midY - height / 2,
                                                   width: width, height: height))
        }
        if let palette = panel.palette {
            let foreground = color(palette.foregroundColor, fallback: panel.isDark ? .white : .black)
            let card = CGRect(x: frame.minX + 16, y: frame.maxY - 106, width: frame.width - 32, height: 90)
            color(palette.cardColor, fallback: background).setFill()
            UIBezierPath(roundedRect: card, cornerRadius: 12).fill()
            draw(panel.title + "书架", at: card.insetBy(dx: 14, dy: 10), size: 22, color: foreground, weight: .semibold)
            let accent = color(palette.accentColor ?? palette.primaryColor, fallback: .systemBlue)
            accent.setFill()
            UIBezierPath(roundedRect: CGRect(x: card.minX + 14, y: card.maxY - 28, width: 76, height: 8),
                         cornerRadius: 4).fill()
        }
    }

    private static func draw(_ text: String, at frame: CGRect, size: CGFloat, color: UIColor, weight: UIFont.Weight = .regular) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        (text as NSString).draw(with: frame, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: [
            .font: UIFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: paragraph
        ], context: nil)
    }

    static func color(_ value: String?, fallback: UIColor) -> UIColor {
        guard let value, value.hasPrefix("#"), [7, 9].contains(value.count),
              let argb = UInt32(value.dropFirst(), radix: 16) else { return fallback }
        let alpha = value.count == 9 ? CGFloat((argb >> 24) & 255) / 255 : 1
        return UIColor(red: CGFloat((argb >> 16) & 255) / 255, green: CGFloat((argb >> 8) & 255) / 255,
                       blue: CGFloat(argb & 255) / 255, alpha: alpha)
    }
}
