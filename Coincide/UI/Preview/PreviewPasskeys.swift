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

/// "Passkeys aren't available in Coincide's browser yet", after a page asks for one in a build without the browser
/// passkey entitlement. It doesn't block the page; × hides it for the site.
final class PreviewPasskeyBanner: ComposerBanner {
    var onDismiss: (() -> Void)?
    private let message = NoticeLabel(wrappingLabelWithString: "")
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
        message.stringValue = String(
            localized: "Passkeys aren’t available in Coincide’s browser yet. Choose another way to sign in (like “Try another way” on Google), then use the key button to fill your password from your password manager.")
        // In a column whose width the banner sets, as the other banners do, so the label wraps to that width.
        let column = NSStackView(views: [message])
        column.orientation = .vertical
        column.alignment = .leading
        // Room below the last line to match the space above the first.
        column.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 4, right: 0)
        column.setContentHuggingPriority(.defaultLow, for: .horizontal)
        column.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        message.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        content.addArrangedSubview(ComposerBanner.icon("person.badge.key.fill", color: Theme.ink))
        content.addArrangedSubview(column)
        content.addArrangedSubview(dismissButton)
        setAccessibilityLabel(String(localized: "Passkeys unavailable"))
        setAccessibilityValue(message.stringValue)
    }

    var text: String { message.stringValue }

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
