import Foundation

/// Settings › General › Keep Awake: keeping a MacBook running around the clock for agents, lid closed and display
/// off, as macbook-24x7-agents (github.com/apoorvdarshan/macbook-24x7-agents) does from the command line.
///
/// Built into both CoincideKit and the lid watcher (`coincide-always-on`), which reads these settings from the
/// app's `settings.json`, so this folder uses nothing else from the kit.
public struct AlwaysOnSettings: Codable, Hashable, Sendable {
    /// The Mac's sleep settings are changed and the lid watcher runs. Set only once both happened.
    public var enabled = false
    /// On battery the Mac sleeps as usual, closing the lid included; on the charger it stays awake. `pmset disablesleep`
    /// covers every power source, so the battery helper (`coincide-power-helper`, a launchd daemon) switches it as the
    /// Mac is plugged in and unplugged. Off, the Mac stays awake on battery too.
    public var sleepsOnBattery = false
    /// The display goes to sleep when the lid closes, which macOS stops doing once sleep is disabled.
    public var displayOffOnLidClose = true
    /// While the lid is closed, displays that keyboard or mouse input woke go back to sleep.
    public var keepDisplaysOff = false
    /// Sound is muted while the lid is closed, and the earlier mute setting comes back when it opens.
    public var muteWhileClosed = false

    public init() {}

    /// A value this version can't read keeps its default, without losing the others.
    public init(from decoder: Decoder) throws {
        let defaults = AlwaysOnSettings()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value(_ key: CodingKeys, _ fallback: Bool) -> Bool {
            (try? container.decodeIfPresent(Bool.self, forKey: key)) ?? fallback
        }
        enabled = value(.enabled, defaults.enabled)
        sleepsOnBattery = value(.sleepsOnBattery, defaults.sleepsOnBattery)
        displayOffOnLidClose = value(.displayOffOnLidClose, defaults.displayOffOnLidClose)
        keepDisplaysOff = value(.keepDisplaysOff, defaults.keepDisplaysOff)
        muteWhileClosed = value(.muteWhileClosed, defaults.muteWhileClosed)
    }

    /// The part of the app's `settings.json` the lid watcher reads. Nothing readable there means off.
    public static func read(settingsFile: URL) -> AlwaysOnSettings {
        struct File: Decodable {
            var alwaysOn: AlwaysOnSettings?
        }
        guard let data = try? Data(contentsOf: settingsFile),
            let file = try? JSONDecoder().decode(File.self, from: data)
        else { return AlwaysOnSettings() }
        return file.alwaysOn ?? AlwaysOnSettings()
    }
}

/// Names and places shared by the app and the lid watcher.
public enum AlwaysOnIdentity {
    /// The watcher's launchd label, named after the app (`CoincideIdentity`).
    public static let label = CoincideIdentity.scoped("always-on")
    /// The plist in `Contents/Library/LaunchAgents`, registered with `SMAppService.agent(plistName:)`.
    public static let plistName = "\(label).plist"
    /// The battery helper's launchd label.
    public static let batteryHelperLabel = CoincideIdentity.scoped("power-helper")
    /// The battery helper's plist in `Contents/Library/LaunchDaemons`, registered with `SMAppService.daemon(plistName:)`.
    public static let batteryHelperPlistName = "\(batteryHelperLabel).plist"
    /// Where the helper's BundleProgram points, inside Coincide.app.
    public static let batteryHelperPath = "Contents/Helpers/coincide-power-helper"

    /// Coincide's data folder, as `AppStore.defaultDirectory` without the testing override: launchd starts the
    /// watcher without the app's environment.
    public static var dataDirectory: URL { CoincideIdentity.dataDirectory }

    public static func settingsFile(in directory: URL) -> URL { directory.appendingPathComponent("settings.json") }
    /// The sleep settings to put back when Keep Awake turns off (`AlwaysOnRestorePoint`).
    public static func restorePointFile(in directory: URL) -> URL { directory.appendingPathComponent("always-on-restore.json") }
    /// The mute setting from before the lid closed, kept until it is put back (`AlwaysOnAudioState`).
    public static func audioStateFile(in directory: URL) -> URL { directory.appendingPathComponent("always-on-audio-state.json") }
}
