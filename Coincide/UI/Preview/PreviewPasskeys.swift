import AppKit
import CoincideKit
import WebKit

/// Receives `PasskeySupport.detectionScript`'s reports from any frame of a tab. Holds its session weakly; WebKit
/// retains the handler. Pages a tab opens share its handler, so the tab is found by the message's web view.
final class PasskeyRequestHandler: NSObject, WKScriptMessageHandler {
    weak var session: PreviewSession?

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let session, let webView = message.webView else { return }
        session.passkeyRequested(in: webView)
    }
}

/// What the passkey notice's actions reach outside the thread's browser: the user's default browser, its saved
/// sign-ins, Full Disk Access and Settings. Tests replace it, so nothing opens another app, reads a real browser's
/// data, asks for the Keychain or shows a window.
struct PasskeyHandoffServices {
    /// The browser web links open in; nil when macOS has none.
    var defaultBrowser: () -> PasskeyHandoff.Browser?
    /// Opens a page in `browser`, or wherever macOS opens web links when it's nil.
    var open: (URL, PasskeyHandoff.Browser?) -> Void
    /// Reads a site's sign-in from a browser, off the main thread.
    var readSignIn: (_ site: String, _ browser: BrowserCatalog.Definition) async -> PasskeyHandoff.Outcome
    var requestFullDiskAccess: () -> Void
    /// Settings › Browser › Import, for a browser Coincide can't import from by itself.
    var showImport: () -> Void

    static let live = PasskeyHandoffServices(
        defaultBrowser: {
            guard let probe = URL(string: "https://example.com"), let app = NSWorkspace.shared.urlForApplication(toOpen: probe)
            else { return nil }
            return PasskeyHandoff.browser(appURL: app, bundleID: Bundle(url: app)?.bundleIdentifier,
                name: FileManager.default.displayName(atPath: app.path), ownBundleID: Bundle.main.bundleIdentifier)
        },
        open: { url, browser in
            if let browser {
                NSWorkspace.shared.open([url], withApplicationAt: browser.appURL, configuration: NSWorkspace.OpenConfiguration())
            } else {
                NSWorkspace.shared.open(url)
            }
        },
        readSignIn: { site, definition in
            // Finding the browser never prompts; reading it may (Full Disk Access, a Chromium browser's Keychain key).
            let home = FileManager.default.homeDirectoryForCurrentUser
            let detected = BrowserCatalog.detect(definition, home: home) { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
            return await Task.detached {
                PasskeyHandoff.readSignIn(site: site, from: detected, home: home) { SafeStorageKeychain.password(services: $0) }
            }.value
        },
        requestFullDiskAccess: { FullDiskAccess.request() },
        showImport: { BrowserSettingsView.showImport() })
}

/// "Passkeys aren't available in Coincide's browser yet", after a page asks for one in a build without the browser
/// passkey entitlement, with the way around it: open the page in the user's own browser, sign in there, then import
/// that sign-in. It doesn't block the page; × remembers the acknowledgment across browser sessions.
final class PreviewPasskeyBanner: ComposerBanner {
    enum Action: Equatable {
        case open
        case importSignIn
        case allowFullDiskAccess
    }

    /// What the notice says and offers at one stage.
    struct Content: Equatable {
        var message: String
        var button: String?
        var action: Action?
        var isPrimary = true
    }

    var onAction: ((Action) -> Void)?
    var onDismiss: (() -> Void)?
    private let message = NoticeLabel(wrappingLabelWithString: "")
    private(set) lazy var actionButton = ThemedButton(title: "", style: .primary, target: self, action: #selector(act))
    private lazy var buttons = NSStackView(views: [NSView(), actionButton])
    private var action: Action?
    private var shown: Content?
    private(set) lazy var dismissButton: NSButton = {
        let label = String(localized: "Dismiss")
        let button = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: label) ?? NSImage(),
            target: self, action: #selector(dismiss))
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        return button
    }()

    init() {
        super.init(tint: Theme.questionTint)
        message.font = .systemFont(ofSize: 12)
        message.isSelectable = true
        message.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // A long browser name squeezes its button, which then shortens its title, rather than widening the banner.
        actionButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        buttons.orientation = .horizontal
        buttons.spacing = 6
        // In a column whose width the banner sets, as the other banners do, so the label wraps to that width.
        let column = NSStackView(views: [message, buttons])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8
        column.detachesHiddenViews = true
        // Room below the last line to match the space above the first.
        column.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 4, right: 0)
        column.setContentHuggingPriority(.defaultLow, for: .horizontal)
        column.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for row in [message, buttons] { row.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
        content.addArrangedSubview(ComposerBanner.icon("person.badge.key.fill", color: Theme.ink))
        content.addArrangedSubview(column)
        content.addArrangedSubview(dismissButton)
        setAccessibilityLabel(String(localized: "Passkeys unavailable"))
        show(PasskeyNoticeState.Notice(tabID: "", site: ""))
    }

