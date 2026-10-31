import AppKit
import CoincideRemoteKit
import CoreGraphics
import Foundation

/// Where an alert goes. Exactly one of these per event.
enum NotificationRoute: Equatable {
    /// A notification on this Mac.
    case mac
    /// The connected phone or iPad, by device id, which shows it in the app.
    case device(String)
    /// A lock-screen alert through the user's private CloudKit database, for a phone that isn't connected or in front.
    case push(PushTarget)
    /// Nowhere: the user is looking at the thread on the device that would have shown it.
    case none
}

/// The user at this Mac: whether Coincide is in front, how long since any input, the thread on screen, and whether the
/// screen is locked or asleep (then nobody is at it, however recent the last input).
struct MacActivity: Equatable {
    var isAppActive: Bool
    /// Seconds since the last keyboard, mouse or trackpad input in any app.
    var idleSeconds: TimeInterval
    var visibleThreadID: UUID?
    var isScreenLocked = false
    var isDisplayAsleep = false

    /// Someone at the Mac: input within `threshold`, on an unlocked, awake screen.
    func isUserActive(threshold: TimeInterval = NotificationRouting.macIdleThreshold) -> Bool {
        idleSeconds < threshold && !isScreenLocked && !isDisplayAsleep
    }

    static func current(visibleThreadID: UUID?) -> MacActivity {
        // Any input event type; reading it needs no permission.
        let anyInput = CGEventType(rawValue: UInt32.max) ?? .null
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        let locked = session?["CGSSessionScreenIsLocked"] as? Bool ?? false
        return MacActivity(
            isAppActive: NSApp.isActive, idleSeconds: idle, visibleThreadID: visibleThreadID, isScreenLocked: locked,
            isDisplayAsleep: CGDisplayIsAsleep(CGMainDisplayID()) != 0)
    }

    /// What connected phones hear (`RemoteMacPresence`), so they stay quiet while the user is here.
    var remote: RemoteMacPresence { RemoteMacPresence(isActive: isUserActive(), idleSeconds: idleSeconds) }
}

/// A connected phone's latest presence, as the Mac keeps it.
struct DevicePresence: Equatable {
    var deviceID: String
    var state: RemotePresence.State
    var openThreadID: UUID?
    /// When the user last touched the phone, in the Mac's clock.
    var lastInteraction: Date
    /// When the phone last said so.
    var updatedAt: Date

    init(deviceID: String, presence: RemotePresence, receivedAt: Date) {
        self.deviceID = deviceID
        state = presence.state
        openThreadID = presence.openThreadID
        lastInteraction = receivedAt.addingTimeInterval(-max(0, presence.idleSeconds))
        updatedAt = receivedAt
    }

    /// In front, taking input, and heard from recently enough to trust.
    func isForeground(at now: Date) -> Bool {
        state == .active && now.timeIntervalSince(updatedAt) <= RemotePresence.lifetime
    }
}

/// A phone that turned on lock-screen alerts, as the Mac remembers it across connections and launches.
struct PushTarget: Codable, Equatable {
    var deviceID: String
    /// Its CloudKit zone (`RemotePresence.alertZone`).
    var zone: String
    /// When it was last in front.
    var lastActiveAt: Date
}

/// Decides where an alert goes. A pure function of what the Mac knows, so the whole table is tested.
///
/// - The Mac in use (input in the last two minutes, unlocked and awake) gets it, even with a phone in front: an iPhone
///   notification would reach the Mac anyway through iPhone Mirroring, so it would show twice.
/// - A phone in front, with the Mac idle, locked or asleep, gets it in the app.
/// - Neither in use: a phone that turned on lock-screen alerts and was in use lately gets it through CloudKit;
///   otherwise the Mac does.
/// - The device that would show it stays quiet when it has the thread open and on screen; nothing else does instead.
enum NotificationRouting {
    /// The Mac's user counts as away after this long without input.
    static let macIdleThreshold: TimeInterval = 120
    /// A phone gets lock-screen alerts only if it was in front this recently, so a phone left in a drawer doesn't.
    static let pushRecency: TimeInterval = 4 * 60 * 60

    static func route(
        threadID: UUID, mac: MacActivity, devices: [DevicePresence], pushTargets: [PushTarget] = [],
        pushAvailable: Bool = false, now: Date, idleThreshold: TimeInterval = macIdleThreshold,
        pushRecency: TimeInterval = pushRecency
    ) -> NotificationRoute {
        let macRoute: NotificationRoute = mac.isAppActive && mac.visibleThreadID == threadID ? .none : .mac
        if mac.isUserActive(threshold: idleThreshold) { return macRoute }
        let foreground = devices.filter { $0.isForeground(at: now) }
        if let phone = foreground.max(by: { $0.lastInteraction < $1.lastInteraction }) {
            return phone.openThreadID == threadID ? .none : .device(phone.deviceID)
        }
        if let target = pushTarget(
            pushTargets, connected: devices, pushAvailable: pushAvailable, now: now, recency: pushRecency)
        {
            return .push(target)
        }
        return macRoute
    }

