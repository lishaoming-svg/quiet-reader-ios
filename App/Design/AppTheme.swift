import SwiftUI

enum AppTheme {
    static let ink = Color.primary
    static let inkSoft = Color.secondary
    static let paper = Color(.systemGroupedBackground)
    static let paperLight = Color(.systemBackground)
    static let vermilion = Color.orange
    static let ochre = Color.orange
    static let jade = Color.secondary
    static let line = Color(.separator)
    static let titleFont = Font.system(size: 34, weight: .bold)
    static let sectionFont = Font.system(size: 22, weight: .bold)
}

struct PaperBackground: View {
    var body: some View { AppTheme.paperLight.ignoresSafeArea() }
}
struct InkCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.padding(16)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }
}
extension View {
    func inkCard() -> some View { modifier(InkCardModifier()) }
}
