import AppKit
import CoincideCore
import SwiftUI

/// Add or edit one app-owned action. Saving a setup or settle role releases it from any other action,
/// as in T3; the change never writes the repository's t3.json.
struct ProjectActionEditorSheet: View {
    let settings: ProjectSettingsStore
    let project: WorkspaceProject
    let actionID: String?
    let close: () -> Void
    @State private var input: ProjectActionInput
    @State private var saving = false
    @State private var error: String?
    @State private var confirmDelete = false
    init(settings: ProjectSettingsStore, project: WorkspaceProject, actionID: String? = nil, initial: ProjectActionInput = .init(), close: @escaping () -> Void) {
        self.settings = settings; self.project = project; self.actionID = actionID; self.close = close
        let existing = actionID.flatMap { id in settings.document(for: project).actions?.first { $0.id == id } }
        _input = State(initialValue: existing.map(ProjectActionInput.init(action:)) ?? initial)
    }
    private var actions: [ProjectAction] { settings.document(for: project).actions ?? [] }
    private func holder(_ role: ProjectScriptRole) -> ProjectAction? {
        actions.first { $0.id != actionID && (role == .setup ? $0.runOnWorktreeCreate : $0.runOnSettle) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(actionID == nil ? "Add Action" : "Edit Action").font(.title2)
            Text("Actions are project commands you can run from the toolbar or with a shortcut. They are saved in Coincide, not in t3.json.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Form {
                HStack(spacing: 8) {
                    Menu {
                        Picker("Icon", selection: $input.icon) {
                            ForEach(ProjectScriptIcon.allCases, id: \.self) { icon in Label(icon.title, systemImage: icon.systemImage).tag(icon) }
                        }.pickerStyle(.inline).labelsHidden()
                    } label: { Image(systemName: input.icon.systemImage) }
                        .menuStyle(.borderlessButton).fixedSize().help("Choose icon").accessibilityLabel("Choose icon")
                        .accessibilityValue(input.icon.title).accessibilityIdentifier("project-action-icon")
                    TextField("Name", text: $input.name, prompt: Text("Test")).accessibilityIdentifier("project-action-name")
                }
                LabeledContent("Shortcut") {
                    ShortcutRecorder(shortcut: $input.shortcut).frame(width: 160, height: 22)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Command")
                    TextEditor(text: $input.command).font(.body.monospaced()).frame(minHeight: 64, maxHeight: 120)
                        .scrollContentBackground(.hidden).padding(4)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.12)))
                        .accessibilityLabel("Command").accessibilityIdentifier("project-action-command")
                }
                TextField("Preview URL", text: $input.previewURL, prompt: Text("http://localhost:5173"))
                    .accessibilityIdentifier("project-action-preview-url")
                Toggle("Run automatically on worktree creation", isOn: $input.runOnWorktreeCreate)
                    .accessibilityIdentifier("project-action-setup")
                if input.runOnWorktreeCreate, let holder = holder(.setup) { roleNote(holder, role: .setup) }
                Toggle("Wait for it to finish before the agent starts", isOn: $input.waitForSetup)
                    .disabled(!input.runOnWorktreeCreate)
                Toggle("Run in the thread’s worktree when the thread settles", isOn: $input.runOnSettle)
                    .accessibilityIdentifier("project-action-settle")
                if input.runOnSettle, let holder = holder(.settle) { roleNote(holder, role: .settle) }
                Toggle("Open preview automatically when this action runs", isOn: $input.autoOpenPreview)
                    .disabled(input.previewURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.formStyle(.grouped).scrollDisabled(true).fixedSize(horizontal: false, vertical: true)
            Text("Setup and settle roles still ask you to review the exact command before Coincide runs it.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error {
                Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("project-action-error")
            }
            HStack {
                if actionID != nil {
                    Button("Delete…", role: .destructive) { confirmDelete = true }.disabled(saving)
                        .accessibilityIdentifier("project-action-delete")
                }
                Spacer()
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                Button(saving ? "Saving…" : actionID == nil ? "Save Action" : "Save Changes") { save() }
                    .keyboardShortcut(.defaultAction).disabled(saving).coincidePrimaryAction()
                    .accessibilityIdentifier("project-action-save")
            }
        }
        .padding(24).frame(width: 520)
        .interactiveDismissDisabled(saving)
        .confirmationDialog("Delete action “\(input.name)”?", isPresented: $confirmDelete) {
            Button("Delete Action", role: .destructive) { delete() }
            Button("Cancel", role: .cancel) { }
        } message: { Text("This action cannot be undone. A setup review that is already waiting keeps its exact command but can no longer start.") }
    }
    private func roleNote(_ holder: ProjectAction, role: ProjectScriptRole) -> some View {
        Text(role == .setup ? "Moves the setup role from “\(holder.name)”." : "Moves the settle role from “\(holder.name)”.")
            .font(.caption).foregroundStyle(.secondary)
    }
    private func save() {
        guard !saving else { return }
        let value = input, id = actionID
        do { _ = try ProjectAction(id: id ?? "validation", input: value) } catch { self.error = error.localizedDescription; return }
        saving = true; error = nil
        Task {
            defer { saving = false }
            do {
                try await settings.update(project) { document in
                    let current = document.actions ?? []
                    document.actions = try id.map { try ProjectActions.updating($0, with: value, in: current) } ?? ProjectActions.adding(value, to: current)
                }
                close()
            } catch { self.error = error.localizedDescription }
        }
    }
    private func delete() {
        guard let id = actionID, !saving else { return }
        saving = true; error = nil
        Task {
            defer { saving = false }
            do {
                try await settings.update(project) { document in document.actions = try ProjectActions.deleting(id, from: document.actions ?? []) }
                close()
            } catch { self.error = error.localizedDescription }
        }
    }
}

