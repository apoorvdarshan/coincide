import AppKit
import CoincideKit

/// Shown when no thread is selected: pick one, start one, or add a first project.
final class ChatNoThreadView: NSView {
    private let icon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private lazy var newThreadButton = NSButton(title: String(localized: "New Thread"), target: self, action: #selector(newThread))
    private lazy var addProjectButton = NSButton(title: String(localized: "Add Project…"), target: self, action: #selector(addProject))

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
    private let selectionLabel = NSTextField(labelWithString: "")
    private let providerRow = NSStackView()
    private let hintsStack = NSStackView()
    private let checkingSpinner = NSProgressIndicator()
    private lazy var refreshButton = NSButton(title: String(localized: "Check Again"), target: self, action: #selector(refresh))
    private lazy var settingsButton = NSButton(title: String(localized: "Agent Settings…"), target: self, action: #selector(openSettings))
    private let footer = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        headline.alignment = .center
        headline.lineBreakMode = .byTruncatingMiddle
        selectionLabel.alignment = .center
        selectionLabel.textColor = .secondaryLabelColor
        providerRow.orientation = .horizontal
        providerRow.spacing = 6
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
        let stack = NSStackView(views: [headline, selectionLabel, providerRow, hintsStack, footer])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.setCustomSpacing(18, after: selectionLabel)
        stack.setCustomSpacing(18, after: providerRow)
        stack.setCustomSpacing(14, after: hintsStack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -10),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: Theme.contentMaxWidth),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(thread: ChatThread, project: Project?, registry: ProviderRegistry) {
        let name = project?.name ?? String(localized: "this project")
        let size: CGFloat = 24
        let text = NSMutableAttributedString(
            string: String(localized: "What should we build in "), attributes: [.font: NSFont.systemFont(ofSize: size), .foregroundColor: NSColor.labelColor])
        text.append(NSAttributedString(string: name, attributes: [.font: NSFont.systemFont(ofSize: size, weight: .semibold), .foregroundColor: NSColor.labelColor]))
        text.append(NSAttributedString(string: "?", attributes: [.font: NSFont.systemFont(ofSize: size), .foregroundColor: NSColor.labelColor]))
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        centered.lineBreakMode = .byTruncatingMiddle
        text.addAttribute(.paragraphStyle, value: centered, range: NSRange(location: 0, length: text.length))
        headline.attributedStringValue = text
        headline.toolTip = project?.path

        let selection = thread.selection
        let model = registry.displayName(for: selection)
        let usesDefault = selection.modelID == "default" || model.isEmpty
        selectionLabel.stringValue =
            usesDefault
            ? String(localized: "Using \(selection.provider.displayName)")
            : String(localized: "Using \(selection.provider.displayName) · \(model)")
        selectionLabel.font = .systemFont(ofSize: 13)

        providerRow.setViews(registry.orderedKinds.map { ProviderChip(kind: $0, status: registry.status($0), isSelected: $0 == selection.provider) }, in: .center)

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
}

/// A provider's name with a dot for whether it is ready.
private final class ProviderChip: NSView {
    init(kind: ProviderKind, status: ProviderStatus, isSelected: Bool) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 11
        layer?.cornerCurve = .continuous
        let isReady = status.state == .ready
        let icon = NSImageView(image: Theme.symbol(kind.symbolName, size: 10, weight: .semibold) ?? NSImage())
        icon.contentTintColor = isReady ? Theme.color(for: kind) : .tertiaryLabelColor
        let label = NSTextField(labelWithString: kind.displayName)
        label.font = .systemFont(ofSize: 12, weight: isSelected ? .semibold : .regular)
        label.textColor = isReady ? .labelColor : .tertiaryLabelColor
        let stack = NSStackView(views: [icon, label])
        stack.spacing = 5
        stack.edgeInsets = NSEdgeInsets(top: 3, left: 9, bottom: 3, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 22),
        ])
        let state: String =
            switch status.state {
            case .ready: String(localized: "ready")
            case .notInstalled: String(localized: "not installed")
            case .notAuthenticated: String(localized: "not signed in")
            case .error: String(localized: "unavailable")
            case .unknown: status.message ?? String(localized: "checking")
            }
        toolTip = [status.version, status.account, status.message].compactMap { $0 }.joined(separator: "\n").nilIfEmpty
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("\(kind.displayName), \(state)")
        self.isSelected = isSelected
    }

    private var isSelected = false

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(isSelected ? 0.09 : 0.05).cgColor
    }
}

/// How to set up a missing provider, with its command in code style.
private final class SetupHintRow: NSView {
    init(kind: ProviderKind, status: ProviderStatus, registry: ProviderRegistry) {
        super.init(frame: .zero)
        let icon = NSImageView(image: Theme.symbol(kind.symbolName, size: 11, weight: .semibold) ?? NSImage())
        icon.contentTintColor = .tertiaryLabelColor
        let hint = registry.provider(kind)?.setupHint ?? status.message ?? ""
        let font = NSFont.systemFont(ofSize: 12)
        let text = NSMutableAttributedString(
            string: kind.displayName + "  ", attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor])
        text.append(TranscriptText.inlineLabel(hint, font: font, color: .secondaryLabelColor))
        let label = NSTextField(labelWithAttributedString: text)
        label.lineBreakMode = .byTruncatingTail
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

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
