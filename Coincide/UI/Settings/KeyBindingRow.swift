import AppKit
import CoincideKit
import SwiftUI

/// One menu command in the Keyboard pane: its name, what else uses its shortcut, a shortcut recorder, and a menu to
/// reset or remove the shortcut (T3 Code's keybinding row).
struct KeyBindingRow: View {
    let command: KeyCommand
    let shortcut: KeyShortcut?
    let isCustomized: Bool
    /// Other uses of the shortcut that stop it or another command from running.
    let warnings: [String]
    /// Places where the shortcut does something else, such as a focused terminal.
    let notes: [String]
    let isRecording: Bool
    let onRecordingChange: (Bool) -> Void
    let onChange: (KeyShortcut?) -> Void
    let onReset: () -> Void

    var body: some View {
        let fieldHeight = ShortcutRecorderView.height
        let fieldBaseline = ShortcutRecorderView.baselineOffset
        LabeledContent {
            HStack(spacing: 6) {
                if !notes.isEmpty {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                        .help(notes.joined(separator: "\n"))
                        .accessibilityLabel(notes.joined(separator: " "))
                }
                ShortcutRecorder(
                    shortcut: shortcut, commandTitle: command.title, onRecordingChange: onRecordingChange, onChange: onChange
                )
                .frame(width: ShortcutRecorderView.width, height: fieldHeight)
                Menu {
                    Button("Reset to Default", action: onReset)
                        .disabled(!isCustomized)
                    Button("Remove Shortcut") { onChange(nil) }
                        .disabled(shortcut == nil)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .pointerCursor()
                .help(Text("Reset or remove the shortcut"))
                .accessibilityLabel(Text("More options for \(command.title)"))
            }
            // SwiftUI doesn't read an AppKit view's baseline: line the field's text up with the command's name.
            .alignmentGuide(.firstTextBaseline) { d in (d.height - fieldHeight) / 2 + fieldBaseline }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(command.title)
                if isRecording {
                    Text("Press the new shortcut. Delete removes it; Escape cancels.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(warnings, id: \.self) { warning in
                        Label {
                            Text(warning)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    if isCustomized {
                        Text(defaultDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var defaultDescription: String {
        if let shortcut = command.defaultShortcut {
            String(localized: "Default: \(shortcut.displayString)")
        } else {
            String(localized: "No shortcut by default")
        }
    }
}

/// Saved shortcuts Coincide ignores, as T3 Code warns about unreadable entries in keybindings.json.
struct ShortcutIssuesSection: View {
    let issues: [KeyBindings.Issue]
    let onRemove: () -> Void

    var body: some View {
        Section {
            Label {
                Text("Some saved shortcuts can’t be used, so their commands keep their defaults.")
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            ForEach(issues) { issue in
                Text(Self.description(of: issue))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("Show Settings File in Finder") {
                    let url = AppStore.shared.directory.appendingPathComponent("settings.json")
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                Button("Remove Them", action: onRemove)
            }
        }
    }

    static func description(of issue: KeyBindings.Issue) -> String {
        let command = KeyCommand(rawValue: issue.commandID)?.title ?? issue.commandID
        return switch issue.reason {
        case .unknownCommand: String(localized: "“\(issue.commandID)” isn’t a Coincide command.")
        case .unreadable: String(localized: "\(command): “\(issue.value)” isn’t a shortcut.")
        case .needsCommandOrControl: String(localized: "\(command): “\(issue.value)” needs ⌘ or ⌃.")
        }
    }
}
