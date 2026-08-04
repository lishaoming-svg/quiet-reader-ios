import SwiftUI

struct BookCoverView: View {
    let urlString: String
    let title: String
    var width: CGFloat = 76
    var height: CGFloat = 108

    var body: some View {
        AsyncImage(url: URL(string: urlString)) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFill()
            default:
                ZStack {
                    LinearGradient(
                        colors: [AppTheme.ink, AppTheme.jade],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    Text(String(title.prefix(2)))
                        .font(.system(size: width * 0.25, weight: .bold, design: .serif))
                        .foregroundStyle(AppTheme.paperLight)
                        .multilineTextAlignment(.center)
                        .padding(6)
                }
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(.white.opacity(0.16))
                .frame(width: 3)
                .padding(.vertical, 5)
                .padding(.leading, 4)
        }
        .shadow(color: AppTheme.ink.opacity(0.22), radius: 8, y: 5)
    }
}

struct EmptyStateView: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(AppTheme.vermilion)
            Text(title)
                .font(AppTheme.sectionFont)
                .foregroundStyle(AppTheme.ink)
            Text(message)
                .font(.callout)
                .foregroundStyle(AppTheme.inkSoft)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 290)
        }
        .inkCard()
        .padding(24)
    }
}

struct InlineErrorView: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(AppTheme.vermilion)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppTheme.vermilion.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }
}
