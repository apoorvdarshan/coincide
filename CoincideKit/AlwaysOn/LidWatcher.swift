import Foundation

/// What the lid watcher does to the Mac. The watcher's own implementation uses IOKit, CoreAudio and pmset; tests use
/// a fake, so nothing real changes while they run.
public protocol LidWatcherHardware: AnyObject {
    func sleepDisplays()
    /// nil when the output's mute setting can't be read.
    func outputMuted() -> Bool?
    /// false when macOS refused the change.
    func setOutputMuted(_ muted: Bool) -> Bool
    /// Seconds since the last keyboard or pointer input; nil when unknown.
    func secondsSinceInput() -> Double?
}

/// The mute setting from before the lid closed, saved once before muting so a retry or a restart of the watcher never
/// replaces it with the mute the watcher applied itself.
public final class AlwaysOnAudioState {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public var previousMute: Bool? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Bool.self, from: data)
    }

    /// Written in full before anything is muted, even if the watcher is stopped part way.
    public func save(_ muted: Bool) -> Bool {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(muted).write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    public func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// The lid watcher's decisions, from lid changes and a two-second tick that runs only while something needs it: a
/// closed lid with "Keep displays off" or "Mute" on, or a mute setting still to be put back. The same behaviour as
/// `lid-display-off.sh`, without polling the lid.
public final class LidWatcherCore {
    /// Input more recent than this means someone woke a display while the lid is closed.
    public static let recentInput: TimeInterval = 3

    private let hardware: LidWatcherHardware
    private let audio: AlwaysOnAudioState
    public var settings: AlwaysOnSettings
    public private(set) var lidClosed: Bool?

    public init(hardware: LidWatcherHardware, audio: AlwaysOnAudioState, settings: AlwaysOnSettings) {
        self.hardware = hardware
        self.audio = audio
        self.settings = settings
    }

    /// Whether the two-second tick should run now.
    public var needsTick: Bool {
        if lidClosed == true { return settings.keepDisplaysOff || settings.muteWhileClosed }
        return audio.previousMute != nil
    }

    /// The lid's state, at start and whenever macOS reports a change. Repeats of the same state are ignored, so the
    /// display sleeps once per close.
    public func lid(closed: Bool) {
        let changed = closed != lidClosed
        lidClosed = closed
        if closed {
            if settings.muteWhileClosed { mute() }
            if changed, settings.displayOffOnLidClose { hardware.sleepDisplays() }
        } else {
            restoreAudio()
        }
    }

    public func tick() {
        guard let closed = lidClosed else { return }
        if closed {
            if settings.muteWhileClosed { mute() }
            if settings.keepDisplaysOff, let idle = hardware.secondsSinceInput(), idle < Self.recentInput {
                hardware.sleepDisplays()
            }
        } else {
            restoreAudio()
        }
    }

    /// Keep Awake turned off or the watcher is stopping: what it muted is put back.
    public func stop() {
        restoreAudio()
    }

    private func mute() {
        if audio.previousMute == nil {
            guard let muted = hardware.outputMuted(), audio.save(muted) else { return }
        }
        // Asked again on every tick, also after the output changes; a failure keeps the saved setting for later.
        if hardware.outputMuted() != true { _ = hardware.setOutputMuted(true) }
    }

    private func restoreAudio() {
        guard let previous = audio.previousMute else { return }
        if hardware.outputMuted() == previous || hardware.setOutputMuted(previous) { audio.clear() }
    }
}