    /// Whether to write a CloudKit alert, and for which phone: CloudKit works on this Mac, the phone turned the alerts
    /// on, isn't in front now, and was in front within `recency`. The most recently used such phone wins.
    static func pushTarget(
        _ targets: [PushTarget], connected: [DevicePresence], pushAvailable: Bool, now: Date,
        recency: TimeInterval = pushRecency
    ) -> PushTarget? {
        guard pushAvailable else { return nil }
        let inFront = Set(connected.filter { $0.isForeground(at: now) }.map(\.deviceID))
        return targets
            .filter { !inFront.contains($0.deviceID) && !$0.zone.isEmpty && now.timeIntervalSince($0.lastActiveAt) <= recency }
            .max { $0.lastActiveAt < $1.lastActiveAt }
    }
}

/// The events this Mac already sent somewhere, so none is sent twice: not when the agent host hands a session back,
/// a phone reconnects, a transcript replays or Coincide relaunches. Kept on disk for `lifetime`.
final class NotificationLedger {
    static let lifetime: TimeInterval = 24 * 60 * 60

    private let url: URL?
    private let lifetime: TimeInterval
    private let now: () -> Date
    private var entries: [String: Date]

    init(url: URL?, lifetime: TimeInterval = NotificationLedger.lifetime, now: @escaping () -> Date = Date.init) {
        self.url = url
        self.lifetime = lifetime
        self.now = now
        if let url, let data = try? Data(contentsOf: url),
            let saved = try? JSONDecoder().decode([String: Date].self, from: data)
        {
            entries = saved
        } else {
            entries = [:]
        }
        prune()
    }

    /// Records the event; false when it was already recorded, so the caller sends nothing.
    func claim(_ eventID: String) -> Bool {
        prune()
        guard entries[eventID] == nil else { return false }
        entries[eventID] = now()
        save()
        return true
    }

    func contains(_ eventID: String) -> Bool { entries[eventID] != nil }

    private func prune() {
        let cutoff = now().addingTimeInterval(-lifetime)
        entries = entries.filter { $0.value >= cutoff }
    }

    private func save() {
        guard let url else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(entries).write(to: url, options: .atomic)
        } catch {
            NSLog("Coincide: couldn’t save the notification ledger: \(error.localizedDescription)")
        }
    }
}

/// An event worth an alert, worded for the user.
struct AlertContent: Equatable {
    /// `RemoteAlerts.eventID`: the same on every device and path.
    var id: String
    var threadID: UUID
    var kind: RemoteNotification.Kind
    var title: String
    var subtitle: String
    var body: String?

    var remote: RemoteNotification {
        RemoteNotification(id: id, threadID: threadID, kind: kind, title: title, subtitle: subtitle, body: body)
    }
}

/// Sends each alert exactly once, to the one place `NotificationRouting` picks, falling back to the Mac when the
/// phone can't take it.
final class NotificationDispatcher {
    struct Environment {
        /// The Mac's "Notify…" setting, the master switch for every path.
        var isEnabled: () -> Bool
        var macActivity: () -> MacActivity
        var devices: () -> [DevicePresence]
        var pushTargets: () -> [PushTarget]
        var postMac: (AlertContent) -> Void
        /// Sends to the device's live connection; false when it's gone.
        var sendLive: (RemoteNotification, String) -> Bool
        var now: () -> Date = Date.init
    }

    let ledger: NotificationLedger
    let push: PushAlertDelivery?
    var environment: Environment

    init(ledger: NotificationLedger, push: PushAlertDelivery?, environment: Environment) {
        self.ledger = ledger
        self.push = push
        self.environment = environment
    }

    /// Routes the alert, unless it was routed before. Returns where it went, or nil when it was a repeat or
    /// notifications are off.
    @discardableResult
    func dispatch(_ alert: AlertContent) -> NotificationRoute? {
        guard environment.isEnabled(), ledger.claim(alert.id) else { return nil }
        let now = environment.now()
        let route = NotificationRouting.route(
            threadID: alert.threadID, mac: environment.macActivity(), devices: environment.devices(),
            pushTargets: environment.pushTargets(), pushAvailable: push?.isAvailable ?? false, now: now)
        switch route {
        case .none:
            break
        case .mac:
            environment.postMac(alert)
        case .device(let deviceID):
            // The connection dropped between deciding and sending: the Mac, once, rather than a retry that could
            // arrive twice.
            if !environment.sendLive(alert.remote, deviceID) { environment.postMac(alert) }
        case .push(let target):
            let postMac = environment.postMac
            push?.deliver(PushAlert(alert, zone: target.zone, createdAt: now)) { postMac(alert) }
        }
        return route
    }

    /// The user saw the thread somewhere: stop a lock-screen alert still being written, and remove written ones.
    func threadSeen(_ threadID: UUID) {
        push?.threadSeen(threadID)
    }
}
