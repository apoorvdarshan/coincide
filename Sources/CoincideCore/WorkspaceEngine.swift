import Foundation
import CryptoKit

public struct WorkspaceUpdate: Sendable {
    public var snapshot: WorkspaceSnapshot
    public var sequence: Int64
    public var error: String?
}

extension WorkspaceEngine {
    public func reviewCheckpointRestore(threadID: UUID, runID: UUID, stage: RunCheckpointStage, expectedAttemptID: UUID) async throws -> RunCheckpointRestoreReview {
        _ = try await load()
        if await waitForRemovalCommit(threadID: threadID) { throw CancellationError() }
        if let reason = revision.snapshot.checkpointRestoreUnavailableReason(threadID: threadID, runID: runID, stage: stage, expectedAttemptID: expectedAttemptID) {
            throw WorkspaceCommandError(reason)
        }
        guard !closing, !stoppingEffects, fatalError == nil,
              let thread = revision.snapshot.threads.first(where: { $0.id == threadID }),
              let incarnation = threadIncarnations[threadID],
              let attempt = thread.runCheckpoint(runID: runID, stage: stage, expectedAttemptID: expectedAttemptID),
              let target = attempt.receipt, restoreRuntimeScopeIsolated(thread: thread, path: target.plan.repositoryPath) else {
            throw WorkspaceCommandError("Finish all work using this checkout before reviewing file restoration.")
        }
        let fingerprint = try revision.snapshot.checkpointRestoreSourceFingerprint(threadID: threadID), id = UUID()
        let git = try await readCheckpointRestore(thread: thread, onRejected: { session, value in
            // Cleanup is an owned job, including when the review reader itself
            // was canceled. Do not inherit its cancellation into the disposer.
            let cleanup = Task { _ = try? await session.discardRestoreReview(value) }
            await cleanup.value
        }) { try await $0.reviewRestore(target: target, id: id) }
        do {
            guard ownsCheckpointRestoreSource(threadID: threadID, incarnation: incarnation, fingerprint: fingerprint),
                  revision.snapshot.checkpointRestoreUnavailableReason(threadID: threadID, runID: runID, stage: stage, expectedAttemptID: expectedAttemptID) == nil,
                  restoreRuntimeScopeIsolated(thread: thread, path: git.currentPlan.repositoryPath) else { throw CancellationError() }
            let review = try RunCheckpointRestoreReview(id: id, threadID: threadID, projectID: thread.projectID, runID: runID,
                stage: stage, attemptID: expectedAttemptID, sourceIncarnation: incarnation, sourceFingerprint: fingerprint,
                checkpoint: attempt, gitReview: git)
            checkpointRestoreReviews[id] = .init(review: review, digest: try checkpointRestoreDigest(review))
            return review
        } catch {
            await discardCheckpointRestoreScratch(git, threadID: threadID, projectID: thread.projectID)
            throw error
        }
    }

    public func discardCheckpointRestoreReview(reviewID: UUID) async {
        // Acceptance owns this review before its durable receipt is published.
        // A disappearing sheet cannot clean scratch out from under that commit.
        guard !acceptingCheckpointRestores.contains(reviewID) else { return }
        guard let prepared = checkpointRestoreReviews.removeValue(forKey: reviewID),
              revision.snapshot.checkpointRestoreOperation(reviewID) == nil, !closing else { return }
        await discardCheckpointRestoreScratch(prepared.review.gitReview, threadID: prepared.review.threadID, projectID: prepared.review.projectID)
    }

    private func discardCheckpointRestoreScratch(_ review: GitCheckpointRestoreReview, threadID: UUID, projectID: UUID) async {
        let token = UUID(), factory = checkpointFactory
        let task = Task { _ = try? await factory(URL(fileURLWithPath: review.currentPlan.workspacePath)).discardRestoreReview(review) }
        checkpointReads[token] = .init(threadID: threadID, projectID: projectID, inspection: false,
                                      task: task, cancel: { task.cancel() })
        await task.value
        checkpointReads.removeValue(forKey: token)
    }

    @discardableResult public func beginCheckpointRestore(_ review: RunCheckpointRestoreReview) async throws -> WorkspaceCommandReceipt {
        _ = try await load(); try Task.checkCancellation(); try review.validate()
        guard !closing, !stoppingEffects, fatalError == nil else { throw CancellationError() }
        if let existing = revision.snapshot.checkpointRestoreOperation(review.id) {
            guard existing.review == review, let receipt = try await database.receipt(review.id) else { throw WorkspaceCommandError("This restoration review changed.") }
            return receipt
        }
        guard checkpointRestoreReviews[review.id]?.digest == (try checkpointRestoreDigest(review)),
              ownsCheckpointRestoreSource(threadID: review.threadID, incarnation: review.sourceIncarnation, fingerprint: review.sourceFingerprint),
              let thread = revision.snapshot.threads.first(where: { $0.id == review.threadID }),
              restoreRuntimeScopeIsolated(thread: thread, path: review.gitReview.currentPlan.repositoryPath) else {
            throw WorkspaceCommandError("This checkout or its owners changed. Review file restoration again.")
        }
        acceptingCheckpointRestores.insert(review.id)
        defer { acceptingCheckpointRestores.remove(review.id); checkpointRestoreReviews.removeValue(forKey: review.id) }
        do {
            let receipt = try await enqueue(.checkpointRestoreAccepted(review: review), id: review.id)
            if let rejection = receipt.rejection { throw WorkspaceCommandError(rejection) }
            return receipt
        } catch {
            // Commit failure may be ambiguous. The service removes only an
            // unused review with its own pinned idle lock and no write marker.
            if revision.snapshot.checkpointRestoreOperation(review.id) == nil {
                await discardCheckpointRestoreScratch(review.gitReview, threadID: review.threadID, projectID: review.projectID)
            }
            throw error
        }
    }

    /// Inspect owned completion evidence without restoring, cleaning or resetting.
    @discardableResult public func inspectCheckpointRestore(operationID: UUID) async throws -> WorkspaceCommandReceipt {
        _ = try await load()
        guard !closing, !stoppingEffects, fatalError == nil,
              let operation = revision.snapshot.checkpointRestoreOperation(operationID), operation.phase == .unconfirmed,
              operation.acknowledgedAt == nil, let incarnation = threadIncarnations[operation.review.threadID],
              let thread = revision.snapshot.threads.first(where: { $0.id == operation.review.threadID }),
              revision.snapshot.canReviewCheckpointRestore(threadID: thread.id, excludingOperationID: operationID),
              try revision.snapshot.checkpointRestoreSourceFingerprint(threadID: thread.id) == operation.review.sourceFingerprint,
              restoreRuntimeScopeIsolated(thread: thread, path: operation.review.gitReview.currentPlan.repositoryPath) else {
            throw WorkspaceCommandError("This restoration or its workspace changed. Inspect the current files before continuing.")
        }
        let result = try await readCheckpointRestore(thread: thread) { try await $0.inspectRestore(review: operation.review.gitReview) }
        guard ownsCheckpointRestoreSource(threadID: thread.id, incarnation: incarnation, fingerprint: operation.review.sourceFingerprint),
              revision.snapshot.checkpointRestoreOperation(operationID) == operation else { throw CancellationError() }
        let receipt = try await enqueue(.checkpointRestoreInspected(operationID: operationID, incarnation: incarnation, result: result))
        if let rejection = receipt.rejection { throw WorkspaceCommandError(rejection) }
        return receipt
    }

    private func checkpointRestoreDigest(_ review: RunCheckpointRestoreReview) throws -> String {
        SHA256.hash(data: try encoder.encode(review)).map { String(format: "%02x", $0) }.joined()
    }
    private func ownsCheckpointRestoreSource(threadID: UUID, incarnation: UUID, fingerprint: String) -> Bool {
        !closing && !stoppingEffects && fatalError == nil && threadIncarnations[threadID] == incarnation &&
            (try? revision.snapshot.checkpointRestoreSourceFingerprint(threadID: threadID)) == fingerprint
    }
    private func ownsCheckpointRestoreEvent(_ command: EngineCommand) -> Bool {
        switch command {
        case .checkpointRestoreAccepted(let review): return threadIncarnations[review.threadID] == review.sourceIncarnation
        case .checkpointRestoreDispatching(let id, _, let incarnation): return threadIncarnations[id] == incarnation
        case .checkpointRestoreEffectResult(let request, _, let incarnation): return request.threadID.map { threadIncarnations[$0] == incarnation } ?? false
        case .checkpointRestoreInspected(let id, let incarnation, _):
            guard let operation = revision.snapshot.checkpointRestoreOperation(id) else { return false }
            return threadIncarnations[operation.review.threadID] == incarnation
        default: return true
        }
    }
    private func restoreRuntimeScopeIsolated(thread: CodingThread, path: String) -> Bool {
        guard !runtimes.contains(where: { $0.key != thread.id && WorkspaceSnapshot.checkpointRestorePathsOverlap($0.value.path, path) }),
              !metadataSessions.values.contains(where: {
                  $0.threadID != thread.id && WorkspaceSnapshot.checkpointRestorePathsOverlap($0.path, path)
              }), !cleanupTasks.values.contains(where: { cleanup in
                  cleanup.threadIDs != Set([thread.id]) && cleanup.workspacePaths.contains { WorkspaceSnapshot.checkpointRestorePathsOverlap($0, path) }
              }), !scriptRuntimes.values.contains(where: { runtime in
                  guard let owner = revision.snapshot.threads.first(where: { $0.id == runtime.threadID }) else { return true }
                  return WorkspaceSnapshot.checkpointRestorePathsOverlap(owner.workspacePath, path)
              }) else { return false }
        return true
    }
    private func readCheckpointRestore<Value: Sendable>(thread: CodingThread,
        onRejected: @escaping @Sendable (any RunCheckpointSession, Value) async -> Void = { _, _ in },
        operation: @escaping @Sendable (any RunCheckpointSession) async throws -> Value) async throws -> Value {
        guard !closing, !stoppingEffects, fatalError == nil, let incarnation = threadIncarnations[thread.id] else { throw CancellationError() }
        let session = try checkpointFactory(URL(fileURLWithPath: thread.workspacePath)), token = UUID()
        let task = Task {
            let value = try await operation(session)
            do { try Task.checkCancellation(); return value }
            catch { await onRejected(session, value); throw error }
        }, drain = Task<Void, Never> { _ = try? await task.value }
        checkpointReads[token] = .init(threadID: thread.id, projectID: thread.projectID, inspection: false, task: drain, cancel: { task.cancel() })
        defer { checkpointReads.removeValue(forKey: token) }
        return try await withTaskCancellationHandler {
            let value = try await task.value
            do {
                try Task.checkCancellation()
                guard !closing, !stoppingEffects, fatalError == nil, threadIncarnations[thread.id] == incarnation,
                      revision.snapshot.threads.contains(where: { $0.id == thread.id && $0.projectID == thread.projectID && $0.workspacePath == thread.workspacePath }) else { throw CancellationError() }
                return value
            } catch { await onRejected(session, value); throw error }
        } onCancel: { task.cancel() }
    }
    private func performCheckpointRestore(_ request: WorkspaceEffectRequest) async throws -> EffectResult {
        guard case .checkpointRestore(let threadID, let operationID) = request,
              let operation = revision.snapshot.checkpointRestoreOperation(operationID), operation.phase == .accepted,
              let thread = revision.snapshot.threads.first(where: { $0.id == threadID }),
              let incarnation = threadIncarnations[threadID],
              ownsCheckpointRestoreSource(threadID: threadID, incarnation: incarnation, fingerprint: operation.review.sourceFingerprint) else { return .cancelled }
        let review = operation.review
        var dispatched = false
        do {
            try Task.checkCancellation()
            guard restoreRuntimeScopeIsolated(thread: thread, path: review.gitReview.currentPlan.repositoryPath) else { throw WorkspaceCommandError("This workspace has another live owner.") }
            // All owned provider connections must finish closing before files can
            // change. The durable source lock prevents a new connection meanwhile.
            await drainCheckpointRestoreOwners(thread)
            try Task.checkCancellation()
            guard ownsCheckpointRestoreSource(threadID: threadID, incarnation: incarnation, fingerprint: review.sourceFingerprint),
                  restoreRuntimeScopeIsolated(thread: thread, path: review.gitReview.currentPlan.repositoryPath) else { throw CancellationError() }
            let session = try checkpointFactory(URL(fileURLWithPath: review.workspacePath))
            let receipt = try await enqueue(.checkpointRestoreDispatching(threadID: threadID, operationID: operationID, incarnation: incarnation))
            guard receipt.rejection == nil, revision.snapshot.checkpointRestoreOperation(operationID)?.phase == .dispatching,
                  ownsCheckpointRestoreSource(threadID: threadID, incarnation: incarnation, fingerprint: review.sourceFingerprint),
                  restoreRuntimeScopeIsolated(thread: thread, path: review.gitReview.currentPlan.repositoryPath) else { throw CancellationError() }
            try Task.checkCancellation(); dispatched = true
            let result = try await session.restore(review: review.gitReview)
            try result.validate()
            guard result.review == review.gitReview,
                  ownsCheckpointRestoreSource(threadID: threadID, incarnation: incarnation, fingerprint: review.sourceFingerprint) else {
                return .checkpointRestoreUnconfirmed
            }
            return .checkpointRestoreConfirmed(result)
        } catch let error as GitCheckpointRestoreError {
            return error.mayHaveMutated ? .checkpointRestoreUnconfirmed : .failed(RunCheckpointRestoreOperation.failureMessage)
        } catch {
            return dispatched ? .checkpointRestoreUnconfirmed : .failed(RunCheckpointRestoreOperation.failureMessage)
        }
    }
    private func drainCheckpointRestoreOwners(_ thread: CodingThread) async {
        await closeRuntime(thread.id)
        let metadata = metadataSessions.filter { $0.value.threadID == thread.id }.map(\.key)
        for id in metadata {
            if let task = beginMetadataClose(id) { await task.value }
            metadataSessions.removeValue(forKey: id)
        }
        await awaitCheckpointDrains(threadID: thread.id)
        let scripts = thread.projectScripts.compactMap { scriptClosures[$0.1.id] }
        for task in scripts { await task.value }
        let cleanups = cleanupTasks.values.filter { $0.threadIDs.contains(thread.id) }.map(\.task)
        for task in cleanups { await task.value }
    }
}

extension WorkspaceEngine {
    private struct ReviewedNativeHistory: Sendable {
        let snapshot: ProviderConversationSnapshot
        let boundary: ProviderHistoryBoundary
        let resultingHead: String?
    }

    /// A review performs only reads. Its ephemeral token is bound to this engine
    /// incarnation and to the complete returned value, not just a caller's UUID.
    public func reviewConversationHistory(threadID: UUID, runID: UUID, kind: ConversationHistoryKind,
                                          recallPromptOnSuccess: Bool = false) async throws -> ConversationHistoryReview {
        _ = try await load()
        if await waitForRemovalCommit(threadID: threadID) { throw CancellationError() }
        if let reason = revision.snapshot.conversationHistoryUnavailableReason(threadID: threadID, runID: runID, kind: kind) {
            throw WorkspaceCommandError(reason)
        }
        guard !closing, !stoppingEffects, fatalError == nil,
              revision.snapshot.canReviewConversationHistory(threadID: threadID),
              let thread = revision.snapshot.threads.first(where: { $0.id == threadID }),
              let incarnation = threadIncarnations[threadID],
              let record = thread.runHistory?.first(where: { $0.id == runID && $0.removedByHistoryOperationID == nil }),
              record.status.isTerminal, record.providerThreadID == thread.providerThreadID,
              record.configuration.provider == thread.provider,
              record.configuration.workspacePath == thread.workspacePath else {
            throw WorkspaceCommandError("Finish this conversation's work and select a run with verified provider history before continuing.")
        }
        let fingerprint = try revision.snapshot.historySourceFingerprint(threadID: threadID)
        let prefix = try thread.transcriptPrefix(runID: runID, boundary: kind == .forkAfterRun ? .afterRun : .beforeRun)
        let native = try await readHistory(thread: thread) { session in
            try await Self.readReviewedNativeHistory(session: session, thread: thread, runID: runID, kind: kind)
        }
        guard ownsHistorySource(threadID: threadID, incarnation: incarnation, fingerprint: fingerprint),
              revision.snapshot.canReviewConversationHistory(threadID: threadID) else { throw ProviderHistoryError(.historyChanged) }
        let activeRecords = (thread.runHistory ?? []).filter { $0.removedByHistoryOperationID == nil }
        guard let index = activeRecords.firstIndex(where: { $0.id == runID }), let head = native.snapshot.headTurnID else { throw ProviderHistoryError(.boundaryUnavailable) }
        let review = try ConversationHistoryReview(kind: kind, sourceThreadID: threadID, projectID: thread.projectID,
            runID: runID, sourceIncarnation: incarnation, sourceConfiguration: .init(thread: thread),
            targetConfiguration: record.configuration, sourceReference: native.snapshot.reference,
            reviewedHeadTurnID: head, boundary: native.boundary, expectedResultHeadTurnID: native.resultingHead,
            prefix: prefix, removedRunIDs: kind == .rewindBeforeRun ? activeRecords[index...].map(\.id) : [],
            removedMessageIDs: kind == .rewindBeforeRun ? thread.visibleMessages.dropFirst(prefix.count).map(\.id) : [],
            sourceFingerprint: fingerprint, targetThreadID: kind == .forkAfterRun ? UUID() : nil,
            suggestedTitle: String((thread.title + " — Fork").prefix(200)),
            recallPromptOnSuccess: kind == .rewindBeforeRun && recallPromptOnSuccess ? true : nil)
        historyReviews[review.id] = .init(review: review, digest: try historyReviewDigest(review))
        return review
    }

