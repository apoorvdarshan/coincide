import CoincideCore
import CoincideMarkdown
import SwiftUI

enum SettingsPage: String, CaseIterable, Identifiable {
    case general, appearance, notifications, providers, models, conversations, keyboard, about
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .notifications: "Notifications"
        case .providers: "Agents"
        case .models: "Models"
        case .conversations: "Conversations"
        case .keyboard: "Keyboard shortcuts"
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
        case .keyboard: "keyboard"
        case .about: "info.circle"
        }
    }
    var searchKeywords: [String] {
        switch self {
        case .general:
            ["quit shortcut", "confirm quitting", "keep Mac awake", "sleep", "conversation banners", "command-line tool", "Terminal", "coincide command", "install"]
        case .appearance:
            ["theme", "system", "light", "dark", "messages", "render math", "LaTeX", "word wrap", "code", "tables", "timestamps", "collapse finished work", "tool calls", "reasoning"]
        case .notifications:
            ["conversation activity", "background", "sounds", "permission", "finished chats", "needs input"]
        case .providers:
            ["Codex", "Claude", "CLI", "sign in", "authentication", "account", "email", "plan", "usage", "limits", "runtime", "executable", "home", "installation", "profile", "configuration folder", "auto-compact", "login shell environment"]
        case .models:
            ["Codex", "Claude", "composer", "model picker", "available models", "hidden models", "show all", "refresh"]
        case .conversations:
            ["chats", "history", "follow-ups", "running turn", "queue", "guidance", "saved conversations", "archived", "import", "Codex", "Claude"]
        case .keyboard:
            ["keybindings", "shortcuts", "keys", "commands", "composer", "send", "new line", "paste", "reset", "configuration"]
        case .about:
            ["version", "build", "source code", "GitHub", "open-source", "licenses"]
        }
    }
}

