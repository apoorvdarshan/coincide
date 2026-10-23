import Foundation
import CryptoKit

public struct WorkspaceUpdate: Sendable {
    public var snapshot: WorkspaceSnapshot
    public var sequence: Int64
    public var error: String?
}

extension WorkspaceEngine {
    private struct ReviewedCodexDefault: Sendable {
        let selection: CodexDefaultModelSelection
        let incarnation: UUID
        let projectID: UUID
        let configuration: ProviderConfiguration
        let preferences: [String: String]?
        let selectionSource: CodexModelSelectionSource?
    }
    public func reviewCodexDefaultModel(threadID: UUID) async throws -> CodexDefaultModelSelection {
        _ = try await load(); try Task.checkCancellation()
        if await waitForRemovalCommit(threadID: threadID) { throw CancellationError() }
        guard !closing, !stoppingEffects, fatalError == nil,
              let thread = revision.snapshot.threads.first(where: { $0.id == threadID }), thread.provider == .codex,
              !thread.isArchived, let incarnation = threadIncarnations[threadID], revision.snapshot.workspaceReady(for: thread),
              !revision.snapshot.isConversationHistoryLocked(threadID: threadID), !revision.snapshot.isCheckpointRestoreLocked(threadID: threadID),
              !revision.snapshot.isPullRequestCreationLocked(threadID: threadID), !revision.snapshot.isPullRequestCheckoutLocked(threadID: threadID) else {
            throw WorkspaceCommandError("Choose an available Codex conversation before reading its CLI defaults.")
        }
        let configuration = ProviderConfiguration(thread: thread)
        guard !isCodexAuthenticationLocked(configuration) else { throw Self.codexChanging() }
        let observed = try await readHistory(thread: thread, forceOwnedMetadata: true) { try await $0.codexDefaultModelSelection() }
        try observed.validate()
        let physicalWorkspace = URL(fileURLWithPath: thread.workspacePath).standardizedFileURL.resolvingSymlinksInPath().path
        guard URL(fileURLWithPath: observed.workspacePath).standardizedFileURL.resolvingSymlinksInPath().path == physicalWorkspace else {
            throw WorkspaceCommandError("The CLI default response belongs to another checkout.")
        }
        // Bind a physical observation back to the exact registered spelling, including
        // a valid /tmp or user-selected symlink alias. The reducer performs no I/O.
        let selection = try CodexDefaultModelSelection(workspacePath: thread.workspacePath, model: observed.model,
            reasoningEffort: observed.reasoningEffort, catalogModel: observed.catalogModel)
        let reviewed = ReviewedCodexDefault(selection: selection, incarnation: incarnation, projectID: thread.projectID,
            configuration: configuration, preferences: thread.codexReasoningPreferences, selectionSource: thread.codexModelSelectionSource)
        guard selection.workspacePath == thread.workspacePath, ownsCodexDefaultSource(reviewed, threadID: threadID, snapshot: revision.snapshot) else {
            throw WorkspaceCommandError("This conversation changed while reading CLI defaults. Choose CLI Default Model again.")
        }
        codexDefaultReviews[threadID] = reviewed
        return selection
    }
    private func ownsCodexDefaultSource(_ reviewed: ReviewedCodexDefault, threadID: UUID, snapshot: WorkspaceSnapshot) -> Bool {
        guard !closing, !stoppingEffects, fatalError == nil, !isCodexAuthenticationLocked(reviewed.configuration), threadIncarnations[threadID] == reviewed.incarnation,
              let thread = snapshot.threads.first(where: { $0.id == threadID }), !thread.isArchived,
              thread.provider == .codex, thread.projectID == reviewed.projectID,
              thread.provider == reviewed.configuration.provider, thread.workspacePath == reviewed.configuration.workspacePath,
              thread.model == reviewed.configuration.model, thread.reasoningEffort == reviewed.configuration.reasoningEffort,
              ProviderConfiguration(thread: thread).codexRuntimeBinding == reviewed.configuration.codexRuntimeBinding,
              thread.codexReasoningPreferences == reviewed.preferences, thread.codexModelSelectionSource == reviewed.selectionSource else { return false }
        return true
    }
    private func validateCodexDefaultCommand(_ command: EngineCommand, snapshot: WorkspaceSnapshot) throws {
        guard case .client(.editThread(let threadID, .codexDefaultModel(let selection))) = command else { return }
        guard let reviewed = codexDefaultReviews[threadID], reviewed.selection == selection,
              ownsCodexDefaultSource(reviewed, threadID: threadID, snapshot: snapshot) else {
            throw WorkspaceCommandError("The reviewed CLI defaults or conversation changed. Choose CLI Default Model again.")
        }
    }
}

extension WorkspaceEngine {
    public func promptSteeringAvailability(threadID: UUID, queuedID: UUID? = nil) async -> PromptSteeringAvailability {
        do { _ = try await load() } catch { return .init(unavailableReason: "The workspace is unavailable.") }
        guard !closing, !stoppingEffects, fatalError == nil else { return .init(unavailableReason: "The workspace is closing.") }
        if let reason = revision.snapshot.promptSteeringTargetReason(threadID: threadID, queuedID: queuedID) { return .init(unavailableReason: reason) }
        guard let thread = revision.snapshot.threads.first(where: { $0.id == threadID }), let run = thread.activeRun,
              let runtime = runtimes[threadID], runtime.id == thread.runtimeID else { return .init(unavailableReason: "Wait for the active provider connection.") }
        guard !isCodexAuthenticationLocked(run.configuration) else { return .init(unavailableReason: Self.codexChanging().localizedDescription) }
        let incarnation = threadIncarnations[threadID]
        let capabilities = await runtime.session.steeringCapabilities()
        guard !closing, !stoppingEffects, threadIncarnations[threadID] == incarnation,
              runtimes[threadID]?.id == runtime.id,
              revision.snapshot.threads.first(where: { $0.id == threadID })?.activeRun == run,
              revision.snapshot.promptSteeringTargetReason(threadID: threadID, queuedID: queuedID) == nil else {
            return .init(unavailableReason: "The active turn changed. Choose its current delivery action again.")
        }
        let target = capabilities.target ?? run.nativeTurnID.map(ProviderSteeringTarget.nativeTurn)
        let canSteer = capabilities.supportsActiveSteering && target?.matches(run: run) == true
        return .init(canSteer: canSteer, runID: run.id, configuration: run.configuration,
                     interruptsTools: capabilities.interruptsTools,
                     unavailableReason: canSteer ? nil : capabilities.unavailableReason ?? "This provider does not support active steering.", target: canSteer ? target : nil)
    }

    @discardableResult public func steerPrompt(threadID: UUID, text: String, expectedRunID: UUID, queuedID: UUID? = nil) async throws -> WorkspaceCommandReceipt {
        return try await preparePromptSteering(threadID: threadID, text: text, expectedRunID: expectedRunID, queuedID: queuedID, preservesComposer: false).receipt
    }
    func steerAppMCPPrompt(threadID: UUID, text: String, expectedRunID: UUID) async throws -> (receipt: WorkspaceCommandReceipt, operationID: UUID) {
        return try await preparePromptSteering(threadID: threadID, text: text, expectedRunID: expectedRunID, queuedID: nil, preservesComposer: true)
    }
    private func preparePromptSteering(threadID: UUID, text: String, expectedRunID: UUID, queuedID: UUID?, preservesComposer: Bool) async throws -> (receipt: WorkspaceCommandReceipt, operationID: UUID) {
        let availability = await promptSteeringAvailability(threadID: threadID, queuedID: queuedID)
        guard availability.canSteer, availability.runID == expectedRunID,
              let thread = revision.snapshot.threads.first(where: { $0.id == threadID }), let run = thread.activeRun,
              run.id == expectedRunID, let target = availability.target, target.matches(run: run), let nativeID = thread.providerThreadID,
              let incarnation = threadIncarnations[threadID], let runtime = runtimes[threadID], runtime.id == thread.runtimeID else {
            throw WorkspaceCommandError(availability.unavailableReason ?? "The exact active turn is no longer available for steering.")
        }
        let input: QueuedTurn
        if let queuedID {
            guard let queued = thread.queuedTurns.first(where: { $0.id == queuedID }) else { throw WorkspaceCommandError("The selected queued input changed.") }
            input = queued
        } else {
            let value = preservesComposer ? text : text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard value.utf16.count <= 120_000, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (!preservesComposer && !thread.draftAttachments.isEmpty) else { throw WorkspaceCommandError("Enter a message or attach a file before steering.") }
            input = .init(id: UUID(), text: value, configuration: run.configuration, createdAt: Date(),
                          attachments: preservesComposer || thread.draftAttachments.isEmpty ? nil : thread.draftAttachments, checkpointPolicy: thread.effectiveCheckpointPolicy)
        }
        var operation = PromptSteeringOperation(threadID: threadID, projectID: thread.projectID, sourceIncarnation: incarnation,
            runtimeID: runtime.id, runID: run.id, nativeThreadID: nativeID, target: target, input: input,
            messageID: "user-\(input.id.uuidString)", queuedID: queuedID, configuration: run.configuration)
        if preservesComposer { operation.preservesComposer = true }
        let receipt = try await enqueue(.promptSteeringAccepted(operation))
        if let rejection = receipt.rejection { throw WorkspaceCommandError(rejection) }
        return (receipt, operation.id)
    }

    private func ownsPromptSteeringEvent(_ command: EngineCommand) -> Bool {
        switch command {
        case .promptSteeringAccepted(let operation): return threadIncarnations[operation.threadID] == operation.sourceIncarnation
        case .promptSteeringDispatching(let id, let incarnation):
            guard let operation = revision.snapshot.promptSteering(id) else { return false }
            return threadIncarnations[operation.threadID] == incarnation
        case .promptSteeringEffectResult(let request, _, let incarnation): return request.threadID.map { threadIncarnations[$0] == incarnation } ?? false
        default: return true
        }
    }
    private func ownsPiHistoryEvent(_ command: EngineCommand) -> Bool {
        switch command {
        case .piRunHistoryPrepared(let threadID, let runtimeID, _, let incarnation):
            return threadIncarnations[threadID] == incarnation && runtimes[threadID]?.id == runtimeID
        case .piSteeringInputPrepared(let operationID, _, let incarnation):
            guard let operation = revision.snapshot.promptSteering(operationID) else { return false }
            return threadIncarnations[operation.threadID] == incarnation && runtimes[operation.threadID]?.id == operation.runtimeID
        default: return true
        }
    }
    private func steeringTargetIsActive(_ operation: PromptSteeringOperation) -> Bool {
        guard !closing, !stoppingEffects, fatalError == nil, !isCodexAuthenticationLocked(operation.configuration), threadIncarnations[operation.threadID] == operation.sourceIncarnation,
              let thread = revision.snapshot.threads.first(where: { $0.id == operation.threadID }), !thread.isArchived,
              thread.runtimeRequests.isEmpty, thread.settlement == nil, revision.snapshot.workspaceReady(for: thread),
              !revision.snapshot.isConversationHistoryLocked(threadID: thread.id), !revision.snapshot.isCheckpointRestoreLocked(threadID: thread.id),
              !revision.snapshot.isPullRequestCreationLocked(threadID: thread.id), !revision.snapshot.isPullRequestCheckoutLocked(threadID: thread.id),
              let current = revision.snapshot.promptSteering(operation.id), current.isWorking, current.fallbackAllowed,
              thread.activeRun?.id == operation.runID, thread.activeRun.map({ operation.matchesActiveRun($0) }) == true,
              thread.activeRun?.stopRequested == false, thread.activeRun?.configuration == operation.configuration,
              thread.providerThreadID == operation.nativeThreadID, thread.runtimeID == operation.runtimeID,
              runtimes[thread.id]?.id == operation.runtimeID else { return false }
        return true
    }
    private func steeringUnsentResult(_ operation: PromptSteeringOperation) -> EffectResult {
        guard !closing, !stoppingEffects, threadIncarnations[operation.threadID] == operation.sourceIncarnation,
              revision.snapshot.promptSteering(operation.id)?.fallbackAllowed == true,
              let thread = revision.snapshot.threads.first(where: { $0.id == operation.threadID }), !thread.isArchived,
              !thread.queuePaused, thread.activeRun == nil,
              thread.runHistory?.contains(where: { $0.id == operation.runID && $0.status == .completed && !$0.stopRequested }) == true else { return .failed(PromptSteeringOperation.failureMessage) }
        return .promptSteeringUnsentCompleted
    }
    private func performPromptSteering(_ request: WorkspaceEffectRequest) async -> EffectResult {
        guard case .promptSteering(let threadID, let id) = request,
              let operation = revision.snapshot.promptSteering(id), operation.phase == .accepted,
              threadIncarnations[threadID] == operation.sourceIncarnation else { return .cancelled }
        guard steeringTargetIsActive(operation) else { return steeringUnsentResult(operation) }
        guard let runtime = runtimes[threadID] else { return .failed(PromptSteeringOperation.failureMessage) }
        do {
            let input = try await attachments.prepare(text: operation.input.text, attachments: operation.input.attachments ?? [])
            guard steeringTargetIsActive(operation) else { return steeringUnsentResult(operation) }
            let capabilities = await runtime.session.steeringCapabilities()
            guard steeringTargetIsActive(operation) else { return steeringUnsentResult(operation) }
            let advertisedTarget = capabilities.target ?? threadNativeSteeringTarget(threadID: threadID)
            guard capabilities.supportsActiveSteering, let target = operation.target, advertisedTarget == target else {
                return .failed(PromptSteeringOperation.failureMessage)
            }
            if operation.configuration.provider == .pi, operation.configuration.piConfiguration?.runtime != nil {
                return await performPreparedPiSteering(operation, input: input, session: runtime.session, target: target)
            }
            try Task.checkCancellation()
            let receipt = try await enqueue(.promptSteeringDispatching(operationID: id, incarnation: operation.sourceIncarnation))
            guard receipt.rejection == nil else { return steeringUnsentResult(operation) }
            guard steeringTargetIsActive(operation), var thread = revision.snapshot.threads.first(where: { $0.id == threadID }) else { return steeringUnsentResult(operation) }
            try Task.checkCancellation() // Still proven unsent; the durable marker is conservative after a crash.
            let configuration = operation.configuration
            thread.provider = configuration.provider; thread.workspacePath = configuration.workspacePath
            thread.model = configuration.model; thread.reasoningEffort = configuration.reasoningEffort; thread.permission = configuration.permission
            thread.agentModeID = configuration.agentModeID; thread.agentConfigValues = configuration.agentConfigValues
            thread.agentConfiguration = configuration.agentConfiguration; thread.acpAgent = configuration.acpAgent; thread.openCodeConfiguration = configuration.openCodeConfiguration; thread.piConfiguration = configuration.piConfiguration; thread.museConfiguration = configuration.museConfiguration; thread.antigravityConfiguration = configuration.antigravityConfiguration; thread.codexRuntimeConfiguration = configuration.codexRuntimeConfiguration; thread.claudeRuntimeConfiguration = configuration.claudeRuntimeConfiguration
            thread.providerThreadID = operation.nativeThreadID
            do {
                let result = try await runtime.session.steer(input: input, thread: thread, target: target, clientMessageID: operation.messageID)
                try result.validate()
                guard result.target == target else { return .promptSteeringUnconfirmed }
                return .promptSteeringDelivered(result)
            } catch let error as ProviderSteeringError {
                if error.mayHaveBeenDelivered { return .promptSteeringUnconfirmed }
                if error.kind == .noActiveTurn || error.kind == .staleTarget {
                    // Only the adapter's proven pre-write refusal plus an observed
                    // exact parent completion can authorize one normal follow-up.
                    await drainCommands()
                    return steeringUnsentResult(operation)
                }
                return .failed(PromptSteeringOperation.failureMessage)
            } catch { return .promptSteeringUnconfirmed }
        } catch { return .failed(PromptSteeringOperation.failureMessage) }
    }
    private func performPreparedPiSteering(_ operation: PromptSteeringOperation, input: ProviderInput,
        session: any ProviderSession, target: ProviderSteeringTarget) async -> EffectResult {
        let preparation: PiSteeringHistoryPreparation
        do {
            guard steeringTargetIsActive(operation), let current = revision.snapshot.threads.first(where: { $0.id == operation.threadID }) else { return steeringUnsentResult(operation) }
            preparation = try await session.preparePiSteering(input: input, thread: current, target: target, clientMessageID: operation.messageID)
        } catch { return await piSteeringFailure(error, operation: operation) }
        let result: EffectResult
        do { result = try await dispatchPreparedPiSteering(operation, input: input, session: session, target: target, preparation: preparation) }
        catch { result = await piSteeringFailure(error, operation: operation) }
        // Release/join this exact reservation on every exit, including a stale
        // reducer marker or cancellation. This never transmits an input.
        await session.cancelPiSteeringPreparation(preparation)
        return result
    }
    private func dispatchPreparedPiSteering(_ operation: PromptSteeringOperation, input: ProviderInput,
        session: any ProviderSession, target: ProviderSteeringTarget, preparation: PiSteeringHistoryPreparation) async throws -> EffectResult {
        try preparation.validate(); try Task.checkCancellation()
        guard steeringTargetIsActive(operation), preparation.runID == operation.runID,
              preparation.runtimeIdentity == operation.configuration.piConfiguration?.runtimeIdentity,
              preparation.input.matchesAuthored(try PiHistoryInputEvidence.steering(clientMessageID: operation.messageID, input: input)),
              revision.snapshot.threads.first(where: { $0.id == operation.threadID })?.runHistory?.first(where: { $0.id == operation.runID })?.pi?.preparation.id == preparation.runPreparationID else {
            return steeringUnsentResult(operation)
        }
        let dispatched = try await enqueue(.promptSteeringDispatching(operationID: operation.id, incarnation: operation.sourceIncarnation))
        guard dispatched.rejection == nil, steeringTargetIsActive(operation) else { return steeringUnsentResult(operation) }
        let saved = try await enqueue(.piSteeringInputPrepared(operationID: operation.id, input: preparation.input, incarnation: operation.sourceIncarnation))
        guard saved.rejection == nil, steeringTargetIsActive(operation),
              var current = revision.snapshot.threads.first(where: { $0.id == operation.threadID }),
              current.runHistory?.first(where: { $0.id == operation.runID })?.pi?.inputs.contains(preparation.input) == true else { return .failed(PromptSteeringOperation.failureMessage) }
        try Task.checkCancellation()
        current.piConfiguration = operation.configuration.piConfiguration; current.model = operation.configuration.model
        current.permission = operation.configuration.permission; current.workspacePath = operation.configuration.workspacePath
        current.providerThreadID = operation.nativeThreadID
        let receipt = try await session.sendPreparedPiSteering(input: input, thread: current, target: target,
            clientMessageID: operation.messageID, preparation: preparation)
        try receipt.validate()
        guard receipt.target == target else { return .promptSteeringUnconfirmed }
        return .promptSteeringDelivered(receipt)
    }
    private func piSteeringFailure(_ error: any Error, operation: PromptSteeringOperation) async -> EffectResult {
        if let error = error as? ProviderSteeringError {
            if error.mayHaveBeenDelivered { return .promptSteeringUnconfirmed }
            if error.kind == .noActiveTurn || error.kind == .staleTarget {
                await drainCommands()
                return steeringUnsentResult(operation)
            }
        }
        return .failed(PromptSteeringOperation.failureMessage)
    }
    private func threadNativeSteeringTarget(threadID: UUID) -> ProviderSteeringTarget? {
        revision.snapshot.threads.first(where: { $0.id == threadID })?.activeRun?.nativeTurnID.map(ProviderSteeringTarget.nativeTurn)
    }
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
        guard !closing, !stoppingEffects, fatalError == nil, !isCodexAuthenticationLocked(.init(thread: thread)), let incarnation = threadIncarnations[thread.id] else { throw CancellationError() }
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