/// Records one shortcut from a key press. Delete or Backspace clears it; Tab moves focus as usual.
struct ShortcutRecorder: NSViewRepresentable {
    @Binding var shortcut: ProjectActionShortcut?
    func makeNSView(context: Context) -> RecorderField {
        let field = RecorderField(); field.onChange = { shortcut = $0 }; field.shortcut = shortcut; return field
    }
    func updateNSView(_ field: RecorderField, context: Context) {
        field.onChange = { shortcut = $0 }; field.shortcut = shortcut
    }
    final class RecorderField: NSButton {
        var onChange: ((ProjectActionShortcut?) -> Void)?
        var shortcut: ProjectActionShortcut? { didSet { refresh() } }
        private var recording = false { didSet { refresh() } }
        private var message: String?
        convenience init() {
            self.init(frame: .zero)
            bezelStyle = .push; setButtonType(.momentaryPushIn); target = self; action = #selector(toggle)
            setAccessibilityLabel(String(localized: "Shortcut")); setAccessibilityIdentifier("project-action-shortcut"); refresh()
        }
        override var acceptsFirstResponder: Bool { true }
        @objc private func toggle() { recording.toggle(); message = nil; if recording { window?.makeFirstResponder(self) } }
        override func resignFirstResponder() -> Bool { recording = false; return super.resignFirstResponder() }
        override func performKeyEquivalent(with event: NSEvent) -> Bool { recording ? record(event) : super.performKeyEquivalent(with: event) }
        override func keyDown(with event: NSEvent) { if !recording || !record(event) { super.keyDown(with: event) } }
        private func record(_ event: NSEvent) -> Bool {
            if event.keyCode == 48 { recording = false; return false }
            if event.keyCode == 51 || event.keyCode == 117 { shortcut = nil; onChange?(nil); recording = false; return true }
            if event.keyCode == 53 { recording = false; return true }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard let key = event.charactersIgnoringModifiers?.lowercased(), !key.isEmpty else { return true }
            do {
                let value = try ProjectActionShortcut(key: key, command: flags.contains(.command), shift: flags.contains(.shift),
                                                      option: flags.contains(.option), control: flags.contains(.control))
                shortcut = value; onChange?(value); recording = false
            } catch { message = error.localizedDescription; refresh(); NSSound.beep() }
            return true
        }
        private func refresh() {
            title = recording ? String(localized: "Press shortcut…") : shortcut?.displayLabel ?? String(localized: "Record Shortcut")
            toolTip = message ?? String(localized: "Click, then press a key with Command or Control. Delete clears it.")
            setAccessibilityValue(shortcut?.displayLabel ?? String(localized: "None"))
        }
    }
}
