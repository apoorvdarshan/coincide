import Foundation

/// Automatic fetch cadence. T3's default is 30 seconds for checkouts someone is looking at.
public enum GitAutomaticFetchInterval: Int, Codable, Sendable, CaseIterable, Identifiable {
    case off = 0, seconds30 = 30, minute1 = 60, minutes5 = 300, minutes15 = 900
    public var id: Int { rawValue }
    public var duration: Duration? { self == .off ? nil : .seconds(rawValue) }
    public var title: String {
        switch self {
        case .off: String(localized: "Off")
        case .seconds30: String(localized: "Every 30 seconds")
        case .minute1: String(localized: "Every minute")
        case .minutes5: String(localized: "Every 5 minutes")
        case .minutes15: String(localized: "Every 15 minutes")
        }
    }
}

/// Per-project auto-pull choice layered over the global default.
public enum GitAutoPullOverride: String, Codable, Sendable, CaseIterable, Identifiable {
    case inherit, enabled, disabled
    public var id: String { rawValue }
    public func resolve(default value: Bool) -> Bool { self == .inherit ? value : self == .enabled }
}

public struct GitSyncObservation: Sendable, Equatable {
    public var branch: String?
    public var hasUpstream: Bool
    public var ahead: Int?
    public var behind: Int?
    public var isClean: Bool
    public var isDetached: Bool
    public var isUnborn: Bool
    public init(branch: String?, hasUpstream: Bool, ahead: Int?, behind: Int?, isClean: Bool, isDetached: Bool = false, isUnborn: Bool = false) {
        self.branch = branch; self.hasUpstream = hasUpstream; self.ahead = ahead; self.behind = behind; self.isClean = isClean
        self.isDetached = isDetached; self.isUnborn = isUnborn
    }
    public init(_ snapshot: GitSnapshot) {
        self.init(branch: snapshot.isDetached ? nil : snapshot.branch, hasUpstream: snapshot.upstream != nil, ahead: snapshot.ahead, behind: snapshot.behind,
                  isClean: snapshot.isClean, isDetached: snapshot.isDetached, isUnborn: snapshot.isUnborn)
    }
}

public enum GitSyncPolicy {
    public enum PullDecision: Sendable, Equatable {
        case pull
        case skip(Reason)
        public enum Reason: String, Sendable { case disabled, noUpstream, notDefaultBranch, detached, dirty, ahead, upToDate, unknownTracking }
    }

    /// T3's maybeAutoPull: upstream, not ahead, behind, on the default branch, no working-tree changes.
    public static func pullDecision(_ observation: GitSyncObservation, defaultBranch: String?, enabled: Bool) -> PullDecision {
        guard enabled else { return .skip(.disabled) }
        guard !observation.isDetached, !observation.isUnborn, let branch = observation.branch else { return .skip(.detached) }
        guard observation.hasUpstream else { return .skip(.noUpstream) }
        guard let ahead = observation.ahead, let behind = observation.behind else { return .skip(.unknownTracking) }
        guard ahead == 0 else { return .skip(.ahead) }
        guard behind > 0 else { return .skip(.upToDate) }
        guard let defaultBranch, branch == defaultBranch else { return .skip(.notDefaultBranch) }
        guard observation.isClean else { return .skip(.dirty) }
        return .pull
    }

    public static let failureBaseDelay = Duration.seconds(30)
    public static let failureMaximumDelay = Duration.seconds(15 * 60)

    /// After consecutive failures, wait at least the configured interval and back off exponentially to 15 minutes.
    public static func nextDelay(interval: Duration, consecutiveFailures: Int) -> Duration {
        guard consecutiveFailures > 0 else { return interval }
        let exponent = min(consecutiveFailures - 1, 16)
        let backoff = min(failureBaseDelay * (1 << exponent), failureMaximumDelay)
        return max(interval, backoff)
    }
}
