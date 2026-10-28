import SwiftUI
import UIKit

struct BookCoverView: View {
    let urlString: String
    let title: String
    var width: CGFloat = 76
    var height: CGFloat = 108

    private var coverColor: Color {
        let colors: [Color] = [Color(red: 0.16, green: 0.28, blue: 0.37),
            Color(red: 0.55, green: 0.25, blue: 0.19), Color(red: 0.29, green: 0.39, blue: 0.30),
            Color(red: 0.44, green: 0.35, blue: 0.49), Color(red: 0.58, green: 0.43, blue: 0.23)]
        return colors[Int(title.unicodeScalars.reduce(UInt32(0)) { ($0 &* 31) &+ $1.value }) % colors.count]
    }
    var body: some View {
        Group {
            if let url = URL(string: urlString), url.isFileURL,
               let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image).resizable().scaledToFill()
            } else if let url = URL(string: urlString), ["https", "http"].contains(url.scheme ?? "") {
                AsyncImage(url: url) { phase in
                    if let image = phase.image { image.resizable().scaledToFill() }
                    else { placeholder }
                }
            } else { placeholder }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .overlay(alignment: .leading) {
            LinearGradient(colors: [.black.opacity(0.18), .white.opacity(0.1), .clear],
                           startPoint: .leading, endPoint: .trailing).frame(width: max(5, width * 0.05))
        }
        .shadow(color: .black.opacity(0.14), radius: 4, x: 1, y: 4)
        .accessibilityHidden(true)
    }
    private var placeholder: some View {
        ZStack {
            coverColor.gradient
            VStack(alignment: .leading, spacing: height * 0.07) {
                Text("墨阅藏书").font(.system(size: max(6, width * 0.065), weight: .medium)).tracking(2)
                    .foregroundStyle(.white.opacity(0.65))
                Rectangle().fill(.white.opacity(0.35)).frame(width: width * 0.25, height: 0.5)
                Text(title).font(.system(size: max(12, width * 0.16), weight: .medium, design: .serif))
                    .lineLimit(5).minimumScaleFactor(0.6).foregroundStyle(.white)
                Spacer(minLength: 2)
                Image(systemName: "book.closed").font(.system(size: max(8, width * 0.1)))
                    .foregroundStyle(.white.opacity(0.6))
            }.padding(.horizontal, width * 0.15).padding(.vertical, height * 0.12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
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
