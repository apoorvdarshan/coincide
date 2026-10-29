import Foundation

/// What a phone tells the Mac about itself (`RemoteRequest.presence`), so the Mac can send an alert where the user
/// is: to the phone in their hand rather than the Mac they walked away from.
///
/// The phone sends it when it connects, when the app moves between foreground and background, when the open thread
/// changes, and every `RemotePresence.heartbeat` while in front, so a phone that went away without saying so (the
/// socket dropped mid-lock) stops counting as active after `RemotePresence.lifetime`.
public struct RemotePresence: Codable, Hashable, Sendable {
    public enum State: String, Codable, Sendable {
        /// In front and taking input.
        case active
        /// On screen but not taking input: the app switcher, Notification Center pulled down, an incoming call.
        case inactive
        case background
        /// A state a newer phone added.
        case unknown

        public init(from decoder: Decoder) throws {
            self = State(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
        }
    }

    public var state: State
    /// The thread on screen, if any.
    public var openThreadID: UUID?
    /// Seconds since the user last touched the app. Relative rather than a date, so the two clocks needn't agree.
    public var idleSeconds: Double
    /// The CloudKit zone this phone receives lock-screen alerts in. Set only while the user has "Notify this iPhone
    /// when it's locked" turned on, notifications are allowed and the subscription is in place; nil means off.
    public var alertZone: String?

    public init(state: State, openThreadID: UUID? = nil, idleSeconds: Double = 0, alertZone: String? = nil) {
        self.state = state
        self.openThreadID = openThreadID
        self.idleSeconds = idleSeconds
        self.alertZone = alertZone
    }

    /// How often a phone in front repeats its presence.
    public static let heartbeat: TimeInterval = 30
    /// How long the Mac trusts a presence it hasn't heard again.
    public static let lifetime: TimeInterval = 75
}

/// An alert the Mac sends to the phone in use (`RemoteEvent.notify`), worded on the Mac.
public struct RemoteNotification: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case completed
        case failed
        case approval
        case question
        case unknown

        public init(from decoder: Decoder) throws {
            self = Kind(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
        }
    }

    /// The event's stable id (`RemoteAlerts.eventID`): the notification's identifier on every device and path, so a
    /// repeat replaces instead of adding a second one.
    public var id: String
    public var threadID: UUID
    public var kind: Kind
    /// The thread's title.
    public var title: String
    /// What happened, such as "Codex finished in coincide".
    public var subtitle: String
    /// A line of detail.
    public var body: String?

    public init(id: String, threadID: UUID, kind: Kind, title: String, subtitle: String, body: String? = nil) {
        self.id = id
        self.threadID = threadID
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.body = body
    }
}

/// Names shared by the Mac, which writes lock-screen alerts to the user's private CloudKit database, and the phone,
/// which subscribes to them. Nothing else is stored there, and no server or key of Coincide's is involved.
public enum RemoteAlerts {
    public static let containerIdentifier = "iCloud.com.apoorvdarshan.coincide"
    public static let recordType = "CoincideAlert"
    public static let category = "COINCIDE_ALERT"

    public enum Field {
        public static let eventID = "eventID"
        public static let threadID = "threadID"
        public static let title = "title"
        public static let subtitle = "subtitle"
        public static let body = "body"
        public static let collapseID = "collapseID"
        public static let createdAt = "createdAt"
    }

    /// Each phone gets its own zone, so an alert written for one phone rings only that phone.
    public static func zoneName(installID: String) -> String { "alerts-\(installID)" }

    /// The phone's "Notify this iPhone when it's locked" setting, in its user defaults. Off until the user turns it on.
    public static let lockScreenAlertsKey = "lockScreenAlerts"

    public static func lockScreenAlertsEnabled(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: lockScreenAlertsKey) as? Bool ?? false
    }

    /// The id of an event worth an alert: its thread, its kind and the transcript item it is about (the approval or
    /// question, or the turn's last item), so the same event always gets the same id and a different one never does.
    public static func eventID(threadID: UUID, kind: RemoteNotification.Kind, itemID: UUID) -> String {
        "\(threadID.uuidString).\(kind.rawValue).\(itemID.uuidString)"
    }

    /// The thread an event id belongs to.
    public static func threadID(ofEvent eventID: String) -> UUID? {
        eventID.split(separator: ".").first.flatMap { UUID(uuidString: String($0)) }
    }

    /// APNs collapse ids are at most 64 bytes, shorter than an event id.
    public static func collapseID(eventID: String) -> String {
        String(RemoteCrypto.sha256Hex(eventID).prefix(40))
    }
}
