import CoincideCore
import CoincideMarkdown
import SwiftUI

struct SettingsView: View {
    @Bindable var store: WorkspaceStore
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("followUpBehavior") private var followUpBehavior = ComposerFollowUpBehavior.queue.rawValue
    @AppStorage("renderMathInMarkdown") private var renderMathInMarkdown = false
    @State private var provider = ProviderKind.codex
    @State private var editingAgent: ACPAgentConfiguration?
    var body: some View {
        TabView {
            Form {
                Picker("Provider", selection: $provider) { ForEach(ProviderKind.builtIn) { Text($0.name).tag($0) } }
                if provider == .antigravity {
                    AntigravitySettingsSection(account: store.antigravityAccount, installation: store.antigravityInstallation)
                } else {
                if provider != .claude && (provider != .codex || store.codexRuntime.configuration.authenticationMode == .cliDefault) {
                    LabeledContent("CLI", value: ProcessChannel.findExecutable(provider.executable)?.path ?? "Not installed")
                    Text("Coincide uses each provider’s existing CLI sign-in and settings on this Mac.").foregroundStyle(.secondary)
                }
                Button(store.isRefreshingModels ? "Refreshing…" : "Refresh Available Models") { Task { await store.refreshModels(provider: provider) } }
                    .disabled(store.isRefreshingModels || (provider == .codex && (store.codexRuntime.isApplying || store.codexAuthentication.isWorking)) || ((provider == .opencode || provider == .pi || provider == .muse) && store.selectedThread?.provider != provider))
                if provider == .opencode {
                    Text("Choose OpenCode in a new conversation, select the installed server generation, and refresh the models and agents available in that workspace.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if provider == .pi {
                    Text("Requires Pi 0.80.5 or newer. Choose Pi in a conversation, then refresh its workspace models. Pi uses its existing sign-in and app-provided tool approval prompts; it is not an OS sandbox.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if provider == .muse {
                    Text("Choose Muse in a conversation before refreshing its models. Muse uses its existing CLI sign-in. A model list does not verify login or access to a model.")
                        .font(.caption).foregroundStyle(.secondary)
                }
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
                }
                Section("ACP Agents") {
                    ForEach(store.snapshot.acpAgents) { agent in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(agent.name)
                                    Text(ProcessChannel.findExecutable(agent.executable)?.path ?? "Executable unavailable")
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                Button("Edit") { editingAgent = agent }
                                Button("Remove", role: .destructive) { store.removeACPAgent(agent.id) }
                            }
                            ACPConnectionSection(agent: agent, connections: store.acpConnections) {
                                await store.refreshACPConnection(agent: agent)
                            }
                        }
                    }
                    HStack {
                        Button("Add Cursor…") { editingAgent = ACPIntegration.cursor.configuration() }
                        Button("Add GitHub Copilot…") { editingAgent = ACPIntegration.copilot.configuration() }
                        Button("Add Grok…") { editingAgent = ACPIntegration.grok.configuration() }
                    }
                    HStack {
                        Button("Add Agent…") { editingAgent = .init(name: "", executable: "") }
                        Button("Add OpenCode…") { editingAgent = .init(name: "OpenCode", executable: "opencode", arguments: ["acp"]) }
                    }
                    Text("Connect an installed ACP agent using its existing sign-in. The agent enforces its own sandbox; Coincide displays its permission requests. Existing conversations retain the invocation they started with.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped).tabItem { Label("Providers", systemImage: "cpu") }
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
                Picker("Group projects", selection: Binding(get: { store.projectGroupingMode }, set: { store.setProjectGroupingMode($0) })) {
                    ForEach(ProjectGroupingMode.allCases) { Text($0.title).tag($0) }
                }
                Text("Group checkouts by repository, by repository and folder, or show them separately. Existing conversations keep their workspaces.")
                    .font(.caption).foregroundStyle(.secondary)
                ExternalEditorSettings(store: store)
                MarkdownSettingsSection()
                TerminalSettingsSection()
                LabeledContent("Version", value: "0.1.0 (development)")
                Link("Source Code", destination: URL(string: "https://github.com/apoorvdarshan/coincide")!)
                Link("T3 Code", destination: URL(string: "https://github.com/pingdotgg/t3code")!)
                Text("Coincide is an independent Swift port. T3 Code source is copyright © 2026 T3 Tools Inc., distributed under the MIT license.").font(.caption).foregroundStyle(.secondary)
            }.formStyle(.grouped).tabItem { Label("General", systemImage: "gear") }
        }.padding().frame(width: 650, height: 520)
            .task(id: provider) {
                if provider == .codex, store.codexRuntime.configuration.authenticationMode == .cliDefault { await store.refreshCodexAccount() }
            }
            .sheet(item: $editingAgent) { agent in ACPAgentEditor(agent: agent, save: { try await store.saveACPAgent($0); editingAgent = nil }, cancel: { editingAgent = nil }) }
    }
}

private struct ACPAgentEditor: View {
    let agent: ACPAgentConfiguration
    let save: (ACPAgentConfiguration) async throws -> Void
    let cancel: () -> Void
    @State private var name: String
    @State private var executable: String
    @State private var arguments: String
    @State private var experimentalV2: Bool
    @State private var integration: ACPIntegration?
    @State private var saving = false
    @State private var error: String?
    init(agent: ACPAgentConfiguration, save: @escaping (ACPAgentConfiguration) async throws -> Void, cancel: @escaping () -> Void) {
        self.agent = agent; self.save = save; self.cancel = cancel
        _name = State(initialValue: agent.name); _executable = State(initialValue: agent.executable)
        _arguments = State(initialValue: agent.arguments.joined(separator: "\n"))
        _experimentalV2 = State(initialValue: agent.experimentalV2 == true)
        _integration = State(initialValue: agent.integration)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("ACP Agent").font(.title2)
            Form {
                Picker("Integration", selection: $integration) {
                    Text("Custom ACP").tag(Optional<ACPIntegration>.none)
                    ForEach(ACPIntegration.allCases) { Text($0.name).tag(Optional($0)) }
                }
                TextField("Name", text: $name)
                TextField("Executable", text: $executable)
                LabeledContent("Arguments") {
                    TextEditor(text: $arguments).font(.system(.body, design: .monospaced)).frame(height: 90)
                        .accessibilityLabel("Arguments, one per line")
                        .disabled(integration != nil)
                }
                Toggle("Use ACP v2 (experimental)", isOn: $experimentalV2)
            }
            if let integration {
                Text("This profile uses the documented stdio arguments. An absolute executable path ending in \(integration.executable) is supported. Choose Custom ACP for other arguments.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                ACPIntegrationGuidance(integration: integration)
            } else {
                Text("Put each argument on its own line. Spaces are passed literally. Use the agent’s own sign-in for credentials.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer(); Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button(saving ? "Saving…" : "Save Agent") {
                    var updated = agent; updated.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    updated.executable = executable.trimmingCharacters(in: .whitespacesAndNewlines)
                    updated.arguments = arguments.isEmpty ? [] : arguments.components(separatedBy: "\n")
                    updated.experimentalV2 = experimentalV2 ? true : nil
                    updated.integration = integration
                    saving = true
                    Task {
                        defer { saving = false }
                        do { try updated.validate(); try await save(updated) } catch { self.error = error.localizedDescription }
                    }
                }.keyboardShortcut(.defaultAction).disabled(saving || name.isEmpty || executable.isEmpty)
            }
        }.padding(24).frame(width: 500)
            .onChange(of: integration) { _, selected in
                guard let selected else { return }
                arguments = selected.arguments.joined(separator: "\n")
                if URL(fileURLWithPath: executable).lastPathComponent != selected.executable {
                    executable = selected.executable
                }
                if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { name = selected.name }
            }
    }
}
