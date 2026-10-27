import AppKit
import CoincideKit

/// The slim bar above the terminal: tabs and a new-tab button on the left; the working directory,
/// split buttons and hide on the right.
final class TerminalHeaderView: NSView {
    static let height: CGFloat = 30

    struct Tab: Equatable {
        var id: UUID
        var title: String
        var symbolName: String
        var toolTip: String
        var hasExited: Bool
    }

    var onSelectTab: ((UUID) -> Void)?
    var onCloseTab: ((UUID) -> Void)?
    var onNewTab: (() -> Void)?
    var onSplit: ((TerminalTab.Layout) -> Void)?
    var onHide: (() -> Void)?

    private let tabStrip = NSStackView()
    private var tabViews: [UUID: TerminalTabItemView] = [:]
    private let directoryIcon = NSImageView()
    private let directoryLabel = NSTextField(labelWithString: "")
    private var directory: URL?
    private var hasThread = false
    private lazy var newTabButton = iconButton("plus", label: String(localized: "New Terminal"), action: #selector(newTab))
    private lazy var splitRightButton = iconButton(
        "rectangle.split.2x1", label: String(localized: "Split Right"), action: #selector(splitRight))
    private lazy var splitDownButton = iconButton(
        "rectangle.split.1x2", label: String(localized: "Split Down"), action: #selector(splitDown))
    private lazy var hideButton = iconButton("chevron.down", label: String(localized: "Hide Terminal"), action: #selector(hide))

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        tabStrip.orientation = .horizontal
        tabStrip.spacing = 2
        tabStrip.setClippingResistancePriority(.defaultLow, for: .horizontal)
        tabStrip.setAccessibilityElement(true)
        tabStrip.setAccessibilityRole(.tabGroup)
        tabStrip.setAccessibilityLabel(String(localized: "Terminal tabs"))

        newTabButton.toolTip = String(localized: "New Terminal (⌘T)")
        directoryIcon.image = Theme.symbol("folder", size: 11)
        directoryIcon.contentTintColor = .tertiaryLabelColor
        directoryIcon.setAccessibilityElement(false)
        directoryLabel.font = Theme.smallFont
        directoryLabel.textColor = .secondaryLabelColor
        directoryLabel.lineBreakMode = .byTruncatingHead
        directoryLabel.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
        directoryLabel.menu = directoryMenu()

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(.init(1), for: .horizontal)

        let row = NSStackView(views: [
            tabStrip, newTabButton, spacer, directoryIcon, directoryLabel, splitRightButton, splitDownButton, hideButton,
        ])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 4
        row.setCustomSpacing(10, after: directoryLabel)
        row.setCustomSpacing(8, after: splitDownButton)
        row.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 6)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }

    // MARK: Content

    /// Shows the tabs in order. Without a thread, only the hide button remains.
    func setTabs(_ tabs: [Tab], activeID: UUID?, canSplit: Bool, hasThread: Bool) {
        let ids = Set(tabs.map(\.id))
        for (id, view) in tabViews where !ids.contains(id) {
            view.removeFromSuperview()
            tabViews[id] = nil
        }
        let views = tabs.map { tab in
            let view = tabViews[tab.id] ?? makeTabView(id: tab.id)
            view.configure(tab, isSelected: tab.id == activeID)
            return view
        }
        if tabStrip.arrangedSubviews != views { tabStrip.setViews(views, in: .leading) }

        self.hasThread = hasThread
        newTabButton.isHidden = !hasThread
        splitRightButton.isHidden = tabs.isEmpty
        splitDownButton.isHidden = tabs.isEmpty
        splitRightButton.isEnabled = canSplit
        splitDownButton.isEnabled = canSplit
        let full = String(localized: "A tab holds at most \(ThreadTerminals.maximumSessionsPerTab) terminals")
        splitRightButton.toolTip = canSplit ? String(localized: "Split Right (⌘D)") : full
        splitDownButton.toolTip = canSplit ? String(localized: "Split Down (⇧⌘D)") : full
        updateDirectoryVisibility()
    }

    /// Refreshes one tab's title, icon and tooltip after its session changed.
    func updateTab(_ tab: Tab) {
        guard let view = tabViews[tab.id] else { return }
        view.configure(tab, isSelected: view.isSelected)
    }

    func setDirectory(_ url: URL?) {
        directory = url
        if let url {
            directoryLabel.stringValue = (url.path as NSString).abbreviatingWithTildeInPath
            directoryLabel.toolTip = url.path
            directoryLabel.setAccessibilityLabel(String(localized: "Working directory \(url.path)"))
        }
        updateDirectoryVisibility()
    }

    private func updateDirectoryVisibility() {
        let hidden = !hasThread || directory == nil
        directoryIcon.isHidden = hidden
        directoryLabel.isHidden = hidden
    }

    // MARK: Building

    private func makeTabView(id: UUID) -> TerminalTabItemView {
        let view = TerminalTabItemView()
        view.onSelect = { [weak self] in self?.onSelectTab?(id) }
        view.onClose = { [weak self] in self?.onCloseTab?(id) }
        tabViews[id] = view
        return view
    }

    private func iconButton(_ symbol: String, label: String, action: Selector) -> NSButton {
        let button = NSButton(image: Theme.symbol(symbol, size: 12) ?? NSImage(), target: self, action: action)
        button.bezelStyle = .accessoryBarAction
        button.showsBorderOnlyWhileMouseInside = true
        button.imagePosition = .imageOnly
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 24), button.heightAnchor.constraint(equalToConstant: 22),
        ])
        return button
    }

    private func directoryMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: String(localized: "Copy Path"), action: #selector(copyDirectory), keyEquivalent: "").target = self
        menu.addItem(withTitle: String(localized: "Reveal in Finder"), action: #selector(revealDirectory), keyEquivalent: "")
            .target = self
        return menu
    }

    // MARK: Actions

    @objc private func newTab() { onNewTab?() }
    @objc private func splitRight() { onSplit?(.sideBySide) }
    @objc private func splitDown() { onSplit?(.stacked) }
    @objc private func hide() { onHide?() }

    @objc private func copyDirectory() {
        guard let directory else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(directory.path, forType: .string)
    }

    @objc private func revealDirectory() {
        guard let directory else { return }
        NSWorkspace.shared.activateFileViewerSelecting([directory])
    }
}

