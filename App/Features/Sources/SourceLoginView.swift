import SwiftUI
import WebKit

struct SourceLoginView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var loginSession = SourceLoginSession()
    @State private var isSyncing = false

    let source: BookSourceDefinition
    let onComplete: () -> Void

    init(source: BookSourceDefinition, onComplete: @escaping () -> Void = {}) {
        self.source = source
        self.onComplete = onComplete
    }

    private var loginURL: URL? {
        guard let value = source.loginUrl?.nilIfBlank else { return nil }
        return try? URLTemplateRenderer.render(value, relativeTo: source.bookSourceUrl)
    }

    var body: some View {
        NavigationStack {
            Group {
                if let loginURL {
                    SourceLoginWebView(
                        url: loginURL,
                        sourceID: source.id,
                        loginSession: loginSession
                    )
                } else {
                    EmptyStateView(
                        icon: "person.crop.circle.badge.exclamationmark",
                        title: "没有登录入口",
                        message: "这个书源没有提供网页登录地址。"
                    )
                }
            }
            .navigationTitle("登录 · \(source.bookSourceName)")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                Text("登录或注册由书源网站处理。完成后点右上角“完成”，墨阅会同步该站点的登录 Cookie。")
                    .font(.caption)
                    .foregroundStyle(AppTheme.inkSoft)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(AppTheme.paperLight)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSyncing ? "同步中…" : "完成") {
                        finishLogin()
                    }
                    .disabled(isSyncing || loginURL == nil)
                }
            }
        }
    }

    private func finishLogin() {
        isSyncing = true
        Task {
            await loginSession.syncCookies(sourceID: source.id, host: loginURL?.host)
            await MainActor.run {
                isSyncing = false
                onComplete()
                dismiss()
            }
        }
    }
}

@MainActor
private final class SourceLoginSession: ObservableObject {
    weak var webView: WKWebView?

    func attach(_ webView: WKWebView, initialURL: URL) {
        self.webView = webView
        Task { await load(initialURL) }
    }

    func syncCookies(sourceID: String, host: String?) async {
        guard let webView else { return }
        let cookies = await allCookies(in: webView.configuration.websiteDataStore.httpCookieStore)
        let matchingCookies = cookies.filter { cookie in
            guard let host else { return true }
            let domain = cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return host == domain || host.hasSuffix(".\(domain)")
        }
        await SourceHTTPClient.shared.installCookies(matchingCookies, for: sourceID)
    }

    private func load(_ url: URL) async {
        guard let webView else { return }
        let store = webView.configuration.websiteDataStore.httpCookieStore
        for cookie in HTTPCookieStorage.shared.cookies(for: url) ?? [] {
            await setCookie(cookie, in: store)
        }
        webView.load(URLRequest(url: url))
    }

    private func allCookies(in store: WKHTTPCookieStore) async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            store.getAllCookies { continuation.resume(returning: $0) }
        }
    }

    private func setCookie(_ cookie: HTTPCookie, in store: WKHTTPCookieStore) async {
        await withCheckedContinuation { continuation in
            store.setCookie(cookie) { continuation.resume() }
        }
    }
}

private struct SourceLoginWebView: UIViewRepresentable {
    let url: URL
    let sourceID: String
    let loginSession: SourceLoginSession

    func makeCoordinator() -> Coordinator {
        Coordinator(loginSession: loginSession, sourceID: sourceID, host: url.host)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        loginSession.attach(webView, initialURL: url)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let loginSession: SourceLoginSession
        let sourceID: String
        let host: String?

        init(loginSession: SourceLoginSession, sourceID: String, host: String?) {
            self.loginSession = loginSession
            self.sourceID = sourceID
            self.host = host
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
            Task { await loginSession.syncCookies(sourceID: sourceID, host: host) }
        }
    }
}
