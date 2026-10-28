import AppKit
import CoincideKit

/// What a thread row shows. Built by the sidebar from the store, the runner and `ThreadActivity`.
struct ThreadRowModel: Equatable {
    enum Status: Equatable {
        case idle
        case starting
        case running(since: Date)
        case approval(count: Int)
        case failed
        case completed

        /// T3's label for the status, used in tooltips and for accessibility.
        var label: String? {
            switch self {
            case .idle: nil
            case .starting: String(localized: "Connecting")
            case .running: String(localized: "Working")
            case .approval: String(localized: "Pending approval")
            case .failed: String(localized: "Failed")
            case .completed: String(localized: "Completed")
            }
        }

        var isRunning: Bool {
            switch self {
            case .starting, .running: true
            default: false
            }
        }

        var color: NSColor? {
            switch self {
            case .approval: .systemOrange
            case .starting, .running: Theme.ink
            case .failed: .systemRed
            case .completed: .systemGreen
            case .idle: nil
            }
        }

        /// Which status a collapsed project or a "Show more" row shows for its hidden threads.
        var priority: Int {
            switch self {
            case .approval: 5
            case .running: 4
            case .starting: 3
            case .failed: 2
            case .completed: 1
            case .idle: 0
            }
        }
    }

    var title: String
    var provider: ProviderKind
    var isPinned: Bool
    var isArchived: Bool
    var status: Status
    var updatedAt: Date
    var canArchive: Bool
    /// Whether the thread has a settled turn to fork from.
    var canFork = false
    /// An agent of the thread still runs work of its own after its reply, such as a subagent: the row keeps its
    /// spinner.
    var hasBackgroundWork = false
    var toolTip: String
    var accessibilityLabel: String
    /// The thread's Go to Thread shortcut ("⌘1"…) while the user holds its modifier keys, as in T3. Nil when the
    /// thread's command has no shortcut.
    var jumpHint: String?
}

/// A table cell that knows when the pointer is over it.
class HoverCellView: NSTableCellView {
    private(set) var isHovered = false {
        didSet { if isHovered != oldValue { hoverChanged() } }
    }
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
        // Rows scroll under a still pointer without sending enter or exit events.
        if let window {
            let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            isHovered = window.isKeyWindow && bounds.contains(point)
        }
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func prepareForReuse() {
        super.prepareForReuse()
        isHovered = false
    }

    func hoverChanged() {}
}

/// A borderless symbol button for row accessories.
func sidebarAccessoryButton(symbol: String, label: String, target: AnyObject?, action: Selector?) -> NSButton {
    let button = NSButton(image: Theme.symbol(symbol, size: 12, weight: .medium) ?? NSImage(), target: target, action: action)
    button.isBordered = false
    button.imagePosition = .imageOnly
    button.contentTintColor = .secondaryLabelColor
    button.toolTip = label
    button.setAccessibilityLabel(label)
    button.translatesAutoresizingMaskIntoConstraints = false
    button.setContentHuggingPriority(.required, for: .horizontal)
    button.setContentCompressionResistancePriority(.required, for: .horizontal)
    return button
}

/// A small capsule such as "Approval" or "Failed".
final class StatusBadge: NSView {
    private let label = NSTextField(labelWithString: "")
    var color: NSColor = .systemOrange {
        didSet { needsDisplay = true }
    }
    var isEmphasized = false {
        didSet { if isEmphasized != oldValue { needsDisplay = true } }
    }

    init() {
        super.init(frame: .zero)
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 16),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var text: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }

    override func draw(_ dirtyRect: NSRect) {
        let fill = isEmphasized ? NSColor.white.withAlphaComponent(0.25) : color.withAlphaComponent(0.16)
        fill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        label.textColor = isEmphasized ? .white : color
    }
}

/// A filled circle for collapsed-project status and unseen results.
final class StatusDot: NSView {
    var color: NSColor = .systemGreen {
        didSet { needsDisplay = true }
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 7, height: 7) }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }
}

// MARK: - Header

