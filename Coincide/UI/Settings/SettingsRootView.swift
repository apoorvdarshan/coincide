import CoincideKit
import SwiftUI

struct SettingsRootView: View {
    @Bindable var model: SettingsModel
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        NavigationSplitView {
            SettingsSidebar(model: model)
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
                .scrollContentBackground(.hidden)
                .background(Color(nsColor: Theme.sidebarBackground))
        } detail: {
            detail
                .scrollContentBackground(.hidden)
                .background(Color(nsColor: Theme.contentBackground))
        }
        .toggleStyle(ThemedSwitchToggleStyle())
        .buttonStyle(ThemedButtonStyle())
        .textFieldStyle(ThemedTextFieldStyle())
        .tint(Color(nsColor: Theme.ink))
        .sheet(isPresented: antigravityRiskShown) {
            AntigravityRiskSheet(gate: model.antigravityRisk)
        }
        .toolbar(removing: .sidebarToggle)
        .searchable(text: $model.searchText, placement: .sidebar, prompt: Text("Search"))
        .searchFocused($isSearchFocused)
        .background {
            // Command-F jumps to the search field, as in System Settings.
            Button("Search Settings") { isSearchFocused = true }
                .keyboardShortcut("f")
                .hidden()
        }
    }

    /// The Antigravity acknowledgement; closing it any other way than I Understand cancels what asked.
    private var antigravityRiskShown: Binding<Bool> {
        Binding(
            get: { model.antigravityRisk.isAsking },
            set: { if !$0 { model.antigravityRisk.cancel() } })
    }

    @ViewBuilder private var detail: some View {
        switch model.pane {
        case .section(.general): GeneralSettingsView(model: model)
        case .section(.providers): ProvidersSettingsView(model: model)
        case .section(.models): ModelsSettingsView(model: model)
        case .section(.usage): UsageSettingsView()
        case .section(.instructions): InstructionsSettingsView()
        case .section(.archive): ArchiveSettingsView()
        case .section(.keyboard): KeyboardSettingsView(model: model)
        case .section(.voice): VoiceSettingsView(model: model)
        case .section(.browser): BrowserSettingsView()
        case .section(.computerUse): ComputerUseSettingsView()
        case .section(.appshots): AppshotsSettingsView()
        case .section(.about): AboutSettingsView()
        case .provider(let kind): ProviderSettingsView(model: model, kind: kind).id(kind)
        }
    }
}

extension SettingsPane {
    var title: String {
        switch self {
        case .section(let section): section.title
        case .provider(let kind): kind.displayName
        }
    }
}

private struct SettingsSidebar: View {
    @Bindable var model: SettingsModel

    var body: some View {
        if model.searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            List(selection: selection) {
                Section {
                    row(.general)
                    row(.models)
                    row(.usage)
                    row(.instructions)
                    row(.archive)
                    row(.keyboard)
                    row(.voice)
                    row(.browser)
                    row(.computerUse)
                    row(.appshots)
                }
                Section("Providers") {
                    Label {
                        Text("Overview")
                    } icon: {
                        SettingsIconTile(symbol: "square.grid.2x2.fill", color: .indigo)
                    }
                    .pointerCursorRow()
                    .tag(SettingsPane.section(.providers))
                    ForEach(model.kinds, id: \.self) { kind in
                        ProviderSidebarRow(model: model, kind: kind)
                            .pointerCursorRow()
                            .tag(SettingsPane.provider(kind))
                    }
                }
                Section {
                    row(.about)
                }
            }
            .listStyle(.sidebar)
        } else {
            SettingsSearchResults(model: model)
        }
    }

    /// The sidebar never deselects; clicking empty space keeps the current pane.
    private var selection: Binding<SettingsPane?> {
        Binding(get: { model.pane }, set: { if let pane = $0 { model.navigate(to: pane) } })
    }

    private func row(_ section: SettingsSection) -> some View {
        Label {
            Text(section.title)
        } icon: {
            SettingsIconTile(symbol: section.symbolName, color: section.tint)
        }
        .pointerCursorRow()
        .tag(SettingsPane.section(section))
    }
}

private struct ProviderSidebarRow: View {
    let model: SettingsModel
    let kind: ProviderKind

