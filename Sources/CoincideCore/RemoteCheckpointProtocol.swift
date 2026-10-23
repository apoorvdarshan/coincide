import CryptoKit
import Foundation

public enum RemoteCheckpointProtocol {
    public static let bindMethod = "remoteEnvironment.checkpoint.bind"
    public static let readMethod = "remoteEnvironment.checkpoint.read"
    public static let reviewMethod = "remoteEnvironment.checkpoint.review"
    public static let discardMethod = "remoteEnvironment.checkpoint.discard"
    public static func payload<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    public static func digest(target: RemoteWorkspaceTarget, value: RunCheckpointRestoreReview) throws -> String {
        struct Binding: Encodable { let target: RemoteWorkspaceTarget; let value: RunCheckpointRestoreReview }
        return SHA256.hash(data: try payload(Binding(target: target, value: value))).map { String(format: "%02x", $0) }.joined()
    }
}
public enum RemoteCheckpointQuery: Codable, Sendable, Equatable {
    case inventory
    case runDiff(runID: UUID, baselineAttemptID: UUID, postRunAttemptID: UUID, maxBytes: Int)
}
public struct RemoteCheckpointReadRequest: Codable, Sendable, Equatable {
    public let target: RemoteWorkspaceTarget
    public let query: RemoteCheckpointQuery
    public init(target: RemoteWorkspaceTarget, query: RemoteCheckpointQuery) { self.target = target; self.query = query }
}
public struct RemoteCheckpointRun: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let baseline: ThreadRunCheckpointAttempt
    public let postRun: ThreadRunCheckpointAttempt?
    public let previousPostRunAttempts: [ThreadRunCheckpointAttempt]
    public let restoreUnavailableReasons: [UUID: String]
    public init(id: UUID, baseline: ThreadRunCheckpointAttempt, postRun: ThreadRunCheckpointAttempt?, previousPostRunAttempts: [ThreadRunCheckpointAttempt], restoreUnavailableReasons: [UUID: String]) {
        self.id = id; self.baseline = baseline; self.postRun = postRun
        self.previousPostRunAttempts = previousPostRunAttempts; self.restoreUnavailableReasons = restoreUnavailableReasons
    }
}
public struct RemoteCheckpointInventory: Codable, Sendable, Equatable {
    public let policy: RunCheckpointPolicy
    public let runs: [RemoteCheckpointRun]
    public init(policy: RunCheckpointPolicy, runs: [RemoteCheckpointRun]) { self.policy = policy; self.runs = runs }
}
public struct RemoteCheckpointDiff: Codable, Sendable, Equatable {
    public let runID: UUID
    public let baselineAttemptID: UUID
    public let postRunAttemptID: UUID
    public let patch: String
    public let truncated: Bool
    public init(runID: UUID, baselineAttemptID: UUID, postRunAttemptID: UUID, patch: String, truncated: Bool) {
        self.runID = runID; self.baselineAttemptID = baselineAttemptID; self.postRunAttemptID = postRunAttemptID; self.patch = patch; self.truncated = truncated
    }
}
public enum RemoteCheckpointValue: Codable, Sendable, Equatable {
    case inventory(RemoteCheckpointInventory), diff(RemoteCheckpointDiff)
}
public struct RemoteCheckpointReadResult: Codable, Sendable, Equatable {
    public let target: RemoteWorkspaceTarget
    public let value: RemoteCheckpointValue
    public init(target: RemoteWorkspaceTarget, value: RemoteCheckpointValue) { self.target = target; self.value = value }
}
public struct RemoteCheckpointReviewRequest: Codable, Sendable, Equatable {
    public let target: RemoteWorkspaceTarget
    public let runID: UUID
    public let stage: RunCheckpointStage
    public let attemptID: UUID
    public init(target: RemoteWorkspaceTarget, runID: UUID, stage: RunCheckpointStage, attemptID: UUID) {
        self.target = target; self.runID = runID; self.stage = stage; self.attemptID = attemptID
    }
}
public struct RemoteCheckpointReview: Codable, Sendable, Equatable, Identifiable {
    public let target: RemoteWorkspaceTarget
    public let id: UUID
    public let digest: String
    public let value: RunCheckpointRestoreReview
    public init(target: RemoteWorkspaceTarget, value: RunCheckpointRestoreReview) throws {
        self.target = target; self.value = value; id = value.id
        digest = try RemoteCheckpointProtocol.digest(target: target, value: value)
    }
}
public struct RemoteCheckpointDiscardRequest: Codable, Sendable, Equatable {
    public let target: RemoteWorkspaceTarget
    public let reviewID: UUID
    public let digest: String
    public init(target: RemoteWorkspaceTarget, reviewID: UUID, digest: String) { self.target = target; self.reviewID = reviewID; self.digest = digest }
}
public struct RemoteCheckpointDiscardResult: Codable, Sendable, Equatable {
    public let request: RemoteCheckpointDiscardRequest
    public let discarded: Bool
    public init(request: RemoteCheckpointDiscardRequest, discarded: Bool) { self.request = request; self.discarded = discarded }
}
public enum RemoteCheckpointAction: Codable, Sendable, Equatable {
    case beginRestore(reviewID: UUID, digest: String)
    case inspectRestore(operationID: UUID)
    case acknowledgeRestore(operationID: UUID)
    case retryPostRun(runID: UUID, attemptID: UUID)
    case continuePostRun(runID: UUID, attemptID: UUID)
    public var requiresBoundRoot: Bool {
        switch self { case .acknowledgeRestore: false; default: true }
    }
}
public struct RemoteCheckpointFailure: Error, Codable, Sendable, Equatable, LocalizedError {
    public enum Kind: String, Codable, Sendable { case invalidRequest, invalidTarget, staleReview, unavailable, busy, limitExceeded, operationFailed }
    public let kind: Kind
    public init(_ kind: Kind) { self.kind = kind }
    public var errorDescription: String? {
        switch kind {
        case .invalidRequest: "The remote checkpoint request is invalid."
        case .invalidTarget: "The remote conversation or checkout changed. Refresh before continuing."
        case .staleReview: "This restoration review changed or expired. Review the current files again."
        case .unavailable: "Remote checkpoints are unavailable."
        case .busy: "Another operation owns this remote checkout."
        case .limitExceeded: "The remote checkpoint request exceeded its limit."
        case .operationFailed: "The remote checkpoint operation failed. Inspect its saved state before continuing."
        }
    }
}
