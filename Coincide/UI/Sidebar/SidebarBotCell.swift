import AppKit
import CoincideKit

/// What a bot's row shows: the bot, its latest message and the status of its conversations.
struct BotRowModel: Equatable {
    var name: String
    var avatar: BotAvatar
    /// The latest message of its latest conversation, or what the bot is for before it has one.
    var preview: String
    var updatedAt: Date?
    /// The most pressing status among its conversations.
    var status: ThreadRowModel.Status
    var toolTip: String
    var accessibilityLabel: String
    /// Its conversations' active schedules, for the clock's tooltip; nil hides the clock.
    var schedule: String? = nil
}

/// A bot in the sidebar: its avatar, name and time on the first line, its latest message below, like a conversation
/// in a messaging app. The avatar blinks while the bot works; an approval or a failure shows as a badge.
final class BotCell: HoverCellView {
    private let avatarView = BotAvatarView(size: 26)
    private let nameField = NSTextField(labelWithString: "")
    private let previewField = NSTextField(labelWithString: "")
    private let timeField = NSTextField(labelWithString: "")
    private let badge = StatusBadge()
    private let unseenDot = StatusDot()
    private let spinner = NSProgressIndicator()
    private let clock = NSImageView()
    private var model: BotRowModel?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        nameField.font = .systemFont(ofSize: 13, weight: .medium)
        nameField.lineBreakMode = .byTruncatingTail
        nameField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        previewField.font = .systemFont(ofSize: 11)
        previewField.textColor = .secondaryLabelColor
        previewField.lineBreakMode = .byTruncatingTail
        previewField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        timeField.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        timeField.alignment = .right
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        unseenDot.isHidden = true
        clock.image = Theme.symbol("clock", size: 9, weight: .semibold)
        clock.contentTintColor = .tertiaryLabelColor
        clock.isHidden = true
        textField = nameField
        let accessories = NSStackView(views: [clock, badge, unseenDot, spinner, timeField])
        accessories.spacing = 4
        for view: NSView in [clock, badge, unseenDot, spinner, timeField] {
            view.setContentHuggingPriority(.required, for: .horizontal)
            view.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        for view: NSView in [avatarView, nameField, previewField, accessories] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            avatarView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 0),
            avatarView.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameField.leadingAnchor.constraint(equalTo: avatarView.trailingAnchor, constant: 8),
            nameField.bottomAnchor.constraint(equalTo: centerYAnchor, constant: 1),
            nameField.trailingAnchor.constraint(lessThanOrEqualTo: accessories.leadingAnchor, constant: -4),
            previewField.leadingAnchor.constraint(equalTo: nameField.leadingAnchor),
            previewField.topAnchor.constraint(equalTo: centerYAnchor, constant: 1),
            previewField.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            accessories.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            accessories.centerYAnchor.constraint(equalTo: nameField.centerYAnchor),
            unseenDot.widthAnchor.constraint(equalToConstant: 7),
            unseenDot.heightAnchor.constraint(equalToConstant: 7),
            spinner.widthAnchor.constraint(equalToConstant: 12),
            spinner.heightAnchor.constraint(equalToConstant: 12),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.cell)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ model: BotRowModel) {
        guard model != self.model else { return }
        self.model = model
        avatarView.avatar = model.avatar
        nameField.stringValue = model.name
        previewField.stringValue = model.preview
        let unseen = model.status == .completed || model.status == .failed
        nameField.font = .systemFont(ofSize: 13, weight: unseen ? .semibold : .medium)
        clock.isHidden = model.schedule == nil
        clock.toolTip = model.schedule
        clock.setAccessibilityLabel(model.schedule)
        toolTip = [model.toolTip, model.schedule].compactMap(\.self).joined(separator: "\n")
        setAccessibilityLabel(model.accessibilityLabel)
        updateStatus()
        refreshTime()
    }

    /// Updates the age or elapsed time without reconfiguring the row.
    func refreshTime() {
        guard let model else { return }
        if case .running(let since) = model.status {
            timeField.stringValue = Formatting.elapsed(since: since)
        } else {
            timeField.stringValue = model.updatedAt.map { Formatting.compactAge(of: $0) } ?? ""
        }
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { updateStatus() }
    }

    private func updateStatus() {
        guard let model else { return }
        let emphasized = backgroundStyle == .emphasized
        let selectedText = NSColor.alternateSelectedControlTextColor
        badge.isHidden = true
        switch model.status {
        case .approval(let count):
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
        avatarView.isAnimating = model.status.isRunning
        if model.status == .starting { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        nameField.textColor = emphasized ? selectedText : .labelColor
        previewField.textColor = emphasized ? selectedText.withAlphaComponent(0.8) : .secondaryLabelColor
        unseenDot.color = emphasized ? selectedText : .systemGreen
        clock.contentTintColor = emphasized ? selectedText : .tertiaryLabelColor
        unseenDot.isHidden = !badge.isHidden || model.status != .completed
        timeField.isHidden = !badge.isHidden
        timeField.textColor = emphasized ? selectedText : model.status.isRunning ? Theme.ink : .secondaryLabelColor
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        spinner.stopAnimation(nil)
        avatarView.isAnimating = false
        model = nil
    }
}