    var body: some View {
        let presentation = SettingsProviderStatus(model: model, kind: kind)
        Label {
            HStack(spacing: 6) {
                Text(kind.displayName)
                    .opacity(model.isEnabled(kind) ? 1 : 0.5)
                Spacer(minLength: 4)
                SettingsStatusDot(color: presentation.color)
                    .help(presentation.headline)
            }
        } icon: {
            SettingsProviderIcon(kind: kind, size: 20)
                .opacity(model.isEnabled(kind) ? 1 : 0.55)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(presentation.headline)
    }
}

extension SettingsSection {
    var tint: Color {
        switch self {
        case .general: .gray
        case .providers: .indigo
        case .models: .purple
        case .usage: .green
        case .instructions: .teal
        case .archive: .brown
        case .keyboard: Color(nsColor: .darkGray)
        case .voice: .red
        case .browser: .cyan
        case .computerUse: .blue
        case .appshots: .orange
        case .about: .blue
        }
    }
}

// MARK: Search

/// One searchable destination: a pane, a provider page, or a row on the General pane.
struct SettingsSearchEntry: Identifiable {
    let title: String
    let pane: SettingsPane
    var setting: SettingsRowID?
    var keywords: [String] = []

    var id: String { "\(pane.title)/\(title)" }

    func matches(_ query: String) -> Bool {
        title.localizedStandardContains(query) || keywords.contains { $0.localizedStandardContains(query) }
    }
}

struct SettingsSearchResults: View {
    let model: SettingsModel
    @State private var selection: SettingsSearchEntry.ID?

    var body: some View {
        let query = model.searchText.trimmingCharacters(in: .whitespaces)
        let results = Self.entries(kinds: model.kinds).filter { $0.matches(query) }
        Group {
            if results.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                List(selection: $selection) {
                    Section("Results") {
                        ForEach(results) { entry in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(entry.title)
                                Text(entry.pane.title)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .pointerCursorRow()
                            .tag(entry.id)
                        }
                    }
                }
                .listStyle(.sidebar)
                .onChange(of: selection) { _, id in
                    guard let entry = results.first(where: { $0.id == id }) else { return }
                    model.navigate(to: entry.pane, reveal: entry.setting)
                }
            }
        }
        .onChange(of: query) { selection = nil }
    }

