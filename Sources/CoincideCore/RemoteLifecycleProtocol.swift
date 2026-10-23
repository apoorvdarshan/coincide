import Foundation

public enum RemoteLifecycleProtocol {
    public static let readMethod = "remoteEnvironment.lifecycle.read"
    public static let maximumResultBytes = 262_144
    public static func validDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    public static func payload<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    public static func same<T: Encodable>(_ lhs: T, _ rhs: T) -> Bool {
        guard let left = try? payload(lhs), let right = try? payload(rhs) else { return false }
        return left == right
    }
}

public struct RemoteLifecycleReadRequest: Codable, Sendable, Equatable {
    public let environmentID: UUID
    public let target: RemoteWorkspaceTarget?
    public init(environmentID: UUID, target: RemoteWorkspaceTarget? = nil) { self.environmentID = environmentID; self.target = target }
}

/// An opaque, immutable host claim. Incarnations remain in the owned host cache;
/// an arbitrary client-authored UUID or digest never grants thread authority.
public struct RemoteLifecycleCapture: Codable, Sendable, Equatable, Identifiable {
    private struct Payload: Codable, Sendable, Equatable { let id: UUID; let digest: String; let target: RemoteWorkspaceTarget }
    private let storage: [Payload]
    public var id: UUID { storage[0].id }
    public var digest: String { storage[0].digest }
    public var target: RemoteWorkspaceTarget { storage[0].target }
    public init(id: UUID, digest: String, target: RemoteWorkspaceTarget) { storage = [.init(id: id, digest: digest, target: target)] }
    public init(from decoder: any Decoder) throws { storage = [try Payload(from: decoder)] }
    public func encode(to encoder: any Encoder) throws { try storage[0].encode(to: encoder) }
}

public enum RemoteLifecycleAction: Codable, Sendable, Equatable {
    /// Discover the native settle role; execution still requires a later review approval.
    case settleReviewingScript
    /// A deliberate opt-out from cleanup-script review, never the normal script path.
    case settleWithoutScript
    case resume(generationID: UUID)
    case snooze(until: Date)
    case wake
    case setAutoSettle(enabled: Bool)
    public var requiresBoundRoot: Bool {
        switch self { case .settleReviewingScript, .settleWithoutScript, .resume: true; default: false }
    }
}

public struct RemoteLifecycleThreadState: Codable, Sendable, Equatable {
    private struct Payload: Codable, Sendable, Equatable {
        let capture: RemoteLifecycleCapture
        let lifecycle: ThreadWorkspaceLifecycle?
        let settlementID: UUID?
        let settlementPhase: ThreadSettlementPhase?
        let settle, resume, snooze, wake: RemoteProjectionAvailability
    }
    private let storage: [Payload]
    public var capture: RemoteLifecycleCapture { storage[0].capture }
    public var lifecycle: ThreadWorkspaceLifecycle? { storage[0].lifecycle }
    public var settlementID: UUID? { storage[0].settlementID }
    public var settlementPhase: ThreadSettlementPhase? { storage[0].settlementPhase }
    public var settle: RemoteProjectionAvailability { storage[0].settle }
    public var resume: RemoteProjectionAvailability { storage[0].resume }
    public var snooze: RemoteProjectionAvailability { storage[0].snooze }
    public var wake: RemoteProjectionAvailability { storage[0].wake }
    public init(capture: RemoteLifecycleCapture, lifecycle: ThreadWorkspaceLifecycle?, settlementID: UUID?, settlementPhase: ThreadSettlementPhase?,
                settle: RemoteProjectionAvailability, resume: RemoteProjectionAvailability, snooze: RemoteProjectionAvailability, wake: RemoteProjectionAvailability) {
        storage = [.init(capture: capture, lifecycle: lifecycle, settlementID: settlementID, settlementPhase: settlementPhase,
            settle: settle, resume: resume, snooze: snooze, wake: wake)]
    }
    public init(from decoder: any Decoder) throws { storage = [try Payload(from: decoder)] }
    public func encode(to encoder: any Encoder) throws { try storage[0].encode(to: encoder) }
}

public struct RemoteLifecycleReadResult: Codable, Sendable, Equatable {
    public let environmentID: UUID
    public let sequence: Int64
    public let policy: WorkspaceLifecyclePolicy
    public let thread: RemoteLifecycleThreadState?
    public init(environmentID: UUID, sequence: Int64, policy: WorkspaceLifecyclePolicy, thread: RemoteLifecycleThreadState? = nil) {
        self.environmentID = environmentID; self.sequence = sequence; self.policy = policy; self.thread = thread
    }
}

public struct RemoteLifecycleFailure: Error, Codable, Sendable, Equatable, LocalizedError {
    public enum Kind: String, Codable, Sendable { case invalidTarget, staleCapture, invalidRequest, unavailable, busy, limitExceeded }
    public let kind: Kind
    public init(_ kind: Kind) { self.kind = kind }
    public var errorDescription: String? {
        switch kind {
        case .invalidTarget: "This remote conversation or environment changed."
        case .staleCapture: "The remote conversation changed. Refresh its controls before trying again."
        case .invalidRequest: "Choose a valid remote lifecycle action or settlement policy."
        case .unavailable: "The remote conversation controls are unavailable."
        case .busy: "Finish the work holding this remote workspace before continuing."
        case .limitExceeded: "The remote conversation controls exceeded a limit."
        }
    }
}
