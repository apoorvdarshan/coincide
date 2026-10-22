import Foundation

public struct ConversationHistoryFilesReview: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let target: ConversationHistoryFileTarget
    public let sourceFingerprint: String
    public let gitReview: GitCheckpointRestoreReview
    public init(id: UUID = UUID(), target: ConversationHistoryFileTarget, sourceFingerprint: String, gitReview: GitCheckpointRestoreReview) throws {
        self.id = id; self.target = target; self.sourceFingerprint = sourceFingerprint; self.gitReview = gitReview
        try validate()
    }
    public func validate() throws {
        try target.validate(); try gitReview.validate()
        guard id == gitReview.id, target.receipt == gitReview.targetReceipt, CheckpointValidation.digest(sourceFingerprint) else { throw CoincideError("The rewind file review has inconsistent ownership.") }
    }
}

public enum ConversationHistoryFilesPhase: String, Codable, Sendable { case waitingForProvider, accepted, dispatching, applied, failed, unconfirmed }

public struct ConversationHistoryFilesState: Codable, Sendable, Equatable {
    public let review: ConversationHistoryFilesReview
    public var phase: ConversationHistoryFilesPhase
    public var postHistorySourceFingerprint: String?
    public var updatedAt: Date
    public var result: GitCheckpointRestoreReceipt?
    public var error: String?
    public var acknowledgedAt: Date?
    public var isWorking: Bool { phase == .accepted || phase == .dispatching }
    public static let failureMessage = "Conversation history was rewound, but workspace files were not restored. Keep the current files explicitly before continuing."
    public static let unconfirmedMessage = "Conversation history was rewound; workspace files or staging may be partially changed. Inspect the restoration evidence or explicitly keep the current files. The restore was not repeated."
    public static let notStartedMessage = "Workspace restoration did not start. No file write was replayed after the interruption."
    public init(review: ConversationHistoryFilesReview, phase: ConversationHistoryFilesPhase = .waitingForProvider,
                postHistorySourceFingerprint: String? = nil, updatedAt: Date = Date(), result: GitCheckpointRestoreReceipt? = nil,
                error: String? = nil, acknowledgedAt: Date? = nil) {
        self.review = review; self.phase = phase; self.postHistorySourceFingerprint = postHistorySourceFingerprint
        self.updatedAt = updatedAt; self.result = result; self.error = error; self.acknowledgedAt = acknowledgedAt
    }
    public func validate(providerPhase: ConversationHistoryPhase) throws {
        try review.validate()
        guard updatedAt.timeIntervalSince1970.isFinite, postHistorySourceFingerprint.map(CheckpointValidation.digest) ?? true,
              (phase == .applied) == (result != nil),
              error.map({ [Self.failureMessage, Self.unconfirmedMessage, Self.notStartedMessage].contains($0) }) ?? true,
              acknowledgedAt.map({ [.failed, .unconfirmed].contains(phase) && $0.timeIntervalSince1970.isFinite }) ?? true else {
            throw CoincideError("The combined rewind's file state is inconsistent.")
        }
        guard providerPhase == .applied || phase == .waitingForProvider else { throw CoincideError("Files cannot advance before confirmed provider history.") }
        if phase != .waitingForProvider {
            guard providerPhase == .applied, postHistorySourceFingerprint != nil else { throw CoincideError("A file stage requires its confirmed provider history source.") }
        }
        if phase == .waitingForProvider { guard providerPhase != .applied, postHistorySourceFingerprint == nil, result == nil, error == nil, acknowledgedAt == nil else { throw CoincideError("A waiting file restore contains premature completion evidence.") } }
        if [.accepted, .dispatching, .applied].contains(phase) { guard error == nil, acknowledgedAt == nil else { throw CoincideError("A pending or applied file restore cannot contain a partial-failure acknowledgement.") } }
        if phase == .failed { guard error == Self.failureMessage || error == Self.notStartedMessage else { throw CoincideError("An unstarted file restore must retain its outcome.") } }
        if phase == .unconfirmed { guard error == Self.unconfirmedMessage else { throw CoincideError("An uncertain file restore must retain its warning.") } }
        if let result { try result.validate(); guard result.review == review.gitReview else { throw CoincideError("The combined file receipt belongs to another review.") } }
    }
}

