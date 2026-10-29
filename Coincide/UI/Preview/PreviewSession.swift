import AppKit
import CoincideKit
import WebKit

/// One tab of a thread's browser: a WebKit view with its own page and back/forward history. A background tab can be
/// unloaded to save memory; it keeps its address and title and loads again when selected or used.
final class PreviewTab: NSObject, WKNavigationDelegate, WKUIDelegate {
    let id: String
    private(set) var webView: WKWebView?
    private var savedURL: URL?
    private var savedTitle = ""
    private(set) var error: String?
    var lastUse = Date()
    weak var owner: PreviewSession?
    private var observations: [NSKeyValueObservation] = []

    init(id: String, owner: PreviewSession, url: URL?) {
        self.id = id
        self.owner = owner
        savedURL = url
        super.init()
    }

    var url: URL? { webView?.url ?? savedURL }
    var title: String { webView?.title.flatMap { $0.isEmpty ? nil : $0 } ?? savedTitle }
    var isLoading: Bool { webView?.isLoading ?? false }
    var isLoaded: Bool { webView != nil }

    /// The tab's web view, created (and its page loaded again) when it was unloaded.
    @discardableResult
    func load(configuration: WKWebViewConfiguration? = nil) -> WKWebView {
        if let webView { return webView }
        guard let owner else { fatalError("A tab outlived its browser") }
        let view = WKWebView(frame: NSRect(origin: .zero, size: PreviewParking.defaultSize),
            configuration: configuration ?? owner.makeConfiguration())
        view.navigationDelegate = self
        view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = true
        for key in [\WKWebView.isLoading, \WKWebView.canGoBack, \WKWebView.canGoForward] {
            observations.append(view.observe(key, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.owner?.tabChanged(self) }
            })
        }
        observations.append(view.observe(\.url, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.owner?.tabChanged(self) }
        })
        observations.append(view.observe(\.title, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.owner?.tabChanged(self) }
        })
        webView = view
        PreviewParking.shared.park(view)
        if configuration == nil, let savedURL { view.load(URLRequest(url: savedURL)) }
        return view
    }

    /// Frees the web view, keeping the address and title. Its back/forward history is lost.
    func unload() {
        guard let webView else { return }
        savedURL = webView.url ?? savedURL
        savedTitle = title
        observations.removeAll()
        webView.stopLoading()
        webView.removeFromSuperview()
        self.webView = nil
    }

    func close() {
        unload()
        owner = nil
    }

    func navigate(_ url: URL) {
        error = nil
        savedURL = url
        load().load(URLRequest(url: url))
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        error = nil
        owner?.tabChanged(self)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let url = webView.url { owner?.tabNavigated(self, to: url, title: webView.title) }
        owner?.tabChanged(self)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(error) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        error = String(localized: "The preview stopped. Reload the page to continue.")
        owner?.tabChanged(self)
    }

    private func failed(_ failure: Error) {
        guard (failure as NSError).code != NSURLErrorCancelled else { return }
        error = failure.localizedDescription
        owner?.tabChanged(self)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        let allowed = navigationAction.request.url.flatMap { PreviewCommand.url($0.absoluteString) } != nil
        decisionHandler(allowed ? .allow : .cancel)
        if !allowed { error = PreviewError.invalidAddress.localizedDescription; owner?.tabChanged(self) }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
        let addressAllowed = navigationResponse.response.url.flatMap { PreviewCommand.url($0.absoluteString) } != nil
        decisionHandler(navigationResponse.canShowMIMEType && addressAllowed ? .allow : .cancel)
    }

    // MARK: WKUIDelegate

    /// `target=_blank` links and `window.open` open a new tab in the same thread, with the page as its opener; at the
    /// tab limit the page loads in this tab instead.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let url = navigationAction.request.url, PreviewCommand.url(url.absoluteString) != nil else { return nil }
        if let tab = owner?.openTab(after: self, configuration: configuration) { return tab.webView }
        webView.load(navigationAction.request)
        return nil
    }

    func webViewDidClose(_ webView: WKWebView) {
        owner?.closeTab(id)
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
        decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void) { decisionHandler(.deny) }
}

