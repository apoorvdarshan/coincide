import Foundation

/// When Coincide Remote reconnects to its Mac, and when the screen says so.
///
/// iOS tears an app's sockets down while it's suspended, so nearly every return to the app finds the connection gone
/// (`ECONNABORTED`), and a launch connects from scratch. Both reconnect quietly: the last workspace stays on screen and
/// nothing says "Connecting" or "Offline" unless the reconnect hasn't succeeded within `grace`. While the app is in the
/// background nothing shows either, so an app switch never catches a banner half drawn. A connection the system
/// dropped (`RemoteSocketError.isTransient`) is retried at once instead of after the backoff, a few times in a row
/// before backing off as for any other failure, so a Mac that keeps dropping the connection isn't hammered.
public struct RemoteReconnect: Sendable {
    /// How long a quiet reconnect may take before the screen says so. Reconnecting on the same network takes a few
    /// hundred milliseconds (TCP, TLS 1.3, the WebSocket upgrade and the hello) and over Tailscale up to about a
    /// second more; a failed first attempt is retried after one second. 2.5 seconds covers all of these, and still
    /// reports a Mac that's really gone before the wait starts to feel broken.
    public static let grace: TimeInterval = 2.5
    /// Transient failures in a row retried at once before the backoff.
    public static let immediateRetries = 3
    /// A connection up at least this long earns a fresh set of immediate retries when it drops.
    public static let stableAfter: TimeInterval = 10

    /// What to do after a failure.
    public enum Next: Sendable, Hashable {
        /// Connect again now; the connection is still on its way back, not offline.
        case retryNow
        /// Show the Mac offline and try again after this many seconds.
        case retry(after: TimeInterval)
    }

    public private(set) var isInBackground = false
    public private(set) var immediateRetriesLeft = Self.immediateRetries
    /// The wait before the next retry that isn't immediate, doubling up to half a minute.
    public private(set) var backoff: TimeInterval = 1
    /// Until when connecting and offline stay off screen, once the app is in front.
    private var quietUntil: Date?
    private var connectedAt: Date?

    public init() {}

    /// Whether connecting and offline stay off screen now.
    public func isQuiet(at now: Date) -> Bool {
        if isInBackground { return true }
        guard let quietUntil else { return false }
        return now < quietUntil
    }

    /// How long the quiet lasts from now, for a timer that ends it; nil when it isn't quiet or lasts until the app is
    /// back in front.
    public func quietRemaining(at now: Date) -> TimeInterval? {
        guard !isInBackground, let quietUntil, now < quietUntil else { return nil }
        return quietUntil.timeIntervalSince(now)
    }

    /// Connecting from scratch, as at launch: what follows stays quiet for `grace`.
    public mutating func connectingQuietly(at now: Date) {
        quietUntil = now.addingTimeInterval(Self.grace)
        startOver()
    }

    /// The app came to the front. Back from the background, where iOS has likely torn the socket down, what follows
    /// stays quiet for `grace`. After a moment inactive in front (Control Center, a system alert) the socket is as it
    /// was, and so is what the screen shows. Either way the next attempt starts afresh.
    public mutating func becameActive(at now: Date) {
        if isInBackground {
            isInBackground = false
            quietUntil = now.addingTimeInterval(Self.grace)
        }
        startOver()
    }

    /// The app went to the background: quiet until it's back in front, and then for `grace`.
    public mutating func enteredBackground() {
        isInBackground = true
    }

    /// The Mac answered the hello. A drop from here shows at once unless it's transient or the app is away.
    public mutating func connected(at now: Date) {
        quietUntil = nil
        connectedAt = now
        backoff = 1
    }

    /// Something the user must see at once, or asked for: pairing again, disconnecting, connecting or retrying by hand.
    public mutating func showNow() {
        quietUntil = nil
        startOver()
    }

    /// A connection dropped or an attempt failed. `transient`: the system dropped it (see
    /// `RemoteSocketError.isTransient`), so it goes on quietly and right away, within the budget of immediate
    /// retries; a working connection that dropped while the app is in front starts a quiet window of its own.
    public mutating func failed(transient: Bool, at now: Date) -> Next {
        if let connectedAt, now.timeIntervalSince(connectedAt) >= Self.stableAfter {
            immediateRetriesLeft = Self.immediateRetries
        }
        let wasConnected = connectedAt != nil
        connectedAt = nil
        if transient, immediateRetriesLeft > 0 {
            immediateRetriesLeft -= 1
            if wasConnected, !isQuiet(at: now) { quietUntil = now.addingTimeInterval(Self.grace) }
            return .retryNow
        }
        let delay = backoff
        backoff = min(backoff * 2, 30)
        return .retry(after: delay)
    }

    /// The immediate retries and the backoff from the beginning.
    private mutating func startOver() {
        immediateRetriesLeft = Self.immediateRetries
        backoff = 1
    }
}
