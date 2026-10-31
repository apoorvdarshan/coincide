import Foundation

/// Turns presses of the dictation shortcut into starting, stopping and cancelling dictation, for each
/// `DictationShortcutMode`. Pure and clock-free: the caller passes event times and runs the hold check it asks for.
///
/// A key shortcut (⌥Space) is unambiguous, so it acts on the key going down. A lone modifier (Fn) is also pressed for
/// other reasons (Fn-arrows, function keys, ⌥-clicks), so it acts only once it is known to be alone: on release for a
/// tap, or once held past `holdThreshold` for push-to-talk. Any other key or modifier during the press drops it.
public struct DictationTriggerMachine: Sendable {
    public enum Action: Equatable, Sendable {
        case none
        case start
        /// Stop listening and insert the transcript.
        case stop
        /// Stop listening and throw the recording away.
        case cancel
        /// Call `holdCheck(at:)` after this many seconds if the shortcut is still down.
        case scheduleHoldCheck(TimeInterval)
    }

    /// Held this long, a press is push-to-talk; shorter, it's a tap.
    public nonisolated static let holdThreshold: TimeInterval = 0.3
    /// In tap-only mode a lone modifier held longer than this isn't a tap, just a key held for something else.
    public nonisolated static let longestTap: TimeInterval = 1.0
    /// Presses closer than this to the last start or stop are ignored, so a bouncing key doesn't toggle twice.
    public nonisolated static let debounce: TimeInterval = 0.12

    private struct Press {
        let start: TimeInterval
        /// Another key or modifier came with it: it isn't the shortcut.
        var interrupted = false
        /// Dictation was on when the press began.
        let wasRecording: Bool
        /// This press started dictation.
        var started = false
        /// This press already did what it does; its release does nothing.
        var handled = false
    }

    public var mode: DictationShortcutMode
    public let isLoneModifier: Bool
    /// Whether dictation is on, as far as the shortcut knows. Tell it when dictation starts or stops another way
    /// (`recordingStarted()`, `recordingEnded()`).
    public private(set) var isRecording = false
    private var press: Press?
    private var lastAction: TimeInterval = -.infinity

    public nonisolated init(mode: DictationShortcutMode, isLoneModifier: Bool) {
        self.mode = mode
        self.isLoneModifier = isLoneModifier
    }

    /// Whether the shortcut is down.
    public nonisolated var isPressed: Bool { press != nil }

    public nonisolated mutating func triggerDown(at time: TimeInterval) -> Action {
        guard press == nil else { return .none }  // a key repeat
        var press = Press(start: time, wasRecording: isRecording)
        if time - lastAction < Self.debounce {
            press.interrupted = true
            self.press = press
            return .none
        }
        defer { self.press = press }
        if isRecording {
            // A lone modifier stops on release, once it's known to be alone; keys stop at once.
            guard !isLoneModifier else { return .none }
            press.handled = true
            return stop(at: time)
        }
        if isLoneModifier {
            return mode == .tap ? .none : .scheduleHoldCheck(Self.holdThreshold)
        }
        press.started = true
        if mode == .tap { press.handled = true }
        return start(at: time)
    }

    public nonisolated mutating func holdCheck(at time: TimeInterval) -> Action {
        guard isLoneModifier, mode != .tap, var press, !press.interrupted, !press.wasRecording, !press.started,
            !isRecording, time - press.start >= Self.holdThreshold - 0.001
        else { return .none }
        press.started = true
        self.press = press
        return start(at: time)
    }

    public nonisolated mutating func triggerUp(at time: TimeInterval) -> Action {
        guard let press else { return .none }
        self.press = nil
        if press.interrupted || press.handled { return .none }
        let held = time - press.start
        if press.started {
            // Push-to-talk ends on release; a quick tap in Both leaves dictation on until the next tap.
            if !isRecording { return .none }
            switch mode {
            case .hold: return stop(at: time)
            case .both: return isLoneModifier || held >= Self.holdThreshold ? stop(at: time) : .none
            case .tap: return .none
            }
        }
        guard isLoneModifier else { return .none }
        if press.wasRecording {
            return isRecording ? stop(at: time) : .none
        }
        switch mode {
        case .both where held < Self.holdThreshold: return start(at: time)
        case .tap where held <= Self.longestTap: return start(at: time)
        default: return .none
        }
    }

    /// Another key or modifier while the shortcut is down. A lone modifier pressed with another key isn't the shortcut:
    /// nothing starts, and a hold that already started is cancelled (Fn held, then an arrow).
    public nonisolated mutating func otherInput(at time: TimeInterval) -> Action {
        guard isLoneModifier, var press, !press.interrupted else { return .none }
        press.interrupted = true
        self.press = press
        guard press.started, isRecording else { return .none }
        isRecording = false
        lastAction = time
        return .cancel
    }

    /// Escape: cancels dictation that's on.
    public nonisolated mutating func escape() -> Action {
        guard isRecording else { return .none }
        isRecording = false
        if var press {
            press.handled = true
            self.press = press
        }
        return .cancel
    }

    /// Dictation started another way, such as the microphone button.
    public nonisolated mutating func recordingStarted() { isRecording = true }

    /// Dictation stopped another way: the button, an error, or the window losing focus.
    public nonisolated mutating func recordingEnded() {
        isRecording = false
        if var press {
            press.handled = true
            self.press = press
        }
    }

    /// Forgets a press in progress, such as when the window stops being key while the key is down.
    public nonisolated mutating func reset() {
        press = nil
    }

    private nonisolated mutating func start(at time: TimeInterval) -> Action {
        isRecording = true
        lastAction = time
        return .start
    }

    private nonisolated mutating func stop(at time: TimeInterval) -> Action {
        isRecording = false
        lastAction = time
        return .stop
    }
}
