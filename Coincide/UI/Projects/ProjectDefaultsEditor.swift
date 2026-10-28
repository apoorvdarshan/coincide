import AppKit
import CoincideKit

/// Edits only a project's new-thread defaults. Saving never rewrites its existing threads or drafts.
final class ProjectDefaultsEditor: NSViewController {
    var onSave: ((ProjectThreadDefaults?) -> Void)?
    private let project: Project
    private let store: AppStore
    private let registry: ProviderRegistry
    private var draft: ProjectThreadDefaults
    private let useGlobal = ThemedCheckbox(label: String(localized: "Use Global Defaults"), target: nil, action: nil)
    private let modelButton = ComposerControlButton()
    private let accessButton = ComposerControlButton()
    private let modeButton = ComposerControlButton()
    private let modelDetail = NSTextField(labelWithString: "")

    init(project: Project, store: AppStore, registry: ProviderRegistry) {
        self.project = project
        self.store = store
        self.registry = registry
        draft = project.threadDefaults ?? store.newThreadDefaults(in: project.id)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let title = NSTextField(labelWithString: String(localized: "Project Defaults"))
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        let name = NSTextField(labelWithString: project.name)
        name.font = .systemFont(ofSize: 13, weight: .medium)
        let subtitle = NSTextField(wrappingLabelWithString:
            String(localized: "Applies to new threads in this project. Existing threads keep their settings."))
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor
        modelDetail.font = .systemFont(ofSize: 11)
        modelDetail.textColor = .secondaryLabelColor
        useGlobal.state = project.threadDefaults == nil ? .on : .off
        useGlobal.target = self
        useGlobal.action = #selector(globalChanged)
        modelButton.popupProvider = { [weak self] in self?.picker() }
        accessButton.menuProvider = { [weak self] in
            guard let self else { return nil }
            return ComposerMenus.accessMenu(current: draft.accessMode, target: self, action: #selector(pickAccess(_:)))
        }
        modeButton.menuProvider = { [weak self] in self?.modeMenu() }
        let reset = ThemedButton(title: String(localized: "Reset to Global"), style: .plain, target: self, action: #selector(reset))
        let cancel = ThemedButton(title: String(localized: "Cancel"), style: .secondary, target: self, action: #selector(cancel))
        let save = ThemedButton(title: String(localized: "Save"), style: .primary, target: self, action: #selector(save))
        cancel.keyEquivalent = "\u{1b}"
        save.keyEquivalent = "\r"
        let buttons = NSStackView(views: [reset, NSView(), cancel, save])
        buttons.spacing = 8
        let stack = NSStackView(views: [title, name, subtitle, useGlobal,
            label(String(localized: "Model")), modelButton, modelDetail,
            label(String(localized: "Permissions")), accessButton,
            label(String(localized: "Mode")), modeButton, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.setCustomSpacing(14, after: subtitle)
        stack.setCustomSpacing(14, after: useGlobal)
        stack.setCustomSpacing(14, after: modelDetail)
        stack.setCustomSpacing(14, after: accessButton)
        stack.setCustomSpacing(20, after: modeButton)
        stack.widthAnchor.constraint(equalToConstant: 460).isActive = true
        for child in [name, subtitle, modelDetail, buttons] {
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

    private func label(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .secondaryLabelColor
        return label
    }

    private var globalDefaults: ProjectThreadDefaults {
        ProjectThreadDefaults(selection: store.settings.defaultSelection, accessMode: store.settings.defaultAccessMode)
    }

    private func refresh() {
        if useGlobal.state == .on { draft = globalDefaults }
        for button in [modelButton, accessButton, modeButton] { button.isEnabled = useGlobal.state != .on }
        let model = registry.model(for: draft.selection)
        modelButton.configure(title: registry.displayName(for: draft.selection), agent: draft.selection.provider, chevron: true)
        modelButton.setAccessibilityLabel(String(localized: "Model"))
        modelButton.accentSymbol = draft.selection.speed == nil ? nil : "bolt.fill"
        modelDetail.stringValue = [
            (draft.selection.effort ?? model?.defaultEffort).map(ComposerMenus.effortTitle),
            draft.selection.speed.map { model?.speed($0)?.name ?? $0 },
        ].compactMap { $0 }.joined(separator: " · ")
        accessButton.configure(title: draft.accessMode.displayName, symbolName: ComposerMenus.symbolName(for: draft.accessMode), chevron: true)
        accessButton.setAccessibilityLabel(String(localized: "Permissions"))
        modeButton.configure(title: draft.interactionMode.displayName, symbolName: draft.interactionMode == .plan ? "list.bullet.clipboard" : "hammer", chevron: true)
        modeButton.setAccessibilityLabel(String(localized: "Mode"))
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
    @objc private func globalChanged() { refresh() }
    @objc private func reset() { useGlobal.state = .on; refresh() }
    @objc private func save() { onSave?(useGlobal.state == .on ? nil : draft); dismiss(nil) }
    @objc private func cancel() { dismiss(nil) }
}
