import AppKit
import CoincideKit

/// The toolbar's buttons for the panels that open in the inspector column on the right: the diff, the pull requests,
/// the browser preview and, when Settings › General puts the terminal on the right (`TerminalPlacement.right`), the
/// terminal. They sit together in one pill drawn like the project scripts control beside them, and the open panel's
/// button is lit. The panels share the column, so the buttons work like its tabs: another panel's button switches the
/// column to that panel, the open panel's button closes it.
///
/// The toolbar item comes after the inspector tracking separator (`toolbarDefaultItemIdentifiers`), so the pill stays at
/// the window's top-right corner: over the column's top edge while the column is open, right after the scripts control
/// while it is closed. The panels' own headers start below the toolbar, so nothing of theirs is under it.
final class InspectorPanelButtons: NSView {
    static let buttonWidth: CGFloat = 30

    let diffButton: ComposerControlButton
    let pullRequestsButton: ComposerControlButton
    let previewButton: ComposerControlButton
    /// Shown only while the terminal opens on the right; otherwise its button is in the navigation rail.
    let terminalButton: ComposerControlButton

    /// Where the buttons send their actions; nil sends them up the responder chain, as menu items do.
    weak var target: AnyObject? {
        didSet { for (button, _) in entries { button.target = target } }
    }

    /// Whether the pill has the terminal's button.
    var showsTerminal: Bool {
        get { !terminalButton.isHidden }
        set {
            guard newValue != showsTerminal else { return }
            terminalButton.isHidden = !newValue
            invalidateIntrinsicContentSize()
        }
    }

    private struct Entry {
        let panel: UIState.InspectorPanel
        let label: String
        let command: KeyCommand?
    }

    private let entries: [(ComposerControlButton, Entry)]

    override init(frame frameRect: NSRect) {
        func make(_ symbol: String, _ label: String, _ action: Selector) -> ComposerControlButton {
            let button = ComposerControlButton()
            button.configure(title: "", symbolName: symbol, chevron: false)
            button.action = action
            button.setAccessibilityLabel(label)
            return button
        }
        diffButton = make("plus.forwardslash.minus", String(localized: "Diff"), #selector(MainWindowController.toggleDiffPanel(_:)))
        pullRequestsButton = make(
            "arrow.triangle.pull", String(localized: "Pull Requests"), #selector(MainWindowController.togglePullRequestsPanel(_:)))
        previewButton = make("globe", String(localized: "Browser Preview"), #selector(MainWindowController.togglePreviewPanel(_:)))
        terminalButton = make("terminal", String(localized: "Terminal"), #selector(MainWindowController.toggleTerminalPanel(_:)))
        terminalButton.isHidden = true
        entries = [
            (diffButton, Entry(panel: .diff, label: String(localized: "Diff"), command: .toggleDiff)),
            (pullRequestsButton, Entry(panel: .pullRequests, label: String(localized: "Pull Requests"), command: nil)),
            (previewButton, Entry(panel: .preview, label: String(localized: "Browser Preview"), command: nil)),
            (terminalButton, Entry(panel: .terminal, label: String(localized: "Terminal"), command: .toggleTerminal)),
        ]
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        // The stack detaches the hidden terminal button, so the pill is only as wide as the buttons it shows.
        let stack = NSStackView(views: entries.map(\.0))
        stack.orientation = .horizontal
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 1, left: 1, bottom: 1, right: 1)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate(
            [
                stack.leadingAnchor.constraint(equalTo: leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: trailingAnchor),
                stack.topAnchor.constraint(equalTo: topAnchor),
                stack.bottomAnchor.constraint(equalTo: bottomAnchor),
                heightAnchor.constraint(equalToConstant: 28),
            ] + entries.map { $0.0.widthAnchor.constraint(equalToConstant: Self.buttonWidth) })
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(String(localized: "Right Panels"))
        updateToolTips()
        NotificationCenter.default.addObserver(
            self, selector: #selector(updateToolTips), name: KeyBindingsController.didChangeNotification, object: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// The buttons the pill shows, in order.
    var shownButtons: [ComposerControlButton] { entries.map(\.0).filter { !$0.isHidden } }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.buttonWidth * CGFloat(shownButtons.count) + 2, height: 28)
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = Theme.raisedFill.cgColor
        layer?.borderColor = Theme.surfaceBorder.cgColor
        layer?.borderWidth = 1
    }

    /// Lights the button of the panel the inspector shows, or none while it is closed.
    func update(open panel: UIState.InspectorPanel?) {
        for (button, entry) in entries {
            let active = entry.panel == panel
            guard button.isActive != active else { continue }
            button.isActive = active
            button.setAccessibilitySelected(active)
        }
    }

    /// The panel whose button is lit.
    var openPanel: UIState.InspectorPanel? {
        entries.first { $0.0.isActive }?.1.panel
    }

    /// The tooltips name the toggles' shortcuts, which the user can change.
    @objc func updateToolTips() {
        for (button, entry) in entries {
            button.toolTip = entry.command.map { KeyBindingsController.shared.toolTip(entry.label, for: $0) } ?? entry.label
        }
    }
}
