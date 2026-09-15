import SwiftUI
import WebKit

struct TradeBrowserView: View {
    @ObservedObject var session: TradeBrowserSession

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                BrowserNavigationControls(page: session.page) {
                    if session.isLoading { session.stopLoading() } else { session.reload() }
                }
                Divider().frame(height: 20)
                Button("Trade Home") { session.openTradeHome() }
                Button("Sign In") { session.openLogin() }
                Spacer(minLength: 8)
                BrowserOriginLabel(url: session.currentURL)
            }.padding(10).background(.bar)
            HStack(spacing: 8) {
                Image(systemName: session.needsAttention ? "person.crop.circle.badge.exclamationmark" : "info.circle")
                Text(session.status).font(.callout).textSelection(.enabled)
                Spacer(minLength: 0)
            }.foregroundStyle(session.needsAttention ? Color.orange : Color.secondary)
                .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            TradeWebView(webView: session.page.webView)
            Divider()
            Text("Sign in or complete verification on the website, then return to the price check and retry. Requests are never retried automatically.")
                .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(10)
        }
    }
}

struct TradeBrowserPopupView: View {
    @ObservedObject var page: TradeBrowserPage

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                BrowserNavigationControls(page: page)
                Spacer()
                BrowserOriginLabel(url: page.url)
            }.padding(10).background(.bar)
            Divider()
            TradeWebView(webView: page.webView)
        }
    }
}

private struct BrowserNavigationControls: View {
    @ObservedObject var page: TradeBrowserPage
    var reloadOrStop: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 8) {
            Button { page.webView.goBack() } label: { Image(systemName: "chevron.left") }
                .disabled(!page.canGoBack).help("Back")
            Button { page.webView.goForward() } label: { Image(systemName: "chevron.right") }
                .disabled(!page.canGoForward).help("Forward")
            Button {
                if let reloadOrStop { reloadOrStop() }
                else if page.isLoading { page.webView.stopLoading() }
                else { page.webView.reload() }
            } label: { Image(systemName: page.isLoading ? "xmark" : "arrow.clockwise") }
                .help(page.isLoading ? "Stop loading" : "Reload")
            if page.isLoading { ProgressView().controlSize(.small).frame(width: 16) }
        }.buttonStyle(.borderless)
    }
}

private struct BrowserOriginLabel: View {
    let url: URL?

    var body: some View {
        if let host = url?.host {
            Label("https://" + host + (url?.port.map { ":\($0)" } ?? ""), systemImage: "lock.fill")
                .font(.system(.caption, design: .monospaced)).lineLimit(1).textSelection(.enabled)
                .help("Check the website address before entering account information.")
        } else {
            Text("No website loaded").font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct TradeWebView: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
