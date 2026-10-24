import AppKit
import CoincideCore
import Observation
import SwiftUI

/// Settings → Keyboard: every command, its shortcut, condition and source, with
/// recording, conditions, reset and removal written to keybindings.json.
struct KeybindingsSettingsView: View {
    let keybindings: KeybindingsStore
    @State private var query = ""
    @State private var editing: KeybindingEditorTarget?
    @State private var editRevision = KeybindingsConfigRevision()
    @State private var error: String?

    var body: some View {
        let rows = KeybindingsSettingsModel.rows(keybindings.keybindings)
        let groups = KeybindingsSettingsModel.groups(KeybindingsSettingsModel.filter(rows, query: query))
        VStack(alignment: .leading, spacing: 22) {
            SettingsCard {
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                    TextField("Search shortcuts", text: $query).textFieldStyle(.plain).font(.system(size: 13))
                        .accessibilityLabel("Search keyboard shortcuts").accessibilityIdentifier("keybindings-search")
                    Button("Add shortcut") { editRevision = keybindings.revision; editing = .new }
                        .buttonStyle(SettingsActionButtonStyle()).accessibilityIdentifier("keybindings-add")
                }.padding(.vertical, 12)
            }
            if !keybindings.issues.isEmpty {
                SettingsCard {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Some shortcuts need attention", systemImage: "exclamationmark.triangle")
                            .font(.system(size: 13)).foregroundStyle(.orange)
                        ForEach(Array(keybindings.issues.enumerated()), id: \.offset) {
                            Text(verbatim: $0.element.summary).font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 14)
                }.accessibilityIdentifier("keybindings-issues")
            }
            if let error {
                Text(verbatim: error).font(.system(size: 12)).foregroundStyle(.red)
                    .accessibilityIdentifier("keybindings-error")
            }
            if groups.isEmpty {
                Text("No shortcuts match your search.").font(.system(size: 13)).foregroundStyle(.secondary)
            }
            ForEach(groups, id: \.title) { group in
                SettingsCard(title: LocalizedStringKey(group.title == "Threads" ? "Chats" : group.title)) {
                    ForEach(group.rows) { row in
                        if row.id != group.rows.first?.id { SettingsDivider() }
                        KeybindingRowView(row: row, edit: { editRevision = keybindings.revision; editing = .row(row) }, reset: {
                            let expected = keybindings.revision
                            perform { try await reset(row, expectedRevision: expected) }
                        }, remove: {
                            let expected = keybindings.revision
                            perform { try await keybindings.remove(row.rule, expectedRevision: expected) }
                        })
                    }
                }
            }
            SettingsCard(title: "Composer") {
                ForEach(Array(Self.builtIn.enumerated()), id: \.offset) { index, item in
                    if index > 0 { SettingsDivider() }
                    SettingsRow(title: item.0) {
                        Text(verbatim: item.1).font(.system(size: 13, design: .monospaced)).foregroundStyle(.secondary)
                    }
                }
            }
            SettingsCard(title: "Advanced") {
                DisclosureGroup("Shortcut configuration") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("The last matching shortcut rule wins. Your saved configuration is preserved; only commands available in Coincide are shown here.")
                            .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Text(verbatim: keybindings.fileURL.path).font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary).textSelection(.enabled)
                        HStack(spacing: 8) {
                            Button("Open configuration") { keybindings.openFile() }.buttonStyle(SettingsActionButtonStyle())
                            Button("Show in Finder") { keybindings.revealFile() }.buttonStyle(SettingsActionButtonStyle())
                        }
                    }.padding(.top, 12).padding(.bottom, 4)
                }.font(.system(size: 13)).padding(.vertical, 14)
            }
        }
        .sheet(item: $editing) { target in
            let expected = editRevision
            KeybindingEditorSheet(target: target, rows: rows, save: { rule, replacing in
                try await keybindings.save(rule, replacing: replacing, expectedRevision: expected); editing = nil
            }, cancel: { editing = nil })
        }
    }

    static let builtIn: [(LocalizedStringKey, String)] = [
        ("Send", "↩"), ("New line", "⇧↩ / ⌥↩"), ("Alternate send action", "⌘↩"),
        ("Paste as plain text", "⇧⌘V"), ("Close a picker", "⎋"),
    ]

    private func reset(_ row: KeybindingRow, expectedRevision: KeybindingsConfigRevision) async throws {
        guard let rule = row.defaultRule else { return }
        try await keybindings.save(rule, replacing: row.rule, expectedRevision: expectedRevision)
    }
    private func perform(_ work: @escaping @MainActor () async throws -> Void) {
        Task { do { try await work(); error = nil } catch { self.error = error.localizedDescription } }
    }
}

