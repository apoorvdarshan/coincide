import Foundation

public enum WorkspaceSettlementOverride: String, Codable, Sendable { case settled, active }

/// Attention metadata is independent of provider execution and of the owned
/// settlement generation which must be explicitly resumed and drained.
public struct ThreadWorkspaceLifecycle: Codable, Sendable, Equatable {
    private struct Payload: Codable, Sendable, Equatable {
        var settledOverride: WorkspaceSettlementOverride?
        var unsettledAt: Date?, snoozedUntil: Date?, snoozedAt: Date?, lastSnoozeWakeAt: Date?, autoSettleDisabledAt: Date?
    }
    private var storage: [Payload]
    public var settledOverride: WorkspaceSettlementOverride? { get { storage[0].settledOverride } set { storage[0].settledOverride = newValue } }
    public var unsettledAt: Date? { get { storage[0].unsettledAt } set { storage[0].unsettledAt = newValue } }
    public var snoozedUntil: Date? { get { storage[0].snoozedUntil } set { storage[0].snoozedUntil = newValue } }
    public var snoozedAt: Date? { get { storage[0].snoozedAt } set { storage[0].snoozedAt = newValue } }
    public var lastSnoozeWakeAt: Date? { get { storage[0].lastSnoozeWakeAt } set { storage[0].lastSnoozeWakeAt = newValue } }
    public var autoSettleDisabledAt: Date? { get { storage[0].autoSettleDisabledAt } set { storage[0].autoSettleDisabledAt = newValue } }
    public init(settledOverride: WorkspaceSettlementOverride? = nil, unsettledAt: Date? = nil, snoozedUntil: Date? = nil,
                snoozedAt: Date? = nil, lastSnoozeWakeAt: Date? = nil, autoSettleDisabledAt: Date? = nil) {
        storage = [.init(settledOverride: settledOverride, unsettledAt: unsettledAt, snoozedUntil: snoozedUntil,
            snoozedAt: snoozedAt, lastSnoozeWakeAt: lastSnoozeWakeAt, autoSettleDisabledAt: autoSettleDisabledAt)]
    }
    public func validate() throws {
        guard [unsettledAt, snoozedUntil, snoozedAt, lastSnoozeWakeAt, autoSettleDisabledAt].compactMap({ $0 }).allSatisfy({ $0.timeIntervalSince1970.isFinite }),
              (snoozedUntil == nil) == (snoozedAt == nil) else { throw WorkspaceLifecycleError.invalidRequest }
    }
    public init(from decoder: any Decoder) throws { storage = [try Payload(from: decoder)]; try validate() }
    public func encode(to encoder: any Encoder) throws { try storage[0].encode(to: encoder) }
}

public struct WorkspaceLifecyclePolicy: Codable, Sendable, Equatable {
    private struct Payload: Codable, Sendable, Equatable { let afterDays: Double?; let onMerge: Bool; let keepPullRequests: Bool }
    private var storage: [Payload]
    public var afterDays: Double? { storage[0].afterDays }
    public var onMerge: Bool { storage[0].onMerge }
    public var keepPullRequests: Bool { storage[0].keepPullRequests }
    public init(afterDays: Double? = 3, onMerge: Bool = true, keepPullRequests: Bool = false) {
        storage = [.init(afterDays: afterDays, onMerge: onMerge, keepPullRequests: keepPullRequests)]
    }
    public static let disabled = Self(afterDays: nil, onMerge: false)
    public var enabled: Bool { afterDays != nil || onMerge }
    public func validate() throws { guard afterDays.map({ $0.isFinite && (1...90).contains($0) }) ?? true else { throw WorkspaceLifecycleError.invalidRequest } }
    public init(from decoder: any Decoder) throws { storage = [try Payload(from: decoder)]; try validate() }
    public func encode(to encoder: any Encoder) throws { try storage[0].encode(to: encoder) }
}

/// An exact existing app link. A shared workspace or matching branch name alone
/// does not establish which conversation owns a pull request.
public struct WorkspaceLifecyclePullRequestLink: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let reference: GitHubPullRequestReference
    public let linkedAt: Date
    public init(id: UUID, reference: GitHubPullRequestReference, linkedAt: Date) { self.id = id; self.reference = reference; self.linkedAt = linkedAt }
}
public struct WorkspaceLifecyclePullRequestObservation: Codable, Sendable, Equatable {
    public let link: WorkspaceLifecyclePullRequestLink
    public let state: GitHubPullRequestState
    public let closedAt: Date?, mergedAt: Date?
    public let observedAt: Date
    /// A new open pull request for the same captured branch prevents settling
    /// from a formerly linked terminal request.
    public let newerOpenPullRequest: Bool
    public init(link: WorkspaceLifecyclePullRequestLink, state: GitHubPullRequestState, closedAt: Date? = nil, mergedAt: Date? = nil,
                observedAt: Date, newerOpenPullRequest: Bool = false) {
        self.link = link; self.state = state; self.closedAt = closedAt; self.mergedAt = mergedAt
        self.observedAt = observedAt; self.newerOpenPullRequest = newerOpenPullRequest
    }
}

