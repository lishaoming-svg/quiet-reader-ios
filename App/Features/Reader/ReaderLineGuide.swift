import SwiftUI

enum ReaderLineGuideGeometry {
    static func window(height: CGFloat, lineHeight: CGFloat, fraction: Double, measuredLine: CGRect? = nil) -> CGRect {
        let band = min(max(measuredLine.map { min(96, $0.height + 6) } ?? lineHeight, 18), max(18, height))
        let center = min(max(measuredLine?.midY ?? CGFloat(fraction) * height, band / 2), max(band / 2, height - band / 2))
        return CGRect(x: 0, y: center - band / 2, width: 1, height: band)
    }
    static func closestLine(_ lines: [CGRect], to y: CGFloat, viewport: CGRect) -> CGRect? {
        lines.filter { $0.width > 2 && $0.height >= 4 && $0.intersects(viewport) && viewport.contains(CGPoint(x: viewport.midX, y: $0.midY)) }
            .min { abs($0.midY - y) < abs($1.midY - y) }
    }
}

/// A reading ruler, independent of speech playback. Content remains selectable
/// and scrollable outside the handle; publisher colors/markup are untouched.
struct ReaderLineGuide: View {
    let paper: Color
    let lineHeight: CGFloat
    @AppStorage("reader.lineGuidePosition") private var fraction = 0.22
    @GestureState private var translation: CGFloat = 0
    @State private var measuredLine: CGRect?

    var body: some View {
        GeometryReader { geometry in
            let position = fraction + Double(translation / max(geometry.size.height, 1))
            let band = ReaderLineGuideGeometry.window(height: geometry.size.height, lineHeight: lineHeight, fraction: position, measuredLine: measuredLine)
            ZStack(alignment: .top) {
              if measuredLine != nil {
                Path { path in
                    path.addRect(CGRect(origin: .zero, size: geometry.size))
                    path.addRect(CGRect(x: 0, y: band.minY, width: geometry.size.width, height: band.height))
                }
                .fill(paper.opacity(0.76), style: FillStyle(eoFill: true))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                Capsule().fill(Color.white.opacity(0.025))
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.65), lineWidth: 1))
                    .shadow(color: .black.opacity(0.12), radius: 3, y: 2)
                    .frame(width: max(44, geometry.size.width - 48), height: band.height)
                    .offset(y: band.minY)
                    .gesture(DragGesture(minimumDistance: 3)
                        .updating($translation) { value, state, _ in state = value.translation.height }
                        .onEnded { value in fraction = min(0.95, max(0.05, fraction + Double(value.translation.height / max(geometry.size.height, 1)))) })
                    .accessibilityLabel("逐行导读阅读标尺")
                    .accessibilityHint("上下拖动标尺，或滚动正文，使当前行保持清晰。")
                    .accessibilityValue("已对齐文字行")
                    .accessibilityAdjustableAction { direction in
                        let delta = Double(lineHeight / max(geometry.size.height, 1))
                        switch direction {
                        case .increment: fraction = min(0.95, fraction + delta)
                        case .decrement: fraction = max(0.05, fraction - delta)
                        @unknown default: break
                        }
                    }
                    .accessibilityIdentifier("reader.lineGuideWindow")
              }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
            .background(ReaderLineGuideProbe(fraction: position) { measuredLine = $0 })
        }
    }
}
