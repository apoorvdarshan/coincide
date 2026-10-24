import CoincideCore
import SwiftUI

/// Settings → General sections for desktop integration.
struct DesktopShellSettings: View {
    let shell: DesktopShell
    @AppStorage(QuitShortcutMonitor.preference) private var quitMode = QuitShortcutStateMachine.Mode.hold.rawValue
    @AppStorage(DesktopShell.runningQuitPreference) private var confirmRunningQuit = true
    @AppStorage(AgentActivityAssertion.preference) private var keepAwake = ActivityAssertionPolicy.defaultPreference.rawValue
    @AppStorage(ThreadBannerCoordinator.preference) private var threadBanners = true

    var body: some View {
        SettingsCard(title: "General") {
            SettingsRow(title: "Quit shortcut", subtitle: "Choose how ⌘Q quits Coincide. The app menu always quits immediately after checking unfinished work.") {
                SettingsMenu(label: QuitShortcutStateMachine.Mode(rawValue: quitMode)?.title ?? QuitShortcutStateMachine.Mode.hold.title) {
                    ForEach(QuitShortcutStateMachine.Mode.allCases) { mode in
                        Button(mode.title) { quitMode = mode.rawValue }
                    }
                }.accessibilityLabel("Quit shortcut").accessibilityIdentifier("settings-quit-shortcut")
            }
            SettingsDivider()
            SettingsRow(title: "Confirm before quitting", subtitle: "Ask while conversations are running. Quitting stops active turns; queued messages wait until you resume them.") {
                Toggle("Ask before quitting while conversations run", isOn: $confirmRunningQuit).labelsHidden()
                    .accessibilityIdentifier("settings-confirm-running-quit")
            }
        }
        SettingsCard(title: "While agents run") {
            SettingsRow(title: "Keep Mac awake", subtitle: "Prevent idle sleep during conversations. Your display can still sleep.") {
                SettingsMenu(label: ActivityAssertionPolicy.Preference(rawValue: keepAwake)?.title ?? ActivityAssertionPolicy.defaultPreference.title) {
                    ForEach(ActivityAssertionPolicy.Preference.allCases) { preference in
                        Button(preference.title) { keepAwake = preference.rawValue }
                    }
                }.onChange(of: keepAwake) { _, _ in shell.activity?.update() }
                    .accessibilityLabel("Keep Mac awake").accessibilityIdentifier("settings-keep-awake")
            }
            SettingsDivider()
            SettingsRow(title: "Conversation banners", subtitle: "Show when another chat finishes, fails, or needs input while Coincide is active.") {
                Toggle("Show banners for other conversations", isOn: $threadBanners).labelsHidden()
                    .accessibilityIdentifier("settings-in-app-banners")
            }
        }
        CommandLineToolSettings(tool: shell.commandLineTool)
    }

    static func versionText(_ info: [String: Any]? = Bundle.main.infoDictionary) -> String {
        guard let version = info?["CFBundleShortVersionString"] as? String, !version.isEmpty else { return String(localized: "Development build") }
        if let build = info?["CFBundleVersion"] as? String, !build.isEmpty, build != version { return "\(version) (\(build))" }
        return version
    }
}

struct ShellEnvironmentSettings: View {
    @Bindable var environment: ShellEnvironmentController
    var body: some View {
        SettingsCard(title: "Shell environment") {
            SettingsRow(title: "Use login shell environment", subtitle: "Find CLI tools installed with Homebrew, nvm, mise, or similar managers. Running conversations keep their current environment.") {
                Toggle("Use login shell environment", isOn: Binding(get: { environment.isEnabled }, set: { value in Task { await environment.setEnabled(value) } }))
                    .labelsHidden().disabled(!environment.available)
            }
            SettingsDivider()
            SettingsRow(title: "Status", subtitle: LocalizedStringKey(environment.summary)) {
                HStack(spacing: 8) {
                    if environment.isCapturing { ProgressView().controlSize(.small) }
                    Button("Refresh") { Task { await environment.refresh() } }
                        .buttonStyle(SettingsActionButtonStyle()).disabled(!environment.isEnabled || environment.isCapturing)
                }
            }.accessibilityIdentifier("settings-shell-environment-status")
            if let failure = environment.snapshot?.failure {
                Text(failure).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(.bottom, 14)
            }
        }
    }
}

struct CommandLineToolSettings: View {
    @Bindable var tool: CommandLineToolController
    var body: some View {
        SettingsCard(title: "Command-line tool") {
            SettingsRow(title: "coincide command", subtitle: "Open a project from Terminal with coincide [folder]. Nothing is sent to an agent.") {
                HStack(spacing: 8) {
                    switch tool.state {
                    case .installed:
                        Button("Reinstall") { tool.install() }.disabled(tool.isWorking)
                        Button("Remove", role: .destructive) { tool.remove() }.disabled(tool.isWorking)
                    case .notInstalled:
                        Button("Install…") { tool.install() }.disabled(tool.isWorking).accessibilityIdentifier("settings-install-cli")
                    }
                }.buttonStyle(SettingsActionButtonStyle())
            }
            if case .installed(let url) = tool.state {
                SettingsDivider()
                SettingsRow(title: "Installed at") {
                    Text(url.path).font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary).textSelection(.enabled).lineLimit(2).truncationMode(.middle)
                }
            }
            if let message = tool.message {
                Text(message).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(.bottom, 14)
            }
        }.task { tool.refresh() }
    }
}