extension WorkspaceSnapshot {
    func validateConversationHistoryFilesReview(_ historyReview: ConversationHistoryReview, excludingOperationID: UUID? = nil) throws {
        guard let files = historyReview.files else { return }
        try files.validate()
        guard historyReview.kind == .rewindBeforeRun,
              threads.contains(where: { $0.id == historyReview.sourceThreadID && $0.projectID == historyReview.projectID }),
              try conversationHistoryFileTarget(for: historyReview) == .available(files.target) else { throw WorkspaceCommandError("The rewind's exact workspace observation changed. Review it again.") }
        let restore = try combinedRestoreReview(history: historyReview, files: files, sourceFingerprint: files.sourceFingerprint)
        try validateCheckpointRestoreSource(restore, excludingOperationID: excludingOperationID)
    }
    func validateConversationHistoryFilesSource(operationID: UUID) throws {
        guard let operation = conversationHistoryOperation(operationID) else { throw WorkspaceCommandError("The combined rewind no longer exists.") }
        try validateConversationHistoryFilesSource(operation)
    }
    func validateConversationHistoryFilesSource(_ operation: ConversationHistoryOperation) throws {
        try operation.validate()
        guard conversationHistoryOperation(operation.id) == operation,
              operation.phase == .applied, operation.review.kind == .rewindBeforeRun, let files = operation.files,
              files.acknowledgedAt == nil, let fingerprint = files.postHistorySourceFingerprint,
              let thread = threads.first(where: { $0.id == operation.review.sourceThreadID && $0.projectID == operation.review.projectID }),
              operation.review.removedRunIDs.allSatisfy({ id in thread.runHistory?.contains(where: { $0.id == id && $0.removedByHistoryOperationID == operation.id }) == true }),
              operation.review.removedMessageIDs.allSatisfy({ id in thread.messages.contains(where: { $0.id == id && $0.removedByHistoryOperationID == operation.id }) }) else { throw WorkspaceCommandError("The rewound conversation or its exact file target changed.") }
        var expectedConfiguration = operation.review.sourceConfiguration
        if operation.review.openCodeV1 != nil || operation.review.claude != nil {
            // The validated V1 result adopts a new native conversation while
            // retaining the exact pre-adoption checkpoint/run audit. Only the
            // current native reference changes; no other reviewed setting does.
            expectedConfiguration.nativeThreadID = operation.result?.reference.nativeThreadID
        }
        if operation.review.claude != nil {
            guard let selection = operation.result?.claude?.selection, thread.claudeResumeSelection == selection,
                  thread.claudeResumeConsumerRunID == nil, thread.claudeInheritedHead == operation.review.claude?.inheritedHead else {
                throw WorkspaceCommandError("The selected Claude context changed before its workspace restoration.")
            }
        }
        guard ProviderConfiguration(thread: thread) == expectedConfiguration,
              try conversationHistoryFileTarget(for: operation.review, includingRemovedByHistoryOperationID: operation.id) == .available(files.review.target) else { throw WorkspaceCommandError("The rewound conversation or its exact file target changed.") }
        let restore = try combinedRestoreReview(history: operation.review, files: files.review, sourceFingerprint: fingerprint)
        try validateCheckpointRestoreSource(restore, excludingOperationID: operation.id)
    }
    private func combinedRestoreReview(history: ConversationHistoryReview, files: ConversationHistoryFilesReview, sourceFingerprint: String) throws -> RunCheckpointRestoreReview {
        guard let thread = threads.first(where: { $0.id == history.sourceThreadID }),
              let attempt = thread.runCheckpoint(runID: files.target.checkpointRunID, stage: files.target.stage, expectedAttemptID: files.target.attemptID),
              attempt.receipt == files.target.receipt else { throw WorkspaceCommandError("The retained checkpoint audit no longer matches the rewind target.") }
        return try .init(id: files.id, reviewedAt: files.gitReview.reviewedAt, threadID: history.sourceThreadID, projectID: history.projectID,
            runID: files.target.checkpointRunID, stage: files.target.stage, attemptID: files.target.attemptID, sourceIncarnation: history.sourceIncarnation,
            sourceFingerprint: sourceFingerprint, checkpoint: attempt, gitReview: files.gitReview)
    }
    func validateConversationHistoryFilesLedger() throws {
        let operations = conversationHistoryOperations ?? []
        let files = operations.compactMap(\.review.files)
        var reserved = Set(projects.map(\.id) + threads.map(\.id) + operations.map(\.id) + operations.compactMap(\.review.targetThreadID) + (checkpointRestoreOperations ?? []).map(\.id))
        for project in projects { if let clone = project.clone { reserved.formUnion((clone.previousPlans + [clone.plan]).map(\.id)) } }
        for thread in threads {
            reserved.formUnion(thread.queuedTurns.map(\.id)); if let run = thread.activeRun { reserved.insert(run.id) }
            if let preparation = thread.workspacePreparation {
                reserved.formUnion(preparation.previousAttempts.map { $0.request.id } + [preparation.id])
                for script in preparation.previousAttempts.compactMap(\.setup) + (preparation.setup.map { [$0] } ?? []) { reserved.formUnion(script.previousPlans.map(\.id) + [script.id]) }
            }
            if let settlement = thread.settlement {
                reserved.insert(settlement.id)
                if let script = settlement.script { reserved.formUnion(script.previousPlans.map(\.id) + [script.id]) }
            }
            for record in thread.runHistory ?? [] {
                reserved.insert(record.id)
                if let checkpoints = record.checkpoints { reserved.formUnion(([checkpoints.baseline] + checkpoints.previousPostRunAttempts + (checkpoints.postRun.map { [$0] } ?? [])).map(\.id)) }
            }
        }
        guard Set(files.map(\.id)).count == files.count, Set(files.map(\.id)).isDisjoint(with: reserved) else { throw CoincideError("Combined rewind file identities must be uniquely reserved.") }
        for operation in operations {
            guard let state = operation.files else { continue }
            if operation.isPending || operation.phase == .unconfirmed {
                guard let thread = threads.first(where: { $0.id == operation.review.sourceThreadID }),
                      try checkpointRestoreSourceFingerprint(threadID: thread.id) == state.review.sourceFingerprint,
                      thread.runCheckpoint(runID: state.review.target.checkpointRunID, stage: state.review.target.stage, expectedAttemptID: state.review.target.attemptID)?.receipt == state.review.target.receipt else { throw CoincideError("A combined rewind lost its reviewed source or retained file target.") }
            }
            if operation.phase == .applied, state.phase != .waitingForProvider,
               state.acknowledgedAt == nil, state.phase != .applied {
                guard let thread = threads.first(where: { $0.id == operation.review.sourceThreadID }),
                      let fingerprint = state.postHistorySourceFingerprint,
                      try checkpointRestoreSourceFingerprint(threadID: thread.id) == fingerprint,
                      thread.runCheckpoint(runID: state.review.target.checkpointRunID, stage: state.review.target.stage, expectedAttemptID: state.review.target.attemptID)?.receipt == state.review.target.receipt else { throw CoincideError("A partial rewind lost its retained file target or source audit.") }
            }
        }
        let locked = operations.filter(\.locksFiles)
        for (index, operation) in locked.enumerated() {
            let path = operation.files!.review.gitReview.currentPlan.repositoryPath
            guard !locked.dropFirst(index + 1).contains(where: {
                let other = $0.files!.review.gitReview.currentPlan.repositoryPath
                return path == other || path.hasPrefix(other + "/") || other.hasPrefix(path + "/")
            }), !(checkpointRestoreOperations ?? []).contains(where: {
                let other = $0.review.gitReview.currentPlan.repositoryPath
                return $0.locksSource && (path == other || path.hasPrefix(other + "/") || other.hasPrefix(path + "/"))
            }) else { throw CoincideError("Pending file actions cannot overlap another workspace owner.") }
        }
    }
}

