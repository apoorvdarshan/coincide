import AppKit
import CoincideCore
import SwiftUI

struct ClaudeRuntimeSettingsSection: View {
    @Bindable var runtime: ClaudeRuntimeSettingsStore
    var body: some View {
        Section("Claude Runtime") {
            VStack(alignment: .leading, spacing: 12) {
                Text("New conversations use this profile; existing conversations keep their captured runtime. Choosing a profile does not sign in or copy CLI accounts, settings, or history.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                ViewThatFits(in: .horizontal) {
                    HStack { executable; chooseExecutable }
                    VStack(alignment: .leading, spacing: 8) { executable; chooseExecutable }
                }
                TextField("Configuration folder (optional absolute path)", text: $runtime.configurationDirectory)
                    .accessibilityIdentifier("claude-runtime-directory")
                Text("Leave the folder empty to inherit CLAUDE_CONFIG_DIR or the native CLI home. Selecting a folder does not migrate accounts or history.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                TextField("Auto-compact tokens (optional)", text: $runtime.autoCompactWindowText)
                    .accessibilityIdentifier("claude-runtime-auto-compact")
                Text("Choose 100,000 to 1,000,000 tokens, or leave empty for the CLI default. Coincide confirms the merged setting before sending. Native model policies may affect when compaction occurs.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("Saved executable: \(runtime.profile.executable)")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if let threshold = runtime.profile.autoCompactWindow {
                    Text("Requested auto-compact setting: \(threshold.formatted()) tokens")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Auto-compact: CLI default").font(.caption).foregroundStyle(.secondary)
                }
                if let message = runtime.errorMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("claude-runtime-error")
                }
                ViewThatFits(in: .horizontal) {
                    HStack { actions }
                    VStack(alignment: .leading, spacing: 8) { actions }
                }
            }.disabled(!runtime.acceptsEdits)
        }
    }
    private var executable: some View {
        TextField("Executable name or absolute path", text: $runtime.executable)
            .accessibilityIdentifier("claude-runtime-executable")
    }
    private var chooseExecutable: some View {
        Button("Choose Executable…") {
            let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false; panel.prompt = String(localized: "Choose")
            if panel.runModal() == .OK, let url = panel.url { runtime.executable = url.path }
        }.accessibilityIdentifier("claude-runtime-choose-executable")
    }
    @ViewBuilder private var actions: some View {
        Button(runtime.isApplying ? "Saving Profile…" : "Use Profile") { Task { await runtime.applySelection() } }
            .disabled(!runtime.canApply).accessibilityIdentifier("claude-runtime-apply")
        Button("CLI Defaults") { runtime.useCLIDefaults() }
            .accessibilityIdentifier("claude-runtime-defaults")
        if !runtime.isLoaded || runtime.errorMessage != nil {
            Button("Reload Saved Profile") { Task { await runtime.load() } }
                .accessibilityIdentifier("claude-runtime-reload")
        } else if runtime.hasUnappliedChanges {
            Button("Discard Changes") { runtime.discardEdits() }
        }
    }
}
