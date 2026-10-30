import AppKit
import CoincideKit
import WebKit

final class PreviewViewController: NSViewController, NSTextFieldDelegate {
    var threadID: UUID? { didSet { if oldValue != threadID, isViewLoaded { showThread() } } }
    /// Replaced by tests before the view loads.
    var sessions = PreviewSessions.shared
    private(set) var session: PreviewSession?
    /// Set by the inspector before it collapses or switches panels, before a hidden layout can shrink the page.
    var isPresented = true {
        didSet { if oldValue != isPresented, isViewLoaded { update() } }
    }
    private let content = PreviewPageContainer()
    private let address = ThemedTextField(placeholder: String(localized: "Search or enter address"))
    private let status = NSTextField(labelWithString: "")
    private let agentStatus = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let empty = NSTextField(wrappingLabelWithString: String(localized: "Search the web, or open a site, a local server such as localhost:3000, or a file."))
    let tabStrip = PreviewTabStrip()
    let userTurnBanner = PreviewUserTurnBanner()
    let approvalBanner = PreviewLoginApprovalBanner()
    let saveBanner = PreviewSaveLoginBanner()
    let passkeyBanner = PreviewPasskeyBanner()
    let dialogBanner = PreviewDialogBanner()
    /// The banners between the status line and the page; hidden ones take no room.
    private let banners = NSStackView()
    /// The web view shown, the active tab's.
    private weak var shownWebView: WKWebView?
    private lazy var back = PanelIconButton(symbol: "chevron.left", label: String(localized: "Back"), target: self, action: #selector(goBack))
    private lazy var forward = PanelIconButton(symbol: "chevron.right", label: String(localized: "Forward"), target: self, action: #selector(goForward))
    private lazy var reload = PanelIconButton(symbol: "arrow.clockwise", label: String(localized: "Reload Preview"), target: self, action: #selector(reloadPage))
    private lazy var bookmark = PanelIconButton(symbol: "star", label: String(localized: "Bookmark This Page"), target: self, action: #selector(toggleBookmark))
    private lazy var libraryButton = PanelIconButton(symbol: "book", label: String(localized: "Bookmarks and History"), target: self, action: #selector(showLibrary))
    /// Agent Control for this thread: a small switch in the header, on unless the user turned it off.
    lazy var control = PanelIconButton(symbol: "cursorarrow.rays", label: String(localized: "Agent Control"), target: self, action: #selector(toggleControl))
    private lazy var closePanel = PanelIconButton(symbol: "xmark", label: String(localized: "Close Browser"), target: self, action: #selector(closeBrowser))
    private var observers: [NSObjectProtocol] = []
    private var lastTypedLength = 0

    override func loadView() {
        let root = PreviewPanelView(color: Theme.contentBackground)
        root.setAccessibilityLabel(String(localized: "Browser Preview"))
        root.keyHandler = { [weak self] event in self?.handleKey(event) ?? false }
        root.visibilityChanged = { [weak self] in self?.update() }
        content.onPanelSize = { [weak self] size in self?.session?.activeTab.panelSize = size }
        address.target = self
        address.action = #selector(navigate)
        address.delegate = self
        address.setAccessibilityLabel(String(localized: "Preview Address"))
        address.setContentCompressionResistancePriority(.init(200), for: .horizontal)
        tabStrip.onSelect = { [weak self] id in self?.selectTab(id) }
        tabStrip.onClose = { [weak self] id in self?.session?.closeTab(id) }
        tabStrip.onNew = { [weak self] in self?.newTab() }
        tabStrip.setContentHuggingPriority(.defaultLow, for: .horizontal)
        tabStrip.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [tabStrip, control, closePanel])
        header.spacing = 4
        let toolbar = NSStackView(views: [back, forward, address, keyButton, bookmark, libraryButton, reload, spinner])
        toolbar.spacing = 4
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        agentStatus.font = .systemFont(ofSize: 11)
        agentStatus.textColor = .secondaryLabelColor
        agentStatus.lineBreakMode = .byTruncatingTail
        agentStatus.alignment = .right
        agentStatus.setContentCompressionResistancePriority(.init(100), for: .horizontal)
        let statusRow = NSStackView(views: [status, NSView(), agentStatus])
        statusRow.spacing = 8
        empty.textColor = .secondaryLabelColor
        empty.alignment = .center
        userTurnBanner.isHidden = true
        userTurnBanner.onDone = { [weak self] in self?.session?.userTurn.finish(.done) }
        userTurnBanner.onDecline = { [weak self] in self?.session?.userTurn.finish(.declined) }
        approvalBanner.onAnswer = { [weak self] in self?.session?.loginApproval.answer($0) }
        saveBanner.onAnswer = { [weak self] save, never in
            guard let self, let session = self.session else { return }
            session.answerSavePrompt(save: save, never: never, provider: self.sessions.profile.logins, settings: self.sessions.profile.settings)
        }
        passkeyBanner.onDismiss = { [weak self] in self?.session?.dismissPasskeyNotice() }
        dialogBanner.onAnswer = { [weak self] accept, text in self?.session?.activeTab.answerDialog(accept: accept, text: text) }
        for banner in [approvalBanner, saveBanner, passkeyBanner, dialogBanner] as [NSView] { banner.isHidden = true }
        banners.orientation = .vertical
        banners.alignment = .leading
        banners.spacing = 6
        banners.detachesHiddenViews = true
        for banner in [dialogBanner, approvalBanner, userTurnBanner, saveBanner, passkeyBanner] as [NSView] {
            banners.addArrangedSubview(banner)
            banner.widthAnchor.constraint(equalTo: banners.widthAnchor).isActive = true
        }
        for child in [header, toolbar, statusRow, banners, content] {
            child.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(child)
        }
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            header.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 6),
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            toolbar.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 6),
            statusRow.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 6),
            statusRow.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor),
            statusRow.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor),
            banners.topAnchor.constraint(equalTo: statusRow.bottomAnchor, constant: 6),
            banners.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            banners.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        contentBelowStatus = content.topAnchor.constraint(equalTo: statusRow.bottomAnchor, constant: 6)
        contentBelowBanner = content.topAnchor.constraint(equalTo: banners.bottomAnchor, constant: 8)
        contentBelowStatus.isActive = true
        empty.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(empty)
        NSLayoutConstraint.activate([
            empty.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            empty.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            empty.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
        ])
        view = root
        let center = NotificationCenter.default
        for name in [PreviewSessions.sessionsReset, PreviewSessions.agentControlChanged] {
            let reset = name == PreviewSessions.sessionsReset
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if reset { self.showThread() } else { self.update() }
                }
            })
        }
        observers.append(center.addObserver(forName: BrowserLibrary.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateBookmark() }
        })
        showThread()
    }

    private var contentBelowStatus: NSLayoutConstraint!
    private var focusObserver: NSObjectProtocol?

    /// Tooltips name ⌘T and ⌘W only while they reach the panel, that is while focus is inside it.
    override func viewDidAppear() {
        super.viewDidAppear()
        update()
        guard focusObserver == nil, let window = view.window else { return }
        focusObserver = NotificationCenter.default.addObserver(forName: NSWindow.didUpdateNotification, object: window, queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.tabStrip.shortcutsActive = (self.view as? PreviewPanelView)?.containsFocus ?? false
            }
        }
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        if let focusObserver { NotificationCenter.default.removeObserver(focusObserver) }
        focusObserver = nil
    }
    private var contentBelowBanner: NSLayoutConstraint!

    isolated deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    private func showThread() {
        // The previous thread's tabs go back offscreen, where its agent can keep using them.
        if let previous = session { previous.onChange = nil }
        parkShownWebView()
        session = threadID.map { sessions.session(for: $0) }
        session?.onChange = { [weak self] in self?.update() }
        address.stringValue = session?.webView.url?.absoluteString ?? ""
        update()
    }

    private func parkShownWebView() {
        guard let shown = shownWebView else { return }
        content.removePage()
        shown.removeFromSuperview()
        shown.translatesAutoresizingMaskIntoConstraints = true
        PreviewParking.shared.park(shown)
        shownWebView = nil
    }

    /// Puts the active tab's web view in the panel, returning the one shown before to the parking window.
    private func showActiveTab() {
        guard isPresented, view.window != nil, !view.isHiddenOrHasHiddenAncestor, let session else {
            parkShownWebView()
            return
        }
        let web = session.webView
        guard web !== shownWebView else { return }
        // Switching tabs keeps focus in the panel, so its shortcuts go on working (⌘W must not fall to Archive Thread).
        let hadFocus = shownWebView.map { shown in
            (view.window?.firstResponder as? NSView)?.isDescendant(of: shown) ?? false
        } ?? false
        parkShownWebView()
        web.removeFromSuperview()
        web.translatesAutoresizingMaskIntoConstraints = true
        content.viewportSize = session.activeTab.viewportSize
        content.show(web)
        content.needsLayout = true
        content.layoutSubtreeIfNeeded()
        shownWebView = web
        if hadFocus { view.window?.makeFirstResponder(web) }
        if address.currentEditor() == nil { address.stringValue = web.url?.absoluteString ?? "" }
    }

    private func update() {
        showActiveTab()
        content.viewportSize = session?.activeTab.viewportSize
        content.needsLayout = true
        content.layoutSubtreeIfNeeded()
        tabStrip.update((session?.tabs ?? []).map { tab in
            PreviewTabStrip.Tab(id: tab.id, title: tab.title.isEmpty ? (tab.url?.host ?? "") : tab.title,
                isActive: tab === session?.activeTab, isLoading: tab.isLoading)
        })
        tabStrip.isHidden = session == nil
        let loading = session?.webView.isLoading == true
        if loading { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        back.isEnabled = session?.webView.canGoBack == true
        forward.isEnabled = session?.webView.canGoForward == true
        reload.isEnabled = session?.webView.url != nil
        address.isEnabled = session != nil
        if address.currentEditor() == nil { address.stringValue = session?.webView.url?.absoluteString ?? "" }
        let enabled = threadID.map { sessions.isAgentControlEnabled($0) } ?? false
        control.isEnabled = session != nil
        control.image = Theme.symbol(enabled ? "cursorarrow.rays" : "cursorarrow.slash", size: 12, weight: .medium)
        control.toolTip = enabled
            ? String(localized: "Agent Control is on: this thread's agent can use its browser. Click to turn it off for this thread.")
            : String(localized: "Agent Control is off for this thread. Click to let its agent use the browser.")
        control.setAccessibilityValue(enabled ? String(localized: "On") : String(localized: "Off"))
        agentStatus.stringValue = agentStatusText(enabled: enabled)
        status.stringValue = session?.error ?? (session?.isPrivate == true
            ? String(localized: "Private preview · cookies are cleared when Coincide quits")
            : String(localized: "Shared browser profile · sign-ins are kept across threads"))
        status.textColor = session?.error == nil ? .secondaryLabelColor : Theme.failure
        empty.isHidden = session?.webView.url != nil || loading
        let request = session?.userTurn.request
        if let request { userTurnBanner.show(request.message) }
        userTurnBanner.isHidden = request == nil
        let approval = session?.loginApproval.request
        if let approval { approvalBanner.show(approval) }
        approvalBanner.isHidden = approval == nil
        let save = session?.savePrompt
        if let save { saveBanner.show(save) }
        saveBanner.isHidden = save == nil
        let passkeyNotice = session?.activePasskeyNotice
        passkeyBanner.isHidden = passkeyNotice == nil
        let dialog = session?.activeTab.dialog
        if let dialog { dialogBanner.show(dialog) }
        dialogBanner.isHidden = dialog == nil
        let showsBanner = request != nil || approval != nil || save != nil || passkeyNotice != nil || dialog != nil
        contentBelowStatus.isActive = false
        contentBelowBanner.isActive = showsBanner
        contentBelowStatus.isActive = !showsBanner
        keyButton.isEnabled = session?.webView.url != nil
        updateBookmark()
    }

    private func agentStatusText(enabled: Bool) -> String {
        guard enabled else { return String(localized: "Agent Control off") }
        if let used = session?.lastAgentUse {
            let ago = RelativeDateTimeFormatter().localizedString(for: used, relativeTo: Date())
            return String(localized: "The agent used this browser \(ago).")
        }
        return String(localized: "Agent Control on")
    }

    // MARK: Tabs

    func newTab() {
        guard let session else { return }
        if session.newTab() == nil {
            status.stringValue = PreviewError.tooManyTabs.localizedDescription
            status.textColor = Theme.failure
            return
        }
        view.window?.makeFirstResponder(address)
    }

    func selectTab(_ id: String) {
        guard let session, let tab = session.tab(id) else { return }
        session.select(tab)
    }

    /// ⌘T, ⌘W and ⌘⇧[ / ⌘⇧] while focus is in the panel. Elsewhere they keep their usual meaning (⌘W archives the
    /// thread, as the menu says).
    func handleKey(_ event: NSEvent) -> Bool {
        guard let session, (view as? PreviewPanelView)?.containsFocus == true,
            let shortcut = KeyShortcut(event: event)
        else { return false }
        if shortcut == KeyShortcut("mod+t") {
            newTab()
        } else if shortcut == KeyShortcut("mod+w") {
            session.closeTab(session.activeTab.id)
            view.window?.makeFirstResponder(session.webView)
        } else if shortcut == KeyShortcut("mod+shift+]") {
            session.selectTab(offset: 1)
        } else if shortcut == KeyShortcut("mod+shift+[") {
            session.selectTab(offset: -1)
        } else {
            return false
        }
        return true
    }

    @objc private func closeBrowser() {
        NSApp.sendAction(#selector(MainWindowController.togglePreviewPanel(_:)), to: nil, from: self)
    }

    private func updateBookmark() {
        let marked = session?.webView.url.map { sessions.profile.library.isBookmarked($0) } ?? false
        bookmark.image = Theme.symbol(marked ? "star.fill" : "star", size: 12, weight: .medium)
        bookmark.toolTip = marked ? String(localized: "Remove Bookmark") : String(localized: "Bookmark This Page")
        bookmark.setAccessibilityLabel(bookmark.toolTip)
        bookmark.isEnabled = session?.webView.url != nil && session?.isPrivate == false
    }

    // MARK: Address

    @objc private func navigate() {
        do { try session?.navigate(address.stringValue) }
        catch { status.stringValue = error.localizedDescription; status.textColor = Theme.failure }
    }

    /// Completes the address inline from bookmarks and history as the user types, selecting the added part.
    func controlTextDidChange(_ notification: Notification) {
        guard let editor = address.currentEditor() as? NSTextView else { return }
        let typed = editor.string
        defer { lastTypedLength = (typed as NSString).length }
        // Deleting shouldn't bring the completion back.
        guard (typed as NSString).length > lastTypedLength, editor.selectedRange().location == (typed as NSString).length,
            session?.isPrivate == false, let completion = sessions.profile.library.inlineCompletion(for: typed)
        else { return }
        let start = (typed as NSString).length
        editor.string = completion
        editor.setSelectedRange(NSRange(location: start, length: (completion as NSString).length - start))
    }

    func controlTextDidBeginEditing(_ notification: Notification) { lastTypedLength = (address.stringValue as NSString).length }

    @objc private func goBack() { session?.webView.goBack() }
    @objc private func goForward() { session?.webView.goForward() }
    @objc private func reloadPage() { session?.webView.reload() }

    // MARK: Passwords

    private lazy var keyButton = PanelIconButton(symbol: "key", label: String(localized: "Fill Saved Login"), target: self, action: #selector(showLogins))

    /// The logins saved for this page in the password managers that are on; choosing one fills it. The user's own
    /// choice, so no approval is asked.
    @objc private func showLogins() {
        guard let session, let page = session.webView.url, let host = page.host else { return }
        let vault = sessions.vault
        Task { [weak self] in
            let found = await vault.candidates(for: page)
            guard let self, self.session === session else { return }
            let menu = NSMenu()
            if vault.enabledKinds.isEmpty {
                menu.addItem(NSMenuItem(title: String(localized: "No password manager is on"), action: nil, keyEquivalent: ""))
            } else if found.items.isEmpty {
                menu.addItem(NSMenuItem(title: String(localized: "No saved logins for \(WebDomain.siteOrHost(host))"), action: nil, keyEquivalent: ""))
            }
            for item in found.items.prefix(20) {
                let name = item.username.isEmpty ? item.title : "\(item.title) — \(item.username)"
                menu.addItem(self.action(name, image: PasswordManagerLogo.image(for: item.source, size: 14)) { [weak self] in
                    self?.fill(item, codeOnly: false)
                })
                if item.hasTOTP != false {
                    menu.addItem(self.action(String(localized: "One-Time Code for \(item.title)"), image: nil) { [weak self] in
                        self?.fill(item, codeOnly: true)
                    })
                }
            }
            for (kind, message) in found.failures.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                menu.addItem(NSMenuItem(title: "\(kind.displayName): \(message)", action: nil, keyEquivalent: ""))
            }
            menu.addItem(.separator())
            menu.addItem(self.action(String(localized: "Password Settings…"), image: nil) { AppEvents.showSettings(section: .browser) })
            _ = ThemedPopup.show(menu: menu, from: self.keyButton, preferAbove: false)
        }
    }

    private func action(_ title: String, image: NSImage?, _ run: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: String(title.prefix(90)), action: #selector(PickerChoice.choose(_:)), keyEquivalent: "")
        let choice = PickerChoice(run)
        item.target = choice
        item.representedObject = choice
        item.image = image
        return item
    }

    private func fill(_ item: LoginItem, codeOnly: Bool) {
        guard let session else { return }
        Task { [weak self] in
            do { try await self?.sessions.autofill(item, in: session, codeOnly: codeOnly) } catch {
                self?.status.stringValue = error.localizedDescription
                self?.status.textColor = Theme.failure
            }
        }
    }

    // MARK: Bookmarks

    @objc private func toggleBookmark() {
        guard let session, let url = session.webView.url else { return }
        let library = sessions.profile.library
        if library.isBookmarked(url) { library.removeBookmark(url: url) } else { library.addBookmark(url: url, title: session.webView.title ?? "") }
    }

    @objc private func showLibrary() {
        let library = sessions.profile.library
        let menu = NSMenu()
        let bookmarks = library.bookmarks.suffix(30).reversed()
        if !bookmarks.isEmpty {
            menu.addItem(.sectionHeader(title: String(localized: "Bookmarks")))
            for item in bookmarks { menu.addItem(open(item.url, title: item.title)) }
        }
        let recent = library.history.sorted { $0.lastVisit > $1.lastVisit }.prefix(12)
        if !recent.isEmpty, session?.isPrivate == false {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            menu.addItem(.sectionHeader(title: String(localized: "Recently Visited")))
            for item in recent { menu.addItem(open(item.url, title: item.title.isEmpty ? item.url : item.title)) }
        }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        let settings = NSMenuItem(title: String(localized: "Browser Settings…"), action: #selector(PickerChoice.choose(_:)), keyEquivalent: "")
        let choice = PickerChoice { AppEvents.showSettings(section: .browser) }
        settings.target = choice
        settings.representedObject = choice
        menu.addItem(settings)
        _ = ThemedPopup.show(menu: menu, from: libraryButton, preferAbove: false)
    }

    private func open(_ address: String, title: String) -> NSMenuItem {
        let item = NSMenuItem(title: String(title.prefix(80)), action: #selector(PickerChoice.choose(_:)), keyEquivalent: "")
        let choice = PickerChoice { [weak self] in try? self?.session?.navigate(address) }
        item.target = choice
        item.representedObject = choice
        item.toolTip = address
        return item
    }

    // MARK: Agent control

    @objc private func toggleControl() {
        guard let id = threadID else { return }
        let enable = !sessions.isAgentControlEnabled(id)
        sessions.setAgentControl(enable, for: id)
        update()
        guard enable else { return }
        Task { [weak self] in
            do { try await self?.sessions.enableAccess(for: id) } catch {
                self?.status.stringValue = error.localizedDescription
                self?.status.textColor = Theme.failure
            }
        }
    }
}

/// Normal browsing fills the panel. A fixed testing viewport remains its requested size inside a scrollable canvas,
/// so its right and bottom edges stay reachable in a smaller panel without changing page zoom or the site's CSS.
private final class PreviewPageContainer: NSView {
    var viewportSize: NSSize? {
        didSet {
            scroll.hasHorizontalScroller = viewportSize != nil
            scroll.hasVerticalScroller = viewportSize != nil
            scroll.tile()
            sizePage()
        }
    }
    var onPanelSize: ((NSSize) -> Void)?
    private let scroll = NSScrollView()
    private weak var page: WKWebView?
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.autohidesScrollers = true
        scroll.autoresizingMask = [.width, .height]
        scroll.frame = bounds
        addSubview(scroll)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ page: WKWebView) {
        self.page = page
        page.autoresizingMask = []
        scroll.documentView = page
        sizePage()
    }

    func removePage() {
        scroll.documentView = nil
        page = nil
    }

    override func layout() {
        super.layout()
        scroll.frame = bounds
        scroll.layoutSubtreeIfNeeded()
        sizePage()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        scroll.frame = bounds
        sizePage()
    }

    private func sizePage() {
        guard let page, bounds.width > 0, bounds.height > 0 else { return }
        let available = scroll.contentSize
        guard available.width > 0, available.height > 0 else { return }
        onPanelSize?(bounds.size)
        page.setFrameSize(viewportSize ?? available)
        if viewportSize == nil { scroll.contentView.scroll(to: .zero) }
    }
}
