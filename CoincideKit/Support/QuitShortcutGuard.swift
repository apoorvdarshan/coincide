import Foundation

/// Decides when ⌘Q quits with "Hold ⌘Q to quit" on (`AppSettings.holdToQuit`), as Chrome's warn-before-quit does: a
/// single press only shows a hint, and Coincide quits once ⌘Q is held for `holdDuration` or pressed again within
/// `doublePressWindow` of the first press. Only the keyboard shortcut goes through it; Quit from the menu, the Dock,
/// logging out and AppleScript quit at once.
///
/// It is a plain state machine fed the key events and the time, so the app drives it from its event monitor and a
/// timer, and tests drive it with made-up times.
public struct QuitShortcutGuard: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        /// Nothing changes.
        case none
        /// Show the hint ("Hold ⌘Q to quit") and start drawing the hold's progress.
        case showHint
        /// Hide the hint: the chance to quit has passed.
        case hideHint
        /// Quit now.
        case quit
    }

    private enum State: Equatable, Sendable {
        case idle
        /// ⌘Q is down, since the time given.
        case holding(since: TimeInterval)
        /// ⌘Q was pressed at the time given and let go; pressing it again soon quits.
        case released(firstPress: TimeInterval)
        /// It asked to quit. The key repeating while ⌘Q is still held, as while the "agents still working"
        /// confirmation shows, never asks again; only a new press does.
        case quitting
    }

    public static let defaultHoldDuration: TimeInterval = 1
    public static let defaultDoublePressWindow: TimeInterval = 1.5

    public let holdDuration: TimeInterval
    public let doublePressWindow: TimeInterval
    private var state: State = .idle

    public nonisolated init(
        holdDuration: TimeInterval = Self.defaultHoldDuration, doublePressWindow: TimeInterval = Self.defaultDoublePressWindow
    ) {
        self.holdDuration = holdDuration
        self.doublePressWindow = doublePressWindow
    }

    /// Whether ⌘Q is being held toward quitting.
    public nonisolated var isHolding: Bool {
        if case .holding = state { return true }
        return false
    }

    /// Whether the hint should show: ⌘Q is held, or was pressed and can still be pressed again to quit.
    public nonisolated var showsHint: Bool {
        switch state {
        case .holding, .released: true
        case .idle, .quitting: false
        }
    }

    /// How far the hold has got toward quitting, from 0 to 1. 0 when ⌘Q is not held.
    public nonisolated func holdProgress(at now: TimeInterval) -> Double {
        guard case .holding(let since) = state, holdDuration > 0 else { return 0 }
        return min(1, max(0, (now - since) / holdDuration))
    }

    /// ⌘Q went down. `isRepeat` is true for the key repeating while it is held.
    public nonisolated mutating func keyDown(at now: TimeInterval, isRepeat: Bool) -> Action {
        switch state {
        case .quitting where isRepeat:
            return .none
        case .holding(let since):
            return now - since >= holdDuration ? quit() : .none
        case .released(let firstPress) where !isRepeat && now - firstPress <= doublePressWindow:
            return quit()
        case .idle, .released, .quitting:
            // A repeat with no press seen (it went down while a menu was open) starts a hold too, and a new press after
            // quitting was asked for (and cancelled) starts over even if the key's release went unseen.
            state = .holding(since: now)
            return .showHint
        }
    }

    /// ⌘Q was let go: the Q key or Command came up.
    public nonisolated mutating func keyUp(at now: TimeInterval) -> Action {
        switch state {
        case .holding(let since):
            if now - since >= holdDuration { return quit() }
            state = .released(firstPress: since)
            return .none
        case .quitting:
            state = .idle
            return .none
        case .idle, .released:
            return .none
        }
    }

    /// Time passed: called often while the hint shows, to quit once the hold is long enough and to hide the hint once
    /// a second press would no longer quit.
    public nonisolated mutating func tick(at now: TimeInterval) -> Action {
        switch state {
        case .holding(let since) where now - since >= holdDuration:
            return quit()
        case .released(let firstPress) where now - firstPress > doublePressWindow:
            state = .idle
            return .hideHint
        default:
            return .none
        }
    }

    /// Stops waiting, as when Coincide stops being the active app.
    public nonisolated mutating func cancel() -> Action {
        let wasShowing = showsHint
        state = .idle
        return wasShowing ? .hideHint : .none
    }

    private nonisolated mutating func quit() -> Action {
        state = .quitting
        return .quit
    }
}