/// Small, proof-free, immutable sweep input. Native checkpoint/history/provider
/// evidence remains in the Engine; its current configuration is a digest only.
public struct ThreadWorkspaceLifecycleFacts: Codable, Sendable, Equatable, Identifiable {
    private struct Payload: Codable, Sendable, Equatable {
        let id: UUID, projectID: UUID, workspacePath: String, configurationDigest: String
        let contentDigest: String?
        let createdAt: Date, updatedAt: Date
        let latestUserMessageAt: Date?, latestUserAuthoredMessageAt: Date?, latestRunRequestedAt: Date?, latestRunStartedAt: Date?, latestRunCompletedAt: Date?, latestRunID: UUID?
        let failed: Bool, failedAt: Date?, busy: Bool, archived: Bool, pinned: Bool, pendingRequest: Bool, pendingBackgroundWork: Bool, authoredQueue: Bool, canSettle: Bool
        let lifecycle: ThreadWorkspaceLifecycle?
        let pullRequests: [WorkspaceLifecyclePullRequestLink]
    }
    private var storage: [Payload]
    public var id: UUID { storage[0].id }; public var projectID: UUID { storage[0].projectID }
    public var workspacePath: String { storage[0].workspacePath }; public var configurationDigest: String { storage[0].configurationDigest }
    public var contentDigest: String? { storage[0].contentDigest }
    public var createdAt: Date { storage[0].createdAt }; public var updatedAt: Date { storage[0].updatedAt }
    public var latestUserMessageAt: Date? { storage[0].latestUserMessageAt }; public var latestUserAuthoredMessageAt: Date? { storage[0].latestUserAuthoredMessageAt }
    public var latestRunRequestedAt: Date? { storage[0].latestRunRequestedAt }; public var latestRunStartedAt: Date? { storage[0].latestRunStartedAt }
    public var latestRunCompletedAt: Date? { storage[0].latestRunCompletedAt }; public var latestRunID: UUID? { storage[0].latestRunID }
    public var failed: Bool { storage[0].failed }; public var failedAt: Date? { storage[0].failedAt }; public var busy: Bool { storage[0].busy }
    public var archived: Bool { storage[0].archived }; public var pinned: Bool { storage[0].pinned }; public var pendingRequest: Bool { storage[0].pendingRequest }
    public var pendingBackgroundWork: Bool { storage[0].pendingBackgroundWork }; public var authoredQueue: Bool { storage[0].authoredQueue }; public var canSettle: Bool { storage[0].canSettle }
    public var lifecycle: ThreadWorkspaceLifecycle? { storage[0].lifecycle }; public var pullRequests: [WorkspaceLifecyclePullRequestLink] { storage[0].pullRequests }
    public init(id: UUID, projectID: UUID, workspacePath: String, configurationDigest: String, createdAt: Date, updatedAt: Date,
                latestUserMessageAt: Date? = nil, latestUserAuthoredMessageAt: Date? = nil, latestRunRequestedAt: Date? = nil,
                latestRunStartedAt: Date? = nil, latestRunCompletedAt: Date? = nil, latestRunID: UUID? = nil,
                failed: Bool = false, failedAt: Date? = nil, busy: Bool = false, archived: Bool = false, pinned: Bool = false,
                pendingRequest: Bool = false, pendingBackgroundWork: Bool = false, authoredQueue: Bool = false, canSettle: Bool = true,
                lifecycle: ThreadWorkspaceLifecycle? = nil, pullRequests: [WorkspaceLifecyclePullRequestLink] = [], contentDigest: String? = nil) {
        storage = [.init(id: id, projectID: projectID, workspacePath: workspacePath, configurationDigest: configurationDigest,
            contentDigest: contentDigest,
            createdAt: createdAt, updatedAt: updatedAt, latestUserMessageAt: latestUserMessageAt, latestUserAuthoredMessageAt: latestUserAuthoredMessageAt,
            latestRunRequestedAt: latestRunRequestedAt, latestRunStartedAt: latestRunStartedAt, latestRunCompletedAt: latestRunCompletedAt, latestRunID: latestRunID,
            failed: failed, failedAt: failedAt, busy: busy, archived: archived, pinned: pinned, pendingRequest: pendingRequest,
            pendingBackgroundWork: pendingBackgroundWork, authoredQueue: authoredQueue, canSettle: canSettle, lifecycle: lifecycle, pullRequests: pullRequests)]
    }
    public init(from decoder: any Decoder) throws { storage = [try Payload(from: decoder)] }
    public func encode(to encoder: any Encoder) throws { try storage[0].encode(to: encoder) }
}

