import CoincideKit
import Foundation
import ServiceManagement

/// The lid watcher's launchd job, as Settings shows it.
enum AlwaysOnServiceState: Equatable, Sendable {
    case running
    /// Registered, waiting for the user to allow it in System Settings › General › Login Items.
    case needsApproval
    case notRegistered
    /// This copy of Coincide doesn't include it.
    case missing
}

/// How the administrator prompt ended.
enum AlwaysOnAdminResult: Equatable, Sendable {
    case succeeded
    case cancelled
    case failed(String)
}

/// macbook-24x7-agents installed from its repository (`install.sh`): its LaunchAgent, script and the mute setting it
/// may still have to put back.
struct StandaloneAlwaysOn: Equatable, Sendable {
    var label: String
    var plist: URL
    var script: URL?
    var audioStateFile: URL
    /// Installed with `--keep-displays-off`.
    var keepsDisplaysOff: Bool
    /// Installed with `--mute-when-closed`.
    var mutesWhileClosed: Bool
}

/// What Keep Awake does outside Coincide. `MacAlwaysOnSystem` changes the real Mac; tests use a fake, so they never
/// change power settings, ask for a password or register anything with launchd.
@MainActor
protocol AlwaysOnSystem: AnyObject {
    /// `pmset -g` and `pmset -g custom`; nil when they can't be read.
    func readPower() async -> PowerSettings?
    /// Runs a script built by `AlwaysOnScript` as administrator, after macOS asks for the user's password.
    func runAsAdministrator(_ script: String, prompt: String) async -> AlwaysOnAdminResult
    var serviceState: AlwaysOnServiceState { get }
    func registerService() throws
    func unregisterService() async throws
    func openLoginItems()
    var hasLid: Bool { get }
    func findStandalone() -> StandaloneAlwaysOn?
    /// Stops its lid watcher and removes its LaunchAgent and script.
    func removeStandalone(_ install: StandaloneAlwaysOn) async throws
    /// Puts back a mute setting the watcher saved, when Keep Awake turns off without it running.
    func restoreAudio(stateFile: URL)
}

final class MacAlwaysOnSystem: AlwaysOnSystem {
    private let service = SMAppService.agent(plistName: AlwaysOnIdentity.plistName)
    private let pmset = URL(fileURLWithPath: "/usr/bin/pmset")

    func readPower() async -> PowerSettings? {
        async let general = ProcessRunner.run(pmset, ["-g"], timeout: 10)
        async let custom = ProcessRunner.run(pmset, ["-g", "custom"], timeout: 10)
        let (current, profiles) = await (general, custom)
        guard current.succeeded, profiles.succeeded else { return nil }
        return PowerSettings.parse(general: current.stdout, custom: profiles.stdout)
    }

    func runAsAdministrator(_ script: String, prompt: String) async -> AlwaysOnAdminResult {
        // The script and prompt go in as arguments, so nothing needs quoting inside the AppleScript.
        let result = await ProcessRunner.run(
            URL(fileURLWithPath: "/usr/bin/osascript"),
            [
                "-e", "on run argv", "-e",
                "do shell script (item 1 of argv) with prompt (item 2 of argv) with administrator privileges",
                "-e", "end run", script, prompt,
            ], timeout: 600)
        if result.succeeded { return .succeeded }
        // AppleScript's "User canceled." error.
        if result.stderr.contains("(-128)") { return .cancelled }
        let reason = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return .failed(reason.isEmpty ? String(localized: "macOS didn’t change the sleep settings.") : reason)
    }

    var serviceState: AlwaysOnServiceState {
        switch service.status {
        case .enabled: .running
        case .requiresApproval: .needsApproval
        case .notFound: .missing
        default: .notRegistered
        }
    }

    func registerService() throws { try service.register() }
    func unregisterService() async throws { try await service.unregister() }
    func openLoginItems() { SMAppService.openSystemSettingsLoginItems() }
    var hasLid: Bool { ClamshellSensor.hasLid }

    func findStandalone() -> StandaloneAlwaysOn? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let label = "com.\(NSUserName()).lidwatch"
        let plist = home.appendingPathComponent("Library/LaunchAgents/\(label).plist")
        guard let data = try? Data(contentsOf: plist),
            let job = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            let arguments = job["ProgramArguments"] as? [String],
            arguments.first?.hasSuffix("lid-display-off.sh") == true
        else { return nil }
        let script = URL(fileURLWithPath: arguments[0])
        return StandaloneAlwaysOn(
            label: label, plist: plist,
            script: FileManager.default.fileExists(atPath: script.path) ? script : nil,
            audioStateFile: home.appendingPathComponent("Library/Application Support/macbook-24x7-agents/audio-mute-state"),
            keepsDisplaysOff: arguments.contains("--mode=continuous"),
            mutesWhileClosed: arguments.contains("--mute-when-closed=true"))
    }

    func removeStandalone(_ install: StandaloneAlwaysOn) async throws {
        // Not loaded is fine: it may have been stopped already.
        _ = await ProcessRunner.run(
            URL(fileURLWithPath: "/bin/launchctl"), ["bootout", "gui/\(getuid())/\(install.label)"], timeout: 20)
        try FileManager.default.removeItem(at: install.plist)
        if let script = install.script { try? FileManager.default.removeItem(at: script) }
    }

    func restoreAudio(stateFile: URL) {
        LidWatcherCore(hardware: MacLidHardware(), audio: AlwaysOnAudioState(url: stateFile), settings: AlwaysOnSettings()).stop()
    }
}
