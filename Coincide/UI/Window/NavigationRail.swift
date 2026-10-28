import AppKit
import CoincideKit

/// The window's content: the navigation rail, then the split view of the thread list, chat and diff. The rail stays
/// when the thread list closes.
final class MainRootViewController: NSViewController {
    let rail = NavigationRailViewController()
    let split: MainSplitViewController

    init(split: MainSplitViewController) {
        self.split = split
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = NSView()
        addChild(rail)
        addChild(split)
        for view in [rail.view, split.view] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            rail.view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            rail.view.topAnchor.constraint(equalTo: root.topAnchor),
            rail.view.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            rail.view.widthAnchor.constraint(equalToConstant: NavigationRailViewController.width),
            split.view.leadingAnchor.constraint(equalTo: rail.view.trailingAnchor),
            split.view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            split.view.topAnchor.constraint(equalTo: root.topAnchor),
            split.view.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
    }
}

/// The slim column at the window's left edge with a button for each place and panel in the app: the thread list, a
/// new thread, search, the terminal, the diff, the pull requests, the project's editor, the agents and settings.
/// The diff and the pull requests share the inspector column, so at most one of the two is lit. Buttons send their
/// actions up the responder chain, the way menu items do, so they run whatever the menu bar would.
final class NavigationRailViewController: NSViewController {
    static let width: CGFloat = 60

    private lazy var threadsButton = RailButton(
        symbol: "sidebar.left", label: String(localized: "Threads"), command: .toggleSidebar,
        action: #selector(MainWindowController.toggleSidebarPanel(_:)))
    private lazy var newThreadButton = RailButton(
        symbol: "square.and.pencil", label: String(localized: "New Thread"), command: .newThread,
        action: #selector(MainWindowController.newThread(_:)))
    private lazy var searchButton = RailButton(
        symbol: "magnifyingglass", label: String(localized: "Search"), command: .commandPalette,
        action: #selector(MainWindowController.showCommandPalette(_:)))
    private lazy var terminalButton = RailButton(
        symbol: "terminal", label: String(localized: "Terminal"), command: .toggleTerminal,
        action: #selector(MainWindowController.toggleTerminalPanel(_:)))
    private lazy var diffButton = RailButton(
        symbol: "plus.forwardslash.minus", label: String(localized: "Diff"), command: .toggleDiff,
        action: #selector(MainWindowController.toggleDiffPanel(_:)))
    private lazy var pullRequestsButton = RailButton(
        symbol: "arrow.triangle.pull", label: String(localized: "Pull Requests"), command: nil,
        action: #selector(MainWindowController.togglePullRequestsPanel(_:)))
    private lazy var previewButton = RailButton(
        symbol: "globe", label: String(localized: "Browser Preview"), command: nil,
        action: #selector(MainWindowController.togglePreviewPanel(_:)))
    private lazy var openInButton = RailButton(
        symbol: "arrow.up.forward.app", label: String(localized: "Open In"), command: .openInEditor,
        action: #selector(MainWindowController.openInPreferred(_:)))
    private lazy var agentsButton = RailButton(
        symbol: "cpu", label: String(localized: "Agents"), command: nil, action: #selector(showAgents(_:)), target: self)
    private lazy var settingsButton = RailButton(
        symbol: "gearshape", label: String(localized: "Settings"), command: nil,
        action: #selector(AppDelegate.showSettings(_:)))

    override func loadView() {
        let root = RailBackgroundView()
        let top = stack([threadsButton, newThreadButton, searchButton])
        let panels = stack([terminalButton, diffButton, pullRequestsButton, previewButton, openInButton])
        let bottom = stack([agentsButton, settingsButton])
        let divider = RailDivider()
        for view in [top, divider, panels, bottom] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 6),
            top.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            divider.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 10),
            divider.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            divider.widthAnchor.constraint(equalToConstant: 24),
            divider.heightAnchor.constraint(equalToConstant: 1),
            panels.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 10),
            panels.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            bottom.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            bottom.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            bottom.topAnchor.constraint(greaterThanOrEqualTo: panels.bottomAnchor, constant: 12),
        ])
        root.setAccessibilityElement(true)
        root.setAccessibilityRole(.toolbar)
        root.setAccessibilityLabel(String(localized: "Navigation"))
        view = root
        updateShortcuts()
        NotificationCenter.default.addObserver(
            self, selector: #selector(updateShortcuts), name: KeyBindingsController.didChangeNotification, object: nil)
    }

    private func stack(_ buttons: [RailButton]) -> NSStackView {
        let stack = NSStackView(views: buttons)
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.distribution = .gravityAreas
        stack.spacing = 6
        // Fixed squares, so the stack never stretches a button and its highlight into the next one.
        for button in buttons {
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: RailButton.side),
                button.heightAnchor.constraint(equalToConstant: RailButton.side),
            ])
        }
        return stack
    }

    /// Lights the buttons of the panels that are open, and enables Open In only when there is a folder to open.
    func update(threadsOpen: Bool, terminalOpen: Bool, diffOpen: Bool, pullRequestsOpen: Bool, previewOpen: Bool = false, canOpenFolder: Bool) {
        threadsButton.isActive = threadsOpen
        terminalButton.isActive = terminalOpen
        diffButton.isActive = diffOpen
        pullRequestsButton.isActive = pullRequestsOpen
        previewButton.isActive = previewOpen
        openInButton.isEnabled = canOpenFolder
    }

    @objc private func updateShortcuts() {
        let buttons = [
            threadsButton, newThreadButton, searchButton, terminalButton, diffButton, pullRequestsButton, previewButton, openInButton,
        ]
        for button in buttons {
            button.updateToolTip()
        }
    }

    @objc private func showAgents(_ sender: Any?) {
        AppEvents.showSettings(section: .providers)
    }
}

/// A square button in the rail: a symbol that brightens on hover and sits on a soft fill while its panel is open.
final class RailButton: NSButton {
    static let side: CGFloat = 38

    var isActive = false {
        didSet {
            guard isActive != oldValue else { return }
            setAccessibilitySelected(isActive)
            updateTint()
        }
    }

    private let label: String
    private let command: KeyCommand?
    private var isHovered = false

    init(symbol: String, label: String, command: KeyCommand?, action: Selector, target: AnyObject? = nil) {
        self.label = label
        self.command = command
        super.init(frame: .zero)
        isBordered = false
        title = ""
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 16, weight: .regular))
        imagePosition = .imageOnly
        imageScaling = .scaleNone
        self.action = action
        self.target = target
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        setAccessibilityLabel(label)
        updateToolTip()
        updateTint()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize { NSSize(width: Self.side, height: Self.side) }

    /// The button paints its own fill across its bounds, so its frame must be exactly the size it is laid out at: the
    /// default push style's alignment insets would make the frame, and the fill, larger than the layout allows for.
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }

    override var isEnabled: Bool {
        didSet { updateTint() }
    }

    override var isHighlighted: Bool {
        didSet { updateTint() }
    }

    func updateToolTip() {
        toolTip = command.map { KeyBindingsController.shared.toolTip(label, for: $0) } ?? label
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateTint()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateTint()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateTint()
    }

    /// The symbol's color and the fill behind it. The button still draws its own image, so the fill is set on the
    /// layer here rather than in `updateLayer`.
    private func updateTint() {
        contentTintColor =
            !isEnabled ? .quaternaryLabelColor : isActive || isHovered ? .labelColor : .secondaryLabelColor
        let fill: NSColor? =
            isHighlighted || isActive ? Theme.sidebarSelection : isHovered && isEnabled ? Theme.sidebarHover : nil
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = fill?.cgColor
        }
    }
}

