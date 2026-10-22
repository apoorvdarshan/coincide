import Foundation

/// The saved workspace observation associated with a local rewind boundary.
/// This is audit evidence, not proof that the current on-disk checkout is unchanged.
/// A restore review must still verify this exact receipt through the Git service.
public struct ConversationHistoryFileTarget: Codable, Sendable, Equatable {
    public let selectedRunID: UUID
    public let checkpointRunID: UUID
    public let stage: RunCheckpointStage
    public let attemptID: UUID
    public let receipt: GitCheckpointReceipt
    public var workspacePath: String { receipt.plan.workspacePath }

    public init(selectedRunID: UUID, checkpointRunID: UUID, stage: RunCheckpointStage,
                attemptID: UUID, receipt: GitCheckpointReceipt) throws {
        self.selectedRunID = selectedRunID; self.checkpointRunID = checkpointRunID
        self.stage = stage; self.attemptID = attemptID; self.receipt = receipt
        try validate()
    }

    public func validate() throws {
        try receipt.validate()
        guard attemptID == receipt.plan.id, attemptID != selectedRunID, attemptID != checkpointRunID,
              stage != .postRun || checkpointRunID != selectedRunID else {
            throw CoincideError("The rewind file target has inconsistent run or checkpoint ownership.")
        }
    }

    private enum CodingKeys: String, CodingKey { case selectedRunID, checkpointRunID, stage, attemptID, receipt }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(selectedRunID: c.decode(UUID.self, forKey: .selectedRunID),
                      checkpointRunID: c.decode(UUID.self, forKey: .checkpointRunID),
                      stage: c.decode(RunCheckpointStage.self, forKey: .stage),
                      attemptID: c.decode(UUID.self, forKey: .attemptID),
                      receipt: c.decode(GitCheckpointReceipt.self, forKey: .receipt))
    }
}

public enum ConversationHistoryFileTargetUnavailableReason: String, Codable, Sendable, Equatable {
    case missingRun, removedRun, unsupportedBoundary, ambiguousBoundary, unsettledWorkspace
    case workspaceChanged, previousPostUnavailable, originalBaselineUnavailable, invalidCheckpoint

    public var message: String {
        switch self {
        case .missingRun: "This run is no longer present in the conversation audit."
        case .removedRun: "This run is already outside the visible conversation."
        case .unsupportedBoundary: "This run has no verified local user-input boundary."
        case .ambiguousBoundary: "The visible run order cannot be matched to an exact workspace observation."
        case .unsettledWorkspace: "Finish current work, queued messages, questions and workspace preparation first."
        case .workspaceChanged: "The saved observation belongs to another checkout or provider conversation."
        case .previousPostUnavailable: "The previous visible run has no ready final workspace observation."
        case .originalBaselineUnavailable: "The original first-input workspace baseline cannot be proven."
        case .invalidCheckpoint: "The saved checkpoint evidence is inconsistent or unavailable."
        }
    }
}

public enum ConversationHistoryFileTargetResolution: Codable, Sendable, Equatable {
    case available(ConversationHistoryFileTarget)
    case unavailable(ConversationHistoryFileTargetUnavailableReason)
}

extension CodingThread {
    /// Resolves T3's previous-visible-run boundary, using the original scope-zero
    /// baseline only when no visible local run precedes the selected input.
    /// The optional projection is for revalidating an already applied rewind's
    /// own retained audit. The caller must separately prove operation ownership.
    public func conversationHistoryFileTarget(beforeRunID selectedRunID: UUID,
        includingRemovedByHistoryOperationID operationID: UUID? = nil) -> ConversationHistoryFileTargetResolution {
        conversationHistoryFileTarget(beforeRunID: selectedRunID, includingRemovedByHistoryOperationID: operationID,
                                      verifiedNativeRunIDs: [])
    }