/// Each thread owns a browser: its tabs, over the shared profile or a private store (`BrowserProfile`). Tabs are never
/// shared between threads, and switching panels never retargets an agent's commands. Tabs not shown in the panel stay
/// alive offscreen (`PreviewParking`), so agents can use them headless.
final class PreviewSession: NSObject {
    /// Whether the session uses temporary storage of its own rather than the shared profile.
    let isPrivate: Bool
    private let dataStore: WKWebsiteDataStore
    private(set) var tabs: [PreviewTab] = []
    private(set) var activeTab: PreviewTab!
    private var nextTabNumber = 1
    /// The agent's open "your turn" request, shown as a banner in the panel.
    let userTurn = UserTurnGate()
    /// An agent's request to sign in with a saved login, waiting on the user.
    let loginApproval = LoginApprovalGate()
    /// A sign-in the user just submitted, which the panel offers to save. Held in memory only until answered.
    var savePrompt: SavePrompt? { didSet { onChange?() } }
    /// Called with the page, username and password when the user submits a sign-in form.
    var onLoginSubmitted: ((URL, String, String) -> Void)?
    /// When an agent last sent this browser a command, for the panel's footer.
    var lastAgentUse: Date?
    /// When the session was last shown or used, so the least recently used one can be closed first.
    var lastUse = Date()
    var onChange: (() -> Void)?
    var onNavigate: ((URL, String?) -> Void)?
    /// Called when tabs open, close, switch or change address, so they can be remembered.
    var onTabsChanged: (() -> Void)?
    /// Called after a tab loads its web view, so the owner can unload others to save memory.
    var onTabLoaded: (() -> Void)?

    convenience override init() {
        self.init(dataStore: .nonPersistent(), isPrivate: true)
    }

    init(dataStore: WKWebsiteDataStore, isPrivate: Bool, restoring state: BrowserTabsState? = nil) {
        self.isPrivate = isPrivate
        self.dataStore = dataStore
        super.init()
        let state = state ?? BrowserTabsState(urls: [""], selected: 0)
        for address in state.urls { tabs.append(makeTab(url: URL(string: address))) }
        activeTab = tabs[state.selected]
        activeTab.load()
        userTurn.onChange = { [weak self] in self?.onChange?() }
        loginApproval.onChange = { [weak self] in self?.onChange?() }
    }

    /// The active tab's web view.
    var webView: WKWebView { activeTab.load() }
    var error: String? { activeTab.error }

    var tabsState: BrowserTabsState {
        BrowserTabsState(urls: tabs.map { $0.url?.absoluteString ?? "" }, selected: tabs.firstIndex { $0 === activeTab } ?? 0)
    }

    /// A configuration for a new tab: the session's storage and Coincide's sign-in watcher. Every tab gets its own, so
    /// each has its own script handler.
    func makeConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        // Notices sign-ins the user submits, to offer saving them. It runs in Coincide's own script world, which the
        // page can't see or call.
        let loginWatcher = LoginSubmitHandler()
        loginWatcher.session = self
        configuration.userContentController.addUserScript(
            WKUserScript(source: Self.loginWatcherScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
        configuration.userContentController.add(loginWatcher, contentWorld: .defaultClient, name: LoginSubmitHandler.name)
        return configuration
    }

    private func makeTab(url: URL?) -> PreviewTab {
        defer { nextTabNumber += 1 }
        return PreviewTab(id: "tab-\(nextTabNumber)", owner: self, url: url)
    }

    // MARK: Tabs

    func tab(_ id: String) -> PreviewTab? { tabs.first { $0.id == id } }

    /// Opens a tab after the active one (or `after`), at `url`, and makes it active. Nil at the tab limit.
    @discardableResult
    func newTab(_ url: URL? = nil, after: PreviewTab? = nil) -> PreviewTab? {
        guard tabs.count < PreviewCommand.tabLimit else { return nil }
        let tab = makeTab(url: nil)
        let index = (tabs.firstIndex { $0 === (after ?? activeTab) } ?? tabs.count - 1) + 1
        tabs.insert(tab, at: index)
        select(tab)
        if let url { tab.navigate(url) }
        return tab
    }

    /// A tab a page opened (`window.open`, `target=_blank`), with the configuration WebKit requires for it.
    func openTab(after opener: PreviewTab, configuration: WKWebViewConfiguration) -> PreviewTab? {
        guard tabs.count < PreviewCommand.tabLimit else { return nil }
        let tab = makeTab(url: nil)
        tabs.insert(tab, at: (tabs.firstIndex { $0 === opener } ?? tabs.count - 1) + 1)
        tab.load(configuration: configuration)
        select(tab)
        return tab
    }

    func select(_ tab: PreviewTab) {
        guard tabs.contains(where: { $0 === tab }) else { return }
        activeTab = tab
        tab.lastUse = Date()
        tab.load()
        onTabLoaded?()
        tabsChanged()
    }

    func selectTab(offset: Int) {
        guard let index = tabs.firstIndex(where: { $0 === activeTab }), tabs.count > 1 else { return }
        select(tabs[(index + offset + tabs.count) % tabs.count])
    }

    /// Closes a tab. Closing the last one leaves a new empty tab, so the browser is never without one.
    func closeTab(_ id: String) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let closing = tabs.remove(at: index)
        closing.close()
        if tabs.isEmpty { tabs.append(makeTab(url: nil)) }
        if closing === activeTab { select(tabs[min(index, tabs.count - 1)]) } else { tabsChanged() }
    }

