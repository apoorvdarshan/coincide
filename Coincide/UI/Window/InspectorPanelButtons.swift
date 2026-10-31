import AppKit
import CoincideKit

/// The toolbar's buttons for the panels that open in the inspector column on the right: every schedule, the diff, the
/// pull requests, the browser preview and, when Settings › General puts the terminal on the right
/// (`TerminalPlacement.right`), the terminal. Whatever opens on the right has its button here, not in the navigation
/// rail. They sit together in one pill drawn like the project scripts control beside them, and the open panel's button
/// is lit. The panels share the column, so the buttons work like its tabs: another panel's button switches the column
/// to that panel, the open panel's button closes it.
///
/// The toolbar item comes after the inspector tracking separator (`toolbarDefaultItemIdentifiers`), so the pill stays at
/// the window's top-right corner: over the column's top edge while the column is open, right after the scripts control
/// while it is closed. The panels' own headers start below the toolbar, so nothing of theirs is under it.
final class InspectorPanelButtons: NSView {
    static let buttonWidth: CGFloat = 30

    /// The Scheduled panel (`SchedulesPanelController`), always shown. While the open thread has schedules it also
    /// reads their next run ("9:00"), and the panel opens on them.
    let scheduleButton: ComposerControlButton
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
    /// The open thread's schedules for the clock's tooltip ("2 scheduled tasks", "Next: …"), nil when it has none.
    private var scheduleDetail: String?

    override init(frame frameRect: NSRect) {
        func make(_ symbol: String, _ label: String, _ action: Selector) -> ComposerControlButton {
            let button = ComposerControlButton()
            button.configure(title: "", symbolName: symbol, chevron: false)
            button.action = action
            button.setAccessibilityLabel(label)
            return button
        }
        scheduleButton = make(
            "clock", String(localized: "Scheduled Tasks"), #selector(MainWindowController.toggleSchedulesPanel(_:)))
        // Below its minimum width (the constraint below), so the clock alone widens to a panel button's.
        scheduleButton.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        diffButton = make("plus.forwardslash.minus", String(localized: "Diff"), #selector(MainWindowController.toggleDiffPanel(_:)))
        pullRequestsButton = make(
            "arrow.triangle.pull", String(localized: "Pull Requests"), #selector(MainWindowController.togglePullRequestsPanel(_:)))
        previewButton = make("globe", String(localized: "Browser Preview"), #selector(MainWindowController.togglePreviewPanel(_:)))
        terminalButton = make("terminal", String(localized: "Terminal"), #selector(MainWindowController.toggleTerminalPanel(_:)))
        terminalButton.isHidden = true
        entries = [
            (scheduleButton, Entry(panel: .schedules, label: String(localized: "Scheduled Tasks"), command: .showSchedules)),
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
                // As wide as the others with only its clock, wider with the next run beside it.
                scheduleButton.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.buttonWidth),
            ] + entries.dropFirst().map { $0.0.widthAnchor.constraint(equalToConstant: Self.buttonWidth) })
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

    /// The clock's width: a panel button's, or more with the next run beside it.
    private var scheduleWidth: CGFloat { max(Self.buttonWidth, scheduleButton.intrinsicContentSize.width) }

    override var intrinsicContentSize: NSSize {
        let panels = entries.dropFirst().map(\.0).filter { !$0.isHidden }.count
        return NSSize(width: Self.buttonWidth * CGFloat(panels) + scheduleWidth + 2, height: 28)
    }

    /// Shows the open thread's next run beside the clock ("9:00") and its schedules in the clock's tooltip. Nil for a
    /// thread without schedules (and `nextRun` nil while all of them are paused) leaves just the clock.
    func showSchedules(nextRun: String?, detail: String?) {
        let width = scheduleWidth
        scheduleButton.configure(title: nextRun ?? "", symbolName: "clock", chevron: false)
        scheduleButton.setAccessibilityValue(detail)
        scheduleDetail = detail
        updateToolTips()
        if scheduleWidth != width { invalidateIntrinsicContentSize() }
    }

    /// The next run beside the clock, empty when it shows none.
    var nextRunTitle: String { scheduleButton.attributedTitle.string }

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

    /// The tooltips name the toggles' shortcuts, which the user can change. The clock's also sums up the open thread's
    /// schedules.
    @objc func updateToolTips() {
        for (button, entry) in entries {
            let title = entry.command.map { KeyBindingsController.shared.toolTip(entry.label, for: $0) } ?? entry.label
            button.toolTip = button === scheduleButton ? [title, scheduleDetail].compactMap(\.self).joined(separator: "\n") : title
        }
    }
}