    func conversationHistoryFileTarget(beforeRunID selectedRunID: UUID,
        includingRemovedByHistoryOperationID operationID: UUID?, verifiedNativeRunIDs: Set<UUID>) -> ConversationHistoryFileTargetResolution {
        var projected = self
        if let operationID {
            for index in projected.messages.indices where projected.messages[index].removedByHistoryOperationID == operationID {
                projected.messages[index].removedByHistoryOperationID = nil
            }
            if projected.runHistory != nil {
                for index in projected.runHistory!.indices where projected.runHistory![index].removedByHistoryOperationID == operationID {
                    projected.runHistory![index].removedByHistoryOperationID = nil
                }
            }
        }
        return projected.resolveConversationHistoryFileTarget(beforeRunID: selectedRunID, verifiedNativeRunIDs: verifiedNativeRunIDs)
    }

    private func resolveConversationHistoryFileTarget(beforeRunID selectedRunID: UUID,
                                                      verifiedNativeRunIDs: Set<UUID>) -> ConversationHistoryFileTargetResolution {
        let retained = runHistory ?? []
        guard let selected = retained.first(where: { $0.id == selectedRunID }) else { return .unavailable(.missingRun) }
        guard selected.removedByHistoryOperationID == nil else { return .unavailable(.removedRun) }
        guard !isArchived, !isBusy, queuedTurns.isEmpty, runtimeRequests.isEmpty, settlement == nil,
              heldPostRunCheckpoint == nil, workspacePreparation?.isReady ?? true,
              workspacePreparation?.setup.map({ [.succeeded, .skipped].contains($0.phase) }) ?? true else {
            return .unavailable(.unsettledWorkspace)
        }
        guard selected.origin == .user, selected.messageAttributionVersion == 1,
              selected.status.isTerminal, selected.status != .unknown else { return .unavailable(.unsupportedBoundary) }
        guard hasCurrentFileTargetOwnership(selected, verifiedNativeRunIDs: verifiedNativeRunIDs) else { return .unavailable(.workspaceChanged) }
        do {
            try validateRunHistory()
            guard Set(messages.map(\.id)).count == messages.count else { return .unavailable(.ambiguousBoundary) }
            _ = try transcriptPrefix(runID: selectedRunID, boundary: .beforeRun)
        } catch { return .unavailable(.ambiguousBoundary) }

        let records = activeHistoryRuns
        guard let selectedIndex = records.firstIndex(where: { $0.id == selectedRunID }) else { return .unavailable(.missingRun) }
        let visible = visibleMessages
        let order = Dictionary(uniqueKeysWithValues: records.enumerated().map { ($0.element.id, $0.offset) })
        var lastOrder = -1
        for message in visible {
            guard let reference = message.runReference, reference.threadID == id else { continue }
            guard let index = order[reference.runID], index >= lastOrder else { return .unavailable(.ambiguousBoundary) }
            lastOrder = index
        }
        if selectedIndex > 0 {
            let previous = records[selectedIndex - 1]
            guard previous.messageAttributionVersion == 1, previous.origin != .legacy,
                  previous.status.isTerminal, previous.status != .unknown,
                  visible.contains(where: { $0.runReference == .init(threadID: id, runID: previous.id) }) else {
                return .unavailable(.ambiguousBoundary)
            }
            guard hasCurrentFileTargetOwnership(previous, verifiedNativeRunIDs: verifiedNativeRunIDs) else { return .unavailable(.workspaceChanged) }
            guard let checkpoints = previous.checkpoints, checkpoints.providerReleased,
                  let attempt = (checkpoints.previousPostRunAttempts + (checkpoints.postRun.map { [$0] } ?? [])).last(where: { $0.phase == .ready }) else {
                return .unavailable(.previousPostUnavailable)
            }
            return fileTarget(selectedRunID: selectedRunID, record: previous, stage: .postRun, attempt: attempt)
        }

        // Scope zero survives rewinds. Never replace it with a newer run's own
        // baseline: edits between turns make those different workspace states.
        guard forkedFromHistoryOperationID == nil, let original = retained.first,
              original.origin == .user, original.messageAttributionVersion == 1,
              original.status.isTerminal, original.status != .unknown,
              original.configuration.nativeThreadID == nil,
              let opening = messages.first, opening.id == original.userMessageID, opening.role == .user,
              opening.runReference == .init(threadID: id, runID: original.id),
              hasCurrentFileTargetOwnership(original, verifiedNativeRunIDs: verifiedNativeRunIDs), let checkpoints = original.checkpoints,
              checkpoints.providerReleased, checkpoints.pendingStart == nil,
              checkpoints.baseline.phase == .ready, !checkpoints.baseline.isLaterObservation else {
            return .unavailable(.originalBaselineUnavailable)
        }
        return fileTarget(selectedRunID: selectedRunID, record: original, stage: .baseline, attempt: checkpoints.baseline)
    }

