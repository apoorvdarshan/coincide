import Foundation

/// Settings › General › Keep Awake: keeping a MacBook running around the clock for agents, lid closed and display
/// off, as macbook-24x7-agents (github.com/apoorvdarshan/macbook-24x7-agents) does from the command line.
///
/// Built into both CoincideKit and the lid watcher (`coincide-always-on`), which reads these settings from the
/// app's `settings.json`, so this folder uses nothing else from the kit.
public struct AlwaysOnSettings: Codable, Hashable, Sendable {
    /// The Mac's sleep settings are changed and the lid watcher runs. Set only once both happened.
    public var enabled = false
    /// Idle sleep is changed only for the charger (`pmset -c sleep 0` rather than `-a`). `disablesleep` covers every
    /// power source, so the Mac doesn't sleep on battery either while Keep Awake is on.
    public var onlyWhileCharging = true
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
        onlyWhileCharging = value(.onlyWhileCharging, defaults.onlyWhileCharging)
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
    /// The plist in `Contents/Library/LaunchAgents`, registered with `SMAppService.agent(plistName:)`.
    public static let plistName = "com.apoorvdarshan.coincide.always-on.plist"
    public static let label = "com.apoorvdarshan.coincide.always-on"

    /// Coincide's data folder, as `AppStore.defaultDirectory` without the testing override: launchd starts the
    /// watcher without the app's environment.
    public static var dataDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Coincide", isDirectory: true)
    }

    public static func settingsFile(in directory: URL) -> URL { directory.appendingPathComponent("settings.json") }
    /// The sleep settings to put back when Keep Awake turns off (`AlwaysOnRestorePoint`).
    public static func restorePointFile(in directory: URL) -> URL { directory.appendingPathComponent("always-on-restore.json") }
    /// The mute setting from before the lid closed, kept until it is put back (`AlwaysOnAudioState`).
    public static func audioStateFile(in directory: URL) -> URL { directory.appendingPathComponent("always-on-audio-state.json") }
}
