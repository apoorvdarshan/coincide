import CoincideCore
import CoincideMarkdown
import SwiftUI

struct SettingsView: View {
    @Bindable var store: WorkspaceStore
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("followUpBehavior") private var followUpBehavior = ComposerFollowUpBehavior.queue.rawValue
    @AppStorage("renderMathInMarkdown") private var renderMathInMarkdown = false
    @State private var provider = ProviderKind.codex
    @Environment(KeybindingsStore.self) private var keybindings: KeybindingsStore?
    var body: some View {
        TabView {
            Form {
                Picker("Provider", selection: $provider) { ForEach(ProviderKind.builtIn) { Text($0.name).tag($0) } }
                if provider == .codex && store.codexRuntime.configuration.authenticationMode == .cliDefault {
                    LabeledContent("CLI", value: ProcessChannel.findExecutable(provider.executable)?.path ?? "Not installed")
                    Text("Coincide uses your existing Codex and Claude CLI sign-in and settings on this Mac.").foregroundStyle(.secondary)
                }
                Button(store.isRefreshingModels ? "Refreshing…" : "Refresh Available Models") { Task { await store.refreshModels(provider: provider) } }
                    .disabled(store.isRefreshingModels || (provider == .codex && (store.codexRuntime.isApplying || store.codexAuthentication.isWorking)))
                LabeledContent("Available models", value: "\(store.models(for: provider).count)")
                if provider == .codex {
                    CodexRuntimeSettingsSection(runtime: store.codexRuntime)
                    CodexAuthenticationSection(authentication: store.codexAuthentication, runtime: store.codexRuntime)
                    if store.codexRuntime.configuration.authenticationMode == .cliDefault {
                        CodexAccountSection(account: store.codexAccount, runtimeConfiguration: store.codexRuntime.configuration) { await store.refreshCodexAccount() }
                            .id(store.codexRuntime.configuration)
                    }
                }
                if provider == .claude { ClaudeRuntimeSettingsSection(runtime: store.claudeRuntime) }
            }.formStyle(.grouped).tabItem { Label("Providers", systemImage: "cpu") }
            if let scheduled = store.scheduledTasks() { ScheduledTasksSettingsView(store: scheduled, navigate: { store.selectThread($0) }).tabItem { Label("Scheduled Tasks", systemImage: "calendar.badge.clock") } }
            SourceControlSettingsView(store: store).tabItem { Label("Source Control", systemImage: "arrow.triangle.branch") }
            Form {
                Picker("Appearance", selection: $appearance) { Text("System").tag("system"); Text("Light").tag("light"); Text("Dark").tag("dark") }
                Toggle("Render Math in Messages", isOn: $renderMathInMarkdown)
                    .accessibilityIdentifier("settings-render-math")
                Text("Render complete LaTeX formulas in responses and previews. Code, authored text and copied responses keep their original contents.")
                    .font(.caption).foregroundStyle(.secondary)
                ThreadNotificationSettings(notifications: store.notifications)
                WorkspaceLifecycleSettingsSection(store: store)
                Picker("Messages during a running turn", selection: $followUpBehavior) {
                    ForEach(ComposerFollowUpBehavior.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Text("Queue waits for the next turn. Steer sends into a supported running turn with that turn's settings. Command-Return uses the alternate action; unavailable steering keeps the message queued.")
                    .font(.caption).foregroundStyle(.secondary)
                TranscriptSettings()
                Picker("Group projects", selection: Binding(get: { store.projectGroupingMode }, set: { store.setProjectGroupingMode($0) })) {
                    ForEach(ProjectGroupingMode.allCases) { Text($0.title).tag($0) }
                }
                Text("Group checkouts by repository, by repository and folder, or show them separately. Existing conversations keep their workspaces.")
                    .font(.caption).foregroundStyle(.secondary)
                ExternalEditorSettings(store: store)
                MarkdownSettingsSection()
                TerminalSettingsSection()
                DesktopShellSettings(shell: .shared)
                Link("Source Code", destination: URL(string: "https://github.com/apoorvdarshan/coincide")!)
                Link("T3 Code", destination: URL(string: "https://github.com/pingdotgg/t3code")!)
                Text("Coincide is an independent Swift port. T3 Code source is copyright © 2026 T3 Tools Inc., distributed under the MIT license.").font(.caption).foregroundStyle(.secondary)
            }.formStyle(.grouped).tabItem { Label("General", systemImage: "gear") }
            if let keybindings { KeybindingsSettingsView(keybindings: keybindings).tabItem { Label("Keyboard", systemImage: "keyboard") } }
        }.padding().frame(width: 650, height: 520)
            .task(id: provider) {
                if provider == .codex, store.codexRuntime.configuration.authenticationMode == .cliDefault { await store.refreshCodexAccount() }
            }
    }
}