public enum WorkspaceAutoSettlementReason: String, Codable, Sendable { case inactivity, closedPullRequest, mergedPullRequest }
public struct ThreadAutoSettlementProposal: Codable, Sendable, Equatable, Identifiable {
    private struct Payload: Codable, Sendable, Equatable {
        let id: UUID, threadID: UUID, projectID: UUID, workspacePath: String, expectedUpdatedAt: Date, expectedFingerprint: String
        let policy: WorkspaceLifecyclePolicy, settledAt: Date, evaluatedAt: Date, reason: WorkspaceAutoSettlementReason
        let pullRequest: WorkspaceLifecyclePullRequestObservation?
        let observations: [WorkspaceLifecyclePullRequestObservation]
        var bindingID: UUID? = nil
    }
    private var storage: [Payload]
    public var id: UUID { storage[0].id }; public var threadID: UUID { storage[0].threadID }; public var projectID: UUID { storage[0].projectID }
    public var workspacePath: String { storage[0].workspacePath }; public var expectedUpdatedAt: Date { storage[0].expectedUpdatedAt }
    public var expectedFingerprint: String { storage[0].expectedFingerprint }; public var policy: WorkspaceLifecyclePolicy { storage[0].policy }
    public var settledAt: Date { storage[0].settledAt }; public var evaluatedAt: Date { storage[0].evaluatedAt }
    public var reason: WorkspaceAutoSettlementReason { storage[0].reason }; public var pullRequest: WorkspaceLifecyclePullRequestObservation? { storage[0].pullRequest }
    public var observations: [WorkspaceLifecyclePullRequestObservation] { storage[0].observations }
    public var bindingID: UUID? { storage[0].bindingID }
    mutating func bindToSnapshot(_ id: UUID) { storage[0].bindingID = id }
    init(id: UUID = UUID(), facts: ThreadWorkspaceLifecycleFacts, policy: WorkspaceLifecyclePolicy, settledAt: Date,
         evaluatedAt: Date, reason: WorkspaceAutoSettlementReason, pullRequest: WorkspaceLifecyclePullRequestObservation?, observations: [WorkspaceLifecyclePullRequestObservation] = []) throws {
        storage = [.init(id: id, threadID: facts.id, projectID: facts.projectID, workspacePath: facts.workspacePath, expectedUpdatedAt: facts.updatedAt,
            expectedFingerprint: try ContextTransferProtocol.digest(facts), policy: policy, settledAt: settledAt, evaluatedAt: evaluatedAt,
            reason: reason, pullRequest: pullRequest, observations: observations)]
    }
    public init(from decoder: any Decoder) throws { storage = [try Payload(from: decoder)] }
    public func encode(to encoder: any Encoder) throws { try storage[0].encode(to: encoder) }
}
public indirect enum WorkspaceLifecycleAction: Codable, Sendable, Equatable {
    case snooze(threadID: UUID, until: Date)
    case wake(threadID: UUID)
    case setAutoSettle(threadID: UUID, enabled: Bool)
    case wakeExpired(WorkspaceLifecycleExpiredSnooze)
    case automaticallySettle(ThreadAutoSettlementProposal)
    public var threadID: UUID { switch self { case .snooze(let id, _), .wake(let id), .setAutoSettle(let id, _): id; case .automaticallySettle(let proposal): proposal.threadID; case .wakeExpired(let wake): wake.threadID } }
    func validateEncoding() throws {
        let dates: [Date]
        switch self {
        case .snooze(_, let until): dates = [until]
        case .wakeExpired(let wake): dates = [wake.expectedUntil, wake.expectedSnoozedAt]
        case .automaticallySettle(let proposal): dates = [proposal.expectedUpdatedAt, proposal.evaluatedAt, proposal.settledAt]
        default: dates = []
        }
        guard dates.allSatisfy({ $0.timeIntervalSince1970.isFinite }) else { throw WorkspaceLifecycleError.invalidRequest }
    }
}
public struct WorkspaceLifecycleExpiredSnooze: Codable, Sendable, Equatable, Identifiable {
    private struct Payload: Codable, Sendable, Equatable { let threadID: UUID; let expectedUntil: Date; let expectedSnoozedAt: Date }
    private var storage: [Payload]
    public var threadID: UUID { storage[0].threadID }
    public var expectedUntil: Date { storage[0].expectedUntil }
    public var expectedSnoozedAt: Date { storage[0].expectedSnoozedAt }
    public var id: UUID { TaskOrchestration.derivedID(threadID, "snooze-expired:\(expectedUntil.timeIntervalSinceReferenceDate.bitPattern):\(expectedSnoozedAt.timeIntervalSinceReferenceDate.bitPattern)") }
    public init(threadID: UUID, expectedUntil: Date, expectedSnoozedAt: Date) { storage = [.init(threadID: threadID, expectedUntil: expectedUntil, expectedSnoozedAt: expectedSnoozedAt)] }
    public init(from decoder: any Decoder) throws { storage = [try Payload(from: decoder)] }
    public func encode(to encoder: any Encoder) throws { try storage[0].encode(to: encoder) }
}
public enum WorkspaceLifecycleError: Error, LocalizedError, Sendable, Equatable {
    case invalidRequest, unavailable, stale, busy
    public var errorDescription: String? {
        switch self {
        case .invalidRequest: "Choose a valid future snooze time or an automatic settlement period from 1 to 90 days."
        case .unavailable: "This conversation is no longer available."
        case .stale: "This conversation or its settlement policy changed before the action was admitted."
        case .busy: "Finish queued input and pending questions before snoozing or settling this conversation."
        }
    }
}
