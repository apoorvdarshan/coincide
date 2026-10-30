import AppKit
import CoincideKit

/// A page's `alert`, `confirm` or `prompt`. The page waits until the agent (`dialog`) or the user (the panel's
/// banner) answers it.
struct PreviewDialog {
    enum Kind: String {
        case alert
        case confirm
        case prompt
    }

    let kind: Kind
    let message: String
    let defaultText: String?
    /// OK or Cancel, with the text typed for a prompt.
    let respond: (Bool, String?) -> Void

    /// What `read` reports to the agent.
    var json: JSONValue {
        var object: [String: JSONValue] = ["type": .string(kind.rawValue), "message": .string(String(message.prefix(4000)))]
        if let defaultText { object["default"] = .string(String(defaultText.prefix(4000))) }
        return .object(object)
    }
}

/// The page's dialog in the browser panel, for the user to answer.
final class PreviewDialogBanner: ComposerBanner {
    var onAnswer: ((Bool, String?) -> Void)?
    private let heading = ComposerBanner.label(String(localized: "The page asks"), size: 11, weight: .semibold, color: Theme.ink)
    private let message = NSTextField(wrappingLabelWithString: "")
    private let field = ThemedTextField(placeholder: "")
    private lazy var ok = ThemedButton(title: String(localized: "OK"), style: .primary, target: self, action: #selector(accept))
    private lazy var cancel = ThemedButton(title: String(localized: "Cancel"), style: .secondary, target: self, action: #selector(dismiss))

    init() {
        super.init(tint: Theme.questionTint)
        message.font = .systemFont(ofSize: 12)
        message.textColor = .labelColor
        message.maximumNumberOfLines = 8
        message.isSelectable = true
        message.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [NSView(), cancel, ok])
        buttons.orientation = .horizontal
        buttons.spacing = 6
        let column = NSStackView(views: [heading, message, field, buttons])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 4
        column.setCustomSpacing(8, after: field)
        for row in [message, field, buttons] { row.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
        content.addArrangedSubview(ComposerBanner.icon("exclamationmark.bubble.fill", color: Theme.ink))
        content.addArrangedSubview(column)
        setAccessibilityLabel(String(localized: "The page asks"))
    }

    func show(_ dialog: PreviewDialog) {
        message.stringValue = dialog.message
        setAccessibilityValue(dialog.message)
        field.isHidden = dialog.kind != .prompt
        if dialog.kind == .prompt, field.stringValue.isEmpty { field.stringValue = dialog.defaultText ?? "" }
        cancel.isHidden = dialog.kind == .alert
    }

    @objc private func accept() {
        onAnswer?(true, field.isHidden ? nil : field.stringValue)
        field.stringValue = ""
    }

    @objc private func dismiss() {
        onAnswer?(false, nil)
        field.stringValue = ""
    }
}
