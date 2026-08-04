import SwiftUI

enum AppTheme {
    static let ink = Color(red: 0.08, green: 0.16, blue: 0.20)
    static let inkSoft = Color(red: 0.20, green: 0.29, blue: 0.31)
    static let paper = Color(red: 0.96, green: 0.93, blue: 0.85)
    static let paperLight = Color(red: 0.99, green: 0.98, blue: 0.94)
    static let vermilion = Color(red: 0.70, green: 0.18, blue: 0.12)
    static let ochre = Color(red: 0.74, green: 0.52, blue: 0.23)
    static let jade = Color(red: 0.18, green: 0.39, blue: 0.36)
    static let line = Color(red: 0.78, green: 0.73, blue: 0.62)

    static let titleFont = Font.system(size: 30, weight: .bold, design: .serif)
    static let sectionFont = Font.system(size: 20, weight: .semibold, design: .serif)
}

struct PaperBackground: View {
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                LinearGradient(
                    colors: [AppTheme.paperLight, AppTheme.paper],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Circle()
                    .fill(AppTheme.ochre.opacity(0.10))
                    .frame(width: proxy.size.width * 0.9)
                    .offset(x: proxy.size.width * 0.35, y: -proxy.size.height * 0.34)
                RoundedRectangle(cornerRadius: 80)
                    .fill(AppTheme.jade.opacity(0.08))
                    .frame(width: proxy.size.width * 0.75, height: proxy.size.height * 0.28)
                    .rotationEffect(.degrees(-14))
                    .offset(x: -proxy.size.width * 0.32, y: proxy.size.height * 0.40)
            }
        }
        .ignoresSafeArea()
    }
}

struct InkCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .background(AppTheme.paperLight.opacity(0.92), in: RoundedRectangle(cornerRadius: 18))
            .overlay {
                RoundedRectangle(cornerRadius: 18)
                    .stroke(AppTheme.line.opacity(0.65), lineWidth: 0.8)
            }
            .shadow(color: AppTheme.ink.opacity(0.08), radius: 14, y: 7)
    }
}

extension View {
    func inkCard() -> some View { modifier(InkCardModifier()) }
}
