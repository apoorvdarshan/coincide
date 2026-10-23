import Foundation

/// Decides which system activity Coincide holds while agents run. This is a native
/// enhancement beyond T3: long turns on a laptop otherwise stop when the Mac idles
/// to sleep, and App Nap can throttle streaming while windows are hidden.
public enum ActivityAssertionPolicy {
    public enum Preference: String, CaseIterable, Identifiable, Sendable {
        case never, whilePluggedIn, always
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .never: String(localized: "Never")
            case .whilePluggedIn: String(localized: "While plugged in")
            case .always: String(localized: "Always")
            }
        }
    }
    public enum PowerSource: Sendable, Equatable { case ac, battery, unknown }
    /// Ordered: a stronger level includes the weaker one.
    public enum Level: Int, Comparable, Sendable {
        case none, preventAppNap, preventIdleSleep
        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }
    public static let releaseDelay: Duration = .seconds(30)

    /// App Nap is always prevented while work runs; idle sleep follows the preference.
    /// An unknown power source (a desktop Mac) counts as plugged in.
    public static func desiredLevel(activeConversations: Int, power: PowerSource, preference: Preference) -> Level {
        guard activeConversations > 0 else { return .none }
        switch preference {
        case .never: return .preventAppNap
        case .always: return .preventIdleSleep
        case .whilePluggedIn: return power == .battery ? .preventAppNap : .preventIdleSleep
        }
    }

    /// Raises immediately; a lower level waits for `releaseDelay` so a queue moving to
    /// its next turn does not drop and retake the assertion.
    public struct Debouncer: Sendable, Equatable {
        public private(set) var held: Level = .none
        public private(set) var pendingRelease: (level: Level, at: ContinuousClock.Instant)?
        public init() {}
        public enum Decision: Sendable, Equatable { case hold(Level), waitUntil(ContinuousClock.Instant), unchanged }
        public mutating func update(desired: Level, now: ContinuousClock.Instant, delay: Duration = ActivityAssertionPolicy.releaseDelay) -> Decision {
            if desired >= held {
                pendingRelease = nil
                guard desired != held else { return .unchanged }
                held = desired; return .hold(desired)
            }
            if let pending = pendingRelease, pending.level == desired {
                guard now >= pending.at else { return .waitUntil(pending.at) }
                pendingRelease = nil; held = desired; return .hold(desired)
            }
            let at = now + delay
            pendingRelease = (desired, at)
            return .waitUntil(at)
        }
        /// Shutdown releases without waiting.
        public mutating func releaseNow() -> Decision {
            pendingRelease = nil
            guard held != .none else { return .unchanged }
            held = .none; return .hold(.none)
        }
        public static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.held == rhs.held && lhs.pendingRelease?.level == rhs.pendingRelease?.level && lhs.pendingRelease?.at == rhs.pendingRelease?.at
        }
    }
}
