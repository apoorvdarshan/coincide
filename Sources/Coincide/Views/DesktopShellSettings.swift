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
        Section("Confirmations") {
            Picker("Quit shortcut (⌘Q)", selection: $quitMode) {
                ForEach(QuitShortcutStateMachine.Mode.allCases) { Text($0.title).tag($0.rawValue) }
            }.accessibilityIdentifier("settings-quit-shortcut")
            Toggle("Ask before quitting while conversations run", isOn: $confirmRunningQuit)
                .accessibilityIdentifier("settings-confirm-running-quit")
            Text("Hold ⌘Q for a moment or press it twice to quit. Choosing Quit from the Coincide menu skips the shortcut delay and still checks unfinished work. Quitting stops running turns; queued messages wait until you resume them.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        Section("While agents run") {
            Picker("Keep Mac awake", selection: $keepAwake) {
                ForEach(ActivityAssertionPolicy.Preference.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .onChange(of: keepAwake) { _, _ in shell.activity?.update() }
            .accessibilityIdentifier("settings-keep-awake")
            Toggle("Show banners for other conversations", isOn: $threadBanners)
                .accessibilityIdentifier("settings-in-app-banners")
            Text("Coincide prevents App Nap while conversations run. Keeping the Mac awake stops idle sleep; the display can still sleep. Banners appear when another conversation finishes, fails or needs input while Coincide is active.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        ShellEnvironmentSettings(environment: shell.environment)
        CommandLineToolSettings(tool: shell.commandLineTool)
        Section("About") {
            LabeledContent("Version", value: Self.versionText())
            HStack {
                Button("View Licenses…") { shell.showLicenses() }.accessibilityIdentifier("settings-view-licenses")
                Button("Run Setup Again…") { shell.showWelcome() }.accessibilityIdentifier("settings-run-setup")
            }
        }
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
        Section("Shell environment") {
            Toggle("Use login shell environment", isOn: Binding(get: { environment.isEnabled }, set: { value in Task { await environment.setEnabled(value) } }))
                .disabled(!environment.available)
            LabeledContent("Status") {
                HStack(spacing: 6) {
                    if environment.isCapturing { ProgressView().controlSize(.small) }
                    Text(environment.summary).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                }
            }.accessibilityIdentifier("settings-shell-environment-status")
            if let failure = environment.snapshot?.failure {
                Text(failure).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Button("Refresh Shell Environment") { Task { await environment.refresh() } }
                .disabled(!environment.isEnabled || environment.isCapturing)
            Text("Coincide reads PATH and selected variables from your login shell so agents, terminals and Git find tools installed with Homebrew, nvm, mise or similar managers. Running conversations and terminals keep the environment they started with.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct CommandLineToolSettings: View {
    @Bindable var tool: CommandLineToolController
    var body: some View {
        Section("Command-line tool") {
            LabeledContent("coincide command") {
                switch tool.state {
                case .installed(let url): Text(url.path).foregroundStyle(.secondary).textSelection(.enabled)
                case .notInstalled: Text("Not installed").foregroundStyle(.secondary)
                }
            }
            HStack {
                switch tool.state {
                case .installed:
                    Button("Reinstall") { tool.install() }.disabled(tool.isWorking)
                    Button("Remove", role: .destructive) { tool.remove() }.disabled(tool.isWorking)
                case .notInstalled:
                    Button("Install Command…") { tool.install() }.disabled(tool.isWorking).accessibilityIdentifier("settings-install-cli")
                }
            }
            if let message = tool.message { Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            Text("Run coincide [folder] in Terminal to open a folder as a project and start a new conversation there. Nothing is sent to an agent.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.task { tool.refresh() }
    }
}