    /// A review drains applicable owned idle connections before reading. Its
    /// ephemeral token binds this incarnation and the complete returned value.
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
              record.status.isTerminal,
              record.providerThreadID == thread.providerThreadID || thread.provider == .claude || thread.provider == .pi || (thread.provider == .opencode && thread.openCodeConfiguration?.generation == .v1),
              record.configuration.provider == thread.provider,
              record.configuration.workspacePath == thread.workspacePath else {
            throw WorkspaceCommandError("Finish this conversation's work and select a run with verified provider history before continuing.")
        }
        let fingerprint = try revision.snapshot.historySourceFingerprint(threadID: threadID)
        let rawPrefix = try thread.transcriptPrefix(runID: runID, boundary: kind == .forkAfterRun ? .afterRun : .beforeRun)
        var prefix = kind == .forkAfterRun && thread.provider != .claude && thread.provider != .pi ? try revision.snapshot.verifiedForkPrefix(rawPrefix) : rawPrefix
        let native: ReviewedNativeHistory?
        let claude: ClaudeHistoryReviewEvidence?
        let openCodeV1: OpenCodeV1HistoryReviewEvidence?
        let openCodeV2: OpenCodeV2HistoryReviewEvidence?
        let pi: PiHistoryReviewEvidence?
        let reviewID = UUID()
        if thread.provider == .pi {
            guard thread.piConfiguration?.runtime != nil, piHistoryScopeIsolated(thread: thread) else { throw ProviderHistoryError(.notIdle) }
            let observed = try await readPiHistorySnapshot(thread: thread)
            guard ownsHistorySource(threadID: threadID, incarnation: incarnation, fingerprint: fingerprint),
                  piHistoryScopeIsolated(thread: thread) else { throw ProviderHistoryError(.historyChanged) }
            pi = try PiHistoryReviewEvidence.make(source: observed, snapshot: revision.snapshot, thread: thread,
                runID: runID, kind: kind, operationID: reviewID)
            if let pi { prefix = try revision.snapshot.verifiedPiHistoryPrefix(rawPrefix, evidence: pi, threadID: threadID, fork: kind == .forkAfterRun) }
            native = nil; claude = nil; openCodeV1 = nil; openCodeV2 = nil
        } else if thread.provider == .claude {
            pi = nil
            guard let nativeID = thread.providerThreadID, claudeHistoryScopeIsolated(thread: thread) else { throw ProviderHistoryError(.notIdle) }
            // Claude flushes native metadata while its idle process closes. The
            // reviewed revision must include that flush; accepting an earlier
            // revision would make our own later drain invalidate the review.
            try await drainClaudeHistoryOwners(thread: thread)
            guard ownsHistorySource(threadID: threadID, incarnation: incarnation, fingerprint: fingerprint),
                  revision.snapshot.canReviewConversationHistory(threadID: threadID),
                  claudeHistoryScopeIsolated(thread: thread) else { throw ProviderHistoryError(.historyChanged) }
            let observed = try await readClaudeHistory(thread: thread) { service in
                let first = try service.snapshot(sessionID: nativeID, selection: thread.claudeResumeSelection)
                guard first == (try service.snapshot(sessionID: nativeID, selection: thread.claudeResumeSelection)) else { throw ProviderHistoryError(.historyChanged) }
                return first
            }
            let evidence = try ClaudeHistoryReviewEvidence.make(source: observed, snapshot: revision.snapshot, thread: thread, runID: runID, kind: kind)
            prefix = try revision.snapshot.verifiedClaudeHistoryPrefix(rawPrefix, evidence: evidence, threadID: threadID, fork: kind == .forkAfterRun)
            claude = evidence; native = nil; openCodeV1 = nil; openCodeV2 = nil
        } else if thread.provider == .opencode, thread.openCodeConfiguration?.generation == .v1 {
            pi = nil
            claude = nil
            guard openCodeHistoryScopeIsolated(thread: thread), let nativeID = thread.providerThreadID else { throw ProviderHistoryError(.notIdle) }
            let observed = try await readHistory(thread: thread) { try await $0.openCodeV1HistorySnapshot(threadID: nativeID) }
            guard ownsHistorySource(threadID: threadID, incarnation: incarnation, fingerprint: fingerprint),
                  openCodeHistoryScopeIsolated(thread: thread) else { throw ProviderHistoryError(.historyChanged) }
            let evidence = try OpenCodeV1HistoryReviewEvidence.make(source: observed, snapshot: revision.snapshot,
                thread: thread, runID: runID, kind: kind)
            openCodeV1 = evidence; openCodeV2 = nil
            native = .init(snapshot: try .init(reference: observed.reference, workspacePath: observed.workspacePath,
                historyMode: .messageOrdered, openCodeV1: observed), boundary: evidence.boundary, resultingHead: nil)
        } else if thread.provider == .opencode, thread.openCodeConfiguration?.generation == .v2 {
            pi = nil
            claude = nil
            guard openCodeHistoryScopeIsolated(thread: thread), let nativeID = thread.providerThreadID else { throw ProviderHistoryError(.notIdle) }
            let observed = try await readHistory(thread: thread) { try await $0.openCodeV2HistorySnapshot(threadID: nativeID) }
            guard ownsHistorySource(threadID: threadID, incarnation: incarnation, fingerprint: fingerprint),
                  openCodeHistoryScopeIsolated(thread: thread) else { throw ProviderHistoryError(.historyChanged) }
            let evidence = try OpenCodeV2HistoryReviewEvidence.make(source: observed, snapshot: revision.snapshot,
                thread: thread, runID: runID, kind: kind)
            openCodeV1 = nil; openCodeV2 = evidence
            native = .init(snapshot: try .init(reference: observed.reference, workspacePath: observed.workspacePath,
                historyMode: .messageOrdered, openCodeV2: observed), boundary: evidence.boundary, resultingHead: nil)
        } else {
            pi = nil
            claude = nil; openCodeV1 = nil; openCodeV2 = nil
            native = try await readHistory(thread: thread) { session in
                try await Self.readReviewedNativeHistory(session: session, thread: thread, runID: runID, kind: kind)
            }
        }
        guard ownsHistorySource(threadID: threadID, incarnation: incarnation, fingerprint: fingerprint),
              revision.snapshot.canReviewConversationHistory(threadID: threadID) else { throw ProviderHistoryError(.historyChanged) }
        let activeRecords = (thread.runHistory ?? []).filter { $0.removedByHistoryOperationID == nil }
        guard let index = activeRecords.firstIndex(where: { $0.id == runID }),
              native?.snapshot.headTurnID != nil || openCodeV2 != nil || openCodeV1 != nil || claude != nil || pi != nil else { throw ProviderHistoryError(.boundaryUnavailable) }
        guard let sourceReference = pi?.source.reference ?? claude?.source.reference ?? native?.snapshot.reference,
              let boundary = pi?.boundary.providerBoundary ?? claude?.boundary.providerBoundary ?? native?.boundary else { throw ProviderHistoryError(.boundaryUnavailable) }
        let review = try ConversationHistoryReview(id: reviewID, kind: kind, sourceThreadID: threadID, projectID: thread.projectID,
            runID: runID, sourceIncarnation: incarnation, sourceConfiguration: .init(thread: thread),
            targetConfiguration: record.configuration, sourceReference: sourceReference,
            reviewedHeadTurnID: native?.snapshot.headTurnID, boundary: boundary, expectedResultHeadTurnID: native?.resultingHead,
            prefix: prefix, removedRunIDs: kind == .rewindBeforeRun ? activeRecords[index...].map(\.id) : [],
            removedMessageIDs: kind == .rewindBeforeRun ? thread.visibleMessages.dropFirst(prefix.count).map(\.id) : [],
            sourceFingerprint: fingerprint, targetThreadID: kind == .forkAfterRun ? UUID() : nil,
            suggestedTitle: String((thread.title + " — Fork").prefix(200)),
            recallPromptOnSuccess: kind == .rewindBeforeRun && recallPromptOnSuccess ? true : nil,
            openCodeV2: openCodeV2, openCodeV1: openCodeV1, claude: claude, pi: pi)
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
            guard (fresh.boundary == keepReview.boundary || (fresh.claude.map { value in keepReview.claude.map { value.sameLogicalBoundary(as: $0) } == true } == true) ||
                   (fresh.pi.map { value in keepReview.pi.map { value.sameLogicalBoundary(as: $0) } == true } == true)), fresh.reviewedHeadTurnID == keepReview.reviewedHeadTurnID,
                  let thread = revision.snapshot.threads.first(where: { $0.id == fresh.sourceThreadID }),
                  revision.snapshot.canReviewCheckpointRestore(threadID: thread.id),
                  case .available(let target) = try revision.snapshot.conversationHistoryFileTarget(for: fresh),
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
                reviewedHeadTurnID: fresh.reviewedHeadTurnID, boundary: keepReview.claude != nil ? keepReview.boundary : fresh.boundary,
                expectedResultHeadTurnID: fresh.expectedResultHeadTurnID, prefix: fresh.prefix,
                removedRunIDs: fresh.removedRunIDs, removedMessageIDs: fresh.removedMessageIDs,
                sourceFingerprint: fresh.sourceFingerprint, targetThreadID: fresh.targetThreadID,
                suggestedTitle: fresh.suggestedTitle, files: files, recallPromptOnSuccess: fresh.recallPromptOnSuccess,
                openCodeV2: fresh.openCodeV2, openCodeV1: fresh.openCodeV1, claude: keepReview.claude ?? fresh.claude, pi: fresh.pi)
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
              operation.phase == .unconfirmed, revision.snapshot.canInspectConversationHistory(operationID: operationID),
              let thread = revision.snapshot.threads.first(where: { $0.id == operation.review.sourceThreadID }),
              let incarnation = threadIncarnations[thread.id], !thread.isBusy, thread.queuedTurns.isEmpty,
              thread.runtimeRequests.isEmpty,
              try revision.snapshot.historySourceFingerprint(threadID: thread.id) == operation.review.sourceFingerprint else { throw ProviderHistoryError(.historyChanged) }
        let expected = operation.review
        if expected.pi != nil { return try await reconcilePiHistory(operation: operation, thread: thread, incarnation: incarnation) }
        if expected.claude != nil { return try await reconcileClaudeHistory(operation: operation, thread: thread, incarnation: incarnation) }
        if expected.openCodeV1 != nil { return try await reconcileOpenCodeV1History(operation: operation, thread: thread, incarnation: incarnation) }
        if expected.openCodeV2 != nil { return try await reconcileOpenCodeV2History(operation: operation, thread: thread, incarnation: incarnation) }
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
            revision.snapshot.threads.first(where: { $0.id == threadID }).map { !isCodexAuthenticationLocked(.init(thread: $0)) } == true &&
            (try? revision.snapshot.historySourceFingerprint(threadID: threadID)) == fingerprint
    }
    private func ownsHistoryEvent(_ command: EngineCommand) -> Bool {
        switch command {
        case .piFreshSessionResolved(let threadID, let incarnation, _, _, _): return threadIncarnations[threadID] == incarnation
        case .conversationHistoryPiCandidateObserved(let id, _, let incarnation),
             .conversationHistoryPiControlsOpened(let id, _, let incarnation),
             .conversationHistoryPiControlEvent(let id, _, _, let incarnation),
             .conversationHistoryPiControlResponding(let id, _, _, _, let incarnation),
             .conversationHistoryPiControlsClosed(let id, _, let incarnation),
             .conversationHistoryPiCancelled(let id, let incarnation):
            guard let operation = revision.snapshot.conversationHistoryOperation(id) else { return false }
            return operation.review.sourceIncarnation == incarnation && threadIncarnations[operation.review.sourceThreadID] == incarnation
        case .claudeResumeInspected(let thread, let incarnation, _, _, _): return threadIncarnations[thread] == incarnation
        case .conversationHistoryAccepted(let review, _):
            return threadIncarnations[review.sourceThreadID] == review.sourceIncarnation
        case .conversationHistoryDispatching(let thread, _, let incarnation): return threadIncarnations[thread] == incarnation
        case .conversationHistoryCandidateObserved(let id, _, let incarnation), .conversationHistoryClaudeForkReserved(let id, _, let incarnation):
            guard let operation = revision.snapshot.conversationHistoryOperation(id) else { return false }
            return operation.review.sourceIncarnation == incarnation && threadIncarnations[operation.review.sourceThreadID] == incarnation
        case .conversationHistoryEffectResult(let request, _, let incarnation): return request.threadID.map { threadIncarnations[$0] == incarnation } ?? false
        case .conversationHistoryReconciled(let id, let incarnation, _):
            guard let operation = revision.snapshot.conversationHistoryOperations?.first(where: { $0.id == id }) else { return false }
            return threadIncarnations[operation.review.sourceThreadID] == incarnation
        case .conversationHistoryMaintenanceAccepted(let id, _, let incarnation),
             .conversationHistoryMaintenanceDispatching(_, let id, _, let incarnation):
            guard let operation = revision.snapshot.conversationHistoryOperation(id) else { return false }
            return threadIncarnations[operation.review.sourceThreadID] == incarnation
        case .conversationHistoryMaintenanceEffectResult(let request, _, let incarnation):
            return request.threadID.map { threadIncarnations[$0] == incarnation } ?? false
        case .conversationHistoryFilesDispatching(let thread, _, let incarnation): return threadIncarnations[thread] == incarnation
        case .conversationHistoryFilesEffectResult(let request, _, let incarnation): return request.threadID.map { threadIncarnations[$0] == incarnation } ?? false
        case .conversationHistoryFilesInspected(let id, let incarnation, _):
            guard let operation = revision.snapshot.conversationHistoryOperation(id) else { return false }
            return threadIncarnations[operation.review.sourceThreadID] == incarnation
        default: return true
        }
    }

    private func readHistory<Value: Sendable>(thread: CodingThread, forceOwnedMetadata: Bool = false,
                                              operation: @escaping @Sendable (any ProviderSession) async throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        guard !closing, !stoppingEffects, fatalError == nil, !isCodexAuthenticationLocked(.init(thread: thread)),
              !openCodeHistoryScopeOwnedElsewhere(thread: thread),
              let incarnation = threadIncarnations[thread.id] else { throw CancellationError() }
        let token = UUID(), metadataID: UUID?, session: any ProviderSession
        if !forceOwnedMetadata, let runtime = runtimes[thread.id], runtime.id == thread.runtimeID, runtime.provider == thread.provider,
           runtime.path == thread.workspacePath, runtime.acpAgent == thread.acpAgent, runtime.openCodeIdentity == thread.openCodeConfiguration?.runtimeIdentity, runtime.grokRuntimeMode == ProviderConfiguration(thread: thread).effectiveGrokRuntimeMode, runtime.piBinding == ProviderConfiguration(thread: thread).piRuntimeBinding, runtime.museBinding == ProviderConfiguration(thread: thread).museRuntimeBinding, runtime.antigravityBinding == ProviderConfiguration(thread: thread).antigravityRuntimeBinding, runtime.codexBinding == ProviderConfiguration(thread: thread).codexRuntimeBinding, claudeRuntimeMatches(runtime, thread: thread) {
            metadataID = nil; session = runtime.session
        } else {
            var configured = thread
            if forceOwnedMetadata {
                configured.activeRun = nil; configured.runtimeID = nil; configured.runtimeRequests = []
                configured.providerActivity = nil; configured.state = .idle
            }
            let id = UUID(); metadataID = id; session = try factory(configured)
            metadataSessions[id] = .init(session: session, path: thread.workspacePath, threadID: thread.id, projectID: thread.projectID, configuration: .init(thread: thread), launchConfiguration: .init(thread: configured))
        }
        let task = Task { try await operation(session) }
        historyReads[token] = .init(threadID: thread.id, projectID: thread.projectID,
            drain: Task { _ = try? await task.value }, cancel: { task.cancel() }, configuration: .init(thread: thread))
        defer { historyReads.removeValue(forKey: token) }
        do {
            let value = try await withTaskCancellationHandler { try await task.value } onCancel: {
                task.cancel()
                if let metadataID {
                    Task { [weak self] in await self?.cancelOwnedHistoryRead(metadataID) }
                }
            }
            try Task.checkCancellation()
            guard !task.isCancelled, !closing, !stoppingEffects, fatalError == nil, !isCodexAuthenticationLocked(.init(thread: thread)), !openCodeHistoryScopeOwnedElsewhere(thread: thread), threadIncarnations[thread.id] == incarnation else { throw CancellationError() }
            if let metadataID {
                if let close = beginMetadataClose(metadataID) { await close.value }
                guard metadataSessions[metadataID] != nil else { throw CancellationError() }
                metadataSessions.removeValue(forKey: metadataID)
            }
            try Task.checkCancellation()
            guard !closing, !stoppingEffects, !isCodexAuthenticationLocked(.init(thread: thread)), !openCodeHistoryScopeOwnedElsewhere(thread: thread), threadIncarnations[thread.id] == incarnation else { throw CancellationError() }
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

    private func cancelOwnedHistoryRead(_ id: UUID) {
        // Reused active runtimes have no metadata ID and never enter this path.
        // Register one idempotent close before waiting for a cancellation-resistant read.
        _ = beginMetadataClose(id)
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
        if review.pi != nil { return await performPiConversationHistory(operation: operation, thread: thread, incarnation: incarnation) }
        if review.claude != nil { return await performClaudeConversationHistory(request, operation: operation, thread: thread, incarnation: incarnation) }
        if review.openCodeV1 != nil || review.openCodeV2 != nil {
            do { try await drainOpenCodeHistoryCleanup(thread: thread) }
            catch { return .failed(ConversationHistoryOperation.failureMessage) }
            guard ownsHistorySource(threadID: threadID, incarnation: incarnation, fingerprint: review.sourceFingerprint),
                  revision.snapshot.conversationHistoryOperation(operationID) == operation,
                  openCodeHistoryScopeIsolated(thread: thread) else { return .failed(ConversationHistoryOperation.failureMessage) }
        }
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
           runtime.provider == thread.provider, runtime.path == thread.workspacePath, runtime.acpAgent == thread.acpAgent, runtime.openCodeIdentity == thread.openCodeConfiguration?.runtimeIdentity, runtime.grokRuntimeMode == ProviderConfiguration(thread: thread).effectiveGrokRuntimeMode, runtime.piBinding == ProviderConfiguration(thread: thread).piRuntimeBinding, runtime.museBinding == ProviderConfiguration(thread: thread).museRuntimeBinding, runtime.antigravityBinding == ProviderConfiguration(thread: thread).antigravityRuntimeBinding, runtime.codexBinding == ProviderConfiguration(thread: thread).codexRuntimeBinding, claudeRuntimeMatches(runtime, thread: thread) {
            metadataID = nil; session = runtime.session
        } else {
            var configured = thread
            if review.kind == .forkAfterRun {
                guard let project = revision.snapshot.projects.first(where: { $0.id == thread.projectID }) else { return .cancelled }
                configured = CodingThread(project: project, model: review.targetConfiguration.model)
                configured.id = review.targetThreadID!; configured.workspacePath = review.targetConfiguration.workspacePath
                configured.provider = review.targetConfiguration.provider; configured.reasoningEffort = review.targetConfiguration.reasoningEffort; configured.permission = review.targetConfiguration.permission
                configured.acpAgent = review.targetConfiguration.acpAgent; configured.openCodeConfiguration = review.targetConfiguration.openCodeConfiguration; configured.piConfiguration = review.targetConfiguration.piConfiguration; configured.museConfiguration = review.targetConfiguration.museConfiguration; configured.antigravityConfiguration = review.targetConfiguration.antigravityConfiguration; configured.codexRuntimeConfiguration = review.targetConfiguration.codexRuntimeConfiguration; configured.agentModeID = review.targetConfiguration.agentModeID
                configured.agentConfigValues = review.targetConfiguration.agentConfigValues; configured.agentConfiguration = review.targetConfiguration.agentConfiguration
            }
            let id = UUID(); metadataID = id; session = try factory(configured)
            metadataSessions[id] = .init(session: session, path: configured.workspacePath, threadID: threadID, projectID: thread.projectID, configuration: .init(thread: thread), launchConfiguration: .init(thread: configured))
        }
        let reusedRuntimeID = metadataID == nil ? runtimes[threadID]?.id : nil
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
            if let evidence = review.openCodeV1 {
                guard openCodeHistoryScopeIsolated(thread: thread) else { throw ProviderHistoryError(.notIdle) }
                let configuration = review.kind == .rewindBeforeRun ? review.sourceConfiguration : review.targetConfiguration
                snapshot = try await session.applyOpenCodeV1History(review: evidence, kind: review.kind, configuration: configuration) { [weak self] candidate in
                    guard let self else { throw CancellationError() }
                    try await self.publishOpenCodeV1HistoryCandidate(candidate, review: review, incarnation: incarnation)
                }
            } else if let evidence = review.openCodeV2 {
                guard openCodeHistoryScopeIsolated(thread: thread) else { throw ProviderHistoryError(.notIdle) }
                snapshot = try await session.applyOpenCodeV2History(review: evidence, kind: review.kind, configuration: review.targetConfiguration)
            }
            else if review.kind == .forkAfterRun { snapshot = try await session.forkConversation(source: review.sourceReference, boundary: review.boundary, configuration: review.targetConfiguration) }
            else {
                guard case .beforeTurn(let turnID) = review.boundary, let head = review.reviewedHeadTurnID else { throw ProviderHistoryError(.invalidRequest) }
                snapshot = try await session.revertConversation(thread: review.sourceReference, beforeTurnID: turnID, expectedHeadTurnID: head)
            }
            try Task.checkCancellation()
            guard ownsHistorySource(threadID: threadID, incarnation: incarnation, fingerprint: review.sourceFingerprint) else { throw CancellationError() }
            try review.validateResult(snapshot)
            if review.openCodeV1 != nil {
                guard revision.snapshot.conversationHistoryOperation(operationID)?.openCodeV1Candidate?.reference == snapshot.reference,
                      openCodeHistoryScopeIsolated(thread: thread) else { throw ProviderHistoryError(.outcomeUncertain) }
            }
            result = .conversationHistoryConfirmed(snapshot)
        } catch {
            if dispatched, error is CancellationError || (error as? ProviderHistoryError)?.kind == .outcomeUncertain {
                result = .conversationHistoryUnconfirmed
            } else if dispatched, !(error is ProviderHistoryError) { result = .conversationHistoryUnconfirmed }
            else { result = .failed(ConversationHistoryOperation.failureMessage) }
        }
        let retireSource: Bool
        if review.openCodeV2 != nil || review.openCodeV1 != nil, case .failed = result { retireSource = false }
        else { retireSource = review.kind == .rewindBeforeRun }
        if let metadataID {
            if let close = beginMetadataClose(metadataID) { await close.value }
            metadataSessions.removeValue(forKey: metadataID)
        } else if retireSource, let reusedRuntimeID {
            // Retire this exact old event stream after success/uncertainty.
            // A proved pre-write refusal keeps its healthy OpenCode actor.
            await closeRuntime(threadID, matching: reusedRuntimeID)
        }
        return result
    }

    private func publishOpenCodeV1HistoryCandidate(_ candidate: OpenCodeV1HistoryCandidate,
        review: ConversationHistoryReview, incarnation: UUID) async throws {
        guard let evidence = review.openCodeV1,
              ownsHistorySource(threadID: review.sourceThreadID, incarnation: incarnation, fingerprint: review.sourceFingerprint),
              let operation = revision.snapshot.conversationHistoryOperation(review.id), operation.review == review,
              operation.phase == .dispatching,
              let thread = revision.snapshot.threads.first(where: { $0.id == review.sourceThreadID }),
              openCodeHistoryScopeIsolated(thread: thread, additionalNativeIDs: [candidate.reference.nativeThreadID]) else {
            throw ProviderHistoryError(.outcomeUncertain)
        }
        try evidence.validateCandidate(candidate)
        let receipt = try await enqueue(.conversationHistoryCandidateObserved(operationID: review.id, candidate: candidate, incarnation: incarnation))
        guard receipt.rejection == nil,
              ownsHistorySource(threadID: review.sourceThreadID, incarnation: incarnation, fingerprint: review.sourceFingerprint),
              let current = revision.snapshot.conversationHistoryOperation(review.id), current.review == review,
              current.phase == .dispatching, current.openCodeV1Candidate == candidate,
              openCodeHistoryScopeIsolated(thread: thread, additionalNativeIDs: [candidate.reference.nativeThreadID]) else {
            throw ProviderHistoryError(.outcomeUncertain)
        }
    }
}

extension WorkspaceEngine {
    private func piHistoryScopeIsolated(thread: CodingThread, additionalNativeFiles: [String] = []) -> Bool {
        guard thread.provider == .pi, thread.piConfiguration?.runtime != nil, let native = thread.providerThreadID else { return false }
        let files = [native] + additionalNativeFiles + (revision.snapshot.conversationHistoryOperations ?? []).filter {
            $0.review.sourceThreadID == thread.id && $0.review.pi != nil && $0.locksSource
        }.flatMap { ($0.piCandidates ?? []).compactMap(\.nativeSessionFile) }
        func matches(_ configuration: ProviderConfiguration, _ path: String?) -> Bool {
            configuration.provider == .pi && (path ?? configuration.nativeThreadID).map { candidate in
                files.contains { PiHistoryScope.sameFile($0, candidate) }
            } == true
        }
        if revision.snapshot.threads.contains(where: { other in
            other.id != thread.id && files.contains { revision.snapshot.hasPiHistoryCapture(other, nativeSessionFile: $0) }
        }) { return false }
        if metadataSessions.values.contains(where: { metadata in
            metadata.threadID != thread.id && (matches(metadata.launchConfiguration, nil) || metadata.configuration.map { matches($0, nil) } == true)
        }) || historyReads.values.contains(where: { $0.threadID != thread.id && matches($0.configuration, nil) }) { return false }
        for (operationID, job) in piHistoryJobs where job.threadID != thread.id && !job.closing {
            if let proof = revision.snapshot.conversationHistoryOperation(operationID)?.review.pi,
               files.contains(where: { PiHistoryScope.sameFile($0, proof.source.reference.nativeThreadID) }) { return false }
        }
        return !cleanupTasks.values.contains { $0.threadIDs.contains(thread.id) }
    }

    private func readPiFiles<Value: Sendable>(thread: CodingThread,
        operation: @escaping @Sendable (PiHistoryService) throws -> Value) async throws -> Value {
        guard !closing, !stoppingEffects, fatalError == nil, let configuration = thread.piConfiguration?.runtime,
              let incarnation = threadIncarnations[thread.id], piHistoryScopeIsolated(thread: thread) else { throw ProviderHistoryError(.notIdle) }
        let service = try PiHistoryService(configuration: configuration), token = UUID()
        let task = Task.detached { try Task.checkCancellation(); return try operation(service) }
        historyReads[token] = .init(threadID: thread.id, projectID: thread.projectID,
            drain: Task { _ = try? await task.value }, cancel: { task.cancel() }, configuration: .init(thread: thread))
        defer { historyReads.removeValue(forKey: token) }
        do {
            let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try Task.checkCancellation()
            guard !closing, !stoppingEffects, fatalError == nil, threadIncarnations[thread.id] == incarnation,
                  revision.snapshot.threads.first(where: { $0.id == thread.id })?.piConfiguration?.runtime == configuration,
                  piHistoryScopeIsolated(thread: thread) else { throw ProviderHistoryError(.historyChanged) }
            return result
        } catch { task.cancel(); _ = await task.result; throw error }
    }

    private func readPiHistorySnapshot(thread: CodingThread) async throws -> PiHistorySnapshot {
        guard let native = thread.providerThreadID, piHistoryScopeIsolated(thread: thread) else { throw ProviderHistoryError(.notIdle) }
        if let runtime = runtimes[thread.id], runtime.id == thread.runtimeID, runtime.provider == .pi,
           runtime.piBinding == ProviderConfiguration(thread: thread).piRuntimeBinding, runtime.path == thread.workspacePath {
            return try await readHistory(thread: thread) { try await $0.piHistorySnapshot(threadID: native) }
        }
        if let proof = thread.activeHistoryRuns.last(where: { $0.providerThreadID == native && $0.pi?.finalObservation != nil })?.pi {
            return try await readPiFiles(thread: thread) { try $0.readSnapshot(nativeSessionFile: native, latestRun: proof, freshIntent: thread.piFreshSessionIntent) }
        }
        let observations = (revision.snapshot.conversationHistoryOperations ?? []).filter {
            $0.phase == .applied && ($0.review.sourceThreadID == thread.id || $0.review.targetThreadID == thread.id) &&
            $0.result?.pi?.snapshot.reference.nativeThreadID == native
        }.compactMap { $0.result?.pi?.snapshot }
        guard let expected = observations.last else { throw ProviderHistoryError(.boundaryUnavailable) }
        return try await readPiFiles(thread: thread) { try $0.inspectOriginal(expected: expected) }
    }

    private func routeProviderEvent(threadID: UUID, runtimeID: UUID, event: ProviderEvent) async throws {
        if let (operationID, job) = piHistoryJobs.first(where: { $0.value.threadID == threadID && ($0.value.reusedRuntimeID == runtimeID || $0.value.sourceRuntimeID == runtimeID) }) {
            if job.reusedRuntimeID != runtimeID {
                switch event {
                case .piHistoryBarrier: break
                case .thread, .configuration, .steeringCapabilitiesChanged: return
                default: piHistoryStreamFailed(operationID: operationID, sessionID: job.id); return
                }
            }
            await receivePiHistoryEvent(operationID: operationID, sessionID: job.id, event: event)
            return
        }
        var routed = event
        if case .thread(let nativeID) = event,
           let thread = revision.snapshot.threads.first(where: { $0.id == threadID }),
           revision.snapshot.isPiHistoryScopeLocked(configuration: thread.activeRun?.configuration ?? .init(thread: thread), nativeThreadID: nativeID) {
            routed = .connectionClosed("This Pi conversation is held by a pending history action.")
        }
        _ = try await enqueue(.provider(threadID: threadID, runtimeID: runtimeID, event: routed))
    }
    private func piRuntimeStreamEnded(threadID: UUID, runtimeID: UUID) {
        guard let (operationID, job) = piHistoryJobs.first(where: { $0.value.threadID == threadID && ($0.value.reusedRuntimeID == runtimeID || $0.value.sourceRuntimeID == runtimeID) }) else { return }
        piHistoryStreamFailed(operationID: operationID, sessionID: job.id)
    }
    private func receivePiHistoryEvent(operationID: UUID, sessionID: UUID, event: ProviderEvent) async {
        guard let job = piHistoryJobs[operationID], job.id == sessionID, !job.closing else { return }
        switch event {
        case .piHistoryBarrier(let barrierID):
            guard let waiter = piHistoryJobs[operationID]?.barrierWaiters.removeValue(forKey: barrierID) else {
                piHistoryStreamFailed(operationID: operationID, sessionID: sessionID); return
            }
            waiter.resume()
        case .sessionApproval, .sessionApprovalDismissed:
            do {
                let receipt = try await enqueue(.conversationHistoryPiControlEvent(operationID: operationID,
                    sessionID: sessionID, event: event, incarnation: job.incarnation))
                if receipt.rejection != nil { piHistoryStreamFailed(operationID: operationID, sessionID: sessionID) }
            } catch { piHistoryStreamFailed(operationID: operationID, sessionID: sessionID) }
        case .thread, .steeringCapabilitiesChanged, .configuration: break // Never adopt a native ID from a history worker event.
        default: piHistoryStreamFailed(operationID: operationID, sessionID: sessionID)
        }
    }
    private func piHistoryStreamFailed(operationID: UUID, sessionID: UUID) {
        guard let job = piHistoryJobs[operationID], job.id == sessionID, !job.closing else { return }
        piHistoryJobs[operationID]?.streamFailed = true
        _ = beginPiHistoryClose(operationID)
    }
    private func beginPiHistoryClose(_ operationID: UUID) -> Task<Void, Never>? {
        guard let job = piHistoryJobs[operationID] else { return nil }
        if let close = job.closeTask { return close }
        piHistoryJobs[operationID]?.closing = true
        job.operation?.cancel(); for response in job.responses.values { response.cancel() }
        for request in job.barrierRequests.values { request.cancel() }
        let waiters = job.barrierWaiters
        piHistoryJobs[operationID]?.barrierWaiters = [:]
        for waiter in waiters.values { waiter.resume(throwing: CancellationError()) }
        let reusedSource: Runtime?
        if let id = job.reusedRuntimeID, runtimes[job.threadID]?.id == id { reusedSource = runtimes.removeValue(forKey: job.threadID) }
        else { reusedSource = nil }
        let failedSource: Runtime?
        if job.streamFailed, let id = job.sourceRuntimeID, id != job.reusedRuntimeID, runtimes[job.threadID]?.id == id {
            failedSource = runtimes.removeValue(forKey: job.threadID)
        } else { failedSource = nil }
        let registry = mcpRegistry
        let close = Task {
            for scope in [reusedSource?.mcpScope, failedSource?.mcpScope].compactMap({ $0 }) { await registry.revoke(sessionID: scope.sessionID) }
            await job.session.close()
            if let failedSource { await failedSource.session.close(); failedSource.reader?.cancel(); await failedSource.reader?.value }
            job.reader?.cancel(); await job.reader?.value
            if let operation = job.operation { _ = await operation.result }
            for response in job.responses.values { _ = await response.result }
            for request in job.barrierRequests.values { await request.value }
        }
        piHistoryJobs[operationID]?.closeTask = close
        return close
    }
    private func finishPiHistoryJob(_ operationID: UUID, sessionID: UUID, preservingReusedRuntime: Bool = false) async {
        if preservingReusedRuntime, let job = piHistoryJobs[operationID], job.id == sessionID {
            // The source's single reader remains attached. Only this history
            // job's already settled tasks are joined; canceling that reader
            // would terminate AsyncStream and lose the original live leaf.
            if let operation = job.operation { _ = await operation.result }
            for response in job.responses.values { _ = await response.result }
            for request in job.barrierRequests.values { await request.value }
        } else if let close = beginPiHistoryClose(operationID) { await close.value }
        guard let job = piHistoryJobs[operationID], job.id == sessionID else { return }
        if !closing, fatalError == nil {
            _ = try? await enqueue(.conversationHistoryPiControlsClosed(operationID: operationID, sessionID: sessionID, incarnation: job.incarnation))
        }
        piHistoryJobs.removeValue(forKey: operationID)
    }

