import AppKit
import CoincideKit
import WebKit

final class PreviewViewController: NSViewController, NSTextFieldDelegate {
    var threadID: UUID? { didSet { if oldValue != threadID, isViewLoaded { showThread() } } }
    /// Replaced by tests before the view loads.
    var sessions = PreviewSessions.shared
    private(set) var session: PreviewSession?
    private let content = NSView()
    private let address = ThemedTextField(placeholder: "http://localhost:3000")
    private let status = NSTextField(wrappingLabelWithString: "")
    private let agentStatus = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let empty = NSTextField(wrappingLabelWithString: String(localized: "Open a page to preview it beside your conversation."))
    let userTurnBanner = PreviewUserTurnBanner()
    private lazy var back = PanelIconButton(symbol: "chevron.left", label: String(localized: "Back"), target: self, action: #selector(goBack))
    private lazy var forward = PanelIconButton(symbol: "chevron.right", label: String(localized: "Forward"), target: self, action: #selector(goForward))
    private lazy var reload = PanelIconButton(symbol: "arrow.clockwise", label: String(localized: "Reload Preview"), target: self, action: #selector(reloadPage))
    private lazy var bookmark = PanelIconButton(symbol: "star", label: String(localized: "Bookmark This Page"), target: self, action: #selector(toggleBookmark))
    private lazy var libraryButton = PanelIconButton(symbol: "book", label: String(localized: "Bookmarks and History"), target: self, action: #selector(showLibrary))
    lazy var control = ThemedButton(title: String(localized: "Enable Agent Control"), style: .secondary, target: self, action: #selector(toggleControl))
    private var observers: [NSObjectProtocol] = []
    private var lastTypedLength = 0

    override func loadView() {
        let root = SolidBackgroundView(color: Theme.contentBackground)
        root.setAccessibilityLabel(String(localized: "Browser Preview"))
        address.target = self
        address.action = #selector(navigate)
        address.delegate = self
        address.setAccessibilityLabel(String(localized: "Preview Address"))
        address.setContentCompressionResistancePriority(.init(200), for: .horizontal)
        let toolbar = NSStackView(views: [back, forward, address, bookmark, libraryButton, reload, spinner])
        toolbar.spacing = 4
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        agentStatus.font = .systemFont(ofSize: 11)
        agentStatus.textColor = .secondaryLabelColor
        agentStatus.lineBreakMode = .byTruncatingTail
        agentStatus.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        empty.textColor = .secondaryLabelColor
        empty.alignment = .center
        userTurnBanner.isHidden = true
        userTurnBanner.onDone = { [weak self] in self?.session?.userTurn.finish(.done) }
        userTurnBanner.onDecline = { [weak self] in self?.session?.userTurn.finish(.declined) }
        let footer = NSStackView(views: [control, agentStatus])
        footer.alignment = .centerY
        footer.spacing = 8
        control.toolTip = String(localized: "Lets this thread's agent read and control its browser through a private local connection. Agents can't read cookies, site storage or passwords.")
        for child in [toolbar, status, userTurnBanner, content, footer] {
            child.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(child)
        }
        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            toolbar.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 8),
            status.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 6),
            status.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor),
            userTurnBanner.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 6),
            userTurnBanner.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            userTurnBanner.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -8),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            footer.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -8),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
        ])
        contentBelowStatus = content.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 6)
        contentBelowBanner = content.topAnchor.constraint(equalTo: userTurnBanner.bottomAnchor, constant: 8)
        contentBelowStatus.isActive = true
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
    private var contentBelowBanner: NSLayoutConstraint!

    isolated deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    private func showThread() {
        // The previous thread's browser goes back offscreen, where its agent can keep using it.
        if let previous = session {
            previous.onChange = nil
            if previous.webView.isDescendant(of: content) {
                previous.webView.removeFromSuperview()
                PreviewParking.shared.park(previous.webView)
            }
        }
        for subview in content.subviews { subview.removeFromSuperview() }
        session = threadID.map { sessions.session(for: $0) }
        if let session {
            session.onChange = { [weak self] in self?.update() }
            let web = session.webView
            web.removeFromSuperview()
            web.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(web)
            NSLayoutConstraint.activate([
                web.leadingAnchor.constraint(equalTo: content.leadingAnchor), web.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                web.topAnchor.constraint(equalTo: content.topAnchor), web.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            ])
        }
        empty.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(empty)
        NSLayoutConstraint.activate([
            empty.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            empty.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            empty.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
        ])
        address.stringValue = session?.webView.url?.absoluteString ?? ""
        update()
    }

    private func update() {
        let loading = session?.webView.isLoading == true
        if loading { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        back.isEnabled = session?.webView.canGoBack == true
        forward.isEnabled = session?.webView.canGoForward == true
        reload.isEnabled = session?.webView.url != nil
        address.isEnabled = session != nil
        if address.currentEditor() == nil, let url = session?.webView.url { address.stringValue = url.absoluteString }
        let enabled = threadID.map { sessions.isAgentControlEnabled($0) } ?? false
        control.isEnabled = session != nil
        control.title = enabled ? String(localized: "Disable Agent Control") : String(localized: "Enable Agent Control")
        agentStatus.stringValue = agentStatusText(enabled: enabled)
        status.stringValue = session?.error ?? (session?.isPrivate == true
            ? String(localized: "Private preview · cookies are cleared when Coincide quits")
            : String(localized: "Shared browser profile · sign-ins are kept across threads"))
        status.textColor = session?.error == nil ? .secondaryLabelColor : Theme.failure
        empty.isHidden = session?.webView.url != nil || loading
        let request = session?.userTurn.request
        if let request { userTurnBanner.show(request.message) }
        userTurnBanner.isHidden = request == nil
        contentBelowBanner.isActive = request != nil
        contentBelowStatus.isActive = request == nil
        updateBookmark()
    }

    private func agentStatusText(enabled: Bool) -> String {
        guard enabled else { return String(localized: "Agents can't use this browser.") }
        if let used = session?.lastAgentUse {
            let ago = RelativeDateTimeFormatter().localizedString(for: used, relativeTo: Date())
            return String(localized: "The agent used this browser \(ago).")
        }
        return String(localized: "The agent can use this browser, even while the panel is closed.")
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