    /// Frees background tabs' web views (memory pressure).
    func unloadBackgroundTabs() {
        for tab in tabs where tab !== activeTab { tab.unload() }
    }

    fileprivate func tabChanged(_ tab: PreviewTab?) {
        if tab === activeTab { onChange?() } else { onTabsChanged?(); onChange?() }
    }

    fileprivate func tabNavigated(_ tab: PreviewTab, to url: URL, title: String?) {
        if tab === activeTab { onNavigate?(url, title) }
        tabsChanged()
    }

    private func tabsChanged() {
        onTabsChanged?()
        onChange?()
    }

    /// Ends the session: stops loading and lets an agent waiting on the user go.
    func close() {
        userTurn.finish(.cancelled)
        loginApproval.answer(.deny)
        savePrompt = nil
        for tab in tabs { tab.close() }
    }

    func navigate(_ address: String) throws {
        guard let url = PreviewCommand.url(address) else { throw PreviewError.invalidAddress }
        activeTab.navigate(url)
        onChange?()
    }

    func perform(_ command: PreviewCommand, directory: URL) async throws -> JSONValue {
        lastAgentUse = Date()
        lastUse = Date()
        defer { onChange?() }
        switch command {
        case .show, .askUser, .fillLogin:
            // The panel's commands; `PreviewSessions` answers them.
            throw PreviewError.invalidCommand
        case .tabs:
            return ["tabs": .array(tabs.map { tab in
                ["id": .string(tab.id), "url": .string(tab.url?.absoluteString ?? ""), "title": .string(String(tab.title.prefix(300))),
                 "active": .bool(tab === activeTab), "loading": .bool(tab.isLoading)]
            })]
        case .newTab(let url):
            guard let tab = newTab(url) else { throw PreviewError.tooManyTabs }
            return ["tab": .string(tab.id), "loading": .bool(url != nil)]
        case .selectTab(let id):
            guard let tab = tab(id) else { throw PreviewError.noSuchTab }
            select(tab)
            return ["tab": .string(tab.id), "active": true]
        case .closeTab(let id):
            guard tab(id) != nil else { throw PreviewError.noSuchTab }
            closeTab(id)
            return ["closed": .string(id), "active": .string(activeTab.id)]
        case .inTab(let id, let inner):
            guard let tab = tab(id) else { throw PreviewError.noSuchTab }
            return try await perform(inner, in: tab, directory: directory)
        default:
            return try await perform(command, in: activeTab, directory: directory)
        }
    }

