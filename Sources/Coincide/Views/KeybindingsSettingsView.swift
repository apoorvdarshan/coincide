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
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField("Search commands, shortcuts or conditions", text: $query).textFieldStyle(.plain)
                    .accessibilityLabel("Search keyboard shortcuts").accessibilityIdentifier("keybindings-search")
                Button { editRevision = keybindings.revision; editing = .new } label: { Label("Add Shortcut", systemImage: "plus") }
                    .accessibilityIdentifier("keybindings-add")
                Button { keybindings.openFile() } label: { Image(systemName: "curlybraces") }
                    .help("Open keybindings.json").accessibilityLabel("Open keybindings.json")
                Button { keybindings.revealFile() } label: { Image(systemName: "folder") }
                    .help("Show keybindings.json in Finder").accessibilityLabel("Show keybindings.json in Finder")
            }.padding(8).coincideSurface(cornerRadius: 8)
            if !keybindings.issues.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Label("keybindings.json has issues. Valid rules and defaults still apply.", systemImage: "exclamationmark.triangle")
                        .font(.caption.weight(.semibold)).foregroundStyle(.orange)
                    ForEach(Array(keybindings.issues.enumerated()), id: \.offset) { Text(verbatim: $0.element.summary).font(.caption).foregroundStyle(.secondary) }
                }.accessibilityIdentifier("keybindings-issues")
            }
            if let error { Text(verbatim: error).font(.caption).foregroundStyle(.red).accessibilityIdentifier("keybindings-error") }
            List {
                if groups.isEmpty { Text("No keyboard shortcuts match your search.").foregroundStyle(.secondary) }
                ForEach(groups, id: \.title) { group in
                    Section(group.title) {
                        ForEach(group.rows) { row in
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
                Section("Composer (built in)") {
                    ForEach(Array(Self.builtIn.enumerated()), id: \.offset) { _, item in
                        LabeledContent { Text(verbatim: item.1).font(.callout.monospaced()).foregroundStyle(.secondary) } label: { Text(item.0) }
                    }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            Text(verbatim: keybindings.fileURL.path).font(.caption2.monospaced()).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                .textSelection(.enabled)
            Text("The last rule whose shortcut and condition match wins. Defaults include !terminalFocus where the terminal keeps its keys. Edit keybindings.json directly for the full syntax.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(4)
        .sheet(item: $editing) { target in
            let expected = editRevision
            KeybindingEditorSheet(target: target, rows: rows, save: { rule, replacing in
                try await keybindings.save(rule, replacing: replacing, expectedRevision: expected); editing = nil
            }, cancel: { editing = nil })
        }
    }

    static let builtIn: [(LocalizedStringKey, String)] = [
        ("Send", "↩"), ("New line", "⇧↩ / ⌥↩"), ("Opposite Queue or Steer action", "⌘↩"),
        ("Stash prompt", "⌘S"), ("Paste as plain text", "⇧⌘V"), ("Close a picker", "⎋"),
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
    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: row.label).lineLimit(1)
                HStack(spacing: 6) {
                    Text(verbatim: row.command.rawValue).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                    if !row.when.isEmpty { Text(verbatim: "when " + row.when).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1) }
                }
                if row.command.availability == .unavailable || row.command.availability == .project || row.command.availability == .reserved {
                    Text(Self.availabilityNote(row.command.availability)).font(.caption2).foregroundStyle(.secondary)
                }
                if !row.conflicts.isEmpty {
                    Label("Also used by \(row.conflicts.joined(separator: ", "))", systemImage: "exclamationmark.triangle")
                        .font(.caption2).foregroundStyle(.orange).lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            if row.source != .default {
                Text(verbatim: row.source.rawValue).font(.caption2).foregroundStyle(.secondary)
                    .padding(.horizontal, 5).padding(.vertical, 1).background(Color.accentColor.opacity(0.12), in: Capsule())
            }
            Button(action: edit) {
                Text(verbatim: row.shortcut.label).font(.callout.monospaced()).padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 5))
            }.buttonStyle(.plain).help("Edit shortcut").accessibilityLabel(Text("Shortcut \(row.shortcut.accessibilityLabel). Edit"))
            Menu {
                Button("Edit…", action: edit)
                if row.canReset { Button("Reset to Default", action: reset) }
                if row.canRemove { Button("Remove", role: .destructive, action: remove) }
            } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel(Text("Actions for \(row.label)"))
        }
        .contextMenu {
            Button("Edit…", action: edit)
            if row.canReset { Button("Reset to Default", action: reset) }
            if row.canRemove { Button("Remove", role: .destructive, action: remove) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("keybinding-row-" + row.command.rawValue)
    }
    static func availabilityNote(_ availability: KeybindingCommandAvailability) -> LocalizedStringKey {
        switch availability {
        case .reserved: "Reserved for the terminal; Coincide does not run this shortcut yet."
        case .project: "Runs a registered action in the current main window. The original thread and checkout must still match."
        default: "Not available in Coincide. The rule is kept for T3 Code compatibility."
        }
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
                TextField("Condition (optional)", text: $when, prompt: Text(verbatim: "!terminalFocus"))
                    .font(.callout.monospaced()).accessibilityIdentifier("keybinding-editor-when")
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
                Text("Conditions: \(KeybindingContext.knownIdentifiers.filter { $0 != "true" && $0 != "false" }.joined(separator: ", "))")
                    .foregroundStyle(.secondary)
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
