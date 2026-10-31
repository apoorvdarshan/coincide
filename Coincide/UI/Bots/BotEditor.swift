import AppKit
import CoincideKit

/// Creates or edits a bot: its look, name and instructions, the agent, model and modes its new conversations start
/// with, and the folder they run in. Shown as a sheet; nothing is saved until Save.
final class BotEditor: NSViewController, NSTextFieldDelegate, NSTextViewDelegate {
    var onSave: ((Bot) -> Void)?
    private(set) var draft: Bot
    private let isNew: Bool
    private let store: AppStore
    private let registry: ProviderRegistry

    private let preview = BotAvatarView(size: 56)
    let nameField = ThemedTextField(placeholder: String(localized: "Name"))
    private let persona = NSTextView()
    private(set) var shapeButtons: [BotChoiceButton] = []
    private var tintButtons: [BotChoiceButton] = []
    private let modelButton = ComposerControlButton()
    private let accessButton = ComposerControlButton()
    private let modeButton = ComposerControlButton()
    private let modelDetail = NSTextField(labelWithString: "")
    /// Beside the agent line while the bot runs on Antigravity: its account risk, opening Settings › Antigravity.
    private let modelRisk = AntigravityRiskBadge(size: 10)
    private let folderLabel = NSTextField(labelWithString: "")
    private lazy var homeButton = ThemedButton(
        title: String(localized: "Use Home Folder"), style: .plain, target: self, action: #selector(useHomeFolder))
    private lazy var saveButton = ThemedButton(
        title: isNew ? String(localized: "Create Bot") : String(localized: "Save"), style: .primary, target: self,
        action: #selector(save))

    init(bot: Bot?, store: AppStore = .shared, registry: ProviderRegistry = .shared) {
        self.store = store
        self.registry = registry
        isNew = bot == nil
        draft = bot ?? Self.newBot(store: store, registry: registry)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// A fresh bot on the user's default agent: a character none of their bots is yet when one is left, in its own color
    /// and with its name.
    static func newBot(store: AppStore, registry: ProviderRegistry) -> Bot {
        let used = Set(store.bots.map(\.avatar.shape))
        let characters = BotAvatar.Shape.allCases
        let character = characters.filter { !used.contains($0) }.randomElement() ?? characters.randomElement()!
        return Bot(
            name: character.defaultName, avatar: BotAvatar(character: character), persona: "",
            selection: registry.usableSelection(preferring: store.settings.defaultSelection),
            accessMode: store.settings.defaultAccessMode)
    }

    override func loadView() {
        let heading = NSTextField(labelWithString: isNew ? String(localized: "New Bot") : String(localized: "Edit Bot"))
        heading.font = .systemFont(ofSize: 17, weight: .semibold)
        let subtitle = NSTextField(wrappingLabelWithString: String(
            localized: "A bot is an ongoing conversation with its own personality and job. It runs on your agents like any thread."))
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor

        nameField.stringValue = draft.name
        nameField.delegate = self
        nameField.setAccessibilityLabel(String(localized: "Name"))
        let nameColumn = NSStackView(views: [label(String(localized: "Name")), nameField])
        nameColumn.orientation = .vertical
        nameColumn.alignment = .leading
        nameColumn.spacing = 6
        let identity = NSStackView(views: [preview, nameColumn])
        identity.spacing = 14
        identity.alignment = .bottom

        shapeButtons = BotAvatar.Shape.allCases.map { shape in
            let button = BotChoiceButton(kind: .shape(shape), target: self, action: #selector(pickShape(_:)))
            button.setAccessibilityLabel(BotAvatarArt.name(of: shape))
            button.toolTip = BotAvatarArt.name(of: shape)
            return button
        }
        tintButtons = BotAvatar.Tint.allCases.map { tint in
            let button = BotChoiceButton(kind: .tint(tint), target: self, action: #selector(pickTint(_:)))
            button.setAccessibilityLabel(BotAvatarArt.name(of: tint))
            button.toolTip = BotAvatarArt.name(of: tint)
            return button
        }
        let shapes = NSStackView(views: shapeButtons)
        shapes.spacing = 6
        let tints = NSStackView(views: tintButtons)
        tints.spacing = 10

        persona.string = draft.persona
        persona.delegate = self
        persona.isRichText = false
        persona.allowsUndo = true
        persona.font = .systemFont(ofSize: 13)
        persona.backgroundColor = Theme.raisedFill
        persona.textColor = Theme.ink
        persona.insertionPointColor = Theme.ink
        persona.textContainerInset = NSSize(width: 8, height: 8)
        persona.isVerticallyResizable = true
        persona.isHorizontallyResizable = false
        persona.autoresizingMask = [.width]
        persona.textContainer?.widthTracksTextView = true
        persona.setAccessibilityLabel(String(localized: "Instructions"))
        let personaScroll = NSScrollView()
        personaScroll.documentView = persona
        personaScroll.hasVerticalScroller = true
        personaScroll.borderType = .noBorder
        personaScroll.drawsBackground = false
        personaScroll.wantsLayer = true
        personaScroll.layer?.cornerRadius = 7
        personaScroll.layer?.cornerCurve = .continuous
        personaScroll.layer?.borderWidth = 1
        personaScroll.layer?.borderColor = Theme.surfaceBorder.cgColor
        personaScroll.heightAnchor.constraint(equalToConstant: 120).isActive = true
        let personaHint = hint(String(
            localized: "Who the bot is and how it works. Its agent gets this at the start of each session; it never shows in the conversation."))

        modelDetail.font = .systemFont(ofSize: 11)
        modelDetail.textColor = .secondaryLabelColor
        modelButton.popupProvider = { [weak self] in self?.picker() }
        accessButton.menuProvider = { [weak self] in
            guard let self else { return nil }
            return ComposerMenus.accessMenu(current: draft.accessMode, target: self, action: #selector(pickAccess(_:)))
        }
        modeButton.menuProvider = { [weak self] in self?.modeMenu() }
        let agentRow = NSStackView(views: [modelButton, accessButton, modeButton])
        agentRow.spacing = 6
        let modelDetailRow = NSStackView(views: [modelDetail, modelRisk])
        modelDetailRow.spacing = 4
        modelDetailRow.detachesHiddenViews = true

        folderLabel.font = .systemFont(ofSize: 12)
        folderLabel.textColor = Theme.ink
        folderLabel.lineBreakMode = .byTruncatingMiddle
        folderLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let choose = ThemedButton(title: String(localized: "Choose…"), style: .secondary, target: self, action: #selector(chooseFolder))
        let folderRow = NSStackView(views: [folderLabel, NSView(), homeButton, choose])
        folderRow.spacing = 8
        let folderHint = hint(String(localized: "Its conversations run here and can work with everything inside."))

        let cancel = ThemedButton(title: String(localized: "Cancel"), style: .secondary, target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        saveButton.keyEquivalent = "\r"
        saveButton.keyEquivalentModifierMask = .command
        let buttons = NSStackView(views: [NSView(), cancel, saveButton])
        buttons.spacing = 8

        let stack = NSStackView(views: [
            heading, subtitle, identity,
            label(String(localized: "Look")), shapes, tints,
            label(String(localized: "Instructions")), personaScroll, personaHint,
            label(String(localized: "Agent")), agentRow, modelDetailRow,
            label(String(localized: "Folder")), folderRow, folderHint, buttons,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.setCustomSpacing(16, after: subtitle)
        stack.setCustomSpacing(16, after: identity)
        stack.setCustomSpacing(10, after: shapes)
        stack.setCustomSpacing(16, after: tints)
        stack.setCustomSpacing(16, after: personaHint)
        stack.setCustomSpacing(16, after: modelDetailRow)
        stack.setCustomSpacing(20, after: folderHint)
        stack.widthAnchor.constraint(equalToConstant: 520).isActive = true
        for child in [subtitle, identity, personaScroll, personaHint, folderRow, folderHint, buttons] {
            child.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        }
        let root = SolidBackgroundView(color: Theme.contentBackground)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor), stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor), stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
        refresh()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(nameField)
    }

    private func label(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func hint(_ text: String) -> NSTextField {
        let hint = NSTextField(wrappingLabelWithString: text)
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        return hint
    }

    private func refresh() {
        preview.avatar = draft.avatar
        // Each character shows in its own color, the chosen one in the bot's.
        for button in shapeButtons {
            guard case .shape(let shape) = button.kind else { continue }
            button.isChosen = shape == draft.avatar.shape
            button.tint = button.isChosen ? draft.avatar.tint : shape.defaultTint
        }
        for button in tintButtons {
            guard case .tint(let tint) = button.kind else { continue }
            button.isChosen = tint == draft.avatar.tint
        }
        let model = registry.model(for: draft.selection)
        modelButton.configure(title: registry.displayName(for: draft.selection), agent: draft.selection.provider, chevron: true)
        modelButton.setAccessibilityLabel(String(localized: "Model"))
        modelButton.accentSymbol = draft.selection.speed == nil ? nil : "bolt.fill"
        let account = registry.accountName(for: draft.selection)
        modelDetail.stringValue = [
            account.map { "\(draft.selection.provider.displayName) (\($0))" } ?? draft.selection.provider.displayName,
            (draft.selection.effort ?? model?.defaultEffort).map(ComposerMenus.effortTitle),
            draft.selection.speed.map { model?.speed($0)?.name ?? $0 },
        ].compactMap { $0 }.joined(separator: " · ")
        modelRisk.isHidden = draft.selection.provider != .antigravity
        accessButton.configure(
            title: draft.accessMode.displayName, symbolName: ComposerMenus.symbolName(for: draft.accessMode), chevron: true)
        accessButton.setAccessibilityLabel(String(localized: "Permissions"))
        modeButton.configure(
            title: draft.interactionMode.displayName,
            symbolName: draft.interactionMode == .plan ? "list.bullet.clipboard" : "hammer", chevron: true)
        modeButton.setAccessibilityLabel(String(localized: "Mode"))
        folderLabel.stringValue = (draft.workingDirectory.path as NSString).abbreviatingWithTildeInPath
        folderLabel.toolTip = draft.workingDirectory.path
        homeButton.isHidden = draft.folder == nil
        saveButton.isEnabled = !nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func picker() -> ModelPickerViewController {
        let picker = ModelPickerViewController(current: draft.selection, registry: registry, store: store)
        picker.onSelect = { [weak self] selection in
            guard let self else { return }
            let model = registry.model(for: selection)
            var selection = selection
            if let effort = draft.selection.effort, model?.efforts.contains(effort) == true { selection.effort = effort }
            selection.speed = model?.speed(draft.selection.speed)?.id
            draft.selection = selection
            refresh()
        }
        picker.onEffort = { [weak self] effort in self?.draft.selection.effort = effort; self?.refresh() }
        picker.onSpeed = { [weak self] speed in self?.draft.selection.speed = speed; self?.refresh() }
        picker.onRefresh = { [weak self] in Task { await self?.registry.refresh(); self?.refresh() } }
        picker.onSettings = { AppEvents.showSettings(section: .models) }
        return picker
    }

    private func modeMenu() -> NSMenu {
        let menu = NSMenu()
        for mode in InteractionMode.allCases {
            let item = menu.addItem(withTitle: mode.displayName, action: #selector(pickMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode
            item.state = mode == draft.interactionMode ? .on : .off
        }
        return menu
    }

    func controlTextDidChange(_ obj: Notification) { refresh() }

    func textDidChange(_ notification: Notification) { draft.persona = persona.string }

    /// A character comes in its own color, and brings its name while the bot still has the previous character's (or
    /// none); a name the user wrote stays.
    @objc func pickShape(_ sender: BotChoiceButton) {
        guard case .shape(let shape) = sender.kind, shape != draft.avatar.shape else { return }
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name == draft.avatar.shape.defaultName { nameField.stringValue = shape.defaultName }
        draft.avatar = BotAvatar(character: shape)
        refresh()
    }

    @objc private func pickTint(_ sender: BotChoiceButton) {
        guard case .tint(let tint) = sender.kind else { return }
        draft.avatar.tint = tint
        refresh()
    }

    @objc private func pickAccess(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? AccessMode else { return }
        draft.accessMode = mode
        refresh()
    }

    @objc private func pickMode(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? InteractionMode else { return }
        draft.interactionMode = mode
        refresh()
    }

    @objc private func chooseFolder() {
        guard let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = draft.workingDirectory
        panel.prompt = String(localized: "Choose")
        panel.message = String(localized: "Choose the folder this bot works in.")
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self, let url = panel.url else { return }
            let path = url.standardizedFileURL.path
            draft.folder = path == FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path ? nil : path
            refresh()
        }
    }

    @objc private func useHomeFolder() {
        draft.folder = nil
        refresh()
    }

    @objc private func save() {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        draft.name = name
        draft.persona = persona.string.trimmingCharacters(in: .whitespacesAndNewlines)
        onSave?(draft)
        dismiss(nil)
    }

    @objc private func cancel() { dismiss(nil) }
}

/// One choice in the editor's avatar picker: a character, drawn in `tint`, or a tint swatch. The chosen one is ringed in
/// the theme's accent.
final class BotChoiceButton: NSButton {
    enum Kind {
        case shape(BotAvatar.Shape)
        case tint(BotAvatar.Tint)
    }

    let kind: Kind
    /// The tint a shape choice is drawn in.
    var tint: BotAvatar.Tint = .sky {
        didSet { needsDisplay = true }
    }
    var isChosen = false {
        didSet {
            needsDisplay = true
            setAccessibilityValue(isChosen ? String(localized: "Selected") : nil)
        }
    }
    private var isHovered = false

    init(kind: Kind, target: AnyObject, action: Selector) {
        self.kind = kind
        super.init(frame: .zero)
        self.target = target
        self.action = action
        isBordered = false
        title = ""
        setButtonType(.momentaryChange)
        let side: CGFloat
        switch kind {
        case .shape: side = 40
        case .tint: side = 24
        }
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: side), heightAnchor.constraint(equalToConstant: side)])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        switch kind {
        case .shape(let shape):
            let tile = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 9, yRadius: 9)
            (isChosen || isHovered ? Theme.raisedFill : NSColor.clear).setFill()
            tile.fill()
            if isChosen {
                Theme.accent.setStroke()
                tile.lineWidth = 2
                tile.stroke()
            }
            BotAvatarArt.draw(BotAvatar(shape: shape, tint: tint), in: bounds.insetBy(dx: 7, dy: 7))
        case .tint(let tint):
            let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
            if isChosen {
                Theme.accent.setStroke()
                ring.lineWidth = 2
                ring.stroke()
            }
            BotAvatarArt.color(tint).setFill()
            NSBezierPath(ovalIn: bounds.insetBy(dx: isHovered && !isChosen ? 3 : 4.5, dy: isHovered && !isChosen ? 3 : 4.5)).fill()
        }
    }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: 9, yRadius: 9).fill()
    }

    override var focusRingMaskBounds: NSRect { bounds }
}