extension WorkspaceDecision {
    mutating func dispatchConversationHistoryFiles(threadID: UUID, operationID: UUID, incarnation: UUID, now: Date) throws {
        guard let i = snapshot.conversationHistoryOperations?.firstIndex(where: { $0.id == operationID }),
              let operation = snapshot.conversationHistoryOperations?[i], operation.phase == .applied,
              operation.review.sourceThreadID == threadID, operation.review.sourceIncarnation == incarnation,
              operation.files?.phase == .accepted else { return }
        try snapshot.validateConversationHistoryFilesSource(operation)
        snapshot.conversationHistoryOperations?[i].files?.phase = .dispatching
        snapshot.conversationHistoryOperations?[i].files?.updatedAt = now
        snapshot.conversationHistoryOperations?[i].updatedAt = now
    }
    mutating func finishConversationHistoryFiles(_ request: WorkspaceEffectRequest, result: EffectResult, incarnation: UUID, now: Date) {
        guard case .conversationHistoryFiles(let threadID, let operationID, let attemptID) = request,
              let i = snapshot.conversationHistoryOperations?.firstIndex(where: { $0.id == operationID }),
              var operation = snapshot.conversationHistoryOperations?[i], operation.phase == .applied,
              operation.review.sourceThreadID == threadID, operation.review.sourceIncarnation == incarnation,
              var files = operation.files, files.review.id == attemptID, files.isWorking else { return }
        switch result {
        case .checkpointRestoreConfirmed(let receipt):
            guard files.phase == .dispatching else { return }
            do {
                try snapshot.validateConversationHistoryFilesSource(operation)
                files.phase = .applied; files.result = receipt; files.error = nil; try files.validate(providerPhase: operation.phase)
            } catch { files.phase = .unconfirmed; files.result = nil; files.error = ConversationHistoryFilesState.unconfirmedMessage }
        case .failed:
            files.phase = .failed; files.error = ConversationHistoryFilesState.failureMessage
        case .cancelled, .stopped, .checkpointRestoreUnconfirmed:
            files.phase = files.phase == .accepted ? .failed : .unconfirmed
            files.error = files.phase == .failed ? ConversationHistoryFilesState.notStartedMessage : ConversationHistoryFilesState.unconfirmedMessage
        default: return
        }
        files.updatedAt = now; operation.files = files; operation.updatedAt = now
        snapshot.conversationHistoryOperations?[i] = operation
    }
    mutating func inspectConversationHistoryFiles(operationID: UUID, result: GitCheckpointRestoreInspection, now: Date) throws {
        guard let i = snapshot.conversationHistoryOperations?.firstIndex(where: { $0.id == operationID }),
              var operation = snapshot.conversationHistoryOperations?[i], operation.phase == .applied,
              var files = operation.files, files.phase == .unconfirmed, files.acknowledgedAt == nil else { throw WorkspaceCommandError("Only the current uncertain rewind file stage can be inspected.") }
        try snapshot.validateConversationHistoryFilesSource(operation)
        switch result {
        case .ready(let receipt): files.phase = .applied; files.result = receipt; files.error = nil
        case .notStarted: files.phase = .failed; files.error = ConversationHistoryFilesState.notStartedMessage
        case .interrupted: files.error = ConversationHistoryFilesState.unconfirmedMessage
        }
        files.updatedAt = now; try files.validate(providerPhase: operation.phase)
        operation.files = files; operation.updatedAt = now; snapshot.conversationHistoryOperations?[i] = operation
    }
    mutating func acknowledgeConversationHistoryFiles(operationID: UUID, now: Date) throws {
        guard let i = snapshot.conversationHistoryOperations?.firstIndex(where: { $0.id == operationID }),
              let operation = snapshot.conversationHistoryOperations?[i], operation.phase == .applied,
              let files = operation.files, [.failed, .unconfirmed].contains(files.phase) else { throw WorkspaceCommandError("Only an incomplete rewind file stage can keep the current files.") }
        if files.acknowledgedAt != nil { return }
        snapshot.conversationHistoryOperations?[i].files?.acknowledgedAt = now
        snapshot.conversationHistoryOperations?[i].files?.updatedAt = now
        snapshot.conversationHistoryOperations?[i].updatedAt = now
    }
    mutating func dismissConversationHistoryRecall(operationID: UUID, now: Date) throws {
        guard let i = snapshot.conversationHistoryOperations?.firstIndex(where: { $0.id == operationID }),
              let operation = snapshot.conversationHistoryOperations?[i], operation.allExternalWorkSucceeded,
              operation.review.recallPromptOnSuccess == true else { throw WorkspaceCommandError("Only a completed rewind can keep its current draft.") }
        if operation.recalledAt != nil || operation.recallDismissedAt != nil { return }
        snapshot.conversationHistoryOperations?[i].recallDismissedAt = now
        snapshot.conversationHistoryOperations?[i].updatedAt = now
    }
}