    /// Preparing the destructive choice creates its own immutable action. The
    /// independently reviewed keep-files choice remains available until accepted.
    public func reviewConversationHistoryRestoringFiles(_ keepReview: ConversationHistoryReview) async throws -> ConversationHistoryReview {
        _ = try await load(); try Task.checkCancellation(); try keepReview.validate()
        guard keepReview.kind == .rewindBeforeRun, keepReview.files == nil,
              historyReviews[keepReview.id]?.digest == (try historyReviewDigest(keepReview)),
              ownsHistorySource(threadID: keepReview.sourceThreadID, incarnation: keepReview.sourceIncarnation, fingerprint: keepReview.sourceFingerprint) else {
            throw ProviderHistoryError(.historyChanged)
        }
        let fresh = try await reviewConversationHistory(threadID: keepReview.sourceThreadID, runID: keepReview.runID,
            kind: .rewindBeforeRun, recallPromptOnSuccess: keepReview.recallPromptOnSuccess == true)
        var prepared: GitCheckpointRestoreReview?
        do {
            guard fresh.boundary == keepReview.boundary, fresh.reviewedHeadTurnID == keepReview.reviewedHeadTurnID,
                  let thread = revision.snapshot.threads.first(where: { $0.id == fresh.sourceThreadID }),
                  revision.snapshot.canReviewCheckpointRestore(threadID: thread.id),
                  case .available(let target) = thread.conversationHistoryFileTarget(beforeRunID: fresh.runID),
                  restoreRuntimeScopeIsolated(thread: thread, path: target.receipt.plan.repositoryPath) else {
                throw WorkspaceCommandError("This boundary has no verified checkpoint in an isolated workspace. Rewind and keep files instead.")
            }
            let fingerprint = try revision.snapshot.checkpointRestoreSourceFingerprint(threadID: thread.id), fileID = UUID()
            let git = try await readCheckpointRestore(thread: thread, onRejected: { session, value in
                let cleanup = Task { _ = try? await session.discardRestoreReview(value) }; await cleanup.value
            }) { try await $0.reviewRestore(target: target.receipt, id: fileID) }
            prepared = git
            let files = try ConversationHistoryFilesReview(id: fileID, target: target, sourceFingerprint: fingerprint, gitReview: git)
            let review = try ConversationHistoryReview(id: fresh.id, kind: fresh.kind, reviewedAt: fresh.reviewedAt,
                sourceThreadID: fresh.sourceThreadID, projectID: fresh.projectID, runID: fresh.runID,
                sourceIncarnation: fresh.sourceIncarnation, sourceConfiguration: fresh.sourceConfiguration,
                targetConfiguration: fresh.targetConfiguration, sourceReference: fresh.sourceReference,
                reviewedHeadTurnID: fresh.reviewedHeadTurnID, boundary: fresh.boundary,
                expectedResultHeadTurnID: fresh.expectedResultHeadTurnID, prefix: fresh.prefix,
                removedRunIDs: fresh.removedRunIDs, removedMessageIDs: fresh.removedMessageIDs,
                sourceFingerprint: fresh.sourceFingerprint, targetThreadID: fresh.targetThreadID,
                suggestedTitle: fresh.suggestedTitle, files: files, recallPromptOnSuccess: fresh.recallPromptOnSuccess)
            guard ownsHistorySource(threadID: review.sourceThreadID, incarnation: review.sourceIncarnation, fingerprint: review.sourceFingerprint),
                  restoreRuntimeScopeIsolated(thread: thread, path: git.currentPlan.repositoryPath) else { throw CancellationError() }
            try revision.snapshot.validateConversationHistoryFilesReview(review)
            historyReviews[review.id] = .init(review: review, digest: try historyReviewDigest(review))
            return review
        } catch {
            historyReviews.removeValue(forKey: fresh.id)
            if let prepared { await discardCheckpointRestoreScratch(prepared, threadID: fresh.sourceThreadID, projectID: fresh.projectID) }
            throw error
        }
    }

    public func discardConversationHistoryReview(reviewID: UUID) async {
        guard !acceptingHistoryReviews.contains(reviewID), let prepared = historyReviews.removeValue(forKey: reviewID),
              revision.snapshot.conversationHistoryOperation(reviewID) == nil, let files = prepared.review.files else { return }
        await discardCheckpointRestoreScratch(files.gitReview, threadID: prepared.review.sourceThreadID, projectID: prepared.review.projectID)
    }

    @discardableResult public func beginConversationHistory(_ review: ConversationHistoryReview, title: String? = nil) async throws -> WorkspaceCommandReceipt {
        _ = try await load(); try Task.checkCancellation(); try review.validate()
        guard !closing, !stoppingEffects, fatalError == nil else { throw CancellationError() }
        if let existing = revision.snapshot.conversationHistoryOperations?.first(where: { $0.id == review.id }) {
            guard existing.review == review, let receipt = try await database.receipt(review.id) else { throw ProviderHistoryError(.historyChanged) }
            return receipt // A repeated acceptance observes the one durable action.
        }
        guard historyReviews[review.id]?.digest == (try historyReviewDigest(review)),
              ownsHistorySource(threadID: review.sourceThreadID, incarnation: review.sourceIncarnation, fingerprint: review.sourceFingerprint),
              revision.snapshot.canReviewConversationHistory(threadID: review.sourceThreadID) else { throw ProviderHistoryError(.historyChanged) }
        if let files = review.files {
            try revision.snapshot.validateConversationHistoryFilesReview(review)
            guard let thread = revision.snapshot.threads.first(where: { $0.id == review.sourceThreadID }),
                  restoreRuntimeScopeIsolated(thread: thread, path: files.gitReview.currentPlan.repositoryPath) else { throw ProviderHistoryError(.notIdle) }
        }
        acceptingHistoryReviews.insert(review.id)
        defer { acceptingHistoryReviews.remove(review.id); historyReviews.removeValue(forKey: review.id) }
        do {
            let receipt = try await enqueue(.conversationHistoryAccepted(review: review, title: title), id: review.id)
            if let rejection = receipt.rejection { throw WorkspaceCommandError(rejection) }
            return receipt
        } catch {
            if revision.snapshot.conversationHistoryOperation(review.id) == nil, let files = review.files {
                await discardCheckpointRestoreScratch(files.gitReview, threadID: review.sourceThreadID, projectID: review.projectID)
            }
            throw error
        }
    }

    /// Inspect an uncertain rewind without repeating it. A third head remains
    /// unresolved; neither local history nor provider work advances by guessing.
    @discardableResult public func reconcileConversationHistory(operationID: UUID) async throws -> WorkspaceCommandReceipt {
        _ = try await load()
        guard !closing, !stoppingEffects, fatalError == nil,
              let operation = revision.snapshot.conversationHistoryOperations?.first(where: { $0.id == operationID }),
              operation.phase == .unconfirmed, operation.review.kind == .rewindBeforeRun,
              let thread = revision.snapshot.threads.first(where: { $0.id == operation.review.sourceThreadID }),
              let incarnation = threadIncarnations[thread.id], !thread.isBusy, thread.queuedTurns.isEmpty,
              thread.runtimeRequests.isEmpty,
              try revision.snapshot.historySourceFingerprint(threadID: thread.id) == operation.review.sourceFingerprint else { throw ProviderHistoryError(.historyChanged) }
        let expected = operation.review
        let snapshot = try await readHistory(thread: thread) { session in
            let capabilities = try await session.historyCapabilities(threadID: expected.sourceReference.nativeThreadID)
            guard capabilities.reference == expected.sourceReference, capabilities.canRead, capabilities.canForkHead else { throw ProviderHistoryError(.notIdle) }
            let first = try await session.conversationSnapshot(threadID: expected.sourceReference.nativeThreadID)
            let last = try await session.conversationSnapshot(threadID: expected.sourceReference.nativeThreadID)
            guard first == last, first.reference == expected.sourceReference, first.historyMode == .paginated,
                  first.workspacePath == expected.sourceConfiguration.workspacePath else { throw ProviderHistoryError(.historyChanged) }
            return first
        }
        guard ownsHistorySource(threadID: thread.id, incarnation: incarnation, fingerprint: expected.sourceFingerprint),
              revision.snapshot.conversationHistoryOperations?.first(where: { $0.id == operationID }) == operation else { throw ProviderHistoryError(.historyChanged) }
        let result: ConversationHistoryReconciliation
        if snapshot.headTurnID == expected.reviewedHeadTurnID { result = .unchanged }
        else if snapshot.headTurnID == expected.expectedResultHeadTurnID { result = .applied(snapshot) }
        else { throw ProviderHistoryError(.historyChanged) }
        let receipt = try await enqueue(.conversationHistoryReconciled(operationID: operationID, incarnation: incarnation, result: result))
        if let rejection = receipt.rejection { throw WorkspaceCommandError(rejection) }
        if case .unchanged = result, let files = expected.files {
            await discardCheckpointRestoreScratch(files.gitReview, threadID: thread.id, projectID: thread.projectID)
        }
        return receipt
    }

    /// Reads the exact file-stage evidence without repeating either external
    /// action. A confirmed provider rewind remains retained on every outcome.
    @discardableResult public func inspectConversationHistoryFiles(operationID: UUID) async throws -> WorkspaceCommandReceipt {
        _ = try await load()
        guard !closing, !stoppingEffects, fatalError == nil,
              let operation = revision.snapshot.conversationHistoryOperation(operationID), operation.phase == .applied,
              let files = operation.files, files.phase == .unconfirmed, files.acknowledgedAt == nil,
              let thread = revision.snapshot.threads.first(where: { $0.id == operation.review.sourceThreadID }),
              let incarnation = threadIncarnations[thread.id],
              restoreRuntimeScopeIsolated(thread: thread, path: files.review.gitReview.currentPlan.repositoryPath) else {
            throw WorkspaceCommandError("The rewind or workspace changed. Check the current files before continuing.")
        }
        try revision.snapshot.validateConversationHistoryFilesSource(operation)
        let result = try await readCheckpointRestore(thread: thread) { try await $0.inspectRestore(review: files.review.gitReview) }
        guard ownsHistoryFilesSource(threadID: thread.id, operationID: operationID, incarnation: incarnation),
              revision.snapshot.conversationHistoryOperation(operationID) == operation else { throw CancellationError() }
        let receipt = try await enqueue(.conversationHistoryFilesInspected(operationID: operationID, incarnation: incarnation, result: result))
        if let rejection = receipt.rejection { throw WorkspaceCommandError(rejection) }
        return receipt
    }

    private func ownsHistoryFilesSource(threadID: UUID, operationID: UUID, incarnation: UUID) -> Bool {
        guard !closing, !stoppingEffects, fatalError == nil, threadIncarnations[threadID] == incarnation,
              let operation = revision.snapshot.conversationHistoryOperation(operationID), operation.phase == .applied,
              operation.review.sourceThreadID == threadID, let files = operation.files,
              let fingerprint = files.postHistorySourceFingerprint else { return false }
        return (try? revision.snapshot.checkpointRestoreSourceFingerprint(threadID: threadID)) == fingerprint
    }

    private func performConversationHistoryFiles(_ request: WorkspaceEffectRequest) async throws -> EffectResult {
        guard case .conversationHistoryFiles(let threadID, let operationID, let fileID) = request,
              let operation = revision.snapshot.conversationHistoryOperation(operationID), operation.phase == .applied,
              let files = operation.files, files.phase == .accepted, files.review.id == fileID,
              let thread = revision.snapshot.threads.first(where: { $0.id == threadID }),
              let incarnation = threadIncarnations[threadID],
              ownsHistoryFilesSource(threadID: threadID, operationID: operationID, incarnation: incarnation) else { return .cancelled }
        var dispatched = false
        do {
            try revision.snapshot.validateConversationHistoryFilesSource(operation)
            guard restoreRuntimeScopeIsolated(thread: thread, path: files.review.gitReview.currentPlan.repositoryPath) else {
                throw WorkspaceCommandError("The workspace has another live owner.")
            }
            await drainCheckpointRestoreOwners(thread)
            try Task.checkCancellation()
            guard ownsHistoryFilesSource(threadID: threadID, operationID: operationID, incarnation: incarnation),
                  restoreRuntimeScopeIsolated(thread: thread, path: files.review.gitReview.currentPlan.repositoryPath) else { throw CancellationError() }
            let session = try checkpointFactory(URL(fileURLWithPath: thread.workspacePath))
            let receipt = try await enqueue(.conversationHistoryFilesDispatching(threadID: threadID, operationID: operationID, incarnation: incarnation))
            guard receipt.rejection == nil, revision.snapshot.conversationHistoryOperation(operationID)?.files?.phase == .dispatching,
                  ownsHistoryFilesSource(threadID: threadID, operationID: operationID, incarnation: incarnation),
                  restoreRuntimeScopeIsolated(thread: thread, path: files.review.gitReview.currentPlan.repositoryPath) else { throw CancellationError() }
            try Task.checkCancellation(); dispatched = true
            let result = try await session.restore(review: files.review.gitReview)
            try result.validate()
            guard result.review == files.review.gitReview,
                  ownsHistoryFilesSource(threadID: threadID, operationID: operationID, incarnation: incarnation) else { return .checkpointRestoreUnconfirmed }
            return .checkpointRestoreConfirmed(result)
        } catch let error as GitCheckpointRestoreError {
            return error.mayHaveMutated ? .checkpointRestoreUnconfirmed : .failed(ConversationHistoryFilesState.failureMessage)
        } catch {
            return dispatched ? .checkpointRestoreUnconfirmed : .failed(ConversationHistoryFilesState.failureMessage)
        }
    }

    private func historyReviewDigest(_ review: ConversationHistoryReview) throws -> String {
        SHA256.hash(data: try encoder.encode(review)).map { String(format: "%02x", $0) }.joined()
    }
    private func ownsHistorySource(threadID: UUID, incarnation: UUID, fingerprint: String) -> Bool {
        !closing && !stoppingEffects && fatalError == nil && threadIncarnations[threadID] == incarnation &&
            (try? revision.snapshot.historySourceFingerprint(threadID: threadID)) == fingerprint
    }
    private func ownsHistoryEvent(_ command: EngineCommand) -> Bool {
        switch command {
        case .conversationHistoryAccepted(let review, _):
            return threadIncarnations[review.sourceThreadID] == review.sourceIncarnation
        case .conversationHistoryDispatching(let thread, _, let incarnation): return threadIncarnations[thread] == incarnation
        case .conversationHistoryEffectResult(let request, _, let incarnation): return request.threadID.map { threadIncarnations[$0] == incarnation } ?? false
        case .conversationHistoryReconciled(let id, let incarnation, _):
            guard let operation = revision.snapshot.conversationHistoryOperations?.first(where: { $0.id == id }) else { return false }
            return threadIncarnations[operation.review.sourceThreadID] == incarnation
        case .conversationHistoryFilesDispatching(let thread, _, let incarnation): return threadIncarnations[thread] == incarnation
        case .conversationHistoryFilesEffectResult(let request, _, let incarnation): return request.threadID.map { threadIncarnations[$0] == incarnation } ?? false
        case .conversationHistoryFilesInspected(let id, let incarnation, _):
            guard let operation = revision.snapshot.conversationHistoryOperation(id) else { return false }
            return threadIncarnations[operation.review.sourceThreadID] == incarnation
        default: return true
        }
    }

    private func readHistory<Value: Sendable>(thread: CodingThread, operation: @escaping @Sendable (any ProviderSession) async throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        guard !closing, !stoppingEffects, fatalError == nil, let incarnation = threadIncarnations[thread.id] else { throw CancellationError() }
        let token = UUID(), metadataID: UUID?, session: any ProviderSession
        if let runtime = runtimes[thread.id], runtime.id == thread.runtimeID, runtime.provider == thread.provider,
           runtime.path == thread.workspacePath, runtime.acpAgent == thread.acpAgent {
            metadataID = nil; session = runtime.session
        } else {
            let id = UUID(); metadataID = id; session = try factory(thread)
            metadataSessions[id] = .init(session: session, path: thread.workspacePath, threadID: thread.id, projectID: thread.projectID, configuration: .init(thread: thread))
        }
        let task = Task { try await operation(session) }
        historyReads[token] = .init(threadID: thread.id, projectID: thread.projectID,
            drain: Task { _ = try? await task.value }, cancel: { task.cancel() })
        defer { historyReads.removeValue(forKey: token) }
        do {
            let value = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try Task.checkCancellation()
            guard !task.isCancelled, !closing, !stoppingEffects, fatalError == nil, threadIncarnations[thread.id] == incarnation else { throw CancellationError() }
            if let metadataID {
                if let close = beginMetadataClose(metadataID) { await close.value }
                guard metadataSessions[metadataID] != nil else { throw CancellationError() }
                metadataSessions.removeValue(forKey: metadataID)
            }
            try Task.checkCancellation()
            guard !closing, !stoppingEffects, threadIncarnations[thread.id] == incarnation else { throw CancellationError() }
            return value
        } catch {
            task.cancel()
            if let metadataID {
                if let close = beginMetadataClose(metadataID) { await close.value }
                metadataSessions.removeValue(forKey: metadataID)
            }
            throw error
        }
    }

