import AppKit
import CoincideCore
import SwiftUI

struct ClaudeRuntimeSettingsSection: View {
    @Bindable var runtime: ClaudeRuntimeSettingsStore
    @State private var advanced = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsCard(title: "Claude runtime") {
                SettingsRow(title: "Executable", subtitle: "Uses the Claude CLI and its existing sign-in.") {
                    Text(runtime.profile.executable).foregroundStyle(.secondary).textSelection(.enabled)
                        .lineLimit(1).truncationMode(.middle).frame(maxWidth: 300, alignment: .trailing)
                }
                SettingsDivider()
                SettingsRow(title: "Auto-compact") {
                    if let threshold = runtime.profile.autoCompactWindow {
                        Text("\(threshold.formatted()) tokens").foregroundStyle(.secondary)
                    } else { Text("CLI default").foregroundStyle(.secondary) }
                }
                SettingsDivider()
                SettingsRow(title: "Save profile", subtitle: "Applies to future chats. Existing chats keep their profile.") {
                    HStack(spacing: 8) { actions }
                }
                if let message = runtime.errorMessage {
                    SettingsDivider()
                    Text(message).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true).padding(.vertical, 14)
                        .accessibilityIdentifier("claude-runtime-error")
                }
            }
            SettingsCard(title: nil) {
                DisclosureGroup("Advanced", isExpanded: $advanced) {
                    SettingsRow(title: "Executable") { HStack(spacing: 8) { executable; chooseExecutable } }
                    SettingsDivider()
                    SettingsRow(title: "Configuration folder", subtitle: "Leave empty to use the CLI default. Accounts and history are not copied.") {
                        TextField("Default", text: $runtime.configurationDirectory)
                            .textFieldStyle(.roundedBorder).frame(minWidth: 150, maxWidth: 300)
                            .accessibilityIdentifier("claude-runtime-directory")
                    }
                    SettingsDivider()
                    SettingsRow(title: "Auto-compact tokens", subtitle: "100,000–1,000,000, or leave empty for the CLI default.") {
                        TextField("Default", text: $runtime.autoCompactWindowText)
                            .textFieldStyle(.roundedBorder).frame(width: 150)
                            .accessibilityIdentifier("claude-runtime-auto-compact")
                    }
                }.font(.system(size: 13)).padding(.vertical, 14)
            }
        }.disabled(!runtime.acceptsEdits)
    }
    private var executable: some View {
        TextField("Path or command", text: $runtime.executable)
            .textFieldStyle(.roundedBorder).frame(minWidth: 150, maxWidth: 280)
            .accessibilityIdentifier("claude-runtime-executable")
    }
    private var chooseExecutable: some View {
        Button("Choose…") {
            let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false; panel.prompt = String(localized: "Choose")
            if panel.runModal() == .OK, let url = panel.url { runtime.executable = url.path }
        }.buttonStyle(SettingsActionButtonStyle())
            .accessibilityLabel("Choose Claude executable")
            .accessibilityIdentifier("claude-runtime-choose-executable")
    }
    @ViewBuilder private var actions: some View {
        Button(runtime.isApplying ? "Saving…" : "Use Profile") { Task { await runtime.applySelection() } }
            .buttonStyle(SettingsActionButtonStyle())
            .disabled(!runtime.canApply).accessibilityIdentifier("claude-runtime-apply")
        Button("CLI Defaults") { runtime.useCLIDefaults() }
            .buttonStyle(SettingsActionButtonStyle())
            .accessibilityIdentifier("claude-runtime-defaults")
        if !runtime.isLoaded || runtime.errorMessage != nil {
            Button("Reload Profile") { Task { await runtime.load() } }
                .buttonStyle(SettingsActionButtonStyle())
                .accessibilityIdentifier("claude-runtime-reload")
        } else if runtime.hasUnappliedChanges {
            Button("Discard Changes") { runtime.discardEdits() }
                .buttonStyle(SettingsActionButtonStyle())
        }
    }
}
