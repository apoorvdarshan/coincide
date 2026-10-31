import AppKit
import CoincideKit

/// One schedule: a clock, its name and badge on the first line, how often it runs and its next run below. On hover its
/// actions appear at the trailing edge: pause or resume, run now, edit and delete. A click on the row opens it
/// (`onOpen`), as a sidebar row does. Used by the thread's clock popup and the Scheduled panel.
final class ScheduleRowView: NSView {
    enum Action {
        case open, togglePause, runNow, edit, delete
    }

    var onAction: ((Action) -> Void)?

    static var height: CGFloat {
        ceil(Theme.lineHeight(of: titleFont) + Theme.lineHeight(of: detailFont)) + 18
    }

    private static var titleFont: NSFont { .systemFont(ofSize: Theme.fontSize - 1, weight: .medium) }
    private static var detailFont: NSFont { .systemFont(ofSize: Theme.fontSize - 2) }

    private let icon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let badge = StatusBadge()
    private let agentMark = NSImageView()
    private lazy var pauseButton = PanelIconButton(symbol: "pause", label: String(localized: "Pause"), target: self, action: #selector(pause))
    private lazy var runButton = PanelIconButton(
        symbol: "play", label: String(localized: "Run Now"), target: self, action: #selector(run))
    private lazy var editButton = PanelIconButton(symbol: "pencil", label: String(localized: "Edit…"), target: self, action: #selector(edit))
    private lazy var deleteButton = PanelIconButton(
        symbol: "trash", label: String(localized: "Delete…"), target: self, action: #selector(delete))
    private let actions = NSStackView()
    private var isHovered = false
    private var isPressed = false
    private var task: ScheduledTask?
    /// Whether the row lights up under the pointer and opens on click. The Scheduled panel's table draws its own.
    var highlightsOnHover = true

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.cornerCurve = .continuous
        icon.imageScaling = .scaleProportionallyDown
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.init(100), for: .horizontal)
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.setContentCompressionResistancePriority(.init(100), for: .horizontal)
        agentMark.image = Theme.symbol("sparkles", size: 9, weight: .semibold)
        agentMark.contentTintColor = .tertiaryLabelColor
        agentMark.toolTip = String(localized: "Created by the agent")
        agentMark.setAccessibilityLabel(String(localized: "Created by the agent"))
        for button in [pauseButton, runButton, editButton, deleteButton] { actions.addArrangedSubview(button) }
        actions.spacing = 0
        actions.isHidden = true
        let firstLine = NSStackView(views: [titleLabel, agentMark, NSView(), badge])
        firstLine.spacing = 5
        firstLine.setHuggingPriority(.init(1), for: .horizontal)
        let lines = NSStackView(views: [firstLine, detailLabel])
        lines.orientation = .vertical
        lines.alignment = .leading
        lines.spacing = 2
        for view in [icon, lines, actions] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: firstLine.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 14),
            icon.heightAnchor.constraint(equalToConstant: 14),
            lines.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            lines.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            lines.centerYAnchor.constraint(equalTo: centerYAnchor),
            firstLine.widthAnchor.constraint(equalTo: lines.widthAnchor),
            detailLabel.widthAnchor.constraint(lessThanOrEqualTo: lines.widthAnchor),
            actions.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            actions.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.cell)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ task: ScheduledTask, isRunning: Bool) {
        self.task = task
        let status = SchedulePresentation.status(task, isRunning: isRunning)
        icon.image = Theme.symbol(task.isActive ? "clock" : task.isAwaitingApproval ? "clock.badge.questionmark" : "clock.badge.xmark", size: 12, weight: .medium)
        icon.contentTintColor = task.isAwaitingApproval ? .systemOrange : task.isActive ? Theme.ink : .tertiaryLabelColor
        titleLabel.stringValue = task.name
        titleLabel.font = Self.titleFont
        titleLabel.textColor = task.isActive ? Theme.ink : .secondaryLabelColor
        detailLabel.stringValue = SchedulePresentation.detail(task)
        detailLabel.font = Self.detailFont
        agentMark.isHidden = task.createdByAgent != true
        badge.isHidden = status == nil
        if let status {
            badge.text = status.label
            badge.color = status.color
        }
        let note = SchedulePresentation.note(task)
        toolTip = [task.name, detailLabel.stringValue, note].compactMap(\.self).joined(separator: "\n")
        pauseButton.image = Theme.symbol(task.isPaused ? "play.fill" : "pause.fill", size: 11, weight: .medium)
        let pauseLabel = task.isPaused ? String(localized: "Resume") : String(localized: "Pause")
        pauseButton.toolTip = pauseLabel
        pauseButton.setAccessibilityLabel(pauseLabel)
        pauseButton.isEnabled = !task.isAwaitingApproval && task.pauseReason == nil
        runButton.image = Theme.symbol("arrow.forward.circle", size: 12, weight: .medium)
        runButton.isEnabled = !task.isAwaitingApproval && !isRunning && task.pauseReason == nil
        setAccessibilityLabel([task.name, detailLabel.stringValue, status?.label].compactMap(\.self).joined(separator: ", "))
        setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: pauseLabel) { [weak self] in self?.onAction?(.togglePause); return true },
            NSAccessibilityCustomAction(name: String(localized: "Run Now")) { [weak self] in self?.onAction?(.runNow); return true },
            NSAccessibilityCustomAction(name: String(localized: "Edit…")) { [weak self] in self?.onAction?(.edit); return true },
            NSAccessibilityCustomAction(name: String(localized: "Delete…")) { [weak self] in self?.onAction?(.delete); return true },
        ])
        updateHover()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
        if let window {
            isHovered = window.isKeyWindow && bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
            updateHover()
        }
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateHover()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        isPressed = false
        updateHover()
    }

    override func mouseDown(with event: NSEvent) {
        guard highlightsOnHover else { return super.mouseDown(with: event) }
        isPressed = true
        updateHover()
    }

    override func mouseUp(with event: NSEvent) {
        guard highlightsOnHover else { return super.mouseUp(with: event) }
        isPressed = false
        updateHover()
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onAction?(event.clickCount >= 2 ? .edit : .open)
    }

    override func accessibilityPerformPress() -> Bool {
        onAction?(.open)
        return true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateHover()
    }

    private func updateHover() {
        actions.isHidden = !isHovered
        // The actions cover the badge's place while they show.
        badge.alphaValue = isHovered ? 0 : 1
        let fill: NSColor? =
            !highlightsOnHover ? nil : isPressed ? Theme.sidebarSelection : isHovered ? Theme.sidebarHover : nil
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = fill?.cgColor
        }
    }

    @objc private func pause() { onAction?(.togglePause) }
    @objc private func run() { onAction?(.runNow) }
    @objc private func edit() { onAction?(.edit) }
    @objc private func delete() { onAction?(.delete) }
}