    private func performPiConversationHistory(operation: ConversationHistoryOperation, thread: CodingThread,
                                               incarnation: UUID) async -> EffectResult {
        let review = operation.review
        guard let evidence = review.pi, piHistoryJobs[operation.id] == nil, piHistoryScopeIsolated(thread: thread) else {
            return .failed(ConversationHistoryOperation.failureMessage)
        }
        if let files = review.files {
            do {
                try revision.snapshot.validateConversationHistoryFilesReview(review, excludingOperationID: operation.id)
                guard restoreRuntimeScopeIsolated(thread: thread, path: files.gitReview.currentPlan.repositoryPath),
                      try await readCheckpointRestore(thread: thread, operation: { try await $0.inspectRestore(review: files.gitReview) }) == .notStarted else { throw ProviderHistoryError(.notIdle) }
            } catch { return .failed(ConversationHistoryOperation.failureMessage) }
        }
        var dispatched = false
        var jobID: UUID?
        var preserveSource = false
        var preservedRuntimeID: UUID?
        var result: EffectResult
        do {
            try Task.checkCancellation()
            let dispatch = try await enqueue(.conversationHistoryDispatching(threadID: thread.id, operationID: operation.id, incarnation: incarnation))
            guard dispatch.rejection == nil, ownsHistorySource(threadID: thread.id, incarnation: incarnation, fingerprint: review.sourceFingerprint),
                  revision.snapshot.conversationHistoryOperation(operation.id)?.phase == .dispatching,
                  piHistoryScopeIsolated(thread: thread) else { throw ProviderHistoryError(.historyChanged) }
            let session: any ProviderSession, reused: UUID?, reader: Task<Void, Never>?
            if review.kind == .rewindBeforeRun, let attached = runtimes[thread.id], attached.id == thread.runtimeID,
               attached.provider == .pi, attached.path == thread.workspacePath,
               attached.piBinding == ProviderConfiguration(thread: thread).piRuntimeBinding {
                session = attached.session; reused = attached.id; reader = attached.reader
            } else {
                var configured = thread
                configured.activeRun = nil; configured.runtimeID = nil; configured.runtimeRequests = []; configured.state = .idle
                if review.kind == .forkAfterRun {
                    guard let project = revision.snapshot.projects.first(where: { $0.id == thread.projectID }), let target = review.targetThreadID else { throw CancellationError() }
                    configured = CodingThread(project: project, model: review.targetConfiguration.model)
                    configured.id = target; configured.provider = .pi; configured.workspacePath = review.targetConfiguration.workspacePath
                    configured.permission = review.targetConfiguration.permission; configured.piConfiguration = review.targetConfiguration.piConfiguration
                }
                session = try factory(configured); reused = nil; reader = nil
            }
            let id = UUID(); jobID = id
            let sourceRuntime = runtimes[thread.id].flatMap { attached in
                attached.provider == .pi && attached.piBinding == ProviderConfiguration(thread: thread).piRuntimeBinding ? attached.id : nil
            }
            piHistoryJobs[operation.id] = .init(id: id, threadID: thread.id, projectID: thread.projectID,
                incarnation: incarnation, session: session, reusedRuntimeID: reused, sourceRuntimeID: sourceRuntime, reader: reader)
            let opened = try await enqueue(.conversationHistoryPiControlsOpened(operationID: operation.id, sessionID: id, incarnation: incarnation))
            guard opened.rejection == nil, ownsHistorySource(threadID: thread.id, incarnation: incarnation, fingerprint: review.sourceFingerprint),
                  piHistoryJobs[operation.id]?.closing == false else { throw CancellationError() }
            if reused == nil {
                let stream = session.events
                piHistoryJobs[operation.id]?.reader = Task { [weak self] in
                    for await event in stream {
                        guard let self else { return }
                        await self.receivePiHistoryEvent(operationID: operation.id, sessionID: id, event: event)
                    }
                    await self?.piHistoryStreamFailed(operationID: operation.id, sessionID: id)
                }
            }
            if review.kind == .forkAfterRun { try await verifyPiHistorySourceRuntime(operationID: operation.id, sessionID: id, expected: evidence.source) }
            try Task.checkCancellation(); dispatched = true
            let configuration = review.kind == .rewindBeforeRun ? review.sourceConfiguration : review.targetConfiguration
            let native = Task { [weak self] in
                guard let self else { throw CancellationError() }
                return try await session.applyPiHistory(review: evidence, configuration: configuration, operationID: operation.id) { candidate in
                    try await self.publishPiHistoryCandidate(candidate, review: review, sessionID: id, incarnation: incarnation)
                }
            }
            piHistoryJobs[operation.id]?.operation = native
            let observed = try await withTaskCancellationHandler { try await native.value } onCancel: {
                native.cancel(); Task { [weak self] in _ = await self?.beginPiHistoryClose(operation.id) }
            }
            if review.kind == .forkAfterRun { try await verifyPiHistorySourceRuntime(operationID: operation.id, sessionID: id, expected: evidence.source) }
            try await flushPiHistoryEvents(operationID: operation.id, sessionID: id)
            try Task.checkCancellation(); try review.validateResult(observed)
            guard ownsHistorySource(threadID: thread.id, incarnation: incarnation, fingerprint: review.sourceFingerprint),
                  let job = piHistoryJobs[operation.id], job.id == id, !job.closing, !job.streamFailed,
                  let current = revision.snapshot.conversationHistoryOperation(operation.id), current.phase == .dispatching,
                  (current.piCandidates ?? []) == (observed.pi?.candidates ?? []), piHistoryScopeIsolated(thread: thread) else {
                throw ProviderHistoryError(.outcomeUncertain)
            }
            result = .conversationHistoryConfirmed(observed)
        } catch {
            let knownNativeWrite = revision.snapshot.conversationHistoryOperation(operation.id)?.piCandidates?.contains(where: { $0.nativeSessionFile != nil }) == true
            if dispatched, knownNativeWrite || error is CancellationError || (error as? ProviderHistoryError)?.kind == .outcomeUncertain || !(error is ProviderHistoryError) {
                result = .conversationHistoryUnconfirmed
            } else { result = .failed(ConversationHistoryOperation.failureMessage) }
        }
        if let jobID, let job = piHistoryJobs[operation.id], job.id == jobID, job.reusedRuntimeID != nil,
           !job.closing, !job.streamFailed, (revision.snapshot.conversationHistoryOperation(operation.id)?.piCandidates ?? []).isEmpty {
            let conclusiveUnchanged: Bool
            if case .failed = result { conclusiveUnchanged = true }
            else if case .conversationHistoryConfirmed(let observed) = result { conclusiveUnchanged = observed.pi?.source == observed.pi?.snapshot }
            else { conclusiveUnchanged = false }
            if conclusiveUnchanged {
                do {
                    let unchanged = try await job.session.piHistorySnapshot(threadID: evidence.source.reference.nativeThreadID)
                    guard unchanged == evidence.source else { throw ProviderHistoryError(.historyChanged) }
                    try await flushPiHistoryEvents(operationID: operation.id, sessionID: jobID)
                    guard let current = piHistoryJobs[operation.id], !current.closing, !current.streamFailed,
                          runtimes[thread.id]?.id == job.reusedRuntimeID else { throw ProviderHistoryError(.historyChanged) }
                    preserveSource = true
                    preservedRuntimeID = job.reusedRuntimeID
                } catch { result = .conversationHistoryUnconfirmed }
            }
        }
        if let jobID { await finishPiHistoryJob(operation.id, sessionID: jobID, preservingReusedRuntime: preserveSource) }
        if case .conversationHistoryConfirmed(let observed) = result, let proof = observed.pi {
            // Shutdown hooks can append native records. Do not publish an
            // earlier revision after our own exact process has drained.
            do {
                let retainedLiveSource = preserveSource
                _ = try await readPiFiles(thread: thread) { service in
                    _ = try service.graph(expected: evidence.source)
                    if retainedLiveSource { _ = try service.graph(expected: proof.snapshot); return proof.snapshot }
                    return try service.inspectOriginal(expected: proof.snapshot)
                }
                guard ownsHistorySource(threadID: thread.id, incarnation: incarnation, fingerprint: review.sourceFingerprint),
                      revision.snapshot.conversationHistoryOperation(operation.id)?.phase == .dispatching else {
                    throw ProviderHistoryError(.outcomeUncertain)
                }
            } catch {
                result = .conversationHistoryUnconfirmed
                if let preservedRuntimeID { await closeRuntime(thread.id, matching: preservedRuntimeID) }
            }
        }
        return result
    }
    private func publishPiHistoryCandidate(_ candidate: PiHistoryCandidate, review: ConversationHistoryReview,
                                          sessionID: UUID, incarnation: UUID) async throws {
        guard let evidence = review.pi, ownsHistorySource(threadID: review.sourceThreadID, incarnation: incarnation, fingerprint: review.sourceFingerprint),
              let job = piHistoryJobs[review.id], job.id == sessionID, !job.closing, !job.streamFailed,
              let operation = revision.snapshot.conversationHistoryOperation(review.id), operation.review == review, operation.phase == .dispatching,
              let thread = revision.snapshot.threads.first(where: { $0.id == review.sourceThreadID }),
              piHistoryScopeIsolated(thread: thread, additionalNativeFiles: candidate.nativeSessionFile.map { [$0] } ?? []) else {
            throw ProviderHistoryError(.outcomeUncertain)
        }
        try evidence.validateCandidate(candidate, previous: operation.piCandidates ?? [])
        let receipt = try await enqueue(.conversationHistoryPiCandidateObserved(operationID: review.id, candidate: candidate, incarnation: incarnation))
        guard receipt.rejection == nil, ownsHistorySource(threadID: review.sourceThreadID, incarnation: incarnation, fingerprint: review.sourceFingerprint),
              piHistoryJobs[review.id]?.id == sessionID, piHistoryJobs[review.id]?.closing == false,
              let saved = revision.snapshot.conversationHistoryOperation(review.id), saved.phase == .dispatching,
              saved.piCandidates?.last == candidate,
              piHistoryScopeIsolated(thread: thread, additionalNativeFiles: candidate.nativeSessionFile.map { [$0] } ?? []) else {
            throw ProviderHistoryError(.outcomeUncertain)
        }
    }

    private func verifyPiHistorySourceRuntime(operationID: UUID, sessionID: UUID, expected: PiHistorySnapshot) async throws {
        guard let job = piHistoryJobs[operationID], job.id == sessionID, !job.closing else { throw ProviderHistoryError(.outcomeUncertain) }
        guard let sourceID = job.sourceRuntimeID else { return }
        guard let source = runtimes[job.threadID], source.id == sourceID else { throw ProviderHistoryError(.outcomeUncertain) }
        let observed = try await source.session.piHistorySnapshot(threadID: expected.reference.nativeThreadID)
        guard observed == expected, piHistoryJobs[operationID]?.closing == false else { throw ProviderHistoryError(.historyChanged) }
        try await flushPiHistoryEvents(operationID: operationID, sessionID: sessionID, emitter: source.session)
    }
    private func flushPiHistoryEvents(operationID: UUID, sessionID: UUID, emitter: (any ProviderSession)? = nil) async throws {
        try Task.checkCancellation()
        let token = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                guard let job = piHistoryJobs[operationID], job.id == sessionID, !job.closing, !job.streamFailed else {
                    continuation.resume(throwing: ProviderHistoryError(.outcomeUncertain)); return
                }
                piHistoryJobs[operationID]?.barrierWaiters[token] = continuation
                let session = emitter ?? job.session
                piHistoryJobs[operationID]?.barrierRequests[token] = Task { [weak self] in
                    do { try await session.piHistoryEventBarrier(token) }
                    catch { await self?.piHistoryBarrierFailed(operationID: operationID, sessionID: sessionID, token: token) }
                }
            }
        } onCancel: { Task { [weak self] in _ = await self?.beginPiHistoryClose(operationID) } }
        if let emitter = piHistoryJobs[operationID]?.barrierRequests.removeValue(forKey: token) { await emitter.value }
        try Task.checkCancellation()
        guard let job = piHistoryJobs[operationID], job.id == sessionID, !job.closing, !job.streamFailed else {
            throw ProviderHistoryError(.outcomeUncertain)
        }
    }
    private func piHistoryBarrierFailed(operationID: UUID, sessionID: UUID, token: UUID) {
        guard piHistoryJobs[operationID]?.id == sessionID else { return }
        piHistoryJobs[operationID]?.barrierWaiters.removeValue(forKey: token)?.resume(throwing: ProviderHistoryError(.outcomeUncertain))
        piHistoryStreamFailed(operationID: operationID, sessionID: sessionID)
    }

    @discardableResult public func respondPiHistory(operationID: UUID, sessionID: UUID, requestID: JSONValue,
                                                    response: ProviderApprovalResponse) async throws -> WorkspaceCommandReceipt {
        _ = try await load(); try Task.checkCancellation()
        guard !closing, !stoppingEffects, fatalError == nil, let job = piHistoryJobs[operationID], job.id == sessionID,
              !job.closing, !job.streamFailed, let operation = revision.snapshot.conversationHistoryOperation(operationID),
              operation.phase == .dispatching, operation.piControls?.sessionID == sessionID,
              let request = operation.piControls?.requests.first(where: { $0.id == requestID && !$0.responding })?.request,
              ownsHistorySource(threadID: job.threadID, incarnation: job.incarnation, fingerprint: operation.review.sourceFingerprint) else {
            throw WorkspaceCommandError("This Pi lifecycle request belongs to an expired history worker.")
        }
        let receipt = try await enqueue(.conversationHistoryPiControlResponding(operationID: operationID, sessionID: sessionID,
            requestID: requestID, response: response, incarnation: job.incarnation))
        if let rejection = receipt.rejection { throw WorkspaceCommandError(rejection) }
        guard piHistoryJobs[operationID]?.id == sessionID, piHistoryJobs[operationID]?.closing == false,
              revision.snapshot.conversationHistoryOperation(operationID)?.piControls?.requests.contains(where: { $0.id == requestID && $0.responding }) == true else {
            throw WorkspaceCommandError("The Pi lifecycle request changed before its response was sent.")
        }
        let token = UUID(), session = job.session
        let task = Task<Void, any Error> {
            try Task.checkCancellation()
            switch response {
            case .decision(let allow): try await session.respond(request, allow: allow)
            case .option(let option): try await session.choose(request, optionID: option)
            case .answers(let answers): try await session.answer(request, answers: answers)
            case .selections, .selectionsWithNotes: throw ProviderHistoryError(.invalidRequest)
            }
        }
        piHistoryJobs[operationID]?.responses[token] = task
        do {
            try await withTaskCancellationHandler { try await task.value } onCancel: {
                task.cancel(); Task { [weak self] in _ = await self?.beginPiHistoryClose(operationID) }
            }
            if piHistoryJobs[operationID]?.id == sessionID { piHistoryJobs[operationID]?.responses.removeValue(forKey: token) }
            return receipt
        } catch {
            if piHistoryJobs[operationID]?.id == sessionID { piHistoryJobs[operationID]?.responses.removeValue(forKey: token) }
            piHistoryStreamFailed(operationID: operationID, sessionID: sessionID)
            if let close = beginPiHistoryClose(operationID) { await close.value }
            throw WorkspaceCommandError("The Pi lifecycle response could not be confirmed. It was not replayed.")
        }
    }
    @discardableResult public func cancelPiHistory(operationID: UUID) async throws -> WorkspaceCommandReceipt {
        _ = try await load(); try Task.checkCancellation()
        guard !closing, !stoppingEffects, fatalError == nil,
              let operation = revision.snapshot.conversationHistoryOperation(operationID), operation.review.pi != nil,
              operation.isPending, let incarnation = threadIncarnations[operation.review.sourceThreadID] else {
            throw WorkspaceCommandError("The Pi history action is no longer running.")
        }
        let receipt = try await enqueue(.conversationHistoryPiCancelled(operationID: operationID, incarnation: incarnation))
        if let rejection = receipt.rejection { throw WorkspaceCommandError(rejection) }
        effects[operationID]?.cancel()
        if let close = beginPiHistoryClose(operationID) { await close.value }
        if let effect = effects[operationID] { await effect.value }
        return receipt
    }
    private func reconcilePiHistory(operation: ConversationHistoryOperation, thread: CodingThread,
                                    incarnation: UUID) async throws -> WorkspaceCommandReceipt {
        guard let evidence = operation.review.pi, let candidate = operation.piCandidates?.last,
              candidate.stage != .reserved, piHistoryJobs[operation.id] == nil,
              piHistoryScopeIsolated(thread: thread, additionalNativeFiles: candidate.nativeSessionFile.map { [$0] } ?? []) else {
            throw ProviderHistoryError(.boundaryUnavailable)
        }
        let configuration = operation.review.kind == .rewindBeforeRun ? operation.review.sourceConfiguration : operation.review.targetConfiguration
        let observed = try await readHistory(thread: thread, forceOwnedMetadata: true) {
            try await $0.inspectPiHistoryCandidate(review: evidence, candidate: candidate, configuration: configuration)
        }
        try operation.review.validateResult(observed)
        guard observed.pi?.candidates == operation.piCandidates,
              ownsHistorySource(threadID: thread.id, incarnation: incarnation, fingerprint: operation.review.sourceFingerprint),
              revision.snapshot.conversationHistoryOperation(operation.id) == operation,
              piHistoryScopeIsolated(thread: thread, additionalNativeFiles: candidate.nativeSessionFile.map { [$0] } ?? []) else {
            throw ProviderHistoryError(.historyChanged)
        }
        if let runtime = runtimes[thread.id] { await closeRuntime(thread.id, matching: runtime.id) }
        guard ownsHistorySource(threadID: thread.id, incarnation: incarnation, fingerprint: operation.review.sourceFingerprint),
              revision.snapshot.conversationHistoryOperation(operation.id) == operation else { throw ProviderHistoryError(.historyChanged) }
        let receipt = try await enqueue(.conversationHistoryReconciled(operationID: operation.id, incarnation: incarnation, result: .applied(observed)))
        if let rejection = receipt.rejection { throw WorkspaceCommandError(rejection) }
        return receipt
    }
    public func inspectPiOriginal(operationID: UUID) async throws -> PiHistorySnapshot {
        _ = try await load(); try Task.checkCancellation()
        guard !closing, !stoppingEffects, fatalError == nil,
              let operation = revision.snapshot.conversationHistoryOperation(operationID), operation.phase == .unconfirmed,
              let proof = operation.review.pi, piHistoryJobs[operationID] == nil,
              let thread = revision.snapshot.threads.first(where: { $0.id == operation.review.sourceThreadID }),
              let incarnation = threadIncarnations[thread.id], !thread.isBusy, thread.queuedTurns.isEmpty,
              ownsHistorySource(threadID: thread.id, incarnation: incarnation, fingerprint: operation.review.sourceFingerprint),
              piHistoryScopeIsolated(thread: thread) else { throw ProviderHistoryError(.historyChanged) }
        let observed = try await readPiFiles(thread: thread) { try $0.inspectOriginal(expected: proof.source) }
        guard observed == proof.source, revision.snapshot.conversationHistoryOperation(operationID) == operation,
              ownsHistorySource(threadID: thread.id, incarnation: incarnation, fingerprint: operation.review.sourceFingerprint) else {
            throw ProviderHistoryError(.historyChanged)
        }
        return observed
    }
    @discardableResult public func keepPiOriginal(operationID: UUID, expected: PiHistorySnapshot) async throws -> WorkspaceCommandReceipt {
        try expected.validate()
        let observed = try await inspectPiOriginal(operationID: operationID)
        guard observed == expected, let operation = revision.snapshot.conversationHistoryOperation(operationID), operation.phase == .unconfirmed,
              let incarnation = threadIncarnations[operation.review.sourceThreadID], piHistoryJobs[operationID] == nil else {
            throw ProviderHistoryError(.historyChanged)
        }
        let receipt = try await enqueue(.conversationHistoryReconciled(operationID: operationID, incarnation: incarnation,
            result: .piOriginalKept(observed)))
        if let rejection = receipt.rejection { throw WorkspaceCommandError(rejection) }
        if let files = operation.review.files {
            await discardCheckpointRestoreScratch(files.gitReview, threadID: operation.review.sourceThreadID, projectID: operation.review.projectID)
        }
        return receipt
    }

    public func inspectPiFreshSession(threadID: UUID) async throws -> PiFreshSessionInspection {
        _ = try await load(); try Task.checkCancellation()
        guard !closing, !stoppingEffects, fatalError == nil,
              revision.snapshot.piFreshSessionNeedsInspection(threadID: threadID),
              let thread = revision.snapshot.threads.first(where: { $0.id == threadID }),
              let intent = thread.piFreshSessionIntent, let consumer = thread.piFreshConsumerRunID,
              let incarnation = threadIncarnations[threadID],
              let record = thread.runHistory?.first(where: { $0.id == consumer }),
              !revision.snapshot.isConversationHistoryLocked(threadID: threadID), piHistoryScopeIsolated(thread: thread) else {
            throw WorkspaceCommandError("The Pi empty-context attempt is no longer available for inspection.")
        }
        // Absence is meaningful only after the exact owned process has drained.
        if let runtime = runtimes[threadID] { await closeRuntime(threadID, matching: runtime.id) }
        for id in metadataSessions.keys.filter({ metadataSessions[$0]?.threadID == threadID }) {
            if let close = beginMetadataClose(id) { await close.value }
            metadataSessions.removeValue(forKey: id)
        }
        guard piFreshOwnerMatches(threadID: threadID, incarnation: incarnation, intent: intent, consumer: consumer),
              piHistoryScopeIsolated(thread: thread) else { throw ProviderHistoryError(.historyChanged) }
        let inspection = try await readPiFiles(thread: thread) { service in
            try service.inspectFresh(intent: intent, consumer: record.pi)
        }
        guard piFreshOwnerMatches(threadID: threadID, incarnation: incarnation, intent: intent, consumer: consumer),
              revision.snapshot.threads.first(where: { $0.id == threadID })?.runHistory?.first(where: { $0.id == consumer }) == record else {
            throw ProviderHistoryError(.historyChanged)
        }
        return inspection
    }
    private func piFreshOwnerMatches(threadID: UUID, incarnation: UUID, intent: PiFreshSessionIntent, consumer: UUID) -> Bool {
        !closing && !stoppingEffects && fatalError == nil && threadIncarnations[threadID] == incarnation &&
        revision.snapshot.piFreshSessionNeedsInspection(threadID: threadID) &&
        revision.snapshot.threads.first(where: { $0.id == threadID }).map {
            $0.piFreshSessionIntent == intent && $0.piFreshConsumerRunID == consumer && !$0.isBusy
        } == true
    }
    @discardableResult public func acknowledgeUnwrittenPiFreshSession(threadID: UUID, expectedIntentID: UUID,
                                                                     expectedConsumerRunID: UUID) async throws -> WorkspaceCommandReceipt {
        _ = try await load()
        guard let thread = revision.snapshot.threads.first(where: { $0.id == threadID }),
              let intent = thread.piFreshSessionIntent, intent.id == expectedIntentID,
              thread.piFreshConsumerRunID == expectedConsumerRunID, let incarnation = threadIncarnations[threadID] else {
            throw ProviderHistoryError(.historyChanged)
        }
        guard try await inspectPiFreshSession(threadID: threadID) == .unwritten,
              piFreshOwnerMatches(threadID: threadID, incarnation: incarnation, intent: intent, consumer: expectedConsumerRunID) else {
            throw ProviderHistoryError(.historyChanged)
        }
        let receipt = try await enqueue(.piFreshSessionResolved(threadID: threadID, incarnation: incarnation,
            intent: intent, consumerRunID: expectedConsumerRunID, inspection: .unwritten))
        if let rejection = receipt.rejection { throw WorkspaceCommandError(rejection) }
        return receipt
    }
    @discardableResult public func confirmPersistedPiFreshSession(threadID: UUID, expected: PiHistoryFileRevision) async throws -> WorkspaceCommandReceipt {
        try expected.validate(); _ = try await load()
        guard let thread = revision.snapshot.threads.first(where: { $0.id == threadID }),
              let intent = thread.piFreshSessionIntent, let consumer = thread.piFreshConsumerRunID,
              let incarnation = threadIncarnations[threadID] else { throw ProviderHistoryError(.historyChanged) }
        guard try await inspectPiFreshSession(threadID: threadID) == .persisted(expected),
              piFreshOwnerMatches(threadID: threadID, incarnation: incarnation, intent: intent, consumer: consumer) else {
            throw ProviderHistoryError(.historyChanged)
        }
        let receipt = try await enqueue(.piFreshSessionResolved(threadID: threadID, incarnation: incarnation,
            intent: intent, consumerRunID: consumer, inspection: .persisted(expected)))
        if let rejection = receipt.rejection { throw WorkspaceCommandError(rejection) }
        return receipt
    }
}

extension WorkspaceEngine {
    private func openCodeHistoryScopeOwnedElsewhere(thread: CodingThread) -> Bool {
        guard let nativeID = thread.providerThreadID, let identity = thread.openCodeConfiguration?.runtimeIdentity else { return false }
        return (revision.snapshot.conversationHistoryOperations ?? []).contains { operation in
            guard operation.review.sourceThreadID != thread.id,
                  (operation.review.openCodeV1?.source.runtimeIdentity ?? operation.review.openCodeV2?.source.runtimeIdentity) == identity else { return false }
            if operation.locksSource && operation.review.sourceReference.nativeThreadID == nativeID { return true }
            return operation.reservesOpenCodeV1Candidate && operation.openCodeV1Candidate?.reference.nativeThreadID == nativeID
        }
    }
    private func openCodeHistoryScopeIsolated(thread: CodingThread, additionalNativeIDs: Set<String> = []) -> Bool {
        guard thread.provider == .opencode, let identity = thread.openCodeConfiguration?.runtimeIdentity,
              let nativeID = thread.providerThreadID else { return false }
        var ids = additionalNativeIDs.union([nativeID])
        for operation in revision.snapshot.conversationHistoryOperations ?? [] where operation.locksSource && operation.review.sourceThreadID == thread.id {
            guard (operation.review.openCodeV1?.source.runtimeIdentity ?? operation.review.openCodeV2?.source.runtimeIdentity) == identity else { continue }
            ids.insert(operation.review.sourceReference.nativeThreadID)
            if let candidate = operation.openCodeV1Candidate { ids.insert(candidate.reference.nativeThreadID) }
        }
        // Native ownership is runtime-wide even when a stale header names a
        // different cwd. Exact workspace equality remains part of copy proof.
        let nativeIDs = ids
        func captured(_ configuration: ProviderConfiguration, native: String?) -> Bool {
            guard let value = native ?? configuration.nativeThreadID else { return false }
            return configuration.provider == .opencode && configuration.openCodeConfiguration?.runtimeIdentity == identity &&
                nativeIDs.contains(value)
        }
        for other in revision.snapshot.threads where other.id != thread.id {
            if captured(.init(thread: other), native: other.providerThreadID) { return false }
            if let run = other.activeRun, captured(run.configuration,
                native: run.configuration.nativeThreadID ?? other.runHistory?.first(where: { $0.id == run.id })?.providerThreadID) { return false }
            if other.queuedTurns.contains(where: { captured($0.configuration, native: $0.configuration.nativeThreadID) }) { return false }
        }
        if let runtime = runtimes[thread.id], runtime.provider != thread.provider || runtime.path != thread.workspacePath ||
            runtime.openCodeIdentity != identity || runtime.id != thread.runtimeID { return false }
        if metadataSessions.values.contains(where: {
            $0.threadID != thread.id && (captured($0.launchConfiguration, native: $0.launchConfiguration.nativeThreadID) ||
                $0.configuration.map { captured($0, native: $0.nativeThreadID) } == true)
        }) { return false }
        if historyReads.values.contains(where: {
            $0.threadID != thread.id && captured($0.configuration, native: $0.configuration.nativeThreadID)
        }) { return false }
        // A detached owner has lost its thread/header reference. Wait for its
        // exact recorded cleanup rather than infer a different native session.
        return !cleanupTasks.values.contains { cleanup in
            cleanup.workspacePaths.contains {
                WorkspaceSnapshot.checkpointRestorePathsOverlap($0, thread.workspacePath)
            }
        }
    }

