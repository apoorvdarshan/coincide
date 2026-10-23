import Foundation

/// A destination grant obtained from the private allocator, never from a
/// transcript link or an operation DTO. Native provider acknowledgment remains
/// independent of this filesystem ownership record.
public struct ScratchHistoryForkGrant: Codable, Sendable, Equatable {
    private final class Storage: Codable, Sendable {
        let operationID: UUID
        let source: ScratchWorkspaceReceipt
        let allocation: ScratchWorkspaceAllocation
        let heldAcknowledgment: ProviderConversationSnapshot?
        init(operationID: UUID, source: ScratchWorkspaceReceipt, allocation: ScratchWorkspaceAllocation,
             heldAcknowledgment: ProviderConversationSnapshot?) {
            self.operationID = operationID; self.source = source; self.allocation = allocation
            self.heldAcknowledgment = heldAcknowledgment
        }
    }
    private let storage: Storage
    public var operationID: UUID { storage.operationID }
    public var source: ScratchWorkspaceReceipt { storage.source }
    public var allocation: ScratchWorkspaceAllocation { storage.allocation }
    public var heldAcknowledgment: ProviderConversationSnapshot? { storage.heldAcknowledgment }
    init(operationID: UUID, source: ScratchWorkspaceReceipt, allocation: ScratchWorkspaceAllocation) {
        storage = .init(operationID: operationID, source: source, allocation: allocation, heldAcknowledgment: nil)
    }
    private init(storage: Storage) { self.storage = storage }
    func holding(_ acknowledgment: ProviderConversationSnapshot) -> Self {
        .init(storage: .init(operationID: operationID, source: source, allocation: allocation, heldAcknowledgment: acknowledgment))
    }
    func validate(review: ConversationHistoryReview) throws {
        let receipt = allocation.receipt
        guard review.kind == .forkAfterRun, operationID == review.id,
              source.threadID == review.sourceThreadID, receipt.threadID == review.targetThreadID,
              receipt.threadID != source.threadID, allocation.project.id == review.projectID,
              receipt.project == source.project, receipt.identity == source.identity,
              receipt.sharedFrom == (source.sharedFrom ?? source.commandID),
              source.workspacePath.utf8.elementsEqual(review.sourceConfiguration.workspacePath.utf8),
              allocation.workspacePath.utf8.elementsEqual(review.targetConfiguration.workspacePath.utf8),
              allocation.workspacePath.utf8.elementsEqual(source.workspacePath.utf8) else { throw ScratchWorkspaceError() }
        if let heldAcknowledgment { try review.validateResult(heldAcknowledgment) }
    }
    public init(from decoder: any Decoder) throws { storage = try Storage(from: decoder) }
    public func encode(to encoder: any Encoder) throws { try storage.encode(to: encoder) }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.operationID == rhs.operationID && lhs.source == rhs.source && lhs.allocation == rhs.allocation &&
        lhs.heldAcknowledgment == rhs.heldAcknowledgment
    }
}

/// An owned SDK reply whose destination can no longer pass physical admission.
/// Keeping it records the observation without publishing a child or retrying it.
struct ScratchHistoryForkHeldResult: Codable, Sendable {
    private final class Storage: Codable, Sendable {
        let request: WorkspaceEffectRequest
        let acknowledgment: ProviderConversationSnapshot
        let incarnation: UUID
        init(request: WorkspaceEffectRequest, acknowledgment: ProviderConversationSnapshot, incarnation: UUID) {
            self.request = request; self.acknowledgment = acknowledgment; self.incarnation = incarnation
        }
    }
    private let storage: Storage
    var request: WorkspaceEffectRequest { storage.request }
    var acknowledgment: ProviderConversationSnapshot { storage.acknowledgment }
    var incarnation: UUID { storage.incarnation }
    init(request: WorkspaceEffectRequest, acknowledgment: ProviderConversationSnapshot, incarnation: UUID) {
        storage = .init(request: request, acknowledgment: acknowledgment, incarnation: incarnation)
    }
    init(from decoder: any Decoder) throws { storage = try Storage(from: decoder) }
    func encode(to encoder: any Encoder) throws { try storage.encode(to: encoder) }
}

extension WorkspaceDecision {
    mutating func holdScratchHistoryFork(_ held: ScratchHistoryForkHeldResult, now: Date) {
        guard case .conversationHistory(let threadID, let operationID) = held.request,
              let index = snapshot.conversationHistoryOperations?.firstIndex(where: { $0.id == operationID }),
              var operation = snapshot.conversationHistoryOperations?[index], operation.phase == .dispatching,
              operation.review.sourceThreadID == threadID, operation.review.sourceIncarnation == held.incarnation,
              let grant = operation.scratchFork else { return }
        do {
            try operation.review.validateResult(held.acknowledgment)
            operation.scratchFork = grant.holding(held.acknowledgment)
            operation.phase = .unconfirmed; operation.result = nil
            operation.error = ConversationHistoryOperation.unconfirmedMessage; operation.updatedAt = now
            operation.piControls = nil
            try operation.validate()
            snapshot.conversationHistoryOperations?[index] = operation
        } catch {
            finishConversationHistory(held.request, result: .conversationHistoryUnconfirmed, incarnation: held.incarnation, now: now)
        }
    }
}
