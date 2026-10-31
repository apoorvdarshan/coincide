import AppKit
import CoincideKit

/// One schedule: a clock, its name and badge on the first line, how often it runs and its next run below. On hover its
/// actions appear at the trailing edge: pause or resume, run now, edit and delete. A click on the row opens it
/// (`onOpen`), as a sidebar row does. The Scheduled panel's rows.
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