    /// Wait for known owned closes before opening another observer of the same
    /// checkout. A mismatched retained actor is drained, never reused by path.
    private func drainOpenCodeHistoryCleanup(thread: CodingThread) async throws {
        guard thread.provider == .opencode else { return }
        if let runtime = runtimes[thread.id], runtime.provider != thread.provider || runtime.path != thread.workspacePath ||
            runtime.openCodeIdentity != thread.openCodeConfiguration?.runtimeIdentity || runtime.id != thread.runtimeID {
            await closeRuntime(thread.id, matching: runtime.id)
        }
        while true {
            try Task.checkCancellation()
            guard !closing, !stoppingEffects, fatalError == nil else { throw CancellationError() }
            let tasks = cleanupTasks.values.filter { cleanup in
                cleanup.workspacePaths.contains { WorkspaceSnapshot.checkpointRestorePathsOverlap($0, thread.workspacePath) }
            }.map(\.task)
            guard !tasks.isEmpty else { return }
            for task in tasks { await task.value }
        }
    }

    private func observedOpenCodeHistory(_ observed: OpenCodeV2HistorySnapshot,
                                         operation: ConversationHistoryOperation) throws -> OpenCodeV2HistorySnapshot {
        try observed.validate()
        for attempt in (operation.previousMaintenanceAttempts ?? []) + (operation.maintenance.map { [$0] } ?? []) {
            guard let result = attempt.result else { continue }
            try attempt.validate()
            if observed.reference == result.reference, observed.runtimeIdentity == result.runtimeIdentity,
               observed.workspacePath == result.workspacePath, observed.messages == result.messages,
               observed.stage == result.stage, observed.fork == result.fork { return result }
        }
        return observed
    }

    private func reconcileOpenCodeV1History(operation: ConversationHistoryOperation, thread: CodingThread,
                                            incarnation: UUID) async throws -> WorkspaceCommandReceipt {
        let review = operation.review
        guard let evidence = review.openCodeV1, let candidate = operation.openCodeV1Candidate else {
            throw ProviderHistoryError(.boundaryUnavailable)
        }
        try evidence.validateCandidate(candidate)
        try await drainOpenCodeHistoryCleanup(thread: thread)
        guard ownsHistorySource(threadID: thread.id, incarnation: incarnation, fingerprint: review.sourceFingerprint),
              revision.snapshot.conversationHistoryOperation(operation.id) == operation,
              openCodeHistoryScopeIsolated(thread: thread, additionalNativeIDs: [candidate.reference.nativeThreadID]) else {
            throw ProviderHistoryError(.historyChanged)
        }
        let oldRuntimeID = runtimes[thread.id]?.id
        // A candidate is an exact acknowledged ID, not native ancestry. This
        // method must prove both source and copy plus installed policy by reads;
        // it cannot finish missing configuration or repeat the native fork.
        let observed = try await readHistory(thread: thread, forceOwnedMetadata: true) { session in
            try await session.inspectOpenCodeV1HistoryCandidate(review: evidence, candidate: candidate, configuration: review.sourceConfiguration)
        }
        try review.validateResult(observed)
        guard observed.reference == candidate.reference,
              ownsHistorySource(threadID: thread.id, incarnation: incarnation, fingerprint: review.sourceFingerprint),
              revision.snapshot.conversationHistoryOperation(operation.id) == operation,
              openCodeHistoryScopeIsolated(thread: thread, additionalNativeIDs: [candidate.reference.nativeThreadID]) else {
            throw ProviderHistoryError(.historyChanged)
        }
        if let oldRuntimeID { await closeRuntime(thread.id, matching: oldRuntimeID) }
        guard ownsHistorySource(threadID: thread.id, incarnation: incarnation, fingerprint: review.sourceFingerprint),
              revision.snapshot.conversationHistoryOperation(operation.id) == operation,
              openCodeHistoryScopeIsolated(thread: thread, additionalNativeIDs: [candidate.reference.nativeThreadID]) else {
            throw ProviderHistoryError(.historyChanged)
        }
        let receipt = try await enqueue(.conversationHistoryReconciled(operationID: operation.id, incarnation: incarnation, result: .applied(observed)))
        if let rejection = receipt.rejection { throw WorkspaceCommandError(rejection) }
        return receipt
    }

    /// Inspect only the exact original native session. An unknown fork may
    /// remain elsewhere; neither enumeration nor a guessed ID is recovery proof.
    public func inspectOpenCodeV1Original(operationID: UUID) async throws -> OpenCodeV1HistorySnapshot {
        _ = try await load(); try Task.checkCancellation()
        guard !closing, !stoppingEffects, fatalError == nil,
              let operation = revision.snapshot.conversationHistoryOperation(operationID), operation.phase == .unconfirmed,
              operation.review.kind == .rewindBeforeRun, let evidence = operation.review.openCodeV1,
              let thread = revision.snapshot.threads.first(where: { $0.id == operation.review.sourceThreadID }),
              let incarnation = threadIncarnations[thread.id], !thread.isBusy, thread.queuedTurns.isEmpty, thread.runtimeRequests.isEmpty,
              ownsHistorySource(threadID: thread.id, incarnation: incarnation, fingerprint: operation.review.sourceFingerprint) else {
            throw ProviderHistoryError(.historyChanged)
        }
        try await drainOpenCodeHistoryCleanup(thread: thread)
        guard revision.snapshot.conversationHistoryOperation(operationID) == operation,
              ownsHistorySource(threadID: thread.id, incarnation: incarnation, fingerprint: operation.review.sourceFingerprint),
              openCodeHistoryScopeIsolated(thread: thread) else { throw ProviderHistoryError(.historyChanged) }
        let observed = try await readHistory(thread: thread, forceOwnedMetadata: true) {
            try await $0.openCodeV1HistorySnapshot(threadID: evidence.source.reference.nativeThreadID)
        }
        try observed.validate()
        guard observed == evidence.source,
              ownsHistorySource(threadID: thread.id, incarnation: incarnation, fingerprint: operation.review.sourceFingerprint),
              revision.snapshot.conversationHistoryOperation(operationID) == operation,
              openCodeHistoryScopeIsolated(thread: thread) else { throw ProviderHistoryError(.historyChanged) }
        return observed
    }

    /// Explicitly keep the re-proved original; this changes only the durable
    /// local resolution and preserves every possible native orphan/candidate.
    @discardableResult public func keepOpenCodeV1Original(operationID: UUID,
        expected: OpenCodeV1HistorySnapshot) async throws -> WorkspaceCommandReceipt {
        try expected.validate()
        let observed = try await inspectOpenCodeV1Original(operationID: operationID)
        guard observed == expected, let operation = revision.snapshot.conversationHistoryOperation(operationID),
              operation.phase == .unconfirmed, let thread = revision.snapshot.threads.first(where: { $0.id == operation.review.sourceThreadID }),
              let incarnation = threadIncarnations[thread.id],
              ownsHistorySource(threadID: thread.id, incarnation: incarnation, fingerprint: operation.review.sourceFingerprint),
              openCodeHistoryScopeIsolated(thread: thread) else { throw ProviderHistoryError(.historyChanged) }
        let receipt = try await enqueue(.conversationHistoryReconciled(operationID: operationID, incarnation: incarnation,
            result: .openCodeV1NotAdopted(observed)))
        if let rejection = receipt.rejection { throw WorkspaceCommandError(rejection) }
        if let files = operation.review.files {
            await discardCheckpointRestoreScratch(files.gitReview, threadID: thread.id, projectID: thread.projectID)
        }
        return receipt
    }

    private func reconcileOpenCodeV2History(operation: ConversationHistoryOperation, thread: CodingThread,
                                            incarnation: UUID) async throws -> WorkspaceCommandReceipt {
        let review = operation.review
        guard let evidence = review.openCodeV2, openCodeHistoryScopeIsolated(thread: thread),
              operation.maintenance?.phase.isWorking != true else { throw ProviderHistoryError(.notIdle) }
        let fresh = try await readHistory(thread: thread) { try await $0.openCodeV2HistorySnapshot(threadID: review.sourceReference.nativeThreadID) }
        guard ownsHistorySource(threadID: thread.id, incarnation: incarnation, fingerprint: review.sourceFingerprint),
              revision.snapshot.conversationHistoryOperation(operation.id) == operation,
              openCodeHistoryScopeIsolated(thread: thread) else { throw ProviderHistoryError(.historyChanged) }
        let observed = try observedOpenCodeHistory(fresh, operation: operation)
        guard observed.stage == nil, observed.reference == evidence.source.reference,
              observed.runtimeIdentity == evidence.source.runtimeIdentity, observed.workspacePath == evidence.source.workspacePath,
              observed.messages.allSatisfy(\.isSettled) else { throw ProviderHistoryError(.historyChanged) }
        let original: Bool
        if let maintenance = observed.maintenance {
            original = maintenance.priorInventoryDigest == evidence.source.inventoryDigest &&
                Array(observed.messages.dropLast()) == evidence.source.messages
        } else { original = observed.messages == evidence.source.messages }
        let result: ConversationHistoryReconciliation
        if original { result = .openCodeV2Unchanged(observed) }
        else {
            let provider = try ProviderConversationSnapshot(reference: observed.reference, workspacePath: observed.workspacePath,
                historyMode: .messageOrdered, openCodeV2: observed)
            try review.validateResult(provider); result = .applied(provider)
        }
        let receipt = try await enqueue(.conversationHistoryReconciled(operationID: operation.id, incarnation: incarnation, result: result))
        if let rejection = receipt.rejection { throw WorkspaceCommandError(rejection) }
        if original, let files = review.files {
            await discardCheckpointRestoreScratch(files.gitReview, threadID: thread.id, projectID: thread.projectID)
        }
        return receipt
    }

    public func inspectConversationHistoryMaintenance(operationID: UUID) async throws -> OpenCodeV2HistorySnapshot {
        _ = try await load(); try Task.checkCancellation()
        guard !closing, !stoppingEffects, fatalError == nil,
              let operation = revision.snapshot.conversationHistoryOperation(operationID), operation.phase == .unconfirmed,
              operation.review.kind == .rewindBeforeRun, let evidence = operation.review.openCodeV2,
              operation.maintenance?.phase.isWorking != true, operation.maintenance?.phase != .applied,
              let thread = revision.snapshot.threads.first(where: { $0.id == operation.review.sourceThreadID }),
              let incarnation = threadIncarnations[thread.id], !thread.isBusy, thread.queuedTurns.isEmpty,
              thread.runtimeRequests.isEmpty, openCodeHistoryScopeIsolated(thread: thread),
              try revision.snapshot.historySourceFingerprint(threadID: thread.id) == operation.review.sourceFingerprint else {
            throw ProviderHistoryError(.historyChanged)
        }
        let observed = try await readHistory(thread: thread) { try await $0.openCodeV2HistorySnapshot(threadID: evidence.source.reference.nativeThreadID) }
        guard ownsHistorySource(threadID: thread.id, incarnation: incarnation, fingerprint: operation.review.sourceFingerprint),
              revision.snapshot.conversationHistoryOperation(operationID) == operation,
              openCodeHistoryScopeIsolated(thread: thread) else { throw ProviderHistoryError(.historyChanged) }
        try evidence.validatesClear(observed)
        return observed
    }

    @discardableResult public func clearConversationHistoryMaintenance(operationID: UUID) async throws -> WorkspaceCommandReceipt {
        let expected = try await inspectConversationHistoryMaintenance(operationID: operationID)
        return try await clearConversationHistoryMaintenance(operationID: operationID, expected: expected)
    }

    @discardableResult public func clearConversationHistoryMaintenance(operationID: UUID,
        expected: OpenCodeV2HistorySnapshot) async throws -> WorkspaceCommandReceipt {
        let observed = try await inspectConversationHistoryMaintenance(operationID: operationID)
        guard observed == expected, let operation = revision.snapshot.conversationHistoryOperation(operationID),
              let incarnation = threadIncarnations[operation.review.sourceThreadID] else { throw ProviderHistoryError(.historyChanged) }
        let attempt = ConversationHistoryMaintenanceAttempt(expected: observed, sourceIncarnation: incarnation)
        let receipt = try await enqueue(.conversationHistoryMaintenanceAccepted(operationID: operationID, attempt: attempt, incarnation: incarnation), id: attempt.id)
        if let rejection = receipt.rejection { throw WorkspaceCommandError(rejection) }
        return receipt
    }

    private func performConversationHistoryMaintenance(_ request: WorkspaceEffectRequest) async -> EffectResult {
        guard case .conversationHistoryMaintenance(let threadID, let operationID, let attemptID) = request,
              let operation = revision.snapshot.conversationHistoryOperation(operationID), operation.phase == .unconfirmed,
              let attempt = operation.maintenance, attempt.id == attemptID, attempt.phase == .accepted,
              let incarnation = threadIncarnations[threadID], let thread = revision.snapshot.threads.first(where: { $0.id == threadID }),
              ownsHistorySource(threadID: threadID, incarnation: incarnation, fingerprint: operation.review.sourceFingerprint),
              openCodeHistoryScopeIsolated(thread: thread) else { return .cancelled }
        var dispatched = false
        do {
            let receipt = try await enqueue(.conversationHistoryMaintenanceDispatching(threadID: threadID, operationID: operationID,
                attemptID: attemptID, incarnation: incarnation))
            guard receipt.rejection == nil, revision.snapshot.conversationHistoryOperation(operationID)?.maintenance?.phase == .dispatching,
                  ownsHistorySource(threadID: threadID, incarnation: incarnation, fingerprint: operation.review.sourceFingerprint),
                  openCodeHistoryScopeIsolated(thread: thread) else { throw ProviderHistoryError(.historyChanged) }
            try Task.checkCancellation(); dispatched = true
            let result = try await readHistory(thread: thread) { try await $0.clearOpenCodeV2HistoryStage(expected: attempt.expected) }
            guard ownsHistorySource(threadID: threadID, incarnation: incarnation, fingerprint: operation.review.sourceFingerprint),
                  revision.snapshot.conversationHistoryOperation(operationID)?.maintenance?.id == attemptID else { throw CancellationError() }
            var checked = attempt; checked.phase = .applied; checked.result = result; try checked.validate()
            return .conversationHistoryMaintenanceConfirmed(result)
        } catch { return dispatched ? .conversationHistoryUnconfirmed : .failed(ConversationHistoryMaintenanceAttempt.failureMessage) }
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
            scriptRuntimes[runID] = .init(threadID: threadID, projectID: thread.projectID, path: plan.workspacePath, owner: owner,
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
        let configuration: ProviderConfiguration
    }
    private var historyReads: [UUID: HistoryRead] = [:]
    private struct PiHistoryJob: Sendable {
        let id: UUID
        let threadID: UUID
        let projectID: UUID
        let incarnation: UUID
        let session: any ProviderSession
        let reusedRuntimeID: UUID?
        let sourceRuntimeID: UUID?
        var reader: Task<Void, Never>?
        var operation: Task<ProviderConversationSnapshot, any Error>?
        var responses: [UUID: Task<Void, any Error>] = [:]
        var barrierWaiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
        var barrierRequests: [UUID: Task<Void, Never>] = [:]
        var closeTask: Task<Void, Never>?
        var streamFailed = false
        var closing = false
    }
    private var piHistoryJobs: [UUID: PiHistoryJob] = [:]
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
    public typealias PullRequestFactory = @Sendable (URL) throws -> any GitHubPullRequestSession
    private let pullRequestFactory: PullRequestFactory
    public typealias PullRequestCheckoutFactory = @Sendable (GitHubPullRequestCheckoutRequest) throws -> any GitHubPullRequestCheckoutSession
    private let pullRequestCheckoutFactory: PullRequestCheckoutFactory
    private struct PreparedPullRequestCheckout: Sendable { let operation: PullRequestCheckoutOperation; let digest: String }
    private var pullRequestCheckoutReviews: [UUID: PreparedPullRequestCheckout] = [:]
    private var acceptingPullRequestCheckouts: Set<UUID> = []
    private struct PreparedPullRequestCreation: Sendable { let operation: PullRequestCreationOperation; let digest: String }
    private var pullRequestCreationReviews: [UUID: PreparedPullRequestCreation] = [:]
    private var acceptingPullRequestCreations: Set<UUID> = []
    private struct PullRequestRead: Sendable { let projectID: UUID; let drain: Task<Void, Never>; let cancel: @Sendable () -> Void }
    private var pullRequestReads: [UUID: PullRequestRead] = [:]
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
        let path: String
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
    private final class MCPCommandAdmission: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        func cancel() { lock.lock(); cancelled = true; lock.unlock() }
        func check() throws {
            lock.lock(); let stopped = cancelled; lock.unlock()
            if stopped { throw WorkspaceCommandError(AppMCPError(.cancelled).localizedDescription) }
        }
    }
    private struct Envelope: Sendable {
        var id: UUID
        var command: EngineCommand
        var mcpAdmission: MCPCommandAdmission?
        var continuation: CheckedContinuation<WorkspaceCommandReceipt, any Error>
    }
    private struct Runtime: Sendable {
        var id: UUID
        var projectID: UUID
        var session: any ProviderSession
        var provider: ProviderKind
        var path: String
        var acpAgent: ACPAgentConfiguration?
        var openCodeIdentity: OpenCodeRuntimeIdentity?
        var grokRuntimeMode: GrokACPRuntimeMode?
        var piBinding: PiRuntimeBinding?
        var museBinding: MuseRuntimeBinding?
        var antigravityBinding: AntigravityRuntimeBinding?
        var codexBinding: CodexRuntimeConfiguration?
        var claudeConfiguration: ClaudeRuntimeConfiguration?
        var claudeLaunchSelection: ClaudeResumeSelection?
        var claudeNativeID: String?
        var reader: Task<Void, Never>?
        var mcpScope: MCPInvocationScope?
    }
    private struct MetadataRuntime: Sendable {
        var session: any ProviderSession
        var path: String
        var threadID: UUID?
        var projectID: UUID?
        var configuration: ProviderConfiguration?
        let launchConfiguration: ProviderConfiguration
        var operationCancel: (@Sendable () -> Void)?
        var operationDrain: Task<Void, Never>?
        var joinsOperation = false
        var closeTask: Task<Void, Never>?
    }
    private struct ClaudeHistoryScope: Sendable, Hashable {
        let configurationDirectory: String
        let nativeSessionID: String
    }
    private struct Cleanup: Sendable {
        var projectIDs: Set<UUID>
        var threadIDs: Set<UUID>
        var workspacePaths: Set<String>
        var codexInstances: Set<UUID>
        var claudeScopes: Set<ClaudeHistoryScope>
        var task: Task<Void, Never>
    }
    private struct IdentityRefresh: Sendable {
        var id: UUID
        var incarnation: UUID
        var path: String
        var task: Task<RepositoryIdentity?, any Error>
    }
    private let appMCPEnabled: Bool
    private let mcpRegistry = MCPSessionRegistry()
    private var mcpServer: MCPHTTPServer?
    private var mcpServerStart: Task<MCPHTTPServer, any Error>?
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
    private var codexDefaultReviews: [UUID: ReviewedCodexDefault] = [:]
    private var antigravityAuthenticationLeases: [UUID: UUID] = [:]
    private var codexAuthenticationLeases: [UUID: UUID] = [:]
    private var codexAuthenticationOwners: [UUID: Set<UUID>] = [:]
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