/// The thread's schedules, from the toolbar's clock: each with its actions, and Add Schedule… to make another.
final class ThreadSchedulesPopup: NSViewController, ThemedPopupContent {
    var close: (() -> Void)?
    var onSizeChange: (() -> Void)?

    private let threadID: UUID
    private let service: ScheduledTasks
    private let stack = NSStackView()
    private var observation: NSObjectProtocol?
    static let width: CGFloat = 340

    init(threadID: UUID, service: ScheduledTasks = .shared) {
        self.threadID = threadID
        self.service = service
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    isolated deinit { if let observation { NotificationCenter.default.removeObserver(observation) } }

    override func loadView() {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 6, bottom: 6, right: 6)
        let root = NSView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            root.widthAnchor.constraint(equalToConstant: Self.width),
        ])
        root.setAccessibilityLabel(String(localized: "Scheduled Tasks"))
        view = root
        observation = NotificationCenter.default.addObserver(forName: ScheduledTasks.didChange, object: service, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        reload()
    }

    func popupDidOpen() {}

    private func reload() {
        for view in stack.arrangedSubviews { view.removeFromSuperview() }
        let heading = NSTextField(labelWithString: String(localized: "Scheduled in This Thread"))
        heading.font = .systemFont(ofSize: 11, weight: .semibold)
        heading.textColor = .secondaryLabelColor
        let header = NSStackView(views: [heading])
        header.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 4, right: 10)
        stack.addArrangedSubview(header)
        let tasks = service.tasks(inThread: threadID)
        for task in tasks {
            let row = ScheduleRowView()
            row.show(task, isRunning: service.hasActiveWork(task) && task.activeThreadID != nil)
            row.onAction = { [weak self] action in self?.perform(action, on: task.id) }
            stack.addArrangedSubview(row)
            NSLayoutConstraint.activate([
                row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -12),
                row.heightAnchor.constraint(equalToConstant: ScheduleRowView.height),
            ])
        }
        if tasks.isEmpty {
            let empty = NSTextField(wrappingLabelWithString: String(localized: "Nothing is scheduled here yet. Add a schedule, or ask the agent to do something later or on a schedule."))
            empty.font = .systemFont(ofSize: 12)
            empty.textColor = .secondaryLabelColor
            let wrap = NSStackView(views: [empty])
            wrap.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 8, right: 10)
            stack.addArrangedSubview(wrap)
            wrap.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -12).isActive = true
        }
        stack.addArrangedSubview(ThemedDivider(frame: .zero))
        let add = SidebarActionRow(symbol: "plus", title: String(localized: "Add Schedule…")) { [weak self] in
            guard let self else { return }
            let threadID = self.threadID, window = view.window?.parent
            close?()
            ScheduleActions.newSchedule(inThread: threadID, in: window)
        }
        let all = SidebarActionRow(symbol: "list.bullet", title: String(localized: "All Scheduled Tasks")) { [weak self] in
            self?.close?()
            NSApp.sendAction(#selector(MainWindowController.toggleSchedulesPanel(_:)), to: nil, from: nil)
        }
        all.shortcut = KeyBindingsController.shared.displayString(for: .showSchedules)
        for row in [add, all] {
            stack.addArrangedSubview(row)
            NSLayoutConstraint.activate([
                row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -12),
                row.heightAnchor.constraint(equalToConstant: 28),
            ])
        }
        for view in stack.arrangedSubviews where view is ThemedDivider {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -12).isActive = true
            view.heightAnchor.constraint(equalToConstant: 1).isActive = true
        }
        view.layoutSubtreeIfNeeded()
        preferredContentSize = view.fittingSize
        onSizeChange?()
    }

    private func perform(_ action: ScheduleRowView.Action, on id: UUID) {
        let window = view.window?.parent
        switch action {
        case .open: return
        case .togglePause: ScheduleActions.togglePause(id, in: window)
        case .runNow: ScheduleActions.runNow(id, in: window)
        case .edit:
            close?()
            ScheduleActions.edit(id, in: window)
        case .delete:
            close?()
            ScheduleActions.confirmDelete(id, in: window)
        }
    }
}