    private static func readReviewedNativeHistory(session: any ProviderSession, thread: CodingThread, runID: UUID, kind: ConversationHistoryKind) async throws -> ReviewedNativeHistory {
        guard let nativeID = thread.providerThreadID, thread.provider == .codex else { throw ProviderHistoryError(.unsupported) }
        let records = (thread.runHistory ?? []).filter { $0.removedByHistoryOperationID == nil }
        guard let selected = records.firstIndex(where: { $0.id == runID }),
              records.allSatisfy({ $0.status.isTerminal && $0.providerThreadID == nativeID && !$0.turnIDs.isEmpty }),
              thread.visibleMessages.allSatisfy({ $0.role == .system || $0.runReference != nil }) else { throw ProviderHistoryError(.boundaryUnavailable) }
        let suffix = Array(records[selected...].flatMap(\.turnIDs).reversed())
        guard !suffix.isEmpty, Set(suffix).count == suffix.count else { throw ProviderHistoryError(.boundaryUnavailable) }
        let deadline = ContinuousClock.now + .seconds(30)
        let capabilities = try await session.historyCapabilities(threadID: nativeID)
        guard capabilities.canRead, kind == .forkAfterRun ? capabilities.canForkFromTurn : capabilities.canRevertBeforeTurn else { throw ProviderHistoryError(.unsupported) }
        let before = try await session.conversationSnapshot(threadID: nativeID)
        guard before.reference == capabilities.reference, before.historyMode == .paginated,
              before.workspacePath == thread.workspacePath, before.headTurnID == suffix.first else { throw ProviderHistoryError(.historyChanged) }
        var turns: [ProviderHistoryTurn] = [], ids = Set<String>(), cursors = Set<String>(), cursor: String?
        for pageIndex in 0..<100 {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw ProviderHistoryError(.limitExceeded) }
            let page = try await session.historyPage(threadID: nativeID, cursor: cursor, limit: 100)
            guard page.reference == before.reference, !page.turns.isEmpty || page.nextCursor == nil else { throw ProviderHistoryError(.invalidResponse) }
            for turn in page.turns {
                guard ids.insert(turn.id).inserted else { throw ProviderHistoryError(.invalidResponse) }
                turns.append(turn)
            }
            if turns.count > suffix.count || page.nextCursor == nil { break }
            guard let next = page.nextCursor, cursors.insert(next).inserted else { throw ProviderHistoryError(.invalidResponse) }
            guard pageIndex < 99 else { throw ProviderHistoryError(.limitExceeded) }; cursor = next
        }
        guard turns.count >= suffix.count, Array(turns.prefix(suffix.count).map(\.id)) == suffix,
              turns.prefix(suffix.count).allSatisfy({ $0.status.isTerminal }) else { throw ProviderHistoryError(.historyChanged) }
        let after = try await session.conversationSnapshot(threadID: nativeID)
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline, after == before else { throw ProviderHistoryError(.historyChanged) }
        if kind == .forkAfterRun {
            let target = records[selected].turnIDs.last!
            return .init(snapshot: after, boundary: .throughTurn(target), resultingHead: target)
        }
        let previous = turns.count > suffix.count ? turns[suffix.count] : nil
        guard previous == nil || previous?.status.isTerminal == true else { throw ProviderHistoryError(.boundaryUnavailable) }
        return .init(snapshot: after, boundary: .beforeTurn(records[selected].turnIDs.first!), resultingHead: previous?.id)
    }

    private func performConversationHistory(_ request: WorkspaceEffectRequest) async throws -> EffectResult {
        guard case .conversationHistory(let threadID, let operationID) = request,
              let operation = revision.snapshot.conversationHistoryOperations?.first(where: { $0.id == operationID }),
              operation.phase == .accepted, let incarnation = threadIncarnations[threadID],
              let thread = revision.snapshot.threads.first(where: { $0.id == threadID }),
              ownsHistorySource(threadID: threadID, incarnation: incarnation, fingerprint: operation.review.sourceFingerprint) else { return .cancelled }
        let review = operation.review
        if let files = review.files {
            do {
                try revision.snapshot.validateConversationHistoryFilesReview(review, excludingOperationID: operationID)
                guard restoreRuntimeScopeIsolated(thread: thread, path: files.gitReview.currentPlan.repositoryPath) else { throw ProviderHistoryError(.notIdle) }
                let inspection = try await readCheckpointRestore(thread: thread) { try await $0.inspectRestore(review: files.gitReview) }
                guard inspection == .notStarted,
                      ownsHistorySource(threadID: threadID, incarnation: incarnation, fingerprint: review.sourceFingerprint),
                      restoreRuntimeScopeIsolated(thread: thread, path: files.gitReview.currentPlan.repositoryPath) else { throw ProviderHistoryError(.historyChanged) }
            } catch { return .failed(ConversationHistoryOperation.failureMessage) }
        }
        let metadataID: UUID?, session: any ProviderSession
        if review.kind == .rewindBeforeRun, let runtime = runtimes[threadID], runtime.id == thread.runtimeID,
           runtime.provider == thread.provider, runtime.path == thread.workspacePath, runtime.acpAgent == thread.acpAgent {
            metadataID = nil; session = runtime.session
        } else {
            var configured = thread
            if review.kind == .forkAfterRun {
                guard let project = revision.snapshot.projects.first(where: { $0.id == thread.projectID }) else { return .cancelled }
                configured = CodingThread(project: project, model: review.targetConfiguration.model)
                configured.id = review.targetThreadID!; configured.workspacePath = review.targetConfiguration.workspacePath
                configured.provider = review.targetConfiguration.provider; configured.permission = review.targetConfiguration.permission
                configured.acpAgent = review.targetConfiguration.acpAgent; configured.agentModeID = review.targetConfiguration.agentModeID
                configured.agentConfigValues = review.targetConfiguration.agentConfigValues; configured.agentConfiguration = review.targetConfiguration.agentConfiguration
            }
            let id = UUID(); metadataID = id; session = try factory(configured)
            metadataSessions[id] = .init(session: session, path: configured.workspacePath, threadID: threadID, projectID: thread.projectID, configuration: .init(thread: thread))
        }
        var dispatched = false
        let result: EffectResult
        do {
            try Task.checkCancellation()
            let receipt = try await enqueue(.conversationHistoryDispatching(threadID: threadID, operationID: operationID, incarnation: incarnation))
            guard receipt.rejection == nil,
                  revision.snapshot.conversationHistoryOperations?.first(where: { $0.id == operationID })?.phase == .dispatching,
                  ownsHistorySource(threadID: threadID, incarnation: incarnation, fingerprint: review.sourceFingerprint) else { throw ProviderHistoryError(.historyChanged) }
            if let files = review.files {
                try revision.snapshot.validateConversationHistoryFilesReview(review, excludingOperationID: operationID)
                guard restoreRuntimeScopeIsolated(thread: thread, path: files.gitReview.currentPlan.repositoryPath) else { throw ProviderHistoryError(.notIdle) }
            }
            try Task.checkCancellation(); dispatched = true
            let snapshot: ProviderConversationSnapshot
            if review.kind == .forkAfterRun { snapshot = try await session.forkConversation(source: review.sourceReference, boundary: review.boundary, configuration: review.targetConfiguration) }
            else {
                guard case .beforeTurn(let turnID) = review.boundary else { throw ProviderHistoryError(.invalidRequest) }
                snapshot = try await session.revertConversation(thread: review.sourceReference, beforeTurnID: turnID, expectedHeadTurnID: review.reviewedHeadTurnID)
            }
            try Task.checkCancellation()
            guard ownsHistorySource(threadID: threadID, incarnation: incarnation, fingerprint: review.sourceFingerprint) else { throw CancellationError() }
            try review.validateResult(snapshot)
            result = .conversationHistoryConfirmed(snapshot)
        } catch {
            if dispatched, error is CancellationError || (error as? ProviderHistoryError)?.kind == .outcomeUncertain {
                result = .conversationHistoryUnconfirmed
            } else if dispatched, !(error is ProviderHistoryError) { result = .conversationHistoryUnconfirmed }
            else { result = .failed(ConversationHistoryOperation.failureMessage) }
        }
        if let metadataID {
            if let close = beginMetadataClose(metadataID) { await close.value }
            metadataSessions.removeValue(forKey: metadataID)
        } else if review.kind == .rewindBeforeRun {
            // Retire the old event stream after every attempted native rewind.
            // Delayed notifications cannot become messages on its new history.
            await closeRuntime(threadID)
        }
        return result
    }
}

