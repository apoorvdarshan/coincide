import Foundation

/// Whether the user is at the Mac (`macPresence`): input in the last two minutes on an unlocked, awake screen. While they
/// are, the phone posts no notifications of its own; the Mac notifies there, and an iPhone notification would only show
/// on the Mac a second time through iPhone Mirroring.
public struct RemoteMacPresence: Codable, Hashable, Sendable {
    public var isActive: Bool
    /// Seconds since the last keyboard, mouse or trackpad input on the Mac.
    public var idleSeconds: Double

    /// How long the phone trusts the news: the Mac repeats it every half minute, so older news means it went away.
    public static let lifetime: TimeInterval = 120

    public init(isActive: Bool, idleSeconds: Double) {
        self.isActive = isActive
        self.idleSeconds = idleSeconds
    }

    /// Whether the phone keeps an alert to itself: the Mac said recently that the user is there. No news (an older Mac,
    /// a dropped connection) or stale news means the phone notifies as before.
    public static func keepsPhoneQuiet(_ presence: RemoteMacPresence?, receivedAt: Date?, now: Date) -> Bool {
        guard let presence, presence.isActive, let receivedAt else { return false }
        return now.timeIntervalSince(receivedAt) <= lifetime
    }
}