    var text: String { message.stringValue }
    /// The action button's title while it shows.
    var actionTitle: String? { buttons.isHidden ? nil : actionButton.title }

    func show(_ notice: PasskeyNoticeState.Notice) {
        let content = Self.content(for: notice)
        // The panel refreshes often; setting the same text again would drop the user's selection in it.
        guard content != shown else { return }
        shown = content
        message.stringValue = content.message
        action = content.action
        actionButton.title = content.button ?? ""
        actionButton.setAccessibilityLabel(content.button)
        actionButton.style = content.isPrimary ? .primary : .secondary
        actionButton.invalidateIntrinsicContentSize()
        buttons.isHidden = content.button == nil
        setAccessibilityValue(content.message)
    }

    /// The notice's words and its one action, by stage. The browser is named where it's known; without one, "Open"
    /// uses whatever macOS opens web links in, and the import goes through Settings, where the user picks the browser.
    static func content(for notice: PasskeyNoticeState.Notice) -> Content {
        let site = notice.site
        guard let browser = notice.browser else {
            if notice.stage == .unavailable {
                return Content(
                    message: String(localized: "Passkeys aren’t available in Coincide’s browser yet. Sign in with your passkey in your browser, then import that sign-in here. Or choose another way to sign in (like “Try another way” on Google), then use the key button to fill your password from your password manager."),
                    button: String(localized: "Open in Default Browser"), action: .open)
            }
            return Content(message: String(localized: "Signed in to \(site) in your browser? Import that sign-in to use it here."),
                button: String(localized: "Import Sign-In…"), action: .importSignIn)
        }
        let name = browser.name
        var isChromium = false
        if case .chromium = browser.importable?.engine { isChromium = true }
        switch notice.stage {
        case .unavailable:
            return Content(
                message: String(localized: "Passkeys aren’t available in Coincide’s browser yet. Sign in with your passkey in \(name), then import that sign-in here. Or choose another way to sign in (like “Try another way” on Google), then use the key button to fill your password from your password manager."),
                button: String(localized: "Open in \(name)"), action: .open)
        case .awaitingImport:
            guard browser.importable != nil else {
                return Content(message: String(localized: "Signed in to \(site) in \(name)? Import that sign-in to use it here."),
                    button: String(localized: "Import Sign-In…"), action: .importSignIn)
            }
            // Chromium browsers keep new cookies in memory for up to half a minute before saving them.
            return Content(
                message: isChromium
                    ? String(localized: "Signed in to \(site) in \(name)? Wait half a minute for it to save the sign-in, then import it here.")
                    : String(localized: "Signed in to \(site) in \(name)? Import that sign-in to use it here."),
                button: String(localized: "Import Sign-In"), action: .importSignIn)
        case .importing:
            return Content(
                message: isChromium
                    ? String(localized: "Importing your \(site) sign-in from \(name)… If macOS asks whether Coincide may use its Keychain key, choose Allow.")
                    : String(localized: "Importing your \(site) sign-in from \(name)…"),
                button: nil, action: nil)
        case .imported:
            return Content(
                message: String(localized: "Imported your \(site) sign-in from \(name) and reloaded the page. If it still asks you to sign in, wait a moment and import again."),
                button: String(localized: "Import Again"), action: .importSignIn, isPrimary: false)
        case .failed(.nothingFound):
            return Content(message: String(localized: "\(name) has no sign-in for \(site) yet. Sign in there, wait a moment, then try again."),
                button: String(localized: "Try Again"), action: .importSignIn)
        case .failed(.problem(.needsFullDiskAccess)):
            return Content(
                message: String(localized: "macOS protects \(name)’s data, so Coincide needs Full Disk Access to import your sign-in from it."),
                button: String(localized: "Allow Full Disk Access…"), action: .allowFullDiskAccess)
        case .failed(.problem(.keyUnavailable)):
            return Content(
                message: String(localized: "\(name)’s Keychain key wasn’t available, so nothing was imported. Try again and choose Allow when macOS asks."),
                button: String(localized: "Try Again"), action: .importSignIn)
        case .failed(.problem(.undecryptable)), .failed(.problem(.unreadable)):
            return Content(message: String(localized: "Coincide couldn’t read \(name)’s sign-ins, so nothing was imported."),
                button: String(localized: "Try Again"), action: .importSignIn)
        }
    }

    @objc private func act() {
        guard let action else { return }
        onAction?(action)
    }

    @objc private func dismiss() { onDismiss?() }
}

/// A label that wraps to the width layout gives it, measured slightly narrower than it draws. A text field's height
/// for a width can count a line fewer than drawing at that width needs (it leaves out the line fragment padding), and
/// the last line is then clipped; measuring narrower costs at most a spare line's height.
private final class NoticeLabel: NSTextField {
    override func layout() {
        super.layout()
        let width = max(0, alignmentRect(forFrame: frame).width - 16)
        guard preferredMaxLayoutWidth != width else { return }
        preferredMaxLayoutWidth = width
        invalidateIntrinsicContentSize()
    }
}
