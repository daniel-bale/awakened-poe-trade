import AppKit
import Combine
import Foundation
import SwiftUI
import TradeCore
import WebKit

enum TradeBrowserError: Error, LocalizedError {
    case openBrowser, finishNavigation, wrongOrigin, navigationChanged
    case invalidRequest, invalidResponse, requestFailed, timedOut, responseTooLarge

    var errorDescription: String? {
        switch self {
        case .openBrowser:
            return "Open the built-in trade browser and complete any sign-in or browser verification, then retry the request."
        case .finishNavigation:
            return "Wait for the built-in trade browser to finish loading, then retry the request."
        case .wrongOrigin:
            return "Finish signing in and return to the Path of Exile website in the built-in browser, then retry."
        case .navigationChanged:
            return "The browser page changed during the trade request. Return to the trade website and retry when it is ready."
        case .invalidRequest:
            return "The built-in browser can only send trade API requests to the official Path of Exile website."
        case .invalidResponse:
            return "The browser returned an unreadable trade response. Open the browser to check the website, then retry."
        case .requestFailed:
            return "The browser could not complete the trade request. Check sign-in, browser verification, and connectivity, then retry."
        case .timedOut:
            return "The browser trade request timed out. It was not retried. Check the website before trying again."
        case .responseTooLarge:
            return "The trade response was too large to read. Narrow the search and try again."
        }
    }
}

/// A WebKit page's visible navigation state. The page, including its credentials,
/// remains entirely in WebKit's persistent default website data store.
@MainActor
final class TradeBrowserPage: ObservableObject {
    let webView: WKWebView
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var isLoading = false
    @Published private(set) var url: URL?
    @Published private(set) var title = "Path of Exile"
    private var observations: [NSKeyValueObservation] = []

    init(configuration: WKWebViewConfiguration) {
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        observations = [
            webView.observe(\.canGoBack, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.refresh() }
            },
            webView.observe(\.canGoForward, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.refresh() }
            },
            webView.observe(\.isLoading, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.refresh() }
            },
            webView.observe(\.url, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.refresh() }
            },
            webView.observe(\.title, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.refresh() }
            }
        ]
    }

    private func refresh() {
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        isLoading = webView.isLoading
        url = webView.url
        title = webView.title ?? "Path of Exile"
    }
}

@MainActor
private final class TradeBrowserPopup: NSObject, NSWindowDelegate {
    let page: TradeBrowserPage
    let window: NSWindow
    var onClose: (() -> Void)?

    init(configuration: WKWebViewConfiguration) {
        page = TradeBrowserPage(configuration: configuration)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        super.init()
        window.title = "Website sign-in"
        window.minSize = NSSize(width: 640, height: 480)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: TradeBrowserPopupView(page: page))
        window.center()
    }

    func windowWillClose(_ notification: Notification) { onClose?() }
}

/// Requests run in the visible browser's main-frame origin. No cookie values,
/// authorization headers, or account credentials cross the WebKit boundary.
@MainActor
final class TradeBrowserSession: NSObject, ObservableObject, TradeHTTPTransport, WKNavigationDelegate, WKUIDelegate {
    @Published private(set) var status = "Open the trade browser to use its session."
    @Published private(set) var needsAttention = false
    let page: TradeBrowserPage

    var currentURL: URL? { page.url }
    var isLoading: Bool { page.isLoading }
    var canGoBack: Bool { page.canGoBack }
    var canGoForward: Bool { page.canGoForward }
    /// Ready means a suitable web origin is loaded; it does not mean signed in.
    var isReadyForRequests: Bool {
        Self.isTradeOrigin(page.webView.url) && !page.webView.isLoading
            && mainDocumentFinished && !mainPageBlocked
    }

    private struct PendingRequest {
        let url: URL
        let generation: UInt64
        let continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>
        var timeoutTask: Task<Void, Never>?
    }

    private let scriptWorld = WKContentWorld.world(name: "AwakenedTradeTransport")
    private var pending: [String: PendingRequest] = [:]
    private var navigationGeneration: UInt64 = 0
    private var mainDocumentFinished = false
    private var mainPageBlocked = false
    private var activeNavigation: WKNavigation?
    private var browserWindow: NSWindow?
    private var popupWindows: [ObjectIdentifier: TradeBrowserPopup] = [:]
    private var pageObservation: AnyCancellable?
    private static let tradeHome = URL(string: "https://www.pathofexile.com/trade")!
    private static let loginPage = URL(string: "https://www.pathofexile.com/login")!

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        page = TradeBrowserPage(configuration: configuration)
        super.init()
        page.webView.navigationDelegate = self
        page.webView.uiDelegate = self
        pageObservation = page.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    func present() { present(initialURL: Self.tradeHome) }

