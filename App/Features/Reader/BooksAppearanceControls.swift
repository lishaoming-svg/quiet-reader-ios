import SwiftUI
import UIKit

enum BooksFont: String, CaseIterable, Identifiable {
    case publisher, pingfang, songti, kaiti, yuanti
    var id: String { rawValue }
    var title: String { switch self { case .publisher: "原书字体"; case .pingfang: "苹方"; case .songti: "宋体"; case .kaiti: "楷体"; case .yuanti: "圆体" } }
    var family: String { switch self { case .publisher: ""; case .pingfang: "PingFang SC"; case .songti: "Songti SC"; case .kaiti: "Kaiti SC"; case .yuanti: "Yuanti SC" } }
    var postscript: String { switch self { case .publisher: ""; case .pingfang: "PingFangSC-Light"; case .songti: "STSongti-SC-Regular"; case .kaiti: "STKaitiSC-Regular"; case .yuanti: "STYuanti-SC-Light" } }
}

enum BooksThemePreset: String, CaseIterable, Identifiable {
    case original, quiet, paper, bold, calm, focus
    var id: String { rawValue }
    var title: String { switch self { case .original: "原始"; case .quiet: "安静"; case .paper: "纸张"; case .bold: "大胆"; case .calm: "平静"; case .focus: "专注" } }
    var paper: String { switch self { case .quiet: "night"; case .paper: "warm"; case .calm: "green"; default: "white" } }
    var color: Color { switch self { case .quiet: Color(white: 0.1); case .paper: Color(red: 242/255, green: 227/255, blue: 200/255); case .calm: Color(red: 0.87, green: 0.92, blue: 0.86); default: .white } }
    var font: BooksFont { self == .paper ? .songti : .pingfang }
    var fontSize: Double { self == .bold ? 22 : self == .focus ? 21 : 19 }
    var lineSpacing: Double { self == .focus ? 14 : 9 }
}

/// Shared local-document controls. Source-specific preferences remain separate.
struct BooksAppearanceControls: View {
    var epub = false
    @AppStorage("local.reader.preset") private var preset = ""
    @AppStorage("reader.family") private var family = BooksFont.pingfang.rawValue
    @AppStorage("reader.fontSize") private var fontSize = 19.0
    @AppStorage("reader.lineSpacing") private var lineSpacing = 9.0
    @AppStorage("reader.paper") private var paper = "warm"
    @AppStorage("reader.serif") private var serif = false
    @AppStorage("reader.bold") private var bold = false
    @AppStorage("reader.importedFont") private var importedFont = ""
    @AppStorage("epub.theme") private var epubTheme = "sepia"
    @AppStorage("epub.fontSize") private var epubSize = 100.0
    @AppStorage("epub.publisherStyles") private var publisher = true
    @State private var brightness = Double(UIScreen.main.brightness)
    var body: some View {
        Section {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                ForEach(BooksThemePreset.allCases) { item in
                    Button {
                        preset = item.rawValue
                        family = epub && item == .original ? BooksFont.publisher.rawValue : item.font.rawValue
                        importedFont = ""; bold = item == .bold
                        if epub {
                            epubTheme = item.paper == "night" ? "dark" : item.paper == "warm" ? "sepia" : "light"
                            epubSize = item.fontSize / 19 * 100; publisher = item == .original
                        } else { paper = item.paper; fontSize = item.fontSize; lineSpacing = item.lineSpacing; serif = item.font == .songti }
                    } label: {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Aa").font(.system(size: 26, weight: item == .bold ? .bold : .regular, design: item == .paper ? .serif : .default))
                            HStack { Text(item.title).font(.caption.weight(.semibold)); Spacer(minLength: 0); if preset == item.rawValue { Image(systemName: "checkmark.circle.fill") } }
                        }.padding(12).frame(maxWidth: .infinity, minHeight: 88).foregroundStyle(item == .quiet ? .white : .black)
                            .background(item.color, in: RoundedRectangle(cornerRadius: 12))
                            .overlay { RoundedRectangle(cornerRadius: 12).stroke(preset == item.rawValue ? Color.primary : Color(.separator), lineWidth: preset == item.rawValue ? 2 : 0.5) }
                    }.buttonStyle(.plain).accessibilityLabel("\(item.title)主题").accessibilityIdentifier("theme.\(item.rawValue)")
                }
            }.padding(.vertical, 6)
            HStack {
                Image(systemName: "sun.min")
                Slider(value: $brightness, in: 0.05...1).accessibilityLabel("屏幕亮度")
                Image(systemName: "sun.max")
            }.onChange(of: brightness) { _, value in UIScreen.main.brightness = value }
        }
        Section("字体") {
            Picker("字体", selection: $family) {
                ForEach(BooksFont.allCases.filter { epub || $0 != .publisher }) { font in Text(font.title).tag(font.rawValue) }
            }.onChange(of: family) { _, value in
                importedFont = ""
                if epub { publisher = value == BooksFont.publisher.rawValue }
                else { serif = value == BooksFont.songti.rawValue }
            }
            if !epub && !ImportedFontStore.fonts.isEmpty {
                Picker("导入的字体", selection: $importedFont) {
                    Text("不使用").tag("")
                    ForEach(ImportedFontStore.fonts) { font in Text(font.name).tag(font.postScriptName) }
                }
            }
            Toggle("粗体文字", isOn: $bold)
        }
        .onAppear {
            if !epub, UserDefaults.standard.object(forKey: "reader.family") == nil, serif { family = BooksFont.songti.rawValue }
        }
    }
}
