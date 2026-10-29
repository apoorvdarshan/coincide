import AppKit
import CoincideKit

/// "Allow agents to sign in to example.com with 1Password item GitHub?": Allow Once, Always for This Site, Deny.
final class PreviewLoginApprovalBanner: ComposerBanner {
    var onAnswer: ((LoginApproval) -> Void)?
    private let heading = ComposerBanner.label(String(localized: "Sign-in request"), size: 11, weight: .semibold, color: Theme.ink)
    private let message = NSTextField(wrappingLabelWithString: "")
    private let logo = NSImageView()
    private lazy var deny = ThemedButton(title: String(localized: "Deny"), style: .secondary, target: self, action: #selector(denied))
    private lazy var always = ThemedButton(title: String(localized: "Always for This Site"), style: .secondary, target: self, action: #selector(allowAlways))
    private lazy var once = ThemedButton(title: String(localized: "Allow Once"), style: .primary, target: self, action: #selector(allowOnce))

    init() {
        super.init(tint: Theme.approvalTint)
        message.font = .systemFont(ofSize: 12)
        message.maximumNumberOfLines = 4
        message.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        logo.imageScaling = .scaleProportionallyUpOrDown
        logo.contentTintColor = Theme.ink
        logo.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([logo.widthAnchor.constraint(equalToConstant: 16), logo.heightAnchor.constraint(equalToConstant: 16)])
        let buttons = NSStackView(views: [NSView(), deny, always, once])
        buttons.orientation = .horizontal
        buttons.spacing = 6
        let column = NSStackView(views: [heading, message, buttons])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 4
        column.setCustomSpacing(8, after: message)
        for row in [message, buttons] { row.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
        content.addArrangedSubview(logo)
        content.addArrangedSubview(column)
        setAccessibilityLabel(String(localized: "Sign-in request"))
    }

    func show(_ request: LoginApprovalGate.Request) {
        let item = request.item
        let who = item.username.isEmpty ? item.title : "\(item.title) (\(item.username))"
        message.stringValue = String(localized: "Allow the agent to sign in to \(request.site) with \(item.source.displayName) login “\(who)”? Coincide types the password; the agent never sees it.")
        logo.image = PasswordManagerLogo.image(for: item.source, size: 16)
        setAccessibilityValue(message.stringValue)
    }

    @objc private func denied() { onAnswer?(.deny) }
    @objc private func allowAlways() { onAnswer?(.always) }
    @objc private func allowOnce() { onAnswer?(.allowOnce) }
}

/// "Save login for example.com?" after the user signs in on a page.
final class PreviewSaveLoginBanner: ComposerBanner {
    var onAnswer: ((_ save: Bool, _ never: Bool) -> Void)?
    private let message = NSTextField(wrappingLabelWithString: "")
    private lazy var never = ThemedButton(title: String(localized: "Never for This Site"), style: .secondary, target: self, action: #selector(neverSave))
    private lazy var later = ThemedButton(title: String(localized: "Not Now"), style: .secondary, target: self, action: #selector(notNow))
    private lazy var save = ThemedButton(title: String(localized: "Save"), style: .primary, target: self, action: #selector(saveLogin))

    init() {
        super.init()
        message.font = .systemFont(ofSize: 12)
        message.maximumNumberOfLines = 3
        message.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [NSView(), never, later, save])
        buttons.orientation = .horizontal
        buttons.spacing = 6
        let column = NSStackView(views: [message, buttons])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8
        for row in [message, buttons] { row.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
        content.addArrangedSubview(ComposerBanner.icon("key.fill", color: Theme.ink))
        content.addArrangedSubview(column)
        setAccessibilityLabel(String(localized: "Save login"))
    }

    func show(_ prompt: SavePrompt) {
        message.stringValue = prompt.username.isEmpty
            ? String(localized: "Save this login for \(prompt.site) in your Keychain?")
            : String(localized: "Save the login for \(prompt.username) on \(prompt.site) in your Keychain?")
        setAccessibilityValue(message.stringValue)
    }

    @objc private func neverSave() { onAnswer?(false, true) }
    @objc private func notNow() { onAnswer?(false, false) }
    @objc private func saveLogin() { onAnswer?(true, false) }
}

/// Password managers' marks: the installed app's own icon when there is one, else the bundled official mark.
enum PasswordManagerLogo {
    static func image(for kind: PasswordManagerKind, size: CGFloat) -> NSImage {
        if let app = kind.appBundleIDs.lazy.compactMap({ NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }).first {
            let icon = NSWorkspace.shared.icon(forFile: app.path)
            icon.size = NSSize(width: size, height: size)
            return icon
        }
        if let name = assetName(kind), let image = NSImage(named: name) {
            let copy = image.copy() as? NSImage ?? image
            copy.size = NSSize(width: size, height: size)
            return copy
        }
        return Theme.symbol(kind == .coincide ? "key.fill" : "lock.fill", size: size * 0.8) ?? NSImage()
    }

    /// The bundled mark (`Assets.xcassets/PasswordManager*.imageset`); nil for Coincide's own logins.
    static func assetName(_ kind: PasswordManagerKind) -> String? {
        switch kind {
        case .coincide: nil
        case .onePassword: "PasswordManager1Password"
        case .bitwarden: "PasswordManagerBitwarden"
        }
    }
}