extension WorkspaceEngine {
    @discardableResult public func retryPostRunCheckpoint(threadID: UUID, runID: UUID, expectedAttemptID: UUID) async throws -> WorkspaceCommandReceipt {
        try await dispatch(.retryPostRunCheckpoint(threadID: threadID, runID: runID, expectedAttemptID: expectedAttemptID))
    }
    @discardableResult public func continueAfterPostRunCheckpoint(threadID: UUID, runID: UUID, expectedAttemptID: UUID) async throws -> WorkspaceCommandReceipt {
        try await dispatch(.continueAfterPostRunCheckpoint(threadID: threadID, runID: runID, expectedAttemptID: expectedAttemptID))
    }
    public func drainCheckpointInspections() async {
        while true {
            let jobs = checkpointReads.values.filter(\.inspection).map(\.task)
            guard !jobs.isEmpty else { return }; for job in jobs { await job.value }
        }
    }
    public func runCheckpointDiff(threadID: UUID, runID: UUID, maxBytes: Int = 1_048_576) async throws -> GitCheckpointDiff {
        _ = try await load()
        if await waitForRemovalCommit(threadID: threadID) { throw CancellationError() }
        guard let thread = revision.snapshot.threads.first(where: { $0.id == threadID }), let incarnation = threadIncarnations[threadID],
              let checkpoints = thread.runHistory?.first(where: { $0.id == runID })?.checkpoints,
              let baseline = checkpoints.baseline.receipt, let post = checkpoints.postRun?.receipt,
              checkpoints.baseline.phase == .ready, checkpoints.postRun?.phase == .ready,
              baseline.plan.workspacePath == thread.workspacePath, post.plan.workspacePath == thread.workspacePath,
              revision.snapshot.workspaceReady(for: thread), !closing, !stoppingEffects else { throw GitCheckpointError(.incomplete) }
        let session = try checkpointFactory(URL(fileURLWithPath: thread.workspacePath)), token = UUID()
        let task = Task { try await session.diff(from: baseline, to: post, paths: nil, ignoreWhitespace: false, maxBytes: maxBytes) }
        let drain = Task<Void, Never> { _ = try? await task.value }
        checkpointReads[token] = .init(threadID: threadID, projectID: thread.projectID, inspection: false, task: drain, cancel: { task.cancel() })
        defer { checkpointReads.removeValue(forKey: token) }
        return try await withTaskCancellationHandler {
            do {
                let value = try await task.value
                if await waitForRemovalCommit(threadID: threadID) { throw CancellationError() }
                guard checkpointDiffOwner(threadID: threadID, runID: runID, path: thread.workspacePath, incarnation: incarnation, baseline: baseline, post: post) else { throw CancellationError() }
                try Task.checkCancellation(); return value
            } catch {
                if await waitForRemovalCommit(threadID: threadID) { throw CancellationError() }
                guard checkpointDiffOwner(threadID: threadID, runID: runID, path: thread.workspacePath, incarnation: incarnation, baseline: baseline, post: post) else { throw CancellationError() }
                throw error
            }
        } onCancel: { task.cancel() }
    }
    @discardableResult public func settleThread(threadID: UUID, expectedWorkspacePath: String, reviewScript: Bool = false) async throws -> WorkspaceCommandReceipt {
        try await dispatch(.settleThread(threadID: threadID, expectedWorkspacePath: expectedWorkspacePath, reviewScript: reviewScript))
    }
    @discardableResult public func resumeThread(threadID: UUID, generationID: UUID) async throws -> WorkspaceCommandReceipt {
        try await dispatch(.resumeThread(threadID: threadID, generationID: generationID))
    }
    @discardableResult public func approveProjectScript(threadID: UUID, runID: UUID, expectedPlan: ProjectScriptExecutionPlan) async throws -> WorkspaceCommandReceipt {
        try await dispatch(.approveProjectScript(threadID: threadID, runID: runID, expectedPlan: expectedPlan))
    }
    @discardableResult public func stopProjectScript(threadID: UUID, runID: UUID) async throws -> WorkspaceCommandReceipt {
        try await dispatch(.stopProjectScript(threadID: threadID, runID: runID))
    }
    @discardableResult public func skipProjectScript(threadID: UUID, runID: UUID) async throws -> WorkspaceCommandReceipt {
        try await dispatch(.skipProjectScript(threadID: threadID, runID: runID))
    }
    @discardableResult public func retryProjectScript(threadID: UUID, runID: UUID) async throws -> WorkspaceCommandReceipt {
        try await dispatch(.retryProjectScript(threadID: threadID, runID: runID))
    }
    public func awaitProjectScriptCleanup(threadID: UUID, runID: UUID) async {
        while let task = scriptClosures[runID] { await task.value }
    }
    public func projectScriptOutput(threadID: UUID, runID: UUID) async throws -> AsyncStream<ProjectScriptOutputSnapshot> {
        _ = try await load()
        guard let run = revision.snapshot.threads.first(where: { $0.id == threadID })?.projectScript(runID: runID) else { throw CancellationError() }
        let log: ProjectScriptRunLog
        if let existing = scriptLogs[runID] { log = existing }
        else {
            log = .init(id: runID); scriptLogs[runID] = log
            if ![.waitingForCheckout, .discovering, .awaitingApproval, .starting, .running].contains(run.phase), scriptRuntimes[runID] == nil, scriptClosures[runID] == nil { await log.close() }
        }
        let stream = await log.stream()
        guard revision.snapshot.threads.first(where: { $0.id == threadID })?.projectScript(runID: runID) != nil else { throw CancellationError() }
        return stream
    }
    private func ownsScript(threadID: UUID, owner: ProjectScriptOwner, runID: UUID, incarnation: UUID, phases: [ThreadProjectScriptRunPhase]? = nil,
                            allowArchived: Bool = false, requireReady: Bool = true) -> Bool {
        guard !closing, !stoppingEffects, fatalError == nil, threadIncarnations[threadID] == incarnation,
              let thread = revision.snapshot.threads.first(where: { $0.id == threadID }), allowArchived || !thread.isArchived,
              let run = thread.projectScript(owner: owner), run.id == runID, phases.map({ $0.contains(run.phase) }) ?? true else { return false }
        if !requireReady { return true }
        return revision.snapshot.permitsScriptAction(owner: owner, thread: thread)
    }
    private func ownsScriptEvent(_ command: EngineCommand) -> Bool {
        switch command {
        case .projectScriptStarted(let thread, let attempt, let run, let token), .projectScriptExited(let thread, let attempt, let run, let token, _):
            return ownsScript(threadID: thread, owner: .setup(attemptID: attempt), runID: run, incarnation: token)
        case .projectScriptStopped(let thread, let attempt, let run, let token):
            return ownsScript(threadID: thread, owner: .setup(attemptID: attempt), runID: run, incarnation: token, allowArchived: true, requireReady: false)
        case .threadScriptStarted(let thread, let owner, let run, let token), .threadScriptExited(let thread, let owner, let run, let token, _):
            return ownsScript(threadID: thread, owner: owner, runID: run, incarnation: token)
        case .threadScriptStopped(let thread, let owner, let run, let token):
            return ownsScript(threadID: thread, owner: owner, runID: run, incarnation: token, allowArchived: true, requireReady: false)
        case .projectScriptEffectResult(let request, _, let token):
            guard let thread = request.threadID, let run = request.projectScriptRunID, let owner = request.projectScriptOwner else { return false }
            return ownsScript(threadID: thread, owner: owner, runID: run, incarnation: token)
        case .threadResumed(let thread, let generation, let token):
            return !closing && !stoppingEffects && fatalError == nil && threadIncarnations[thread] == token && revision.snapshot.threads.contains { $0.id == thread && $0.settlement?.id == generation && $0.settlement?.phase == .resuming }
        default: return true
        }
    }
    private func waitForScriptCommit(_ runID: UUID) async {
        while scriptCommitRuns.contains(runID) { await withCheckedContinuation { scriptCommitWaiters.append($0) } }
    }
    private func performProjectScript(_ request: WorkspaceEffectRequest) async throws -> EffectResult {
        guard let threadID = request.threadID, let runID = request.projectScriptRunID, let owner = request.projectScriptOwner,
              let incarnation = threadIncarnations[threadID] else { return .cancelled }
        await waitForScriptCommit(runID)
        guard let thread = revision.snapshot.threads.first(where: { $0.id == threadID }),
              let project = revision.snapshot.projects.first(where: { $0.id == thread.projectID }) else { return .cancelled }
        switch request {
        case .resolveProjectScript, .resolveThreadScript:
            guard ownsScript(threadID: threadID, owner: owner, runID: runID, incarnation: incarnation, phases: [.discovering]) else { return .cancelled }
            do {
                if case .settlement(let generation) = owner, let prerequisite = settlementPrerequisites[generation] { await prerequisite.value }
                if await waitForRemovalCommit(threadID: threadID, projectID: thread.projectID) { throw CancellationError() }
                await waitForScriptCommit(runID)
                guard ownsScript(threadID: threadID, owner: owner, runID: runID, incarnation: incarnation, phases: [.discovering]) else { throw CancellationError() }
                try Task.checkCancellation()
                let plan = try await projectScriptPlanner(.init(id: runID, projectRoot: URL(fileURLWithPath: project.path), workspacePath: URL(fileURLWithPath: thread.workspacePath), role: owner.role))
                if await waitForRemovalCommit(threadID: threadID, projectID: thread.projectID) { throw CancellationError() }
                await waitForScriptCommit(runID)
                guard ownsScript(threadID: threadID, owner: owner, runID: runID, incarnation: incarnation, phases: [.discovering]) else { throw CancellationError() }
                try Task.checkCancellation()
                if let plan {
                    try plan.validate()
                    guard plan.id == runID, plan.workspacePath == thread.workspacePath, plan.projectRoot == project.path,
                          owner.role == .setup ? plan.script.runOnWorktreeCreate : plan.script.runOnSettle else { throw ProjectScriptExecutionError(.invalidPlan) }
                    if owner.role == .settle, plan.projectRootIdentity == plan.workspaceIdentity { return .projectScriptResolved(nil) }
                }
                return .projectScriptResolved(plan)
            } catch {
                if await waitForRemovalCommit(threadID: threadID, projectID: thread.projectID) { throw CancellationError() }
                await waitForScriptCommit(runID)
                guard ownsScript(threadID: threadID, owner: owner, runID: runID, incarnation: incarnation, phases: [.discovering]) else { throw CancellationError() }
                try Task.checkCancellation(); throw CoincideError(ThreadProjectScriptRun.discoveryError(for: owner.role))
            }
        case .startProjectScript(_, _, let plan), .startThreadScript(_, _, let plan):
            guard ownsScript(threadID: threadID, owner: owner, runID: runID, incarnation: incarnation, phases: [.starting]),
                  thread.projectScript(owner: owner)?.plan == plan, scriptRuntimes[runID] == nil else { return .cancelled }
            let log = scriptLogs[runID] ?? ProjectScriptRunLog(id: runID); scriptLogs[runID] = log
            let session: any ProjectScriptExecutionSession
            do { session = try projectScriptFactory(plan) }
            catch { await log.close(); throw CoincideError(ThreadProjectScriptRun.executionError(for: owner.role)) }
            let output: Task<Void, Never> = Task {
                do { try await session.consumeOutput { chunk in await log.append(chunk.data) } } catch { }
                await session.close(); await log.close()
            }
            scriptRuntimes[runID] = .init(threadID: threadID, projectID: thread.projectID, owner: owner,
                incarnation: incarnation, session: session, output: output, monitor: nil)
            do {
                try await session.prepare()
                if await waitForRemovalCommit(threadID: threadID, projectID: thread.projectID) { throw CancellationError() }
                await waitForScriptCommit(runID)
                guard ownsScript(threadID: threadID, owner: owner, runID: runID, incarnation: incarnation, phases: [.starting]), scriptRuntimes[runID] != nil else { throw CancellationError() }
                try Task.checkCancellation()
                try session.start()
                try await session.waitUntilStarted()
                if await waitForRemovalCommit(threadID: threadID, projectID: thread.projectID) { throw CancellationError() }
                await waitForScriptCommit(runID)
                guard ownsScript(threadID: threadID, owner: owner, runID: runID, incarnation: incarnation, phases: [.starting]) else { throw CancellationError() }
                try Task.checkCancellation()
                _ = try await enqueue(.threadScriptStarted(threadID: threadID, owner: owner, runID: runID, incarnation: incarnation))
                guard ownsScript(threadID: threadID, owner: owner, runID: runID, incarnation: incarnation, phases: [.running]), scriptRuntimes[runID] != nil else { throw CancellationError() }
                let monitor = Task { [weak self] in
                    let result: ProjectScriptCommandExit?
                    do { result = try await session.waitForCommandExit() } catch { result = nil }
                    guard !Task.isCancelled, let self else { return }
                    _ = try? await self.enqueue(.threadScriptExited(threadID: threadID, owner: owner, runID: runID, incarnation: incarnation, result: result))
                }
                scriptRuntimes[runID]?.monitor = monitor
                return .succeeded
            } catch {
                await session.close(); output.cancel(); await log.close()
                if scriptRuntimes[runID]?.incarnation == incarnation { scriptRuntimes.removeValue(forKey: runID)?.monitor?.cancel() }
                try Task.checkCancellation()
                if !ownsScript(threadID: threadID, owner: owner, runID: runID, incarnation: incarnation, phases: [.starting]) { throw CancellationError() }
                throw CoincideError(ThreadProjectScriptRun.executionError(for: owner.role))
            }
        default: return .cancelled
        }
    }
    private func beginScriptDecisionCleanup(previous: WorkspaceSnapshot, next: WorkspaceSnapshot, removedEffects: [WorkspaceEffect], projectIDs: inout Set<UUID>, threadIDs: inout Set<UUID>) -> [Task<Void, Never>] {
        var jobs: [Task<Void, Never>] = []
        for old in previous.threads {
            let current = next.threads.first(where: { $0.id == old.id })
            for (owner, run) in old.projectScripts {
                let currentRun = current?.projectScript(owner: owner)
                let stopping = currentRun?.id == run.id && (currentRun?.phase == .stopping || (owner.role == .settle && current?.settlement?.phase == .resuming))
                let settling = owner.role == .setup && current?.settlement != nil && old.settlement?.id != current?.settlement?.id
                let retired = current == nil || current?.workspacePath != old.workspacePath || currentRun?.id != run.id || (current?.isArchived == true && !old.isArchived)
                if !stopping, !retired, !settling, let terminal = currentRun, terminal.phase != run.phase,
                   [.skipped, .failed, .interrupted, .cancelled].contains(terminal.phase),
                   scriptRuntimes[run.id] == nil, scriptClosures[run.id] == nil, let log = scriptLogs[run.id] {
                    projectIDs.insert(old.projectID); threadIDs.insert(old.id); jobs.append(Task { await log.close() })
                }
                if settling, let existing = scriptClosures[run.id] {
                    projectIDs.insert(old.projectID); threadIDs.insert(old.id); jobs.append(existing); continue
                }
                guard stopping || retired || settling, scriptClosures[run.id] == nil else { continue }
                projectIDs.insert(old.projectID); threadIDs.insert(old.id)
                let runtime = scriptRuntimes.removeValue(forKey: run.id), log = scriptLogs[run.id]
                runtime?.monitor?.cancel(); runtime?.output.cancel()
                let effectIDs = removedEffects.filter { $0.request.projectScriptRunID == run.id && $0.status == .running && $0.leaseOwner == workerID }.map(\.id)
                let incarnation = threadIncarnations[old.id]
                let task: Task<Void, Never> = Task.detached { [weak self] in
                    if let runtime { await runtime.session.close() }
                    for effect in effectIDs { await self?.awaitRetiringEffect(effect) }
                    await log?.close()
                    if let self, let incarnation { _ = try? await self.enqueue(.threadScriptStopped(threadID: old.id, owner: owner, runID: run.id, incarnation: incarnation)) }
                    await self?.projectScriptCleanupFinished(run.id, threadID: old.id)
                }
                scriptClosures[run.id] = task; jobs.append(task)
            }
        }
        return jobs
    }
    private func beginSettlementResumeCleanup(previous: WorkspaceSnapshot, next: WorkspaceSnapshot, projectIDs: inout Set<UUID>, threadIDs: inout Set<UUID>) -> [Task<Void, Never>] {
        var jobs: [Task<Void, Never>] = []
        for thread in next.threads {
            guard let settlement = thread.settlement, settlement.phase == .resuming, settlementClosures[settlement.id] == nil,
                  let token = threadIncarnations[thread.id] else { continue }
            var drains = thread.projectScripts.compactMap { scriptClosures[$0.1.id] }
            if let prerequisite = settlementPrerequisites[settlement.id] { drains.append(prerequisite) }
            projectIDs.insert(thread.projectID); threadIDs.insert(thread.id)
            let task: Task<Void, Never> = Task.detached { [weak self] in
                for drain in drains { await drain.value }
                _ = try? await self?.enqueue(.threadResumed(threadID: thread.id, generationID: settlement.id, incarnation: token))
                await self?.settlementCleanupFinished(settlement.id)
            }
            settlementClosures[settlement.id] = task; jobs.append(task)
        }
        return jobs
    }
    private func settlementCleanupFinished(_ id: UUID) { settlementClosures.removeValue(forKey: id); settlementPrerequisites.removeValue(forKey: id) }
    private func projectScriptCleanupFinished(_ id: UUID, threadID: UUID) {
        scriptClosures.removeValue(forKey: id)
        if revision.snapshot.threads.first(where: { $0.id == threadID })?.projectScript(runID: id) == nil { scriptLogs.removeValue(forKey: id) }
    }
    private func closeAllProjectScripts() async {
        let runtimes = scriptRuntimes; scriptRuntimes = [:]
        for runtime in runtimes.values { runtime.monitor?.cancel(); runtime.output.cancel() }
        await withTaskGroup(of: Void.self) { group in
            for runtime in runtimes.values { group.addTask { await runtime.session.close() } }
            await group.waitForAll()
        }
        for (id, log) in scriptLogs where scriptClosures[id] == nil { await log.close() }
    }
}

private extension WorkspaceEngine {
    func checkpointProviderReleased(threadID: UUID, runID: UUID) -> Bool {
        guard !closing, !stoppingEffects, fatalError == nil,
              let thread = revision.snapshot.threads.first(where: { $0.id == threadID }), thread.activeRun?.id == runID,
              thread.activeRun?.stopRequested == false, !thread.isArchived else { return false }
        return thread.runHistory?.first(where: { $0.id == runID })?.checkpoints?.providerReleased ?? true
    }
    func checkpointDiffOwner(threadID: UUID, runID: UUID, path: String, incarnation: UUID,
                             baseline: GitCheckpointReceipt, post: GitCheckpointReceipt) -> Bool {
        guard !closing, !stoppingEffects, fatalError == nil, threadIncarnations[threadID] == incarnation,
              let thread = revision.snapshot.threads.first(where: { $0.id == threadID && $0.workspacePath == path }),
              revision.snapshot.workspaceReady(for: thread), let checkpoints = thread.runHistory?.first(where: { $0.id == runID })?.checkpoints else { return false }
        return checkpoints.baseline.receipt == baseline && checkpoints.postRun?.receipt == post
    }
    func ownsCheckpoint(threadID: UUID, runID: UUID, stage: RunCheckpointStage, attemptID: UUID,
                        path: String, incarnation: UUID, recovery: Bool = false) -> Bool {
        guard !closing, !stoppingEffects, fatalError == nil, threadIncarnations[threadID] == incarnation,
              let thread = revision.snapshot.threads.first(where: { $0.id == threadID && $0.workspacePath == path }),
              revision.snapshot.workspaceReady(for: thread), recovery || !thread.isArchived,
              let attempt = thread.runCheckpoint(runID: runID, stage: stage), attempt.id == attemptID, attempt.workspacePath == path else { return false }
        if recovery { return attempt.phase == .interrupted && attempt.plan != nil }
        guard attempt.phase.isRunning else { return false }
        if stage == .baseline { return thread.activeRun?.id == runID && thread.activeRun?.stopRequested == false }
        return thread.heldPostRunCheckpoint?.runID == runID && thread.heldPostRunCheckpoint?.attempt.id == attemptID
    }
    func ownsCheckpointEvent(_ command: EngineCommand) -> Bool {
        switch command {
        case .runCheckpointEffectResult(let request, _, let incarnation):
            guard let threadID = request.threadID, let owner = request.checkpointOwner,
                  let path = revision.snapshot.threads.first(where: { $0.id == threadID })?.runCheckpoint(runID: owner.runID, stage: owner.stage)?.workspacePath else { return false }
            return ownsCheckpoint(threadID: threadID, runID: owner.runID, stage: owner.stage, attemptID: owner.attemptID, path: path, incarnation: incarnation)
        case .runCheckpointRecovered(let thread, let run, let stage, let attempt, let path, let incarnation, _):
            return ownsCheckpoint(threadID: thread, runID: run, stage: stage, attemptID: attempt, path: path, incarnation: incarnation, recovery: true)
        default: return true
        }
    }
    func awaitCheckpointDrains(threadID: UUID, excludingAttempt: UUID? = nil) async {
        while true {
            let tasks = checkpointDrains.values.filter { $0.threadID == threadID && $0.attemptID != excludingAttempt }.map(\.task)
            guard !tasks.isEmpty else { return }; for task in tasks { await task.value }
        }
    }
    func performRunCheckpoint(_ request: WorkspaceEffectRequest) async throws -> EffectResult {
        guard let threadID = request.threadID, let owner = request.checkpointOwner, let incarnation = threadIncarnations[threadID],
              let thread = revision.snapshot.threads.first(where: { $0.id == threadID }),
              let attempt = thread.runCheckpoint(runID: owner.runID, stage: owner.stage),
              ownsCheckpoint(threadID: threadID, runID: owner.runID, stage: owner.stage, attemptID: owner.attemptID, path: attempt.workspacePath, incarnation: incarnation) else { return .cancelled }
        await awaitCheckpointDrains(threadID: threadID, excludingAttempt: owner.attemptID)
        try Task.checkCancellation()
        guard ownsCheckpoint(threadID: threadID, runID: owner.runID, stage: owner.stage, attemptID: owner.attemptID, path: attempt.workspacePath, incarnation: incarnation) else { throw CancellationError() }
        // Interrupt/error teardown can already be detached when the post boundary is committed.
        // Join only this thread's existing closes; process I/O never runs on the command inbox.
        let prerequisites = cleanupTasks.values.filter { $0.threadIDs.contains(threadID) }.map(\.task)
        for task in prerequisites { await task.value }
        if await waitForRemovalCommit(threadID: threadID, projectID: thread.projectID) { throw CancellationError() }
        guard ownsCheckpoint(threadID: threadID, runID: owner.runID, stage: owner.stage, attemptID: owner.attemptID, path: attempt.workspacePath, incarnation: incarnation) else { throw CancellationError() }
        try Task.checkCancellation()
        let session = try checkpointFactory(URL(fileURLWithPath: attempt.workspacePath))
        do {
            let result: EffectResult
            switch request {
            case .resolveRunCheckpoint:
                guard attempt.phase == .resolving, attempt.plan == nil else { return .cancelled }
                let plan = try await session.prepare(id: attempt.id)
                try plan.validate()
                guard plan.id == attempt.id, plan.workspacePath == attempt.workspacePath else { throw GitCheckpointError(.invalidPlan) }
                result = .checkpointResolved(plan)
            case .captureRunCheckpoint(_, _, _, let plan):
                guard attempt.phase == .capturing, attempt.plan == plan else { return .cancelled }
                let receipt = try await session.capture(plan)
                try receipt.validate(); guard receipt.plan == plan else { throw GitCheckpointError(.invalidPlan) }
                var cleanupWarning = false
                do { cleanupWarning = try await session.finalizeScratch(receipt) == .preserved }
                catch is CancellationError { throw CancellationError() }
                catch { cleanupWarning = true }
                result = .checkpointCaptured(receipt, cleanupWarning: cleanupWarning)
            default: return .cancelled
            }
            if await waitForRemovalCommit(threadID: threadID, projectID: thread.projectID) { throw CancellationError() }
            guard ownsCheckpoint(threadID: threadID, runID: owner.runID, stage: owner.stage, attemptID: owner.attemptID, path: attempt.workspacePath, incarnation: incarnation) else { throw CancellationError() }
            try Task.checkCancellation(); return result
        } catch {
            if await waitForRemovalCommit(threadID: threadID, projectID: thread.projectID) { throw CancellationError() }
            guard ownsCheckpoint(threadID: threadID, runID: owner.runID, stage: owner.stage, attemptID: owner.attemptID, path: attempt.workspacePath, incarnation: incarnation) else { throw CancellationError() }
            try Task.checkCancellation()
            if let error = error as? GitCheckpointError, error.kind == .notRepository { return .checkpointUnavailable }
            throw error
        }
    }
    func beginCheckpointCleanup(previous: WorkspaceSnapshot, next: WorkspaceSnapshot, projectIDs: inout Set<UUID>, threadIDs: inout Set<UUID>, jobs: inout [Task<Void, Never>]) {
        for (effectID, request) in effectRequests {
            guard let threadID = request.threadID, let owner = request.checkpointOwner,
                  let old = previous.threads.first(where: { $0.id == threadID }) else { continue }
            let current = next.threads.first(where: { $0.id == threadID })
            let active = current?.runCheckpoint(runID: owner.runID, stage: owner.stage)
            if current?.isArchived != true, current?.workspacePath == old.workspacePath, active?.id == owner.attemptID, active?.phase.isRunning == true { continue }
            guard let task = effects[effectID], checkpointDrains[effectID] == nil else { continue }
            task.cancel(); projectIDs.insert(old.projectID); threadIDs.insert(threadID)
            let drain = Task<Void, Never> { [weak self] in await task.value; await self?.checkpointDrainFinished(effectID) }
            checkpointDrains[effectID] = .init(threadID: threadID, attemptID: owner.attemptID, task: drain); jobs.append(drain)
        }
        for (id, read) in checkpointReads where !next.threads.contains(where: { $0.id == read.threadID && $0.workspacePath == previous.threads.first(where: { $0.id == read.threadID })?.workspacePath && (!$0.isArchived || read.inspection) }) {
            checkpointReads.removeValue(forKey: id); read.cancel()
            projectIDs.insert(read.projectID); threadIDs.insert(read.threadID); jobs.append(read.task)
        }
    }
    func checkpointDrainFinished(_ id: UUID) { checkpointDrains.removeValue(forKey: id) }
    func cancelCheckpointReads() {
        let reads = checkpointReads; checkpointReads = [:]
        for read in reads.values {
            read.cancel()
            _ = startCleanup(projectIDs: [read.projectID], threadIDs: [read.threadID], sessions: [], jobs: [read.task])
        }
    }
    func scheduleCheckpointReconciliation() {
        let gate = checkpointInspectionGate
        for thread in revision.snapshot.threads {
            var candidates: [(UUID, RunCheckpointStage, ThreadRunCheckpointAttempt)] = []
            for record in thread.runHistory ?? [] {
                guard let checkpoints = record.checkpoints else { continue }
                let baseline = checkpoints.baseline
                if baseline.phase == .interrupted, baseline.plan != nil { candidates.append((record.id, .baseline, baseline)) }
                if let post = checkpoints.postRun, post.phase == .interrupted, post.plan != nil { candidates.append((record.id, .postRun, post)) }
            }
            guard !candidates.isEmpty, let incarnation = threadIncarnations[thread.id] else { continue }
            let token = UUID(), factory = checkpointFactory, pending = candidates
            let task = Task<Void, Never> { [weak self] in
                for (runID, stage, attempt) in pending {
                    if Task.isCancelled { break }
                    guard let plan = attempt.plan else { continue }
                    do {
                        let receipt: GitCheckpointReceipt? = try await gate.perform(key: String(thread.id.uuid.0 & 3)) {
                            let session = try factory(URL(fileURLWithPath: attempt.workspacePath))
                            if case .ready(let receipt) = try await session.inspect(plan) { return receipt }; return nil
                        }
                        try Task.checkCancellation()
                        guard let self, let receipt else { continue }
                        if await self.waitForRemovalCommit(threadID: thread.id, projectID: thread.projectID) { break }
                        guard await self.ownsCheckpoint(threadID: thread.id, runID: runID, stage: stage, attemptID: attempt.id, path: attempt.workspacePath, incarnation: incarnation, recovery: true) else { continue }
                        _ = try await self.enqueue(.runCheckpointRecovered(threadID: thread.id, runID: runID, stage: stage, attemptID: attempt.id, path: attempt.workspacePath, incarnation: incarnation, receipt: receipt))
                    } catch { if Task.isCancelled { break } }
                }
                await self?.checkpointReadFinished(token)
            }
            checkpointReads[token] = .init(threadID: thread.id, projectID: thread.projectID, inspection: true, task: task, cancel: { task.cancel() })
        }
    }
    func checkpointReadFinished(_ id: UUID) { checkpointReads.removeValue(forKey: id) }
}

