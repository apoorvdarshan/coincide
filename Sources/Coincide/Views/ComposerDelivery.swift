import Foundation

enum ComposerFollowUpBehavior: String, CaseIterable, Identifiable {
    case queue, steer
    var id: String { rawValue }
    var title: String { self == .queue ? String(localized: "Queue") : String(localized: "Steer") }
}

enum ComposerDelivery: Equatable {
    case send, queue, steer

    static func resolve(running: Bool, preference: ComposerFollowUpBehavior, alternate: Bool,
                        canSteer: Bool) -> Self {
        guard running else { return .send }
        guard canSteer else { return .queue }
        let steer = preference == .steer
        return steer != alternate ? .steer : .queue
    }

    var label: String {
        switch self {
        case .send: String(localized: "Send message")
        case .queue: String(localized: "Queue message")
        case .steer: String(localized: "Steer current turn")
        }
    }
}