struct SettingsView: View {
    @Bindable var store: WorkspaceStore
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("followUpBehavior") private var followUpBehavior = ComposerFollowUpBehavior.queue.rawValue
    @AppStorage(MarkdownPreferences.renderMathKey) private var renderMathInMarkdown = false
    @AppStorage(MarkdownPreferences.wordWrapKey) private var wordWrap = true
    @State private var provider = ProviderKind.codex
    @State private var search = ""
    @State private var showingImport = false
    @State private var hoveredPage: SettingsPage?
    @State private var hoveredProvider: ProviderKind?
    @FocusState private var searchIsFocused: Bool
    @Environment(KeybindingsStore.self) private var keybindings: KeybindingsStore?

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            GeometryReader { geometry in
                ScrollView {
                    VStack(alignment: .leading, spacing: 32) {
                        Text(store.settingsPage.title)
                            .font(.system(size: 26, weight: .regular))
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityAddTraits(.isHeader)
                        page
                    }
                    .frame(maxWidth: 720, alignment: .leading)
                    .padding(.horizontal, geometry.size.width < 620 ? 24 : 40)
                    .padding(.top, geometry.size.height < 680 ? 48 : 76).padding(.bottom, 48)
                    .frame(maxWidth: .infinity, alignment: .top)
                }
                .id(store.settingsPage)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(ChatChrome.canvas)
        }
        .font(.system(size: 13))
        .toggleStyle(.switch).controlSize(.regular)
        .sheet(isPresented: $showingImport) { AgentSessionImportView(store: store.agentSessionImports) }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Settings").font(.system(size: 16, weight: .medium))
                Spacer()
                Button { store.showChat() } label: {
                    Image(systemName: "xmark").font(.system(size: 12))
                        .foregroundStyle(.secondary).frame(width: 28, height: 28)
                }.buttonStyle(SettingsSidebarControlStyle()).help("Back to chat").accessibilityLabel("Back to chat")
            }.padding(.horizontal, 8)
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(.secondary)
                TextField("Search", text: $search).textFieldStyle(.plain)
                    .focused($searchIsFocused)
                    .accessibilityLabel("Search settings").accessibilityIdentifier("settings-search")
                if !search.isEmpty {
                    Button { search = ""; searchIsFocused = true } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 12))
                            .foregroundStyle(.secondary).frame(width: 20, height: 24)
                    }.buttonStyle(SettingsSidebarControlStyle())
                        .help("Clear search").accessibilityLabel("Clear settings search")
                        .accessibilityIdentifier("settings-clear-search")
                }
            }.padding(.leading, 12).padding(.trailing, search.isEmpty ? 12 : 6).frame(height: 34)
                .background(Color.primary.opacity(0.065), in: Capsule())
                .overlay { Capsule().strokeBorder(Color.primary.opacity(searchIsFocused ? 0.15 : 0)).allowsHitTesting(false) }
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    navigationGroup("Personal", pages: [.general, .notifications, .appearance, .conversations, .keyboard])
                    navigationGroup("Integrations", pages: [.providers, .models])
                    navigationGroup("Coincide", pages: [.about])
                    if !SettingsPage.allCases.contains(where: matchesSearch) {
                        Text("No matching settings")
                            .foregroundStyle(.secondary).padding(.horizontal, 10).padding(.top, 4)
                    }
                }
                .padding(.top, 4).padding(.bottom, 12)
            }.scrollIndicators(.hidden)
        }
        .padding(.horizontal, 12).padding(.top, 20).padding(.bottom, 12)
        .frame(width: 248).frame(maxHeight: .infinity, alignment: .topLeading)
        .background(ChatChrome.sidebar)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 12, bottomLeadingRadius: 12))
        .overlay(alignment: .trailing) { Rectangle().fill(ChatChrome.separator).frame(width: 1) }
    }

    private func matchesSearch(_ page: SettingsPage) -> Bool {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        let terms = [page.title] + page.searchKeywords
        return query.split(whereSeparator: { $0.isWhitespace }).allSatisfy { word in
            terms.contains { $0.localizedCaseInsensitiveContains(String(word)) }
        }
    }

    @ViewBuilder private func navigationGroup(_ title: LocalizedStringKey, pages: [SettingsPage]) -> some View {
        let matches = pages.filter(matchesSearch)
        if !matches.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12)).foregroundStyle(.secondary)
                    .padding(.horizontal, 10).padding(.bottom, 6).accessibilityAddTraits(.isHeader)
                ForEach(matches) { page in
                    Button { store.settingsPage = page } label: {
                        HStack(spacing: 10) {
                            Image(systemName: page.icon).font(.system(size: 14)).frame(width: 18)
                            Text(page.title).font(.system(size: 13)).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(.primary).padding(.horizontal, 10).frame(height: 33)
                        .contentShape(RoundedRectangle(cornerRadius: 7))
                        .background(Color.primary.opacity(store.settingsPage == page ? 0.10 : hoveredPage == page ? 0.05 : 0), in: RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                    .onHover { hoveredPage = $0 ? page : hoveredPage == page ? nil : hoveredPage }
                    .accessibilityIdentifier("settings-page-" + page.rawValue)
                    .accessibilityAddTraits(store.settingsPage == page ? .isSelected : [])
                }
            }
        }
    }

    @ViewBuilder private var page: some View {
        switch store.settingsPage {
        case .general:
            DesktopShellSettings(shell: .shared)
        case .appearance:
            SettingsCard(title: "Theme") {
                SettingsRow(title: "Appearance", subtitle: "Choose how Coincide looks on this Mac.") {
                    SettingsMenu(label: appearance == "dark" ? String(localized: "Dark") : appearance == "light" ? String(localized: "Light") : String(localized: "System")) {
                        Button("System") { appearance = "system" }
                        Button("Light") { appearance = "light" }
                        Button("Dark") { appearance = "dark" }
                    }.accessibilityLabel("Appearance")
                }
            }
            SettingsCard(title: "Messages") {
                SettingsRow(title: "Render math", subtitle: "Display mathematical notation in conversation messages.") {
                    Toggle("Render math in messages", isOn: $renderMathInMarkdown).labelsHidden()
                        .accessibilityIdentifier("settings-render-math")
                }
                SettingsDivider()
                SettingsRow(title: "Wrap code and tables", subtitle: "Wrap long lines by default. Each block also has its own wrap control.") {
                    Toggle("Word wrap", isOn: $wordWrap).labelsHidden().accessibilityIdentifier("settings.wordWrap")
                }
                SettingsDivider()
                TranscriptSettings()
            }
        case .notifications:
            ThreadNotificationSettings(notifications: store.notifications)
        case .providers:
            agentSettings
        case .models:
            ModelPickerSettings(store: store, openAgentSettings: { selectedProvider in
                provider = selectedProvider
                store.settingsPage = .providers
            })
        case .conversations:
            SettingsCard(title: "Follow-ups") {
                SettingsRow(title: "Messages during a running turn", subtitle: "Queue your next message or send it as guidance to the current turn.") {
                    SettingsMenu(label: ComposerFollowUpBehavior(rawValue: followUpBehavior)?.title ?? ComposerFollowUpBehavior.queue.title) {
                        ForEach(ComposerFollowUpBehavior.allCases) { behavior in
                            Button(behavior.title) { followUpBehavior = behavior.rawValue }
                        }
                    }.accessibilityLabel("Messages during a running turn")
                }
            }
            SettingsCard(title: "Saved conversations") {
                SettingsRow(title: "Chats on this Mac", subtitle: "Coincide keeps its own history, including when you switch agents.") {
                    Text("\(store.snapshot.threads.count)").foregroundStyle(.secondary)
                }
                SettingsDivider()
                SettingsRow(title: "Show archived chats", subtitle: "Include archived conversations in the sidebar.") {
                    Toggle("Show archived chats in the sidebar", isOn: $store.showArchived).labelsHidden()
                }
                SettingsDivider()
                SettingsRow(title: "Import conversations", subtitle: "Copy Codex or Claude conversations into independent Coincide chats.") {
                    Button("Import…") { showingImport = true }.buttonStyle(SettingsActionButtonStyle())
                }
            }
        case .keyboard:
            if let keybindings { KeybindingsSettingsView(keybindings: keybindings) }
            else { ContentUnavailableView("Keyboard settings unavailable", systemImage: "keyboard") }
        case .about:
            SettingsCard {
                SettingsRow(title: "Coincide", subtitle: "A native Mac app for Codex and Claude.") {
                    Text(DesktopShellSettings.versionText()).foregroundStyle(.secondary)
                }
                SettingsDivider()
                SettingsRow(title: "Source code") {
                    Link("View on GitHub", destination: URL(string: "https://github.com/apoorvdarshan/coincide")!)
                        .buttonStyle(SettingsActionButtonStyle())
                }
                SettingsDivider()
                SettingsRow(title: "Open-source licenses") {
                    Button("View licenses") { DesktopShell.shared.showLicenses() }
                        .buttonStyle(SettingsActionButtonStyle()).accessibilityIdentifier("settings-view-licenses")
                }
            }
        }
    }

    private var agentSettings: some View {
        VStack(alignment: .leading, spacing: 32) {
            HStack(spacing: 12) {
                ForEach(ProviderKind.builtIn) { agent in
                    Button { provider = agent } label: {
                        HStack(spacing: 10) {
                            ProviderLogo(provider: agent, size: 22)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(agent.name).font(.system(size: 13, weight: .medium))
                                Text(!store.models(for: agent).isEmpty ? "Models available" : store.pickerProviderAvailable(agent) ? "CLI found" : "Set up CLI")
                                    .font(.system(size: 12)).foregroundStyle(.secondary)
                            }.fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                            Image(systemName: "checkmark").font(.system(size: 12))
                                .opacity(provider == agent ? 1 : 0).accessibilityHidden(true)
                        }
                        .padding(16).frame(maxWidth: .infinity)
                        .background(ChatChrome.settingsCard, in: RoundedRectangle(cornerRadius: 14))
                        .overlay { RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(hoveredProvider == agent ? 0.035 : 0)).allowsHitTesting(false) }
                        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(provider == agent ? 0.28 : hoveredProvider == agent ? 0.16 : 0.08)).allowsHitTesting(false) }
                        .contentShape(RoundedRectangle(cornerRadius: 14))
                    }.buttonStyle(.plain).accessibilityLabel(agent.name + " agent settings")
                        .onHover { hoveredProvider = $0 ? agent : hoveredProvider == agent ? nil : hoveredProvider }
                        .accessibilityAddTraits(provider == agent ? .isSelected : [])
                }
            }
            SettingsCard(title: "Connection") {
                SettingsRow(title: "CLI sign-in", subtitle: "Uses the official CLI and its existing sign-in on this Mac. An authenticated CLI needs no separate API key.") {
                    Button("Set up…") { DesktopShell.shared.showWelcome() }
                        .buttonStyle(SettingsActionButtonStyle()).accessibilityIdentifier("settings-run-setup")
                }
                SettingsDivider()
                SettingsRow(title: "Available models", subtitle: "\(store.models(for: provider).count) models loaded for this agent.") {
                    Button(store.isRefreshingModels ? "Refreshing…" : "Refresh") {
                        Task { await store.refreshModels(provider: provider) }
                    }.buttonStyle(SettingsActionButtonStyle()).disabled(store.isRefreshingModels)
                }
            }
            if provider == .codex {
                VStack(alignment: .leading, spacing: 32) {
                CodexRuntimeSettingsSection(runtime: store.codexRuntime)
                if store.codexRuntime.configuration.authenticationMode == .cliDefault {
                    CodexAccountSection(account: store.codexAccount, runtimeConfiguration: store.codexRuntime.configuration) { await store.refreshCodexAccount() }
                        .id(store.codexRuntime.configuration)
                } else {
                    Text("This saved runtime uses an app-managed account. New app-managed sign-in is deferred; its existing configuration is unchanged.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                }
            } else { ClaudeRuntimeSettingsSection(runtime: store.claudeRuntime) }
            ShellEnvironmentSettings(environment: DesktopShell.shared.environment)
        }
    }
}

private struct SettingsSidebarControlStyle: ButtonStyle {
    @State private var isHovered = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Color.primary.opacity(configuration.isPressed ? 0.11 : isHovered ? 0.06 : 0), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .onHover { isHovered = $0 }
    }
}