/// Serial command decisions and durable commits are independent of provider I/O.
public actor WorkspaceEngine {
    private struct HistoryRead: Sendable {
        let threadID: UUID
        let projectID: UUID
        let drain: Task<Void, Never>
        let cancel: @Sendable () -> Void
    }
    private var historyReads: [UUID: HistoryRead] = [:]
    private struct PreparedHistoryReview: Sendable {
        let review: ConversationHistoryReview
        let digest: String
    }
    private var historyReviews: [UUID: PreparedHistoryReview] = [:]
    private var acceptingHistoryReviews: Set<UUID> = []
    private struct PreparedCheckpointRestore: Sendable {
        let review: RunCheckpointRestoreReview
        let digest: String
    }
    private var checkpointRestoreReviews: [UUID: PreparedCheckpointRestore] = [:]
    private var acceptingCheckpointRestores: Set<UUID> = []
    public typealias ProviderFactory = @Sendable (CodingThread) throws -> any ProviderSession
    public typealias WorktreeFactory = @Sendable (GitWorktreeRequest) throws -> any WorkspaceWorktreeSession
    public typealias CloneFactory = @Sendable (GitClonePlan) throws -> any ProjectCloneSession
    public typealias IdentityResolver = @Sendable (URL) async throws -> RepositoryIdentity?
    public typealias ProjectScriptPlanner = @Sendable (ProjectScriptPlanningContext) async throws -> ProjectScriptExecutionPlan?
    public typealias ProjectScriptFactory = @Sendable (ProjectScriptExecutionPlan) throws -> any ProjectScriptExecutionSession
    public typealias CheckpointFactory = @Sendable (URL) throws -> any RunCheckpointSession
    private let checkpointFactory: CheckpointFactory
    private struct CheckpointRead: Sendable {
        let threadID: UUID
        let projectID: UUID
        let inspection: Bool
        let task: Task<Void, Never>
        let cancel: @Sendable () -> Void
    }
    private var checkpointReads: [UUID: CheckpointRead] = [:]
    private struct CheckpointDrain: Sendable { let threadID: UUID; let attemptID: UUID; let task: Task<Void, Never> }
    private var checkpointDrains: [UUID: CheckpointDrain] = [:]
    private let checkpointInspectionGate = GitOperationGate()
    private struct ScriptRuntime: Sendable {
        let threadID: UUID, projectID: UUID
        let owner: ProjectScriptOwner
        let incarnation: UUID
        let session: any ProjectScriptExecutionSession
        let output: Task<Void, Never>
        var monitor: Task<Void, Never>?
    }
    private let projectScriptPlanner: ProjectScriptPlanner
    private let projectScriptFactory: ProjectScriptFactory
    private var scriptRuntimes: [UUID: ScriptRuntime] = [:]
    private var scriptLogs: [UUID: ProjectScriptRunLog] = [:]
    private var scriptClosures: [UUID: Task<Void, Never>] = [:]
    private var settlementClosures: [UUID: Task<Void, Never>] = [:]
    private var settlementPrerequisites: [UUID: Task<Void, Never>] = [:]
    private var scriptCommitRuns: Set<UUID> = []
    private var scriptCommitWaiters: [CheckedContinuation<Void, Never>] = []
    private struct Envelope: Sendable {
        var id: UUID
        var command: EngineCommand
        var continuation: CheckedContinuation<WorkspaceCommandReceipt, any Error>
    }
    private struct Runtime: Sendable {
        var id: UUID
        var projectID: UUID
        var session: any ProviderSession
        var provider: ProviderKind
        var path: String
        var acpAgent: ACPAgentConfiguration?
        var reader: Task<Void, Never>?
    }
    private struct MetadataRuntime: Sendable {
        var session: any ProviderSession
        var path: String
        var threadID: UUID?
        var projectID: UUID?
        var configuration: ProviderConfiguration?
        var closeTask: Task<Void, Never>?
    }
    private struct Cleanup: Sendable {
        var projectIDs: Set<UUID>
        var threadIDs: Set<UUID>
        var workspacePaths: Set<String>
        var task: Task<Void, Never>
    }
    private struct IdentityRefresh: Sendable {
        var id: UUID
        var incarnation: UUID
        var path: String
        var task: Task<RepositoryIdentity?, any Error>
    }
    private let database: WorkspaceDatabase
    public nonisolated let attachments: AttachmentStore
    public nonisolated let worktreesRoot: URL
    private let worktreeFactory: WorktreeFactory
    private struct WorktreeInspection: Sendable {
        let threadID: UUID
        let projectID: UUID
        let task: Task<GitWorktreeResult?, any Error>
    }
    private var worktreeInspections: [UUID: WorktreeInspection] = [:]
    private var threadIncarnations: [UUID: UUID] = [:]
    private let ownership: WorkspaceRuntimeLock
    private let factory: ProviderFactory
    private let cloneFactory: CloneFactory
    private let identityResolver: IdentityResolver
    private let identityGate = GitOperationGate()
    private let worktreeInspectionGate = GitOperationGate()
    private let workerID = UUID()
    private let inbox: AsyncStream<Envelope>
    private let incoming: AsyncStream<Envelope>.Continuation
    private var commandWorker: Task<Void, Never>?
    private var initialization: Task<WorkspaceSnapshot, any Error>?
    private var shutdownTask: Task<Void, Never>?
    private var revision = WorkspaceRevision(snapshot: WorkspaceSnapshot(), sequence: 0)
    private var loaded = false
    private var closing = false
    private var stoppingEffects = false
    private var fatalError: String?
    private var pendingCommands = 0
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []
    private var listeners: [UUID: AsyncStream<WorkspaceUpdate>.Continuation] = [:]
    private var pumping = false
    private var effectWakeGeneration = 0
    private var effects: [UUID: Task<Void, Never>] = [:]
    private var effectRequests: [UUID: WorkspaceEffectRequest] = [:]
    private var runtimes: [UUID: Runtime] = [:]
    private var metadataSessions: [UUID: MetadataRuntime] = [:]
    private var projectIncarnations: [UUID: UUID] = [:]
    private var identityRefreshes: [UUID: IdentityRefresh] = [:]
    private var cleanupTasks: [UUID: Cleanup] = [:]
    private var retiringEffects: Set<UUID> = []
    private var retiringEffectWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]
    private var completedDuringCommit: Set<UUID>?
    private var removalCommitProjects: Set<UUID> = []
    private var removalCommitThreads: Set<UUID> = []
    private var removalCommitWaiters: [CheckedContinuation<Bool, Never>] = []
    private var cloneProgressTimes: [UUID: (ContinuousClock.Instant, GitCloneProgress)] = [:]
    private let encoder: JSONEncoder = { let value = JSONEncoder(); value.outputFormatting = [.sortedKeys]; return value }()

    public init(url: URL, providerFactory: @escaping ProviderFactory = { try ProviderSessions.make(for: $0) },
                cloneFactory: @escaping CloneFactory = { GitCloneService(plan: $0) },
                identityResolver: @escaping IdentityResolver = { try await RepositoryIdentityResolver(root: $0).resolve() },
                worktreeFactory: @escaping WorktreeFactory = { GitWorktreeService(request: $0) },
                projectScriptPlanner: @escaping ProjectScriptPlanner = { try await ProjectScriptSetupPlanner.plan($0) },
                projectScriptFactory: @escaping ProjectScriptFactory = { _ in throw ProjectScriptExecutionError(.helperUnavailable) },
                checkpointFactory: @escaping CheckpointFactory = { GitCheckpointService(root: $0) }) throws {
        ownership = try WorkspaceRuntimeLock(url: url.appendingPathExtension("runtime-lock"))
        database = try WorkspaceDatabase(url: url)
        attachments = try AttachmentStore(root: url.deletingLastPathComponent().appendingPathComponent("Attachments", isDirectory: true))
        factory = providerFactory
        self.cloneFactory = cloneFactory
        self.identityResolver = identityResolver
        self.worktreeFactory = worktreeFactory
        self.projectScriptPlanner = projectScriptPlanner; self.projectScriptFactory = projectScriptFactory
        self.checkpointFactory = checkpointFactory
        worktreesRoot = url.deletingLastPathComponent().appendingPathComponent("Worktrees", isDirectory: true).standardizedFileURL
        try FileManager.default.createDirectory(at: worktreesRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let pair = AsyncStream<Envelope>.makeStream()
        inbox = pair.stream; incoming = pair.continuation
    }
    public func load() async throws -> WorkspaceSnapshot {
        guard !closing else { throw CancellationError() }
        if loaded { return revision.snapshot }
        if let initialization { return try await initialization.value }
        let task = Task { try await self.initialize() }
        initialization = task
        return try await task.value
    }
    private func initialize() async throws -> WorkspaceSnapshot {
        revision = try await database.revision()
        _ = try await database.cancelEffectsAfterProcessLoss()
        var recovered = revision.snapshot; recovered.recoverInterruptedWork()
        recovered = await reconcileCompletedClones(in: recovered)
        let receipt = try await database.commit(recovered, event: "workspace.opened", commandID: UUID(), expectedSequence: revision.sequence)
        revision = .init(snapshot: recovered, sequence: receipt.sequence)
        projectIncarnations = Dictionary(uniqueKeysWithValues: recovered.projects.map { ($0.id, UUID()) })
        threadIncarnations = Dictionary(uniqueKeysWithValues: recovered.threads.map { ($0.id, UUID()) })
        loaded = true
        let stream = inbox
        commandWorker = Task { [weak self] in
            for await envelope in stream {
                guard let self else { envelope.continuation.resume(throwing: CancellationError()); continue }
                await self.process(envelope)
            }
        }
        publish()
        scheduleIdentityRefreshes(previous: nil)
        scheduleWorktreeReconciliation()
        scheduleCheckpointReconciliation()
        return recovered
    }
    public func current() -> WorkspaceUpdate { .init(snapshot: revision.snapshot, sequence: revision.sequence, error: fatalError) }
    public func updates() -> AsyncStream<WorkspaceUpdate> {
        let id = UUID(), pair = AsyncStream<WorkspaceUpdate>.makeStream(bufferingPolicy: .bufferingNewest(1))
        listeners[id] = pair.continuation
        if loaded { pair.continuation.yield(current()) }
        pair.continuation.onTermination = { [weak self] _ in Task { await self?.removeListener(id) } }
        return pair.stream
    }
    private func removeListener(_ id: UUID) { listeners.removeValue(forKey: id) }
    private func publish(error: String? = nil) {
        let update = WorkspaceUpdate(snapshot: revision.snapshot, sequence: revision.sequence, error: error ?? fatalError)
        for listener in listeners.values { listener.yield(update) }
    }
    @discardableResult public func dispatch(_ command: WorkspaceCommand, id: UUID = UUID()) async throws -> WorkspaceCommandReceipt {
        _ = try await load()
        guard !stoppingEffects else { throw CancellationError() }
        let receipt = try await enqueue(.client(command), id: id)
        if let rejection = receipt.rejection { throw WorkspaceCommandError(rejection) }
        return receipt
    }
    /// A retry first checks the previous attempt's durable publication evidence. A crash or
    /// late Cancel must not overwrite or clone over an already completed destination.
    @discardableResult public func retryProjectClone(_ projectID: UUID) async throws -> WorkspaceCommandReceipt {
        _ = try await load()
        guard !stoppingEffects else { throw CancellationError() }
        guard let clone = revision.snapshot.projects.first(where: { $0.id == projectID })?.clone, clone.canRetry else {
            throw WorkspaceCommandError("This project has no interrupted clone to retry.")
        }
        if try await cloneFactory(clone.plan).isCompleted() {
            guard !stoppingEffects else { throw CancellationError() }
            return try await enqueue(.effectResult(.projectClone(projectID: projectID, plan: clone.plan), .succeeded))
        }
        let plan = try GitClonePlan.prepare(source: clone.plan.source, destination: URL(fileURLWithPath: clone.plan.destinationPath))
        return try await dispatch(.retryProjectClone(projectID: projectID, plan: plan))
    }
    /// Record the destination before resolving Git references. The command rechecks the source
    /// and first-turn boundary after any UI command that was already queued.
    @discardableResult public func beginWorktreePreparation(threadID: UUID, selection: GitWorktreeSelection,
                                                          submodules: ProjectWorktreeSubmoduleMode = .none, reviewSetup: Bool = false) async throws -> WorkspaceCommandReceipt {
        _ = try await load()
        if await waitForRemovalCommit(threadID: threadID) { throw CancellationError() }
        try Task.checkCancellation()
        guard !stoppingEffects, let thread = revision.snapshot.threads.first(where: { $0.id == threadID }),
              let incarnation = threadIncarnations[threadID] else { throw CancellationError() }
        let source = thread.workspacePreparation.flatMap { $0.canRetry ? $0.request.sourcePath : nil } ?? thread.workspacePath
        if let setup = thread.workspacePreparation?.setup, scriptRuntimes[setup.id] != nil || scriptClosures[setup.id] != nil {
            throw WorkspaceCommandError("Stop this conversation's setup or background jobs before choosing another worktree.")
        }
        let request = GitWorktreeRequest(sourcePath: source, destinationRoot: worktreesRoot.path, selection: selection, submodules: submodules)
        let receipt = try await enqueue(.beginWorktreePreparation(threadID: threadID, request: request, expectedSourcePath: thread.workspacePath, previousAttemptID: nil, incarnation: incarnation, reviewSetup: reviewSetup))
        if let rejection = receipt.rejection { throw WorkspaceCommandError(rejection) }; return receipt
    }
    @discardableResult public func cancelWorktreePreparation(_ threadID: UUID) async throws -> WorkspaceCommandReceipt {
        try await dispatch(.cancelWorktreePreparation(threadID))
    }
    /// Inspect an exact saved plan first. An unproven partial checkout is preserved, and a new
    /// attempt gets another managed folder rather than resuming Git over existing bytes.
    @discardableResult public func retryWorktreePreparation(_ threadID: UUID) async throws -> WorkspaceCommandReceipt {
        _ = try await load()
        if await waitForRemovalCommit(threadID: threadID) { throw CancellationError() }
        try Task.checkCancellation()
        guard !stoppingEffects, let thread = revision.snapshot.threads.first(where: { $0.id == threadID }),
              let state = thread.workspacePreparation, state.canRetry,
              let incarnation = threadIncarnations[threadID], state.request.destinationRoot == worktreesRoot.path else {
            throw WorkspaceCommandError("This conversation has no interrupted workspace preparation to retry.")
        }
        if let plan = state.plan {
            let session = try worktreeFactory(state.request), token = UUID()
            let task = Task { try await session.inspectCompletion(plan) }
            worktreeInspections[token] = .init(threadID: threadID, projectID: thread.projectID, task: task)
            defer { worktreeInspections.removeValue(forKey: token) }
            let result: GitWorktreeResult?
            do {
                result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            } catch {
                if await waitForRemovalCommit(threadID: threadID, projectID: thread.projectID) { throw CancellationError() }
                guard ownsWorktree(threadID: threadID, attemptID: state.id, incarnation: incarnation), !task.isCancelled else { throw CancellationError() }
                try Task.checkCancellation(); throw error
            }
            if await waitForRemovalCommit(threadID: threadID, projectID: thread.projectID) { throw CancellationError() }
            guard ownsWorktree(threadID: threadID, attemptID: state.id, incarnation: incarnation), !task.isCancelled else { throw CancellationError() }
            try Task.checkCancellation()
            if let result {
                try ThreadWorkspacePreparation.validate(result: result, plan: plan)
                return try await enqueue(.effectResult(.prepareWorktree(threadID: threadID, plan: plan), .worktreePrepared(result)))
            }
        }
        guard ownsWorktree(threadID: threadID, attemptID: state.id, incarnation: incarnation) else { throw CancellationError() }
        let request = GitWorktreeRequest(sourcePath: state.request.sourcePath, destinationRoot: worktreesRoot.path, selection: state.request.selection, submodules: state.request.submodules)
        let receipt = try await enqueue(.beginWorktreePreparation(threadID: threadID, request: request, expectedSourcePath: thread.workspacePath, previousAttemptID: state.id, incarnation: incarnation, reviewSetup: state.setup != nil))
        if let rejection = receipt.rejection { throw WorkspaceCommandError(rejection) }; return receipt
    }
    private func enqueue(_ command: EngineCommand, id: UUID = UUID()) async throws -> WorkspaceCommandReceipt {
        guard loaded, !closing, fatalError == nil else { throw CoincideError(fatalError ?? "The workspace is closing.") }
        return try await withCheckedThrowingContinuation { continuation in
            pendingCommands += 1
            incoming.yield(.init(id: id, command: command, continuation: continuation))
        }
    }
    private func process(_ envelope: Envelope) async {
        defer {
            pendingCommands -= 1
            if pendingCommands == 0 { let waiters = drainWaiters; drainWaiters = []; for waiter in waiters { waiter.resume() } }
        }
        if let fatalError { envelope.continuation.resume(throwing: CoincideError(fatalError)); return }
        do {
            let payload = try encoder.encode(envelope.command)
            if let receipt = try await database.receipt(envelope.id, matching: payload) {
                envelope.continuation.resume(returning: receipt); return
            }
            for attempt in 0..<4 {
                let base = try await database.revision()
                if let fatalError { throw CoincideError(fatalError) }
                let decision: WorkspaceDecision
                do {
                    if case .checkpointRestoreAccepted(let review) = envelope.command,
                       threadIncarnations[review.threadID] != review.sourceIncarnation {
                        throw WorkspaceCommandError("This conversation changed. Review its files again before restoring.")
                    }
                    if case .conversationHistoryAccepted(let review, _) = envelope.command,
                       threadIncarnations[review.sourceThreadID] != review.sourceIncarnation {
                        throw WorkspaceCommandError("This conversation changed. Review its current history before continuing.")
                    }
                    if case .beginWorktreePreparation(let threadID, let request, _, _, let incarnation, _) = envelope.command,
                       (threadIncarnations[threadID] != incarnation || request.destinationRoot != worktreesRoot.path) {
                        throw WorkspaceCommandError("This conversation changed. Choose the worktree again in its current workspace.")
                    }
                    if !ownsCheckpointRestoreEvent(envelope.command) || !ownsHistoryEvent(envelope.command) || !ownsScriptEvent(envelope.command) || !ownsCheckpointEvent(envelope.command) {
                        decision = WorkspaceDecision(snapshot: base.snapshot)
                    } else if case .worktreeRecovered(let threadID, let attemptID, let incarnation, _) = envelope.command,
                       !ownsWorktree(threadID: threadID, attemptID: attemptID, incarnation: incarnation) {
                        decision = WorkspaceDecision(snapshot: base.snapshot)
                    } else if case .repositoryIdentityResolved(let projectID, let path, let incarnation, let requestID, _) = envelope.command,
                       !ownsIdentityRefresh(projectID: projectID, path: path, incarnation: incarnation, requestID: requestID) {
                        decision = WorkspaceDecision(snapshot: base.snapshot)
                    } else { decision = try WorkspaceDecision.make(envelope.command, id: envelope.id, snapshot: base.snapshot, now: Date()) }
                }
                catch let error as WorkspaceCommandError {
                    do {
                        let receipt = try await database.rejectCommand(envelope.id, matching: payload, reason: error.message, expectedSequence: base.sequence)
                        envelope.continuation.resume(returning: receipt); return
                    } catch WorkspaceCommitError.revisionChanged where attempt < 3 { continue }
                }
                do {
                    completedDuringCommit = []
                    removalCommitProjects = Set(base.snapshot.projects.map(\.id)).subtracting(decision.snapshot.projects.map(\.id))
                    removalCommitThreads = Set(base.snapshot.threads.map(\.id)).subtracting(decision.snapshot.threads.map(\.id))
                    scriptCommitRuns = Set(base.snapshot.threads.flatMap { old in
                        let next = decision.snapshot.threads.first(where: { $0.id == old.id })
                        return old.projectScripts.compactMap { owner, run in next?.projectScript(owner: owner) != run ? run.id : nil }
                    })
                    var committed = false
                    defer { finishCommitFence(removed: committed) }
                    let outcome = try await database.commitWithRemovedEffects(decision.snapshot, event: "workspace.command", commandID: envelope.id,
                        expectedSequence: base.sequence, effects: decision.effects, deduplicationPayload: payload)
                    let receipt = outcome.receipt
                    revision = .init(snapshot: decision.snapshot, sequence: receipt.sequence)
                    if let attemptID = decision.cancelCloneAttempt {
                        for (effectID, request) in effectRequests {
                            if case .projectClone(_, let plan) = request, plan.id == attemptID { effects[effectID]?.cancel() }
                        }
                    }
                    if let attemptID = decision.cancelWorktreeAttempt {
                        for (effectID, request) in effectRequests where request.worktreeAttemptID == attemptID { effects[effectID]?.cancel() }
                    }
                    beginDecisionCleanup(decision, previous: base.snapshot, removedEffects: outcome.removedEffects)
                    committed = true
                    publish()
                    envelope.continuation.resume(returning: receipt)
                    scheduleEffects()
                    scheduleIdentityRefreshes(previous: base.snapshot)
                    return
                } catch WorkspaceCommitError.revisionChanged where attempt < 3 { continue }
            }
            throw WorkspaceCommitError.revisionChanged
        } catch let error as WorkspaceCommitError { envelope.continuation.resume(throwing: error) }
        catch {
            envelope.continuation.resume(throwing: error)
            await infrastructureFailed(error.localizedDescription)
        }
    }
    public func drainCommands() async {
        if pendingCommands == 0 { return }
        await withCheckedContinuation { drainWaiters.append($0) }
    }
    /// The durable removal receipt returns before process I/O. Callers await this separately so
    /// serialized UI command tails and the engine inbox remain available to unrelated projects.
    public func awaitProjectRemovalCleanup(projectID: UUID) async {
        while true {
            let tasks = cleanupTasks.values.filter { $0.projectIDs.contains(projectID) }.map(\.task)
            guard !tasks.isEmpty else { return }
            for task in tasks { await task.value }
        }
    }
    /// A provider operation can resume while SQLite has committed a removal but before this actor
    /// receives its acknowledgement. Suspend new owner work until publication/detachment completes.
    /// Rollback resumes the unchanged owner; successful removal invalidates even a reused owner ID.
    private func waitForRemovalCommit(threadID: UUID? = nil, projectID: UUID? = nil) async -> Bool {
        guard threadID.map({ removalCommitThreads.contains($0) }) == true || projectID.map({ removalCommitProjects.contains($0) }) == true else { return false }
        return await withCheckedContinuation { removalCommitWaiters.append($0) }
    }
    private func finishCommitFence(removed: Bool) {
        completedDuringCommit = nil; removalCommitProjects = []; removalCommitThreads = []
        scriptCommitRuns = []; let scriptWaiters = scriptCommitWaiters; scriptCommitWaiters = []; for waiter in scriptWaiters { waiter.resume() }
        let waiters = removalCommitWaiters; removalCommitWaiters = []
        for waiter in waiters { waiter.resume(returning: removed) }
    }
    private func beginDecisionCleanup(_ decision: WorkspaceDecision, previous: WorkspaceSnapshot, removedEffects: [WorkspaceEffect]) {
        let removedProjects = Set(previous.projects.map(\.id)).subtracting(decision.snapshot.projects.map(\.id))
        let removedThreads = Set(previous.threads.map(\.id)).subtracting(decision.snapshot.threads.map(\.id))
        let threads = decision.closeRuntimes.union(removedThreads)
        var cleanupThreadIDs = threads
        var projectIDs = removedProjects
        var sessions: [any ProviderSession] = []
        var providerPaths: Set<String> = []
        var jobs: [Task<Void, Never>] = []
        let old = Dictionary(uniqueKeysWithValues: previous.projects.map { ($0.id, $0) })
        for project in decision.snapshot.projects where old[project.id] == nil || old[project.id]?.path != project.path {
            projectIncarnations[project.id] = UUID()
        }
        for id in removedProjects { projectIncarnations.removeValue(forKey: id) }
        let previousThreads = Dictionary(uniqueKeysWithValues: previous.threads.map { ($0.id, $0) })
        for old in previous.threads {
            if let generation = old.settlement?.id,
               decision.snapshot.threads.first(where: { $0.id == old.id })?.settlement?.id != generation {
                // Its tracked project cleanup still owns any live drain; this is only a lookup.
                settlementPrerequisites.removeValue(forKey: generation)
            }
        }
        for thread in decision.snapshot.threads where previousThreads[thread.id] == nil || previousThreads[thread.id]?.workspacePath != thread.workspacePath {
            threadIncarnations[thread.id] = UUID()
        }
        for id in removedThreads { threadIncarnations.removeValue(forKey: id) }
        for (id, read) in historyReads where removedThreads.contains(read.threadID) || removedProjects.contains(read.projectID) || threads.contains(read.threadID) {
            historyReads.removeValue(forKey: id); read.cancel()
            jobs.append(read.drain); projectIDs.insert(read.projectID); cleanupThreadIDs.insert(read.threadID)
        }
        beginCheckpointCleanup(previous: previous, next: decision.snapshot, projectIDs: &projectIDs, threadIDs: &cleanupThreadIDs, jobs: &jobs)
        for (id, inspection) in worktreeInspections where removedThreads.contains(inspection.threadID) || removedProjects.contains(inspection.projectID) {
            worktreeInspections.removeValue(forKey: id); inspection.task.cancel(); projectIDs.insert(inspection.projectID)
            jobs.append(Task { _ = try? await inspection.task.value })
        }
        for (id, refresh) in identityRefreshes where removedProjects.contains(id) || !decision.snapshot.projects.contains(where: { $0.id == id && $0.path == refresh.path && ($0.clone == nil || $0.clone?.isReady == true) }) {
            identityRefreshes.removeValue(forKey: id); refresh.task.cancel(); projectIDs.insert(id)
            jobs.append(Task { _ = try? await refresh.task.value })
        }
        for id in threads {
            if let runtime = runtimes.removeValue(forKey: id) {
                runtime.reader?.cancel(); sessions.append(runtime.session); projectIDs.insert(runtime.projectID); providerPaths.insert(runtime.path)
            }
        }
        for (id, metadata) in metadataSessions where metadata.threadID.map({ threads.contains($0) }) == true || metadata.projectID.map({ removedProjects.contains($0) }) == true {
            metadataSessions.removeValue(forKey: id)
            providerPaths.insert(metadata.path)
            if let projectID = metadata.projectID { projectIDs.insert(projectID) }
            if metadata.closeTask == nil { sessions.append(metadata.session) }
        }
        for effect in removedEffects where effect.status == .running && effect.leaseOwner == workerID {
            // Shutdown/failure can finish an executor while the commit awaits SQLite. Its ID
            // must not become a waiter after its one completion notification already happened.
            if completedDuringCommit?.contains(effect.id) == true { continue }
            // Record exact IDs before yielding, covering a claim that is still returning from SQLite.
            retiringEffects.insert(effect.id); effects[effect.id]?.cancel()
            jobs.append(Task { await self.awaitRetiringEffect(effect.id) })
        }
        jobs.append(contentsOf: beginScriptDecisionCleanup(previous: previous, next: decision.snapshot, removedEffects: removedEffects, projectIDs: &projectIDs, threadIDs: &cleanupThreadIDs))
        jobs.append(contentsOf: beginSettlementResumeCleanup(previous: previous, next: decision.snapshot, projectIDs: &projectIDs, threadIDs: &cleanupThreadIDs))
        // Join a prior archive/idle-session close for this exact thread. Capture before
        // registering the new join, so no cleanup can accidentally await itself.
        for thread in decision.snapshot.threads where thread.settlement != nil && previousThreads[thread.id]?.settlement?.id != thread.settlement?.id {
            let prior = cleanupTasks.values.filter { $0.threadIDs.contains(thread.id) }.map(\.task)
            if !prior.isEmpty { jobs.append(contentsOf: prior); projectIDs.insert(thread.projectID); cleanupThreadIDs.insert(thread.id) }
        }
        let cleanup = startCleanup(projectIDs: projectIDs, threadIDs: cleanupThreadIDs, sessions: sessions, jobs: jobs, workspacePaths: providerPaths)
        for thread in decision.snapshot.threads {
            if let settlement = thread.settlement, settlement.phase == .settled,
               previousThreads[thread.id]?.settlement?.id != settlement.id, let cleanup { settlementPrerequisites[settlement.id] = cleanup }
        }
    }
    @discardableResult private func startCleanup(projectIDs: Set<UUID>, threadIDs: Set<UUID> = [], sessions: [any ProviderSession], jobs: [Task<Void, Never>] = [], workspacePaths: Set<String> = []) -> Task<Void, Never>? {
        guard !sessions.isEmpty || !jobs.isEmpty else { return nil }
        let id = UUID()
        let task: Task<Void, Never> = Task.detached { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                for session in sessions { group.addTask { await session.close() } }
                for job in jobs { group.addTask { await job.value } }
                await group.waitForAll()
            }
            await self?.cleanupFinished(id)
        }
        cleanupTasks[id] = .init(projectIDs: projectIDs, threadIDs: threadIDs, workspacePaths: workspacePaths, task: task)
        return task
    }
    private func cleanupFinished(_ id: UUID) { cleanupTasks.removeValue(forKey: id) }
    private func awaitRetiringEffect(_ id: UUID) async {
        guard retiringEffects.contains(id) else { return }
        await withCheckedContinuation { retiringEffectWaiters[id, default: []].append($0) }
    }
    private func retiredEffectFinished(_ id: UUID) {
        retiringEffects.remove(id)
        let waiters = retiringEffectWaiters.removeValue(forKey: id) ?? []
        for waiter in waiters { waiter.resume() }
    }
    /// Metadata reads are owned by one project incarnation. Cancelling waits for the resolver's
    /// owned process to exit; failures never stop provider execution or discard a known identity.
    public func refreshRepositoryIdentity(projectID: UUID) async throws -> RepositoryIdentity? {
        _ = try await load()
        if await waitForRemovalCommit(projectID: projectID) { throw CancellationError() }
        try Task.checkCancellation()
        guard let project = revision.snapshot.projects.first(where: { $0.id == projectID }), let incarnation = projectIncarnations[projectID] else { throw CancellationError() }
        let task = try startIdentityRefresh(projectID: projectID)
        return try await withTaskCancellationHandler {
            do {
                let value = try await task.value
                let owned = await identityCallerIsCurrent(projectID: projectID, path: project.path, incarnation: incarnation)
                try Task.checkCancellation()
                guard owned, !task.isCancelled else { throw CancellationError() }
                return value
            } catch {
                let owned = await identityCallerIsCurrent(projectID: projectID, path: project.path, incarnation: incarnation)
                try Task.checkCancellation()
                guard owned, !task.isCancelled else { throw CancellationError() }
                throw error
            }
        } onCancel: { task.cancel() }
    }
    private func identityCallerIsCurrent(projectID: UUID, path: String, incarnation: UUID) async -> Bool {
        if await waitForRemovalCommit(projectID: projectID) { return false }
        return !closing && !stoppingEffects && fatalError == nil && projectIncarnations[projectID] == incarnation &&
            revision.snapshot.projects.contains { $0.id == projectID && $0.path == path && ($0.clone == nil || $0.clone?.isReady == true) }
    }
    private func startIdentityRefresh(projectID: UUID) throws -> Task<RepositoryIdentity?, any Error> {
        guard !closing, !stoppingEffects, fatalError == nil,
              let project = revision.snapshot.projects.first(where: { $0.id == projectID && ($0.clone == nil || $0.clone?.isReady == true) }),
              let incarnation = projectIncarnations[projectID] else { throw CancellationError() }
        if let current = identityRefreshes[projectID], current.incarnation == incarnation, current.path == project.path { return current.task }
        let id = UUID(), path = project.path, resolver = identityResolver, gate = identityGate
        // Four independent FIFO lanes cap local Git discovery without sharing mutation locks.
        let lane = String(projectID.uuid.0 & 3)
        let task: Task<RepositoryIdentity?, any Error> = Task { [weak self] in
            do {
                let identity = try await gate.perform(key: lane) { try await resolver(URL(fileURLWithPath: path)) }
                try Task.checkCancellation()
                guard let self else { throw CancellationError() }
                let value = try await self.applyIdentityRefresh(projectID: projectID, path: path, incarnation: incarnation, requestID: id, identity: identity)
                await self.identityRefreshFinished(projectID: projectID, requestID: id)
                try Task.checkCancellation(); return value
            } catch {
                let owned = await self?.identityRefreshFailed(projectID: projectID, path: path, incarnation: incarnation, requestID: id) ?? false
                try Task.checkCancellation()
                guard owned else { throw CancellationError() }
                throw error
            }
        }
        identityRefreshes[projectID] = .init(id: id, incarnation: incarnation, path: path, task: task)
        return task
    }
    private func ownsIdentityRefresh(projectID: UUID, path: String, incarnation: UUID, requestID: UUID) -> Bool {
        guard !closing, !stoppingEffects, fatalError == nil, projectIncarnations[projectID] == incarnation,
              let current = identityRefreshes[projectID], !current.task.isCancelled, current.id == requestID, current.incarnation == incarnation, current.path == path,
              revision.snapshot.projects.contains(where: { $0.id == projectID && $0.path == path && ($0.clone == nil || $0.clone?.isReady == true) }) else { return false }
        return true
    }
    private func applyIdentityRefresh(projectID: UUID, path: String, incarnation: UUID, requestID: UUID, identity: RepositoryIdentity?) async throws -> RepositoryIdentity? {
        if await waitForRemovalCommit(projectID: projectID) { throw CancellationError() }
        guard ownsIdentityRefresh(projectID: projectID, path: path, incarnation: incarnation, requestID: requestID),
              let project = revision.snapshot.projects.first(where: { $0.id == projectID }) else { throw CancellationError() }
        try Task.checkCancellation()
        try WorkspaceJournal.validateRepositoryIdentity(identity, project: project)
        if project.repositoryIdentity != identity {
            _ = try await enqueue(.repositoryIdentityResolved(projectID: projectID, path: path, incarnation: incarnation, requestID: requestID, identity: identity))
        }
        if await waitForRemovalCommit(projectID: projectID) { throw CancellationError() }
        guard ownsIdentityRefresh(projectID: projectID, path: path, incarnation: incarnation, requestID: requestID) else { throw CancellationError() }
        try Task.checkCancellation(); return identity
    }
    private func identityRefreshFinished(projectID: UUID, requestID: UUID) {
        if identityRefreshes[projectID]?.id == requestID { identityRefreshes.removeValue(forKey: projectID) }
    }
    private func identityRefreshFailed(projectID: UUID, path: String, incarnation: UUID, requestID: UUID) async -> Bool {
        let removed = await waitForRemovalCommit(projectID: projectID)
        let owned = !removed && ownsIdentityRefresh(projectID: projectID, path: path, incarnation: incarnation, requestID: requestID)
        identityRefreshFinished(projectID: projectID, requestID: requestID)
        return owned
    }
    private func scheduleIdentityRefreshes(previous: WorkspaceSnapshot?) {
        guard loaded, !closing, !stoppingEffects, fatalError == nil else { return }
        let old = Dictionary(uniqueKeysWithValues: (previous?.projects ?? []).map { ($0.id, $0) })
        for project in revision.snapshot.projects where project.clone == nil || project.clone?.isReady == true {
            let prior = old[project.id]
            if prior == nil || prior?.path != project.path || (prior?.clone != nil && prior?.clone?.isReady != true) {
                _ = try? startIdentityRefresh(projectID: project.id)
            }
        }
    }
    private func scheduleEffects() {
        effectWakeGeneration += 1
        guard !pumping, !closing, !stoppingEffects, fatalError == nil else { return }
        pumping = true
        Task { await self.pumpEffects() }
    }
    private func pumpEffects() async {
        let generation = effectWakeGeneration
        defer {
            pumping = false
            if generation != effectWakeGeneration { scheduleEffects() }
        }
        do {
            while !closing, !stoppingEffects, fatalError == nil, effects.count < 64 {
                let startingCount = effectRequests.values.filter { if case .providerStart = $0 { true } else { false } }.count
                guard let effect = try await database.claimNextEffect(workerID: workerID, includeProviderStarts: startingCount < 8) else { break }
                effectRequests[effect.id] = effect.request
                effects[effect.id] = Task { await self.execute(effect) }
                if retiringEffects.contains(effect.id) { effects[effect.id]?.cancel() }
            }
        } catch { await infrastructureFailed(error.localizedDescription) }
    }
    private func execute(_ effect: WorkspaceEffect) async {
        let scriptIncarnation = effect.request.projectScriptRunID == nil ? nil : effect.request.threadID.flatMap { threadIncarnations[$0] }
        let checkpointIncarnation = effect.request.checkpointOwner == nil ? nil : effect.request.threadID.flatMap { threadIncarnations[$0] }
        let historyIncarnation: UUID?
        if case .conversationHistory = effect.request { historyIncarnation = effect.request.threadID.flatMap { threadIncarnations[$0] } }
        else { historyIncarnation = nil }
        let historyFilesIncarnation: UUID?
        if case .conversationHistoryFiles = effect.request { historyFilesIncarnation = effect.request.threadID.flatMap { threadIncarnations[$0] } }
        else { historyFilesIncarnation = nil }
        let restoreIncarnation = effect.request.checkpointRestoreOperationID == nil ? nil : effect.request.threadID.flatMap { threadIncarnations[$0] }
        defer {
            effects.removeValue(forKey: effect.id); effectRequests.removeValue(forKey: effect.id)
            completedDuringCommit?.insert(effect.id)
            retiredEffectFinished(effect.id)
            if case .projectClone(_, let plan) = effect.request { cloneProgressTimes.removeValue(forKey: plan.id) }
            scheduleEffects()
        }
        let heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                guard let self else { return }
                await self.renew(effect.id)
            }
        }
        let result: EffectResult
        do {
            let performed = try await perform(effect.request)
            result = retiringEffects.contains(effect.id) ? .cancelled : performed
        }
        catch is CancellationError { result = .cancelled }
        catch {
            let message = historyFilesIncarnation != nil ? ConversationHistoryFilesState.failureMessage : restoreIncarnation != nil ? RunCheckpointRestoreOperation.failureMessage : historyIncarnation != nil ? ConversationHistoryOperation.failureMessage : effect.request.checkpointOwner != nil ? ThreadRunCheckpointAttempt.failureMessage : effect.request.projectScriptRunID != nil ? ThreadProjectScriptRun.executionError(for: effect.request.projectScriptOwner?.role ?? .setup) : effect.request.projectID == nil && effect.request.worktreeAttemptID == nil ? error.localizedDescription : String(GitService.redactURLs(error.localizedDescription).prefix(4_000))
            result = .failed(message)
        }
        heartbeat.cancel()
        if !closing, fatalError == nil {
            do {
                let owned: Bool
                switch result {
                case .succeeded, .stopped, .worktreeResolved, .worktreePrepared, .projectScriptResolved, .checkpointResolved, .checkpointCaptured, .checkpointUnavailable, .conversationHistoryConfirmed, .conversationHistoryUnconfirmed, .checkpointRestoreConfirmed, .checkpointRestoreUnconfirmed: owned = try await database.settleEffect(effect.id, workerID: workerID)
                case .failed(let message): owned = try await database.settleEffect(effect.id, workerID: workerID, error: message)
                case .cancelled: owned = try await database.cancelEffect(effect.id, workerID: workerID, reason: "The targeted run or request is no longer active.")
                }
                guard owned else { await infrastructureFailed("Provider execution lost its workspace lease."); return }
                if let historyFilesIncarnation {
                    if !retiringEffects.contains(effect.id) {
                        _ = try await enqueue(.conversationHistoryFilesEffectResult(effect.request, result, incarnation: historyFilesIncarnation))
                        if case .conversationHistoryFiles(_, let operationID, _) = effect.request,
                           let operation = revision.snapshot.conversationHistoryOperation(operationID), let files = operation.files,
                           files.phase == .failed {
                            await discardCheckpointRestoreScratch(files.review.gitReview, threadID: operation.review.sourceThreadID, projectID: operation.review.projectID)
                        }
                    }
                } else if let restoreIncarnation {
                    if !retiringEffects.contains(effect.id) { _ = try await enqueue(.checkpointRestoreEffectResult(effect.request, result, incarnation: restoreIncarnation)) }
                } else if let historyIncarnation {
                    if !retiringEffects.contains(effect.id) {
                        _ = try await enqueue(.conversationHistoryEffectResult(effect.request, result, incarnation: historyIncarnation))
                        if case .conversationHistory(_, let operationID) = effect.request,
                           let operation = revision.snapshot.conversationHistoryOperation(operationID), let files = operation.review.files,
                           operation.phase == .failed || operation.phase == .unconfirmed {
                            await discardCheckpointRestoreScratch(files.gitReview, threadID: operation.review.sourceThreadID, projectID: operation.review.projectID)
                        }
                    }
                } else if effect.request.checkpointOwner != nil {
                    if !retiringEffects.contains(effect.id), let checkpointIncarnation { _ = try await enqueue(.runCheckpointEffectResult(effect.request, result, incarnation: checkpointIncarnation)) }
                } else if effect.request.projectScriptRunID != nil {
                    if !retiringEffects.contains(effect.id), let scriptIncarnation {
                        _ = try await enqueue(.projectScriptEffectResult(effect.request, result, incarnation: scriptIncarnation))
                    }
                } else { _ = try await enqueue(.effectResult(effect.request, result)) }
            } catch { if !closing { await infrastructureFailed(error.localizedDescription) } }
        }
    }
    private func renew(_ id: UUID) async {
        guard effects[id] != nil, !closing, fatalError == nil else { return }
        do {
            guard try await database.renewEffectLease(id, workerID: workerID) else {
                await infrastructureFailed("Provider execution lost its workspace lease."); return
            }
        } catch { await infrastructureFailed(error.localizedDescription) }
    }
    private func perform(_ request: WorkspaceEffectRequest) async throws -> EffectResult {
        try Task.checkCancellation()
        guard !stoppingEffects, fatalError == nil else { throw CancellationError() }
        if await waitForRemovalCommit(threadID: request.threadID, projectID: request.projectID) { return .cancelled }
        try Task.checkCancellation()
        if case .checkpointRestore = request { return try await performCheckpointRestore(request) }
        if case .conversationHistoryFiles = request { return try await performConversationHistoryFiles(request) }
        if case .conversationHistory = request { return try await performConversationHistory(request) }
        if request.checkpointOwner != nil { return try await performRunCheckpoint(request) }
        if request.projectScriptRunID != nil { return try await performProjectScript(request) }
        if request.worktreeAttemptID != nil { return try await performWorktree(request) }
        if case .projectClone(let projectID, let plan) = request {
            guard let clone = revision.snapshot.projects.first(where: { $0.id == projectID })?.clone,
                  clone.id == plan.id, clone.isRunning, !clone.cancelRequested else { return .cancelled }
            _ = try await enqueue(.cloneStarted(projectID: projectID, attemptID: plan.id))
            if await waitForRemovalCommit(projectID: projectID) { return .cancelled }
            guard let latest = revision.snapshot.projects.first(where: { $0.id == projectID })?.clone,
                  latest.id == plan.id, latest.isRunning, !latest.cancelRequested else { return .cancelled }
            try Task.checkCancellation()
            let session = try cloneFactory(plan)
            do {
                try await session.run { [weak self] progress in await self?.receiveCloneProgress(projectID: projectID, attemptID: plan.id, progress: progress) }
                return .succeeded
            } catch {
                // Git may have completed promotion while cancellation was arriving. Inspect
                // local ownership evidence on an uncancelled task before choosing its outcome.
                if (try? await Task.detached { try await session.isCompleted() }.value) == true { return .succeeded }
                throw error
            }
        }
        guard let thread = revision.snapshot.threads.first(where: { $0.id == request.threadID }), revision.snapshot.workspaceReady(for: thread) else { return .cancelled }
        switch request {
        case .conversationHistoryFiles, .checkpointRestore, .conversationHistory, .resolveRunCheckpoint, .captureRunCheckpoint, .resolveThreadScript, .startThreadScript, .resolveProjectScript, .startProjectScript, .resolveWorktree, .prepareWorktree, .projectClone: return .cancelled // Preparation/project actions are handled before thread lookup.
        case .providerStart(_, let runID, let configuration, let prompt, let references):
            guard thread.activeRun?.id == runID, thread.activeRun?.stopRequested == false else { return .cancelled }
            await awaitCheckpointDrains(threadID: thread.id)
            guard checkpointProviderReleased(threadID: thread.id, runID: runID) else { return .cancelled }
            let input = try await attachments.prepare(text: prompt, attachments: references ?? [])
            guard !closing, !stoppingEffects,
                  revision.snapshot.workspaceReady(for: thread),
                  revision.snapshot.threads.first(where: { $0.id == thread.id })?.activeRun?.id == runID,
                  revision.snapshot.threads.first(where: { $0.id == thread.id })?.activeRun?.stopRequested == false else { return .cancelled }
            var configured = thread
            configured.provider = configuration.provider; configured.workspacePath = configuration.workspacePath
            configured.providerThreadID = configuration.nativeThreadID; configured.model = configuration.model; configured.permission = configuration.permission
            configured.acpAgent = configuration.acpAgent; configured.agentModeID = configuration.agentModeID
            configured.agentConfigValues = configuration.agentConfigValues
            configured.agentConfiguration = configuration.agentConfiguration
            let runtime = try await runtime(for: configured, runID: runID)
            if await waitForRemovalCommit(threadID: thread.id, projectID: thread.projectID) { return .cancelled }
            guard !closing, !stoppingEffects, revision.snapshot.threads.first(where: { $0.id == thread.id })?.activeRun?.id == runID,
                  revision.snapshot.workspaceReady(for: thread),
                  revision.snapshot.threads.first(where: { $0.id == thread.id })?.activeRun?.stopRequested == false,
                  runtimes[thread.id]?.id == runtime.id else { return .cancelled }
            try Task.checkCancellation()
            try await runtime.session.send(input: input, thread: configured)
            return .succeeded
        case .providerInterrupt(_, let runID):
            guard thread.activeRun?.id == runID else { return .cancelled }
            if thread.activeRun?.nativeTurnID != nil, let runtime = runtimes[thread.id] {
                do { try await runtime.session.interrupt(); return .succeeded } catch { /* Fall back to closing the owned process. */ }
            }
            // Closing the owned runtime also stops startup before a native turn ID exists.
            await closeRuntime(thread.id)
            return .stopped
        case .providerRespond(_, let runID, let request, let response):
            guard thread.activeRun?.id == runID, thread.activeRun?.stopRequested == false,
                  thread.runtimeRequests.contains(where: { $0.id == request.id && $0.responding }),
                  let runtime = runtimes[thread.id], runtime.id == thread.runtimeID else { return .cancelled }
            switch response {
            case .option(let id): try await runtime.session.choose(request, optionID: id)
            case .decision(let allow): try await runtime.session.respond(request, allow: allow)
            case .answers(let answers): try await runtime.session.answer(request, answers: answers)
            }
            return .succeeded
        case .providerSessionRespond(_, let runtimeID, let request, let response):
            guard thread.runtimeID == runtimeID, thread.runtimeRequests.contains(where: { $0.id == request.id && $0.responding && $0.sessionScoped == true }),
                  let runtime = runtimes[thread.id], runtime.id == runtimeID else { return .cancelled }
            switch response {
            case .option(let id): try await runtime.session.choose(request, optionID: id)
            case .decision(let allow): try await runtime.session.respond(request, allow: allow)
            case .answers(let answers): try await runtime.session.answer(request, answers: answers)
            }
            return .succeeded
        }
    }
    private func ownsWorktree(threadID: UUID, attemptID: UUID, incarnation: UUID) -> Bool {
        guard !closing, !stoppingEffects, fatalError == nil, threadIncarnations[threadID] == incarnation,
              let thread = revision.snapshot.threads.first(where: { $0.id == threadID }),
              let state = thread.workspacePreparation, state.id == attemptID,
              thread.workspacePath == state.destinationPath, state.request.destinationRoot == worktreesRoot.path else { return false }
        return true
    }
    private func performWorktree(_ effect: WorkspaceEffectRequest) async throws -> EffectResult {
        guard let threadID = effect.threadID, let attemptID = effect.worktreeAttemptID,
              let incarnation = threadIncarnations[threadID],
              let thread = revision.snapshot.threads.first(where: { $0.id == threadID }),
              let state = thread.workspacePreparation, state.id == attemptID, state.isRunning, !state.cancelRequested,
              ownsWorktree(threadID: threadID, attemptID: attemptID, incarnation: incarnation) else { return .cancelled }
        let session = try worktreeFactory(state.request)
        switch effect {
        case .resolveWorktree(_, let request):
            guard request == state.request, state.plan == nil else { return .cancelled }
            _ = try await enqueue(.worktreeStarted(threadID: threadID, attemptID: attemptID))
            if await waitForRemovalCommit(threadID: threadID, projectID: thread.projectID) { return .cancelled }
            guard ownsWorktree(threadID: threadID, attemptID: attemptID, incarnation: incarnation),
                  revision.snapshot.threads.first(where: { $0.id == threadID })?.workspacePreparation?.cancelRequested == false else { return .cancelled }
            try Task.checkCancellation()
            do {
                let plan = try await session.prepare()
                if await waitForRemovalCommit(threadID: threadID, projectID: thread.projectID) { return .cancelled }
                guard ownsWorktree(threadID: threadID, attemptID: attemptID, incarnation: incarnation) else { return .cancelled }
                try Task.checkCancellation(); try ThreadWorkspacePreparation.validate(plan: plan, request: request)
                return .worktreeResolved(plan)
            } catch {
                if await waitForRemovalCommit(threadID: threadID, projectID: thread.projectID) { throw CancellationError() }
                guard ownsWorktree(threadID: threadID, attemptID: attemptID, incarnation: incarnation) else { throw CancellationError() }
                throw error
            }
        case .prepareWorktree(_, let plan):
            guard state.plan == plan, state.phase == .preparing else { return .cancelled }
            do {
                let result = try await session.run(plan)
                if await waitForRemovalCommit(threadID: threadID, projectID: thread.projectID) { return .cancelled }
                guard ownsWorktree(threadID: threadID, attemptID: attemptID, incarnation: incarnation) else { return .cancelled }
                try ThreadWorkspacePreparation.validate(result: result, plan: plan)
                return .worktreePrepared(result)
            } catch {
                // A late cancellation can race Git's completed registration. Only local exact
                // ownership evidence may promote that attempt; its queue remains paused.
                let completed = try? await Task.detached { try await session.inspectCompletion(plan) }.value
                if await waitForRemovalCommit(threadID: threadID, projectID: thread.projectID) { throw CancellationError() }
                guard ownsWorktree(threadID: threadID, attemptID: attemptID, incarnation: incarnation) else { throw CancellationError() }
                if let result = completed {
                    try ThreadWorkspacePreparation.validate(result: result, plan: plan); return .worktreePrepared(result)
                }
                throw error
            }
        default: return .cancelled
        }
    }
    /// Publish interrupted state immediately. Local completion probes are owned background
    /// reads, so a slow repository cannot delay loading or commands in other workspaces.
    private func scheduleWorktreeReconciliation() {
        let gate = worktreeInspectionGate
        for thread in revision.snapshot.threads {
            guard let state = thread.workspacePreparation, !state.isReady, let plan = state.plan,
                  state.request.destinationRoot == worktreesRoot.path, let incarnation = threadIncarnations[thread.id],
                  let session = try? worktreeFactory(state.request) else { continue }
            let token = UUID(), threadID = thread.id, projectID = thread.projectID, attemptID = state.id
            let lane = String(threadID.uuid.0 & 3)
            let task: Task<GitWorktreeResult?, any Error> = Task { [weak self] in
                do {
                    let result = try await gate.perform(key: lane) { try await session.inspectCompletion(plan) }
                    try Task.checkCancellation()
                    if let result { try await self?.applyRecoveredWorktree(threadID: threadID, projectID: projectID, attemptID: attemptID, incarnation: incarnation, result: result, plan: plan) }
                    await self?.worktreeInspectionFinished(token)
                    return result
                } catch {
                    await self?.worktreeInspectionFinished(token); throw error
                }
            }
            worktreeInspections[token] = .init(threadID: threadID, projectID: projectID, task: task)
        }
    }
    private func applyRecoveredWorktree(threadID: UUID, projectID: UUID, attemptID: UUID, incarnation: UUID, result: GitWorktreeResult, plan: GitWorktreePlan) async throws {
        if await waitForRemovalCommit(threadID: threadID, projectID: projectID) { throw CancellationError() }
        try Task.checkCancellation()
        guard ownsWorktree(threadID: threadID, attemptID: attemptID, incarnation: incarnation) else { throw CancellationError() }
        try ThreadWorkspacePreparation.validate(result: result, plan: plan)
        _ = try await enqueue(.worktreeRecovered(threadID: threadID, attemptID: attemptID, incarnation: incarnation, result: result))
    }
    private func worktreeInspectionFinished(_ token: UUID) { worktreeInspections.removeValue(forKey: token) }
    private func receiveCloneProgress(projectID: UUID, attemptID: UUID, progress: GitCloneProgress) async {
        guard !closing, !stoppingEffects, fatalError == nil,
              revision.snapshot.projects.first(where: { $0.id == projectID })?.clone?.id == attemptID,
              effectRequests.values.contains(where: { if case .projectClone(let id, let plan) = $0 { id == projectID && plan.id == attemptID } else { false } }) else { return }
        let now = ContinuousClock.now
        if let last = cloneProgressTimes[attemptID] {
            if last.1 == progress { return }
            if last.1.stage == progress.stage, last.1.stalled == progress.stalled, progress.percent != 100, now - last.0 < .milliseconds(100) { return }
        }
        cloneProgressTimes[attemptID] = (now, progress)
        _ = try? await enqueue(.cloneProgress(projectID: projectID, attemptID: attemptID, progress: progress))
    }
    private func reconcileCompletedClones(in snapshot: WorkspaceSnapshot) async -> WorkspaceSnapshot {
        var recovered = snapshot
        for i in recovered.projects.indices {
            guard var clone = recovered.projects[i].clone, !clone.isReady else { continue }
            guard (try? await cloneFactory(clone.plan).isCompleted()) == true else { continue }
            clone.phase = .completed; clone.cancelRequested = false; clone.error = nil
            clone.progress = .init(stage: .checkout, percent: 100, detail: nil, stalled: false)
            clone.updatedAt = Date(); clone.endedAt = clone.updatedAt; recovered.projects[i].clone = clone
        }
        return recovered
    }
    private func runtime(for thread: CodingThread, runID: UUID) async throws -> Runtime {
        if await waitForRemovalCommit(threadID: thread.id, projectID: thread.projectID) { throw CancellationError() }
        try Task.checkCancellation()
        guard ownsRun(threadID: thread.id, projectID: thread.projectID, runID: runID) else { throw CancellationError() }
        if let existing = runtimes[thread.id], existing.provider == thread.provider, existing.path == thread.workspacePath, existing.acpAgent == thread.acpAgent { return existing }
        await closeRuntime(thread.id)
        if await waitForRemovalCommit(threadID: thread.id, projectID: thread.projectID) { throw CancellationError() }
        try Task.checkCancellation()
        // Closing the previous process is an await: removal may have committed during that I/O.
        guard ownsRun(threadID: thread.id, projectID: thread.projectID, runID: runID) else { throw CancellationError() }
        let id = UUID(), session = try factory(thread)
        var runtime = Runtime(id: id, projectID: thread.projectID, session: session, provider: thread.provider, path: thread.workspacePath, acpAgent: thread.acpAgent)
        runtimes[thread.id] = runtime
        _ = try await enqueue(.runtimeOpened(threadID: thread.id, runID: runID, runtimeID: id))
        guard ownsRun(threadID: thread.id, projectID: thread.projectID, runID: runID), runtimes[thread.id]?.id == id else {
            await closeRuntime(thread.id, matching: id); throw CancellationError()
        }
        let stream = session.events
        runtime.reader = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                do { _ = try await self.enqueue(.provider(threadID: thread.id, runtimeID: id, event: event)) }
                catch { return }
            }
        }
        if runtimes[thread.id]?.id == id { runtimes[thread.id] = runtime }
        else { runtime.reader?.cancel(); throw CancellationError() }
        return runtime
    }
    private func ownsRun(threadID: UUID, projectID: UUID, runID: UUID) -> Bool {
        guard !closing, !stoppingEffects, fatalError == nil,
              let thread = revision.snapshot.threads.first(where: { $0.id == threadID && $0.projectID == projectID }),
              thread.activeRun?.id == runID, thread.activeRun?.stopRequested == false,
              revision.snapshot.workspaceReady(for: thread) else { return false }
        return true
    }
    private func closeRuntime(_ threadID: UUID, matching expectedID: UUID? = nil) async {
        guard let runtime = runtimes[threadID], expectedID == nil || expectedID == runtime.id else { return }
        runtimes.removeValue(forKey: threadID); runtime.reader?.cancel()
        if let task = startCleanup(projectIDs: [runtime.projectID], threadIDs: [threadID], sessions: [runtime.session], workspacePaths: [runtime.path]) { await task.value }
    }
    private func infrastructureFailed(_ message: String) async {
        guard fatalError == nil else { return }
        fatalError = "Workspace execution stopped: \(message)"; publish()
        for task in effects.values { task.cancel() }
        cancelIdentityRefreshes()
        cancelCheckpointReads()
        for read in historyReads.values { read.cancel() }
        historyReviews = [:]
        checkpointRestoreReviews = [:]
        let inspections = worktreeInspections; worktreeInspections = [:]
        for inspection in inspections.values {
            inspection.task.cancel()
            _ = startCleanup(projectIDs: [inspection.projectID], threadIDs: [inspection.threadID], sessions: [], jobs: [Task { _ = try? await inspection.task.value }])
        }
        for id in Array(runtimes.keys) { await closeRuntime(id) }
        await closeAllProjectScripts()
    }
    private func cancelIdentityRefreshes() {
        let refreshes = identityRefreshes; identityRefreshes = [:]
        for (id, refresh) in refreshes {
            refresh.task.cancel()
            _ = startCleanup(projectIDs: [id], sessions: [], jobs: [Task { _ = try? await refresh.task.value }])
        }
    }
    public func models(provider: ProviderKind) async throws -> [ProviderModel] {
        var thread = CodingThread(project: WorkspaceProject(path: FileManager.default.homeDirectoryForCurrentUser.path)); thread.provider = provider
        return try await queryModels(thread: thread, owned: false)
    }
    public func models(thread: CodingThread) async throws -> [ProviderModel] {
        _ = try await load()
        guard !closing, !stoppingEffects,
              let current = revision.snapshot.threads.first(where: { $0.id == thread.id && $0.projectID == thread.projectID }),
              revision.snapshot.projects.contains(where: { $0.id == thread.projectID }),
              current.provider == thread.provider, current.workspacePath == thread.workspacePath, current.acpAgent == thread.acpAgent else { throw CancellationError() }
        if !revision.snapshot.providerReady(for: current) {
            throw CoincideError("Wait for the workspace to finish preparing before refreshing this agent's models.")
        }
        return try await queryModels(thread: current, owned: true)
    }
    private func queryModels(thread: CodingThread, owned: Bool) async throws -> [ProviderModel] {
        if owned {
            if await waitForRemovalCommit(threadID: thread.id, projectID: thread.projectID) { throw CancellationError() }
            guard let current = revision.snapshot.threads.first(where: { $0.id == thread.id && $0.projectID == thread.projectID }),
                  current.provider == thread.provider, current.workspacePath == thread.workspacePath, current.acpAgent == thread.acpAgent,
                  revision.snapshot.providerReady(for: current) else { throw CancellationError() }
        }
        guard !closing, !stoppingEffects, !revision.snapshot.isCheckpointRestoreLocked(path: thread.workspacePath) else { throw CancellationError() }
        let id = UUID(), session = try factory(thread)
        metadataSessions[id] = .init(session: session, path: thread.workspacePath, threadID: owned ? thread.id : nil,
                                     projectID: owned ? thread.projectID : nil, configuration: owned ? .init(thread: thread) : nil)
        do {
            let result = try await session.models()
            if owned, await waitForRemovalCommit(threadID: thread.id, projectID: thread.projectID) { throw CancellationError() }
            guard let metadata = metadataSessions[id], metadataOwnerIsCurrent(metadata) else { throw CancellationError() }
            if let task = beginMetadataClose(id) { await task.value }
            if owned, await waitForRemovalCommit(threadID: thread.id, projectID: thread.projectID) { throw CancellationError() }
            guard let metadata = metadataSessions[id], metadataOwnerIsCurrent(metadata) else { throw CancellationError() }
            metadataSessions.removeValue(forKey: id); return result
        } catch {
            if owned, await waitForRemovalCommit(threadID: thread.id, projectID: thread.projectID) { throw CancellationError() }
            let ownerIsCurrent = metadataSessions[id].map(metadataOwnerIsCurrent) == true
            if let task = beginMetadataClose(id) { await task.value }
            if owned, await waitForRemovalCommit(threadID: thread.id, projectID: thread.projectID) { throw CancellationError() }
            let stillOwned = metadataSessions[id].map(metadataOwnerIsCurrent) == true
            metadataSessions.removeValue(forKey: id)
            if !ownerIsCurrent || !stillOwned || closing || stoppingEffects { throw CancellationError() }
            throw error
        }
    }
    private func metadataOwnerIsCurrent(_ metadata: MetadataRuntime) -> Bool {
        guard !closing, !stoppingEffects else { return false }
        guard let threadID = metadata.threadID else { return true } // Neutral provider discovery.
        guard let thread = revision.snapshot.threads.first(where: { $0.id == threadID && $0.projectID == metadata.projectID }),
              revision.snapshot.projects.contains(where: { $0.id == thread.projectID }),
              let configuration = metadata.configuration,
              thread.provider == configuration.provider, thread.workspacePath == configuration.workspacePath, thread.acpAgent == configuration.acpAgent,
              revision.snapshot.providerReady(for: thread) else { return false }
        return true
    }
    private func beginMetadataClose(_ id: UUID) -> Task<Void, Never>? {
        guard let metadata = metadataSessions[id] else { return nil }
        if let task = metadata.closeTask { return task }
        let task = startCleanup(projectIDs: Set(metadata.projectID.map { [$0] } ?? []), threadIDs: Set(metadata.threadID.map { [$0] } ?? []), sessions: [metadata.session], workspacePaths: [metadata.path])
        metadataSessions[id]?.closeTask = task
        return task
    }
    public func shutdown() async {
        if let shutdownTask { await shutdownTask.value; return }
        let task = Task { await self.stopRuntime() }; shutdownTask = task
        await task.value
    }
    private func stopRuntime() async {
        if let initialization { _ = try? await initialization.value }
        guard !closing else { return }
        stoppingEffects = true
        if loaded, fatalError == nil { _ = try? await enqueue(.pauseQueues) }
        closing = true
        let history = Array(historyReads.values); historyReads = [:]
        for read in history { read.cancel() }
        let unusedHistoryReviews = Array(historyReviews.values)
        historyReviews = [:]
        let unusedRestoreReviews = Array(checkpointRestoreReviews.values)
        checkpointRestoreReviews = [:]
        let inspections = Array(worktreeInspections.values); worktreeInspections = [:]
        for inspection in inspections { inspection.task.cancel() }
        cancelIdentityRefreshes()
        cancelCheckpointReads()
        let jobs = Array(effects.values); for job in jobs { job.cancel() }
        await closeAllProjectScripts()
        for id in Array(runtimes.keys) { await closeRuntime(id) }
        let metadata = Array(metadataSessions.values); metadataSessions = [:]
        for runtime in metadata where runtime.closeTask == nil {
            _ = startCleanup(projectIDs: Set(runtime.projectID.map { [$0] } ?? []), threadIDs: Set(runtime.threadID.map { [$0] } ?? []), sessions: [runtime.session], workspacePaths: [runtime.path])
        }
        for job in jobs { await job.value }
        for read in history { await read.drain.value }
        for inspection in inspections { _ = try? await inspection.task.value }
        while !cleanupTasks.isEmpty {
            let tasks = cleanupTasks.values.map(\.task)
            for task in tasks { await task.value }
        }
        for prepared in unusedRestoreReviews where revision.snapshot.checkpointRestoreOperation(prepared.review.id) == nil {
            _ = try? await checkpointFactory(URL(fileURLWithPath: prepared.review.workspacePath)).discardRestoreReview(prepared.review.gitReview)
        }
        for prepared in unusedHistoryReviews where revision.snapshot.conversationHistoryOperation(prepared.review.id) == nil {
            if let files = prepared.review.files {
                _ = try? await checkpointFactory(URL(fileURLWithPath: prepared.review.sourceConfiguration.workspacePath)).discardRestoreReview(files.gitReview)
            }
        }
        await drainCommands()
        if loaded {
            do {
                _ = try await database.cancelEffectsAfterProcessLoss(reason: "The app closed.")
                let base = try await database.revision(); var recovered = base.snapshot; recovered.recoverInterruptedWork()
                recovered = await reconcileCompletedClones(in: recovered)
                let receipt = try await database.commit(recovered, event: "workspace.closed", commandID: UUID(), expectedSequence: base.sequence)
                revision = .init(snapshot: recovered, sequence: receipt.sequence); publish()
            } catch { fatalError = error.localizedDescription; publish() }
        }
        incoming.finish(); commandWorker?.cancel(); commandWorker = nil
        for listener in listeners.values { listener.finish() }; listeners = [:]
        ownership.release()
    }
}
