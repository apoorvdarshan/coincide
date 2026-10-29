import AppKit
import CoincideKit
import WebKit

/// Lets Settings › Usage read the sites the user turned on with their sign-in in Coincide's shared browser profile
/// (`BrowserProfile.sharedDataStore`): the cookies go only into requests to their own site, and chatgpt.com's credit
/// history is read from its page in a hidden browser. Nothing here logs cookies, tokens or what the pages say.
enum BrowserUsageBridge {
    /// Connects `UsageInsights` to the profile. Called once at launch.
    static func connect(insights: UsageInsights = .shared, profile: BrowserProfile = .shared) {
        insights.browserCookies = { [weak profile] source in
            guard let profile else { return nil }
            let cookies = await profile.sharedDataStore.httpCookieStore.allCookies()
            return BrowserCookieHeader.make(cookies, host: source.host)
        }
        insights.creditHistoryReader = { [weak profile] in
            guard let profile else { return .problem(.notSignedIn) }
            let page = CreditHistoryPage(dataStore: profile.sharedDataStore)
            defer { page.close() }
            return await page.read(BrowserUsageSource.chatGPT.signInURL)
        }
    }
}

/// chatgpt.com's Codex analytics page, loaded in a browser that is never shown, to read its "Credits usage history"
/// table (`ChatGPTCodexBilling.historyScript`). The page is a web app that renders the table some time after it loads,
/// so the script runs every half second until it finds rows, finds the table empty for a while, or time runs out.
final class CreditHistoryPage: NSObject, WKNavigationDelegate {
    static let timeout: Duration = .seconds(25)
    /// How long the table must stay empty before it counts as empty rather than still loading.
    static let emptyGrace: Duration = .seconds(3)

    let webView: WKWebView
    private let window: NSWindow
    private var failed = false

    init(dataStore: WKWebsiteDataStore) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        let frame = NSRect(x: 0, y: 0, width: 1200, height: 1600)
        webView = WKWebView(frame: frame, configuration: configuration)
        // Hosted in a borderless window far off every screen that is never ordered in, like the parked thread browsers.
        window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: -20_000, y: -20_000), size: frame.size), styleMask: [.borderless], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.isExcludedFromWindowsMenu = true
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.alphaValue = 0
        window.contentView = NSView(frame: NSRect(origin: .zero, size: frame.size))
        super.init()
        webView.navigationDelegate = self
        window.contentView?.addSubview(webView)
    }

    /// Loads `url` and reads the table.
    func read(_ url: URL) async -> ChatGPTCodexBilling.HistoryOutcome {
        webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20))
        return await poll()
    }

    /// Reads the table from `html` as if it were at `baseURL`, for tests.
    func read(html: String, baseURL: URL) async -> ChatGPTCodexBilling.HistoryOutcome {
        webView.loadHTMLString(html, baseURL: baseURL)
        return await poll()
    }

    private func poll() async -> ChatGPTCodexBilling.HistoryOutcome {
        let clock = ContinuousClock()
        let start = clock.now
        var emptySince: ContinuousClock.Instant?
        while clock.now - start < Self.timeout {
            try? await Task.sleep(for: .milliseconds(500))
            if Task.isCancelled { break }
            if failed { return .problem(.offline) }
            guard let result = try? await webView.callAsyncJavaScript(
                "return " + ChatGPTCodexBilling.historyScript, arguments: [:], in: nil, contentWorld: .defaultClient) as? [String: Any]
            else { continue }
            switch result["state"] as? String {
            case "signedOut":
                return .problem(.notSignedIn)
            case "rows":
                let rows = (result["rows"] as? [[Any]] ?? []).map { $0.map { ($0 as? String) ?? "" } }
                return .rows(rows)
            case "empty":
                if let emptySince, clock.now - emptySince >= Self.emptyGrace { return .rows([]) }
                emptySince = emptySince ?? clock.now
            default:
                emptySince = nil
            }
        }
        // A page that never showed the table: changed, or held at a check Coincide can't pass.
        return .problem(.unrecognized)
    }

    /// Stops the page and lets the window go.
    func close() {
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.removeFromSuperview()
        window.close()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed = true }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        // A redirect the page cancels itself isn't a failure.
        if (error as NSError).code != NSURLErrorCancelled { failed = true }
    }
}

/// Opens a site's sign-in page in Coincide's browser: the open thread's browser panel when there is one and it uses
/// the shared profile, else a small window of its own over the shared profile. Either way the sign-in lands in the
/// profile the reads use; the site is read again when the window closes, or with Check Again.
enum BrowserUsageSignIn {
    static func open(_ source: BrowserUsageSource) {
        if !BrowserProfile.shared.usesPrivateSessions, let main = (NSApp.delegate as? AppDelegate)?.mainWindow,
            main.openInBrowserPreview(source.signInURL)
        {
            main.showWindow(nil)
            main.window?.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        BrowserSignInWindowController.show(source)
    }
}

/// A small browser window over the shared profile, for signing in to a site from Settings › Usage.
final class BrowserSignInWindowController: NSWindowController, NSWindowDelegate, WKUIDelegate {
    private static var open: [BrowserSignInWindowController] = []
    private let source: BrowserUsageSource
    private let webView: WKWebView

    static func show(_ source: BrowserUsageSource) {
        if let existing = open.first(where: { $0.source == source }) {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let controller = BrowserSignInWindowController(source: source)
        open.append(controller)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        controller.webView.load(URLRequest(url: source.signInURL))
    }

    private init(source: BrowserUsageSource) {
        self.source = source
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = BrowserProfile.shared.sharedDataStore
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 720), configuration: configuration)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 720), styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        window.title = String(localized: "Sign In to \(source.host)")
        window.minSize = NSSize(width: 480, height: 420)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        window.center()
        super.init(window: window)
        window.delegate = self
        webView.uiDelegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Sign-in pages that open a pop-up (a provider's sign-in) open it here instead.
    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url { webView.load(URLRequest(url: url)) }
        return nil
    }

    func windowWillClose(_ notification: Notification) {
        webView.stopLoading()
        let source = source
        Task { await UsageInsights.shared.readBrowserUsage(source, force: true) }
        Self.open.removeAll { $0 === self }
    }
}
