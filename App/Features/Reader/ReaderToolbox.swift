import SwiftUI

struct ReaderToolbox: View {
    let contents: () -> Void
    let search: () -> Void
    let settings: () -> Void
    let direction: () -> Void
    let scroll: () -> Void
    let bookmark: () -> Void
    let shareURL: URL?
    @State private var brightness = Double(UIScreen.main.brightness)
    var body: some View {
        HStack(alignment: .bottom, spacing: 12) {
            VStack(spacing: 6) {
                row("目录", icon: "list.bullet", action: contents)
                row("在图书中搜索", icon: "magnifyingglass", action: search)
                row("主题与设置", icon: "textformat.size", action: settings)
                HStack(spacing: 6) {
                    if let shareURL { ShareLink(item: shareURL) { Image(systemName: "square.and.arrow.up").frame(maxWidth: .infinity, minHeight: 48) }.background(.regularMaterial, in: Capsule()).accessibilityLabel("分享原书") }
                    icon("文字方向", "textformat.abc", action: direction)
                    icon("切换上下滚动", "scroll", action: scroll)
                    icon("添加书签", "bookmark", action: bookmark)
                }.font(.title3.weight(.semibold))
            }
            VStack(spacing: 8) {
                Image(systemName: "sun.max.fill").font(.caption)
                Slider(value: $brightness, in: 0.05...1).rotationEffect(.degrees(-90)).frame(width: 140, height: 40).frame(width: 44, height: 140)
                    .accessibilityLabel("屏幕亮度")
                Image(systemName: "sun.min").font(.caption)
            }.padding(.vertical, 18).frame(width: 54).background(.regularMaterial, in: Capsule())
        }.frame(maxWidth: 380).onChange(of: brightness) { _, value in UIScreen.main.brightness = value }
    }
    private func row(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack { Text(title); Spacer(); Image(systemName: icon) }.font(.headline).padding(.horizontal, 20).frame(minHeight: 52)
        }.background(.regularMaterial, in: Capsule())
    }
    private func icon(_ title: String, _ image: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: image).frame(maxWidth: .infinity, minHeight: 48) }
            .background(.regularMaterial, in: Capsule()).accessibilityLabel(title)
    }
}