private struct KeybindingRowView: View {
    let row: KeybindingRow
    let edit: () -> Void
    let reset: () -> Void
    let remove: () -> Void
    private var title: String {
        if row.command == .sidebarToggle { return String(localized: "Toggle sidebar") }
        if let number = row.command.threadJumpNumber { return String(localized: "Go to chat \(number)") }
        let label = row.label.components(separatedBy: ": ").last ?? row.label
        return label.replacingOccurrences(of: "Thread", with: "Chat")
    }
    private var subtitle: LocalizedStringKey? {
        if !row.conflicts.isEmpty { return LocalizedStringKey("Also used by " + row.conflicts.joined(separator: ", ")) }
        return row.source == .default ? nil : "Custom shortcut"
    }
    private var details: String {
        row.command.rawValue + (row.when.isEmpty ? "" : "\nCondition: " + row.when)
    }
    var body: some View {
        SettingsRow(title: LocalizedStringKey(title), subtitle: subtitle) {
            HStack(spacing: 8) {
                Button(action: edit) {
                    Text(verbatim: row.shortcut.label).font(.system(size: 13, design: .monospaced))
                }
                .buttonStyle(SettingsActionButtonStyle())
                .help("Edit shortcut").accessibilityLabel(Text("Shortcut \(row.shortcut.accessibilityLabel). Edit"))
                Menu {
                    Button("Edit…", action: edit)
                    if row.canReset { Button("Reset to Default", action: reset) }
                    if row.canRemove { Button("Remove", role: .destructive, action: remove) }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 13)).frame(width: 22, height: 24)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel(Text("Actions for \(title)"))
            }
        }
        .help(details)
        .contextMenu {
            Button("Edit…", action: edit)
            if row.canReset { Button("Reset to Default", action: reset) }
            if row.canRemove { Button("Remove", role: .destructive, action: remove) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("keybinding-row-" + row.command.rawValue)
    }
}

enum KeybindingEditorTarget: Identifiable {
    case new, row(KeybindingRow)
    var id: String { if case .row(let row) = self { row.id } else { "new" } }
}

/// Records a shortcut and edits its condition, with live validation and conflicts.
struct KeybindingEditorSheet: View {
    let target: KeybindingEditorTarget
    let rows: [KeybindingRow]
    let save: (KeybindingRule, KeybindingRule?) async throws -> Void
    let cancel: () -> Void
    @State private var command: KeybindingCommand
    @State private var key: String
    @State private var when: String
    @State private var recorder = ShortcutRecorder()
    @State private var saving = false
    @State private var error: String?

    init(target: KeybindingEditorTarget, rows: [KeybindingRow], save: @escaping (KeybindingRule, KeybindingRule?) async throws -> Void, cancel: @escaping () -> Void) {
        self.target = target; self.rows = rows; self.save = save; self.cancel = cancel
        if case .row(let row) = target {
            _command = State(initialValue: row.command); _key = State(initialValue: row.key); _when = State(initialValue: row.when)
        } else {
            _command = State(initialValue: .commandPaletteToggle); _key = State(initialValue: ""); _when = State(initialValue: "")
        }
    }