/// A section heading with an add button and optional sidebar options.
final class SidebarHeaderCell: NSTableCellView {
    init(title: String, target: AnyObject, addAction: Selector, addSymbol: String, addLabel: String, optionsAction: Selector? = nil) {
        super.init(frame: .zero)
        let title = NSTextField(labelWithString: title)
        title.font = .systemFont(ofSize: 11, weight: .semibold)
        title.textColor = .secondaryLabelColor
        var views: [NSView] = [title, NSView()]
        if let optionsAction {
            views.append(sidebarAccessoryButton(
                symbol: "ellipsis.circle", label: String(localized: "Sidebar Options"), target: target, action: optionsAction))
        }
        let add = sidebarAccessoryButton(
            symbol: addSymbol, label: addLabel, target: target, action: addAction)
        views.append(add)
        let stack = NSStackView(views: views)
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        textField = title
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - Project

final class ProjectCell: HoverCellView {
    private let icon = NSImageView()
    private let nameField = NSTextField(labelWithString: "")
    private let statusDot = StatusDot()
    private let newThreadButton: NSButton
    var onNewThread: (() -> Void)?

    override init(frame frameRect: NSRect) {
        newThreadButton = sidebarAccessoryButton(
            symbol: "square.and.pencil", label: String(localized: "New Thread"), target: nil, action: nil)
        super.init(frame: frameRect)
        newThreadButton.target = self
        newThreadButton.action = #selector(newThreadClicked)
        newThreadButton.isHidden = true
        icon.imageScaling = .scaleProportionallyDown
        nameField.font = .systemFont(ofSize: 13, weight: .medium)
        nameField.lineBreakMode = .byTruncatingTail
        nameField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusDot.isHidden = true
        imageView = icon
        textField = nameField

        let accessories = NSStackView(views: [statusDot, newThreadButton])
        accessories.spacing = 6
        for view: NSView in [icon, nameField, accessories] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 16),
            nameField.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5),
            nameField.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameField.trailingAnchor.constraint(lessThanOrEqualTo: accessories.leadingAnchor, constant: -6),
            accessories.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            accessories.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusDot.widthAnchor.constraint(equalToConstant: 7),
            statusDot.heightAnchor.constraint(equalToConstant: 7),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// `hiddenStatus` is the most urgent status among threads the row hides while collapsed.
    func configure(project: Project, hiddenStatus: ThreadRowModel.Status?) {
        // During an inline rename this would replace what the user typed; ending the rename sets the name.
        if nameField.currentEditor() == nil { nameField.stringValue = project.name }
        newThreadButton.toolTip = String(localized: "New Thread")
        newThreadButton.setAccessibilityLabel(String(localized: "New Thread"))
        let exists = FileManager.default.fileExists(atPath: project.path)
        icon.image = Theme.symbol(exists ? "folder" : "questionmark.folder", size: 14)
        icon.contentTintColor = .secondaryLabelColor
        icon.setAccessibilityLabel(exists ? String(localized: "Folder") : String(localized: "Folder not found"))
        let path = Formatting.abbreviatedPath(project.path)
        toolTip = exists ? path : String(localized: "Folder not found: \(path)")
        if let hiddenStatus, let color = hiddenStatus.color {
            statusDot.color = color
            statusDot.toolTip = hiddenStatus.label
            statusDot.isHidden = false
        } else {
            statusDot.isHidden = true
        }
        let newThread = String(localized: "New Thread in \(project.name)")
        newThreadButton.toolTip = newThread
        newThreadButton.setAccessibilityLabel(newThread)
        var label = project.name
        if let status = hiddenStatus?.label { label += ", " + status }
        setAccessibilityLabel(label)
        // The button only appears on hover, so VoiceOver gets the same command as an action.
        setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: String(localized: "New Thread")) { [weak self] in
                self?.onNewThread?()
                return true
            }
        ])
    }

    override func hoverChanged() {
        newThreadButton.isHidden = !isHovered
    }

    @objc private func newThreadClicked() {
        onNewThread?()
    }
}

// MARK: - Thread

