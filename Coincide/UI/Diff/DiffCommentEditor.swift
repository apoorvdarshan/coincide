import AppKit
import CoincideKit

/// The field for a comment on lines of the diff, T3 Code's review comment: a themed popup under the selected lines
/// that shows them, takes the comment, and attaches both to the composer's message. Return adds it, Shift-Return
/// starts a new line and Escape cancels.
final class DiffCommentEditor: NSViewController, ThemedPopupContent, NSTextViewDelegate {
    var close: (() -> Void)?
    var onSizeChange: (() -> Void)?
    /// Called with the comment, which may be empty, when the user adds it.
    var onAdd: ((String) -> Void)?

    private static let width: CGFloat = 420
    private static let previewLines = 6

    private let draft: MessageContext.DiffComment
    private let textView = PlaceholderTextView()

    init(draft: MessageContext.DiffComment) {
        self.draft = draft
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let context = MessageContext(.diffComment(draft))
        let icon = NSImageView(image: Theme.symbol("text.bubble", size: 12, weight: .medium) ?? NSImage())
        icon.contentTintColor = Theme.accent
        let title = NSTextField(labelWithString: String(localized: "Comment on \(context.title)"))
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.textColor = Theme.ink
        title.lineBreakMode = .byTruncatingMiddle
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [icon, title])
        header.orientation = .horizontal
        header.spacing = 6

        let preview = NSTextField(labelWithString: Self.preview(of: draft.diff))
        preview.font = Theme.smallMonoFont
        preview.textColor = .secondaryLabelColor
        preview.maximumNumberOfLines = Self.previewLines + 1
        preview.lineBreakMode = .byClipping
        preview.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let previewBox = NSView()
        previewBox.wantsLayer = true
        previewBox.layer?.cornerRadius = Theme.smallCornerRadius
        previewBox.layer?.cornerCurve = .continuous
        previewBox.layer?.backgroundColor = Theme.codeBackground.cgColor
        preview.translatesAutoresizingMaskIntoConstraints = false
        previewBox.addSubview(preview)
        NSLayoutConstraint.activate([
            preview.leadingAnchor.constraint(equalTo: previewBox.leadingAnchor, constant: 8),
            preview.trailingAnchor.constraint(lessThanOrEqualTo: previewBox.trailingAnchor, constant: -8),
            preview.topAnchor.constraint(equalTo: previewBox.topAnchor, constant: 6),
            preview.bottomAnchor.constraint(equalTo: previewBox.bottomAnchor, constant: -6),
        ])

        textView.placeholder = String(localized: "What should the agent know or do about these lines?")
        textView.font = .systemFont(ofSize: 13)
        textView.textColor = Theme.ink
        textView.insertionPointColor = Theme.accent
        textView.selectedTextAttributes = [.backgroundColor: Theme.opaqueTextSelection(over: Theme.composerFill)]
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.textContainerInset = NSSize(width: 6, height: 7)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.delegate = self
        textView.setAccessibilityLabel(String(localized: "Comment on the diff"))
        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        let field = FlatSurfaceView(style: .composer)
        field.cornerRadius = 9
        field.contentView = scroll
        field.heightAnchor.constraint(equalToConstant: 78).isActive = true

        let hint = NSTextField(labelWithString: String(localized: "Return adds it to the message, Shift-Return starts a new line"))
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor
        hint.lineBreakMode = .byTruncatingTail
        hint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let cancel = ThemedButton(title: String(localized: "Cancel"), style: .secondary, target: self, action: #selector(cancel))
        let add = ThemedButton(title: String(localized: "Add to Composer"), style: .primary, target: self, action: #selector(submit))
        for button in [cancel, add] {
            button.font = .systemFont(ofSize: 12, weight: .medium)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        let buttons = NSStackView(views: [hint, NSView(), cancel, add])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let rows: [NSView] = [header, previewBox, field, buttons]
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        for row in rows { row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true }
        stack.widthAnchor.constraint(equalToConstant: Self.width).isActive = true
        stack.setAccessibilityElement(true)
        stack.setAccessibilityRole(.group)
        stack.setAccessibilityLabel(title.stringValue)
        view = stack
        preferredContentSize = stack.fittingSize
    }

    func popupDidOpen() {
        view.window?.makeFirstResponder(textView)
    }

    /// The commented lines as the diff shows them, without hunk headers, cut after a few.
    static func preview(of diff: String) -> String {
        let lines = diff.split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.hasPrefix("@@") }
        let shown = lines.prefix(previewLines).map(String.init)
        return lines.count > previewLines ? (shown + ["…"]).joined(separator: "\n") : shown.joined(separator: "\n")
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.insertNewline(_:)), !textView.hasMarkedText() else { return false }
        let flags = NSApp.currentEvent?.modifierFlags.intersection(.deviceIndependentFlagsMask) ?? []
        guard flags.isDisjoint(with: [.shift, .option]) else {
            textView.insertNewlineIgnoringFieldEditor(nil)
            return true
        }
        submit()
        return true
    }

    @objc private func submit() {
        let comment = textView.string
        close?()
        onAdd?(comment)
    }

    @objc private func cancel() {
        close?()
    }
}
