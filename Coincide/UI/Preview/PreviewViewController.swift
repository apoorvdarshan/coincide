import AppKit
import CoincideKit

final class PreviewViewController: NSViewController {
    var threadID: UUID? { didSet { if oldValue != threadID, isViewLoaded { showThread() } } }
    private var session: PreviewSession?
    private let content = NSView()
    private let address = ThemedTextField(placeholder: String(localized: "http://localhost:3000"))
    private let status = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    private let empty = NSTextField(wrappingLabelWithString: String(localized: "Open a page to preview it beside your conversation."))
    private lazy var back = PanelIconButton(symbol: "chevron.left", label: String(localized: "Back"), target: self, action: #selector(goBack))
    private lazy var forward = PanelIconButton(symbol: "chevron.right", label: String(localized: "Forward"), target: self, action: #selector(goForward))
    private lazy var reload = PanelIconButton(symbol: "arrow.clockwise", label: String(localized: "Reload Preview"), target: self, action: #selector(reloadPage))
    private lazy var control = ThemedButton(title: String(localized: "Enable Agent Control"), style: .secondary, target: self, action: #selector(toggleControl))
    private var enabling = false

    override func loadView() {
        let root = SolidBackgroundView(color: Theme.contentBackground)
        root.setAccessibilityLabel(String(localized: "Browser Preview"))
        address.target = self
        address.action = #selector(navigate)
        address.setAccessibilityLabel(String(localized: "Preview Address"))
        address.setContentCompressionResistancePriority(.init(200), for: .horizontal)
        let toolbar = NSStackView(views: [back, forward, address, reload, spinner])
        toolbar.spacing = 4
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        empty.textColor = .secondaryLabelColor
        empty.alignment = .center
        let footer = NSStackView(views: [control])
        footer.alignment = .leading
        control.toolTip = String(localized: "Lets this thread's agent read and control its preview through a local shell connection. Turns off when Coincide quits.")
        for child in [toolbar, status, content, footer] {
            child.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(child)
        }
        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            toolbar.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            status.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 6),
            status.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor),
            content.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 6),
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -8),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            footer.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -8),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
        ])
        view = root
        showThread()
    }

    private func showThread() {
        session?.onChange = nil
        for subview in content.subviews { subview.removeFromSuperview() }
        session = threadID.map { PreviewSessions.shared.session(for: $0) }
        if let session {
            session.onChange = { [weak self] in self?.update() }
            let web = session.webView
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
        control.isEnabled = session != nil && !enabling
        let enabled = threadID.flatMap { PreviewSessions.shared.bridge.access(for: $0) } != nil
        control.title = enabled ? String(localized: "Disable Agent Control") : String(localized: "Enable Agent Control")
        status.stringValue = session?.error ?? (enabled
            ? String(localized: "Agent control is on. Send a message to give the agent access.")
            : String(localized: "Private preview · cookies are cleared when Coincide quits"))
        status.textColor = session?.error == nil ? .secondaryLabelColor : .systemRed
        empty.isHidden = session?.webView.url != nil || loading
    }

    @objc private func navigate() {
        do { try session?.navigate(address.stringValue) }
        catch { status.stringValue = error.localizedDescription; status.textColor = .systemRed }
    }
    @objc private func goBack() { session?.webView.goBack() }
    @objc private func goForward() { session?.webView.goForward() }
    @objc private func reloadPage() { session?.webView.reload() }

    @objc private func toggleControl() {
        guard let id = threadID, let session else { return }
        let bridge = PreviewSessions.shared.bridge
        if bridge.access(for: id) != nil { bridge.disable(threadID: id); update(); return }
        enabling = true
        update()
        Task { [weak self, session] in
            do {
                _ = try await bridge.enable(threadID: id) { [weak session] command, directory in
                    guard let session else { throw PreviewError.unavailable }
                    return try await session.perform(command, directory: directory)
                }
                self?.enabling = false
                self?.update()
            } catch {
                self?.enabling = false
                self?.update()
                self?.status.stringValue = error.localizedDescription
                self?.status.textColor = .systemRed
            }
        }
    }
}