final class ThreadCell: HoverCellView {
    /// What the row's archive button and its VoiceOver actions ask for.
    enum Command {
        case togglePin
        case rename
        case fork
        case toggleArchived
        case delete
    }

    private let icon = NSImageView()
    private let spinner = NSProgressIndicator()
    private let titleField = NSTextField(labelWithString: "")
    private let pin = NSImageView()
    private let badge = StatusBadge()
    private let unseenDot = StatusDot()
    private let timeField = NSTextField(labelWithString: "")
    private let archiveButton: NSButton
    private var model: ThreadRowModel?
    var onCommand: ((Command) -> Void)?

    override init(frame frameRect: NSRect) {
        archiveButton = sidebarAccessoryButton(
            symbol: "archivebox", label: String(localized: "Archive"), target: nil, action: nil)
        super.init(frame: frameRect)
        archiveButton.target = self
        archiveButton.action = #selector(archiveClicked)
        archiveButton.isHidden = true
        icon.imageScaling = .scaleProportionallyDown
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        titleField.font = .systemFont(ofSize: 13)
        titleField.lineBreakMode = .byTruncatingTail
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        pin.image = Theme.symbol("pin.fill", size: 9)
        pin.contentTintColor = .tertiaryLabelColor
        pin.setAccessibilityLabel(String(localized: "Pinned"))
        unseenDot.isHidden = true
        timeField.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        timeField.alignment = .right
        imageView = icon
        textField = titleField

        let accessories = NSStackView(views: [pin, badge, unseenDot, timeField, archiveButton])
        accessories.spacing = 4
        for view: NSView in [pin, badge, unseenDot, timeField] {
            view.setContentHuggingPriority(.required, for: .horizontal)
            view.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        for view: NSView in [icon, spinner, titleField, accessories] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            spinner.centerXAnchor.constraint(equalTo: icon.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 14),
            spinner.heightAnchor.constraint(equalToConstant: 14),
            titleField.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleField.trailingAnchor.constraint(lessThanOrEqualTo: accessories.leadingAnchor, constant: -4),
            accessories.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            accessories.centerYAnchor.constraint(equalTo: centerYAnchor),
            unseenDot.widthAnchor.constraint(equalToConstant: 7),
            unseenDot.heightAnchor.constraint(equalToConstant: 7),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ model: ThreadRowModel) {
        guard model != self.model else { return }
        self.model = model
        // During an inline rename this would replace what the user typed; ending the rename sets the title.
        if titleField.currentEditor() == nil { titleField.stringValue = model.title }
        let unseen = model.status == .completed || model.status == .failed
        titleField.font = .systemFont(ofSize: 13, weight: unseen ? .semibold : .regular)
        pin.isHidden = !model.isPinned
        toolTip = model.toolTip
        setAccessibilityLabel(model.accessibilityLabel)
        var actions = [
            accessibilityAction(model.isPinned ? String(localized: "Unpin") : String(localized: "Pin"), .togglePin),
            accessibilityAction(String(localized: "Rename"), .rename),
        ]
        if model.canFork { actions.append(accessibilityAction(String(localized: "Fork Thread"), .fork)) }
        if model.canArchive {
            let title = model.isArchived ? String(localized: "Unarchive") : String(localized: "Archive")
            actions.append(accessibilityAction(title, .toggleArchived))
        }
        actions.append(accessibilityAction(String(localized: "Delete"), .delete))
        setAccessibilityCustomActions(actions)
        updateStatus()
        refreshTime()
    }

    /// The hover-only archive button and the context menu, offered to VoiceOver as actions.
    private func accessibilityAction(_ name: String, _ command: Command) -> NSAccessibilityCustomAction {
        NSAccessibilityCustomAction(name: name) { [weak self] in
            guard let self else { return false }
            // Some commands reload this row or open a sheet; finish the accessibility request first.
            DispatchQueue.main.async { self.onCommand?(command) }
            return true
        }
    }

    /// Updates the age or elapsed time without reconfiguring the row.
    func refreshTime() {
        guard let model else { return }
        if let hint = model.jumpHint {
            timeField.stringValue = hint
        } else if case .running(let since) = model.status {
            timeField.stringValue = Formatting.elapsed(since: since)
        } else {
            timeField.stringValue = Formatting.compactAge(of: model.updatedAt)
        }
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { updateStatus() }
    }

    override func hoverChanged() {
        updateAccessories()
    }

    private func updateStatus() {
        guard let model else { return }
        let emphasized = backgroundStyle == .emphasized
        let selectedText = NSColor.alternateSelectedControlTextColor
        // The agent's logo, unless the thread is archived or waits for an approval.
        var symbol: String? = model.isArchived ? "archivebox" : nil
        var tint = model.isArchived ? NSColor.tertiaryLabelColor : NSColor.labelColor
        badge.isHidden = true
        switch model.status {
        case .approval(let count):
            symbol = "exclamationmark.shield.fill"
            tint = .systemOrange
            badge.text = count > 1 ? String(localized: "Approval \(count)") : String(localized: "Approval")
            badge.color = .systemOrange
            badge.isHidden = false
        case .failed:
            badge.text = String(localized: "Failed")
            badge.color = .systemRed
            badge.isHidden = false
        case .idle, .completed, .starting, .running:
            break
        }
        badge.isEmphasized = emphasized
        icon.image = symbol.flatMap { Theme.symbol($0, size: 12, weight: .medium) } ?? Theme.logo(for: model.provider, size: 14)
        icon.setAccessibilityLabel(model.provider.displayName)
        icon.contentTintColor = emphasized ? selectedText : tint
        let spins = model.status.isRunning || model.hasBackgroundWork
        icon.isHidden = spins
        if spins { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        titleField.textColor = model.isArchived ? .secondaryLabelColor : .labelColor
        unseenDot.color = emphasized ? selectedText : .systemGreen
        let timeColor: NSColor =
            model.jumpHint != nil ? .labelColor : model.status.isRunning ? Theme.color(for: model.provider) : .secondaryLabelColor
        timeField.textColor = emphasized ? selectedText : timeColor
        updateAccessories()
    }

    private func updateAccessories() {
        guard let model else { return }
        let showsArchive =
            isHovered && model.canArchive && !model.isArchived && model.jumpHint == nil && !model.status.isRunning
        archiveButton.isHidden = !showsArchive
        let hasBadge = !badge.isHidden
        timeField.isHidden = showsArchive || (hasBadge && model.jumpHint == nil)
        unseenDot.isHidden = showsArchive || hasBadge || model.status != .completed
    }

    @objc private func archiveClicked() {
        onCommand?(.toggleArchived)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        spinner.stopAnimation(nil)
        model = nil
    }
}

// MARK: - Notes

/// "Show N more", "Show less" and "No threads yet".
final class SidebarNoteCell: NSTableCellView {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let dot = StatusDot()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        icon.contentTintColor = .tertiaryLabelColor
        dot.isHidden = true
        textField = label
        for view: NSView in [icon, label, dot] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 6),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 7),
            dot.heightAnchor.constraint(equalToConstant: 7),
            dot.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Set for "Show more" and "Show less", which act on click.
    var onPress: (() -> Void)?

    func configure(text: String, symbol: String?, hiddenStatus: ThreadRowModel.Status? = nil, onPress: (() -> Void)? = nil) {
        label.stringValue = text
        icon.image = symbol.flatMap { Theme.symbol($0, size: 10, weight: .semibold) }
        if let color = hiddenStatus?.color {
            dot.color = color
            dot.toolTip = hiddenStatus?.label
            dot.isHidden = false
        } else {
            dot.isHidden = true
        }
        self.onPress = onPress
        var label = text
        if let status = hiddenStatus?.label { label += ", " + status }
        setAccessibilityLabel(label)
    }

    // The rows are not selectable, so assistive apps press them instead.
    override func accessibilityPerformPress() -> Bool {
        guard let onPress else { return false }
        // Pressing reloads this row; finish the accessibility request first.
        DispatchQueue.main.async { onPress() }
        return true
    }
}
