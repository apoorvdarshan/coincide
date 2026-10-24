import CoincideCore
import CoincideMarkdown
import SwiftUI

enum SettingsPage: String, CaseIterable, Identifiable {
    case general, appearance, notifications, providers, models, conversations, sourceControl, terminal, keyboard, about
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .notifications: "Notifications"
        case .providers: "Agents"
        case .models: "Models"
        case .conversations: "Conversations"
        case .sourceControl: "Source control"
        case .terminal: "Terminal"
        case .keyboard: "Keyboard"
        case .about: "About Coincide"
        }
    }
    var icon: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "sun.max"
        case .notifications: "bell"
        case .providers: "cpu"
        case .models: "list.bullet"
        case .conversations: "bubble.left.and.bubble.right"
        case .sourceControl: "arrow.triangle.branch"
        case .terminal: "terminal"
        case .keyboard: "keyboard"
        case .about: "info.circle"
        }
    }
    var group: String { [.general, .appearance, .notifications, .about].contains(self) ? "Personal" : "Coding" }
}

struct SettingsView: View {
    @Bindable var store: WorkspaceStore
    var embedded = false
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("followUpBehavior") private var followUpBehavior = ComposerFollowUpBehavior.queue.rawValue
    @AppStorage("renderMathInMarkdown") private var renderMathInMarkdown = false
    @State private var provider = ProviderKind.codex
    @State private var search = ""
    @Environment(KeybindingsStore.self) private var keybindings: KeybindingsStore?
    private var selection: Binding<SettingsPage?> {
        Binding(get: { store.settingsPage }, set: { if let value = $0 { store.settingsPage = value } })
    }
    var body: some View {
        NavigationSplitView {
            List(selection: selection) {
                ForEach(["Personal", "Coding"], id: \.self) { group in
                    Section(group) {
                        ForEach(SettingsPage.allCases.filter { $0.group == group && (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search)) }) { page in
                            Label(page.title, systemImage: page.icon).tag(page)
                                .padding(.vertical, 5).accessibilityIdentifier("settings-page-" + page.rawValue)
                        }
                    }
                }
            }
            .listStyle(.sidebar).scrollContentBackground(.hidden).background(ChatChrome.sidebar)
            .safeAreaInset(edge: .top) {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        Text("Settings").font(.system(size: 17, weight: .medium))
                        Spacer()
                        if embedded {
                            Button { store.showingSettings = false } label: { Image(systemName: "xmark") }
                                .buttonStyle(.plain).help("Back to chat").accessibilityLabel("Back to chat")
                        }
                    }
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Search settings", text: $search).textFieldStyle(.plain)
                    }.padding(9).background(Color.primary.opacity(0.05), in: Capsule())
                }.padding(18).background(ChatChrome.sidebar)
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 300)
        } detail: {
            VStack(alignment: .leading, spacing: 8) {
                Text(store.settingsPage.title).font(.system(size: 25, weight: .medium))
                    .padding(.horizontal, 40).padding(.top, 28)
                page.frame(maxWidth: 840, maxHeight: .infinity, alignment: .topLeading)
            }.frame(maxWidth: 840, maxHeight: .infinity, alignment: .topLeading)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(ChatChrome.canvas)
        }
        .frame(minWidth: 740, idealWidth: 1080, minHeight: 560, idealHeight: 760)
        .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
    }
    @ViewBuilder private var page: some View {
        switch store.settingsPage {
        case .general:
            settingsForm { DesktopShellSettings(shell: .shared) }
        case .appearance:
            settingsForm {
                Section("Theme") {
                    Picker("Appearance", selection: $appearance) {
                        Text("System").tag("system"); Text("Light").tag("light"); Text("Dark").tag("dark")
                    }.pickerStyle(.menu)
                }
                Section("Messages") {
                    Toggle("Render math in messages", isOn: $renderMathInMarkdown)
                        .accessibilityIdentifier("settings-render-math")
                    MarkdownSettingsSection()
                    TranscriptSettings()
                }
            }
        case .notifications:
            settingsForm { ThreadNotificationSettings(notifications: store.notifications) }
        case .providers:
            settingsForm {
                Section {
                    HStack(spacing: 12) {
                        ForEach(ProviderKind.builtIn) { agent in
                            Button { provider = agent } label: {
                                HStack(spacing: 10) {
                                    ProviderLogo(provider: agent, size: 26)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(agent.name).font(.headline)
                                        Text(!store.models(for: agent).isEmpty ? "Models available" : store.pickerProviderAvailable(agent) ? "CLI found" : "Set up CLI")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                    if provider == agent { Image(systemName: "checkmark") }
                                }.padding(12).frame(maxWidth: .infinity)
                                    .background(Color.primary.opacity(provider == agent ? 0.08 : 0.025), in: RoundedRectangle(cornerRadius: 12))
                            }.buttonStyle(.plain).accessibilityLabel(agent.name + " agent settings")
                        }
                    }
                    LabeledContent("Installed CLI", value: ProcessChannel.findExecutable(provider.executable)?.path ?? "Not found")
                    Text("Coincide runs the official CLI on your Mac and uses its existing sign-in. No separate API key is needed for an authenticated CLI account.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("Open agent setup") { DesktopShell.shared.showWelcome() }
                    Button(store.isRefreshingModels ? "Refreshing…" : "Refresh models") {
                        Task { await store.refreshModels(provider: provider) }
                    }.disabled(store.isRefreshingModels)
                    LabeledContent("Loaded models", value: "\(store.models(for: provider).count)")
                }
                if provider == .codex {
                    CodexRuntimeSettingsSection(runtime: store.codexRuntime)
                    if store.codexRuntime.configuration.authenticationMode == .cliDefault {
                        CodexAccountSection(account: store.codexAccount, runtimeConfiguration: store.codexRuntime.configuration) { await store.refreshCodexAccount() }
                            .id(store.codexRuntime.configuration)
                    } else {
                        Text("This saved runtime uses an app-managed account. New app-managed sign-in is deferred; its existing configuration is unchanged.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else { ClaudeRuntimeSettingsSection(runtime: store.claudeRuntime) }
            }
        case .models:
            settingsForm { ModelPickerSettings(store: store) }
        case .conversations:
            settingsForm {
                Section("Follow-ups") {
                    Picker("Messages during a running turn", selection: $followUpBehavior) {
                        ForEach(ComposerFollowUpBehavior.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                }
                Section("Projects") {
                    Picker("Group projects", selection: Binding(get: { store.projectGroupingMode }, set: { store.setProjectGroupingMode($0) })) {
                        ForEach(ProjectGroupingMode.allCases) { Text($0.title).tag($0) }
                    }
                }
            }
        case .sourceControl:
            SourceControlSettingsView(store: store)
        case .terminal:
            settingsForm { TerminalSettingsSection(); ExternalEditorSettings(store: store) }
        case .keyboard:
            if let keybindings { KeybindingsSettingsView(keybindings: keybindings) }
            else { ContentUnavailableView("Keyboard settings unavailable", systemImage: "keyboard") }
        case .about:
            settingsForm {
                Section {
                    LabeledContent("Coincide", value: DesktopShellSettings.versionText())
                    Text("A native Mac workspace for Codex and Claude.").foregroundStyle(.secondary)
                    Link("Source code", destination: URL(string: "https://github.com/apoorvdarshan/coincide")!)
                    Button("Open-source licenses") { DesktopShell.shared.showLicenses() }
                    Link("T3 Code credits", destination: URL(string: "https://github.com/pingdotgg/t3code")!)
                }
            }
        }
    }
    private func settingsForm<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        Form(content: content).formStyle(.grouped).scrollContentBackground(.hidden)
    }
}
