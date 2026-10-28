import AppKit

/// T3 Code's thread find bar: a floating field over the top of the conversation with the match count
/// and previous, next and close buttons. Return and Shift-Return step through the matches and Escape
/// closes it; ⌘G and ⇧⌘G work anywhere in the chat.
final class TranscriptFindBar: NSView {
    var onQueryChange: ((String) -> Void)?
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onClose: (() -> Void)?

    static let width: CGFloat = 340

    let field = TranscriptFindSearchField()
    private let glass = FlatSurfaceView()
    private let countLabel = NSTextField(labelWithString: "")
    private lazy var previousButton = Self.button(
        "chevron.up", label: String(localized: "Previous Match"), toolTip: String(localized: "Previous Match (⇧⌘G)"),
        target: self, action: #selector(previous))
    private lazy var nextButton = Self.button(
        "chevron.down", label: String(localized: "Next Match"), toolTip: String(localized: "Next Match (⌘G)"),
        target: self, action: #selector(next))
    private lazy var closeButton = Self.button(
        "xmark", label: String(localized: "Close Find Bar"), toolTip: String(localized: "Close (⎋)"), target: self,
        action: #selector(close))

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        glass.cornerRadius = 17
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)

        field.placeholderString = String(localized: "Find in Thread")
        field.setAccessibilityLabel(String(localized: "Find in Thread"))
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        field.maximumRecents = 0
        field.recentsAutosaveName = nil
        field.target = self
        field.action = #selector(queryChanged)
        field.delegate = self
        field.setContentHuggingPriority(.init(1), for: .horizontal)
        field.setContentCompressionResistancePriority(.init(200), for: .horizontal)

        countLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        countLabel.textColor = .secondaryLabelColor
        countLabel.alignment = .center
        countLabel.lineBreakMode = .byClipping
        countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        countLabel.setContentHuggingPriority(.required, for: .horizontal)

        let row = NSStackView(views: [field, countLabel, previousButton, nextButton, closeButton])
        row.spacing = 2
        row.setCustomSpacing(6, after: countLabel)
        row.setCustomSpacing(4, after: nextButton)
        row.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 6)
        row.alignment = .centerY
        glass.contentView = row

        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 34),
            countLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(String(localized: "Find in Thread"))
        showCount(current: nil, total: 0, isTruncated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private static func button(_ symbol: String, label: String, toolTip: String, target: AnyObject, action: Selector) -> NSButton {
        let button = NSButton(image: Theme.symbol(symbol, size: 11, weight: .semibold) ?? NSImage(), target: target, action: action)
        button.bezelStyle = .accessoryBarAction
        button.showsBorderOnlyWhileMouseInside = true
        button.imagePosition = .imageOnly
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = toolTip
        button.setAccessibilityLabel(label)
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 24), button.heightAnchor.constraint(equalToConstant: 22),
        ])
        return button
    }

    // MARK: State

    var query: String { field.stringValue }

    /// Replaces the query without reporting it as typed, selected so typing replaces it.
    func setQuery(_ query: String) {
        guard field.stringValue != query else { return }
        if let editor = field.currentEditor() as? NSTextView {
            editor.string = query
            editor.selectAll(nil)
        } else {
            field.stringValue = query
        }
    }

    /// Focuses the field with its text selected, so typing replaces the last search.
    func focus() {
        guard let window else { return }
        window.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    var hasFocus: Bool {
        guard let editor = window?.firstResponder as? NSText else { return false }
        return editor.delegate as? NSSearchField === field
    }

    /// "3 of 12", or "No matches" in red once there is a query without results.
    func showCount(current: Int?, total: Int, isTruncated: Bool) {
        let hasQuery = !field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let text: String
        if !hasQuery {
            text = ""
        } else if total == 0 {
            text = String(localized: "No matches")
        } else {
            let position = (current ?? 0) + 1
            text =
                isTruncated
                ? String(localized: "\(position) of \(total)+") : String(localized: "\(position) of \(total)")
        }
        countLabel.stringValue = text
        countLabel.textColor = hasQuery && total == 0 ? .systemRed : .secondaryLabelColor
        countLabel.isHidden = text.isEmpty
        previousButton.isEnabled = total > 0
        nextButton.isEnabled = total > 0
        countLabel.setAccessibilityLabel(text)
    }

    var countDescription: String { countLabel.stringValue }

    // MARK: Actions

    @objc private func queryChanged() {
        onQueryChange?(field.stringValue)
    }

    @objc private func previous() {
        onPrevious?()
    }

    @objc private func next() {
        onNext?()
    }

    @objc private func close() {
        onClose?()
    }
}

extension TranscriptFindBar: NSSearchFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { onPrevious?() } else { onNext?() }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?()
            return true
        default:
            return false
        }
    }
}

// MARK: - Field

/// The find bar's search field. Its field editor passes ⌘G, ⇧⌘G and ⌘E on to the chat while you type,
/// where an ordinary field editor would take them for itself and turn them off.
final class TranscriptFindSearchField: NSSearchField {
    override class var cellClass: AnyClass? {
        get { TranscriptFindSearchFieldCell.self }
        set {}
    }
}

private final class TranscriptFindSearchFieldCell: NSSearchFieldCell {
    // Cells are copied by value, so the editor is shared rather than stored here.
    override func fieldEditor(for controlView: NSView) -> NSTextView? {
        TranscriptFindSearchFieldEditor.shared
    }
}

private final class TranscriptFindSearchFieldEditor: NSTextView {
    static let shared: TranscriptFindSearchFieldEditor = {
        let editor = TranscriptFindSearchFieldEditor()
        editor.isFieldEditor = true
        return editor
    }()

    override func performTextFinderAction(_ sender: Any?) {
        passTextFinderActionOn(sender)
    }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(performTextFinderAction(_:)) { return validatePassedOnTextFinderAction(menuItem) }
        return super.validateMenuItem(menuItem)
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(performTextFinderAction(_:)) { return validatePassedOnTextFinderAction(item) }
        return super.validateUserInterfaceItem(item)
    }
}