    public init(url: URL, appMCPEnabled: Bool = false, providerFactory: @escaping ProviderFactory = { try ProviderSessions.make(for: $0) },
                cloneFactory: @escaping CloneFactory = { GitCloneService(plan: $0) },
                identityResolver: IdentityResolver? = nil,
                worktreeFactory: @escaping WorktreeFactory = { GitWorktreeService(request: $0) },
                projectScriptPlanner: ProjectScriptPlanner? = nil,
                projectScriptFactory: @escaping ProjectScriptFactory = { _ in throw ProjectScriptExecutionError(.helperUnavailable) },
                checkpointFactory: @escaping CheckpointFactory = { GitCheckpointService(root: $0) },
                pullRequestFactory: @escaping PullRequestFactory = { GitHubPullRequestService(root: $0) },
                pullRequestCheckoutFactory: @escaping PullRequestCheckoutFactory = { GitHubPullRequestCheckoutService(request: $0) }) throws {
        self.appMCPEnabled = appMCPEnabled
        ownership = try WorkspaceRuntimeLock(url: url.appendingPathExtension("runtime-lock"))
        database = try WorkspaceDatabase(url: url)
        attachments = try AttachmentStore(root: url.deletingLastPathComponent().appendingPathComponent("Attachments", isDirectory: true))
        factory = providerFactory
        self.cloneFactory = cloneFactory
        self.identityResolver = identityResolver ?? { try await RepositoryIdentityResolver(root: $0).resolve() }
        self.worktreeFactory = worktreeFactory
        self.projectScriptPlanner = projectScriptPlanner ?? { try await ProjectScriptSetupPlanner.plan($0) }
        self.projectScriptFactory = projectScriptFactory
        self.checkpointFactory = checkpointFactory; self.pullRequestFactory = pullRequestFactory
        self.pullRequestCheckoutFactory = pullRequestCheckoutFactory
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
        var capturedCommand = command
        if case .editThread(let threadID, .workspacePath(let path)) = command,
           let runtime = revision.snapshot.threads.first(where: { $0.id == threadID })?.claudeRuntimeConfiguration {
            let captured = try runtime.replacingWorkspace(path, physicalPath: ClaudeRuntimeValidation.physical(path, allowMissing: false))
            capturedCommand = .editThread(threadID, .claudeWorkspace(captured))
        }
        if case .editThread(let threadID, .workspacePath(let path)) = command,
           let runtime = revision.snapshot.threads.first(where: { $0.id == threadID })?.piConfiguration?.runtime {
            let captured = try runtime.replacingWorkspace(path, physicalPath: PiRuntimeConfiguration.physical(path))
            capturedCommand = .editThread(threadID, .piWorkspace(captured))
        }
        let receipt = try await enqueue(.client(capturedCommand), id: id)
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
        let receipt = try await enqueue(.beginWorktreePreparation(threadID: threadID, request: request, expectedSourcePath: thread.workspacePath, previousAttemptID: nil, incarnation: incarnation, reviewSetup: reviewSetup, claudeRuntimeConfiguration: try thread.claudeRuntimeConfiguration?.replacingWorkspace(request.destinationPath, physicalPath: ClaudeRuntimeValidation.physical(request.destinationPath, allowMissing: true)), piRuntimeConfiguration: try thread.piConfiguration?.runtime?.replacingWorkspace(request.destinationPath, physicalPath: PiRuntimeConfiguration.physical(request.destinationPath, allowMissing: true))))
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
        let receipt = try await enqueue(.beginWorktreePreparation(threadID: threadID, request: request, expectedSourcePath: thread.workspacePath, previousAttemptID: state.id, incarnation: incarnation, reviewSetup: state.setup != nil, claudeRuntimeConfiguration: try thread.claudeRuntimeConfiguration?.replacingWorkspace(request.destinationPath, physicalPath: ClaudeRuntimeValidation.physical(request.destinationPath, allowMissing: true)), piRuntimeConfiguration: try thread.piConfiguration?.runtime?.replacingWorkspace(request.destinationPath, physicalPath: PiRuntimeConfiguration.physical(request.destinationPath, allowMissing: true))))
        if let rejection = receipt.rejection { throw WorkspaceCommandError(rejection) }; return receipt
    }
    private func enqueue(_ command: EngineCommand, id: UUID = UUID()) async throws -> WorkspaceCommandReceipt {
        guard loaded, !closing, fatalError == nil else { throw CoincideError(fatalError ?? "The workspace is closing.") }
        let admitted: EngineCommand
        if let authority = AppMCPTaskContext.authority {
            try Task.checkCancellation()
            switch command {
            case .client, .promptSteeringAccepted, .conversationHistoryAccepted, .beginWorktreePreparation:
                admitted = .appMCP(authority: authority, commands: [command])
            default: admitted = command
            }
        } else { admitted = command }
        let permit: MCPCommandAdmission?
        if case .appMCP = admitted { permit = MCPCommandAdmission() } else { permit = nil }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pendingCommands += 1
                incoming.yield(.init(id: id, command: admitted, mcpAdmission: permit, continuation: continuation))
            }
        } onCancel: { permit?.cancel() }
    }
    private func process(_ envelope: Envelope) async {
        defer {
            pendingCommands -= 1
            if pendingCommands == 0 { let waiters = drainWaiters; drainWaiters = []; for waiter in waiters { waiter.resume() } }
        }
        if let fatalError { envelope.continuation.resume(throwing: CoincideError(fatalError)); return }
        do {
            let payload: Data
            if case .remoteEnvironment(let request, _) = envelope.command { payload = try RemoteEnvironmentProtocol.payload(request) }
            else { payload = try encoder.encode(envelope.command) }
            if let receipt = try await database.receipt(envelope.id, matching: payload) {
                envelope.continuation.resume(returning: receipt); return
            }
            for attempt in 0..<4 {
                let base = try await database.revision()
                if let fatalError { throw CoincideError(fatalError) }
                let decision: WorkspaceDecision
                do {
                    try envelope.mcpAdmission?.check()
                    let admissionCommands: [EngineCommand]
                    if case .appMCP(let authority, let commands) = envelope.command {
                        try validateAppMCPLiveAuthority(authority)
                        try AppMCPAdmission.validate(authority: authority, snapshot: base.snapshot, commands: commands)
                        admissionCommands = commands
                    } else if case .remoteEnvironment(let request, let preparation) = envelope.command {
                        admissionCommands = [.client(try RemoteEnvironmentAdmission.action(request, preparation: preparation, snapshot: base.snapshot))]
                    } else { admissionCommands = [envelope.command] }
                    for command in admissionCommands {
                        try validateCodexDefaultCommand(command, snapshot: base.snapshot)
                        try validateAntigravityAdmission(command, snapshot: base.snapshot)
                        try validateCodexAuthenticationAdmission(command, snapshot: base.snapshot)
                        try validateAppMCPPreparedCommand(command)
                    }
                    if case .promptSteeringAccepted(let operation) = envelope.command,
                       threadIncarnations[operation.threadID] != operation.sourceIncarnation {
                        throw WorkspaceCommandError("The active provider turn changed before steering was accepted.")
                    }
                    if case .pullRequestCheckoutAccepted(let operation) = envelope.command,
                       projectIncarnations[operation.projectID] != operation.review.sourceIncarnation {
                        throw WorkspaceCommandError("This project changed. Review the pull request checkout again.")
                    }
                    if case .pullRequestCreationAccepted(let operation) = envelope.command,
                       projectIncarnations[operation.projectID] != operation.sourceIncarnation {
                        throw WorkspaceCommandError("This project changed. Review its current pull request checkout again.")
                    }
                    if case .checkpointRestoreAccepted(let review) = envelope.command,
                       threadIncarnations[review.threadID] != review.sourceIncarnation {
                        throw WorkspaceCommandError("This conversation changed. Review its files again before restoring.")
                    }
                    if case .conversationHistoryAccepted(let review, _) = envelope.command,
                       threadIncarnations[review.sourceThreadID] != review.sourceIncarnation {
                        throw WorkspaceCommandError("This conversation changed. Review its current history before continuing.")
                    }
                    if case .beginWorktreePreparation(let threadID, let request, _, _, let incarnation, _, _, _) = envelope.command,
                       (threadIncarnations[threadID] != incarnation || request.destinationRoot != worktreesRoot.path) {
                        throw WorkspaceCommandError("This conversation changed. Choose the worktree again in its current workspace.")
                    }
                    if !ownsPromptSteeringEvent(envelope.command) || !ownsPiHistoryEvent(envelope.command) || !ownsPullRequestCheckoutEvent(envelope.command) || !ownsPullRequestCreationEvent(envelope.command) || !ownsCheckpointRestoreEvent(envelope.command) || !ownsHistoryEvent(envelope.command) || !ownsScriptEvent(envelope.command) || !ownsCheckpointEvent(envelope.command) {
                        decision = WorkspaceDecision(snapshot: base.snapshot)
                    } else if case .worktreeRecovered(let threadID, let attemptID, let incarnation, _) = envelope.command,
                       !ownsWorktree(threadID: threadID, attemptID: attemptID, incarnation: incarnation) {
                        decision = WorkspaceDecision(snapshot: base.snapshot)
                    } else if case .repositoryIdentityResolved(let projectID, let path, let incarnation, let requestID, _) = envelope.command,
                       !ownsIdentityRefresh(projectID: projectID, path: path, incarnation: incarnation, requestID: requestID) {
                        decision = WorkspaceDecision(snapshot: base.snapshot)
                    } else { decision = try WorkspaceDecision.make(envelope.command, id: envelope.id, snapshot: base.snapshot, now: Date()) }
                }
                catch where error is WorkspaceCommandError || error is AppMCPError {
                    do {
                        let reason = (error as? WorkspaceCommandError)?.message ?? (error as? AppMCPError)?.localizedDescription ?? AppMCPError(.unavailable).localizedDescription
                        let receipt = try await database.rejectCommand(envelope.id, matching: payload, reason: reason, expectedSequence: base.sequence)
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
                    codexDefaultReviews = codexDefaultReviews.filter { id, reviewed in
                        decision.snapshot.threads.contains { $0.id == id && $0.projectID == reviewed.projectID }
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
        var codexInstances: Set<UUID> = []
        var claudeScopes: Set<ClaudeHistoryScope> = []
        var jobs: [Task<Void, Never>] = []
        let old = Dictionary(uniqueKeysWithValues: previous.projects.map { ($0.id, $0) })
        for project in decision.snapshot.projects where old[project.id] == nil || old[project.id]?.path != project.path {
            projectIncarnations[project.id] = UUID()
        }
        for id in removedProjects { projectIncarnations.removeValue(forKey: id) }
        for (id, read) in pullRequestReads where removedProjects.contains(read.projectID) {
            read.cancel(); jobs.append(read.drain); pullRequestReads.removeValue(forKey: id)
        }
        pullRequestCreationReviews = pullRequestCreationReviews.filter { !removedProjects.contains($0.value.operation.projectID) }
        pullRequestCheckoutReviews = pullRequestCheckoutReviews.filter { !removedProjects.contains($0.value.operation.projectID) }

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
        for (operationID, job) in piHistoryJobs where threads.contains(job.threadID) || removedProjects.contains(job.projectID) {
            if let close = beginPiHistoryClose(operationID) { jobs.append(close) }
            cleanupThreadIDs.insert(job.threadID); projectIDs.insert(job.projectID)
        }
        for (id, read) in historyReads where removedThreads.contains(read.threadID) || removedProjects.contains(read.projectID) || threads.contains(read.threadID) {
            historyReads.removeValue(forKey: id); read.cancel()
            jobs.append(read.drain); projectIDs.insert(read.projectID); cleanupThreadIDs.insert(read.threadID)
            if let instance = read.configuration.ownedCodexInstanceID { codexInstances.insert(instance) }; claudeScopes.formUnion(Self.claudeScopes(read.configuration))
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
                if let scope = runtime.mcpScope { let registry = mcpRegistry; jobs.append(Task { await registry.revoke(sessionID: scope.sessionID) }) }
                if let binding = runtime.codexBinding, binding.authenticationMode == .ownedChatGPT { codexInstances.insert(binding.instanceID) }
                if let configuration = runtime.claudeConfiguration, let native = previousThreads[id]?.providerThreadID ?? runtime.claudeNativeID {
                    claudeScopes.insert(.init(configurationDirectory: configuration.configurationDirectory, nativeSessionID: native))
                }
            }
        }
        for (id, metadata) in metadataSessions where metadata.threadID.map({ threads.contains($0) }) == true || metadata.projectID.map({ removedProjects.contains($0) }) == true {
            metadataSessions.removeValue(forKey: id)
            providerPaths.insert(metadata.path)
            if let projectID = metadata.projectID { projectIDs.insert(projectID) }
            if let instance = metadata.launchConfiguration.ownedCodexInstanceID { codexInstances.insert(instance) }; claudeScopes.formUnion(Self.claudeScopes(metadata.launchConfiguration)); if let captured = metadata.configuration { claudeScopes.formUnion(Self.claudeScopes(captured)) }
            metadata.operationCancel?()
            if let task = metadata.closeTask { jobs.append(task) }
            else {
                sessions.append(metadata.session)
                // Legacy metadata results are incarnation-fenced and may finish
                // after project removal. Owned auth additionally retains every
                // credential-bound operation until account mutation can proceed.
                if metadata.joinsOperation || metadata.launchConfiguration.ownedCodexInstanceID != nil || metadata.launchConfiguration.claudeRuntimeConfiguration != nil, let drain = metadata.operationDrain { jobs.append(drain) }
            }
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
        // Baseline/checkpoint cleanup may precede creation of a provider actor.
        // Preserve its captured account scope even after the run/thread is removed.
        for thread in previous.threads where cleanupThreadIDs.contains(thread.id) {
            codexInstances.formUnion(thread.ownedCodexInstances)
            claudeScopes.formUnion(Self.claudeScopes(.init(thread: thread)))
            if let active = thread.activeRun {
                var configuration = active.configuration
                configuration.nativeThreadID = configuration.nativeThreadID ?? thread.runHistory?.first(where: { $0.id == active.id })?.providerThreadID
                claudeScopes.formUnion(Self.claudeScopes(configuration))
            }
        }
        let cleanup = startCleanup(projectIDs: projectIDs, threadIDs: cleanupThreadIDs, sessions: sessions, jobs: jobs, workspacePaths: providerPaths, codexInstances: codexInstances, claudeScopes: claudeScopes)
        for thread in decision.snapshot.threads {
            if let settlement = thread.settlement, settlement.phase == .settled,
               previousThreads[thread.id]?.settlement?.id != settlement.id, let cleanup { settlementPrerequisites[settlement.id] = cleanup }
        }
    }
    @discardableResult private func startCleanup(projectIDs: Set<UUID>, threadIDs: Set<UUID> = [], sessions: [any ProviderSession], jobs: [Task<Void, Never>] = [], workspacePaths: Set<String> = [], codexInstances: Set<UUID> = [], claudeScopes: Set<ClaudeHistoryScope> = []) -> Task<Void, Never>? {
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
        cleanupTasks[id] = .init(projectIDs: projectIDs, threadIDs: threadIDs, workspacePaths: workspacePaths, codexInstances: codexInstances, claudeScopes: claudeScopes, task: task)
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
        let steeringIncarnation = effect.request.promptSteeringOperationID == nil ? nil : effect.request.threadID.flatMap { threadIncarnations[$0] }
        let scriptIncarnation = effect.request.projectScriptRunID == nil ? nil : effect.request.threadID.flatMap { threadIncarnations[$0] }
        let checkpointIncarnation = effect.request.checkpointOwner == nil ? nil : effect.request.threadID.flatMap { threadIncarnations[$0] }
        let historyIncarnation: UUID?
        switch effect.request {
        case .conversationHistory, .conversationHistoryMaintenance: historyIncarnation = effect.request.threadID.flatMap { threadIncarnations[$0] }
        default: historyIncarnation = nil
        }
        let historyFilesIncarnation: UUID?
        if case .conversationHistoryFiles = effect.request { historyFilesIncarnation = effect.request.threadID.flatMap { threadIncarnations[$0] } }
        else { historyFilesIncarnation = nil }
        let pullRequestIncarnation = effect.request.pullRequestCreationOperationID == nil ? nil : effect.request.projectID.flatMap { projectIncarnations[$0] }
        let checkoutIncarnation = effect.request.pullRequestCheckoutOperationID == nil ? nil : effect.request.projectID.flatMap { projectIncarnations[$0] }
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
            let message = checkoutIncarnation != nil ? PullRequestCheckoutOperation.failureMessage : pullRequestIncarnation != nil ? PullRequestCreationOperation.failureMessage : historyFilesIncarnation != nil ? ConversationHistoryFilesState.failureMessage : restoreIncarnation != nil ? RunCheckpointRestoreOperation.failureMessage : historyIncarnation != nil ? ConversationHistoryOperation.failureMessage : effect.request.checkpointOwner != nil ? ThreadRunCheckpointAttempt.failureMessage : effect.request.projectScriptRunID != nil ? ThreadProjectScriptRun.executionError(for: effect.request.projectScriptOwner?.role ?? .setup) : effect.request.projectID == nil && effect.request.worktreeAttemptID == nil ? error.localizedDescription : String(GitService.redactURLs(error.localizedDescription).prefix(4_000))
            result = .failed(message)
        }
        heartbeat.cancel()
        if !closing, fatalError == nil {
            do {
                let owned: Bool
                switch result {
                case .promptSteeringDelivered, .promptSteeringUnconfirmed, .promptSteeringUnsentCompleted, .succeeded, .stopped, .worktreeResolved, .worktreePrepared, .projectScriptResolved, .checkpointResolved, .checkpointCaptured, .checkpointUnavailable, .conversationHistoryConfirmed, .conversationHistoryUnconfirmed, .conversationHistoryMaintenanceConfirmed, .checkpointRestoreConfirmed, .checkpointRestoreUnconfirmed, .pullRequestCreationConfirmed, .pullRequestCreationUnconfirmed, .pullRequestCheckoutCompleted, .pullRequestCheckoutUnconfirmed: owned = try await database.settleEffect(effect.id, workerID: workerID)
                case .failed(let message): owned = try await database.settleEffect(effect.id, workerID: workerID, error: message)
                case .cancelled: owned = try await database.cancelEffect(effect.id, workerID: workerID, reason: "The targeted run or request is no longer active.")
                }
                guard owned else { await infrastructureFailed("Provider execution lost its workspace lease."); return }
                if let steeringIncarnation {
                    if !retiringEffects.contains(effect.id) { _ = try await enqueue(.promptSteeringEffectResult(effect.request, result, incarnation: steeringIncarnation)) }
                } else if let checkoutIncarnation {
                    if !retiringEffects.contains(effect.id) { _ = try await enqueue(.pullRequestCheckoutEffectResult(effect.request, result, incarnation: checkoutIncarnation)) }
                } else if let pullRequestIncarnation {
                    if !retiringEffects.contains(effect.id) { _ = try await enqueue(.pullRequestCreationEffectResult(effect.request, result, incarnation: pullRequestIncarnation)) }
                } else if let historyFilesIncarnation {
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
                        if effect.request.conversationHistoryMaintenanceOperationID != nil {
                            _ = try await enqueue(.conversationHistoryMaintenanceEffectResult(effect.request, result, incarnation: historyIncarnation))
                        } else { _ = try await enqueue(.conversationHistoryEffectResult(effect.request, result, incarnation: historyIncarnation)) }
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
        if case .promptSteering = request { return await performPromptSteering(request) }
        if case .pullRequestCreation = request { return try await performPullRequestCreation(request) }
        if case .pullRequestCheckout = request { return try await performPullRequestCheckout(request) }
        if case .checkpointRestore = request { return try await performCheckpointRestore(request) }
        if case .conversationHistoryFiles = request { return try await performConversationHistoryFiles(request) }
        if case .conversationHistory = request { return try await performConversationHistory(request) }
        if case .conversationHistoryMaintenance = request { return await performConversationHistoryMaintenance(request) }
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
        case .promptSteering, .pullRequestCheckout, .pullRequestCreation, .conversationHistoryFiles, .checkpointRestore, .conversationHistory, .conversationHistoryMaintenance, .resolveRunCheckpoint, .captureRunCheckpoint, .resolveThreadScript, .startThreadScript, .resolveProjectScript, .startProjectScript, .resolveWorktree, .prepareWorktree, .projectClone: return .cancelled // Preparation/project actions are handled before thread lookup.
        case .providerStart(_, let runID, let configuration, let prompt, let references):
            guard thread.activeRun?.id == runID, thread.activeRun?.stopRequested == false, !isCodexAuthenticationLocked(configuration) else { return .cancelled }
            guard !providerHistoryScopeLocked(configuration: configuration,
                nativeThreadID: configuration.nativeThreadID ?? thread.runHistory?.first(where: { $0.id == runID })?.providerThreadID ?? thread.providerThreadID) else { return .failed("This provider conversation is held by a pending history action.") }
            await awaitCheckpointDrains(threadID: thread.id)
            guard checkpointProviderReleased(threadID: thread.id, runID: runID) else { return .cancelled }
            let input = try await attachments.prepare(text: prompt, attachments: references ?? [])
            guard !closing, !stoppingEffects, !isCodexAuthenticationLocked(configuration),
                  revision.snapshot.workspaceReady(for: thread),
                  revision.snapshot.threads.first(where: { $0.id == thread.id })?.activeRun?.id == runID,
                  revision.snapshot.threads.first(where: { $0.id == thread.id })?.activeRun?.stopRequested == false else { return .cancelled }
            var configured = thread
            configured.provider = configuration.provider; configured.workspacePath = configuration.workspacePath
            configured.providerThreadID = configuration.nativeThreadID; configured.model = configuration.model; configured.reasoningEffort = configuration.reasoningEffort; configured.permission = configuration.permission
            configured.acpAgent = configuration.acpAgent; configured.openCodeConfiguration = configuration.openCodeConfiguration; configured.piConfiguration = configuration.piConfiguration; configured.museConfiguration = configuration.museConfiguration; configured.antigravityConfiguration = configuration.antigravityConfiguration; configured.codexRuntimeConfiguration = configuration.codexRuntimeConfiguration; configured.claudeRuntimeConfiguration = configuration.claudeRuntimeConfiguration; configured.agentModeID = configuration.agentModeID
            configured.agentConfigValues = configuration.agentConfigValues
            configured.agentConfiguration = configuration.agentConfiguration
            let runtime = try await runtime(for: configured, runID: runID)
            if await waitForRemovalCommit(threadID: thread.id, projectID: thread.projectID) { return .cancelled }
            guard !closing, !stoppingEffects, !isCodexAuthenticationLocked(configuration), revision.snapshot.threads.first(where: { $0.id == thread.id })?.activeRun?.id == runID,
                  revision.snapshot.workspaceReady(for: thread),
                  revision.snapshot.threads.first(where: { $0.id == thread.id })?.activeRun?.stopRequested == false,
                  runtimes[thread.id]?.id == runtime.id else { return .cancelled }
            try Task.checkCancellation()
            guard !providerHistoryScopeLocked(configuration: configuration,
                nativeThreadID: configuration.nativeThreadID ?? revision.snapshot.threads.first(where: { $0.id == thread.id })?.runHistory?.first(where: { $0.id == runID })?.providerThreadID ?? configured.providerThreadID) else { return .failed("This provider conversation is held by a pending history action.") }
            if configuration.provider == .pi, configuration.piConfiguration?.runtime != nil {
                guard let incarnation = threadIncarnations[thread.id] else { return .cancelled }
                let preparation = try await runtime.session.preparePiRun(input: input, thread: configured)
                guard !closing, !stoppingEffects, fatalError == nil, !Task.isCancelled,
                      threadIncarnations[thread.id] == incarnation, runtimes[thread.id]?.id == runtime.id,
                      let current = revision.snapshot.threads.first(where: { $0.id == thread.id }),
                      current.activeRun?.id == runID, current.activeRun?.configuration == configuration,
                      current.activeRun?.stopRequested == false, current.runtimeID == runtime.id,
                      revision.snapshot.workspaceReady(for: current) else { return .cancelled }
                guard preparation.runID == runID, preparation.runtimeIdentity == configuration.piConfiguration?.runtimeIdentity,
                      preparation.inputDigest == (try PiHistoryInputEvidence.digest(input)) else { throw PiHistoryGraphError(.invalidWindow) }
                let saved = try await enqueue(.piRunHistoryPrepared(threadID: thread.id, runtimeID: runtime.id, preparation: preparation, incarnation: incarnation))
                guard saved.rejection == nil else { throw PiHistoryGraphError(.invalidWindow) }
                guard !closing, !stoppingEffects, fatalError == nil, !Task.isCancelled,
                      threadIncarnations[thread.id] == incarnation, runtimes[thread.id]?.id == runtime.id,
                      let committed = revision.snapshot.threads.first(where: { $0.id == thread.id }),
                      committed.activeRun?.id == runID, committed.activeRun?.configuration == configuration,
                      committed.activeRun?.stopRequested == false, committed.runtimeID == runtime.id,
                      committed.runHistory?.first(where: { $0.id == runID })?.pi?.preparation == preparation,
                      revision.snapshot.workspaceReady(for: committed) else { return .cancelled }
                configured.runHistory = committed.runHistory; configured.providerThreadID = preparation.nativeSessionFile
                try await runtime.session.sendPreparedPi(input: input, thread: configured, preparation: preparation)
            } else { try await runtime.session.send(input: input, thread: configured) }
            return .succeeded
        case .providerInterrupt(_, let runID):
            guard thread.activeRun?.id == runID else { return .cancelled }
            let expectedRuntimeID = runtimes[thread.id]?.id
            if let runtime = runtimes[thread.id], runtime.id == thread.runtimeID,
               runtime.codexBinding == thread.activeRun?.configuration.codexRuntimeBinding,
               thread.activeRun?.nativeTurnID != nil ||
                (thread.activeRun?.configuration.provider == .pi && runtime.provider == .pi &&
                 runtime.piBinding == thread.activeRun?.configuration.piRuntimeBinding) ||
                (thread.activeRun?.configuration.provider == .antigravity && runtime.provider == .antigravity &&
                 runtime.antigravityBinding == thread.activeRun?.configuration.antigravityRuntimeBinding) {
                do { try await runtime.session.interrupt(expectedRunID: runID); return .succeeded }
                catch { /* Fall back only while this same run/runtime is still owned. */ }
            }
            guard revision.snapshot.threads.first(where: { $0.id == thread.id })?.activeRun?.id == runID,
                  runtimes[thread.id]?.id == expectedRuntimeID else { return .cancelled }
            // Closing the owned runtime also stops startup before a native turn ID exists.
            await closeRuntime(thread.id)
            return .stopped
        case .providerRespond(_, let runID, let request, let response):
            guard thread.activeRun?.id == runID, thread.activeRun?.stopRequested == false,
                  thread.runtimeRequests.contains(where: { $0.id == request.id && $0.responding }),
                  let runtime = runtimes[thread.id], runtime.id == thread.runtimeID,
                  thread.activeRun.map({ !isCodexAuthenticationLocked($0.configuration) }) == true else { return .cancelled }
            switch response {
            case .option(let id): try await runtime.session.choose(request, optionID: id)
            case .decision(let allow): try await runtime.session.respond(request, allow: allow)
            case .answers(let answers): try await runtime.session.answer(request, answers: answers)
            case .selections(let selections): try await runtime.session.selectAnswers(request, selections: selections)
            case .selectionsWithNotes(let selections, let notes): try await runtime.session.selectAnswers(request, selections: selections, notes: notes)
            }
            return .succeeded
        case .providerSessionRespond(_, let runtimeID, let request, let response):
            guard thread.runtimeID == runtimeID, thread.runtimeRequests.contains(where: { $0.id == request.id && $0.responding && $0.sessionScoped == true }),
                  let runtime = runtimes[thread.id], runtime.id == runtimeID else { return .cancelled }
            if let binding = runtime.codexBinding, binding.authenticationMode == .ownedChatGPT, codexAuthenticationLeases[binding.instanceID] != nil { return .cancelled }
            switch response {
            case .option(let id): try await runtime.session.choose(request, optionID: id)
            case .decision(let allow): try await runtime.session.respond(request, allow: allow)
            case .answers(let answers): try await runtime.session.answer(request, answers: answers)
            case .selections(let selections): try await runtime.session.selectAnswers(request, selections: selections)
            case .selectionsWithNotes(let selections, let notes): try await runtime.session.selectAnswers(request, selections: selections, notes: notes)
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
        let configuration = thread.activeRun?.configuration ?? ProviderConfiguration(thread: thread)
        let nativeID = configuration.nativeThreadID ?? thread.runHistory?.first(where: { $0.id == runID })?.providerThreadID ?? thread.providerThreadID
        guard !providerHistoryScopeLocked(configuration: configuration, nativeThreadID: nativeID), !revision.snapshot.isClaudeHistoryScopeLocked(configuration: configuration, nativeThreadID: nativeID) else {
            throw WorkspaceCommandError("This provider conversation is held by a pending history action.")
        }
        if let captured = ProviderConfiguration(thread: thread).codexRuntimeBinding, captured.authenticationMode == .ownedChatGPT {
            guard captured.accountBinding != nil, let current = revision.snapshot.threads.first(where: { $0.id == thread.id }),
                  ProviderConfiguration(thread: current).codexRuntimeBinding == captured else { throw CodexAccountError.staleAccount }
        }
        if thread.provider == .antigravity {
            guard let captured = thread.antigravityConfiguration,
                  let current = revision.snapshot.threads.first(where: { $0.id == thread.id })?.antigravityConfiguration,
                  current.runtimeIdentity == captured.runtimeIdentity else {
                throw CoincideError("This queued input belongs to an earlier Antigravity account or runtime. Review it before sending with the current settings.")
            }
        }
        if let existing = runtimes[thread.id], existing.provider == thread.provider, existing.path == thread.workspacePath, existing.acpAgent == thread.acpAgent, existing.openCodeIdentity == thread.openCodeConfiguration?.runtimeIdentity, existing.grokRuntimeMode == ProviderConfiguration(thread: thread).effectiveGrokRuntimeMode, existing.piBinding == ProviderConfiguration(thread: thread).piRuntimeBinding, existing.museBinding == ProviderConfiguration(thread: thread).museRuntimeBinding, existing.antigravityBinding == ProviderConfiguration(thread: thread).antigravityRuntimeBinding, existing.codexBinding == ProviderConfiguration(thread: thread).codexRuntimeBinding, claudeRuntimeMatches(existing, thread: thread) {
            if let scope = existing.mcpScope, scope.permission != configuration.permission {
                // A session's authority is immutable. Reissue it when an explicit
                // successor captures different permissions, preserving native history.
                await closeRuntime(thread.id, matching: existing.id)
                return try await runtime(for: thread, runID: runID)
            }
            if let scope = existing.mcpScope { await mcpRegistry.touch(sessionID: scope.sessionID) }
            guard ownsRun(threadID: thread.id, projectID: thread.projectID, runID: runID), runtimes[thread.id]?.id == existing.id else { throw CancellationError() }
            return existing
        }
        await closeRuntime(thread.id)
        if await waitForRemovalCommit(threadID: thread.id, projectID: thread.projectID) { throw CancellationError() }
        try Task.checkCancellation()
        // Closing the previous process is an await: removal may have committed during that I/O.
        guard ownsRun(threadID: thread.id, projectID: thread.projectID, runID: runID) else { throw CancellationError() }
        guard !providerHistoryScopeLocked(configuration: configuration, nativeThreadID: nativeID), !revision.snapshot.isClaudeHistoryScopeLocked(configuration: configuration, nativeThreadID: nativeID) else {
            throw WorkspaceCommandError("This provider conversation is held by a pending history action.")
        }
        let id = UUID(), session = try factory(thread)
        var runtime = Runtime(id: id, projectID: thread.projectID, session: session, provider: thread.provider, path: thread.workspacePath, acpAgent: thread.acpAgent, openCodeIdentity: thread.openCodeConfiguration?.runtimeIdentity, grokRuntimeMode: ProviderConfiguration(thread: thread).effectiveGrokRuntimeMode, piBinding: ProviderConfiguration(thread: thread).piRuntimeBinding, museBinding: ProviderConfiguration(thread: thread).museRuntimeBinding, antigravityBinding: ProviderConfiguration(thread: thread).antigravityRuntimeBinding, codexBinding: ProviderConfiguration(thread: thread).codexRuntimeBinding, claudeConfiguration: thread.claudeRuntimeConfiguration, claudeLaunchSelection: thread.activeRun?.configuration.claudeLaunchSelection, claudeNativeID: thread.providerThreadID)
        runtimes[thread.id] = runtime
        do { runtime.mcpScope = try await configureAppMCP(thread: thread, runID: runID, runtimeID: id, session: session, configuration: configuration) }
        catch { await closeRuntime(thread.id, matching: id); throw error }
        if let native = session as? AntigravitySession {
            do {
                try await native.setFileAccessGuard { [weak self] _, writing in
                    guard let self else { throw CancellationError() }
                    try await self.validateAntigravityFileAccess(threadID: thread.id, projectID: thread.projectID,
                        runtimeID: id, path: thread.workspacePath, writing: writing)
                }
            } catch { await closeRuntime(thread.id, matching: id); throw error }
        }
        _ = try await enqueue(.runtimeOpened(threadID: thread.id, runID: runID, runtimeID: id))
        guard ownsRun(threadID: thread.id, projectID: thread.projectID, runID: runID), runtimes[thread.id]?.id == id else {
            await closeRuntime(thread.id, matching: id); throw CancellationError()
        }
        let stream = session.events
        runtime.reader = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                do { try await self.routeProviderEvent(threadID: thread.id, runtimeID: id, event: event) }
                catch { return }
            }
            await self?.piRuntimeStreamEnded(threadID: thread.id, runtimeID: id)
        }
        if runtimes[thread.id]?.id == id { runtimes[thread.id] = runtime }
        else { runtime.reader?.cancel(); throw CancellationError() }
        return runtime
    }
    private func validateAntigravityFileAccess(threadID: UUID, projectID: UUID, runtimeID: UUID, path: String, writing: Bool) throws {
        guard !closing, !stoppingEffects, fatalError == nil,
              let runtime = runtimes[threadID], runtime.id == runtimeID, runtime.provider == .antigravity, runtime.path == path,
              let current = revision.snapshot.threads.first(where: { $0.id == threadID && $0.projectID == projectID }),
              current.provider == .antigravity, current.workspacePath == path, current.runtimeID == runtimeID,
              current.activeRun?.stopRequested != true, !isAntigravityAuthenticationLocked(current),
              revision.snapshot.providerReady(for: current),
              !revision.snapshot.isConversationHistoryLocked(threadID: threadID),
              !revision.snapshot.isCheckpointRestoreLocked(path: path), !revision.snapshot.isPullRequestCreationLocked(path: path),
              !revision.snapshot.isPullRequestCheckoutLocked(path: path) else {
            throw CoincideError(writing ? "Antigravity cannot write while this workspace is changing." : "Antigravity cannot read while this workspace is changing.")
        }
    }
    private func ownsRun(threadID: UUID, projectID: UUID, runID: UUID) -> Bool {
        guard !closing, !stoppingEffects, fatalError == nil,
              let thread = revision.snapshot.threads.first(where: { $0.id == threadID && $0.projectID == projectID }),
              thread.activeRun?.id == runID, thread.activeRun?.stopRequested == false,
              !isAntigravityAuthenticationLocked(thread),
              thread.activeRun.map({ !isCodexAuthenticationLocked($0.configuration) }) == true,
              revision.snapshot.workspaceReady(for: thread) else { return false }
        return true
    }
    private func isAntigravityAuthenticationLocked(_ thread: CodingThread) -> Bool {
        let instance = thread.activeRun?.configuration.antigravityConfiguration?.instanceID ?? thread.antigravityConfiguration?.instanceID
        return instance.map { antigravityAuthenticationLeases[$0] != nil } ?? false
    }
    private func validateAntigravityAdmission(_ command: EngineCommand, snapshot: WorkspaceSnapshot) throws {
        let threadID: UUID
        switch command {
        case .client(.submit(let id, _)), .client(.submitFromAppMCP(let id, _, _)), .client(.resumeQueue(let id)): threadID = id
        default: return
        }
        guard let thread = snapshot.threads.first(where: { $0.id == threadID }), isAntigravityAuthenticationLocked(thread) else { return }
        throw WorkspaceCommandError("Wait for the Antigravity account change before sending or resuming messages. Your draft and queued messages were kept.")
    }
    /// An explicit account mutation retires every owner sharing that instance.
    /// The lease remains held through native auth, credential/config persistence
    /// and final app publication. Drafts and queued input are never replayed.
    public func beginAntigravityAuthentication(instanceID: UUID) async throws -> UUID {
        guard loaded, !closing, !stoppingEffects, fatalError == nil, antigravityAuthenticationLeases[instanceID] == nil else {
            throw WorkspaceCommandError("An Antigravity account change is already running or the workspace is unavailable.")
        }
        let affected = revision.snapshot.threads.filter { $0.antigravityConfiguration?.instanceID == instanceID || $0.activeRun?.configuration.antigravityConfiguration?.instanceID == instanceID }
        guard affected.allSatisfy({ !revision.snapshot.isConversationHistoryLocked(threadID: $0.id) && !revision.snapshot.isCheckpointRestoreLocked(path: $0.workspacePath) && !revision.snapshot.isPullRequestCreationLocked(path: $0.workspacePath) && !revision.snapshot.isPullRequestCheckoutLocked(path: $0.workspacePath) }) else {
            throw WorkspaceCommandError("Wait for Antigravity workspace operations to finish before changing the account.")
        }
        let leaseID = UUID(); antigravityAuthenticationLeases[instanceID] = leaseID
        do {
            let receipt = try await enqueue(.antigravityAuthenticationPreparing(instanceID: instanceID))
            if let rejection = receipt.rejection { throw WorkspaceCommandError(rejection) }
            let owners = Set(affected.map(\.id))
            while true {
                let jobs = cleanupTasks.values.filter { !$0.threadIDs.isDisjoint(with: owners) }.map(\.task)
                if jobs.isEmpty { break }
                for job in jobs { await job.value }
            }
            // Include metadata created without a conversation owner.
            for (id, metadata) in metadataSessions where metadata.configuration?.antigravityConfiguration?.instanceID == instanceID {
                if let close = beginMetadataClose(id) { await close.value }
                metadataSessions.removeValue(forKey: id)
            }
            try Task.checkCancellation()
            guard !closing, !stoppingEffects, fatalError == nil, antigravityAuthenticationLeases[instanceID] == leaseID else { throw CancellationError() }
            return leaseID
        } catch {
            if antigravityAuthenticationLeases[instanceID] == leaseID { antigravityAuthenticationLeases.removeValue(forKey: instanceID) }
            throw error
        }
    }
    public func endAntigravityAuthentication(leaseID: UUID) async {
        guard let instance = antigravityAuthenticationLeases.first(where: { $0.value == leaseID })?.key else { return }
        antigravityAuthenticationLeases.removeValue(forKey: instance)
    }
    public func applyAntigravityAccountConfiguration(_ configuration: AntigravityConfiguration) async throws {
        guard antigravityAuthenticationLeases[configuration.instanceID] != nil, !closing, !stoppingEffects, fatalError == nil else {
            throw WorkspaceCommandError("Begin an Antigravity account change before saving its settings.")
        }
        try configuration.validate()
        let receipt = try await enqueue(.antigravityAccountConfigured(configuration))
        if let rejection = receipt.rejection { throw WorkspaceCommandError(rejection) }
    }
    private func closeRuntime(_ threadID: UUID, matching expectedID: UUID? = nil) async {
        guard let runtime = runtimes[threadID], expectedID == nil || expectedID == runtime.id else { return }
        runtimes.removeValue(forKey: threadID); runtime.reader?.cancel()
        let registry = mcpRegistry
        let mcpJobs: [Task<Void, Never>] = runtime.mcpScope.map { scope in [Task { await registry.revoke(sessionID: scope.sessionID) }] } ?? []
        if let task = startCleanup(projectIDs: [runtime.projectID], threadIDs: [threadID], sessions: [runtime.session], jobs: mcpJobs, workspacePaths: [runtime.path], codexInstances: Set(runtime.codexBinding.flatMap { $0.authenticationMode == .ownedChatGPT ? $0.instanceID : nil }.map { [$0] } ?? []),
            claudeScopes: runtime.claudeConfiguration.flatMap { configuration in
                (revision.snapshot.threads.first(where: { $0.id == threadID })?.providerThreadID ?? runtime.claudeNativeID).map {
                    Set([ClaudeHistoryScope(configurationDirectory: configuration.configurationDirectory, nativeSessionID: $0)])
                }
            } ?? []) { await task.value }
    }
    private func infrastructureFailed(_ message: String) async {
        guard fatalError == nil else { return }
        fatalError = "Workspace execution stopped: \(message)"; publish()
        for task in effects.values { task.cancel() }
        cancelIdentityRefreshes()
        cancelCheckpointReads()
        for read in historyReads.values { read.cancel() }
        let piCloses = Array(piHistoryJobs.keys).compactMap { beginPiHistoryClose($0) }
        for close in piCloses { await close.value }
        historyReviews = [:]
        checkpointRestoreReviews = [:]
        pullRequestCreationReviews = [:]; pullRequestCheckoutReviews = [:]; codexDefaultReviews = [:]
        for read in pullRequestReads.values { read.cancel() }
        let inspections = worktreeInspections; worktreeInspections = [:]
        for inspection in inspections.values {
            inspection.task.cancel()
            _ = startCleanup(projectIDs: [inspection.projectID], threadIDs: [inspection.threadID], sessions: [], jobs: [Task { _ = try? await inspection.task.value }])
        }
        for id in Array(runtimes.keys) { await closeRuntime(id) }
        await closeAppMCPServer()
        await closeAllProjectScripts()
    }
    private func cancelIdentityRefreshes() {
        let refreshes = identityRefreshes; identityRefreshes = [:]
        for (id, refresh) in refreshes {
            refresh.task.cancel()
            _ = startCleanup(projectIDs: [id], sessions: [], jobs: [Task { _ = try? await refresh.task.value }])
        }
    }
    public func models(provider: ProviderKind, codexRuntimeConfiguration: CodexRuntimeConfiguration? = nil) async throws -> [ProviderModel] {
        guard provider == .codex || codexRuntimeConfiguration == nil else { throw CodexRuntimeConfiguration.invalid() }
        try codexRuntimeConfiguration?.validate()
        var thread = CodingThread(project: WorkspaceProject(path: FileManager.default.homeDirectoryForCurrentUser.path)); thread.provider = provider
        thread.codexRuntimeConfiguration = codexRuntimeConfiguration
        return try await queryModels(thread: thread, owned: false)
    }
    /// Provider-level CLI account metadata is deliberately never published in a
    /// workspace snapshot, command journal, transcript, or database.
    public func codexAccountSnapshot(configuration: CodexRuntimeConfiguration? = nil) async throws -> CodexAccountSnapshot {
        try configuration?.validate()
        var thread = CodingThread(project: WorkspaceProject(path: FileManager.default.homeDirectoryForCurrentUser.path))
        thread.provider = .codex; thread.codexRuntimeConfiguration = configuration
        return try await queryProviderMetadata(thread: thread, owned: false) { try await $0.codexAccountSnapshot() }
    }
    public func acpConnectionInfo(agent: ACPAgentConfiguration) async throws -> ACPConnectionInfo {
        try agent.validate(); try Task.checkCancellation()
        var thread = CodingThread(project: WorkspaceProject(path: FileManager.default.homeDirectoryForCurrentUser.path))
        thread.provider = .acp; thread.acpAgent = agent
        return try await queryProviderMetadata(thread: thread, owned: false) { try await $0.acpConnectionInfo() }
    }
    public func models(thread: CodingThread) async throws -> [ProviderModel] {
        _ = try await load()
        guard !closing, !stoppingEffects,
              let current = revision.snapshot.threads.first(where: { $0.id == thread.id && $0.projectID == thread.projectID }),
              revision.snapshot.projects.contains(where: { $0.id == thread.projectID }),
              current.provider == thread.provider, current.workspacePath == thread.workspacePath, current.acpAgent == thread.acpAgent, current.openCodeConfiguration?.runtimeIdentity == thread.openCodeConfiguration?.runtimeIdentity, ProviderConfiguration(thread: current).effectiveGrokRuntimeMode == ProviderConfiguration(thread: thread).effectiveGrokRuntimeMode, ProviderConfiguration(thread: current).piRuntimeBinding == ProviderConfiguration(thread: thread).piRuntimeBinding, ProviderConfiguration(thread: current).museRuntimeBinding == ProviderConfiguration(thread: thread).museRuntimeBinding, ProviderConfiguration(thread: current).antigravityRuntimeBinding == ProviderConfiguration(thread: thread).antigravityRuntimeBinding, ProviderConfiguration(thread: current).codexRuntimeBinding == ProviderConfiguration(thread: thread).codexRuntimeBinding, current.claudeRuntimeConfiguration == thread.claudeRuntimeConfiguration else { throw CancellationError() }
        if !revision.snapshot.providerReady(for: current) {
            throw CoincideError("Wait for the workspace to finish preparing before refreshing this agent's models.")
        }
        return try await queryModels(thread: current, owned: true)
    }
    public func openCodeInventory(thread: CodingThread) async throws -> OpenCodeMetadataSnapshot {
        _ = try await load()
        guard !closing, !stoppingEffects, thread.provider == .opencode,
              let current = revision.snapshot.threads.first(where: { $0.id == thread.id && $0.projectID == thread.projectID }),
              current.provider == .opencode, current.workspacePath == thread.workspacePath,
              current.openCodeConfiguration?.runtimeIdentity == thread.openCodeConfiguration?.runtimeIdentity, ProviderConfiguration(thread: current).effectiveGrokRuntimeMode == ProviderConfiguration(thread: thread).effectiveGrokRuntimeMode, ProviderConfiguration(thread: current).piRuntimeBinding == ProviderConfiguration(thread: thread).piRuntimeBinding, ProviderConfiguration(thread: current).museRuntimeBinding == ProviderConfiguration(thread: thread).museRuntimeBinding, ProviderConfiguration(thread: current).antigravityRuntimeBinding == ProviderConfiguration(thread: thread).antigravityRuntimeBinding, ProviderConfiguration(thread: current).codexRuntimeBinding == ProviderConfiguration(thread: thread).codexRuntimeBinding, current.claudeRuntimeConfiguration == thread.claudeRuntimeConfiguration,
              revision.snapshot.providerReady(for: current) else { throw CancellationError() }
        return try await queryProviderMetadata(thread: current, owned: true) { try await $0.openCodeInventory() }
    }
    /// Skills belong to the selected conversation's exact workspace and Codex
    /// account/runtime. Discovery uses a separate metadata connection and never
    /// starts, resumes, or retargets that conversation's active provider actor.
    public func skills(thread: CodingThread, forceReload: Bool = false) async throws -> ProviderSkillInventory {
        _ = try await load(); try Task.checkCancellation()
        guard thread.provider == .codex else { throw ProviderSkillError(.unsupported) }
        guard !closing, !stoppingEffects, fatalError == nil,
              let incarnation = threadIncarnations[thread.id],
              let current = revision.snapshot.threads.first(where: { $0.id == thread.id && $0.projectID == thread.projectID }),
              current.provider == .codex, current.workspacePath == thread.workspacePath,
              ProviderConfiguration(thread: current).codexRuntimeBinding == ProviderConfiguration(thread: thread).codexRuntimeBinding, current.claudeRuntimeConfiguration == thread.claudeRuntimeConfiguration,
              revision.snapshot.providerReady(for: current) else { throw CancellationError() }
        let inventory = try await queryProviderMetadata(thread: current, owned: true) {
            try await $0.codexSkills(forceReload: forceReload)
        }
        try inventory.validate()
        guard threadIncarnations[thread.id] == incarnation else { throw CancellationError() }
        guard CodexSkillInventory.sameWorkspace(inventory.cwd, current.workspacePath) else {
            throw ProviderSkillError(.invalidResponse)
        }
        // Keep the registered path spelling (including a valid symlink alias)
        // after proving that the response names this physical workspace.
        return .init(cwd: current.workspacePath, skills: inventory.skills, problems: inventory.problems, checkedAt: inventory.checkedAt)
    }
    /// Native commands and skills are read on a separate, captured workspace
    /// connection. No active run, resume selection or native session is passed
    /// to that metadata actor, and its exact operation is joined on cancellation.
    public func commands(thread: CodingThread, forceReload: Bool = false) async throws -> ProviderCommandInventory {
        _ = try await load(); try Task.checkCancellation()
        guard [.pi, .opencode, .claude].contains(thread.provider) else { throw ProviderCommandError(.unsupported) }
        guard !closing, !stoppingEffects, fatalError == nil,
              let incarnation = threadIncarnations[thread.id],
              let current = revision.snapshot.threads.first(where: { $0.id == thread.id && $0.projectID == thread.projectID }),
              ProviderConfiguration(thread: current) == ProviderConfiguration(thread: thread),
              revision.snapshot.providerReady(for: current) else { throw CancellationError() }
        let inventory = try await queryProviderMetadata(thread: current, owned: true, joinOperation: true) {
            try await $0.providerCommands(forceReload: forceReload)
        }
        try inventory.validate()
        guard threadIncarnations[thread.id] == incarnation,
              let latest = revision.snapshot.threads.first(where: { $0.id == thread.id && $0.projectID == thread.projectID }),
              ProviderConfiguration(thread: latest) == ProviderConfiguration(thread: current) else { throw CancellationError() }
        guard CodexSkillInventory.sameWorkspace(inventory.cwd, current.workspacePath) else { throw ProviderCommandError(.invalidResponse) }
        return .init(cwd: current.workspacePath, commands: inventory.commands, skills: inventory.skills,
            problems: inventory.problems, checkedAt: inventory.checkedAt)
    }
    private func queryModels(thread: CodingThread, owned: Bool) async throws -> [ProviderModel] {
        try await queryProviderMetadata(thread: thread, owned: owned) { try await $0.models() }
    }
    private func queryProviderMetadata<Value: Sendable>(thread: CodingThread, owned: Bool, joinOperation: Bool = false,
                                                       operation: @escaping @Sendable (any ProviderSession) async throws -> Value) async throws -> Value {
        guard !isCodexAuthenticationLocked(.init(thread: thread)) else { throw Self.codexChanging() }
        guard !isAntigravityAuthenticationLocked(thread) else { throw WorkspaceCommandError("Wait for the Antigravity account change before refreshing models.") }
        if owned {
            if await waitForRemovalCommit(threadID: thread.id, projectID: thread.projectID) { throw CancellationError() }
            guard let current = revision.snapshot.threads.first(where: { $0.id == thread.id && $0.projectID == thread.projectID }),
                  current.provider == thread.provider, current.workspacePath == thread.workspacePath, current.acpAgent == thread.acpAgent, current.openCodeConfiguration?.runtimeIdentity == thread.openCodeConfiguration?.runtimeIdentity, ProviderConfiguration(thread: current).effectiveGrokRuntimeMode == ProviderConfiguration(thread: thread).effectiveGrokRuntimeMode, ProviderConfiguration(thread: current).piRuntimeBinding == ProviderConfiguration(thread: thread).piRuntimeBinding, ProviderConfiguration(thread: current).museRuntimeBinding == ProviderConfiguration(thread: thread).museRuntimeBinding, ProviderConfiguration(thread: current).antigravityRuntimeBinding == ProviderConfiguration(thread: thread).antigravityRuntimeBinding, ProviderConfiguration(thread: current).codexRuntimeBinding == ProviderConfiguration(thread: thread).codexRuntimeBinding, current.claudeRuntimeConfiguration == thread.claudeRuntimeConfiguration,
                  revision.snapshot.providerReady(for: current) else { throw CancellationError() }
        }
        guard !closing, !stoppingEffects, !isCodexAuthenticationLocked(.init(thread: thread)),
              !providerHistoryScopeLocked(configuration: .init(thread: thread), nativeThreadID: thread.providerThreadID),
              !revision.snapshot.isClaudeHistoryScopeLocked(configuration: .init(thread: thread), nativeThreadID: thread.providerThreadID),
              !revision.snapshot.isCheckpointRestoreLocked(path: thread.workspacePath), !revision.snapshot.isPullRequestCreationLocked(path: thread.workspacePath), !revision.snapshot.isPullRequestCheckoutLocked(path: thread.workspacePath) else { throw CancellationError() }
        var metadataLaunch = thread
        if metadataLaunch.provider == .codex || metadataLaunch.provider == .claude || metadataLaunch.provider == .pi || metadataLaunch.provider == .opencode {
            // Metadata owns the original conversation binding, but it must not
            // ask the factory for a live turn's actor or carry its submissions.
            metadataLaunch.activeRun = nil; metadataLaunch.runtimeID = nil
            metadataLaunch.runtimeRequests = []; metadataLaunch.queuedTurns = []
            metadataLaunch.state = .idle
            if metadataLaunch.provider == .pi || metadataLaunch.provider == .opencode || metadataLaunch.provider == .claude {
                metadataLaunch.providerThreadID = nil
                metadataLaunch.piFreshSessionIntent = nil; metadataLaunch.piFreshConsumerRunID = nil
                metadataLaunch.claudeResumeSelection = nil; metadataLaunch.claudeResumeConsumerRunID = nil
            }
        }
        let id = UUID(), session = try factory(metadataLaunch)
        metadataSessions[id] = .init(session: session, path: thread.workspacePath, threadID: owned ? thread.id : nil,
                                     projectID: owned ? thread.projectID : nil, configuration: owned ? .init(thread: thread) : nil,
                                     launchConfiguration: .init(thread: metadataLaunch))
        metadataSessions[id]?.joinsOperation = joinOperation
        do {
            let task = Task { try await operation(session) }
            metadataSessions[id]?.operationCancel = { task.cancel() }
            metadataSessions[id]?.operationDrain = Task { _ = try? await task.value }
            let result = try await withTaskCancellationHandler { try await task.value } onCancel: {
                task.cancel(); Task { [weak self] in await self?.cancelOwnedHistoryRead(id) }
            }
            try Task.checkCancellation()
            if owned, await waitForRemovalCommit(threadID: thread.id, projectID: thread.projectID) { throw CancellationError() }
            guard let metadata = metadataSessions[id], metadataOwnerIsCurrent(metadata) else { throw CancellationError() }
            if let task = beginMetadataClose(id) { await task.value }
            if owned, await waitForRemovalCommit(threadID: thread.id, projectID: thread.projectID) { throw CancellationError() }
            try Task.checkCancellation()
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
            try Task.checkCancellation()
            throw error
        }
    }
    private func metadataOwnerIsCurrent(_ metadata: MetadataRuntime) -> Bool {
        guard !closing, !stoppingEffects, !isCodexAuthenticationLocked(metadata.launchConfiguration) else { return false }
        guard let threadID = metadata.threadID else { return true } // Neutral provider discovery.
        guard let thread = revision.snapshot.threads.first(where: { $0.id == threadID && $0.projectID == metadata.projectID }),
              revision.snapshot.projects.contains(where: { $0.id == thread.projectID }),
              let configuration = metadata.configuration,
              thread.provider == configuration.provider, thread.workspacePath == configuration.workspacePath, thread.acpAgent == configuration.acpAgent, thread.openCodeConfiguration?.runtimeIdentity == configuration.openCodeConfiguration?.runtimeIdentity, ProviderConfiguration(thread: thread).effectiveGrokRuntimeMode == configuration.effectiveGrokRuntimeMode, ProviderConfiguration(thread: thread).piRuntimeBinding == configuration.piRuntimeBinding, ProviderConfiguration(thread: thread).museRuntimeBinding == configuration.museRuntimeBinding, ProviderConfiguration(thread: thread).antigravityRuntimeBinding == configuration.antigravityRuntimeBinding, ProviderConfiguration(thread: thread).codexRuntimeBinding == configuration.codexRuntimeBinding, thread.claudeRuntimeConfiguration == configuration.claudeRuntimeConfiguration,
              revision.snapshot.providerReady(for: thread) else { return false }
        return true
    }
    private func beginMetadataClose(_ id: UUID) -> Task<Void, Never>? {
        guard let metadata = metadataSessions[id] else { return nil }
        if let task = metadata.closeTask { return task }
        metadata.operationCancel?()
        let ownedOperations = (metadata.joinsOperation || metadata.launchConfiguration.ownedCodexInstanceID != nil || metadata.launchConfiguration.claudeRuntimeConfiguration != nil) ? metadata.operationDrain.map { [$0] } ?? [] : []
        let task = startCleanup(projectIDs: Set(metadata.projectID.map { [$0] } ?? []), threadIDs: Set(metadata.threadID.map { [$0] } ?? []), sessions: [metadata.session], jobs: ownedOperations, workspacePaths: [metadata.path], codexInstances: Set(metadata.launchConfiguration.ownedCodexInstanceID.map { [$0] } ?? []), claudeScopes: Self.claudeScopes(metadata.launchConfiguration).union(metadata.configuration.map(Self.claudeScopes) ?? []))
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
        let pullRequestReadJobs = Array(pullRequestReads.values); for read in pullRequestReadJobs { read.cancel() }
        pullRequestCreationReviews = [:]; pullRequestCheckoutReviews = [:]; codexDefaultReviews = [:]
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
        let piCloses = Array(piHistoryJobs.keys).compactMap { beginPiHistoryClose($0) }
        for close in piCloses { await close.value }
        await closeAllProjectScripts()
        for id in Array(runtimes.keys) { await closeRuntime(id) }
        await closeAppMCPServer()
        let metadata = Array(metadataSessions.values); metadataSessions = [:]
        for runtime in metadata { runtime.operationCancel?() }
        for runtime in metadata where runtime.closeTask == nil {
            let ownedOperations = (runtime.joinsOperation || runtime.launchConfiguration.ownedCodexInstanceID != nil || runtime.launchConfiguration.claudeRuntimeConfiguration != nil) ? runtime.operationDrain.map { [$0] } ?? [] : []
            _ = startCleanup(projectIDs: Set(runtime.projectID.map { [$0] } ?? []), threadIDs: Set(runtime.threadID.map { [$0] } ?? []), sessions: [runtime.session], jobs: ownedOperations, workspacePaths: [runtime.path], codexInstances: Set(runtime.launchConfiguration.ownedCodexInstanceID.map { [$0] } ?? []), claudeScopes: Self.claudeScopes(runtime.launchConfiguration).union(runtime.configuration.map(Self.claudeScopes) ?? []))
        }
        for job in jobs { await job.value }
        for read in history { await read.drain.value }
        for read in pullRequestReadJobs { await read.drain.value }
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

extension WorkspaceEngine {
    public func reviewPullRequestCheckout(projectID: UUID, workspacePath: String, reference: GitHubPullRequestReference,
        mode: GitHubPullRequestCheckoutMode, configuration: ProviderConfiguration, checkpointPolicy: RunCheckpointPolicy? = nil,
        title: String? = nil, submodules: ProjectWorktreeSubmoduleMode = .none, reviewSetup: Bool = true,
        busyWorktreePaths: [String] = []) async throws -> PullRequestCheckoutReview {
        _ = try await load(); try Task.checkCancellation()
        for path in busyWorktreePaths { try CheckpointValidation.path(path) }
        if await waitForRemovalCommit(projectID: projectID) { throw CancellationError() }
        guard !closing, !stoppingEffects, fatalError == nil, let project = revision.snapshot.projects.first(where: { $0.id == projectID }),
              let incarnation = projectIncarnations[projectID], revision.snapshot.ownsPullRequestWorkspace(projectID: projectID, workspacePath: workspacePath),
              !revision.snapshot.isPullRequestCreationLocked(path: workspacePath), !revision.snapshot.isPullRequestCheckoutLocked(path: workspacePath),
              !revision.snapshot.isCheckpointRestoreLocked(path: workspacePath) else { throw WorkspaceCommandError("Choose an available registered checkout before importing a pull request.") }
        let initialRequest = GitHubPullRequestCheckoutRequest(sourcePath: workspacePath, destinationRoot: worktreesRoot.path, reference: reference, mode: mode, submodules: submodules)
        let initialSession = try pullRequestCheckoutFactory(initialRequest)
        var plan = try await readPullRequest(projectID: projectID, incarnation: incarnation) { try await initialSession.prepare() }
        let canonical = URL(fileURLWithPath: workspacePath).standardizedFileURL.resolvingSymlinksInPath().path
        guard plan.request == initialRequest, plan.sourcePath == canonical, projectIncarnations[projectID] == incarnation else { throw GitHubPullRequestCheckoutError(.staleReview) }
        let targetBusy = revision.snapshot.pullRequestCheckoutHasBusyOwners(paths: plan.affectedWorkspacePaths) ||
            pullRequestCheckoutHasRuntimeOwners(paths: plan.affectedWorkspacePaths) ||
            busyWorktreePaths.contains { path in plan.affectedWorkspacePaths.contains { WorkspaceSnapshot.checkpointRestorePathsOverlap(path, $0) } }
        if targetBusy, plan.disposition == .reuseWorktree || plan.disposition == .reuseUnrelatedWorktree {
            let readRequest = GitHubPullRequestCheckoutRequest(id: initialRequest.id, sourcePath: workspacePath,
                destinationRoot: worktreesRoot.path, reference: reference, mode: mode, submodules: submodules, policy: .inspectOnly)
            let readSession = try pullRequestCheckoutFactory(readRequest)
            plan = try await readPullRequest(projectID: projectID, incarnation: incarnation) { try await readSession.prepare() }
            guard plan.request == readRequest, plan.sourcePath == canonical, projectIncarnations[projectID] == incarnation else { throw GitHubPullRequestCheckoutError(.staleReview) }
        } else if targetBusy { throw WorkspaceCommandError("Finish work in the affected checkout before changing its files.") }
        var target = configuration; target.nativeThreadID = nil; target.workspacePath = plan.destinationPath
        target.claudeRuntimeConfiguration = try configuration.claudeRuntimeConfiguration?.replacingWorkspace(plan.destinationPath, physicalPath: ClaudeRuntimeValidation.physical(plan.destinationPath, allowMissing: true))
        if let native = configuration.piConfiguration, let runtime = native.runtime {
            target.piConfiguration = .init(instanceID: native.instanceID, executable: native.executable,
                model: native.model, thinkingLevel: native.thinkingLevel,
                runtime: try runtime.replacingWorkspace(plan.destinationPath, physicalPath: PiRuntimeConfiguration.physical(plan.destinationPath, allowMissing: true)))
        }
        target.claudeLaunchSelection = nil
        let review = try PullRequestCheckoutReview(projectID: projectID, projectPath: project.path, registeredWorkspacePath: workspacePath,
            sourceIncarnation: incarnation, targetConfiguration: target, checkpointPolicy: checkpointPolicy,
            title: title ?? plan.pullRequest.title, reviewSetup: reviewSetup, plan: plan)
        let operation = PullRequestCheckoutOperation(review: review)
        var admission = WorkspaceDecision(snapshot: revision.snapshot); try admission.acceptPullRequestCheckout(operation)
        guard pullRequestCheckoutRuntimeScopeAvailable(operation) else { throw WorkspaceCommandError("Finish project scripts before checking out a pull request.") }
        pullRequestCheckoutReviews[review.id] = .init(operation: operation, digest: try pullRequestCheckoutReviewDigest(review))
        return review
    }
    public func discardPullRequestCheckoutReview(reviewID: UUID) {
        guard !acceptingPullRequestCheckouts.contains(reviewID) else { return }; pullRequestCheckoutReviews.removeValue(forKey: reviewID)
    }
    @discardableResult public func beginPullRequestCheckout(review: PullRequestCheckoutReview) async throws -> WorkspaceCommandReceipt {
        _ = try await load(); try Task.checkCancellation(); try review.validate()
        guard !closing, !stoppingEffects, fatalError == nil else { throw CancellationError() }
        if let existing = revision.snapshot.pullRequestCheckout(review.id) {
            guard existing.review == review, let receipt = try await database.receipt(review.id) else { throw GitHubPullRequestCheckoutError(.staleReview) }; return receipt
        }
        guard let prepared = pullRequestCheckoutReviews[review.id], prepared.operation.review == review, prepared.digest == (try pullRequestCheckoutReviewDigest(review)),
              projectIncarnations[review.projectID] == review.sourceIncarnation else { throw GitHubPullRequestCheckoutError(.staleReview) }
        // The effect identity must also be immutable across concurrent acceptance of one token.
        let operation = prepared.operation
        var admission = WorkspaceDecision(snapshot: revision.snapshot); try admission.acceptPullRequestCheckout(operation)
        guard pullRequestCheckoutRuntimeScopeAvailable(operation) else { throw WorkspaceCommandError("Finish project scripts before checking out a pull request.") }
        acceptingPullRequestCheckouts.insert(review.id)
        defer { acceptingPullRequestCheckouts.remove(review.id); pullRequestCheckoutReviews.removeValue(forKey: review.id) }
        let receipt = try await enqueue(.pullRequestCheckoutAccepted(operation), id: review.id)
        if let rejection = receipt.rejection { throw WorkspaceCommandError(rejection) }; return receipt
    }
    @discardableResult public func inspectPullRequestCheckout(operationID: UUID) async throws -> WorkspaceCommandReceipt {
        _ = try await load(); try Task.checkCancellation()
        guard !closing, !stoppingEffects, fatalError == nil, let operation = revision.snapshot.pullRequestCheckout(operationID),
              operation.phase == .unconfirmed, operation.acknowledgedAt == nil, let incarnation = projectIncarnations[operation.projectID] else { throw WorkspaceCommandError("Only an uncertain checkout can be inspected.") }
        try revision.snapshot.validatePullRequestCheckoutSource(operation)
        let session = try pullRequestCheckoutFactory(operation.review.plan.request)
        let result = try await readPullRequest(projectID: operation.projectID, incarnation: incarnation) { try await session.inspectCompletion(operation.review.plan) }
        guard revision.snapshot.pullRequestCheckout(operationID) == operation, projectIncarnations[operation.projectID] == incarnation else { throw CancellationError() }
        let receipt = try await enqueue(.pullRequestCheckoutInspected(operationID: operationID, incarnation: incarnation, result: result))
        if let rejection = receipt.rejection { throw WorkspaceCommandError(rejection) }; return receipt
    }
    @discardableResult public func cancelPullRequestCheckout(operationID: UUID) async throws -> WorkspaceCommandReceipt {
        _ = try await load()
        let receipt = try await enqueue(.pullRequestCheckoutCancel(operationID: operationID))
        if let rejection = receipt.rejection { throw WorkspaceCommandError(rejection) }
        for (id, request) in effectRequests where request.pullRequestCheckoutOperationID == operationID { effects[id]?.cancel() }
        return receipt
    }
    private func pullRequestCheckoutReviewDigest(_ review: PullRequestCheckoutReview) throws -> String {
        SHA256.hash(data: try encoder.encode(review)).map { String(format: "%02x", $0) }.joined()
    }
    private func ownsPullRequestCheckoutEvent(_ command: EngineCommand) -> Bool {
        switch command {
        case .pullRequestCheckoutAccepted(let operation): return projectIncarnations[operation.projectID] == operation.review.sourceIncarnation
        case .pullRequestCheckoutDispatching(let project, _, let incarnation): return projectIncarnations[project] == incarnation
        case .pullRequestCheckoutEffectResult(let request, _, let incarnation): return request.projectID.map { projectIncarnations[$0] == incarnation } ?? false
        case .pullRequestCheckoutInspected(let id, let incarnation, _): return revision.snapshot.pullRequestCheckout(id).map { projectIncarnations[$0.projectID] == incarnation } ?? false
        default: return true
        }
    }
    private func pullRequestCheckoutRuntimeScopeAvailable(_ operation: PullRequestCheckoutOperation) -> Bool {
        !pullRequestCheckoutHasRuntimeOwners(paths: operation.scopePaths)
    }
    private func pullRequestCheckoutHasRuntimeOwners(paths: [String]) -> Bool {
        guard !paths.isEmpty else { return false }
        func overlaps(_ path: String) -> Bool { paths.contains { WorkspaceSnapshot.checkpointRestorePathsOverlap(path, $0) } }
        if scriptRuntimes.values.contains(where: { overlaps($0.path) }) || metadataSessions.values.contains(where: { overlaps($0.path) }) ||
            cleanupTasks.values.contains(where: { $0.workspacePaths.contains(where: overlaps) }) { return true }
        for thread in revision.snapshot.threads {
            let scripts = thread.projectScripts.map { $0.1 } + (thread.workspacePreparation?.previousAttempts.compactMap(\.setup) ?? [])
            if scripts.contains(where: { scriptClosures[$0.id] != nil && overlaps($0.plan?.workspacePath ?? thread.workspacePath) }) { return true }
            for record in thread.runHistory ?? [] {
                guard let checkpoints = record.checkpoints else { continue }
                let attempts = [checkpoints.baseline] + checkpoints.previousPostRunAttempts + (checkpoints.postRun.map { [$0] } ?? [])
                if attempts.contains(where: { attempt in
                    checkpointDrains.values.contains { $0.threadID == thread.id && $0.attemptID == attempt.id } &&
                        (overlaps(attempt.workspacePath) || attempt.plan.map { overlaps($0.repositoryPath) } == true)
                }) { return true }
            }
        }
        return false
    }
    private func drainPullRequestCheckoutOwners(_ operation: PullRequestCheckoutOperation) async {
        let paths = operation.scopePaths
        func overlaps(_ path: String) -> Bool { paths.contains { WorkspaceSnapshot.checkpointRestorePathsOverlap(path, $0) } }
        for id in runtimes.filter({ overlaps($0.value.path) }).map(\.key) { await closeRuntime(id) }
        for id in metadataSessions.filter({ overlaps($0.value.path) }).map(\.key) {
            if let task = beginMetadataClose(id) { await task.value }; metadataSessions.removeValue(forKey: id)
        }
        for thread in revision.snapshot.threads where thread.pullRequestCheckoutWorkspacePaths.contains(where: overlaps) { await awaitCheckpointDrains(threadID: thread.id) }
        let jobs = cleanupTasks.values.filter { $0.workspacePaths.contains(where: overlaps) }.map(\.task)
        for job in jobs { await job.value }
    }
    private func performPullRequestCheckout(_ request: WorkspaceEffectRequest) async throws -> EffectResult {
        guard case .pullRequestCheckout(let projectID, let operationID, let effectID) = request,
              let operation = revision.snapshot.pullRequestCheckout(operationID), operation.phase == .accepted, operation.effectID == effectID,
              operation.projectID == projectID, projectIncarnations[projectID] == operation.review.sourceIncarnation else { return .cancelled }
        var dispatched = false
        var returnedResult = false
        do {
            try revision.snapshot.validatePullRequestCheckoutSource(operation)
            try revision.snapshot.validatePullRequestCheckoutTarget(operation)
            guard pullRequestCheckoutRuntimeScopeAvailable(operation), !revision.snapshot.pullRequestCheckoutHasBusyOwners(paths: operation.scopePaths) else { throw GitHubPullRequestCheckoutError(.staleReview) }
            await drainPullRequestCheckoutOwners(operation); try Task.checkCancellation()
            try revision.snapshot.validatePullRequestCheckoutSource(operation)
            try revision.snapshot.validatePullRequestCheckoutTarget(operation)
            guard projectIncarnations[projectID] == operation.review.sourceIncarnation, pullRequestCheckoutRuntimeScopeAvailable(operation),
                  !revision.snapshot.pullRequestCheckoutHasBusyOwners(paths: operation.scopePaths) else { throw GitHubPullRequestCheckoutError(.staleReview) }
            let session = try pullRequestCheckoutFactory(operation.review.plan.request)
            let receipt = try await enqueue(.pullRequestCheckoutDispatching(projectID: projectID, operationID: operationID, incarnation: operation.review.sourceIncarnation))
            guard receipt.rejection == nil, revision.snapshot.pullRequestCheckout(operationID)?.phase == .dispatching,
                  projectIncarnations[projectID] == operation.review.sourceIncarnation else { throw GitHubPullRequestCheckoutError(.staleReview) }
            try Task.checkCancellation(); dispatched = true
            let result = try await session.run(operation.review.plan); returnedResult = true
            try operation.validateResult(result)
            return .pullRequestCheckoutCompleted(result)
        } catch {
            if operation.review.plan.isReadOnly { return .failed(PullRequestCheckoutOperation.failureMessage) }
            if dispatched, let session = try? pullRequestCheckoutFactory(operation.review.plan.request),
               let inspection = try? await Task.detached(operation: { try await session.inspectCompletion(operation.review.plan) }).value,
               case .completed(let result) = inspection, (try? operation.validateResult(result)) != nil { return .pullRequestCheckoutCompleted(result) }
            if returnedResult { return .pullRequestCheckoutUnconfirmed }
            if let typed = error as? GitHubPullRequestCheckoutError { return typed.mayHaveMutated ? .pullRequestCheckoutUnconfirmed : .failed(PullRequestCheckoutOperation.failureMessage) }
            return dispatched ? .pullRequestCheckoutUnconfirmed : .failed(PullRequestCheckoutOperation.failureMessage)
        }
    }

    public func reviewPullRequestCreation(projectID: UUID, workspacePath: String, title: String, body: String,
                                          baseBranch: String?, isDraft: Bool) async throws -> GitHubPullRequestCreateReview {
        _ = try await load(); try Task.checkCancellation()
        if await waitForRemovalCommit(projectID: projectID) { throw CancellationError() }
        guard !closing, !stoppingEffects, fatalError == nil,
              let project = revision.snapshot.projects.first(where: { $0.id == projectID }),
              let incarnation = projectIncarnations[projectID],
              revision.snapshot.ownsPullRequestWorkspace(projectID: projectID, workspacePath: workspacePath),
              !revision.snapshot.isPullRequestCreationLocked(path: workspacePath),
              !revision.snapshot.isCheckpointRestoreLocked(path: workspacePath) else {
            throw WorkspaceCommandError("Choose an available registered project checkout before reviewing a pull request.")
        }
        let session = try pullRequestFactory(URL(fileURLWithPath: workspacePath))
        let review = try await readPullRequest(projectID: projectID, incarnation: incarnation) {
            try await session.reviewCreate(title: title, body: body, baseBranch: baseBranch, isDraft: isDraft)
        }
        let canonical = URL(fileURLWithPath: workspacePath).standardizedFileURL.resolvingSymlinksInPath().path
        guard review.context.workspacePath == canonical,
              projectIncarnations[projectID] == incarnation else { throw GitHubPullRequestError(.staleReview) }
        let operation = PullRequestCreationOperation(projectID: projectID, projectPath: project.path, sourceIncarnation: incarnation,
            review: review, registeredWorkspacePath: workspacePath)
        var admission = WorkspaceDecision(snapshot: revision.snapshot)
        try admission.acceptPullRequestCreation(operation)
        guard pullRequestRuntimeScopeAvailable(operation) else { throw WorkspaceCommandError("Finish workspace scripts and closing jobs before creating a pull request.") }
        pullRequestCreationReviews[review.id] = .init(operation: operation, digest: try pullRequestReviewDigest(review))
        return review
    }
    public func discardPullRequestCreationReview(reviewID: UUID) {
        guard !acceptingPullRequestCreations.contains(reviewID) else { return }
        pullRequestCreationReviews.removeValue(forKey: reviewID)
    }
    @discardableResult public func beginPullRequestCreation(projectID: UUID, review: GitHubPullRequestCreateReview) async throws -> WorkspaceCommandReceipt {
        _ = try await load(); try Task.checkCancellation(); try review.validate()
        guard !closing, !stoppingEffects, fatalError == nil else { throw CancellationError() }
        if let existing = revision.snapshot.pullRequestCreation(review.id) {
            guard existing.projectID == projectID, existing.review == review, let receipt = try await database.receipt(review.id) else { throw GitHubPullRequestError(.staleReview) }
            return receipt
        }
        guard let prepared = pullRequestCreationReviews[review.id], prepared.operation.projectID == projectID,
              prepared.digest == (try pullRequestReviewDigest(review)),
              projectIncarnations[projectID] == prepared.operation.sourceIncarnation else { throw GitHubPullRequestError(.staleReview) }
        var admission = WorkspaceDecision(snapshot: revision.snapshot); try admission.acceptPullRequestCreation(prepared.operation)
        guard pullRequestRuntimeScopeAvailable(prepared.operation) else { throw WorkspaceCommandError("Finish workspace scripts and closing jobs before creating a pull request.") }
        acceptingPullRequestCreations.insert(review.id)
        defer { acceptingPullRequestCreations.remove(review.id); pullRequestCreationReviews.removeValue(forKey: review.id) }
        let receipt = try await enqueue(.pullRequestCreationAccepted(prepared.operation), id: review.id)
        if let rejection = receipt.rejection { throw WorkspaceCommandError(rejection) }
        return receipt
    }
    @discardableResult public func reconcilePullRequestCreation(operationID: UUID) async throws -> WorkspaceCommandReceipt {
        _ = try await load(); try Task.checkCancellation()
        guard !closing, !stoppingEffects, fatalError == nil,
              let operation = revision.snapshot.pullRequestCreation(operationID), operation.phase == .unconfirmed,
              operation.acknowledgedAt == nil, let incarnation = projectIncarnations[operation.projectID] else {
            throw WorkspaceCommandError("Only an uncertain pull request creation can be refreshed.")
        }
        try revision.snapshot.validatePullRequestCreationSource(operation)
        let session = try pullRequestFactory(URL(fileURLWithPath: operation.workspacePath))
        let result = try await readPullRequest(projectID: operation.projectID, incarnation: incarnation) { try await session.reconcileCreate(operation.review) }
        guard revision.snapshot.pullRequestCreation(operationID) == operation,
              projectIncarnations[operation.projectID] == incarnation else { throw GitHubPullRequestError(.staleReview) }
        let receipt = try await enqueue(.pullRequestCreationReconciled(operationID: operationID, incarnation: incarnation, result: result))
        if let rejection = receipt.rejection { throw WorkspaceCommandError(rejection) }
        return receipt
    }
    private func pullRequestReviewDigest(_ review: GitHubPullRequestCreateReview) throws -> String {
        SHA256.hash(data: try encoder.encode(review)).map { String(format: "%02x", $0) }.joined()
    }
    private func readPullRequest<Value: Sendable>(projectID: UUID, incarnation: UUID,
        operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        guard !closing, !stoppingEffects, fatalError == nil, projectIncarnations[projectID] == incarnation else { throw CancellationError() }
        let token = UUID(), task = Task { try await operation() }, drain = Task<Void, Never> { _ = try? await task.value }
        pullRequestReads[token] = .init(projectID: projectID, drain: drain, cancel: { task.cancel() })
        defer { pullRequestReads.removeValue(forKey: token) }
        return try await withTaskCancellationHandler {
            let result = try await task.value; try Task.checkCancellation()
            guard !closing, !stoppingEffects, fatalError == nil, projectIncarnations[projectID] == incarnation else { throw CancellationError() }
            return result
        } onCancel: { task.cancel() }
    }
    private func ownsPullRequestCreationEvent(_ command: EngineCommand) -> Bool {
        switch command {
        case .pullRequestCreationAccepted(let operation): return projectIncarnations[operation.projectID] == operation.sourceIncarnation
        case .pullRequestCreationDispatching(let projectID, _, let incarnation): return projectIncarnations[projectID] == incarnation
        case .pullRequestCreationEffectResult(let request, _, let incarnation): return request.projectID.map { projectIncarnations[$0] == incarnation } ?? false
        case .pullRequestCreationReconciled(let id, let incarnation, _):
            return revision.snapshot.pullRequestCreation(id).map { projectIncarnations[$0.projectID] == incarnation } ?? false
        default: return true
        }
    }
    private func pullRequestRuntimeScopeAvailable(_ operation: PullRequestCreationOperation) -> Bool {
        !scriptRuntimes.values.contains { runtime in
            guard let thread = revision.snapshot.threads.first(where: { $0.id == runtime.threadID }) else { return true }
            return thread.projectID == operation.projectID || thread.pullRequestCreationScopePaths.contains { path in operation.scopePaths.contains { WorkspaceSnapshot.checkpointRestorePathsOverlap(path, $0) } }
        }
    }
    private func drainPullRequestOwners(_ operation: PullRequestCreationOperation) async {
        let paths = operation.scopePaths
        func overlaps(_ path: String) -> Bool { paths.contains { WorkspaceSnapshot.checkpointRestorePathsOverlap(path, $0) } }
        for id in runtimes.filter({ $0.value.projectID == operation.projectID || overlaps($0.value.path) }).map(\.key) { await closeRuntime(id) }
        for id in metadataSessions.filter({ $0.value.projectID == operation.projectID || overlaps($0.value.path) }).map(\.key) {
            if let task = beginMetadataClose(id) { await task.value }; metadataSessions.removeValue(forKey: id)
        }
        let sourceThreads = revision.snapshot.threads.filter { $0.projectID == operation.projectID || $0.pullRequestCreationScopePaths.contains(where: overlaps) }
        for thread in sourceThreads { await awaitCheckpointDrains(threadID: thread.id) }
        let jobs = cleanupTasks.values.filter { $0.projectIDs.contains(operation.projectID) || $0.workspacePaths.contains(where: overlaps) }.map(\.task)
        for job in jobs { await job.value }
    }
    private func performPullRequestCreation(_ request: WorkspaceEffectRequest) async throws -> EffectResult {
        guard case .pullRequestCreation(let projectID, let operationID, let effectID) = request,
              let operation = revision.snapshot.pullRequestCreation(operationID), operation.phase == .accepted,
              operation.projectID == projectID, operation.effectID == effectID,
              projectIncarnations[projectID] == operation.sourceIncarnation else { return .cancelled }
        var apiStarted = false
        do {
            try revision.snapshot.validatePullRequestCreationSource(operation)
            guard pullRequestRuntimeScopeAvailable(operation) else { throw GitHubPullRequestError(.staleReview) }
            await drainPullRequestOwners(operation); try Task.checkCancellation()
            try revision.snapshot.validatePullRequestCreationSource(operation)
            guard projectIncarnations[projectID] == operation.sourceIncarnation, pullRequestRuntimeScopeAvailable(operation) else { throw GitHubPullRequestError(.staleReview) }
            let session = try pullRequestFactory(URL(fileURLWithPath: operation.workspacePath))
            let receipt = try await enqueue(.pullRequestCreationDispatching(projectID: projectID, operationID: operationID, incarnation: operation.sourceIncarnation))
            guard receipt.rejection == nil, revision.snapshot.pullRequestCreation(operationID)?.phase == .dispatching,
                  projectIncarnations[projectID] == operation.sourceIncarnation else { throw GitHubPullRequestError(.staleReview) }
            try Task.checkCancellation(); apiStarted = true
            let outcome = try await session.create(operation.review)
            guard projectIncarnations[projectID] == operation.sourceIncarnation else { return .pullRequestCreationUnconfirmed }
            var completed = operation
            switch outcome { case .created: completed.phase = .created; case .openedExisting: completed.phase = .openedExisting }
            completed.result = outcome; try completed.validate()
            return .pullRequestCreationConfirmed(outcome)
        } catch let error as GitHubPullRequestError {
            return error.mayHaveCreated ? .pullRequestCreationUnconfirmed : .failed(PullRequestCreationOperation.failureMessage)
        } catch { return apiStarted ? .pullRequestCreationUnconfirmed : .failed(PullRequestCreationOperation.failureMessage) }
    }
}

extension WorkspaceEngine {
    private func isCodexAuthenticationLocked(_ configuration: ProviderConfiguration) -> Bool {
        configuration.ownedCodexInstanceID.map { codexAuthenticationLeases[$0] != nil } ?? false
    }
    private func isCodexAuthenticationLocked(_ thread: CodingThread) -> Bool {
        isCodexAuthenticationLocked(.init(thread: thread)) || thread.activeRun.map { isCodexAuthenticationLocked($0.configuration) } == true
    }
    private func validateCodexAuthenticationAdmission(_ command: EngineCommand, snapshot: WorkspaceSnapshot) throws {
        var configurations: [ProviderConfiguration] = []
        switch command {
        case .client(.submit(let id, _)), .client(.submitFromAppMCP(let id, _, _)):
            if let thread = snapshot.threads.first(where: { $0.id == id }) {
                let capture = ProviderConfiguration(thread: thread); configurations = [capture]
                if capture.ownedCodexInstanceID != nil, capture.codexRuntimeBinding?.accountBinding == nil {
                    throw WorkspaceCommandError(CodexAccountError.signInRequired.localizedDescription)
                }
            }
        case .client(.resumeQueue(let id)):
            if let thread = snapshot.threads.first(where: { $0.id == id }), let first = thread.queuedTurns.first {
                configurations = [first.configuration]
                if first.configuration.ownedCodexInstanceID != nil,
                   first.configuration.codexRuntimeBinding != ProviderConfiguration(thread: thread).codexRuntimeBinding {
                    throw WorkspaceCommandError("This queued message belongs to an earlier Codex account. Edit it to review and send with the current account. Its original input was kept.")
                }
            }
        case .client(.respond(let id, _, _)):
            if let thread = snapshot.threads.first(where: { $0.id == id }) {
                if let active = thread.activeRun { configurations = [active.configuration] }
                else if let binding = runtimes[id]?.codexBinding {
                    var actual = ProviderConfiguration(thread: thread); actual.provider = .codex; actual.codexRuntimeConfiguration = binding; configurations = [actual]
                }
            }
        case .client(.editThread(let id, let edit)):
            switch edit {
            case .draft, .title, .pinned, .archived: return
            default:
                if codexAuthenticationOwners.values.contains(where: { $0.contains(id) }) { throw Self.codexChanging() }
                if let thread = snapshot.threads.first(where: { $0.id == id }) { configurations = [.init(thread: thread)] + [thread.activeRun?.configuration].compactMap { $0 } }
                let target: CodexRuntimeConfiguration?
                switch edit {
                case .codexRuntimeConfiguration(let value), .codexProvider(let value): target = value
                default: target = nil
                }
                if let target {
                    var value = ProviderConfiguration(thread: CodingThread(project: WorkspaceProject(path: "/")))
                    value.provider = .codex; value.codexRuntimeConfiguration = target; configurations.append(value)
                }
            }
        case .promptSteeringAccepted(let operation): configurations = [operation.configuration]
        case .conversationHistoryAccepted(let review, _): configurations = [review.sourceConfiguration, review.targetConfiguration]
        case .provider(let id, let runtimeID, _):
            if let runtime = runtimes[id], runtime.id == runtimeID, let binding = runtime.codexBinding,
               binding.authenticationMode == .ownedChatGPT, codexAuthenticationLeases[binding.instanceID] != nil { throw Self.codexChanging() }
        default: return
        }
        guard !configurations.contains(where: isCodexAuthenticationLocked) else { throw Self.codexChanging() }
    }
    private static func codexChanging() -> WorkspaceCommandError {
        .init("Wait for the Codex account change before sending or changing provider settings. Drafts and queued messages were kept.")
    }
    public func beginCodexAuthentication(configuration: CodexRuntimeConfiguration) async throws -> UUID {
        try configuration.validate()
        guard configuration.authenticationMode == .ownedChatGPT else { throw CodexRuntimeConfiguration.invalid() }
        _ = try await load(); try Task.checkCancellation()
        let instanceID = configuration.instanceID
        guard !closing, !stoppingEffects, fatalError == nil, codexAuthenticationLeases[instanceID] == nil else { throw Self.codexChanging() }
        var actualOwners = Set(runtimes.compactMap { id, runtime in
            runtime.codexBinding.flatMap { $0.authenticationMode == .ownedChatGPT && $0.instanceID == instanceID ? id : nil }
        })
        for metadata in metadataSessions.values where metadata.launchConfiguration.ownedCodexInstanceID == instanceID {
            if let id = metadata.threadID { actualOwners.insert(id) }
        }
        for request in effectRequests.values {
            if case .providerStart(let id, _, let capture, _, _) = request, capture.ownedCodexInstanceID == instanceID { actualOwners.insert(id) }
        }
        let affected = revision.snapshot.threads.filter { $0.ownedCodexInstances.contains(instanceID) || actualOwners.contains($0.id) }
        guard affected.allSatisfy({ !revision.snapshot.isConversationHistoryLocked(threadID: $0.id) && !revision.snapshot.isCheckpointRestoreLocked(path: $0.workspacePath) && !revision.snapshot.isPullRequestCreationLocked(path: $0.workspacePath) && !revision.snapshot.isPullRequestCheckoutLocked(path: $0.workspacePath) }) else {
            throw WorkspaceCommandError("Finish Codex history and workspace operations before changing the account.")
        }
        let leaseID = UUID()
        codexAuthenticationLeases[instanceID] = leaseID
        codexAuthenticationOwners[instanceID] = Set(affected.map(\.id)).union(actualOwners)
        do {
            let receipt = try await enqueue(.codexAuthenticationPreparing(instanceID: instanceID, threadIDs: actualOwners))
            if let rejection = receipt.rejection { throw WorkspaceCommandError(rejection) }
            historyReviews = historyReviews.filter { $0.value.review.sourceConfiguration.ownedCodexInstanceID != instanceID && $0.value.review.targetConfiguration.ownedCodexInstanceID != instanceID }
            codexDefaultReviews = codexDefaultReviews.filter { $0.value.configuration.ownedCodexInstanceID != instanceID }
            let reads = historyReads.filter { $0.value.configuration.ownedCodexInstanceID == instanceID }
            for read in reads.values { read.cancel() }
            let metadata = metadataSessions.filter { $0.value.launchConfiguration.ownedCodexInstanceID == instanceID }
            var closes: [Task<Void, Never>] = []
            for id in metadata.keys { if let task = beginMetadataClose(id) { closes.append(task) } }
            let providerJobs = effectRequests.compactMap { id, request -> Task<Void, Never>? in
                let matches: Bool
                switch request {
                case .providerStart(_, _, let captured, _, _): matches = captured.ownedCodexInstanceID == instanceID
                case .providerRespond(let threadID, _, _, _), .providerSessionRespond(let threadID, _, _, _), .promptSteering(let threadID, _): matches = actualOwners.contains(threadID)
                default: matches = false
                }
                guard matches, let task = effects[id] else { return nil }; task.cancel(); return task
            }
            for task in closes { await task.value }
            for read in reads.values { await read.drain.value }
            for task in providerJobs { await task.value }
            for id in metadata.keys { metadataSessions.removeValue(forKey: id) }
            while true {
                let cleanups = cleanupTasks.values.filter { $0.codexInstances.contains(instanceID) }.map(\.task)
                if cleanups.isEmpty { break }; for task in cleanups { await task.value }
            }
            try Task.checkCancellation()
            guard !closing, !stoppingEffects, fatalError == nil, codexAuthenticationLeases[instanceID] == leaseID else { throw CancellationError() }
            return leaseID
        } catch {
            if codexAuthenticationLeases[instanceID] == leaseID {
                codexAuthenticationLeases.removeValue(forKey: instanceID); codexAuthenticationOwners.removeValue(forKey: instanceID)
            }
            throw error
        }
    }
    public func endCodexAuthentication(leaseID: UUID) async {
        guard let instance = codexAuthenticationLeases.first(where: { $0.value == leaseID })?.key else { return }
        codexAuthenticationLeases.removeValue(forKey: instance); codexAuthenticationOwners.removeValue(forKey: instance)
    }
    public func applyCodexAccountBinding(instanceID: UUID, binding: CodexAccountBinding?, leaseID: UUID) async throws {
        guard codexAuthenticationLeases[instanceID] == leaseID, !closing, !stoppingEffects, fatalError == nil else { throw Self.codexChanging() }
        let receipt = try await enqueue(.codexAccountConfigured(instanceID: instanceID, binding: binding))
        if let rejection = receipt.rejection { throw WorkspaceCommandError(rejection) }
    }
}

extension WorkspaceEngine {
    private func providerHistoryScopeLocked(configuration: ProviderConfiguration, nativeThreadID: String?) -> Bool {
        revision.snapshot.isOpenCodeHistoryScopeLocked(configuration: configuration, nativeThreadID: nativeThreadID) ||
            revision.snapshot.isClaudeHistoryScopeLocked(configuration: configuration, nativeThreadID: nativeThreadID) ||
            revision.snapshot.isPiHistoryScopeLocked(configuration: configuration, nativeThreadID: nativeThreadID)
    }

    private static func claudeScopes(_ configuration: ProviderConfiguration) -> Set<ClaudeHistoryScope> {
        guard configuration.provider == .claude, let runtime = configuration.claudeRuntimeConfiguration,
              let native = configuration.nativeThreadID ?? configuration.claudeLaunchSelection?.nativeSessionID else { return [] }
        return [.init(configurationDirectory: runtime.configurationDirectory, nativeSessionID: native)]
    }

    private func claudeRuntimeMatches(_ runtime: Runtime, thread: CodingThread) -> Bool {
        guard thread.provider == .claude else { return runtime.claudeConfiguration == nil }
        return runtime.claudeConfiguration == thread.claudeRuntimeConfiguration &&
            runtime.claudeLaunchSelection == thread.activeRun?.configuration.claudeLaunchSelection &&
            (runtime.claudeNativeID == nil || runtime.claudeNativeID == thread.providerThreadID)
    }

    /// The native namespace is the physical configuration root and session UUID.
    /// Different executable, cwd or registered alias spellings cannot escape it.
    private func claudeHistoryScopeIsolated(thread: CodingThread, additionalNativeIDs: Set<String> = []) -> Bool {
        guard thread.provider == .claude, let runtime = thread.claudeRuntimeConfiguration,
              let native = thread.providerThreadID else { return false }
        let ids = Set(additionalNativeIDs.union([native]).map { $0.lowercased() })
        func captured(_ configuration: ProviderConfiguration) -> Bool {
            configuration.provider == .claude && configuration.claudeRuntimeConfiguration?.configurationDirectory == runtime.configurationDirectory &&
                (configuration.nativeThreadID ?? configuration.claudeLaunchSelection?.nativeSessionID).map { ids.contains($0.lowercased()) } == true
        }
        for other in revision.snapshot.threads where other.id != thread.id {
            if captured(.init(thread: other)) || other.queuedTurns.contains(where: { captured($0.configuration) }) { return false }
            if let run = other.activeRun {
                var configuration = run.configuration
                configuration.nativeThreadID = configuration.nativeThreadID ?? other.runHistory?.first(where: { $0.id == run.id })?.providerThreadID
                if captured(configuration) { return false }
            }
        }
        if metadataSessions.values.contains(where: {
            $0.threadID != thread.id && (captured($0.launchConfiguration) || $0.configuration.map(captured) == true)
        }) || historyReads.values.contains(where: { $0.threadID != thread.id && captured($0.configuration) }) { return false }
        for (id, owner) in runtimes where id != thread.id && owner.provider == .claude &&
            owner.claudeConfiguration?.configurationDirectory == runtime.configurationDirectory {
            if owner.claudeNativeID.map({ ids.contains($0.lowercased()) }) == true { return false }
        }
        return !cleanupTasks.values.contains { cleanup in
            cleanup.claudeScopes.contains { $0.configurationDirectory == runtime.configurationDirectory && ids.contains($0.nativeSessionID.lowercased()) }
        }
    }

    /// All native transcript work is bounded Swift I/O, tracked and drained with
    /// its thread. History never starts a provider or sends a hidden prompt.
    private func readClaudeHistory<Value: Sendable>(thread: CodingThread,
        operation: @escaping @Sendable (ClaudeHistoryService) async throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        guard !closing, !stoppingEffects, fatalError == nil, let configuration = thread.claudeRuntimeConfiguration,
              let incarnation = threadIncarnations[thread.id], claudeHistoryScopeIsolated(thread: thread) else { throw ProviderHistoryError(.notIdle) }
        let service = try ClaudeHistoryService(configuration: configuration), token = UUID()
        let task = Task.detached { try Task.checkCancellation(); return try await operation(service) }
        historyReads[token] = .init(threadID: thread.id, projectID: thread.projectID,
            drain: Task { _ = try? await task.value }, cancel: { task.cancel() }, configuration: .init(thread: thread))
        defer { historyReads.removeValue(forKey: token) }
        do {
            let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try Task.checkCancellation()
            guard !closing, !stoppingEffects, fatalError == nil, threadIncarnations[thread.id] == incarnation,
                  revision.snapshot.threads.first(where: { $0.id == thread.id })?.claudeRuntimeConfiguration == configuration,
                  claudeHistoryScopeIsolated(thread: thread) else { throw ProviderHistoryError(.historyChanged) }
            return result
        } catch {
            task.cancel(); _ = try? await task.value
            throw error
        }
    }

    private func drainClaudeHistoryOwners(thread: CodingThread) async throws {
        if let runtime = runtimes[thread.id] { await closeRuntime(thread.id, matching: runtime.id) }
        for id in metadataSessions.keys.filter({ metadataSessions[$0]?.threadID == thread.id }) {
            if let task = beginMetadataClose(id) { await task.value }
            metadataSessions.removeValue(forKey: id)
        }
        let reads = historyReads.values.filter { $0.threadID == thread.id }
        for read in reads { read.cancel() }
        for read in reads { await read.drain.value }
        guard let configuration = thread.claudeRuntimeConfiguration else { throw ClaudeRuntimeConfiguration.invalid() }
        while true {
            try Task.checkCancellation()
            guard !closing, !stoppingEffects, fatalError == nil else { throw CancellationError() }
            let tasks = cleanupTasks.values.filter { cleanup in
                cleanup.threadIDs.contains(thread.id) || cleanup.claudeScopes.contains {
                    $0.configurationDirectory == configuration.configurationDirectory && $0.nativeSessionID.lowercased() == thread.providerThreadID?.lowercased()
                }
            }.map(\.task)
            if tasks.isEmpty { return }
            for task in tasks { await task.value }
        }
    }

    private func performClaudeConversationHistory(_ request: WorkspaceEffectRequest, operation: ConversationHistoryOperation,
                                                  thread: CodingThread, incarnation: UUID) async -> EffectResult {
        let review = operation.review
        guard let evidence = review.claude else { return .failed(ConversationHistoryOperation.failureMessage) }
        var dispatched = false
        do {
            try await drainClaudeHistoryOwners(thread: thread)
            guard ownsHistorySource(threadID: thread.id, incarnation: incarnation, fingerprint: review.sourceFingerprint),
                  revision.snapshot.conversationHistoryOperation(operation.id) == operation,
                  claudeHistoryScopeIsolated(thread: thread) else { throw ProviderHistoryError(.historyChanged) }
            if let files = review.files {
                try revision.snapshot.validateConversationHistoryFilesReview(review, excludingOperationID: operation.id)
                guard restoreRuntimeScopeIsolated(thread: thread, path: files.gitReview.currentPlan.repositoryPath),
                      try await readCheckpointRestore(thread: thread, operation: { try await $0.inspectRestore(review: files.gitReview) }) == .notStarted else {
                    throw ProviderHistoryError(.historyChanged)
                }
            }
            let receipt = try await enqueue(.conversationHistoryDispatching(threadID: thread.id, operationID: operation.id, incarnation: incarnation))
            guard receipt.rejection == nil, ownsHistorySource(threadID: thread.id, incarnation: incarnation, fingerprint: review.sourceFingerprint),
                  revision.snapshot.conversationHistoryOperation(operation.id)?.phase == .dispatching,
                  claudeHistoryScopeIsolated(thread: thread) else { throw ProviderHistoryError(.historyChanged) }
            dispatched = true
            let result = try await readClaudeHistory(thread: thread) { [self] service in
                if review.kind == .rewindBeforeRun { return try service.prepareRewind(review: evidence, selectionID: review.id) }
                let plan = try service.prepareFork(review: evidence, targetSessionID: UUID().uuidString.lowercased())
                return try await service.publishFork(plan) { publication in
                    try await self.reserveClaudeFork(publication, review: review, incarnation: incarnation)
                }
            }
            guard ownsHistorySource(threadID: thread.id, incarnation: incarnation, fingerprint: review.sourceFingerprint),
                  claudeHistoryScopeIsolated(thread: thread, additionalNativeIDs: [result.reference.nativeThreadID]) else { throw ProviderHistoryError(.outcomeUncertain) }
            let snapshot = try ProviderConversationSnapshot(reference: result.reference, workspacePath: result.workspacePath,
                historyMode: .nativeTranscript, claude: result)
            try review.validateResult(snapshot)
            return .conversationHistoryConfirmed(snapshot)
        } catch {
            // Once a publication was reserved, preserve its exact name and bytes
            // for inspection. An inspection never retries the write.
            if revision.snapshot.conversationHistoryOperation(operation.id)?.claudeForkPublication != nil ||
                (dispatched && error is CancellationError) { return .conversationHistoryUnconfirmed }
            return .failed(ConversationHistoryOperation.failureMessage)
        }
    }

    private func reserveClaudeFork(_ publication: ClaudeTranscriptPublication, review: ConversationHistoryReview, incarnation: UUID) async throws {
        guard ownsHistorySource(threadID: review.sourceThreadID, incarnation: incarnation, fingerprint: review.sourceFingerprint),
              let thread = revision.snapshot.threads.first(where: { $0.id == review.sourceThreadID }),
              claudeHistoryScopeIsolated(thread: thread, additionalNativeIDs: [publication.target.sessionID]) else { throw ProviderHistoryError(.notIdle) }
        let receipt = try await enqueue(.conversationHistoryClaudeForkReserved(operationID: review.id, publication: publication, incarnation: incarnation))
        guard receipt.rejection == nil, ownsHistorySource(threadID: thread.id, incarnation: incarnation, fingerprint: review.sourceFingerprint),
              revision.snapshot.conversationHistoryOperation(review.id)?.claudeForkPublication == publication,
              claudeHistoryScopeIsolated(thread: thread, additionalNativeIDs: [publication.target.sessionID]) else { throw ProviderHistoryError(.outcomeUncertain) }
    }

    private func reconcileClaudeHistory(operation: ConversationHistoryOperation, thread: CodingThread, incarnation: UUID) async throws -> WorkspaceCommandReceipt {
        guard let evidence = operation.review.claude else { throw ProviderHistoryError(.outcomeUncertain) }
        let publication = operation.claudeForkPublication
        try await drainClaudeHistoryOwners(thread: thread)
        let result: ConversationHistoryReconciliation = try await readClaudeHistory(thread: thread) { service in
            if evidence.kind == .rewindBeforeRun {
                let selected = try service.prepareRewind(review: evidence, selectionID: operation.review.id)
                return .applied(try .init(reference: selected.reference, workspacePath: selected.workspacePath, historyMode: .nativeTranscript, claude: selected))
            }
            guard let publication else { throw ProviderHistoryError(.outcomeUncertain) }
            switch try service.inspectFork(review: evidence, publication: publication) {
            case .ready(let result):
                return .applied(try .init(reference: result.reference, workspacePath: result.workspacePath, historyMode: .nativeTranscript, claude: result))
            case .notStarted:
                return .claudeForkNotStarted(try service.snapshot(sessionID: evidence.source.reference.nativeThreadID, selection: evidence.source.selection))
            case .incomplete: throw ProviderHistoryError(.outcomeUncertain)
            }
        }
        guard ownsHistorySource(threadID: thread.id, incarnation: incarnation, fingerprint: operation.review.sourceFingerprint),
              revision.snapshot.conversationHistoryOperation(operation.id) == operation,
              claudeHistoryScopeIsolated(thread: thread, additionalNativeIDs: Set(publication.map { [$0.target.sessionID] } ?? [])) else { throw ProviderHistoryError(.historyChanged) }
        let receipt = try await enqueue(.conversationHistoryReconciled(operationID: operation.id, incarnation: incarnation, result: result))
        if let rejection = receipt.rejection { throw WorkspaceCommandError(rejection) }
        return receipt
    }

    @discardableResult public func reconcileClaudeResumeSelection(threadID: UUID) async throws -> WorkspaceCommandReceipt {
        _ = try await load(); try Task.checkCancellation()
        guard !closing, !stoppingEffects, fatalError == nil,
              revision.snapshot.claudeResumeSelectionNeedsInspection(threadID: threadID),
              let thread = revision.snapshot.threads.first(where: { $0.id == threadID }),
              let configuration = thread.claudeRuntimeConfiguration, let selection = thread.claudeResumeSelection,
              let run = thread.runHistory?.first(where: { $0.id == thread.claudeResumeConsumerRunID }),
              let incarnation = threadIncarnations[threadID] else { throw ProviderHistoryError(.notIdle) }
        try await drainClaudeHistoryOwners(thread: thread)
        let result = try await readClaudeHistory(thread: thread) { _ in
            try ClaudeResumeInspection.inspect(configuration: configuration, selection: selection, run: run)
        }
        guard !closing, !stoppingEffects, threadIncarnations[threadID] == incarnation,
              let current = revision.snapshot.threads.first(where: { $0.id == threadID }), !current.isBusy,
              current.claudeRuntimeConfiguration == configuration, current.claudeResumeSelection == selection,
              current.claudeResumeConsumerRunID == run.id, current.runHistory?.first(where: { $0.id == run.id }) == run,
              claudeHistoryScopeIsolated(thread: current) else { throw ProviderHistoryError(.historyChanged) }
        let receipt = try await enqueue(.claudeResumeInspected(threadID: threadID, incarnation: incarnation, selection: selection, run: run, result: result))
        if let rejection = receipt.rejection { throw WorkspaceCommandError(rejection) }
        return receipt
    }
}

extension WorkspaceEngine {
    /// Resolve the lease afresh for every invocation. A provider session spans
    /// multiple app runs; a retained credential never pins an obsolete run ID.
    func appMCPContext(threadID: UUID) throws -> AppMCPContext {
        guard let scope = runtimes[threadID]?.mcpScope else { throw AppMCPError(.staleCaller) }
        return try appMCPContext(scope: scope)
    }
    private func appMCPContext(scope: MCPInvocationScope) throws -> AppMCPContext {
        guard !closing, !stoppingEffects, fatalError == nil,
              let runtime = runtimes[scope.threadID], runtime.id == scope.runtimeID,
              runtime.mcpScope?.sessionID == scope.sessionID,
              runtime.provider == scope.provider, runtime.path == scope.workspacePath,
              threadIncarnations[scope.threadID] == scope.incarnation,
              let thread = revision.snapshot.threads.first(where: { $0.id == scope.threadID }),
              thread.projectID == scope.projectID, !thread.isArchived,
              thread.runtimeID == scope.runtimeID, thread.provider == scope.provider,
              thread.workspacePath == scope.workspacePath,
              !removalCommitThreads.contains(thread.id), !removalCommitProjects.contains(thread.projectID),
              !isAntigravityAuthenticationLocked(thread), !isCodexAuthenticationLocked(thread),
              !revision.snapshot.isConversationHistoryLocked(threadID: thread.id) else { throw AppMCPError(.staleCaller) }
        let configuration = thread.activeRun?.configuration ?? ProviderConfiguration(thread: thread)
        guard try AppMCPAdmission.instanceID(configuration: configuration) == scope.providerInstanceID else { throw AppMCPError(.staleCaller) }
        let runID = thread.activeRun.flatMap { $0.stopRequested ? nil : $0.id }
        return AppMCPContext(scope: scope, runID: runID, configuration: configuration)
    }
    func appMCPView(_ context: AppMCPContext) async throws -> AppMCPView {
        try Task.checkCancellation()
        let fresh = try appMCPContext(scope: context.scope)
        guard fresh.runID == context.runID, fresh.configuration == context.configuration else { throw AppMCPError(.staleCaller) }
        return AppMCPView(snapshot: revision.snapshot, sequence: revision.sequence)
    }
    func appMCPDispatch(_ commands: [WorkspaceCommand], context: AppMCPContext, id: UUID? = nil, expectedTargets: [UUID: ProviderConfiguration] = [:]) async throws -> WorkspaceCommandReceipt {
        _ = try await appMCPView(context)
        let authority = try AppMCPCommandAuthority(context: context)
        let guards = expectedTargets.keys.sorted { $0.uuidString < $1.uuidString }.map { EngineCommand.appMCPTargetGuard(threadID: $0, configuration: expectedTargets[$0]!) }
        let receipt = try await enqueue(.appMCP(authority: authority, commands: guards + commands.map(EngineCommand.client)), id: id ?? UUID())
        if let rejection = receipt.rejection { throw WorkspaceCommandError(rejection) }
        return receipt
    }
    func appMCPAnswerQuestion(threadID: UUID, request: ApprovalRequest, expectedRuntimeID: UUID?, expectedRunID: UUID?,
                              answers: [String: String], context: AppMCPContext) async throws -> WorkspaceCommandReceipt {
        _ = try await appMCPView(context)
        let authority = try AppMCPCommandAuthority(context: context)
        let commands: [EngineCommand] = [
            .appMCPRequestGuard(threadID: threadID, runtimeID: expectedRuntimeID, runID: expectedRunID, request: request),
            .client(.respond(threadID: threadID, requestID: request.id, response: .answers(answers)))
        ]
        let receipt = try await enqueue(.appMCP(authority: authority, commands: commands))
        if let rejection = receipt.rejection { throw WorkspaceCommandError(rejection) }
        return receipt
    }
    private func validateAppMCPLiveAuthority(_ authority: AppMCPCommandAuthority) throws {
        guard let runtime = runtimes[authority.threadID],
              let scope = runtime.mcpScope, scope.sessionID == authority.sessionID,
              scope.threadID == authority.threadID, scope.projectID == authority.projectID,
              scope.runtimeID == authority.runtimeID, scope.incarnation == authority.incarnation,
              scope.providerInstanceID == authority.providerInstanceID,
              scope.provider == authority.provider, scope.workspacePath == authority.workspacePath,
              scope.permission == authority.permission,
              try appMCPContext(scope: scope).runID == authority.runID else { throw WorkspaceCommandError(AppMCPError(.staleCaller).localizedDescription) }
    }
    private func validateAppMCPPreparedCommand(_ command: EngineCommand) throws {
        switch command {
        case .promptSteeringAccepted(let operation):
            guard threadIncarnations[operation.threadID] == operation.sourceIncarnation,
                  runtimes[operation.threadID]?.id == operation.runtimeID else { throw WorkspaceCommandError(AppMCPError(.staleCaller).localizedDescription) }
        case .conversationHistoryAccepted(let review, _):
            guard threadIncarnations[review.sourceThreadID] == review.sourceIncarnation else { throw WorkspaceCommandError(AppMCPError(.staleCaller).localizedDescription) }
        case .beginWorktreePreparation(let threadID, let request, _, _, let incarnation, _, _, _):
            guard threadIncarnations[threadID] == incarnation, request.destinationRoot == worktreesRoot.path else { throw WorkspaceCommandError(AppMCPError(.staleCaller).localizedDescription) }
        default: break
        }
    }
    private func appMCPTools() -> AppMCPTools {
        AppMCPTools(client: .init(read: { [weak self] context in
            guard let self else { throw AppMCPError(.staleCaller) }
            return try await self.appMCPView(context)
        }, perform: { [weak self] action, context in
            guard let self else { throw AppMCPError(.staleCaller) }
            return try await self.performScopedAppMCP(action, context: context)
        }))
    }
    func performScopedAppMCP(_ action: AppMCPAction, context: AppMCPContext) async throws -> JSONValue {
        _ = try await appMCPView(context)
        switch action {
        case .capabilities, .wait: return try await performAppMCP(action, context: context)
        default:
            let authority = try AppMCPCommandAuthority(context: context)
            return try await AppMCPTaskContext.$authority.withValue(authority) {
                try await self.performAppMCP(action, context: context)
            }
        }
    }
    private func ensureAppMCPServer() async throws -> MCPHTTPServer {
        guard appMCPEnabled, !closing, !stoppingEffects, fatalError == nil else { throw AppMCPError(.unavailable) }
        if let mcpServer { return mcpServer }
        let task: Task<MCPHTTPServer, any Error>
        if let pending = mcpServerStart { task = pending }
        else {
            let registry = mcpRegistry, tools = appMCPTools()
            task = Task { [weak self] in
                guard let self else { throw AppMCPError(.staleCaller) }
                return try await MCPHTTPServer.start(registry: registry, tools: tools.descriptors, requestTimeout: .seconds(660), invoke: { [weak self] invocation in
                    guard let self else { throw AppMCPError(.staleCaller) }
                    let context = try await self.appMCPContext(scope: invocation.scope)
                    return await tools.call(name: invocation.toolName, arguments: invocation.arguments, context: context)
                })
            }
            mcpServerStart = task
        }
        do {
            let server = try await task.value
            guard !closing, !stoppingEffects, fatalError == nil else { await server.close(); throw CancellationError() }
            mcpServer = server; mcpServerStart = nil; return server
        } catch { mcpServerStart = nil; throw error }
    }
    private func configureAppMCP(thread: CodingThread, runID: UUID, runtimeID: UUID, session: any ProviderSession,
                                 configuration: ProviderConfiguration) async throws -> MCPInvocationScope? {
        guard appMCPEnabled, session.supportsAppMCP else { return nil }
        let server = try await ensureAppMCPServer()
        guard ownsRun(threadID: thread.id, projectID: thread.projectID, runID: runID),
              runtimes[thread.id]?.id == runtimeID, let incarnation = threadIncarnations[thread.id] else { throw CancellationError() }
        let scope = MCPInvocationScope(threadID: thread.id, projectID: thread.projectID, provider: configuration.provider,
            runtimeID: runtimeID, incarnation: incarnation, providerInstanceID: try AppMCPAdmission.instanceID(configuration: configuration),
            workspacePath: configuration.workspacePath, permission: configuration.permission, capabilities: [.orchestration, .worktree])
        runtimes[thread.id]?.mcpScope = scope
        let credential = try await mcpRegistry.issue(scope: scope)
        do {
            guard ownsRun(threadID: thread.id, projectID: thread.projectID, runID: runID), runtimes[thread.id]?.mcpScope?.sessionID == scope.sessionID else { throw CancellationError() }
            try await session.configureAppMCP(AppMCPConnection(endpoint: server.endpoint, authorizationHeader: credential.authorizationHeader, scopeID: scope.sessionID))
            guard ownsRun(threadID: thread.id, projectID: thread.projectID, runID: runID), runtimes[thread.id]?.mcpScope?.sessionID == scope.sessionID else { throw CancellationError() }
            return scope
        } catch { await mcpRegistry.revoke(sessionID: scope.sessionID); throw error }
    }
    private func closeAppMCPServer() async {
        let pending = mcpServerStart; mcpServerStart = nil; pending?.cancel()
        let server = mcpServer; mcpServer = nil
        await mcpRegistry.shutdown()
        if let pending, let started = try? await pending.value { await started.close() }
        await server?.close()
    }
}


extension WorkspaceEngine {
    func dispatchRemoteEnvironment(_ request: RemoteEnvironmentCommandRequest,
                                   preparation: RemoteEnvironmentPreparation) async throws -> WorkspaceCommandReceipt {
        _ = try await load()
        guard AppMCPTaskContext.authority == nil else { throw AppMCPError(.permissionDenied) }
        guard !stoppingEffects else { throw CancellationError() }
        return try await enqueue(.remoteEnvironment(request, preparation: preparation), id: request.id)
    }
    func remoteEnvironmentReceipt(_ request: RemoteEnvironmentCommandRequest) async throws -> WorkspaceCommandReceipt? {
        _ = try await load()
        return try await database.receipt(request.id, matching: RemoteEnvironmentProtocol.payload(request))
    }
}