    private func hasCurrentFileTargetOwnership(_ record: ThreadRunRecord, verifiedNativeRunIDs: Set<UUID>) -> Bool {
        guard let nativeID = providerThreadID, !nativeID.isEmpty,
              record.configuration.provider == provider,
              record.configuration.workspacePath == workspacePath else { return false }
        if verifiedNativeRunIDs.contains(record.id) {
            guard provider == .opencode, openCodeConfiguration?.generation == .v1,
                  record.configuration.openCodeConfiguration?.runtimeIdentity == openCodeConfiguration?.runtimeIdentity,
                  let originalID = record.providerThreadID, !originalID.isEmpty else { return false }
            return record.configuration.nativeThreadID == nil || record.configuration.nativeThreadID == originalID
        }
        guard record.providerThreadID == nativeID else { return false }
        return record.configuration.nativeThreadID == nil || record.configuration.nativeThreadID == nativeID
    }

    private func fileTarget(selectedRunID: UUID, record: ThreadRunRecord, stage: RunCheckpointStage,
                            attempt: ThreadRunCheckpointAttempt) -> ConversationHistoryFileTargetResolution {
        do {
            try attempt.validate(workspacePath: workspacePath)
            guard attempt.phase == .ready, let receipt = attempt.receipt else { return .unavailable(.invalidCheckpoint) }
            return .available(try .init(selectedRunID: selectedRunID, checkpointRunID: record.id, stage: stage,
                                        attemptID: attempt.id, receipt: receipt))
        } catch { return .unavailable(.invalidCheckpoint) }
    }
}

extension WorkspaceSnapshot {
    /// Only a reviewed V1 native-copy proof may retain checkpoints whose immutable
    /// run references precede adoption of the current native conversation.
    func conversationHistoryFileTarget(for review: ConversationHistoryReview,
        includingRemovedByHistoryOperationID operationID: UUID? = nil) throws -> ConversationHistoryFileTargetResolution {
        try review.validate()
        guard let thread = threads.first(where: { $0.id == review.sourceThreadID && $0.projectID == review.projectID }) else {
            return .unavailable(.missingRun)
        }
        guard let evidence = review.openCodeV1 else {
            return thread.conversationHistoryFileTarget(beforeRunID: review.runID, includingRemovedByHistoryOperationID: operationID)
        }
        guard thread.provider == .opencode, thread.openCodeConfiguration?.runtimeIdentity == evidence.source.runtimeIdentity,
              thread.workspacePath == evidence.source.workspacePath else { return .unavailable(.workspaceChanged) }
        if thread.providerThreadID != review.sourceReference.nativeThreadID {
            guard operationID == review.id, let operation = conversationHistoryOperation(review.id), operation.review == review,
                  operation.phase == .applied, operation.result?.reference.nativeThreadID == thread.providerThreadID else {
                return .unavailable(.workspaceChanged)
            }
            try operation.validate()
        }
        var verified = Set<UUID>()
        for input in evidence.inputs {
            guard let record = thread.runHistory?.first(where: { $0.id == input.runID }), record.origin == .user,
                  record.messageAttributionVersion == 1, record.configuration.provider == .opencode,
                  record.configuration.openCodeConfiguration?.runtimeIdentity == evidence.source.runtimeIdentity,
                  record.configuration.workspacePath == evidence.source.workspacePath,
                  record.providerThreadID == input.originalReference.nativeThreadID,
                  record.turnIDs == [input.originalMessageID] else { return .unavailable(.workspaceChanged) }
            verified.insert(record.id)
        }
        return thread.conversationHistoryFileTarget(beforeRunID: review.runID,
            includingRemovedByHistoryOperationID: operationID, verifiedNativeRunIDs: verified)
    }
}
