import Foundation

/// T3's ⌘Q protection (QuitHold.ts) as a pure reducer over key events and timers.
/// "Still held" is proven by key auto-repeat, not by the absence of a release: macOS
/// suppresses the Q key-up while ⌘ is down. Choosing Quit from the menu bypasses it.
public struct QuitShortcutStateMachine: Sendable {
    public enum Mode: String, CaseIterable, Identifiable, Sendable {
        case hold, doublePress, direct
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .hold: String(localized: "Hold or press twice")
            case .doublePress: String(localized: "Press twice")
            case .direct: String(localized: "Quit immediately")
            }
        }
    }
    public enum Effect: Sendable, Equatable {
        case showHint(Mode)
        case hideHint
        /// Replaces any pending timer; deliver `.timer(token)` after the delay.
        case schedule(token: UInt64, milliseconds: Int)
        case cancelTimer
        case quit
    }
    public enum Input: Sendable, Equatable {
        /// `command`: ⌘ is held; `otherModifiers`: ⌥, ⇧ or ⌃ is held.
        case keyDown(isQ: Bool, command: Bool, otherModifiers: Bool, isRepeat: Bool)
        case qKeyUp
        case commandReleased
        /// Window, modal, input-method or shortcut ownership changed.
        case cancel
        case timer(UInt64)
    }
    public struct Output: Sendable, Equatable {
        public var consumed = false
        public var effects: [Effect] = []
    }
    public static let holdMilliseconds: Int64 = 1_200
    public static let doublePressMilliseconds: Int64 = 500
    public static let releaseGraceMilliseconds: Int64 = 600
    public static let repeatCadenceMultiplier: Int64 = 2

    private enum TimerAction: Sendable { case release, quit }
    private var holding = false
    private var notified = false
    private var armed = false
    private var quitOnRelease = false
    private var visibleMode: Mode?
    private var heldSince: Int64 = 0
    private var lastPressAt: Int64?
    private var lastRepeatAt: Int64?
    private var repeatCadence: Int64 = 0
    private var timerToken: UInt64 = 0
    private var timerAction: TimerAction?

    public init() {}
    public var isShowingHint: Bool { notified }

    /// `now` is a monotonic time in milliseconds.
    public mutating func handle(_ input: Input, mode: Mode, now: Int64) -> Output {
        var output = Output()
        switch input {
        case .cancel:
            lastPressAt = nil
            release(&output)
            timerToken &+= 1
        case .timer(let token):
            guard token == timerToken, let action = timerAction else { return output }
            timerAction = nil
            switch action {
            case .release: release(&output)
            case .quit: quitNow(&output)
            }
        case .qKeyUp:
            let shouldQuit = quitOnRelease
            release(&output, keepDoublePressHint: true)
            if shouldQuit { output.effects.append(.quit) }
        case .commandReleased:
            if quitOnRelease { quitAfterQuietPeriod(&output) } else { release(&output, keepDoublePressHint: true) }
        case let .keyDown(isQ, command, otherModifiers, isRepeat):
            if isRepeat && command && isQ {
                repeatCadence = now - (lastRepeatAt ?? heldSince)
                lastRepeatAt = now
            }
            if quitOnRelease {
                output.consumed = true
                if isQ { quitAfterQuietPeriod(&output) }
                return output
            }
            guard command, !otherModifiers, isQ else {
                // A fresh unrelated key also follows a Q key-up that macOS did not deliver.
                if !isRepeat { lastPressAt = nil; release(&output) }
                return output
            }
            output.consumed = true
            if isRepeat {
                if mode == .hold, armed, now - heldSince >= Self.holdMilliseconds {
                    armed = false; quitOnRelease = true
                    quitAfterQuietPeriod(&output)
                }
                return output
            }
            let previous = lastPressAt
            lastPressAt = now
            if holding || notified { release(&output) }
            if mode == .direct || previous.map({ now - $0 <= Self.doublePressMilliseconds }) == true {
                quitNow(&output); return output
            }
            holding = true; heldSince = now
            visibleMode = mode; notified = true
            output.effects.append(.showHint(mode))
            if mode == .hold {
                armed = true
                schedule(.release, after: Self.holdMilliseconds + Self.releaseGraceMilliseconds, &output)
            } else {
                schedule(.release, after: Self.doublePressMilliseconds, &output)
            }
        }
        return output
    }

    private mutating func release(_ output: inout Output, keepDoublePressHint: Bool = false) {
        guard holding || notified else { return }
        let keepHint = keepDoublePressHint && visibleMode == .doublePress && notified
        holding = false; armed = false; quitOnRelease = false; lastRepeatAt = nil; repeatCadence = 0
        if keepHint { return }
        visibleMode = nil
        if timerAction != nil { timerAction = nil; output.effects.append(.cancelTimer) }
        if notified { notified = false; output.effects.append(.hideHint) }
    }

    private mutating func quitNow(_ output: inout Output) {
        release(&output)
        lastPressAt = nil
        output.effects.append(.quit)
    }

    private mutating func quitAfterQuietPeriod(_ output: inout Output) {
        // A slow repeat rate can exceed the fixed grace; wait two observed cadences.
        schedule(.quit, after: max(Self.releaseGraceMilliseconds, repeatCadence * Self.repeatCadenceMultiplier), &output)
    }

    private mutating func schedule(_ action: TimerAction, after milliseconds: Int64, _ output: inout Output) {
        timerToken &+= 1; timerAction = action
        output.effects.append(.schedule(token: timerToken, milliseconds: Int(milliseconds)))
    }
}

/// What quitting now would interrupt. Pure so the warning text and count can be checked.
public struct QuitRunningWork: Sendable, Equatable {
    public let localConversations: Int
    public let remoteConversations: Int
    public init(localConversations: Int, remoteConversations: Int) {
        self.localConversations = localConversations; self.remoteConversations = remoteConversations
    }
    public init(snapshot: WorkspaceSnapshot, remoteConversations: Int) {
        self.init(localConversations: snapshot.threads.filter(\.isBusy).count, remoteConversations: remoteConversations)
    }
    public var total: Int { localConversations + remoteConversations }
    public var isEmpty: Bool { total == 0 }
    public var title: String {
        total == 1 ? String(localized: "Quit while a conversation is running?")
            : String(localized: "Quit while \(total) conversations are running?")
    }
    public var detail: String {
        var parts: [String] = []
        if localConversations > 0 {
            parts.append(String(localized: "Running turns on this Mac stop. Unfinished runs are marked interrupted and queued messages wait until you resume them."))
        }
        if remoteConversations > 0 {
            parts.append(String(localized: "Disconnecting from the remote environment stops its active work."))
        }
        return parts.joined(separator: " ")
    }
}