    private func perform(_ command: PreviewCommand, in tab: PreviewTab, directory: URL) async throws -> JSONValue {
        tab.lastUse = Date()
        let webView = tab.load()
        onTabLoaded?()
        switch command {
        case .navigate(let url):
            tab.navigate(url)
            return ["loading": true, "url": .string(url.absoluteString), "tab": .string(tab.id)]
        case .read:
            let result = try await script(Self.readScript, in: webView)
            var object = result.object ?? [:]
            object["loading"] = .bool(webView.isLoading)
            object["tab"] = .string(tab.id)
            if let error = tab.error { object["error"] = .string(error) }
            return .object(object)
        case .click(let selector):
            return try await script(Self.clickScript, arguments: ["selector": selector], in: webView)
        case .input(let selector, let text):
            return try await script(Self.inputScript, arguments: ["selector": selector, "text": text], in: webView)
        case .screenshot:
            let configuration = WKSnapshotConfiguration()
            if webView.superview == nil { PreviewParking.shared.park(webView) }
            // Codes Coincide typed into ordinary fields are drawn as dots in the picture, like passwords.
            _ = try? await webView.callAsyncJavaScript(Self.maskScript, arguments: ["mask": true], in: nil, contentWorld: .defaultClient)
            defer { Task { _ = try? await webView.callAsyncJavaScript(Self.maskScript, arguments: ["mask": false], in: nil, contentWorld: .defaultClient) } }
            let scale = webView.window?.backingScaleFactor ?? 2
            configuration.snapshotWidth = min(1600 / scale, webView.bounds.width) as NSNumber
            let image = try await PreviewParking.shared.rendering(webView) { try await webView.takeSnapshot(configuration: configuration) }
            guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
                let png = bitmap.representation(using: .png, properties: [:]) else { throw PreviewError.unavailable }
            // A fixed path bounds disk usage; no path supplied by the caller is accepted.
            let url = directory.appendingPathComponent("preview.png")
            guard FileManager.default.createFile(atPath: url.path, contents: png, attributes: [.posixPermissions: 0o600])
            else { throw PreviewError.unavailable }
            return ["path": .string(url.path), "mimeType": "image/png", "tab": .string(tab.id)]
        default:
            throw PreviewError.invalidCommand
        }
    }

    private func script(_ body: String, arguments: [String: Any] = [:], in webView: WKWebView) async throws -> JSONValue {
        let value = try await webView.callAsyncJavaScript(body, arguments: arguments, in: nil, contentWorld: .defaultClient)
        guard let value, JSONSerialization.isValidJSONObject(value),
            let result = JSONValue.parse(try JSONSerialization.data(withJSONObject: value))
        else { throw PreviewError.invalidCommand }
        return result
    }

    // Static code, with selector/text passed as WebKit arguments instead of interpolated into JavaScript.
    private static let readScript = #"""
        function selectorFor(el) {
            if (el.id) return '#' + CSS.escape(el.id);
            const parts = [];
            for (let node = el; node && node.nodeType === 1; node = node.parentElement) {
                const tag = node.tagName.toLowerCase();
                const siblings = node.parentElement ? [...node.parentElement.children].filter(n => n.tagName === node.tagName) : [node];
                parts.unshift(tag + ':nth-of-type(' + (siblings.indexOf(node) + 1) + ')');
            }
            return parts.join(' > ');
        }
        const elements = [...document.querySelectorAll('a,button,input,textarea,select,[role="button"],[contenteditable="true"]')]
            .filter(el => el.getClientRects().length).slice(0, 200).map(el => ({
                selector: selectorFor(el).slice(0, 4096), tag: el.tagName.toLowerCase(), type: el.type || '',
                label: (el.getAttribute('aria-label') || el.innerText || el.getAttribute('placeholder') || '').slice(0, 300),
                value: el.type === 'password' || el.type === 'file' || el.autocomplete === 'one-time-code'
                    || (window.__coincideSecretFields && window.__coincideSecretFields.has(el)) ? '' : String(el.value || '').slice(0, 1000),
                disabled: !!el.disabled
            }));
        return {url: location.href.slice(0, 8192), title: document.title.slice(0, 1000), text: (document.body?.innerText || '').slice(0, 30000), elements};
        """#
    private static let clickScript = #"""
        const el = document.querySelector(selector);
        if (!el || !el.getClientRects().length || el.disabled || el.type === 'file') throw new Error('No visible enabled element matches the selector.');
        el.scrollIntoView({block: 'center'});
        el.click();
        return {clicked: true};
        """#
    private static let inputScript = #"""
        const el = document.querySelector(selector);
        if (!el || !el.getClientRects().length || el.disabled || el.readOnly || el.type === 'file') throw new Error('No editable element matches the selector.');
        el.focus();
        if (el.isContentEditable) el.textContent = text;
        else {
            const prototype = el instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype
                : el instanceof HTMLSelectElement ? HTMLSelectElement.prototype
                : el instanceof HTMLInputElement ? HTMLInputElement.prototype : null;
            if (!prototype) throw new Error('The element is not an input.');
            Object.getOwnPropertyDescriptor(prototype, 'value').set.call(el, text);
        }
        el.dispatchEvent(new Event('input', {bubbles: true}));
        el.dispatchEvent(new Event('change', {bubbles: true}));
        return {filled: true};
        """#
}