/// One tab in the terminal header: an icon, the title and a close button that shows on hover.
final class TerminalTabItemView: NSView {
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
    private(set) var isSelected = false

    private let iconView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private var isHovered = false {
        didSet { updateAppearance() }
    }

    init() {
        super.init(frame: .zero)
        iconView.setAccessibilityElement(false)
        titleField.font = Theme.smallFont
        titleField.lineBreakMode = .byTruncatingTail
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleField.setAccessibilityElement(false)

        closeButton.image = Theme.symbol("xmark", size: 8, weight: .semibold)
        closeButton.isBordered = false
        closeButton.imagePosition = .imageOnly
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(closeTab)

        let stack = NSStackView(views: [iconView, titleField, closeButton])
        stack.orientation = .horizontal
        stack.spacing = 5
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 4)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 22),
            widthAnchor.constraint(lessThanOrEqualToConstant: 200),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 72),
            closeButton.widthAnchor.constraint(equalToConstant: 16),
            closeButton.heightAnchor.constraint(equalToConstant: 16),
        ])

        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(_ tab: TerminalHeaderView.Tab, isSelected: Bool) {
        self.isSelected = isSelected
        iconView.image = Theme.symbol(tab.symbolName, size: 11)
        iconView.contentTintColor = isSelected ? .labelColor : .secondaryLabelColor
        titleField.stringValue = tab.title
        titleField.textColor = tab.hasExited ? .tertiaryLabelColor : (isSelected ? .labelColor : .secondaryLabelColor)
        toolTip = tab.toolTip
        let closeLabel = String(localized: "Close \(tab.title)")
        closeButton.toolTip = closeLabel
        closeButton.setAccessibilityLabel(closeLabel)
        setAccessibilityLabel(tab.title)
        setAccessibilityValue(isSelected)
        updateAppearance()
    }

    private func updateAppearance() {
        closeButton.alphaValue = isSelected || isHovered ? 1 : 0
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isSelected || isHovered else { return }
        NSColor.labelColor.withAlphaComponent(isSelected ? 0.1 : 0.05).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: Theme.smallCornerRadius, yRadius: Theme.smallCornerRadius).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(
            NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func mouseDown(with event: NSEvent) {
        onSelect?()
    }

    override func otherMouseUp(with event: NSEvent) {
        // Middle-click closes, as in browsers and editors.
        if event.buttonNumber == 2 { onClose?() } else { super.otherMouseUp(with: event) }
    }

    override func accessibilityPerformPress() -> Bool {
        onSelect?()
        return true
    }

    @objc private func closeTab() {
        onClose?()
    }
}
