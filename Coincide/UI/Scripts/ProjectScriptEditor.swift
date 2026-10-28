import AppKit
import CoincideKit

/// Adds or edits one project script: its name, command, icon, and whether it runs in new worktrees (T3 Code's
/// project script dialog). Shown as a sheet on the main window.
final class ProjectScriptEditor: NSViewController, NSTextFieldDelegate {
    var onSave: ((ProjectScript) -> Void)?
    var onDelete: ((ProjectScript) -> Void)?

    private var script: ProjectScript
    private let isNew: Bool
    private let nameField = ThemedTextField(placeholder: String(localized: "Dev server"))
    private let commandField = ThemedTextField(placeholder: "npm run dev", monospaced: true)
    private var iconButtons: [ProjectScript.Icon: ThemedButton] = [:]
    private let worktreeCheckbox = ThemedCheckbox(
        label: String(localized: "Run when a thread gets a new worktree"), target: nil, action: nil)
    private let saveButton = ThemedButton(title: String(localized: "Save"), style: .primary, target: nil, action: nil)

    init(script: ProjectScript?) {
        self.script = script ?? ProjectScript(name: "", command: "")
        isNew = script == nil
        super.init(nibName: nil, bundle: nil)
        title = isNew ? String(localized: "Add Script") : String(localized: "Edit Script")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let heading = NSTextField(labelWithString: title ?? "")
        heading.font = .systemFont(ofSize: 15, weight: .semibold)
        let subtitle = NSTextField(
            wrappingLabelWithString: String(
                localized: "Runs in a terminal of the thread, in its worktree or the project folder. $COINCIDE_PROJECT_ROOT is the project folder and $COINCIDE_WORKTREE_PATH the worktree."))
        subtitle.textColor = .secondaryLabelColor
        subtitle.font = .systemFont(ofSize: 12)

        nameField.stringValue = script.name
        commandField.stringValue = script.command
        for field in [nameField, commandField] { field.delegate = self }

        let icons = NSStackView()
        icons.spacing = 6
        for icon in ProjectScript.Icon.allCases {
            let button = ThemedButton(title: "", style: .secondary, target: self, action: #selector(pickIcon(_:)))
            button.image = Theme.symbol(icon.symbolName, size: 13)
            button.imagePosition = .imageOnly
            button.toolTip = icon.title
            button.setAccessibilityLabel(icon.title)
            button.identifier = NSUserInterfaceItemIdentifier(icon.rawValue)
            button.widthAnchor.constraint(equalToConstant: 34).isActive = true
            iconButtons[icon] = button
            icons.addArrangedSubview(button)
        }
        updateIcons()

        worktreeCheckbox.state = script.runOnWorktreeCreate ? .on : .off

        let cancel = ThemedButton(title: String(localized: "Cancel"), style: .secondary, target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        saveButton.target = self
        saveButton.action = #selector(save)
        saveButton.keyEquivalent = "\r"
        var buttons: [NSView] = []
        if !isNew {
            let delete = ThemedButton(title: String(localized: "Delete"), style: .plain, target: self, action: #selector(delete))
            delete.hasDestructiveAction = true
            buttons.append(delete)
        }
        buttons += [NSView(), cancel, saveButton]
        let buttonRow = NSStackView(views: buttons)
        buttonRow.spacing = 8

        let stack = NSStackView(views: [
            heading, subtitle, label(String(localized: "Name")), nameField, label(String(localized: "Command")), commandField,
            label(String(localized: "Icon")), icons, worktreeCheckbox, buttonRow,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.setCustomSpacing(4, after: heading)
        stack.setCustomSpacing(16, after: subtitle)
        stack.setCustomSpacing(12, after: nameField)
        stack.setCustomSpacing(12, after: commandField)
        stack.setCustomSpacing(14, after: icons)
        stack.setCustomSpacing(20, after: worktreeCheckbox)
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        for view in [subtitle, nameField, commandField, buttonRow] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        }
        stack.widthAnchor.constraint(equalToConstant: 440).isActive = true
        let root = SolidBackgroundView(color: Theme.contentBackground)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
        updateSaveButton()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(isNew ? nameField : commandField)
    }

    private func label(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .secondaryLabelColor
        return label
    }

    func controlTextDidChange(_ notification: Notification) {
        updateSaveButton()
    }

    private func updateSaveButton() {
        saveButton.isEnabled = !trimmed(nameField).isEmpty && !trimmed(commandField).isEmpty
    }

    private func trimmed(_ field: NSTextField) -> String {
        field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func updateIcons() {
        for (icon, button) in iconButtons {
            button.style = icon == script.icon ? .primary : .secondary
            button.setAccessibilityValue(icon == script.icon ? String(localized: "selected") : nil)
        }
    }

    @objc private func pickIcon(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let icon = ProjectScript.Icon(rawValue: raw) else { return }
        script.icon = icon
        updateIcons()
    }

    @objc private func save() {
        guard saveButton.isEnabled else { return }
        script.name = trimmed(nameField)
        script.command = trimmed(commandField)
        script.runOnWorktreeCreate = worktreeCheckbox.state == .on
        onSave?(script)
        dismiss(nil)
    }

    @objc private func delete() {
        onDelete?(script)
        dismiss(nil)
    }

    @objc private func cancel() {
        dismiss(nil)
    }
}
