import AppKit
import CoincideKit

/// Shown when no thread is selected: pick one, start one, or add a first project.
final class ChatNoThreadView: NSView {
    private let icon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private lazy var newThreadButton = ThemedButton(
        title: String(localized: "New Thread"), style: .primary, target: self, action: #selector(newThread))
    private lazy var addProjectButton = ThemedButton(
        title: String(localized: "Add Project…"), target: self, action: #selector(addProject))

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        icon.image = Theme.symbol("bubble.left.and.text.bubble.right", size: 34, weight: .light)
        icon.contentTintColor = .tertiaryLabelColor
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.alignment = .center
        messageLabel.font = .systemFont(ofSize: 13)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.alignment = .center
        messageLabel.preferredMaxLayoutWidth = 340
        for button in [newThreadButton, addProjectButton] {
            button.bezelStyle = .push
            button.controlSize = .large
        }
        newThreadButton.tintProminence = .primary
        let buttons = NSStackView(views: [addProjectButton, newThreadButton])
        buttons.spacing = 10
        let stack = NSStackView(views: [icon, titleLabel, messageLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.setCustomSpacing(16, after: icon)
        stack.setCustomSpacing(20, after: messageLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -20),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
            messageLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 340),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(hasProjects: Bool) {
        if hasProjects {
            titleLabel.stringValue = String(localized: "Pick a thread to continue")
            messageLabel.stringValue = String(localized: "Select an existing thread or create a new one to get started.")
        } else {
            titleLabel.stringValue = String(localized: "Add a project to start")
            messageLabel.stringValue = String(
                localized: "Coincide runs your coding agents in a folder on your Mac. Add one, then start a thread.")
        }
        newThreadButton.isHidden = !hasProjects
        addProjectButton.tintProminence = hasProjects ? .automatic : .primary
    }

    @objc private func newThread() {
        AppEvents.newThread()
    }

    @objc private func addProject() {
        AppEvents.post(.coincideAddProject)
    }
}

/// The start of a new thread: what to build, which agents are ready, and how to set up the rest.
final class ChatWelcomeView: NSView {
    private let headline = NSTextField(labelWithString: "")
    /// A bot's avatar above the headline, in its conversations.
    private let botAvatar = BotAvatarView(size: 52)
    private let selectionLabel = NSTextField(labelWithString: "")
    private let providerRow = NSStackView()
    private let hintsStack = NSStackView()
    private let checkingSpinner = NSProgressIndicator()
    private lazy var refreshButton = NSButton(title: String(localized: "Check Again"), target: self, action: #selector(refresh))
    private lazy var settingsButton = NSButton(title: String(localized: "Agent Settings…"), target: self, action: #selector(openSettings))
    private let footer = NSStackView()
    private let missingLabel = NSTextField(labelWithString: "")
    private lazy var locateButton = ThemedButton(
        title: String(localized: "Locate Folder…"), target: self, action: #selector(locateFolder))
    private let missingRow = NSStackView()
    private var projectID: UUID?
    /// Runs when the user picks an agent from the row of agents.
    var onChooseAgent: ((ProviderKind) -> Void)?
    /// How to set up the agents that aren't ready, with buttons to check again and open their settings. The chat
    /// places it under the composer, which sits in the middle of an empty thread.
    let setupView = NSStackView()

    /// For text that gives way before the chat grows: above a stack view's hugging (250), so it keeps its
    /// size when there is room, and below the sidebar's holding priority (260), so the split view never
    /// shrinks the sidebar to make room for it.
    static let yieldingPriority = NSLayoutConstraint.Priority(255)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        headline.alignment = .center
        headline.lineBreakMode = .byTruncatingMiddle
        headline.setContentCompressionResistancePriority(Self.yieldingPriority, for: .horizontal)
        selectionLabel.alignment = .center
        selectionLabel.textColor = .secondaryLabelColor
        providerRow.orientation = .horizontal
        providerRow.alignment = .top
        providerRow.spacing = 10
        // Chips that do not fit are left out, the least useful first.
        providerRow.setClippingResistancePriority(Self.yieldingPriority, for: .horizontal)
        hintsStack.orientation = .vertical
        hintsStack.alignment = .leading
        hintsStack.spacing = 8
        checkingSpinner.style = .spinning
        checkingSpinner.controlSize = .small
        checkingSpinner.isDisplayedWhenStopped = false
        for button in [refreshButton, settingsButton] {
            button.bezelStyle = .accessoryBarAction
            button.isBordered = false
            button.font = .systemFont(ofSize: 12, weight: .medium)
            button.contentTintColor = .secondaryLabelColor
        }
        footer.orientation = .horizontal
        footer.spacing = 12
        footer.setViews([checkingSpinner, refreshButton, settingsButton], in: .center)
        let warning = NSImageView(image: Theme.symbol("questionmark.folder", size: 13, weight: .medium) ?? NSImage())
        warning.contentTintColor = Theme.warning
        warning.setAccessibilityElement(false)
        missingLabel.font = .systemFont(ofSize: 13)
        missingLabel.textColor = .secondaryLabelColor
        missingLabel.lineBreakMode = .byTruncatingTail
        missingLabel.setContentCompressionResistancePriority(Self.yieldingPriority, for: .horizontal)
        locateButton.bezelStyle = .push
        locateButton.controlSize = .small
        missingRow.orientation = .horizontal
        missingRow.spacing = 8
        missingRow.setViews([warning, missingLabel, locateButton], in: .center)
        missingRow.isHidden = true
        botAvatar.isHidden = true
        let stack = NSStackView(views: [botAvatar, headline, selectionLabel, missingRow, providerRow])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.setCustomSpacing(12, after: botAvatar)
        stack.setCustomSpacing(6, after: headline)
        stack.setCustomSpacing(26, after: selectionLabel)
        stack.setCustomSpacing(18, after: missingRow)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        // The headline and agents sit just above the composer; when the window is short they scroll off the top
        // rather than push it down.
        let fitsBelowTop = stack.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 12)
        fitsBelowTop.priority = .defaultLow
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -28),
            fitsBelowTop,
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: Theme.contentMaxWidth),
        ])
        setupView.setViews([hintsStack, footer], in: .top)
        setupView.orientation = .vertical
        setupView.alignment = .centerX
        setupView.spacing = 14
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(thread: ChatThread, project: Project?, registry: ProviderRegistry) {
        let name = project?.name ?? String(localized: "this project")
        // One sentence, so each language can place the project name where it belongs. Set in New York, the serif of
        // the agents' replies. A chat has no project to name.
        let bot = thread.botID.flatMap { AppStore.shared.bot($0) }
        let sentence =
            if let bot {
                String(localized: "Hi, I’m \(bot.displayName). What can I do for you?")
            } else if project?.isChats == true || project?.isBots == true {
                String(localized: "What can I help with?")
            } else {
                String(localized: "What should we build in \(name)?")
            }
        botAvatar.isHidden = bot == nil
        if let bot { botAvatar.avatar = bot.avatar }
        let text = NSMutableAttributedString(
            string: sentence, attributes: [.font: Theme.serifFont(ofSize: 30), .foregroundColor: NSColor.labelColor])
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        centered.lineBreakMode = .byTruncatingMiddle
        text.addAttribute(.paragraphStyle, value: centered, range: NSRange(location: 0, length: text.length))
        headline.attributedStringValue = text
        headline.toolTip = bot?.workingDirectory.path ?? project?.path

        projectID = project?.id
        if bot == nil, let project, !FileManager.default.fileExists(atPath: project.path) {
            missingLabel.stringValue = String(localized: "The project folder was moved or deleted.")
            missingLabel.toolTip = Formatting.abbreviatedPath(project.path)
            missingRow.setAccessibilityElement(true)
            missingRow.setAccessibilityLabel(
                String(localized: "The project folder was moved or deleted: \(Formatting.abbreviatedPath(project.path))"))
            missingRow.isHidden = false
        } else {
            missingRow.isHidden = true
        }

        let selection = thread.selection
        let model = registry.displayName(for: selection)
        let usesDefault = selection.modelID == "default" || model.isEmpty
        selectionLabel.stringValue =
            usesDefault
            ? String(localized: "Using \(selection.provider.displayName)")
            : String(localized: "Using \(selection.provider.displayName) · \(model)")
        selectionLabel.font = .systemFont(ofSize: 13)

        let chips = registry.orderedKinds.map { kind in
            ProviderChip(kind: kind, status: registry.status(kind), isSelected: kind == selection.provider) { [weak self] in
                self?.onChooseAgent?(kind)
            }
        }
        providerRow.setViews(chips, in: .center)
        for (kind, chip) in zip(registry.orderedKinds, chips) {
            let priority: NSStackView.VisibilityPriority =
                kind == selection.provider ? .mustHold : registry.status(kind).state == .ready ? .init(600) : .init(500)
            providerRow.setVisibilityPriority(priority, for: chip)
        }

        let missing = registry.orderedKinds.filter {
            let state = registry.status($0).state
            return state == .notInstalled || state == .notAuthenticated || state == .error
        }
        hintsStack.setViews(missing.map { SetupHintRow(kind: $0, status: registry.status($0), registry: registry) }, in: .top)
        hintsStack.isHidden = missing.isEmpty
        if registry.isRefreshing { checkingSpinner.startAnimation(nil) } else { checkingSpinner.stopAnimation(nil) }
        refreshButton.isEnabled = !registry.isRefreshing
    }

    @objc private func refresh() {
        Task { await ProviderRegistry.shared.refresh() }
    }

    @objc private func openSettings() {
        AppEvents.showSettings(section: .providers)
    }

    @objc private func locateFolder() {
        guard let projectID else { return }
        ThreadActions.locateProject(projectID, in: window)
    }
}

/// An agent to start the thread with: its logo on a tile and its name below. The chosen one is tinted in the agent's
/// color; agents that are not ready are dimmed and cannot be chosen.
private final class ProviderChip: NSControl, PointerCursorControl {
    private static let tileSize: CGFloat = 52

