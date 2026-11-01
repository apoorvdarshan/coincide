import AppKit
import CoincideKit
import CoincideRemoteKit

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

/// The slim column at the window's left edge with a button for each place in the app: the thread list, a new thread,
/// search, the terminal (when it opens along the bottom), the project's editor, Help & Community's GitHub, Product Hunt,
/// Discord and Ko-fi links, usage, instructions, the agents and settings. Whatever opens on the right (every schedule,
/// the diff, the pull requests, the browser preview, and the terminal when it goes there) has its button on the right
/// too, in the toolbar (`InspectorPanelButtons`), never here.
/// Buttons send their actions up the responder chain, the way menu items do, so they run whatever the menu bar would.
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
    /// The Open In button's right-click menu of apps.
    let openInChooser: OpenTargetChooser
    private let store: AppStore
    private(set) lazy var openInButton = RailButton(
        symbol: "arrow.up.forward.app", label: String(localized: "Open In"), command: .openInEditor,
        action: #selector(MainWindowController.openInPreferred(_:)))
    private lazy var usageButton = RailButton(
        symbol: "chart.bar", label: String(localized: "Usage"), command: nil, action: #selector(showUsage(_:)), target: self)
    private lazy var instructionsButton = RailButton(
        symbol: "text.book.closed", label: String(localized: "Instructions"), command: nil,
        action: #selector(showInstructions(_:)), target: self)
    private lazy var agentsButton = RailButton(
        symbol: "cpu", label: String(localized: "Agents"), command: nil, action: #selector(showAgents(_:)), target: self)
    private lazy var settingsButton = RailButton(
        symbol: "gearshape", label: String(localized: "Settings"), command: nil,
        action: #selector(AppDelegate.showSettings(_:)))
    /// Help & Community links with a button above the bottom group, which open as their rows in Settings › About do.
    static let communityLinks: [CommunityLink] = [.starOnGitHub, .upvoteOnProductHunt, .joinDiscord, .supportOnKoFi]
    private(set) lazy var communityButtons: [RailButton] = Self.communityLinks.map { link in
        let button = RailButton(
            symbol: Self.railSymbol(link), label: link.menuTitle, command: nil, action: #selector(openCommunityLink(_:)),
            target: self)
        button.identifier = NSUserInterfaceItemIdentifier(Self.communityPrefix + link.rawValue)
        button.hint = link.detail
        return button
    }
    private static let communityPrefix = "community."

    init(store: AppStore = .shared, openInChooser: OpenTargetChooser? = nil) {
        self.store = store
        self.openInChooser = openInChooser ?? OpenTargetChooser(store: store)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let root = RailBackgroundView()
        let top = stack([threadsButton, newThreadButton, searchButton])
        let panels = stack([terminalButton, openInButton])
        let bottom = stack(communityButtons + [usageButton, instructionsButton, agentsButton, settingsButton])
        // When the window is too short for every button, the bottom group may shrink and lets the community buttons go
        // (Ko-fi, then Product Hunt, then GitHub, then Discord) rather than overlap the buttons above it.
        bottom.setClippingResistancePriority(.defaultLow, for: .vertical)
        for (button, priority) in zip(communityButtons, Self.communityVisibility) {
            bottom.setVisibilityPriority(priority, for: button)
        }
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
        openInButton.hint = String(localized: "Right-click to choose another app")
        openInButton.contextMenu = { [weak self] in self?.openInChooser.makeMenu() }
        updateOpenInTarget()
        updateShortcuts()
        NotificationCenter.default.addObserver(
            self, selector: #selector(updateShortcuts), name: KeyBindingsController.didChangeNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(updateOpenInTarget), name: OpenTargets.preferredDidChange, object: nil)
    }

    /// Names the app Open In uses in its tooltip and accessibility label, as the default changes.
    @objc func updateOpenInTarget() {
        let target = OpenTargets.preferred(in: store.settings, among: openInChooser.availableTargets)
        openInButton.label = target.map { String(localized: "Open in \($0.name)") } ?? String(localized: "Open In")
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

    /// Whether the rail has the Terminal button: it does while the terminal opens in the drawer below the chat. With the
    /// terminal on the right, its button is in the toolbar's top-right group (`InspectorPanelButtons`) instead, and
    /// Open In moves up into its place.
    var showsTerminalButton: Bool {
        get { !terminalButton.isHidden }
        set { terminalButton.isHidden = !newValue }
    }

    /// Lights the buttons of the panels that are open, and enables Open In only when there is a folder to open. Its
    /// right-click menu works either way, so the default app can be changed before a thread has a folder.
    func update(threadsOpen: Bool, terminalOpen: Bool, canOpenFolder: Bool) {
        threadsButton.isActive = threadsOpen
        terminalButton.isActive = terminalOpen
        openInButton.isEnabled = canOpenFolder
    }

    @objc private func updateShortcuts() {
        let buttons = [threadsButton, newThreadButton, searchButton, terminalButton, openInButton]
        for button in buttons {
            button.updateToolTip()
        }
    }

    @objc private func showAgents(_ sender: Any?) {
        AppEvents.showSettings(section: .providers)
    }

    @objc private func showInstructions(_ sender: Any?) {
        AppEvents.showSettings(section: .instructions)
    }

    @objc private func showUsage(_ sender: Any?) {
        UsageNavigation.show()
    }

    @objc private func openCommunityLink(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue, id.hasPrefix(Self.communityPrefix),
            let link = CommunityLink(rawValue: String(id.dropFirst(Self.communityPrefix.count)))
        else { return }
        link.open()
    }

    /// The rail's outline symbols for `communityLinks`.
    private static func railSymbol(_ link: CommunityLink) -> String {
        switch link {
        case .starOnGitHub: "star"
        case .upvoteOnProductHunt: "arrowtriangle.up.circle"
        case .joinDiscord: "bubble.left.and.bubble.right"
        case .supportOnKoFi: "heart"
        default: link.symbol
        }
    }

    /// How firmly each of `communityLinks` stays when the rail runs out of room: Discord longest, then GitHub, then
    /// Product Hunt, and Ko-fi least.
    private static let communityVisibility: [NSStackView.VisibilityPriority] = [
        NSStackView.VisibilityPriority(rawValue: 850), NSStackView.VisibilityPriority(rawValue: 825),
        NSStackView.VisibilityPriority(rawValue: 900), NSStackView.VisibilityPriority(rawValue: 800),
    ]
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

    /// What the button does, for its tooltip and accessibility label.
    var label: String {
        didSet {
            guard label != oldValue else { return }
            setAccessibilityLabel(label)
            updateToolTip()
        }
    }
    /// A second line for the tooltip, such as what a right-click does.
    var hint: String? {
        didSet {
            setAccessibilityHelp(hint)
            updateToolTip()
        }
    }
    /// The menu a right-click or Control-click shows, as a themed popup; nil for none. It opens even while the button
    /// is disabled.
    var contextMenu: (() -> NSMenu?)?
    private let command: KeyCommand?
    /// The event whose menu is up, so the window asking for the menu and the click itself don't open it twice.
    private var menuEventNumber: Int?
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
        let title = command.map { KeyBindingsController.shared.toolTip(label, for: $0) } ?? label
        toolTip = hint.map { title + "\n" + $0 } ?? title
    }

    override func rightMouseDown(with event: NSEvent) {
        if !showContextMenu(for: event) { super.rightMouseDown(with: event) }
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control), showContextMenu(for: event) { return }
        super.mouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        showContextMenu(for: event) ? nil : super.menu(for: event)
    }

    override func accessibilityPerformShowMenu() -> Bool {
        guard let menu = contextMenu?() else { return super.accessibilityPerformShowMenu() }
        ThemedPopup.show(menu: menu, from: self, preferAbove: false)
        return true
    }

    /// Opens `contextMenu` under the pointer, once per event. False when the button has none.
    private func showContextMenu(for event: NSEvent) -> Bool {
        guard contextMenu != nil else { return false }
        guard menuEventNumber != event.eventNumber else { return true }
        guard let window, let menu = contextMenu?() else { return false }
        menuEventNumber = event.eventNumber
        ThemedPopup.show(contextMenu: menu, for: event, in: window)
        return true
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
    /// The narrowest the toolbar makes the title, truncated, before it moves items into its overflow menu.
    static let minimumWidth: CGFloat = 80
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    /// The bot's avatar, in a bot's conversation.
    let avatarView = BotAvatarView(size: 24)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        for label in [titleLabel, subtitleLabel] {
            label.lineBreakMode = .byTruncatingTail
            // Below the toolbar's own sizing, so a narrow toolbar truncates the title rather than moving it, or the
            // scripts and panel buttons after it, into its overflow menu.
            label.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        }
        let labels = NSStackView(views: [titleLabel, subtitleLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 0
        avatarView.isHidden = true
        let stack = NSStackView(views: [avatarView, labels])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            // The toolbar sizes the item between these, as it does a search field.
            widthAnchor.constraint(greaterThanOrEqualToConstant: Self.minimumWidth),
            widthAnchor.constraint(lessThanOrEqualToConstant: 520),
            heightAnchor.constraint(equalToConstant: 32),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// `detail` shows only in the tooltip, such as a bot's personality.
    func set(title: String, subtitle: String, avatar: BotAvatar? = nil, detail: String? = nil) {
        avatarView.isHidden = avatar == nil
        if let avatar { avatarView.avatar = avatar }
        titleLabel.stringValue = title
        subtitleLabel.stringValue = subtitle
        subtitleLabel.isHidden = subtitle.isEmpty
        toolTip = [title, subtitle, detail ?? ""].filter { !$0.isEmpty }.joined(separator: "\n")
        setAccessibilityLabel(subtitle.isEmpty ? title : "\(title), \(subtitle)")
    }
}
