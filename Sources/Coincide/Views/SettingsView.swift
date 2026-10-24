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
        case .keyboard: "keyboard"
        case .about: "info.circle"
        }
    }
}

struct SettingsView: View {
    @Bindable var store: WorkspaceStore
    var embedded = false
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("followUpBehavior") private var followUpBehavior = ComposerFollowUpBehavior.queue.rawValue
    @AppStorage("renderMathInMarkdown") private var renderMathInMarkdown = false
    @State private var provider = ProviderKind.codex
    @State private var search = ""
    @State private var showingImport = false
    @Environment(KeybindingsStore.self) private var keybindings: KeybindingsStore?
    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 1)
            VStack(alignment: .leading, spacing: 12) {
                Text(store.settingsPage.title)
                    .font(.system(size: 26, weight: .regular))
                    .padding(.horizontal, 20).padding(.top, 78)
                page.frame(maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: 680, maxHeight: .infinity, alignment: .topLeading)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(ChatChrome.canvas)
        }
        .font(.system(size: 13))
        .controlSize(.small)
        .frame(minWidth: 740, idealWidth: 1020, minHeight: 560, idealHeight: 720)
        .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
        .sheet(isPresented: $showingImport) { AgentSessionImportView(store: store.agentSessionImports) }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Settings").font(.system(size: 16, weight: .medium))
                Spacer()
                if embedded {
                    Button { store.showingSettings = false } label: {
                        Image(systemName: "xmark").font(.system(size: 12))
                            .foregroundStyle(.secondary).frame(width: 24, height: 24)
                    }.buttonStyle(.plain).help("Back to chat").accessibilityLabel("Back to chat")
                }
            }.padding(.horizontal, 8)
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search settings", text: $search).textFieldStyle(.plain)
                    .accessibilityLabel("Search settings")
            }.padding(.horizontal, 10).frame(height: 32)
                .background(Color.primary.opacity(0.05), in: Capsule())
            ScrollView {
                VStack(spacing: 3) {
                    ForEach(SettingsPage.allCases.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }) { page in
                        Button { store.settingsPage = page } label: {
                            HStack(spacing: 10) {
                                Image(systemName: page.icon).font(.system(size: 14)).frame(width: 18)
                                Text(page.title).font(.system(size: 13, weight: .regular))
                                Spacer(minLength: 0)
                            }
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 10).frame(height: 32)
                            .contentShape(RoundedRectangle(cornerRadius: 7))
                            .background(Color.primary.opacity(store.settingsPage == page ? 0.09 : 0), in: RoundedRectangle(cornerRadius: 7))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("settings-page-" + page.rawValue)
                        .accessibilityAddTraits(store.settingsPage == page ? .isSelected : [])
                    }
                }
            }
        }
        .padding(.horizontal, 12).padding(.top, 20).padding(.bottom, 12)
        .frame(width: 248).frame(maxHeight: .infinity, alignment: .topLeading)
        .background(ChatChrome.sidebar)
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
                                    ProviderLogo(provider: agent, size: 22)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(agent.name).font(.system(size: 13, weight: .medium))
                                        Text(!store.models(for: agent).isEmpty ? "Models available" : store.pickerProviderAvailable(agent) ? "CLI found" : "Set up CLI")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                    if provider == agent { Image(systemName: "checkmark") }
                                }.padding(10).frame(maxWidth: .infinity)
                                    .background(Color.primary.opacity(provider == agent ? 0.08 : 0.025), in: RoundedRectangle(cornerRadius: 12))
                            }.buttonStyle(.plain).accessibilityLabel(agent.name + " agent settings")
                        }
                    }
                    LabeledContent("Installed CLI", value: ProcessChannel.findExecutable(provider == .codex ? store.codexRuntime.configuration.executable : store.claudeRuntime.profile.executable)?.path ?? "Not found")
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
                Section("Saved conversations") {
                    LabeledContent("Chats on this Mac", value: "\(store.snapshot.threads.count)")
                    Toggle("Show archived chats in the sidebar", isOn: $store.showArchived)
                    Button("Import conversations…") { showingImport = true }
                    Text("Coincide saves its own conversation history. Imports create independent copies, and changing agents keeps the same chat.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        case .keyboard:
            if let keybindings { KeybindingsSettingsView(keybindings: keybindings) }
            else { ContentUnavailableView("Keyboard settings unavailable", systemImage: "keyboard") }
        case .about:
            settingsForm {
                Section {
                    LabeledContent("Coincide", value: DesktopShellSettings.versionText())
                    Text("A native Mac app for Codex and Claude.").foregroundStyle(.secondary)
                    Link("Source code", destination: URL(string: "https://github.com/apoorvdarshan/coincide")!)
                    Button("Open-source licenses") { DesktopShell.shared.showLicenses() }
                }
            }
        }
    }
    private func settingsForm<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        Form(content: content).formStyle(.grouped).scrollContentBackground(.hidden)
            .font(.system(size: 13)).controlSize(.small)
    }
}