    private let kind: ProviderKind
    private let isSelected: Bool
    private let isReady: Bool
    /// An agent that isn't ready can't be chosen, so it keeps the arrow (`PointerCursorControl`).
    var isClickable: Bool { isReady }
    private let onChoose: () -> Void
    private let tile = NSView()
    private var isHovered = false
    private var isPressed = false

    init(kind: ProviderKind, status: ProviderStatus, isSelected: Bool, onChoose: @escaping () -> Void) {
        self.kind = kind
        self.isSelected = isSelected
        isReady = status.state == .ready
        self.onChoose = onChoose
        super.init(frame: .zero)
        tile.wantsLayer = true
        tile.layer?.cornerRadius = 14
        tile.layer?.cornerCurve = .continuous
        let logo = NSImageView(image: Theme.logo(for: kind))
        logo.imageScaling = .scaleProportionallyUpOrDown
        logo.contentTintColor = .labelColor
        logo.alphaValue = isReady ? 1 : 0.35
        let label = NSTextField(labelWithString: kind.displayName)
        label.font = .systemFont(ofSize: 11, weight: isSelected ? .semibold : .regular)
        label.textColor = isSelected ? .labelColor : isReady ? .secondaryLabelColor : .tertiaryLabelColor
        label.alignment = .center
        for view in [tile, logo, label] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.setAccessibilityElement(false)
        }
        addSubview(tile)
        tile.addSubview(logo)
        addSubview(label)
        NSLayoutConstraint.activate([
            tile.topAnchor.constraint(equalTo: topAnchor),
            tile.centerXAnchor.constraint(equalTo: centerXAnchor),
            tile.widthAnchor.constraint(equalToConstant: Self.tileSize),
            tile.heightAnchor.constraint(equalToConstant: Self.tileSize),
            logo.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            logo.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
            logo.widthAnchor.constraint(equalToConstant: 24),
            logo.heightAnchor.constraint(equalToConstant: 24),
            label.topAnchor.constraint(equalTo: tile.bottomAnchor, constant: 6),
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor),
            // One width for every agent, so the row reads as even steps whatever the names.
            widthAnchor.constraint(equalToConstant: Self.tileSize + 24),
        ])
        let state: String =
            switch status.state {
            case .ready: String(localized: "ready")
            case .notInstalled: String(localized: "not installed")
            case .notAuthenticated: String(localized: "not signed in")
            case .error: String(localized: "unavailable")
            case .unknown: status.message ?? String(localized: "checking")
            }
        toolTip = [status.version, status.account, status.message].compactMap { $0 }.joined(separator: "\n").nonEmpty
        if kind == .antigravity { addRiskBadge() }
        setAccessibilityElement(true)
        setAccessibilityRole(isReady ? .button : .staticText)
        setAccessibilityLabel("\(kind.displayName), \(state)")
        if isSelected { setAccessibilitySelected(true) }
        updateTile()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Antigravity's account-risk glyph on its tile's corner; a click opens Settings › Antigravity.
    private func addRiskBadge() {
        let badge = AntigravityRiskBadge(size: 10)
        badge.translatesAutoresizingMaskIntoConstraints = false
        addSubview(badge)
        NSLayoutConstraint.activate([
            badge.centerXAnchor.constraint(equalTo: tile.trailingAnchor, constant: -6),
            badge.centerYAnchor.constraint(equalTo: tile.topAnchor, constant: 6),
        ])
        toolTip = [toolTip, AntigravityRiskText.glyphHelp].compactMap { $0 }.joined(separator: "\n")
        setAccessibilityHelp(AntigravityRiskText.glyphHelp)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateTile()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateTile()
    }

