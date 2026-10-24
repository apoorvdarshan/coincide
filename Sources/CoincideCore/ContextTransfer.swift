import CryptoKit
import Foundation

/// A source is resolved once at review time. A checkpoint source is an after-run
/// observation; before-run baselines retain their separate rewind semantics.
public enum ContextTransferSourcePoint: Codable, Sendable, Equatable {
    /// Coincide's visible saved transcript, including imported messages that
    /// have no native run or checkpoint attribution.
    case conversation
    case latestStable
    case run(UUID)
    case checkpoint(runID: UUID, attemptID: UUID, digest: String)
}
public struct ContextTransferResolvedPoint: Codable, Sendable, Equatable {
    public let threadID: UUID
    public let runID: UUID?
    public let checkpointAttemptID: UUID?
    public let checkpointDigest: String?
    public init(threadID: UUID, runID: UUID?, checkpointAttemptID: UUID? = nil, checkpointDigest: String? = nil) {
        self.threadID = threadID; self.runID = runID; self.checkpointAttemptID = checkpointAttemptID; self.checkpointDigest = checkpointDigest
    }
    var source: ContextTransferSourcePoint {
        guard let runID else { return .conversation }
        if let checkpointAttemptID { return .checkpoint(runID: runID, attemptID: checkpointAttemptID, digest: checkpointDigest ?? "") }
        return .run(runID)
    }
}
public enum ContextTransferIntent: Codable, Sendable, Equatable {
    case fork(destination: ProviderConfiguration)
    case providerHandoff(destination: ProviderConfiguration)
    case mergeBack(targetConfiguration: ProviderConfiguration)
}
public enum ContextTransferKind: String, Codable, Sendable { case fork, providerHandoff, mergeBack }
public enum ContextTransferStrategy: String, Codable, Sendable { case nativeFork, portableContext, deltaContext, forkDeltaContext }
public enum ContextTransferStatus: String, Codable, Sendable { case pending, resolvedNative, resolvedPortable, consumed, failed, superseded, uncertain }
public enum ContextTransferDeliveryStatus: String, Codable, Sendable { case reserved, dispatching, delivered, uncertain }
public struct ContextTransferLineage: Codable, Sendable, Equatable {
    public let parentThreadID: UUID
    public let rootThreadID: UUID
    public let transferID: UUID
    public let basePoint: ContextTransferResolvedPoint
    public init(parentThreadID: UUID, rootThreadID: UUID, transferID: UUID, basePoint: ContextTransferResolvedPoint) {
        self.parentThreadID = parentThreadID; self.rootThreadID = rootThreadID; self.transferID = transferID; self.basePoint = basePoint
    }
}
public struct ContextTransferProviderBinding: Codable, Sendable, Equatable {
    public let configuration: ProviderConfiguration
    public let knownItemIDs: [String]
    public let updatedAt: Date
    public init(configuration: ProviderConfiguration, knownItemIDs: [String], updatedAt: Date) {
        self.configuration = configuration; self.knownItemIDs = knownItemIDs; self.updatedAt = updatedAt
    }
}
public struct ContextTransferPendingReference: Codable, Sendable, Equatable {
    public let id: UUID
    public let digest: String
    public init(id: UUID, digest: String) { self.id = id; self.digest = digest }
}
public struct ContextTransferReviewRequest: Codable, Sendable, Equatable {
    public let sourceThreadID: UUID
    public let expectedConfiguration: ProviderConfiguration
    public let sourcePoint: ContextTransferSourcePoint
    public let intent: ContextTransferIntent
    public init(sourceThreadID: UUID, expectedConfiguration: ProviderConfiguration, sourcePoint: ContextTransferSourcePoint = .latestStable, intent: ContextTransferIntent) {
        self.sourceThreadID = sourceThreadID; self.expectedConfiguration = expectedConfiguration; self.sourcePoint = sourcePoint; self.intent = intent
    }
}
/// Host-owned immutable archive. Remote adapters publish bounded display leases,
/// never accept a caller-supplied native review or source transcript.
public struct ContextTransferReview: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public internal(set) var digest: String
    public let request: ContextTransferReviewRequest
    public let sourcePoint: ContextTransferResolvedPoint
    public let basePoint: ContextTransferResolvedPoint?
    public let targetThreadID: UUID
    public let projectID: UUID
    public let sourceConfiguration: ProviderConfiguration
    public let targetConfiguration: ProviderConfiguration
    public let targetProviderBinding: ContextTransferProviderBinding?
    public let strategy: ContextTransferStrategy
    public let title: String
    public let messages: [ContextHandoffMessage]
    public let nativeReview: ConversationHistoryReview?
    public let sourceFingerprint: String
    public let sourceIncarnation: UUID
    public let targetIncarnation: UUID?
    public let reviewedAt: Date
    public internal(set) var pendingSourceTransfers: [ContextTransferPendingReference]? = nil
    public var kind: ContextTransferKind {
        switch request.intent { case .fork: .fork; case .providerHandoff: .providerHandoff; case .mergeBack: .mergeBack }
    }
}
public struct ContextTransfer: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let commandID: UUID
    public let review: ContextTransferReview
    public var status: ContextTransferStatus
    public var targetRunID: UUID?
    public var delivery: ContextTransferDelivery?
    public var error: String?
    public var updatedAt: Date
    public var abandonedAt: Date? = nil
    public var sourceThreadID: UUID { review.request.sourceThreadID }
    public var targetThreadID: UUID { review.targetThreadID }
}
/// The delivery marker precedes native fork/injection. An ambiguous dispatch is
/// never automatically retried, including after process loss.
public struct ContextTransferDelivery: Codable, Sendable, Equatable {
    // This value lives inside queued, active and archived runs. Native fork
    // proofs must not inflate every CodingThread copy and validator stack frame.
    // Array's copy-on-write storage preserves independent snapshot mutations.
    private struct Payload: Codable, Sendable, Equatable {
        var id: UUID
        var runID: UUID
        var transferIDs: [UUID]
        var selection: ContextHandoffSelection
        var status: ContextTransferDeliveryStatus
        var runtimeID: UUID?
        var nativeThreadID: String?
        var nativeResult: ProviderConversationSnapshot?
        var claudePublication: ClaudeTranscriptPublication?
        var authoredText: String?
        var authoredAttachments: [ChatAttachment]?
        var eligibleItemIDs: [String]?
        var error: String?
    }
    private var storage: [Payload]
    public var id: UUID { storage[0].id }
    public var runID: UUID { storage[0].runID }
    public var transferIDs: [UUID] { storage[0].transferIDs }
    public internal(set) var selection: ContextHandoffSelection { get { storage[0].selection } set { storage[0].selection = newValue } }
    public var status: ContextTransferDeliveryStatus { get { storage[0].status } set { storage[0].status = newValue } }
    public var runtimeID: UUID? { get { storage[0].runtimeID } set { storage[0].runtimeID = newValue } }
    public var nativeThreadID: String? { get { storage[0].nativeThreadID } set { storage[0].nativeThreadID = newValue } }
    public var nativeResult: ProviderConversationSnapshot? { get { storage[0].nativeResult } set { storage[0].nativeResult = newValue } }
    public var claudePublication: ClaudeTranscriptPublication? { get { storage[0].claudePublication } set { storage[0].claudePublication = newValue } }
    public var authoredText: String? { get { storage[0].authoredText } set { storage[0].authoredText = newValue } }
    public var authoredAttachments: [ChatAttachment]? { get { storage[0].authoredAttachments } set { storage[0].authoredAttachments = newValue } }
    public var eligibleItemIDs: [String]? { get { storage[0].eligibleItemIDs } set { storage[0].eligibleItemIDs = newValue } }
    public var error: String? { get { storage[0].error } set { storage[0].error = newValue } }
    public init(id: UUID, runID: UUID, transferIDs: [UUID], selection: ContextHandoffSelection, status: ContextTransferDeliveryStatus,
                runtimeID: UUID? = nil, nativeThreadID: String? = nil, nativeResult: ProviderConversationSnapshot? = nil,
                claudePublication: ClaudeTranscriptPublication? = nil, authoredText: String? = nil,
                authoredAttachments: [ChatAttachment]? = nil, eligibleItemIDs: [String]? = nil, error: String? = nil) {
        storage = [.init(id: id, runID: runID, transferIDs: transferIDs, selection: selection, status: status,
            runtimeID: runtimeID, nativeThreadID: nativeThreadID, nativeResult: nativeResult, claudePublication: claudePublication,
            authoredText: authoredText, authoredAttachments: authoredAttachments, eligibleItemIDs: eligibleItemIDs, error: error)]
    }
    public init(from decoder: any Decoder) throws { storage = [try Payload(from: decoder)] }
    public func encode(to encoder: any Encoder) throws { try storage[0].encode(to: encoder) }
}
public enum ContextTransferError: Error, LocalizedError, Sendable, Equatable {
    case invalidSource, staleReview, unavailable, limit, uncertain
    public var errorDescription: String? {
        switch self {
        case .invalidSource: "This context source is unavailable or does not belong to this conversation."
        case .staleReview: "The source, destination, or reviewed context changed. Review it again."
        case .unavailable: "This context transfer cannot run while the conversation is busy or held."
        case .limit: "This context exceeds the immutable transfer storage limit."
        case .uncertain: "Context delivery may have occurred. Inspect the saved outcome before using a fresh conversation."
        }
    }
}
public enum ContextTransferProtocol {
    public static let maximumArchiveBytes = 64 * 1_024 * 1_024
    public static let maximumReviewBytes = 128 * 1_024 * 1_024
    public static let maximumReviews = 8
    public static let maximumStoredTransfers = 4_096
    public static let maximumStoredArchiveBytes = 256 * 1_024 * 1_024
    public static func payload<T: Encodable>(_ value: T) throws -> Data { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; return try e.encode(value) }
    public static func digest<T: Encodable>(_ value: T) throws -> String { SHA256.hash(data: try payload(value)).map { String(format: "%02x", $0) }.joined() }
    public static func same<T: Encodable>(_ lhs: T, _ rhs: T) -> Bool { (try? payload(lhs)) == (try? payload(rhs)) }
}
