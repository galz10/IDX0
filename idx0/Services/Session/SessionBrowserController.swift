import AppKit
import Foundation
import SwiftUI
import WebKit

@MainActor
final class EmbeddedWebViewDelegate: NSObject, WKNavigationDelegate {
    private let logLabel: String
    private let onProcessTermination: ((WKWebView) -> Void)?

    init(
        logLabel: String,
        onProcessTermination: ((WKWebView) -> Void)? = nil
    ) {
        self.logLabel = logLabel
        self.onProcessTermination = onProcessTermination
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        guard navigationAction.navigationType == .linkActivated,
              let url = navigationAction.request.url,
              shouldOpenExternally(url),
              navigationAction.targetFrame?.isMainFrame != false else {
            decisionHandler(.allow)
            return
        }

        Logger.info("\(logLabel): opening external URL \(url.absoluteString)")
        NSWorkspace.shared.open(url)
        decisionHandler(.cancel)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Logger.warning("\(logLabel): WebContent process terminated")
        onProcessTermination?(webView)
    }

    private func shouldOpenExternally(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        switch scheme {
        case "http", "https", "about", "data", "file", "blob":
            return false
        default:
            return true
        }
    }
}

@MainActor
final class SessionBrowserController: NSObject, ObservableObject, WKNavigationDelegate {
    private static var chromeCookieHydrationTask: Task<Void, Never>?
    private static var hasHydratedChromeCookies = false

    @Published private(set) var currentURLString: String?
    @Published private(set) var pageTitle: String?
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var estimatedProgress: Double = 0
    @Published private(set) var canGoBack: Bool = false
    @Published private(set) var canGoForward: Bool = false
    @Published var navigationError: String?
    @Published var isFindBarVisible: Bool = false

    var isSecure: Bool {
        currentURLString?.hasPrefix("https://") ?? false
    }

    let webView: WKWebView

    var onURLChanged: ((String?) -> Void)?

    private var isBootstrapComplete = false
    private var pendingLoadURLString: String?
    private var kvoObservations: [NSKeyValueObservation] = []
    private var webContentTerminationCount = 0
    private let maxWebContentReloadAttempts = 2

    init(initialURL: String?) {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.websiteDataStore = .default()
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        webView = WKWebView(frame: .zero, configuration: config)
        webView.pageZoom = 0.85
        currentURLString = nil
        pendingLoadURLString = initialURL
        super.init()
        webView.navigationDelegate = self
        installKVOObservers()

        Task { [weak self] in
            guard let self else { return }
            await Self.hydrateChromeCookiesIfNeeded(using: self.webView.configuration.websiteDataStore.httpCookieStore)
            self.isBootstrapComplete = true
            self.flushPendingLoad()
        }
    }

    deinit {
        kvoObservations.removeAll()
    }

    private func installKVOObservers() {
        kvoObservations.append(webView.observe(\.canGoBack, options: [.new]) { [weak self] _, change in
            Task { @MainActor [weak self] in self?.canGoBack = change.newValue ?? false }
        })
        kvoObservations.append(webView.observe(\.canGoForward, options: [.new]) { [weak self] _, change in
            Task { @MainActor [weak self] in self?.canGoForward = change.newValue ?? false }
        })
        kvoObservations.append(webView.observe(\.isLoading, options: [.new]) { [weak self] _, change in
            Task { @MainActor [weak self] in self?.isLoading = change.newValue ?? false }
        })
        kvoObservations.append(webView.observe(\.estimatedProgress, options: [.new]) { [weak self] _, change in
            Task { @MainActor [weak self] in self?.estimatedProgress = change.newValue ?? 0 }
        })
        kvoObservations.append(webView.observe(\.title, options: [.new]) { [weak self] _, change in
            Task { @MainActor [weak self] in self?.pageTitle = change.newValue ?? nil }
        })
    }

    // MARK: - Navigation

    func load(urlString: String?) {
        navigationError = nil
        pendingLoadURLString = urlString
        guard isBootstrapComplete else { return }
        flushPendingLoad()
    }

    func goBack() {
        navigationError = nil
        webView.goBack()
    }

    func goForward() {
        navigationError = nil
        webView.goForward()
    }

    func reload() {
        navigationError = nil
        webView.reload()
    }

    func stopLoading() {
        webView.stopLoading()
    }

    // MARK: - Find in Page