    override func mouseDown(with event: NSEvent) {
        guard isReady else { return }
        isPressed = true
        updateTile()
    }

    override func mouseUp(with event: NSEvent) {
        guard isPressed else { return }
        isPressed = false
        updateTile()
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onChoose() }
    }

    override func accessibilityPerformPress() -> Bool {
        guard isReady else { return false }
        onChoose()
        return true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateTile()
    }

    private func updateTile() {
        guard let layer = tile.layer else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let color = Theme.color(for: kind)
            if isSelected {
                layer.backgroundColor = color.withAlphaComponent(isPressed ? 0.22 : 0.14).cgColor
                layer.borderColor = color.withAlphaComponent(0.7).cgColor
                layer.borderWidth = 1.5
            } else {
                let fill: CGFloat = isPressed ? 0.12 : isHovered && isReady ? 0.08 : 0.045
                layer.backgroundColor = NSColor.labelColor.withAlphaComponent(fill).cgColor
                layer.borderColor = NSColor.separatorColor.cgColor
                layer.borderWidth = 0
            }
        }
    }
}

/// How to set up a missing provider, with its command in code style.
private final class SetupHintRow: NSView {
    init(kind: ProviderKind, status: ProviderStatus, registry: ProviderRegistry) {
        super.init(frame: .zero)
        let icon = NSImageView(image: Theme.logo(for: kind, size: 12))
        icon.contentTintColor = .tertiaryLabelColor
        icon.alphaValue = 0.6
        let hint = registry.provider(kind)?.setupHint ?? status.message ?? ""
        let font = NSFont.systemFont(ofSize: 12)
        let text = NSMutableAttributedString(
            string: kind.displayName + "  ", attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor])
        text.append(TranscriptText.inlineLabel(hint, font: font, color: .secondaryLabelColor))
        let label = NSTextField(labelWithAttributedString: text)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(ChatWelcomeView.yieldingPriority, for: .horizontal)
        label.isSelectable = true
        label.toolTip = hint
        let stack = NSStackView(views: [icon, label])
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 560),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("\(kind.displayName): \(hint)")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