    private var existing: KeybindingRow? { if case .row(let row) = target { row } else { nil } }
    private var shortcut: KeybindingShortcut? { KeybindingShortcut(parsing: key) }
    private var whenDraft: KeybindingsSettingsModel.WhenDraft { KeybindingsSettingsModel.parseWhen(when) }
    private var conflicts: [String] {
        let whenText: String = if case .valid(let node, _) = whenDraft { node.expression } else { when }
        return KeybindingsSettingsModel.conflictLabels(rows.filter { $0.command != command || $0.id == existing?.id }, rowID: existing?.id, shortcut: shortcut, when: whenText)
    }
    private var canSave: Bool {
        guard !saving, let shortcut, shortcut.encoded != nil, key.count <= KeybindingShortcut.maxLength else { return false }
        if case .invalid = whenDraft { return false }
        return true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(existing == nil ? "Add Keyboard Shortcut" : "Edit Keyboard Shortcut").font(.title2)
            Form {
                if existing == nil {
                    Picker("Command", selection: $command) {
                        ForEach(KeybindingsSettingsModel.commandOptions, id: \.self) { Text(verbatim: $0.label).tag($0) }
                    }.accessibilityIdentifier("keybinding-editor-command")
                } else {
                    LabeledContent("Command") { Text(verbatim: command.label) }
                }
                LabeledContent("Shortcut") {
                    HStack {
                        Button {
                            if recorder.isRecording { recorder.stop() }
                            else { recorder.start { recorded in if let recorded { key = recorded } } }
                        } label: {
                            Text(verbatim: recorder.isRecording ? String(localized: "Type a shortcut…") : shortcut?.label ?? String(localized: "Record Shortcut"))
                                .frame(minWidth: 140)
                        }
                        .accessibilityIdentifier("keybinding-editor-record")
                        TextField("mod+shift+k", text: $key).font(.callout.monospaced()).frame(width: 160)
                            .accessibilityLabel("Shortcut text").accessibilityIdentifier("keybinding-editor-key")
                    }
                }
                DisclosureGroup("Advanced condition") {
                    TextField("Condition (optional)", text: $when, prompt: Text(verbatim: "!editableFocus"))
                        .font(.system(size: 13, design: .monospaced)).accessibilityIdentifier("keybinding-editor-when")
                    Text("Conditions: \(KeybindingContext.knownIdentifiers.filter { $0 != "true" && $0 != "false" }.joined(separator: ", "))")
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)
            VStack(alignment: .leading, spacing: 4) {
                if !key.isEmpty, shortcut == nil {
                    Text("Join modifiers and one key with +, such as mod+shift+k.").foregroundStyle(.red)
                } else if let shortcut, !shortcut.usesCommand, !shortcut.control, whenDraft == .empty, shortcut.key.count == 1 {
                    Text("Without ⌘ or ⌃ this shortcut also types text. Add a condition such as !editableFocus.").foregroundStyle(.orange)
                }
                switch whenDraft {
                case .invalid(let message): Text(verbatim: message).foregroundStyle(.red)
                case .valid(_, let unknown) where !unknown.isEmpty:
                    Text("Unknown condition variables are always false: \(unknown.joined(separator: ", "))").foregroundStyle(.orange)
                default: EmptyView()
                }
                if !conflicts.isEmpty { Text("Conflicts with \(conflicts.joined(separator: ", ")). The rule saved last wins.").foregroundStyle(.orange) }
                if let error { Text(verbatim: error).foregroundStyle(.red) }
            }.font(.caption).fixedSize(horizontal: false, vertical: true)
            HStack {
                if let existing, let defaultRule = existing.defaultRule, existing.source == .custom {
                    Button("Reset to Default") { key = defaultRule.key; when = defaultRule.when ?? "" }
                }
                Spacer()
                Button("Cancel") { recorder.stop(); cancel() }.keyboardShortcut(.cancelAction)
                Button(saving ? "Saving…" : "Save") {
                    recorder.stop(); saving = true
                    let rule = KeybindingRule(key: key.trimmingCharacters(in: .whitespaces), command: command, when: when)
                    Task {
                        defer { saving = false }
                        do { try await save(rule, existing?.rule) } catch { self.error = error.localizedDescription }
                    }
                }.keyboardShortcut(.defaultAction).disabled(!canSave).accessibilityIdentifier("keybinding-editor-save")
            }
        }
        .padding(22).frame(width: 520)
        .onDisappear { recorder.stop() }
    }
}

/// Captures the next key press in this app for the shortcut recorder.
/// Escape cancels; Return and Delete without modifiers record as keys only with a modifier.
@MainActor @Observable
final class ShortcutRecorder {
    private(set) var isRecording = false
    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private var completion: ((String?) -> Void)?
    @ObservationIgnored private weak var window: NSWindow?

    func start(in window: NSWindow? = NSApp.keyWindow, _ completion: @escaping (String?) -> Void) {
        stop()
        guard let window, window.isKeyWindow else { return }
        self.window = window; self.completion = completion; isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.capture(event) == true }
            return consumed ? nil : event
        }
    }
    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil; isRecording = false; completion = nil; window = nil
    }
    /// Returns true when the event was consumed.
    func capture(_ event: NSEvent) -> Bool {
        guard isRecording, let window, window.isKeyWindow, event.window === window else { return false }
        let flags = event.modifierFlags
        if event.keyCode == 53, flags.intersection([.command, .control, .option, .shift]).isEmpty { completion?(nil); stop(); return true }
        let recorded = Self.record(keyCode: event.keyCode, characters: event.charactersIgnoringModifiers, flags: flags)
        guard let recorded else { return true }
        completion?(recorded); stop(); return true
    }
    static func record(keyCode: UInt16, characters: String?, flags: NSEvent.ModifierFlags) -> String? {
        KeybindingsSettingsModel.recordedKey(keyCode: keyCode, characters: characters, command: flags.contains(.command), control: flags.contains(.control),
                                             option: flags.contains(.option), shift: flags.contains(.shift))
    }
}
