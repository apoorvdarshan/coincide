import AppKit
import CoincideKit

/// The agent's "your turn" request: its message, and Done for when the user has finished in the browser.
final class PreviewUserTurnBanner: ComposerBanner {
    var onDone: (() -> Void)?
    var onDecline: (() -> Void)?
    private let heading = ComposerBanner.label(String(localized: "Your turn"), size: 11, weight: .semibold, color: Theme.ink)
    private let message = NSTextField(wrappingLabelWithString: "")
    private lazy var done = ThemedButton(title: String(localized: "Done"), style: .primary, target: self, action: #selector(finish))
    private lazy var decline = ThemedButton(title: String(localized: "Not Now"), style: .secondary, target: self, action: #selector(skip))

    init() {
        super.init(tint: Theme.questionTint)
        message.font = .systemFont(ofSize: 12)
        message.textColor = .labelColor
        message.maximumNumberOfLines = 6
        message.isSelectable = true
        message.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        done.keyEquivalent = ""
        let buttons = NSStackView(views: [NSView(), decline, done])
        buttons.orientation = .horizontal
        buttons.spacing = 6
        let column = NSStackView(views: [heading, message, buttons])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 4
        column.setCustomSpacing(8, after: message)
        for row in [message, buttons] { row.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
        content.addArrangedSubview(ComposerBanner.icon("hand.raised.fill", color: Theme.ink))
        content.addArrangedSubview(column)
        setAccessibilityLabel(String(localized: "Your turn"))
    }

    /// The agent's words, shown as plain text.
    func show(_ text: String) {
        message.stringValue = text
        setAccessibilityValue(text)
    }

    @objc private func finish() { onDone?() }
    @objc private func skip() { onDecline?() }
}
