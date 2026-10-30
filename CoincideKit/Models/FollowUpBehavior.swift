import Foundation

/// What sending does while the agent works, as T3 Code's `followUpBehavior`: steer the message into the running turn,
/// queue it for after the turn, or interrupt the turn and send it now. The alternate send does the other for one
/// message. Each thread keeps its own (`ChatThread.followUpBehavior`); the last one picked is the default for new
/// threads (`AppSettings.followUpBehavior`).
public enum FollowUpBehavior: String, Codable, CaseIterable, Sendable {
    case steer
    case queue
    case interrupt

    public nonisolated var displayName: String {
        switch self {
        case .steer: String(localized: "Steer")
        case .queue: String(localized: "Queue")
        case .interrupt: String(localized: "Interrupt")
        }
    }

    /// The other behavior, which the alternate send uses: steer and queue swap, and an interrupt waits instead.
    public nonisolated var opposite: FollowUpBehavior {
        switch self {
        case .steer: .queue
        case .queue: .steer
        case .interrupt: .queue
        }
    }
}