/// The rail's color, the sidebar's, with a hairline on its right edge.
private final class RailBackgroundView: NSView {
    override var wantsUpdateLayer: Bool { true }
    private let edge = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(edge)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        edge.frame = CGRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height)
    }

    override func updateLayer() {
        layer?.backgroundColor = Theme.sidebarBackground.cgColor
        edge.backgroundColor = Theme.surfaceBorder.cgColor
    }
}

/// A short line between the rail's groups.
private final class RailDivider: NSView {
    override var wantsUpdateLayer: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateLayer() {
        layer?.backgroundColor = Theme.surfaceBorder.cgColor
    }
}

/// The thread's title over its project and branch, shown in the toolbar right after the thread list. The window's
/// own title is hidden, since the toolbar would put it over the thread list, beside the traffic lights.
final class ThreadTitleView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        for label in [titleLabel, subtitleLabel] {
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        let stack = NSStackView(views: [titleLabel, subtitleLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            widthAnchor.constraint(lessThanOrEqualToConstant: 520),
            heightAnchor.constraint(equalToConstant: 32),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func set(title: String, subtitle: String) {
        titleLabel.stringValue = title
        subtitleLabel.stringValue = subtitle
        subtitleLabel.isHidden = subtitle.isEmpty
        toolTip = subtitle.isEmpty ? title : "\(title)\n\(subtitle)"
        setAccessibilityLabel(subtitle.isEmpty ? title : "\(title), \(subtitle)")
    }
}