    static func entries(kinds: [ProviderKind]) -> [SettingsSearchEntry] {
        let general = SettingsPane.section(.general)
        let voice = SettingsPane.section(.voice)
        var entries: [SettingsSearchEntry] = [
            SettingsSearchEntry(title: String(localized: "Usage"), pane: .section(.usage),
                keywords: [String(localized: "Account limits"), String(localized: "Tokens"), String(localized: "Cost"),
                           String(localized: "Credits"), String(localized: "Menu bar")]),
            SettingsSearchEntry(
                title: String(localized: "Appearance"), pane: general, setting: .appearance,
                keywords: [String(localized: "Dark mode"), String(localized: "Light mode"), String(localized: "Theme")]),
            SettingsSearchEntry(
                title: String(localized: "Number format"), pane: general, setting: .numberFormat,
                keywords: [
                    NumberFormatMode.system.displayName, NumberFormatMode.international.displayName,
                    "number format", "grouping", "locale", "commas", "international",
                ]),
            SettingsSearchEntry(
                title: String(localized: "Font size"), pane: general, setting: .fontSize,
                keywords: [String(localized: "Text size"), String(localized: "Zoom")]),
            SettingsSearchEntry(
                title: String(localized: "Dark theme"), pane: general, setting: .darkTheme,
                keywords: [String(localized: "Theme"), String(localized: "Colors"), String(localized: "Dark mode")]),
            SettingsSearchEntry(
                title: String(localized: "Light theme"), pane: general, setting: .lightTheme,
                keywords: [String(localized: "Theme"), String(localized: "Colors"), String(localized: "Light mode")]),
            SettingsSearchEntry(
                title: String(localized: "Pointing hand over clickable items"), pane: general, setting: .pointingHand,
                keywords: [
                    String(
                        localized: "settings.search.cursor", defaultValue: "Cursor",
                        comment: "A Settings search keyword for the mouse pointer (not the Cursor agent)"),
                    String(localized: "Pointer"), String(localized: "Mouse"), String(localized: "Hand"),
                    String(localized: "Links"), String(localized: "Buttons"), "cursor", "pointer",
                ]),
            SettingsSearchEntry(
                title: String(localized: "Reply font"), pane: general, setting: .replyTypeface,
                keywords: [String(localized: "Serif"), String(localized: "Typeface"), String(localized: "New York")]),
            SettingsSearchEntry(
                title: String(localized: "Your messages"), pane: general, setting: .userMessageSide,
                keywords: [String(localized: "Chat layout"), String(localized: "Message alignment"), String(localized: "Right"),
                           String(localized: "Left")]),
            SettingsSearchEntry(
                title: String(localized: "Terminal"), pane: general, setting: .terminalPlacement,
                keywords: [
                    String(localized: "Bottom panel"), String(localized: "Right panel"), String(localized: "Toolbar"),
                    String(localized: "Navigation"), String(localized: "Shell"), String(localized: "Layout"),
                ]),
            SettingsSearchEntry(
                title: String(localized: "GPU rendering"), pane: general, setting: .terminalGPURendering,
                keywords: [
                    String(localized: "Terminal"), String(localized: "Metal"), String(localized: "Graphics"),
                    String(localized: "Performance"), "GPU", "Metal", "SwiftTerm",
                ]),
            SettingsSearchEntry(
                title: String(localized: "Translucent terminal"), pane: general, setting: .terminalTranslucency,
                keywords: [
                    String(localized: "Terminal"), String(localized: "Transparency"), String(localized: "Background"),
                    String(localized: "Blur"), String(localized: "Opacity"),
                ]),
            SettingsSearchEntry(
                title: String(localized: "Open project folders in"), pane: general, setting: .openIn,
                keywords: [
                    String(localized: "Open In"), String(localized: "Editor"), "Xcode", "VS Code", "Cursor", "Finder",
                    String(localized: "Terminal"),
                ]),
            SettingsSearchEntry(
                title: String(localized: "Send messages with"), pane: general, setting: .sendShortcut,
                keywords: [String(localized: "Return"), String(localized: "Enter"), String(localized: "New line")]),
            SettingsSearchEntry(
                title: String(localized: "Follow-up behavior"), pane: general, setting: .followUpBehavior,
                keywords: [String(localized: "Steer"), String(localized: "Queue"), String(localized: "Follow-ups")]),
            SettingsSearchEntry(
                title: String(localized: "Show reasoning"), pane: general, setting: .showReasoning,
                keywords: [String(localized: "Thinking")]),
            SettingsSearchEntry(
                title: String(localized: "Open links in your default browser"), pane: general, setting: .openLinksInBrowser,
                keywords: [String(localized: "Links"), String(localized: "Browser Preview"), String(localized: "Web links")]),
            SettingsSearchEntry(
                title: String(localized: "Default model"), pane: general, setting: .defaultModel,
                keywords: [String(localized: "New threads"), String(localized: "Reasoning effort")]),
            SettingsSearchEntry(
                title: String(localized: "Access"), pane: general, setting: .accessMode,
                keywords: [String(localized: "Approval"), String(localized: "Permissions"), String(localized: "Full access")]),
            SettingsSearchEntry(
                title: String(localized: "Confirm before deleting threads"), pane: general, setting: .confirmDelete),
            SettingsSearchEntry(
                title: String(localized: "Confirm before archiving threads"), pane: general, setting: .confirmArchive),
            SettingsSearchEntry(
                title: String(localized: "Hold ⌘Q to quit"), pane: general, setting: .holdToQuit,
                keywords: [String(localized: "Quit"), String(localized: "Keyboard")]),
            SettingsSearchEntry(
                title: String(localized: "Approve schedules agents create"), pane: general, setting: .approveSchedules,
                keywords: [
                    String(localized: "Schedule"), String(localized: "Scheduled Tasks"), String(localized: "Recurring"),
                    String(localized: "Cron"), String(localized: "Approval"), String(localized: "Reminder"),
                ]),
            SettingsSearchEntry(
                title: String(localized: "Resume after usage limits"), pane: general, setting: .resumeAfterLimit,
                keywords: [String(localized: "Rate limit"), String(localized: "Continue"), String(localized: "Auto-resume")]),
            SettingsSearchEntry(
                title: String(localized: "New Thread starts a chat"), pane: general, setting: .newThreadChat,
                keywords: [String(localized: "Chats"), String(localized: "No project"), String(localized: "Shortcut")]),
            SettingsSearchEntry(
                title: String(localized: "Name threads with the agent"), pane: general, setting: .threadTitles,
                keywords: [String(localized: "Titles"), String(localized: "Rename"), String(localized: "AI")]),
            SettingsSearchEntry(
                title: String(localized: "Keep titles up to date"), pane: general, setting: .threadTitleUpdates,
                keywords: [
                    String(localized: "Titles"), String(localized: "Rename"), String(localized: "Refresh"),
                    String(localized: "Automatic"),
                ]),
            SettingsSearchEntry(
                title: String(localized: "Notifications"), pane: general, setting: .notifications,
                keywords: [String(localized: "Background"), String(localized: "Alerts")]),
            SettingsSearchEntry(
                title: String(localized: "Checkpoints"), pane: general, setting: .checkpoints,
                keywords: [String(localized: "Git"), String(localized: "Revert"), String(localized: "Undo")]),
            SettingsSearchEntry(
                title: String(localized: "Worktree branch prefix"), pane: general, setting: .branchPrefix,
                keywords: [String(localized: "Git"), String(localized: "Branch")]),
            SettingsSearchEntry(
                title: String(localized: "Close idle agents"), pane: general, setting: .idleTimeout,
                keywords: [String(localized: "Timeout"), String(localized: "Memory"), String(localized: "Sessions")]),
            SettingsSearchEntry(
                title: String(localized: "Keep agents running when Coincide quits"), pane: general, setting: .backgroundAgents,
                keywords: [
                    String(localized: "Background"), String(localized: "Agent host"), String(localized: "Login Items"),
                    String(localized: "Quit"),
                ]),
            SettingsSearchEntry(
                title: String(localized: "Keep this Mac awake 24/7"), pane: general, setting: .keepAwake,
                keywords: [
                    String(localized: "Keep Awake"), String(localized: "Sleep"), String(localized: "Lid"), String(localized: "Clamshell"),
                    String(localized: "Always on"), String(localized: "Display"), String(localized: "Battery"),
                    "24/7", "24x7", "pmset", "macbook-24x7-agents",
                ]),
            SettingsSearchEntry(
                title: String(localized: "Sleep normally on battery"), pane: general, setting: .keepAwake,
                keywords: [
                    String(localized: "Battery"), String(localized: "Charger"), String(localized: "Unplugged"),
                    String(localized: "Lid"), String(localized: "Battery helper"), "disablesleep",
                ]),
            SettingsSearchEntry(
                title: String(localized: "Command-line control"), pane: general, setting: .commandLine,
                keywords: ["coincide", String(localized: "Terminal"), String(localized: "Command line"), "CLI", String(localized: "Automation")]),
            SettingsSearchEntry(
                title: String(localized: "Coincide Remote"), pane: general, setting: .remote,
                keywords: [
                    String(localized: "iPhone"), String(localized: "iPad"), String(localized: "Pair"), String(localized: "Tailscale"),
                    String(localized: "Phone"),
                ]),
            SettingsSearchEntry(
                title: String(localized: "Providers"), pane: .section(.providers),
                keywords: [String(localized: "Agents"), String(localized: "Check again"), String(localized: "Status")]),
            SettingsSearchEntry(
                title: String(localized: "Models"), pane: .section(.models),
                keywords: [String(localized: "Custom model"), String(localized: "Context window")]),
            SettingsSearchEntry(
                title: String(localized: "Instructions"), pane: .section(.instructions),
                keywords: ["AGENTS.md", "CLAUDE.md", "GEMINI.md", String(localized: "Rules"), String(localized: "Memory")]),
            SettingsSearchEntry(
                title: SettingsSection.archive.title, pane: .section(.archive),
                keywords: [String(localized: "Archived threads"), String(localized: "Unarchive"), String(localized: "Delete All")]),
            SettingsSearchEntry(
                title: String(localized: "Keyboard shortcuts"), pane: .section(.keyboard),
                keywords: [String(localized: "Keybindings"), String(localized: "Hotkeys")]),
            SettingsSearchEntry(
                title: SettingsSection.voice.title, pane: voice, setting: .voiceEnabled,
                keywords: [
                    String(localized: "Dictation"), String(localized: "Speech to text"), String(localized: "Microphone"),
                    String(localized: "Voice input"), "dictate", "speech", "voice", "mic",
                ]),
            SettingsSearchEntry(
                title: String(localized: "Dictation engine"), pane: voice, setting: .voiceEngine,
                keywords: [
                    String(localized: "Speech recognition"), String(localized: "On device"), "Apple", "OpenAI", "Groq", "Whisper",
                    "WhisperKit",
                ]),
            SettingsSearchEntry(
                title: String(localized: "Dictation language"), pane: voice, setting: .voiceLanguage,
                keywords: [String(localized: "Language"), String(localized: "Automatic"), String(localized: "Locale")]),
            SettingsSearchEntry(
                title: String(localized: "Dictation keyboard shortcut"), pane: voice, setting: .voiceShortcut,
                keywords: [
                    String(localized: "Push to talk"), String(localized: "Hold to talk"), String(localized: "Tap to toggle"),
                    "Fn", "🌐", String(localized: "Globe key"), String(localized: "Hotkey"),
                ]),
            SettingsSearchEntry(
                title: String(localized: "Send when I stop"), pane: voice, setting: .voiceSendWhenStopped,
                keywords: [String(localized: "Auto-send"), String(localized: "Dictation")]),
            SettingsSearchEntry(
                title: String(localized: "Microphone"), pane: voice, setting: .voiceMicrophone,
                keywords: [String(localized: "Input device"), String(localized: "Test microphone"), String(localized: "Level")]),
            SettingsSearchEntry(
                title: String(localized: "OpenAI API key for dictation"), pane: voice, setting: .voiceOpenAI,
                keywords: [
                    "OpenAI", "gpt-transcribe", "gpt-4o-transcribe", "whisper-1", "Codex", String(localized: "API key"),
                    String(localized: "Bring your own key"), "BYOK",
                ]),
            SettingsSearchEntry(
                title: String(localized: "Groq API key for dictation"), pane: voice, setting: .voiceGroq,
                keywords: ["Groq", "whisper-large-v3", "whisper-large-v3-turbo", String(localized: "API key"), "BYOK"]),
            SettingsSearchEntry(
                title: String(localized: "Whisper models"), pane: voice, setting: .voiceWhisper,
                keywords: [
                    "Whisper", "WhisperKit", String(localized: "Offline"), String(localized: "Download"), "tiny", "base", "small",
                    "large-v3-turbo", String(localized: "Local model"),
                ]),
            SettingsSearchEntry(
                title: String(localized: "Browser"), pane: .section(.browser),
                keywords: [
                    String(localized: "Cookies"), String(localized: "History"), String(localized: "Bookmarks"),
                    String(localized: "Import"), String(localized: "Private sessions"), String(localized: "Agent Control"),
                    "Chrome", "Safari", "Firefox", String(localized: "Passwords"), String(localized: "Saved Logins"),
                    "1Password", "Bitwarden", String(localized: "Keychain"),
                ]),
            SettingsSearchEntry(
                title: String(localized: "Computer Use"), pane: .section(.computerUse),
                keywords: [
                    String(localized: "Accessibility"), String(localized: "Screen Recording"),
                    String(localized: "Permissions"), String(localized: "Automation"),
                    "computer use", "accessibility", "screen recording", "automation", "desktop", "screen", "control",
                    "TryCua", "Cua Driver", String(localized: "Show agent cursor"), "cursor", "pointer",
                ]),
            SettingsSearchEntry(
                title: String(localized: "Appshots"), pane: .section(.appshots),
                keywords: [
                    String(localized: "Screenshot"), String(localized: "Capture"), String(localized: "Window"),
                    String(localized: "Both Command keys"), String(localized: "Shortcut"), String(localized: "Window text"),
                    String(localized: "Screen Recording"), String(localized: "Accessibility"), String(localized: "Play a sound"),
                    "appshot", "screenshot", "capture", "window", "command", "hotkey", "⌘", "sound",
                ]),
            SettingsSearchEntry(
                title: String(localized: "About Coincide"), pane: .section(.about),
                keywords: [
                    String(localized: "Version"), String(localized: "License"), "GitHub", "T3 Code", "X", "Instagram",
                ]),
            SettingsSearchEntry(
                title: String(localized: "Report an Issue"), pane: .section(.about),
                keywords: [String(localized: "Bug"), String(localized: "Feedback"), String(localized: "Help"), "GitHub", "bug", "issue"]),
            SettingsSearchEntry(
                title: String(localized: "Request a Feature"), pane: .section(.about),
                keywords: [String(localized: "Idea"), String(localized: "Feedback"), String(localized: "Help"), "GitHub", "feature"]),
        ]
        for kind in kinds {
            entries.append(
                SettingsSearchEntry(
                    title: kind.displayName, pane: .provider(kind),
                    keywords: [
                        String(localized: "Install"), String(localized: "Sign in"), String(localized: "Executable path"),
                        String(localized: "Environment variables"),
                    ]))
        }
        return entries
    }
}
