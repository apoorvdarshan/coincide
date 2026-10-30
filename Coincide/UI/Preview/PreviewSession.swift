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
    /// Whether the page shown asked for a passkey this browser can't provide, for the agent's `read`.
    fileprivate(set) var passkeyRequested = false
    /// Files an agent's `upload` is attaching: the page's next file chooser gets them instead of a dialog.
    fileprivate var pendingUpload: [URL]?
    /// The page's alert, confirmation or prompt, which blocks the page until the agent or the user answers it.
    private(set) var dialog: PreviewDialog?
    fileprivate var dialogWaiters: [UUID: (JSONValue) -> Void] = [:]
    /// The folder a local file the user opened may read from; navigations stay inside it.
    private var fileRoot: URL?
    var viewportSize: NSSize?
    /// The last usable panel area, retained while parked and when a fixed test viewport is reset in the background.
    var panelSize: NSSize?
    let downloads: PreviewDownloads
    var lastUse = Date()
    weak var owner: PreviewSession?
    private var observations: [NSKeyValueObservation] = []

    init(id: String, owner: PreviewSession, url: URL?) {
        self.id = id
        downloads = PreviewDownloads(directory: owner.downloadDirectory)
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
        let view = WKWebView(frame: NSRect(origin: .zero, size: viewportSize ?? panelSize ?? PreviewParking.defaultSize),
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
        if configuration == nil, let savedURL {
            if savedURL.isFileURL { openFile(savedURL, in: view) } else { view.load(URLRequest(url: savedURL)) }
        }
        return view
    }

    /// Frees the web view, keeping the address and title. Its back/forward history is lost.
    func unload() {
        _ = answerDialog(accept: false, text: nil)
        guard let webView else { return }
        savedURL = webView.url ?? savedURL
        savedTitle = title
        owner?.pageTools.reset(webView)
        observations.removeAll()
        webView.stopLoading()
        webView.removeFromSuperview()
        self.webView = nil
    }

    func close() {
        _ = answerDialog(accept: false, text: nil)
        downloads.stop()
        unload()
        owner = nil
    }

    /// Answers the open dialog. False when there is none.
    @discardableResult
    func answerDialog(accept: Bool, text: String?) -> Bool {
        guard let dialog else { return false }
        self.dialog = nil
        dialog.respond(accept, text)
        owner?.tabChanged(self)
        return true
    }

    private func show(_ dialog: PreviewDialog) {
        // A page can't open a second dialog while one blocks it; answer a stray one as cancelled.
        if self.dialog != nil { dialog.respond(false, nil); return }
        self.dialog = dialog
        // WebKit may hold the JavaScript reply until this dialog is answered. Release commands already in
        // flight with the dialog, so the agent can issue its separate answer command.
        for reply in Array(dialogWaiters.values) { reply(["dialog": dialog.json]) }
        owner?.tabChanged(self)
    }

    func navigate(_ url: URL) {
        error = nil
        savedURL = url
        if url.isFileURL { openFile(url, in: load()) } else { load().load(URLRequest(url: url)) }
    }

    /// A local file the user typed the path of, which may read the files beside it.
    private func openFile(_ url: URL, in view: WKWebView) {
        let root = url.deletingLastPathComponent()
        fileRoot = root
        view.loadFileURL(url, allowingReadAccessTo: root)
    }

    /// Web addresses, and local files inside the folder of a file the user opened.
    private func allows(_ url: URL?) -> Bool {
        guard let url else { return false }
        if url.isFileURL {
            guard let fileRoot else { return false }
            return url.standardizedFileURL.path.hasPrefix(fileRoot.standardizedFileURL.path)
        }
        return PreviewCommand.url(url.absoluteString) != nil
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        error = nil
        owner?.pageTools.reset(webView)
        owner?.tabChanged(self)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        passkeyRequested = false
        owner?.tabCommitted(self, host: webView.url?.host ?? "")
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
        let scheme = navigationAction.request.url?.scheme
        let download = navigationAction.shouldPerformDownload
        let allowed = allows(navigationAction.request.url)
            || (!navigationAction.sourceFrame.isMainFrame && scheme == "about")
            || (download && scheme == "blob")
        decisionHandler(allowed ? (download ? .download : .allow) : .cancel)
        if !allowed { error = PreviewError.invalidAddress.localizedDescription; owner?.tabChanged(self) }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
        let addressAllowed = allows(navigationResponse.response.url) || navigationResponse.response.url?.scheme == "blob"
        decisionHandler(addressAllowed ? (navigationResponse.canShowMIMEType ? .allow : .download) : .cancel)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        downloads.receive(download)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        downloads.receive(download)
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

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor @Sendable () -> Void) {
        show(PreviewDialog(kind: .alert, message: message, defaultText: nil) { _, _ in completionHandler() })
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor @Sendable (Bool) -> Void) {
        show(PreviewDialog(kind: .confirm, message: message, defaultText: nil) { accept, _ in completionHandler(accept) })
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
        initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable (String?) -> Void) {
        show(PreviewDialog(kind: .prompt, message: prompt, defaultText: defaultText) { accept, text in
            completionHandler(accept ? (text ?? defaultText ?? "") : nil)
        })
    }

    /// A file chooser: an agent's pending `upload` answers it with no dialog; the user's own click on a file input gets
    /// the standard open panel, as a sheet on the window showing the page.
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor @Sendable ([URL]?) -> Void) {
        if let files = pendingUpload {
            pendingUpload = nil
            completionHandler(parameters.allowsMultipleSelection ? files : Array(files.prefix(1)))
            return
        }
        guard let window = webView.window, window.isKeyWindow else {
            completionHandler(nil)
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated { completionHandler(response == .OK ? panel.urls : nil) }
        }
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
    private let warningStore: AppStore
    private var warningObservation: ObservationToken?
    private(set) var tabs: [PreviewTab] = []
    private(set) var activeTab: PreviewTab!
    private var nextTabNumber = 1
    /// Whether pages can use passkeys; when they can't, passkey requests show `passkeyNotice` instead.
    let passkeys: PasskeySupport
    /// "Passkeys aren't available" for the tab whose page asked for one.
    private(set) var passkeyNotice = PasskeyNoticeState()
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

    let pageTools = PreviewPageTools()
    let downloadDirectory: URL

    convenience override init() {
        self.init(dataStore: .nonPersistent(), isPrivate: true)
    }

    init(dataStore: WKWebsiteDataStore, isPrivate: Bool, restoring state: BrowserTabsState? = nil,
        passkeys: PasskeySupport = .current, warningStore: AppStore = .shared,
        downloadDirectory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/Coincide", isDirectory: true)) {
        self.downloadDirectory = downloadDirectory
        self.isPrivate = isPrivate
        self.dataStore = dataStore
        self.passkeys = passkeys
        self.warningStore = warningStore
        super.init()
        let state = state ?? BrowserTabsState(urls: [""], selected: 0)
        for address in state.urls { tabs.append(makeTab(url: URL(string: address))) }
        activeTab = tabs[state.selected]
        activeTab.load()
        userTurn.onChange = { [weak self] in self?.onChange?() }
        loginApproval.onChange = { [weak self] in self?.onChange?() }
        warningObservation = warningStore.observe { [weak self] change in
            guard change == .settings, let self,
                self.warningStore.isWarningDismissed(WarningDismissalKey.passkeysUnavailable),
                self.passkeyNotice.notice != nil else { return }
            // Dismissing this browser limitation in one thread also updates banners already open elsewhere.
            self.passkeyNotice.dismiss()
            self.onChange?()
        }
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
        pageTools.install(in: configuration)
        // Notices sign-ins the user submits, to offer saving them. It runs in Coincide's own script world, which the
        // page can't see or call.
        let loginWatcher = LoginSubmitHandler()
        loginWatcher.session = self
        configuration.userContentController.addUserScript(
            WKUserScript(source: Self.loginWatcherScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
        configuration.userContentController.add(loginWatcher, contentWorld: .defaultClient, name: LoginSubmitHandler.name)
        if !passkeys.isAvailable {
            // Notices pages asking for a passkey, which fails without the entitlement, to suggest another way to sign
            // in. It must run in the page's world to see the page's calls, and passes every call through unchanged.
            let passkeyWatcher = PasskeyRequestHandler()
            passkeyWatcher.session = self
            configuration.userContentController.addUserScript(
                WKUserScript(source: PasskeySupport.detectionScript, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
            configuration.userContentController.add(passkeyWatcher, contentWorld: .page, name: PasskeySupport.messageHandler)
        }
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
        passkeyNotice.closed(tabID: id)
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

    fileprivate func tabCommitted(_ tab: PreviewTab, host: String) {
        if passkeyNotice.navigated(tabID: tab.id, host: host) { onChange?() }
    }

    /// A page in `webView` asked for a passkey. The agent's page state is always recorded; the capability
    /// notice stays hidden in every browser after the user has dismissed it once.
    func passkeyRequested(in webView: WKWebView) {
        guard let tab = tabs.first(where: { $0.webView === webView }), let page = webView.url, let host = page.host,
            PreviewCommand.url(page.absoluteString) != nil
        else { return }
        tab.passkeyRequested = true
        guard !warningStore.isWarningDismissed(WarningDismissalKey.passkeysUnavailable) else { return }
        if passkeyNotice.requested(tabID: tab.id, host: host) { onChange?() }
    }

    func dismissPasskeyNotice() {
        guard passkeyNotice.notice != nil else { return }
        passkeyNotice.dismiss()
        // This is the same app capability warning on every site. Persist no browsing-domain history.
        warningStore.dismissWarning(WarningDismissalKey.passkeysUnavailable)
        onChange?()
    }

    /// The notice for the tab shown in the panel, if any.
    var activePasskeyNotice: PasskeyNoticeState.Notice? {
        guard !warningStore.isWarningDismissed(WarningDismissalKey.passkeysUnavailable) else { return nil }
        return passkeyNotice.notice.flatMap { $0.tabID == activeTab.id ? $0 : nil }
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
        warningObservation = nil
        userTurn.finish(.cancelled)
        loginApproval.answer(.deny)
        savePrompt = nil
        for tab in tabs { tab.close() }
    }

    /// The user's search engine, read when something is searched.
    var searchEngine: () -> SearchEngine = { .google }

    /// What the user typed in the address bar: an address, a local file, or a search.
    func navigate(_ address: String) throws {
        guard let destination = BrowserAddress.resolve(address, engine: searchEngine(), allowsFiles: true) else {
            throw PreviewError.invalidAddress
        }
        activeTab.navigate(destination.url)
        onChange?()
    }

    func perform(_ command: PreviewCommand, directory: URL) async throws -> JSONValue {
        lastAgentUse = Date()
        lastUse = Date()
        defer { onChange?() }
        switch command {
        case .show, .hide, .askUser, .fillLogin:
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

    private func perform(_ command: PreviewCommand, in tab: PreviewTab, directory: URL, frame: WKFrameInfo? = nil) async throws -> JSONValue {
        tab.lastUse = Date()
        let webView = tab.load()
        onTabLoaded?()
        if case .inFrame(let id, let inner) = command {
            guard let target = pageTools.frames(in: webView).first(where: { $0.id == id }) else { throw PreviewError.invalidCommand }
            return try await perform(inner, in: tab, directory: directory, frame: target.info)
        }
        // A dialog blocks the page's scripts, so only reading it and answering it work until it's answered.
        if let dialog = tab.dialog {
            switch command {
            case .dialog(let accept, let text):
                tab.answerDialog(accept: accept, text: text)
                return ["answered": .string(dialog.kind.rawValue), "tab": .string(tab.id)]
            case .read:
                return ["dialog": dialog.json, "url": .string(webView.url?.absoluteString ?? ""), "title": .string(webView.title ?? ""),
                        "loading": .bool(webView.isLoading), "tab": .string(tab.id),
                        "viewport": viewport(of: tab, webView: webView), "panelVisible": .bool(panelIsVisible(webView))]
            default:
                throw PreviewError.dialogOpen
            }
        }
        switch command {
        case .frames:
            return ["frames": .array(pageTools.frames(in: webView).map { frame in
                ["id": .string(frame.id), "title": .string(frame.title), "url": .string(frame.info.request.url?.absoluteString ?? "")]
            })]
        case .console(let clear):
            return pageTools.console(in: webView, clear: clear)
        case .downloads:
            return ["downloads": tab.downloads.json]
        case .viewport(let width, let height):
            tab.viewportSize = width.flatMap { w in height.map { NSSize(width: w, height: $0) } }
            if let size = tab.viewportSize { webView.setFrameSize(size) }
            else if PreviewParking.shared.isParked(webView) { webView.setFrameSize(tab.panelSize ?? PreviewParking.defaultSize) }
            onChange?()
            return ["width": .number(webView.bounds.width), "height": .number(webView.bounds.height)]
        case .dialog:
            throw PreviewError.noDialog
        case .back, .forward:
            let back = command == .back
            guard back ? webView.canGoBack : webView.canGoForward else { return ["moved": false, "tab": .string(tab.id)] }
            if back { webView.goBack() } else { webView.goForward() }
            return ["moved": true, "loading": true, "tab": .string(tab.id)]
        case .reload:
            webView.reload()
            return ["loading": true, "tab": .string(tab.id)]
        case .type(let selector, let text, let clear):
            return try await script(Self.typeScript, arguments: ["selector": selector, "text": text, "clear": clear], in: webView, frame: frame)
        case .press(let key, let selector):
            if let selector { _ = try await script(Self.focusScript, arguments: ["selector": selector], in: webView, frame: frame) }
            Self.press(key, in: webView)
            // Let the page handle the key (and any navigation it starts) before the agent reads again.
            try await Task.sleep(for: .milliseconds(100))
            return ["pressed": true, "loading": .bool(webView.isLoading), "tab": .string(tab.id)]
        case .scroll(let target):
            var arguments: [String: Any] = ["target": "by", "selector": "", "by": 0, "hasBy": false]
            switch target {
            case .element(let selector): arguments["target"] = "element"; arguments["selector"] = selector
            case .top: arguments["target"] = "top"
            case .bottom: arguments["target"] = "bottom"
            case .by(let pixels): arguments["by"] = pixels ?? 0; arguments["hasBy"] = pixels != nil
            }
            return try await script(Self.scrollScript, arguments: arguments, in: webView, frame: frame)
        case .waitFor(let selector, let text, let timeout):
            let start = Date()
            while true {
                if tab.dialog != nil { throw PreviewError.dialogOpen }
                let found = try await script(Self.findScript, arguments: ["selector": selector ?? "", "text": text ?? ""], in: webView, frame: frame)
                if found["found"]?.bool == true {
                    return ["found": true, "waited": .number((Date().timeIntervalSince(start) * 10).rounded() / 10), "tab": .string(tab.id)]
                }
                guard Date().timeIntervalSince(start) < timeout else { throw PreviewError.timedOut }
                try await Task.sleep(for: .milliseconds(250))
            }
        case .navigate(let url):
            tab.navigate(url)
            return ["loading": true, "url": .string(url.absoluteString), "tab": .string(tab.id)]
        case .search(let query):
            guard let url = searchEngine().url(for: query) else { throw PreviewError.invalidCommand }
            tab.navigate(url)
            return ["loading": true, "url": .string(url.absoluteString), "tab": .string(tab.id)]
        case .read(let page, let scope):
            let result = try await script(Self.readScript, arguments: ["page": page, "scope": scope ?? ""], in: webView, frame: frame)
            var object = result.object ?? [:]
            object["loading"] = .bool(webView.isLoading)
            object["tab"] = .string(tab.id)
            object["viewport"] = viewport(of: tab, webView: webView, dimensions: object["viewport"])
            object["panelVisible"] = .bool(panelIsVisible(webView))
            if let error = tab.error { object["error"] = .string(error) }
            if tab.passkeyRequested { object["passkey"] = .string(PasskeySupport.agentNote) }
            return .object(object)
        case .click(let selector):
            _ = try await script(Self.clickScript, arguments: ["selector": selector], in: webView, frame: frame)
            // A dialog can release the script reply before the click handler finishes.
            try await Task.sleep(for: .milliseconds(80))
            var reply: [String: JSONValue] = ["clicked": true, "tab": .string(tab.id)]
            if let dialog = tab.dialog { reply["dialog"] = dialog.json }
            return .object(reply)
        case .input(let selector, let text):
            return try await script(Self.inputScript, arguments: ["selector": selector, "text": text], in: webView, frame: frame)
        case .upload(let selector, let files):
            for file in files {
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory), !isDirectory.boolValue,
                    FileManager.default.isReadableFile(atPath: file.path)
                else { throw PreviewError.uploadFileMissing(file.path) }
            }
            tab.pendingUpload = files
            defer { tab.pendingUpload = nil }
            _ = try await script(Self.uploadScript, arguments: ["selector": selector, "count": files.count], in: webView, frame: frame)
            // The page asks for files right after the click; a chooser it opens itself may take a moment.
            for _ in 0..<50 where tab.pendingUpload != nil { try await Task.sleep(for: .milliseconds(100)) }
            guard tab.pendingUpload == nil else { throw PreviewError.uploadNotAccepted }
            return ["uploaded": .array(files.map { .string($0.lastPathComponent) }), "tab": .string(tab.id)]
        case .screenshot, .fullPageScreenshot:
            return try await snapshot(webView, directory: directory, tab: tab, fullPage: command == .fullPageScreenshot)
        default:
            throw PreviewError.invalidCommand
        }
    }

    private func panelIsVisible(_ webView: WKWebView) -> Bool {
        guard let window = webView.window else { return false }
        return !PreviewParking.shared.isParked(webView) && window.isVisible && !window.isMiniaturized && !webView.isHiddenOrHasHiddenAncestor
    }

    private func viewport(of tab: PreviewTab, webView: WKWebView, dimensions: JSONValue? = nil) -> JSONValue {
        var result = dimensions?.object ?? ["width": .number(webView.bounds.width), "height": .number(webView.bounds.height)]
        result["mode"] = .string(tab.viewportSize == nil ? "panel" : "fixed")
        return .object(result)
    }

    private func script(_ body: String, arguments: [String: Any] = [:], in webView: WKWebView, frame: WKFrameInfo? = nil) async throws -> JSONValue {
        guard let tab = tabs.first(where: { $0.webView === webView }) else { throw PreviewError.noSuchTab }
        return try await withCheckedThrowingContinuation { continuation in
            let id = UUID()
            var pending: CheckedContinuation<JSONValue, Error>? = continuation
            @MainActor func finish(_ result: Result<JSONValue, Error>) {
                guard let reply = pending else { return }
                pending = nil
                tab.dialogWaiters[id] = nil
                reply.resume(with: result)
            }
            tab.dialogWaiters[id] = { finish(.success($0)) }
            Task { @MainActor in
                do {
                    let value = try await webView.callAsyncJavaScript(body, arguments: arguments, in: frame, contentWorld: .defaultClient)
                    guard let value, JSONSerialization.isValidJSONObject(value),
                        let result = JSONValue.parse(try JSONSerialization.data(withJSONObject: value))
                    else { throw PreviewError.invalidCommand }
                    finish(.success(result))
                } catch { finish(.failure(error)) }
            }
        }
    }

    private func snapshot(_ webView: WKWebView, directory: URL, tab: PreviewTab, fullPage: Bool) async throws -> JSONValue {
        if webView.superview == nil { PreviewParking.shared.park(webView) }
        let original = webView.frame
        var truncated = false
        if fullPage {
            let size = try await script("return {height: Math.max(document.body?.scrollHeight || 0, document.documentElement.scrollHeight)}", in: webView)
            let height = size["height"]?.number ?? original.height
            let bounded = min(20_000, max(original.height, height))
            truncated = height > bounded
            webView.setFrameSize(NSSize(width: original.width, height: bounded))
        }
        defer { webView.frame = original }
        _ = try? await webView.callAsyncJavaScript(Self.maskScript, arguments: ["mask": true], in: nil, contentWorld: .defaultClient)
        defer { Task { _ = try? await webView.callAsyncJavaScript(Self.maskScript, arguments: ["mask": false], in: nil, contentWorld: .defaultClient) } }
        let configuration = WKSnapshotConfiguration()
        configuration.rect = webView.bounds
        let scale = webView.window?.backingScaleFactor ?? 2
        configuration.snapshotWidth = min(1600 / scale, webView.bounds.width) as NSNumber
        let image = try await PreviewParking.shared.rendering(webView) { try await webView.takeSnapshot(configuration: configuration) }
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
            let png = bitmap.representation(using: .png, properties: [:]) else { throw PreviewError.unavailable }
        let url = directory.appendingPathComponent(fullPage ? "preview-full.png" : "preview.png")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard FileManager.default.createFile(atPath: url.path, contents: png, attributes: [.posixPermissions: 0o600]) else { throw PreviewError.unavailable }
        return ["path": .string(url.path), "mimeType": "image/png", "tab": .string(tab.id),
            "width": .number(Double(bitmap.pixelsWide)), "height": .number(Double(bitmap.pixelsHigh)), "truncated": .bool(truncated)]
    }

    /// Sends `key` to the page as real key events, so it sees trusted keystrokes and their default actions happen.
    private static func press(_ key: KeyPress, in webView: WKWebView) {
        var flags: NSEvent.ModifierFlags = []
        if key.command { flags.insert(.command) }
        if key.control { flags.insert(.control) }
        if key.option { flags.insert(.option) }
        if key.shift { flags.insert(.shift) }
        func event(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: webView.window?.windowNumber ?? 0, context: nil, characters: key.characters,
                charactersIgnoringModifiers: key.charactersIgnoringModifiers, isARepeat: false, keyCode: key.keyCode)
        }
        guard let down = event(.keyDown), let up = event(.keyUp) else { return }
        if flags.contains(.command), webView.performKeyEquivalent(with: down) { return }
        webView.keyDown(with: down)
        webView.keyUp(with: up)
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
        const root = scope ? document.querySelector(scope) : document.body;
        if (scope && !root) throw new Error('No element matches the selector.');
        const all = [...(scope ? root : document).querySelectorAll('a,button,input,textarea,select,[role="button"],[contenteditable="true"]')]
            .filter(el => el.getClientRects().length);
        const fullText = root?.innerText || '';
        const pages = Math.max(1, Math.ceil(fullText.length / 30000), Math.ceil(all.length / 200));
        const elements = all.slice((page - 1) * 200, page * 200).map(el => ({
                selector: selectorFor(el).slice(0, 4096), tag: el.tagName.toLowerCase(), type: el.type || '',
                label: (el.getAttribute('aria-label') || el.innerText || el.getAttribute('placeholder') || '').slice(0, 300),
                value: el.type === 'password' || el.type === 'file' || el.autocomplete === 'one-time-code'
                    || (window.__coincideSecretFields && window.__coincideSecretFields.has(el)) ? '' : String(el.value || '').slice(0, 1000),
                disabled: !!el.disabled
            }));
        return {url: location.href.slice(0, 8192), title: document.title.slice(0, 1000),
            text: fullText.slice((page - 1) * 30000, page * 30000), elements, page, pages,
            viewport: {width: innerWidth, height: innerHeight}};
        """#
    private static let clickScript = #"""
        const el = document.querySelector(selector);
        if (!el || !el.getClientRects().length || el.disabled || el.type === 'file') throw new Error('No visible enabled element matches the selector.');
        el.scrollIntoView({block: 'center'});
        el.click();
        return {clicked: true};
        """#
    /// Activates the file input the selector names, or the one inside or labelled by it; otherwise clicks the element
    /// (a button or drop area that opens a chooser itself). Runs as a user gesture, so the page may open its chooser.
    private static let uploadScript = #"""
        const target = document.querySelector(selector);
        if (!target) throw new Error('No element matches the selector.');
        const input = target.matches('input[type=file]') ? target
            : target.querySelector('input[type=file]')
            || (target.control && target.control.type === 'file' ? target.control : null);
        if (input) {
            if (input.disabled) throw new Error('The file input is disabled.');
            if (count > 1 && !input.multiple) throw new Error('This file input takes one file.');
            input.click();
        } else {
            if (!target.getClientRects().length || target.disabled) throw new Error('No visible enabled element matches the selector.');
            target.scrollIntoView({block: 'center'});
            target.click();
        }
        return {clicked: true};
        """#
    private static let focusScript = #"""
        const el = document.querySelector(selector);
        if (!el || !el.getClientRects().length) throw new Error('No visible element matches the selector.');
        el.scrollIntoView({block: 'center'});
        el.focus();
        return {focused: document.activeElement === el};
        """#
    /// Types like a keyboard: inserts at the end (or over everything with `clear`) through the editing commands, so
    /// rich editors see the same input events as from typing. Falls back to setting the value for a plain field.
    private static let typeScript = #"""
        const el = document.querySelector(selector);
        if (!el || !el.getClientRects().length || el.disabled || el.readOnly || el.type === 'file') throw new Error('No editable element matches the selector.');
        const editable = el.isContentEditable;
        if (!editable && !(el instanceof HTMLInputElement || el instanceof HTMLTextAreaElement)) throw new Error('The element is not a text field or editor.');
        el.scrollIntoView({block: 'center'});
        el.focus();
        const selection = getSelection();
        if (editable) {
            const range = document.createRange();
            range.selectNodeContents(el);
            if (!clear) range.collapse(false);
            selection.removeAllRanges();
            selection.addRange(range);
        } else if (clear) {
            el.select();
        } else {
            try { el.setSelectionRange(el.value.length, el.value.length); } catch (e) {}
        }
        if (clear) document.execCommand('delete');
        const before = editable ? el.textContent : el.value;
        let worked = true;
        text.split('\n').forEach((line, index) => {
            if (index > 0) {
                if (editable) worked = document.execCommand('insertParagraph') && worked;
                else if (el instanceof HTMLTextAreaElement) worked = document.execCommand('insertText', false, '\n') && worked;
            }
            if (line) worked = document.execCommand('insertText', false, line) && worked;
        });
        if (!worked && !editable) {
            const prototype = el instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
            Object.getOwnPropertyDescriptor(prototype, 'value').set.call(el, (clear ? '' : before) + text);
            el.dispatchEvent(new Event('input', {bubbles: true}));
            el.dispatchEvent(new Event('change', {bubbles: true}));
        }
        return {typed: true};
        """#
    private static let scrollScript = #"""
        const root = document.scrollingElement || document.documentElement;
        if (target === 'element') {
            const el = document.querySelector(selector);
            if (!el) throw new Error('No element matches the selector.');
            el.scrollIntoView({block: 'center'});
        } else if (target === 'top') {
            window.scrollTo(0, 0);
        } else if (target === 'bottom') {
            window.scrollTo(0, root.scrollHeight);
        } else {
            window.scrollBy(0, hasBy ? by : Math.round(innerHeight * 0.9));
        }
        return {scrollY: Math.round(scrollY), scrollHeight: root.scrollHeight, viewportHeight: innerHeight,
            atBottom: scrollY + innerHeight >= root.scrollHeight - 2};
        """#
    private static let findScript = #"""
        if (selector) {
            const el = document.querySelector(selector);
            if (!el || !el.getClientRects().length) return {found: false};
        }
        if (text && !(document.body?.innerText || '').includes(text)) return {found: false};
        return {found: true};
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
