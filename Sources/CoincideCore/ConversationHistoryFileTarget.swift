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
            if provider == .pi {
                guard let runtime = piConfiguration?.runtimeIdentity, let evidence = record.pi,
                      record.configuration.piConfiguration?.runtimeIdentity == runtime, evidence.runtimeIdentity == runtime,
                      evidence.runID == record.id, evidence.nativeSessionFile == record.providerThreadID,
                      evidence.preparation.openingInput.clientMessageID == record.userMessageID else { return false }
                return record.configuration.nativeThreadID == nil || record.configuration.nativeThreadID == evidence.nativeSessionFile
            }
            if provider == .claude {
                guard let runtime = claudeRuntimeConfiguration, let evidence = record.claude,
                      record.configuration.claudeRuntimeConfiguration?.runtimeIdentity == runtime.runtimeIdentity,
                      evidence.runtimeIdentity == runtime.runtimeIdentity, evidence.nativeSessionID == record.providerThreadID,
                      evidence.openingInputID == ClaudeInputIdentity.opening(runID: record.id),
                      record.providerThreadID != nil else { return false }
                return record.configuration.nativeThreadID == nil || record.configuration.nativeThreadID == record.providerThreadID
            }
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
        if let evidence = review.pi {
            return piConversationHistoryFileTarget(for: review, evidence: evidence, thread: thread,
                includingRemovedByHistoryOperationID: operationID)
        }
        if let evidence = review.claude {
            guard evidence.source.matchesBinding(.init(thread: thread)) else { return .unavailable(.workspaceChanged) }
            if operationID != nil {
                guard operationID == review.id, let operation = conversationHistoryOperation(review.id), operation.review == review,
                      operation.phase == .applied, let selection = operation.result?.claude?.selection,
                      thread.providerThreadID == selection.nativeSessionID, thread.claudeResumeSelection == selection,
                      thread.claudeResumeConsumerRunID == nil else { return .unavailable(.workspaceChanged) }
                try operation.validate()
            } else {
                guard thread.providerThreadID == evidence.source.reference.nativeThreadID,
                      thread.claudeResumeSelection == evidence.source.selection else { return .unavailable(.workspaceChanged) }
            }
            var verified = Set<UUID>()
            for input in evidence.inputs {
                guard let record = thread.runHistory?.first(where: { $0.id == input.runID }), let original = record.claude,
                      record.origin == .user, record.messageAttributionVersion == 1,
                      record.configuration.provider == .claude, evidence.source.matchesBinding(record.configuration),
                      original.runtimeIdentity == evidence.source.runtimeIdentity,
                      original.nativeSessionID == evidence.source.reference.nativeThreadID,
                      record.providerThreadID == original.nativeSessionID,
                      original.openingInputID == input.openingInputID,
                      original.rootAssistantMessageIDs == input.rootAssistantMessageIDs,
                      input.steeringInputs.allSatisfy({ original.steeringInputs.contains($0) }) else { return .unavailable(.workspaceChanged) }
                try original.validate(); verified.insert(record.id)
            }
            // The original scope-zero baseline survives a confirmed fresh reset.
            // Follow only this logical thread's exact applied native selections;
            // never rewrite a historical run's original provider reference.
            if let original = thread.runHistory?.first, !verified.contains(original.id), let captured = original.claude,
               captured.runtimeIdentity == evidence.source.runtimeIdentity, original.providerThreadID == captured.nativeSessionID,
               original.configuration.provider == .claude, evidence.source.matchesBinding(original.configuration),
               let start = captured.nativeSessionID {
                var current = start, seen = Set<String>()
                while current != evidence.source.reference.nativeThreadID, seen.insert(current).inserted, seen.count <= 10_000 {
                    let successors = (conversationHistoryOperations ?? []).filter { prior in
                        prior.phase == .applied && prior.review.sourceThreadID == thread.id && prior.review.kind == .rewindBeforeRun &&
                            prior.review.claude?.source.runtimeIdentity == evidence.source.runtimeIdentity &&
                            prior.review.sourceReference.nativeThreadID == current && prior.result?.reference.nativeThreadID != current &&
                            prior.result?.claude?.selection?.kind == .freshSession
                    }
                    guard successors.count == 1, let next = successors[0].result?.reference.nativeThreadID else { break }
                    try successors[0].validate(); current = next
                }
                if current == evidence.source.reference.nativeThreadID,
                   (start == current || (conversationHistoryOperations ?? []).contains(where: {
                       $0.phase == .applied && $0.review.sourceThreadID == thread.id &&
                           $0.review.claude?.source.runtimeIdentity == captured.runtimeIdentity &&
                           $0.review.claude?.inputs.contains(where: { $0.runID == original.id && $0.openingInputID == captured.openingInputID }) == true
                   })) { verified.insert(original.id) }
            }
            return thread.conversationHistoryFileTarget(beforeRunID: review.runID,
                includingRemovedByHistoryOperationID: operationID, verifiedNativeRunIDs: verified)
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

    private func piConversationHistoryFileTarget(for review: ConversationHistoryReview, evidence: PiHistoryReviewEvidence,
        thread: CodingThread, includingRemovedByHistoryOperationID operationID: UUID?) -> ConversationHistoryFileTargetResolution {
        guard evidence.source.matchesBinding(.init(thread: thread)) else { return .unavailable(.workspaceChanged) }
        do {
            if let operationID {
                guard operationID == review.id, let operation = conversationHistoryOperation(operationID), operation.review == review,
                      operation.phase == .applied, let result = operation.result?.pi,
                      thread.providerThreadID == result.reference.nativeThreadID,
                      thread.piFreshSessionIntent == result.freshIntent, thread.piFreshConsumerRunID == nil else {
                    return .unavailable(.workspaceChanged)
                }
                try operation.validate()
            } else {
                guard thread.providerThreadID == evidence.source.reference.nativeThreadID,
                      thread.piFreshSessionIntent == evidence.source.freshIntent, thread.piFreshConsumerRunID == nil else {
                    return .unavailable(.workspaceChanged)
                }
            }
            var verified = Set<UUID>()
            for input in evidence.inputs {
                guard let record = thread.runHistory?.first(where: { $0.id == input.runID }), let proof = record.pi,
                      record.origin == .user, record.messageAttributionVersion == 1,
                      record.configuration.provider == .pi, evidence.source.matchesBinding(record.configuration),
                      record.id == proof.runID, record.providerThreadID == proof.nativeSessionFile,
                      proof.runtimeIdentity == evidence.source.runtimeIdentity,
                      proof.preparation.openingInput.clientMessageID == record.userMessageID else { return .unavailable(.workspaceChanged) }
                try proof.validate()
                let original = try PiHistoryRunInput(runID: record.id, nativeSessionFile: proof.nativeSessionFile,
                    inputs: proof.inputs, captureStatus: proof.captureStatus, baselineLeafID: proof.preparation.baseline.leafID,
                    finalLeafID: proof.finalObservation?.leafID)
                guard input == original else { return .unavailable(.workspaceChanged) }
                _ = try PiHistoryProofValidation.lineage(owner: original, proof: proof, current: evidence.source,
                    snapshot: self, threadID: thread.id)
                verified.insert(record.id)
            }

            // A scope-zero baseline can outlive removal of its opening run.
            // Follow only exact applied rewinds in this logical conversation;
            // the immutable original file/input record is never rewritten.
            if let original = thread.runHistory?.first, !verified.contains(original.id), let proof = original.pi,
               original.origin == .user, original.messageAttributionVersion == 1, original.configuration.nativeThreadID == nil,
               original.configuration.provider == .pi, evidence.source.matchesBinding(original.configuration),
               original.id == proof.runID, original.providerThreadID == proof.nativeSessionFile,
               proof.runtimeIdentity == evidence.source.runtimeIdentity,
               proof.preparation.openingInput.clientMessageID == original.userMessageID {
                try proof.validate()
                let owner = try PiHistoryRunInput(runID: original.id, nativeSessionFile: proof.nativeSessionFile,
                    inputs: proof.inputs, captureStatus: proof.captureStatus, baselineLeafID: proof.preparation.baseline.leafID,
                    finalLeafID: proof.finalObservation?.leafID)
                var unchangedOriginalScope = false
                if let removingID = original.removedByHistoryOperationID, let removing = conversationHistoryOperation(removingID),
                   removing.phase == .applied, removing.review.kind == .rewindBeforeRun,
                   removing.review.sourceThreadID == thread.id, removing.review.removedRunIDs.contains(original.id),
                   let captured = removing.review.pi, captured.source.runtimeIdentity == evidence.source.runtimeIdentity,
                   captured.boundary == .head, captured.inputs.contains(owner), proof.captureStatus == .noNativeChange,
                   removing.result?.pi?.snapshot == captured.source {
                    try removing.validate()
                    _ = try PiHistoryProofValidation.lineage(owner: owner, proof: proof, current: captured.source,
                        snapshot: self, threadID: thread.id)
                    unchangedOriginalScope = true
                }
                var current = proof.nativeSessionFile, seen = Set<String>(), first = true
                while current != evidence.source.reference.nativeThreadID, seen.insert(current).inserted, seen.count <= 256 {
                    let edges = (conversationHistoryOperations ?? []).filter { prior in
                        prior.phase == .applied && prior.review.sourceThreadID == thread.id && prior.review.kind == .rewindBeforeRun &&
                            prior.review.pi?.source.runtimeIdentity == evidence.source.runtimeIdentity &&
                            prior.review.sourceReference.nativeThreadID == current && prior.result?.reference.nativeThreadID != current &&
                            (!first || unchangedOriginalScope || prior.review.pi?.inputs.contains(owner) == true)
                    }
                    guard edges.count == 1, let next = edges[0].result?.pi?.snapshot.reference.nativeThreadID else { break }
                    try edges[0].validate(); current = next; first = false
                }
                if current == evidence.source.reference.nativeThreadID, !first || unchangedOriginalScope {
                    if first {
                        _ = try PiHistoryProofValidation.lineage(owner: owner, proof: proof, current: evidence.source,
                            snapshot: self, threadID: thread.id)
                    }
                    verified.insert(original.id)
                }
            }
            return thread.conversationHistoryFileTarget(beforeRunID: review.runID,
                includingRemovedByHistoryOperationID: operationID, verifiedNativeRunIDs: verified)
        } catch {
            return .unavailable(.workspaceChanged)
        }
    }
}