    func findInPage(_ query: String) {
        guard !query.isEmpty else { return }
        let escaped = query.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
        webView.evaluateJavaScript("window.find('\(escaped)', false, false, true)") { _, _ in }
    }

    func dismissFind() {
        isFindBarVisible = false
        webView.evaluateJavaScript("window.getSelection().removeAllRanges()") { _, _ in }
    }

    // MARK: - Private

    private func flushPendingLoad() {
        guard let urlString = pendingLoadURLString else { return }
        pendingLoadURLString = nil

        guard let parsed = normalizeURL(urlString) else { return }
        let request = URLRequest(url: parsed)
        webView.load(request)
        setCurrentURL(parsed.absoluteString)
    }

    private static func hydrateChromeCookiesIfNeeded(using cookieStore: WKHTTPCookieStore) async {
        if hasHydratedChromeCookies {
            return
        }
        if let existingTask = chromeCookieHydrationTask {
            await existingTask.value
            return
        }

        let task = Task {
            let imported = await ChromeCookieImporter.hydrate(cookieStore: cookieStore)
            if imported > 0 {
                Logger.info("Hydrated embedded browser with \(imported) Chrome cookies.")
                hasHydratedChromeCookies = true
            } else {
                Logger.warning("Embedded browser imported 0 Chrome cookies; will retry on next browser startup.")
                hasHydratedChromeCookies = false
            }
        }

        chromeCookieHydrationTask = task
        await task.value
        chromeCookieHydrationTask = nil
    }

    func openInDefaultBrowser() {
        guard let currentURLString, let url = URL(string: currentURLString) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - WKNavigationDelegate

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        _ = webView
        guard navigationAction.navigationType == .linkActivated,
              let url = navigationAction.request.url,
              shouldOpenExternally(url),
              navigationAction.targetFrame?.isMainFrame != false else {
            decisionHandler(.allow)
            return
        }

        NSWorkspace.shared.open(url)
        decisionHandler(.cancel)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        _ = navigation
        _ = webView
        webContentTerminationCount = 0
        navigationError = nil
        setCurrentURL(webView.url?.absoluteString)
        recordHistoryIfNeeded()
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        _ = navigation
        _ = webView
        navigationError = nil
        setCurrentURL(webView.url?.absoluteString)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        _ = navigation
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return }
        navigationError = error.localizedDescription
        setCurrentURL(webView.url?.absoluteString)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        _ = navigation
        _ = webView
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return }
        navigationError = error.localizedDescription
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webContentTerminationCount += 1
        Logger.warning("Session browser WebContent terminated count=\(webContentTerminationCount)")

        guard webContentTerminationCount <= maxWebContentReloadAttempts else {
            navigationError = "Embedded browser crashed repeatedly. Use Reload or Open in Default Browser."
            return
        }

        navigationError = "Embedded browser process restarted. Reloading..."
        if webView.url != nil {
            webView.reload()
            return
        }

        if pendingLoadURLString == nil {
            pendingLoadURLString = currentURLString
        }
        flushPendingLoad()
    }

    private func recordHistoryIfNeeded() {
        guard let url = currentURLString, !url.isEmpty else { return }
        let title = pageTitle ?? url
        BrowserDataStore.shared.recordVisit(title: title, url: url)
    }

    private func setCurrentURL(_ value: String?) {
        currentURLString = value
        onURLChanged?(value)
    }

    private func shouldOpenExternally(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        switch scheme {
        case "http", "https", "about", "data", "file", "blob":
            return false
        default:
            return true
        }
    }

    func normalizeURL(_ value: String?) -> URL? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let url = URL(string: trimmed), let scheme = url.scheme, !scheme.isEmpty {
            return url
        }

        // Detect localhost patterns — use http, not https
        if trimmed.hasPrefix("localhost") || trimmed.hasPrefix("127.0.0.1") || trimmed.hasPrefix("0.0.0.0") {
            if let withHTTP = URL(string: "http://\(trimmed)") {
                return withHTTP
            }
        }

        // If it looks like a domain (contains a dot), treat as URL
        if trimmed.contains(".") || trimmed.contains(":") {
            if let withHTTPS = URL(string: "https://\(trimmed)") {
                return withHTTPS
            }
        }

        // Otherwise, treat as a search query
        let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? trimmed
        return URL(string: "https://www.google.com/search?q=\(encoded)")
    }
}
