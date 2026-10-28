import AppKit
import CoincideKit

/// Floating glass bar at the foot of the diff inspector: the branch, how it stands against its
/// upstream, and T3 Code's git action button (a primary action plus a menu of the others).
final class GitActionsBar: NSView {
    struct State: Equatable {
        var branch: String?
        var ahead = 0
        var behind = 0
        var upstream: String?
        var pullRequest: GitPullRequest?
        /// What the host calls the pull request: GitLab's are merge requests, written `!12`.
        var changeRequestTerm = ChangeRequestTerm.pullRequest
        var quickAction = GitQuickAction(title: String(localized: "Commit"), kind: .hint(""), isEnabled: false)
        /// The step a running action is on, such as "Pushing…".
        var progress: String?
    }

    var onQuickAction: (() -> Void)?
    var menuProvider: (() -> NSMenu)?

    private let glass = FlatSurfaceView()
    private let branchIcon = NSImageView()
    private let branchLabel = NSTextField(labelWithString: "")
    private let syncLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let progressLabel = NSTextField(labelWithString: "")
    private let primaryButton = NSButton(title: "", target: nil, action: nil)
    private let menuButton = NSButton(title: "", target: nil, action: nil)
    private(set) var state = State()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        glass.cornerRadius = 18
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)

        branchIcon.image = Theme.symbol("arrow.triangle.branch", size: 12, weight: .medium)
        branchIcon.contentTintColor = .secondaryLabelColor
        branchLabel.font = .systemFont(ofSize: Theme.fontSize - 1, weight: .medium)
        branchLabel.lineBreakMode = .byTruncatingMiddle
        branchLabel.setContentCompressionResistancePriority(.init(100), for: .horizontal)
        syncLabel.font = .monospacedDigitSystemFont(ofSize: Theme.fontSize - 2, weight: .regular)
        syncLabel.textColor = .secondaryLabelColor
        syncLabel.setContentCompressionResistancePriority(.init(200), for: .horizontal)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        progressLabel.font = .systemFont(ofSize: Theme.fontSize - 2)
        progressLabel.textColor = .secondaryLabelColor
        progressLabel.lineBreakMode = .byTruncatingTail
        progressLabel.setContentCompressionResistancePriority(.init(150), for: .horizontal)

        primaryButton.bezelStyle = .glass
        primaryButton.controlSize = .regular
        primaryButton.tintProminence = .primary
        primaryButton.target = self
        primaryButton.action = #selector(runQuickAction)
        primaryButton.imagePosition = .imageLeading
        primaryButton.setContentCompressionResistancePriority(.init(300), for: .horizontal)

        menuButton.bezelStyle = .glass
        menuButton.controlSize = .regular
        menuButton.image = Theme.symbol("chevron.down", size: 11, weight: .semibold)
        menuButton.imagePosition = .imageOnly
        menuButton.target = self
        menuButton.action = #selector(showMenu)
        menuButton.setAccessibilityLabel(String(localized: "More Git actions"))
        menuButton.toolTip = String(localized: "More Git actions")

        let branch = NSStackView(views: [branchIcon, branchLabel, syncLabel])
        branch.spacing = 4
        let row = NSStackView(views: [branch, NSView(), spinner, progressLabel, primaryButton, menuButton])
        row.spacing = 6
        row.edgeInsets = NSEdgeInsets(top: 6, left: 14, bottom: 6, right: 6)
        row.setCustomSpacing(4, after: primaryButton)
        row.setHuggingPriority(.init(1), for: .horizontal)
        glass.contentView = row

        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(String(localized: "Git actions"))
        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 44) }

    func update(_ state: State) {
        guard state != self.state else { return }
        self.state = state
        apply()
    }

    private func apply() {
        branchLabel.stringValue = state.branch ?? String(localized: "Detached HEAD")
        branchLabel.textColor = state.branch == nil ? .systemOrange : .labelColor
        var tooltip = state.branch ?? String(localized: "HEAD is not on a branch.")
        if let upstream = state.upstream { tooltip += "\n" + String(localized: "Tracks \(upstream)") }
        if let pullRequest = state.pullRequest {
            tooltip += "\n" + state.changeRequestTerm.summary(pullRequest.number, title: pullRequest.title)
        }
        branchLabel.toolTip = tooltip

        var sync: [String] = []
        if state.ahead > 0 { sync.append("↑\(state.ahead)") }
        if state.behind > 0 { sync.append("↓\(state.behind)") }
        if let pullRequest = state.pullRequest { sync.append(state.changeRequestTerm.reference(pullRequest.number)) }
        syncLabel.stringValue = sync.joined(separator: " ")
        syncLabel.isHidden = sync.isEmpty
        syncLabel.setAccessibilityLabel(
            String(localized: "\(state.ahead) commits to push, \(state.behind) to pull"))

        let running = state.progress != nil
        progressLabel.stringValue = state.progress ?? ""
        progressLabel.isHidden = !running
        if running { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        primaryButton.isHidden = running
        menuButton.isHidden = running

        let action = state.quickAction
        primaryButton.title = action.title
        primaryButton.image = Theme.symbol(Self.symbol(for: action.kind), size: 12, weight: .medium)
        primaryButton.isEnabled = action.isEnabled
        if case .hint(let hint) = action.kind, !hint.isEmpty {
            primaryButton.toolTip = hint
        } else {
            primaryButton.toolTip = nil
        }
    }

    private static func symbol(for kind: GitQuickAction.Kind) -> String {
        switch kind {
        case .pull: "arrow.down.circle"
        case .hint: "checkmark.circle"
        case .run(let action):
            switch action {
            case .commit: "checkmark.circle"
            case .commitPush, .push: "arrow.up.circle"
            case .commitPushPR, .createPR: "arrow.triangle.pull"
            }
        }
    }

    @objc private func runQuickAction() { onQuickAction?() }

    @objc private func showMenu() {
        guard let menu = menuProvider?() else { return }
        ThemedPopup.show(menu: menu, from: menuButton)
    }
}