    private func present(initialURL: URL) {
        if browserWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1050, height: 780),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false
            )
            window.title = "Path of Exile Trade Browser"
            window.minSize = NSSize(width: 740, height: 540)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: TradeBrowserView(session: self))
            window.center()
            browserWindow = window
        }
        if page.webView.url == nil && !page.webView.isLoading { load(initialURL) }
        NSApp.activate(ignoringOtherApps: true)
        if browserWindow?.isMiniaturized == true { browserWindow?.deminiaturize(nil) }
        browserWindow?.makeKeyAndOrderFront(nil)
    }

    func openLogin() {
        if page.webView.url == nil && !page.webView.isLoading {
            present(initialURL: Self.loginPage)
        } else {
            present()
            load(Self.loginPage)
        }
    }

    func openTrade(_ url: URL) {
        guard Self.isTradeOrigin(url), url.path == "/trade" || url.path.hasPrefix("/trade/") else {
            markAttention(.invalidRequest)
            return
        }
        if page.webView.url == nil && !page.webView.isLoading {
            present(initialURL: url)
        } else {
            present()
            load(url)
        }
    }

    func openTradeHome() { openTrade(Self.tradeHome) }
    func goBack() { if page.webView.canGoBack { page.webView.goBack() } }
    func goForward() { if page.webView.canGoForward { page.webView.goForward() } }
    func reload() {
        if page.webView.url == nil { load(Self.tradeHome) }
        else { page.webView.reload() }
    }
    func stopLoading() {
        cancelPending(error: CancellationError())
        page.webView.stopLoading()
        status = "Browser loading stopped."
    }

    private func load(_ url: URL) { page.webView.load(URLRequest(url: url)) }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        guard let url = request.url, Self.isTradeAPI(url),
              request.httpBodyStream == nil else { throw TradeBrowserError.invalidRequest }
        let method = (request.httpMethod ?? "GET").uppercased()
        guard method == "GET" || method == "POST" else { throw TradeBrowserError.invalidRequest }
        let requestHeaders = request.allHTTPHeaderFields ?? [:]
        guard !requestHeaders.keys.contains(where: { ["cookie", "authorization", "proxy-authorization"].contains($0.lowercased()) }) else {
            throw TradeBrowserError.invalidRequest
        }
        var headers: [String: String] = [:]
        for (name, value) in requestHeaders where ["accept", "content-type"].contains(name.lowercased()) {
            headers[name] = value
        }
        let body: Any
        if let bytes = request.httpBody {
            guard method == "POST", bytes.count <= 2_097_152, let string = String(data: bytes, encoding: .utf8) else {
                throw TradeBrowserError.invalidRequest
            }
            body = string
        } else {
            body = NSNull()
        }
        guard Self.isTradeOrigin(page.webView.url) else {
            let error: TradeBrowserError = page.webView.url == nil ? .openBrowser : .wrongOrigin
            markAttention(error)
            throw error
        }
        guard !page.webView.isLoading, mainDocumentFinished else {
            markAttention(.finishNavigation)
            throw TradeBrowserError.finishNavigation
        }
        guard !mainPageBlocked else {
            markAttention(.openBrowser)
            throw TradeBrowserError.openBrowser
        }
        let requestID = UUID().uuidString
        let timeout = request.timeoutInterval.isFinite && request.timeoutInterval > 0
            ? min(max(request.timeoutInterval, 1), 60) : 30
        let arguments: [String: Any] = [
            "requestID": requestID, "requestURL": url.absoluteString,
            "requestMethod": method, "requestHeaders": headers, "requestBody": body,
            "timeoutMilliseconds": Int(timeout * 1000)
        ]
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                var record = PendingRequest(url: url, generation: navigationGeneration, continuation: continuation)
                record.timeoutTask = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000)) }
                    catch { return }
                    self?.complete(requestID, with: .failure(TradeBrowserError.timedOut), abort: true)
                }
                pending[requestID] = record
                status = "Requesting trade data through the browser session…"
                page.webView.callAsyncJavaScript(Self.fetchScript, arguments: arguments, in: nil, in: scriptWorld) { [weak self] result in
                    self?.receive(result, requestID: requestID)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.complete(requestID, with: .failure(CancellationError()), abort: true)
            }
        }
    }

    private func receive(_ result: Result<Any, Error>, requestID: String) {
        guard let record = pending[requestID] else { return }
        guard record.generation == navigationGeneration, Self.isTradeOrigin(page.webView.url) else {
            complete(requestID, with: .failure(TradeBrowserError.navigationChanged))
            return
        }
        do {
            let value = try result.get()
            guard let payload = value as? [String: Any] else { throw TradeBrowserError.invalidResponse }
            if let failure = payload["failure"] as? String {
                switch failure {
                case "wrong-origin": throw TradeBrowserError.wrongOrigin
                case "aborted": throw TradeBrowserError.timedOut
                case "too-large": throw TradeBrowserError.responseTooLarge
                default: throw TradeBrowserError.requestFailed
                }
            }
            guard let statusCode = payload["status"] as? Int, (100...599).contains(statusCode),
                  let responseURLString = payload["url"] as? String, let responseURL = URL(string: responseURLString),
                  Self.isTradeAPI(responseURL),
                  let responseHeaders = payload["headers"] as? [String: String],
                  let base64 = payload["body"] as? String, let data = Data(base64Encoded: base64),
                  let response = HTTPURLResponse(url: responseURL, statusCode: statusCode, httpVersion: "HTTP/1.1", headerFields: responseHeaders) else {
                throw TradeBrowserError.invalidResponse
            }
            if statusCode == 401 || statusCode == 403 || response.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("text/html") == true {
                needsAttention = true
                status = "The trade service needs sign-in or browser verification. Open the browser, complete it, then retry."
            } else if statusCode == 429 {
                status = "The trade service is rate limiting requests. Wait before trying again."
            } else {
                needsAttention = false
                status = "Trade response received through the browser session."
            }
            complete(requestID, with: .success((data, response)))
        } catch {
            let failure = error as? TradeBrowserError ?? .requestFailed
            markAttention(failure)
            complete(requestID, with: .failure(failure))
        }
    }

    private func complete(_ requestID: String, with result: Result<(Data, HTTPURLResponse), Error>, abort: Bool = false) {
        guard let record = pending.removeValue(forKey: requestID) else { return }
        record.timeoutTask?.cancel()
        if abort {
            page.webView.callAsyncJavaScript(Self.abortScript, arguments: ["requestID": requestID], in: nil, in: scriptWorld) { _ in }
        }
        if case .failure(let error) = result {
            if error is CancellationError { status = "Trade request cancelled." }
            else if let error = error as? TradeBrowserError { markAttention(error) }
        }
        record.continuation.resume(with: result)
    }

    private func cancelPending(error: Error) {
        for id in Array(pending.keys) { complete(id, with: .failure(error), abort: true) }
    }

    private func markAttention(_ error: TradeBrowserError) {
        needsAttention = true
        status = error.localizedDescription
    }

    private static func isTradeOrigin(_ url: URL?) -> Bool {
        guard let url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return components.scheme?.lowercased() == "https"
            && components.host?.lowercased() == "www.pathofexile.com"
            && (components.port == nil || components.port == 443)
            && components.user == nil && components.password == nil
    }

    private static func isTradeAPI(_ url: URL) -> Bool {
        isTradeOrigin(url) && url.fragment == nil && url.path.hasPrefix("/api/trade/")
    }

    private static func allowsWebNavigation(_ url: URL?, allowBlankDocument: Bool) -> Bool {
        guard let url else { return false }
        if allowBlankDocument && ["about:blank", "about:srcdoc"].contains(url.absoluteString) { return true }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return components.scheme?.lowercased() == "https" && components.host != nil
            && components.user == nil && components.password == nil
    }

    private func isUninitializedPopup(_ webView: WKWebView) -> Bool {
        webView !== page.webView && (webView.url == nil || ["about:blank", "about:srcdoc"].contains(webView.url?.absoluteString ?? ""))
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let isMainFrame = navigationAction.targetFrame?.isMainFrame == true
        // Websites may create a blank child frame before navigating it to HTTPS.
        // Only child frames and newly opened windows need this initial document.
        let allowBlankDocument = navigationAction.targetFrame?.isMainFrame == false
            || navigationAction.targetFrame == nil || isUninitializedPopup(webView)
        guard Self.allowsWebNavigation(navigationAction.request.url, allowBlankDocument: allowBlankDocument) else {
            if webView === page.webView, isMainFrame {
                status = "This browser only opens HTTPS websites. Local files and app links are not opened."
                needsAttention = true
            }
            decisionHandler(.cancel)
            return
        }
        if webView === page.webView, isMainFrame {
            navigationGeneration &+= 1
            mainDocumentFinished = false
            mainPageBlocked = false
            cancelPending(error: TradeBrowserError.navigationChanged)
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let allowBlankDocument = !navigationResponse.isForMainFrame || isUninitializedPopup(webView)
        guard Self.allowsWebNavigation(navigationResponse.response.url, allowBlankDocument: allowBlankDocument) else {
            decisionHandler(.cancel)
            return
        }
        if webView === page.webView, navigationResponse.isForMainFrame,
           let response = navigationResponse.response as? HTTPURLResponse {
            mainPageBlocked = response.statusCode == 401 || response.statusCode == 403
                || response.value(forHTTPHeaderField: "cf-mitigated")?.lowercased() == "challenge"
            if mainPageBlocked { markAttention(.openBrowser) }
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        if webView === page.webView {
            activeNavigation = navigation
            mainDocumentFinished = false
            status = "Loading the trade browser…"
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === page.webView, activeNavigation === navigation else { return }
        mainDocumentFinished = true
        if mainPageBlocked {
            markAttention(.openBrowser)
        } else if Self.isTradeOrigin(webView.url) {
            needsAttention = false
            status = "Browser ready. The trade service will check this session's access when you retry."
        } else {
            markAttention(.wrongOrigin)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        navigationFailed(webView, navigation: navigation)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        navigationFailed(webView, navigation: navigation)
    }

    private func navigationFailed(_ webView: WKWebView, navigation: WKNavigation?) {
        guard webView === page.webView, activeNavigation === navigation else { return }
        mainDocumentFinished = false
        cancelPending(error: TradeBrowserError.navigationChanged)
        status = "The browser page did not finish loading. Check the website and try loading it again."
        needsAttention = true
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if webView === page.webView {
            mainDocumentFinished = false
            cancelPending(error: TradeBrowserError.navigationChanged)
            status = "The browser process stopped. Reload the page before retrying the trade request."
            needsAttention = true
        }
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard popupWindows.count < 4,
              Self.allowsWebNavigation(navigationAction.request.url, allowBlankDocument: true) else { return nil }
        // WebKit must receive the exact supplied configuration to preserve
        // opener relationships and the login provider's popup flow.
        let popup = TradeBrowserPopup(configuration: configuration)
        let id = ObjectIdentifier(popup.page.webView)
        popup.page.webView.navigationDelegate = self
        popup.page.webView.uiDelegate = self
        popup.onClose = { [weak self] in self?.popupWindows.removeValue(forKey: id) }
        popupWindows[id] = popup
        popup.window.makeKeyAndOrderFront(nil)
        return popup.page.webView
    }

    func webViewDidClose(_ webView: WKWebView) {
        popupWindows[ObjectIdentifier(webView)]?.window.close()
    }

    private static let fetchScript = #"""
    const expectedOrigin = 'https://www.pathofexile.com';
    const url = new URL(requestURL);
    if (location.origin !== expectedOrigin || url.origin !== expectedOrigin ||
        !url.pathname.startsWith('/api/trade/') || url.username || url.password || url.hash) {
      return { failure: 'wrong-origin' };
    }
    const requests = globalThis.__awakenedTradeRequests ??= new Map();
    const aborted = globalThis.__awakenedTradeAborted ??= new Set();
    if (aborted.delete(requestID)) return { failure: 'aborted' };
    const controller = new AbortController();
    requests.set(requestID, controller);
    const timer = setTimeout(() => controller.abort(), timeoutMilliseconds);
    try {
      const response = await fetch(url.href, {
        method: requestMethod, headers: requestHeaders, body: requestBody,
        credentials: 'same-origin', mode: 'same-origin', redirect: 'error',
        cache: 'no-store', signal: controller.signal
      });
      const bytes = new Uint8Array(await response.arrayBuffer());
      if (bytes.byteLength > 8388608) return { failure: 'too-large' };
      let binary = '';
      for (let i = 0; i < bytes.length; i += 32768) {
        binary += String.fromCharCode(...bytes.subarray(i, i + 32768));
      }
      const headers = {};
      for (const [name, value] of response.headers) {
        if (name === 'content-type' || name === 'retry-after' || name.startsWith('x-rate-limit-')) {
          headers[name] = value;
        }
      }
      return { status: response.status, url: response.url, headers, body: btoa(binary) };
    } catch (error) {
      return { failure: error && error.name === 'AbortError' ? 'aborted' : 'request-failed' };
    } finally {
      clearTimeout(timer);
      requests.delete(requestID);
      aborted.delete(requestID);
    }
    """#

    private static let abortScript = #"""
    const requests = globalThis.__awakenedTradeRequests;
    const controller = requests && requests.get(requestID);
    if (controller) {
      controller.abort();
    } else {
      const aborted = globalThis.__awakenedTradeAborted ??= new Set();
      if (aborted.size >= 32) aborted.clear();
      aborted.add(requestID);
    }
    return true;
    """#
}