/// A short-lived message above the action bar: what a git action did, or why it failed,
/// with an optional follow-up such as "Create PR".
final class GitResultBanner: NSView {
    private let glass = FlatSurfaceView()
    private let icon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let actionButton = NSButton(title: "", target: nil, action: nil)
    private let closeButton = NSButton(title: "", target: nil, action: nil)
    private var action: (() -> Void)?
    private var dismissTask: Task<Void, Never>?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        glass.cornerRadius = 14
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)
        titleLabel.font = .systemFont(ofSize: Theme.fontSize - 1, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        detailLabel.font = .systemFont(ofSize: Theme.fontSize - 2)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.maximumNumberOfLines = 4
        detailLabel.isSelectable = true
        actionButton.bezelStyle = .glass
        actionButton.controlSize = .small
        actionButton.target = self
        actionButton.action = #selector(runAction)
        closeButton.isBordered = false
        closeButton.image = Theme.symbol("xmark", size: 10, weight: .semibold)
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(dismiss)
        closeButton.setAccessibilityLabel(String(localized: "Dismiss"))

        let text = NSStackView(views: [titleLabel, detailLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        text.setContentCompressionResistancePriority(.init(100), for: .horizontal)
        let row = NSStackView(views: [icon, text, actionButton, closeButton])
        row.alignment = .centerY
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 10)
        glass.contentView = row
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Shows a message. Successes disappear after ten seconds; failures stay until dismissed.
    func show(title: String, detail: String?, isError: Bool, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        titleLabel.stringValue = title
        detailLabel.stringValue = detail ?? ""
        detailLabel.isHidden = (detail ?? "").isEmpty
        icon.image = Theme.symbol(isError ? "exclamationmark.triangle" : "checkmark.circle", size: 15, weight: .medium)
        icon.contentTintColor = isError ? .systemOrange : .systemGreen
        self.action = action
        actionButton.title = actionTitle ?? ""
        actionButton.isHidden = actionTitle == nil
        setAccessibilityLabel([title, detail].compactMap { $0 }.joined(separator: ". "))
        isHidden = false
        NSAccessibility.post(element: self, notification: .announcementRequested, userInfo: [
            .announcement: title, .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
        dismissTask?.cancel()
        guard !isError else { return }
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    @objc func dismiss() {
        dismissTask?.cancel()
        isHidden = true
        action = nil
    }

    @objc private func runAction() {
        let action = self.action
        dismiss()
        action?()
    }
}
