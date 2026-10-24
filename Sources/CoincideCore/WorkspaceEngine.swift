import Foundation
import CryptoKit

public struct WorkspaceUpdate: Sendable {
    public var snapshot: WorkspaceSnapshot
    public var sequence: Int64
    public var error: String?
}

struct WorkspaceLifecycleCommit: Sendable {
    let perform: @Sendable () async throws -> Void
}

extension WorkspaceEngine {
    typealias WorkspaceLifecycleAdmission = @Sendable (ThreadAutoSettlementProposal, WorkspaceLifecycleCommit) async throws -> Void
    func enableRemoteWorkspaceLifecycle(admission: @escaping WorkspaceLifecycleAdmission) async throws {
        try Task.checkCancellation()
        guard loaded, !closing, !stoppingEffects, !workspaceLifecycleClosing, fatalError == nil else { throw CancellationError() }
        workspaceLifecycleAdmission = admission; workspaceLifecycleRemoteEnabled = true
        await ownedWorkspaceLifecycleService().start()
    }
    func readRemoteLifecycle(_ target: RemoteWorkspaceTarget?) async throws -> RemoteLifecycleNativeRead {
        _ = try await load()
        guard !closing, !stoppingEffects, fatalError == nil else { throw RemoteLifecycleFailure(.unavailable) }
        let snapshot = revision.snapshot, policy = snapshot.workspaceLifecyclePolicy ?? .init()
        guard let target else { return .init(sequence: revision.sequence, policy: policy) }
        guard let thread = snapshot.threads.first(where: { $0.id == target.threadID && $0.projectID == target.projectID }),
              snapshot.projects.contains(where: { $0.id == target.projectID }), !thread.isArchived,
              thread.workspacePath.utf8.elementsEqual(target.workspacePath.utf8),
              RemoteLifecycleProtocol.same(ProviderConfiguration(thread: thread), target.configuration),
              let project = projectIncarnations[target.projectID], let incarnation = threadIncarnations[target.threadID],
              let facts = try snapshot.workspaceLifecycleFacts(threadID: thread.id) else { throw RemoteLifecycleFailure(.invalidTarget) }
        func available(_ allowed: Bool, _ reason: String) -> RemoteProjectionAvailability { .init(allowed: allowed, reason: allowed ? nil : reason) }
        let state = RemoteLifecycleNativeState(target: target, projectIncarnation: project, threadIncarnation: incarnation,
            lifecycle: thread.workspaceLifecycle, settlementID: thread.settlement?.id, settlementPhase: thread.settlement?.phase,
            settle: available(snapshot.canSettle(threadID: thread.id), "Finish current work before settling this conversation."),
            resume: available(thread.settlement?.phase == .settled && snapshot.workspaceReady(for: thread), "This conversation has no settled generation to resume."),
            snooze: available(WorkspaceLifecyclePolicyDecision.canSnooze(facts, now: Date()), "Answer pending questions and finish queued input before snoozing."),
            wake: available(thread.workspaceLifecycle?.snoozedUntil != nil, "This conversation is already awake."))
        return .init(sequence: revision.sequence, policy: policy, state: state)
    }
    private func validateRemoteLifecyclePreparation(_ prepared: RemoteLifecyclePreparation, snapshot: WorkspaceSnapshot) throws {
        guard !closing, !stoppingEffects, fatalError == nil else { throw RemoteLifecycleFailure(.unavailable) }
        if case .thread(let native, _, _) = prepared.action {
            guard projectIncarnations[native.target.projectID] == native.projectIncarnation,
                  threadIncarnations[native.target.threadID] == native.threadIncarnation,
                  let thread = snapshot.threads.first(where: { $0.id == native.target.threadID && $0.projectID == native.target.projectID }),
                  thread.workspacePath.utf8.elementsEqual(native.target.workspacePath.utf8),
                  RemoteLifecycleProtocol.same(ProviderConfiguration(thread: thread), native.target.configuration),
                  RemoteLifecycleProtocol.same(thread.workspaceLifecycle, native.lifecycle),
                  thread.settlement?.id == native.settlementID, thread.settlement?.phase == native.settlementPhase else { throw RemoteLifecycleFailure(.staleCapture) }
        }
    }
    private func ownedWorkspaceLifecycleService() -> WorkspaceLifecycleService {
        if let workspaceLifecycleService { return workspaceLifecycleService }
        let service = WorkspaceLifecycleService(read: { [weak self] in
            guard let self else { throw CancellationError() }; return try await self.readWorkspaceLifecycleSnapshot()
        }, lookup: { [weak self] facts in
            guard let self else { throw CancellationError() }; return try await self.lookupWorkspaceLifecyclePullRequests(facts)
        }, apply: { [weak self] proposal in
            guard let self else { throw CancellationError() }; try await self.admitWorkspaceLifecycleProposal(proposal)
        }, wake: { [weak self] wake in
            guard let self else { throw CancellationError() }; try await self.wakeExpiredWorkspaceSnooze(wake)
        })
        workspaceLifecycleService = service; return service
    }
    public func sweepWorkspaceLifecycle() async {
        guard (try? await load()) != nil, !closing, !stoppingEffects, !workspaceLifecycleClosing else { return }
        let service = ownedWorkspaceLifecycleService(); await service.requestSweep(); await service.drain()
    }
    private func closeWorkspaceLifecycle() async {
        await stopWorkspaceLifecycle()
        await workspaceLifecycleDrain?.value
    }
    private func stopWorkspaceLifecycle() async {
        if workspaceLifecycleClosing { return }
        workspaceLifecycleClosing = true
        let service = workspaceLifecycleService; workspaceLifecycleService = nil
        // Publish the join owner before suspending so a concurrent shutdown
        // cannot observe a closing service with no drain to await.
        workspaceLifecycleDrain = Task { if let service { await service.close() } }
        workspaceLifecycleProposals = [:]; workspaceLifecycleReadOwners = nil
    }
    private func readWorkspaceLifecycleSnapshot() throws -> WorkspaceLifecycleSweepSnapshot {
        guard loaded, !closing, !stoppingEffects, !workspaceLifecycleClosing, fatalError == nil else { throw CancellationError() }
        let facts = try revision.snapshot.threads.compactMap { try revision.snapshot.workspaceLifecycleFacts(threadID: $0.id) }
        let bindingID = UUID(); workspaceLifecycleReadOwners = (bindingID, threadIncarnations, projectIncarnations)
        return .init(facts: facts, policy: revision.snapshot.workspaceLifecyclePolicy ?? .init(), bindingID: bindingID)
    }
    private func admitWorkspaceLifecycleProposal(_ proposal: ThreadAutoSettlementProposal) async throws {
        guard !closing, !stoppingEffects, !workspaceLifecycleClosing, fatalError == nil else { throw CancellationError() }
        workspaceLifecycleProposals[proposal.id] = proposal
        defer { workspaceLifecycleProposals.removeValue(forKey: proposal.id) }
        let commit = WorkspaceLifecycleCommit { [weak self] in
            guard let self else { throw CancellationError() }
            try await self.commitWorkspaceLifecycleProposal(proposal)
        }
        if let workspaceLifecycleAdmission { try await workspaceLifecycleAdmission(proposal, commit) }
        else { try await commit.perform() }
    }
    private func commitWorkspaceLifecycleProposal(_ proposal: ThreadAutoSettlementProposal) async throws {
        let receipt = try await enqueue(.client(.workspaceLifecycle(.automaticallySettle(proposal))), id: proposal.id)
        if let rejection = receipt.rejection { throw WorkspaceCommandError(rejection) }
    }
    private func wakeExpiredWorkspaceSnooze(_ wake: WorkspaceLifecycleExpiredSnooze) async throws {
        guard !closing, !stoppingEffects, !workspaceLifecycleClosing, fatalError == nil else { throw CancellationError() }
        let receipt = try await enqueue(.client(.workspaceLifecycle(.wakeExpired(wake))), id: wake.id)
        if let rejection = receipt.rejection { throw WorkspaceCommandError(rejection) }
    }
    private func validateOwnedWorkspaceLifecycleProposal(_ proposal: ThreadAutoSettlementProposal, commandID: UUID, snapshot: WorkspaceSnapshot) throws {
        guard !closing, !stoppingEffects, !workspaceLifecycleClosing, fatalError == nil,
              proposal.id == commandID, workspaceLifecycleProposals[proposal.id] == proposal,
              proposal.bindingID == workspaceLifecycleReadOwners?.id,
              workspaceLifecycleReadOwners?.threads[proposal.threadID] == threadIncarnations[proposal.threadID],
              workspaceLifecycleReadOwners?.projects[proposal.projectID] == projectIncarnations[proposal.projectID],
              let facts = try snapshot.workspaceLifecycleFacts(threadID: proposal.threadID) else { throw WorkspaceLifecycleError.stale }
        try WorkspaceLifecyclePolicyDecision.validate(proposal, facts: facts, policy: snapshot.workspaceLifecyclePolicy ?? .init(), now: Date())
    }
    private func lookupWorkspaceLifecyclePullRequests(_ facts: ThreadWorkspaceLifecycleFacts) async throws -> [WorkspaceLifecyclePullRequestObservation] {
        guard !closing, !stoppingEffects, !workspaceLifecycleClosing, fatalError == nil,
              facts.pullRequests.count == 1, let current = try revision.snapshot.workspaceLifecycleFacts(threadID: facts.id),
              try ContextTransferProtocol.digest(current) == ContextTransferProtocol.digest(facts),
              let incarnation = projectIncarnations[facts.projectID] else { throw WorkspaceLifecycleError.stale }
        var expectedBranches: [UUID: String] = [:]
        for link in facts.pullRequests {
            if let creation = revision.snapshot.pullRequestCreations?.first(where: { $0.id == link.id && $0.sourceThreadID == facts.id }),
               let branch = creation.review.context.branch { expectedBranches[link.id] = branch }
            else if let checkout = revision.snapshot.pullRequestCheckouts?.first(where: { $0.id == link.id && $0.targetThreadID == facts.id }),
                    let branch = checkout.result?.branch { expectedBranches[link.id] = branch }
            else { throw WorkspaceLifecycleError.stale }
        }
        let branches = expectedBranches
        let session = try pullRequestFactory(URL(fileURLWithPath: facts.workspacePath))
        let result: [WorkspaceLifecyclePullRequestObservation] = try await readPullRequest(projectID: facts.projectID, incarnation: incarnation) {
            var details: [(WorkspaceLifecyclePullRequestLink, GitHubPullRequestDetail)] = []
            for link in facts.pullRequests {
                try Task.checkCancellation()
                let detail = try await session.detail(link.reference)
                guard detail.summary.reference == link.reference else { throw WorkspaceLifecycleError.stale }
                details.append((link, detail))
            }
            // Read the native branch again after linked terminal observations:
            // a newer open PR on that branch wins over a stale closed link.
            let context = try await session.context()
            let actualPath = URL(fileURLWithPath: context.workspacePath).standardizedFileURL.resolvingSymlinksInPath().path
            let expectedPath = URL(fileURLWithPath: facts.workspacePath).standardizedFileURL.resolvingSymlinksInPath().path
            guard actualPath.utf8.elementsEqual(expectedPath.utf8),
                  facts.pullRequests.allSatisfy({ $0.reference.repository == context.repository }),
                  details.allSatisfy({ branches[$0.0.id] == context.branch && context.headCommit == $0.1.summary.headCommit }) else { throw WorkspaceLifecycleError.stale }
            let newerOpen = context.existingPullRequest?.state == .open, observedAt = Date()
            return details.map { link, detail in
                .init(link: link, state: detail.summary.state, closedAt: detail.summary.closedAt, mergedAt: detail.summary.mergedAt,
                    observedAt: observedAt, newerOpenPullRequest: newerOpen)
            }
        }
        guard !closing, !stoppingEffects, !workspaceLifecycleClosing,
              let latest = try revision.snapshot.workspaceLifecycleFacts(threadID: facts.id),
              try ContextTransferProtocol.digest(latest) == ContextTransferProtocol.digest(facts) else { throw WorkspaceLifecycleError.stale }
        return result
    }

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
            try Task.checkCancellation()
            let receipt = try await enqueue(.promptSteeringDispatching(operationID: id, incarnation: operation.sourceIncarnation))
            guard receipt.rejection == nil else { return steeringUnsentResult(operation) }
            guard steeringTargetIsActive(operation), var thread = revision.snapshot.threads.first(where: { $0.id == threadID }) else { return steeringUnsentResult(operation) }
            try Task.checkCancellation() // Still proven unsent; the durable marker is conservative after a crash.
            let configuration = operation.configuration
            thread.provider = configuration.provider; thread.workspacePath = configuration.workspacePath
            thread.model = configuration.model; thread.reasoningEffort = configuration.reasoningEffort; thread.permission = configuration.permission
            thread.agentModeID = configuration.agentModeID; thread.agentConfigValues = configuration.agentConfigValues
            thread.agentConfiguration = configuration.agentConfiguration; thread.codexRuntimeConfiguration = configuration.codexRuntimeConfiguration; thread.claudeRuntimeConfiguration = configuration.claudeRuntimeConfiguration
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
            try Task.checkCancellation(); try validateScratchHistorySource(thread); dispatched = true
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
              record.providerThreadID == thread.providerThreadID || thread.provider == .claude,
              record.configuration.provider == thread.provider,
              record.configuration.workspacePath == thread.workspacePath else {
            throw WorkspaceCommandError("Finish this conversation's work and select a run with verified provider history before continuing.")
        }
        if thread.scratchWorkspace != nil { try scratchWorkspaces.validate(thread: thread) }
        let fingerprint = try revision.snapshot.historySourceFingerprint(threadID: threadID)
        let rawPrefix = try thread.transcriptPrefix(runID: runID, boundary: kind == .forkAfterRun ? .afterRun : .beforeRun)
        var prefix = kind == .forkAfterRun && thread.provider != .claude ? try revision.snapshot.verifiedForkPrefix(rawPrefix) : rawPrefix
        let native: ReviewedNativeHistory?
        let claude: ClaudeHistoryReviewEvidence?
        let reviewID = UUID()
        if thread.provider == .claude {
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
            claude = evidence; native = nil
        } else {
            claude = nil
            native = try await readHistory(thread: thread) { session in
                try await Self.readReviewedNativeHistory(session: session, thread: thread, runID: runID, kind: kind)
            }
        }
        guard ownsHistorySource(threadID: threadID, incarnation: incarnation, fingerprint: fingerprint),
              revision.snapshot.canReviewConversationHistory(threadID: threadID) else { throw ProviderHistoryError(.historyChanged) }
        let activeRecords = (thread.runHistory ?? []).filter { $0.removedByHistoryOperationID == nil }
        guard let index = activeRecords.firstIndex(where: { $0.id == runID }),
              native?.snapshot.headTurnID != nil || claude != nil else { throw ProviderHistoryError(.boundaryUnavailable) }
        guard let sourceReference = claude?.source.reference ?? native?.snapshot.reference,
              let boundary = claude?.boundary.providerBoundary ?? native?.boundary else { throw ProviderHistoryError(.boundaryUnavailable) }
        let review = try ConversationHistoryReview(id: reviewID, kind: kind, sourceThreadID: threadID, projectID: thread.projectID,
            runID: runID, sourceIncarnation: incarnation, sourceConfiguration: .init(thread: thread),
            targetConfiguration: record.configuration, sourceReference: sourceReference,
            reviewedHeadTurnID: native?.snapshot.headTurnID, boundary: boundary, expectedResultHeadTurnID: native?.resultingHead,
            prefix: prefix, removedRunIDs: kind == .rewindBeforeRun ? activeRecords[index...].map(\.id) : [],
            removedMessageIDs: kind == .rewindBeforeRun ? thread.visibleMessages.dropFirst(prefix.count).map(\.id) : [],
            sourceFingerprint: fingerprint, targetThreadID: kind == .forkAfterRun ? UUID() : nil,
            suggestedTitle: String((thread.title + " — Fork").prefix(200)),
            recallPromptOnSuccess: kind == .rewindBeforeRun && recallPromptOnSuccess ? true : nil,
            claude: claude)
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
            guard (fresh.boundary == keepReview.boundary || (fresh.claude.map { value in keepReview.claude.map { value.sameLogicalBoundary(as: $0) } == true } == true)), fresh.reviewedHeadTurnID == keepReview.reviewedHeadTurnID,
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
                claude: keepReview.claude ?? fresh.claude)
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
        if let payload = try scratchWorkspaces.submission(review.id) {
            guard let recorded = try? JSONDecoder().decode(EngineCommand.self, from: payload),
                  let (original, originalTitle, grant) = capturedScratchHistory(recorded), grant?.operationID == review.id,
                  original == review, ContextTransferProtocol.same(title, originalTitle) else { throw WorkspaceCommitError.commandIDCollision }
            if let receipt = try await database.receipt(review.id, matching: payload) {
                if let rejection = receipt.rejection { throw WorkspaceCommandError(rejection) }; return receipt
            }
            let receipt = try await enqueue(recorded, id: review.id)
            if let rejection = receipt.rejection { throw WorkspaceCommandError(rejection) }; return receipt
        }
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
            let grant = try prepareScratchHistoryFork(review, commandID: review.id)
            let native = EngineCommand.conversationHistoryAccepted(review: review, title: title, scratchFork: grant)
            let command: EngineCommand
            if let authority = AppMCPTaskContext.authority { command = .appMCP(authority: authority, commands: [native]) }
            else { command = native }
            try recordScratchHistoryFork(grant, commandID: review.id, originalPayload: taskCommandPayload(command))
            let receipt = try await enqueue(command, id: review.id)
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
        try validateScratchHistorySource(thread)
        if let grant = operation.scratchFork { try validateScratchHistoryFork(grant, review: operation.review, snapshot: revision.snapshot) }
        let expected = operation.review
        if expected.claude != nil { return try await reconcileClaudeHistory(operation: operation, thread: thread, incarnation: incarnation) }
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
        case .claudeResumeInspected(let thread, let incarnation, _, _, _): return threadIncarnations[thread] == incarnation
        case .conversationHistoryAccepted(let review, _, _):
            return threadIncarnations[review.sourceThreadID] == review.sourceIncarnation
        case .conversationHistoryDispatching(let thread, _, let incarnation): return threadIncarnations[thread] == incarnation
        case .conversationHistoryClaudeForkReserved(let id, _, let incarnation):
            guard let operation = revision.snapshot.conversationHistoryOperation(id) else { return false }
            return operation.review.sourceIncarnation == incarnation && threadIncarnations[operation.review.sourceThreadID] == incarnation
        case .conversationHistoryEffectResult(let request, _, let incarnation): return request.threadID.map { threadIncarnations[$0] == incarnation } ?? false
        case .conversationHistoryScratchForkHeld(let held): return held.request.threadID.map { threadIncarnations[$0] == held.incarnation } ?? false
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

    private func readHistory<Value: Sendable>(thread: CodingThread, forceOwnedMetadata: Bool = false,
                                              operation: @escaping @Sendable (any ProviderSession) async throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        guard !closing, !stoppingEffects, fatalError == nil, !isCodexAuthenticationLocked(.init(thread: thread)),
              let incarnation = threadIncarnations[thread.id] else { throw CancellationError() }
        try validateScratchHistorySource(thread)
        let token = UUID(), metadataID: UUID?, session: any ProviderSession
        if !forceOwnedMetadata, let runtime = runtimes[thread.id], runtime.id == thread.runtimeID, runtime.provider == thread.provider,
           runtime.path == thread.workspacePath, runtime.codexBinding == ProviderConfiguration(thread: thread).codexRuntimeBinding, claudeRuntimeMatches(runtime, thread: thread) {
            metadataID = nil; session = runtime.session
        } else {
            var configured = thread
            if forceOwnedMetadata {
                configured.activeRun = nil; configured.runtimeID = nil; configured.runtimeRequests = []
                configured.providerActivity = nil; configured.state = .idle
            }
            try validateScratchHistorySource(thread)
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
            guard !task.isCancelled, !closing, !stoppingEffects, fatalError == nil, !isCodexAuthenticationLocked(.init(thread: thread)), threadIncarnations[thread.id] == incarnation else { throw CancellationError() }
            if let metadataID {
                if let close = beginMetadataClose(metadataID) { await close.value }
                guard metadataSessions[metadataID] != nil else { throw CancellationError() }
                metadataSessions.removeValue(forKey: metadataID)
            }
            try Task.checkCancellation()
            guard !closing, !stoppingEffects, !isCodexAuthenticationLocked(.init(thread: thread)), threadIncarnations[thread.id] == incarnation else { throw CancellationError() }
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
        do {
            try validateScratchHistorySource(thread)
            if let grant = operation.scratchFork { try validateScratchHistoryFork(grant, review: review, snapshot: revision.snapshot) }
        } catch { return .failed(ConversationHistoryOperation.failureMessage) }
        if review.claude != nil { return await performClaudeConversationHistory(request, operation: operation, thread: thread, incarnation: incarnation) }
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
           runtime.provider == thread.provider, runtime.path == thread.workspacePath, runtime.codexBinding == ProviderConfiguration(thread: thread).codexRuntimeBinding, claudeRuntimeMatches(runtime, thread: thread) {
            metadataID = nil; session = runtime.session
        } else {
            var configured = thread
            if review.kind == .forkAfterRun {
                guard let project = revision.snapshot.projects.first(where: { $0.id == thread.projectID }) else { return .cancelled }
                configured = CodingThread(project: project, model: review.targetConfiguration.model)
                configured.id = review.targetThreadID!; configured.workspacePath = review.targetConfiguration.workspacePath
                if let grant = operation.scratchFork {
                    configured.scratchWorkspace = grant.allocation.receipt; configured.createdAt = grant.allocation.receipt.createdAt
                }
                configured.provider = review.targetConfiguration.provider; configured.reasoningEffort = review.targetConfiguration.reasoningEffort; configured.permission = review.targetConfiguration.permission
                configured.codexRuntimeConfiguration = review.targetConfiguration.codexRuntimeConfiguration; configured.agentModeID = review.targetConfiguration.agentModeID
                configured.agentConfigValues = review.targetConfiguration.agentConfigValues; configured.agentConfiguration = review.targetConfiguration.agentConfiguration
            }
            try validateScratchHistorySource(thread)
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
            if review.kind == .forkAfterRun { snapshot = try await session.forkConversation(source: review.sourceReference, boundary: review.boundary, configuration: review.targetConfiguration) }
            else {
                guard case .beforeTurn(let turnID) = review.boundary, let head = review.reviewedHeadTurnID else { throw ProviderHistoryError(.invalidRequest) }
                snapshot = try await session.revertConversation(thread: review.sourceReference, beforeTurnID: turnID, expectedHeadTurnID: head)
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
        let retireSource = review.kind == .rewindBeforeRun
        if let metadataID {
            if let close = beginMetadataClose(metadataID) { await close.value }
            metadataSessions.removeValue(forKey: metadataID)
        } else if retireSource, let reusedRuntimeID {
            // Retire this exact old event stream after success/uncertainty.
            await closeRuntime(threadID, matching: reusedRuntimeID)
        }
        return result
    }
}

extension WorkspaceEngine {
    private func routeProviderEvent(threadID: UUID, runtimeID: UUID, event: ProviderEvent) async throws {
        _ = try await enqueue(.provider(threadID: threadID, runtimeID: runtimeID, event: event))
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
                let plan = try await projectScriptPlanner(.init(id: runID, projectRoot: URL(fileURLWithPath: project.path), workspacePath: URL(fileURLWithPath: thread.workspacePath), role: owner.role,
                    settingsRoot: projectSettingsRoot, settingsKeys: ProjectSettingsKey.candidates(for: project)))
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
            let outputToken = UUID()
            remoteProjectScriptPaths[runID] = .init(token: outputToken, threadID: threadID, paths: Array(Set([plan.workspacePath, plan.projectRoot])), drained: false)
            let output: Task<Void, Never> = Task { [weak self] in
                do { try await session.consumeOutput { chunk in await log.append(chunk.data) } } catch { }
                await session.close(); await log.close()
                await self?.remoteProjectScriptOutputDrained(runID, token: outputToken)
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
                if remoteProjectScriptPaths[run.id] == nil {
                    let projectPath = previous.projects.first(where: { $0.id == old.projectID })?.path ?? old.workspacePath
                    remoteProjectScriptPaths[run.id] = .init(token: UUID(), threadID: old.id,
                        paths: Array(Set([run.plan?.workspacePath ?? old.workspacePath, run.plan?.projectRoot ?? projectPath])), drained: true)
                }
                let runtime = scriptRuntimes.removeValue(forKey: run.id), log = scriptLogs[run.id]
                runtime?.monitor?.cancel(); runtime?.output.cancel()
                let effectIDs = removedEffects.filter { $0.request.projectScriptRunID == run.id && $0.status == .running && $0.leaseOwner == workerID }.map(\.id)
                let incarnation = threadIncarnations[old.id]
                let leaseToken = remoteProjectScriptPaths[run.id]?.token
                let task: Task<Void, Never> = Task.detached { [weak self] in
                    if let runtime { await runtime.session.close() }
                    for effect in effectIDs { await self?.awaitRetiringEffect(effect) }
                    await log?.close()
                    if let self, let incarnation { _ = try? await self.enqueue(.threadScriptStopped(threadID: old.id, owner: owner, runID: run.id, incarnation: incarnation)) }
                    await self?.projectScriptCleanupFinished(run.id, threadID: old.id, leaseToken: leaseToken)
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
    private func projectScriptCleanupFinished(_ id: UUID, threadID: UUID, leaseToken: UUID?) {
        scriptClosures.removeValue(forKey: id)
        // The close/effect join above is authoritative even when the output
        // consumer's final actor callback has not yet received its turn.
        if let leaseToken, remoteProjectScriptPaths[id]?.token == leaseToken { remoteProjectScriptPaths[id]?.drained = true }
        if remoteProjectScriptPaths[id]?.drained == true, scriptRuntimes[id] == nil { remoteProjectScriptPaths.removeValue(forKey: id) }
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

    /// Retained native jobs remain leases after their command exits and while
    /// removed-thread cleanup drains. A closed retained log is not a lease.
    func remoteProjectScriptBusyPaths(excludingThreadID: UUID? = nil) -> [String] {
        var paths = Set<String>()
        for (id, owner) in remoteProjectScriptPaths where owner.threadID != excludingThreadID {
            if !owner.drained || scriptClosures[id] != nil { paths.formUnion(owner.paths) }
        }
        for thread in revision.snapshot.threads where thread.id != excludingThreadID {
            for (_, run) in thread.projectScripts where [.starting, .running, .stopping].contains(run.phase) {
                paths.insert(run.plan?.workspacePath ?? thread.workspacePath)
                if let path = run.plan?.projectRoot ?? revision.snapshot.projects.first(where: { $0.id == thread.projectID })?.path { paths.insert(path) }
            }
        }
        return paths.sorted()
    }
    private func remoteProjectScriptOutputDrained(_ runID: UUID, token: UUID) {
        guard remoteProjectScriptPaths[runID]?.token == token else { return }
        remoteProjectScriptPaths[runID]?.drained = true
        if scriptRuntimes[runID] == nil, scriptClosures[runID] == nil { remoteProjectScriptPaths.removeValue(forKey: runID) }
    }
    private func remoteProjectScriptHasOwnedJob(_ runID: UUID) -> Bool {
        scriptClosures[runID] != nil || remoteProjectScriptPaths[runID]?.drained == false
    }
    func readRemoteProjectScript(_ target: RemoteWorkspaceTarget, generationID: UUID) async throws -> RemoteProjectScriptNativeState {
        _ = try await load(); try Task.checkCancellation()
        guard !closing, !stoppingEffects, fatalError == nil else { throw RemoteProjectScriptFailure(.unavailable) }
        guard let thread = revision.snapshot.threads.first(where: { $0.id == target.threadID && $0.projectID == target.projectID }),
              let project = revision.snapshot.projects.first(where: { $0.id == target.projectID }),
              thread.workspacePath.utf8.elementsEqual(target.workspacePath.utf8),
              RemoteLifecycleProtocol.same(ProviderConfiguration(thread: thread), target.configuration),
              let projectIncarnation = projectIncarnations[project.id], let threadIncarnation = threadIncarnations[thread.id],
              thread.settlement?.id == generationID else { throw RemoteProjectScriptFailure(.invalidTarget) }
        let run = thread.settlement?.script
        return .init(target: target, projectPath: project.path, projectIncarnation: projectIncarnation,
            threadIncarnation: threadIncarnation, generationID: generationID, run: run,
            hasOwnedJob: run.map { remoteProjectScriptHasOwnedJob($0.id) } ?? false)
    }
    private func validateRemoteProjectScriptPreparation(_ prepared: RemoteProjectScriptPreparation, snapshot: WorkspaceSnapshot) throws {
        guard !closing, !stoppingEffects, fatalError == nil else { throw RemoteProjectScriptFailure(.unavailable) }
        let native = prepared.native, target = native.target, action = prepared.action
        guard projectIncarnations[target.projectID] == native.projectIncarnation,
              threadIncarnations[target.threadID] == native.threadIncarnation,
              let project = snapshot.projects.first(where: { $0.id == target.projectID }),
              project.path.utf8.elementsEqual(native.projectPath.utf8),
              let thread = snapshot.threads.first(where: { $0.id == target.threadID && $0.projectID == target.projectID }),
              thread.workspacePath.utf8.elementsEqual(target.workspacePath.utf8),
              RemoteLifecycleProtocol.same(ProviderConfiguration(thread: thread), target.configuration),
              thread.settlement?.id == native.generationID, native.generationID == action.generationID,
              thread.settlement?.phase == .settled, let run = thread.settlement?.script,
              run.id == action.runID, run.id == native.run?.id,
              !action.requiresBoundRoot || target.rootID != nil else { throw RemoteProjectScriptFailure(.invalidTarget) }
        switch action {
        case .approve:
            guard run.canApprove, RemoteLifecycleProtocol.same(run.plan, native.run?.plan),
                  snapshot.permitsScriptAction(owner: .settlement(generationID: native.generationID), thread: thread) else { throw RemoteProjectScriptFailure(.staleReview) }
        case .retry:
            guard run.canRetry, RemoteLifecycleProtocol.same(Optional(run), native.run), !thread.isBusy,
                  snapshot.permitsScriptAction(owner: .settlement(generationID: native.generationID), thread: thread) else { throw RemoteProjectScriptFailure(.staleReview) }
        case .skip:
            guard run.canSkip else { throw RemoteProjectScriptFailure(.staleReview) }
        case .stop:
            guard run.phase != .stopping, remoteProjectScriptHasOwnedJob(run.id) || [.discovering, .starting, .running].contains(run.phase) else { throw RemoteProjectScriptFailure(.staleReview) }
        }
        if action.requiresBoundRoot {
            let paths = [thread.workspacePath, project.path]
            for other in snapshot.threads where other.id != thread.id {
                let ownedPaths = [other.workspacePath] + (other.activeRun.map { [$0.configuration.workspacePath] } ?? []) + other.queuedTurns.map { $0.configuration.workspacePath }
                guard !other.isBusy && other.queuedTurns.isEmpty && other.runtimeRequests.isEmpty ||
                      !ownedPaths.contains(where: { path in paths.contains { WorkspaceSnapshot.checkpointRestorePathsOverlap(path, $0) } }) else { throw RemoteProjectScriptFailure(.busy) }
            }
        }
    }
    func readRemoteProjectScriptOutput(_ owner: RemoteProjectScriptOutputOwner) async throws -> RemoteProjectScriptNativeOutput {
        _ = try await load(); try Task.checkCancellation()
        try validateRemoteProjectScriptOutputOwner(owner)
        if let log = scriptLogs[owner.runID] {
            let value = await log.currentSnapshot()
            try Task.checkCancellation(); try validateRemoteProjectScriptOutputOwner(owner)
            return .init(value: value, retention: .retained)
        }
        if let thread = revision.snapshot.threads.first(where: { $0.id == owner.target.threadID }),
           thread.settlement?.id == owner.generationID, let run = thread.settlement?.script, run.id == owner.runID,
           run.startedAt == nil, [.waitingForCheckout, .discovering, .awaitingApproval, .skipped].contains(run.phase) {
            let value: ProjectScriptOutputSnapshot? = run.phase == .skipped ? .init(runID: run.id, sequence: 0, text: "", truncated: false, isClosed: true) : nil
            return .init(value: value, retention: .notStarted)
        }
        // Logs are host-lifetime state. Never synthesize a retained empty log
        // for a completed or interrupted job loaded by a replacement helper.
        return .init(value: nil, retention: .notRetained)
    }
    private func validateRemoteProjectScriptOutputOwner(_ owner: RemoteProjectScriptOutputOwner) throws {
        guard !closing, !stoppingEffects, fatalError == nil else { throw RemoteProjectScriptFailure(.unavailable) }
        guard projectIncarnations[owner.target.projectID] == owner.projectIncarnation,
              threadIncarnations[owner.target.threadID] == owner.threadIncarnation,
              revision.snapshot.projects.contains(where: { $0.id == owner.target.projectID }),
              revision.snapshot.threads.contains(where: { $0.id == owner.target.threadID && $0.projectID == owner.target.projectID && $0.workspacePath.utf8.elementsEqual(owner.target.workspacePath.utf8) }) else { throw RemoteProjectScriptFailure(.invalidTarget) }
    }
    func awaitRemoteProjectScriptCompletion(_ request: RemoteEnvironmentCommandRequest) async {
        switch request.command {
        case .projectScript(_, let action):
            switch action {
            case .approve: return
            case .stop, .skip, .retry:
                while let task = scriptClosures[action.runID] { await task.value }
            }
        case .lifecycle(_, .resume(let generationID)):
            while let task = settlementClosures[generationID] { await task.value }
        default: break
        }
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
    private var scheduledTaskService: ScheduledTaskService?

    private struct HistoryRead: Sendable {
        let threadID: UUID
        let projectID: UUID
        let drain: Task<Void, Never>
        let cancel: @Sendable () -> Void
        let configuration: ProviderConfiguration
    }
    private var historyReads: [UUID: HistoryRead] = [:]
    private struct PreparedHistoryReview: Sendable {
        let review: ConversationHistoryReview
        let digest: String
    }
    private var historyReviews: [UUID: PreparedHistoryReview] = [:]
    private var acceptingHistoryReviews: Set<UUID> = []
    private var remoteHistoryReviews: [UUID: RemoteHistoryPreparedReview] = [:]
    private var remoteHistoriesClosing = false
    private var remoteHistoryOperations = 0
    private var remoteHistoryWaiters: [CheckedContinuation<Void, Never>] = []
    private var remoteHistoryCloseTask: Task<Void, Never>?
    private var remoteHistoryAcceptances: [UUID: Int] = [:]
    private var remoteHistoryTasks: [UUID: Task<Void, Never>] = [:]
    private struct PreparedCheckpointRestore: Sendable {
        let review: RunCheckpointRestoreReview
        let digest: String
    }
    private var checkpointRestoreReviews: [UUID: PreparedCheckpointRestore] = [:]
    private var remoteCheckpointReviews: [UUID: RemoteCheckpointReview] = [:]
    private var remoteCheckpointsClosing = false
    private var remoteCheckpointOperations = 0
    private var remoteCheckpointWaiters: [CheckedContinuation<Void, Never>] = []
    private var remoteCheckpointCloseTask: Task<Void, Never>?
    private var remoteCheckpointAcceptances: [UUID: Int] = [:]
    private var acceptingCheckpointRestores: Set<UUID> = []
    public typealias PullRequestFactory = @Sendable (URL) throws -> any GitHubPullRequestSession
    private let pullRequestFactory: PullRequestFactory
    public typealias PullRequestActionFactory = @Sendable (URL) throws -> any GitHubPullRequestActionSession
    private let pullRequestActionFactory: PullRequestActionFactory
    private struct PreparedPullRequestAction: Sendable {
        let operation: PullRequestActionOperation
        let digest: String
        let proof: TaskIsolationProof
        let sourceThreadIncarnation: UUID?
        let sourceThreadCreatedAt: Date?
    }
    private var pullRequestActionReviews: [UUID: PreparedPullRequestAction] = [:]
    private var acceptingPullRequestActions: Set<UUID> = []
    public typealias PullRequestCheckoutFactory = @Sendable (GitHubPullRequestCheckoutRequest) throws -> any GitHubPullRequestCheckoutSession
    private let pullRequestCheckoutFactory: PullRequestCheckoutFactory
    private struct PreparedPullRequestCheckout: Sendable { let operation: PullRequestCheckoutOperation; let digest: String }
    private var pullRequestCheckoutReviews: [UUID: PreparedPullRequestCheckout] = [:]
    private var acceptingPullRequestCheckouts: Set<UUID> = []
    private struct PreparedPullRequestCreation: Sendable {
        let operation: PullRequestCreationOperation; let digest: String
        let sourceThreadIncarnation: UUID?; let sourceThreadCreatedAt: Date?
    }
    private var pullRequestCreationReviews: [UUID: PreparedPullRequestCreation] = [:]
    private var acceptingPullRequestCreations: Set<UUID> = []
    private struct PullRequestRead: Sendable { let projectID: UUID; let drain: Task<Void, Never>; let cancel: @Sendable () -> Void }
    private var pullRequestReads: [UUID: PullRequestRead] = [:]
    private var remotePullRequestReviews: [UUID: RemotePullRequestReview] = [:]
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
    private let projectSettingsRoot: URL
    private var scriptRuntimes: [UUID: ScriptRuntime] = [:]
    private var scriptLogs: [UUID: ProjectScriptRunLog] = [:]
    private var scriptClosures: [UUID: Task<Void, Never>] = [:]
    private struct RemoteOwnedScriptPaths: Sendable { let token: UUID; let threadID: UUID; let paths: [String]; var drained: Bool }
    private var remoteProjectScriptPaths: [UUID: RemoteOwnedScriptPaths] = [:]
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
        var codexBinding: CodexRuntimeConfiguration?
        var claudeConfiguration: ClaudeRuntimeConfiguration?
        var claudeLaunchSelection: ClaudeResumeSelection?
        var claudeNativeID: String?
        var claudeModelOptions: ClaudeModelOptions?
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
    private let contextMCPEnabled: Bool
    private let workspaceLifecycleEnabled: Bool
    private var workspaceLifecycleRemoteEnabled = false
    private var workspaceLifecycleAdmission: WorkspaceLifecycleAdmission?
    private var workspaceLifecycleService: WorkspaceLifecycleService?
    private var workspaceLifecycleProposals: [UUID: ThreadAutoSettlementProposal] = [:]
    private var workspaceLifecycleDrain: Task<Void, Never>?
    private var workspaceLifecycleReadOwners: (id: UUID, threads: [UUID: UUID], projects: [UUID: UUID])?
    private var workspaceLifecycleClosing = false
    private var delegatedTaskDeliveryJob: Task<Void, Never>?
    private var delegatedTaskWakeGeneration: UInt64 = 0
    private var delegatedTaskDrains: [UUID: Task<Void, Never>] = [:]
    private var contextTransferReviews: [UUID: ContextTransferReview] = [:]
    private var acceptingContextTransfers: [UUID: Int] = [:]
    private var contextTransfersClosing = false
    private var contextTransferOperations = 0
    private var contextTransferWaiters: [CheckedContinuation<Void, Never>] = []
    private struct ContextTransferRetirement {
        let id: UUID
        let threadID: UUID
        let task: Task<Void, Never>
    }
    private var contextTransferRetirements: [UUID: ContextTransferRetirement] = [:]
    private let agentSessionDataRoot: URL
    private var agentSessionScanner: AgentSessionScanner?
    private var agentSessionProfilesDigest: String?
    private var agentSessionScannerGeneration = UUID()
    private var agentSessionScanResults: [UUID: AgentSessionScanResult] = [:]
    private var agentSessionScanOrder: [UUID] = []
    private var agentSessionCompletedSources: [String: [AgentSessionImportSource]] = [:]
    private var agentSessionImportReviews: [UUID: AgentSessionImportAdmission] = [:]
    private var agentSessionImportsClosing = false
    private let mcpRegistry = MCPSessionRegistry()
    private var mcpServer: MCPHTTPServer?
    private var mcpServerStart: Task<MCPHTTPServer, any Error>?
    private let database: WorkspaceDatabase
    private let scratchWorkspaces: ScratchWorkspaceService
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

    public init(url: URL, appMCPEnabled: Bool = false, contextMCPEnabled: Bool = false, workspaceLifecycleEnabled: Bool = false, providerFactory: @escaping ProviderFactory = { try ProviderSessions.make(for: $0) },
                cloneFactory: @escaping CloneFactory = { GitCloneService(plan: $0) },
                identityResolver: IdentityResolver? = nil,
                worktreeFactory: @escaping WorktreeFactory = { GitWorktreeService(request: $0) },
                projectScriptPlanner: ProjectScriptPlanner? = nil,
                projectScriptFactory: @escaping ProjectScriptFactory = { _ in throw ProjectScriptExecutionError(.helperUnavailable) },
                checkpointFactory: @escaping CheckpointFactory = { GitCheckpointService(root: $0) },
                pullRequestFactory: @escaping PullRequestFactory = { GitHubPullRequestService(root: $0) },
                pullRequestCheckoutFactory: @escaping PullRequestCheckoutFactory = { GitHubPullRequestCheckoutService(request: $0) },
                pullRequestActionFactory: PullRequestActionFactory? = nil) throws {
        self.appMCPEnabled = appMCPEnabled
        self.contextMCPEnabled = contextMCPEnabled
        self.workspaceLifecycleEnabled = workspaceLifecycleEnabled
        agentSessionDataRoot = url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
        ownership = try WorkspaceRuntimeLock(url: url.appendingPathExtension("runtime-lock"))
        database = try WorkspaceDatabase(url: url)
        scratchWorkspaces = .init(dataRoot: url.deletingLastPathComponent())
        attachments = try AttachmentStore(root: url.deletingLastPathComponent().appendingPathComponent("Attachments", isDirectory: true))
        factory = providerFactory
        self.cloneFactory = cloneFactory
        self.identityResolver = identityResolver ?? { try await RepositoryIdentityResolver(root: $0).resolve() }
        self.worktreeFactory = worktreeFactory
        self.projectScriptPlanner = projectScriptPlanner ?? { try await ProjectScriptSetupPlanner.plan($0) }
        self.projectScriptFactory = projectScriptFactory
        projectSettingsRoot = ProjectSettingsFiles.root(dataRoot: url.deletingLastPathComponent())
        self.checkpointFactory = checkpointFactory; self.pullRequestFactory = pullRequestFactory
        self.pullRequestCheckoutFactory = pullRequestCheckoutFactory
        self.pullRequestActionFactory = pullRequestActionFactory ?? { GitHubPullRequestActionService(root: $0) }
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
        if workspaceLifecycleEnabled { await ownedWorkspaceLifecycleService().start() }
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
        if workspaceLifecycleEnabled || workspaceLifecycleRemoteEnabled, !closing, !stoppingEffects, fatalError == nil, let service = workspaceLifecycleService {
            Task { await service.requestSweep() }
        }
    }
    public func scheduler() -> ScheduledTaskService {
        if let scheduledTaskService { return scheduledTaskService }
        let namespace = "coincide.scheduler." + SHA256.hash(data: Data(agentSessionDataRoot.path.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        let service = ScheduledTaskService(engine: self, secrets: KeychainScheduledTaskSecrets(namespace: namespace))
        scheduledTaskService = service; return service
    }
    func dispatchScheduledTaskFromAppMCP(_ action: ScheduledTaskMCPAction, source: ScheduledTaskSource, commandID: UUID, context: AppMCPContext) async throws -> JSONValue {
        let expected: UUID?
        if case .run(let taskID, _) = action { expected = revision.snapshot.scheduler?.tasks.first(where: { $0.id == taskID })?.revision } else { expected = nil }
        let request = ScheduledTaskMCPCommand(action: action, source: source, managedRoot: worktreesRoot.path, expectedTaskRevision: expected)
        let receipt = try await appMCPDispatch([.scheduledTask(.mcp(request))], context: context, id: commandID)
        var result: [String: JSONValue] = ["commandId": .string(receipt.commandID.uuidString), "sequence": .number(Double(receipt.sequence)), "accepted": .bool(true)]
        let taskID: UUID?
        switch action {
        case .save(let id, _, _, _, _, _, _, _): taskID = id ?? TaskOrchestration.derivedID(commandID, "definition")
        case .delete(let id, _, _), .run(let id, _): taskID = id
        case .acknowledge, .list, .read: taskID = nil
        }
        if let taskID {
            result["scheduledTaskId"] = .string(taskID.uuidString)
            if let task = revision.snapshot.scheduler?.tasks.first(where: { $0.id == taskID }) {
                result["revision"] = .string(task.revision.uuidString); result["enabled"] = .bool(task.enabled)
                result["nextRunAt"] = task.nextRunAt.map { .string(ISO8601DateFormatter().string(from: $0)) } ?? .null
            }
            if let occurrence = revision.snapshot.scheduler?.occurrences.first(where: { $0.id == commandID }) {
                result["threadId"] = occurrence.threadID.map { .string($0.uuidString) } ?? .null; result["status"] = .string(occurrence.phase.rawValue)
            }
        }
        if case .save = action { await scheduler().start() }
        return .object(result)
    }
    public func closeScheduledTasks() async { await scheduledTaskService?.shutdown() }
    public func scheduledTaskReceipt(commandID: UUID, taskID: UUID) async throws -> WorkspaceCommandReceipt? {
        _ = try await load()
        guard revision.snapshot.scheduler?.occurrences.contains(where: { $0.id == commandID && $0.taskID == taskID }) == true else { return nil }
        return try await database.receipt(commandID)
    }
    public func fireScheduledTask(taskID: UUID, revision: UUID, trigger: ScheduledTaskOccurrence.Trigger, commandID: UUID,
                                  dueAt: Date, observedAt: Date, prompt: String? = nil, delivery: ScheduledTaskWebhookDelivery? = nil) async throws -> WorkspaceCommandReceipt {
        _ = try await load()
        let fire = ScheduledTaskFire(taskID: taskID, revision: revision, trigger: trigger, dueAt: dueAt, observedAt: observedAt,
            managedRoot: worktreesRoot.path, prompt: prompt, delivery: delivery)
        return try await dispatch(.scheduledTask(.fire(fire)), id: commandID)
    }

    public func validateScratchWorkspace(threadID: UUID, workspacePath: String) async throws {
        _ = try await load()
        guard !closing, !stoppingEffects, let thread = revision.snapshot.threads.first(where: { $0.id == threadID }),
              thread.workspacePath.utf8.elementsEqual(workspacePath.utf8) else { throw ScratchWorkspaceError() }
        if thread.scratchWorkspace != nil { try scratchWorkspaces.validate(thread: thread) }
    }
    public func prepareScratchWorkspace(commandID: UUID, threadID: UUID, namingText: String = "") async throws -> ScratchWorkspaceAllocation {
        _ = try await load(); try Task.checkCancellation()
        guard !closing, !stoppingEffects, fatalError == nil else { throw CancellationError() }
        if let authority = AppMCPTaskContext.authority { try validateAppMCPLiveAuthority(authority) }
        return try scratchWorkspaces.prepare(commandID: commandID, threadID: threadID, namingText: namingText)
    }
    public func prepareScratchWorkspaceReuse(sourceThreadID: UUID, destinationThreadID: UUID, commandID: UUID) async throws -> ScratchWorkspaceAllocation {
        _ = try await load(); try Task.checkCancellation()
        guard !closing, !stoppingEffects, fatalError == nil,
              let source = revision.snapshot.threads.first(where: { $0.id == sourceThreadID }), !source.isArchived,
              let receipt = source.scratchWorkspace, revision.snapshot.workspaceReady(for: source) else { throw ScratchWorkspaceError() }
        if let authority = AppMCPTaskContext.authority { try validateAppMCPLiveAuthority(authority) }
        return try scratchWorkspaces.reuse(source: receipt, commandID: commandID, threadID: destinationThreadID)
    }
    @discardableResult public func createScratchThread(_ creation: ScratchThreadCreation, commandID: UUID) async throws -> WorkspaceCommandReceipt {
        _ = try await load(); try Task.checkCancellation()
        guard !closing, !stoppingEffects, fatalError == nil, creation.allocation.receipt.commandID == commandID else { throw ScratchWorkspaceError() }
        let command: EngineCommand
        if let authority = AppMCPTaskContext.authority {
            command = .appMCP(authority: authority, commands: [.scratchThreadAccepted(creation)])
        } else { command = .scratchThreadAccepted(creation) }
        let payload = try taskCommandPayload(command)
        if let receipt = try await database.receipt(commandID, matching: payload) {
            if let rejection = receipt.rejection { throw WorkspaceCommandError(rejection) }; return receipt
        }
        try scratchWorkspaces.recordSubmission(creation, payload: payload)
        try Task.checkCancellation()
        let receipt = try await enqueue(command, id: commandID)
        if let rejection = receipt.rejection { throw WorkspaceCommandError(rejection) }
        return receipt
    }
    public func scratchWorkspaceRecoveries(limit: Int = 64, offset: Int = 0) async throws -> [ScratchWorkspaceRecovery] {
        _ = try await load()
        let entries = try scratchWorkspaces.allocations(limit: limit, offset: offset)
        var result: [ScratchWorkspaceRecovery] = []
        for (id, allocation, cancelled) in entries {
            if let payload = try scratchWorkspaces.submission(id) {
                let receipt = try await database.receipt(id, matching: payload)
                let phase: ScratchWorkspaceRecoveryPhase
                if cancelled { phase = .cancelled }
                else if let receipt {
                    if receipt.rejection != nil { phase = .rejected }
                    else if let history = revision.snapshot.conversationHistoryOperations?.first(where: { $0.scratchFork?.allocation.receipt.commandID == id }),
                            history.phase != .applied || !revision.snapshot.threads.contains(where: { $0.id == history.review.targetThreadID }) {
                        phase = .acceptedHistoryPending
                    } else { phase = .accepted }
                }
                else { phase = .uncertain }
                result.append(.init(id: id, allocation: allocation, phase: phase, receipt: receipt))
            } else { result.append(.init(id: id, allocation: allocation, phase: cancelled ? .cancelled : allocation == nil ? .incomplete : .prepared)) }
        }
        return result
    }
    /// Never retries a first input. Absence is atomically sealed as an original-
    /// UUID rejection before any still-empty unaccepted folder can be removed.
    public func discardEmptyScratchAllocation(commandID: UUID) async throws -> Bool {
        _ = try await load(); try Task.checkCancellation()
        guard !closing, !stoppingEffects else { throw CancellationError() }
        if let payload = try scratchWorkspaces.submission(commandID) {
            guard let receipt = try await inspectedCommandReceipt(commandID, payload: payload, resolvingAbsent: true), receipt.rejection != nil else {
                throw ScratchWorkspaceError("This scratch conversation was accepted. Its folder and user files must be kept.")
            }
        }
        return try scratchWorkspaces.discardEmpty(commandID)
    }
    func prepareScratchHistoryFork(_ review: ConversationHistoryReview, commandID: UUID) throws -> ScratchHistoryForkGrant? {
        guard review.kind == .forkAfterRun,
              let source = revision.snapshot.threads.first(where: { $0.id == review.sourceThreadID }),
              let receipt = source.scratchWorkspace else { return nil }
        try revision.snapshot.validateConversationHistorySource(review)
        guard let targetID = review.targetThreadID else { throw ScratchWorkspaceError() }
        try scratchWorkspaces.validate(thread: source)
        let allocation = try scratchWorkspaces.reuse(source: receipt, commandID: commandID, threadID: targetID)
        let grant = ScratchHistoryForkGrant(operationID: review.id, source: receipt, allocation: allocation)
        try grant.validate(review: review); return grant
    }
    func recordScratchHistoryFork(_ grant: ScratchHistoryForkGrant?, commandID: UUID, originalPayload: Data) throws {
        guard let grant else { return }
        guard grant.allocation.receipt.commandID == commandID else { throw ScratchWorkspaceError() }
        try scratchWorkspaces.recordPayload(allocation: grant.allocation, payload: originalPayload)
    }
    private func capturedScratchHistory(_ command: EngineCommand) -> (ConversationHistoryReview, String?, ScratchHistoryForkGrant?)? {
        switch command {
        case .conversationHistoryAccepted(let review, let title, let grant): return (review, title, grant)
        case .appMCP(_, let commands) where commands.count == 1:
            if case .conversationHistoryAccepted(let review, let title, let grant) = commands[0] { return (review, title, grant) }; return nil
        default: return nil
        }
    }
    private func validateScratchHistorySource(_ thread: CodingThread) throws {
        if thread.scratchWorkspace != nil { try scratchWorkspaces.validate(thread: thread) }
    }
    private func validateScratchHistoryFork(_ grant: ScratchHistoryForkGrant, review: ConversationHistoryReview, snapshot: WorkspaceSnapshot) throws {
        try grant.validate(review: review)
        guard let source = snapshot.threads.first(where: { $0.id == review.sourceThreadID }),
              source.scratchWorkspace == grant.source else { throw ScratchWorkspaceError() }
        try scratchWorkspaces.validate(thread: source)
        try scratchWorkspaces.validate(grant.allocation)
    }
    private func scratchHistoryPublication(_ command: EngineCommand, snapshot: WorkspaceSnapshot) -> EngineCommand {
        guard case .conversationHistoryEffectResult(let request, .conversationHistoryConfirmed(let acknowledgment), let incarnation) = command,
              case .conversationHistory(_, let operationID) = request,
              let operation = snapshot.conversationHistoryOperation(operationID), let grant = operation.scratchFork else { return command }
        do { try validateScratchHistoryFork(grant, review: operation.review, snapshot: snapshot); return command }
        catch { return .conversationHistoryScratchForkHeld(.init(request: request, acknowledgment: acknowledgment, incarnation: incarnation)) }
    }
    private func validateScratchAdmission(_ command: EngineCommand, id: UUID, payload: Data, snapshot: WorkspaceSnapshot) throws {
        switch command {
        case .conversationHistoryAccepted(let review, _, let grant):
            if let source = snapshot.threads.first(where: { $0.id == review.sourceThreadID }) { try validateScratchHistorySource(source) }
            if let grant {
                try validateScratchHistoryFork(grant, review: review, snapshot: snapshot)
                guard grant.allocation.receipt.commandID == id, try scratchWorkspaces.submission(id) == payload else { throw ScratchWorkspaceError() }
            } else if review.kind == .forkAfterRun, snapshot.threads.first(where: { $0.id == review.sourceThreadID })?.scratchWorkspace != nil { throw ScratchWorkspaceError() }
        case .conversationHistoryDispatching(_, let operationID, _), .conversationHistoryReconciled(let operationID, _, _):
            if let operation = snapshot.conversationHistoryOperation(operationID) {
                if let source = snapshot.threads.first(where: { $0.id == operation.review.sourceThreadID }) { try validateScratchHistorySource(source) }
                if let grant = operation.scratchFork { try validateScratchHistoryFork(grant, review: operation.review, snapshot: snapshot) }
            }
        case .contextTransferAccepted(let review, _, let allocation):
            if let allocation {
                guard review.kind == .fork, allocation.receipt.commandID == id,
                      allocation.threadID == review.targetThreadID, allocation.project.id == review.projectID,
                      allocation.workspacePath.utf8.elementsEqual(review.targetConfiguration.workspacePath.utf8),
                      try scratchWorkspaces.submission(id) == payload else { throw ScratchWorkspaceError() }
                try scratchWorkspaces.validate(allocation)
            } else if review.kind == .fork, snapshot.projects.first(where: { $0.id == review.projectID })?.scratch != nil { throw ScratchWorkspaceError() }
        case .transcriptPlanImplementation(let request):
            if request.scratchSource != nil {
                guard let source = snapshot.threads.first(where: { $0.id == request.threadID }) else { throw ScratchWorkspaceError() }
                try scratchWorkspaces.validate(thread: source)
            }
            if let grant = request.scratchAllocation {
                _ = try request.command(in: snapshot)
                try scratchWorkspaces.validate(grant)
                guard grant.receipt.commandID == id, try scratchWorkspaces.submission(id) == payload else { throw ScratchWorkspaceError() }
            }
        case .scratchThreadAccepted(let creation):
            try creation.validate(); try scratchWorkspaces.validate(creation.allocation)
            guard creation.allocation.receipt.commandID == id, try scratchWorkspaces.submission(id) == payload else { throw ScratchWorkspaceError() }
        case .client(let action):
            let paths: [String]
            switch action {
            case .addProject(let project): paths = [project.path]
            case .addProjectWithThread(let project, let thread), .startProjectClone(let project, let thread): paths = [project.path, thread.workspacePath]
            case .createThread(let thread): paths = [thread.workspacePath]
            case .editThread(let threadID, let edit):
                if snapshot.threads.first(where: { $0.id == threadID })?.scratchWorkspace != nil { return }
                switch edit { case .workspacePath(let path): paths = [path]
                case .draftProject(let assignment): paths = [assignment.targetProject.path]
                case .claudeWorkspace(let value): paths = [value.registeredWorkspacePath]
                default: paths = [] }
            default: paths = []
            }
            let root = scratchWorkspaces.root.path
            guard !paths.contains(where: { path in
                let physical = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
                return physical == root || physical.hasPrefix(root + "/")
            }) else { throw ScratchWorkspaceError("Create this conversation through the owned scratch allocator.") }
        case .beginWorktreePreparation(let threadID, _, _, _, _, _, _):
            guard snapshot.threads.first(where: { $0.id == threadID })?.scratchWorkspace == nil else { throw ScratchWorkspaceError("Scratch folders are not Git worktrees. Choose a project to prepare a worktree.") }
        default: break
        }
    }
    /// Adds a host-owned grant without recapturing any original source, draft,
    /// configuration or destination UUID from a newer selection.
    func prepareTranscriptPlanImplementation(_ request: TranscriptPlanImplementation, commandID: UUID) async throws -> TranscriptPlanImplementation {
        _ = try await load(); try Task.checkCancellation()
        guard !closing, !stoppingEffects, fatalError == nil else { throw CancellationError() }
        guard let destination = request.destination, request.scratchSource != nil else { return request }
        _ = try request.command(in: revision.snapshot, allowUnpreparedScratch: true)
        guard let source = revision.snapshot.threads.first(where: { $0.id == request.threadID }),
              let receipt = source.scratchWorkspace else { throw ScratchWorkspaceError() }
        try scratchWorkspaces.validate(thread: source)
        let grant = try scratchWorkspaces.reuse(source: receipt, commandID: commandID, threadID: destination.threadID)
        guard request.scratchAllocation == nil || request.scratchAllocation == grant else { throw ScratchWorkspaceError() }
        return request.usingScratchAllocation(grant)
    }
    func recordScratchTranscriptPlan(_ request: TranscriptPlanImplementation, commandID: UUID, originalPayload: Data) throws {
        guard let allocation = request.scratchAllocation else { return }
        guard allocation.receipt.commandID == commandID else { throw ScratchWorkspaceError() }
        try scratchWorkspaces.recordPayload(allocation: allocation, payload: originalPayload)
        _ = try request.command(in: revision.snapshot)
    }
    private func capturedScratchPlan(_ command: EngineCommand) -> TranscriptPlanImplementation? {
        switch command {
        case .transcriptPlanImplementation(let value): return value
        case .appMCP(_, let commands) where commands.count == 1:
            if case .transcriptPlanImplementation(let value) = commands[0] { return value }; return nil
        default: return nil
        }
    }
    @discardableResult public func implementTranscriptPlan(_ request: TranscriptPlanImplementation, commandID: UUID = UUID()) async throws -> WorkspaceCommandReceipt {
        _ = try await load()
        guard !stoppingEffects else { throw CancellationError() }
        let command: EngineCommand
        if request.destination != nil, request.scratchSource != nil,
           let payload = try scratchWorkspaces.submission(commandID) {
            guard let recorded = try? JSONDecoder().decode(EngineCommand.self, from: payload),
                  let original = capturedScratchPlan(recorded), original.scratchAllocation?.receipt.commandID == commandID,
                  request.matchesOriginalCapture(original) else { throw WorkspaceCommitError.commandIDCollision }
            if let receipt = try await database.receipt(commandID, matching: payload) {
                if let rejection = receipt.rejection { throw WorkspaceCommandError(rejection) }; return receipt
            }
            command = recorded
        } else {
            let prepared = try await prepareTranscriptPlanImplementation(request, commandID: commandID)
            let native = EngineCommand.transcriptPlanImplementation(prepared)
            if let authority = AppMCPTaskContext.authority { command = .appMCP(authority: authority, commands: [native]) }
            else { command = native }
            try recordScratchTranscriptPlan(prepared, commandID: commandID, originalPayload: taskCommandPayload(command))
        }
        let receipt = try await enqueue(command, id: commandID)
        if let rejection = receipt.rejection { throw WorkspaceCommandError(rejection) }
        return receipt
    }
    private let threadActionUndos = ThreadActionUndoRegistry()
    private var remoteThreadActionDrains: [UUID: (UUID, Task<Void, Never>)] = [:]
    private var remoteThreadActionOwners: [UUID: RemoteThreadActionBinding] = [:]
    /// Only this Engine's exact committed forward decisions create Undo claims.
    public func takeThreadActionUndo(forwardCommandID: UUID, ownerID: UUID) -> ThreadActionUndoClaim? {
        guard !closing, fatalError == nil else { return nil }
        return threadActionUndos.take(forwardID: forwardCommandID, ownerID: ownerID, now: Date())
    }
    public func undoThreadAction(_ claim: ThreadActionUndoClaim) async throws -> WorkspaceCommandReceipt {
        try await dispatch(.threadActionUndo(claim), id: claim.id)
    }
    @discardableResult public func dispatch(_ command: WorkspaceCommand, id: UUID = UUID()) async throws -> WorkspaceCommandReceipt {
        _ = try await load()
        guard !stoppingEffects else { throw CancellationError() }
        if case .scheduledTask(.fire(let fire)) = command, !fire.managedRoot.utf8.elementsEqual(worktreesRoot.path.utf8) { throw ScheduledTaskError.sourceChanged }
        if case .scheduledTask(.mcp(let request)) = command, !request.managedRoot.utf8.elementsEqual(worktreesRoot.path.utf8) { throw ScheduledTaskError.sourceChanged }
        if case .submitDefaultWorktree(let input) = command {
            guard AppMCPTaskContext.authority == nil else { throw WorkspaceCommandError("Use the native draft’s explicit Send action for its captured workspace choice.") }
            let request = GitWorktreeRequest(id: DefaultWorktreeIdentity.preparationID(commandID: id), sourcePath: input.intent.sourcePath,
                destinationRoot: worktreesRoot.path,
                selection: .createBranch(name: "coincide/" + id.uuidString.lowercased(), baseRef: "refs/heads/" + input.intent.baseBranch),
                submodules: input.intent.submodules, expectedSourceIdentity: input.intent.sourceProof.sourceIdentity,
                automaticBase: .init(intent: input.intent))
            try request.validate()
            let receipt = try await enqueue(.defaultWorktreeSubmission(input, request), id: id)
            if let rejection = receipt.rejection { throw WorkspaceCommandError(rejection) }
            return receipt
        }
        if case .setWorkspaceLifecyclePolicy(let policy) = command { try policy.validate() }
        if case .workspaceLifecycle(let action) = command { try action.validateEncoding() }
        var capturedCommand = command
        if case .editThread(let threadID, .workspacePath(let path)) = command,
           let runtime = revision.snapshot.threads.first(where: { $0.id == threadID })?.claudeRuntimeConfiguration {
            let captured = try runtime.replacingWorkspace(path, physicalPath: ClaudeRuntimeValidation.physical(path, allowMissing: false))
            capturedCommand = .editThread(threadID, .claudeWorkspace(captured))
        }
        let receipt = try await enqueue(.client(capturedCommand), id: id)
        if let rejection = receipt.rejection { throw WorkspaceCommandError(rejection) }
        return receipt
    }

    /// Receipt inspection uses the original payload and never resubmits a draft
    /// mutation whose response was lost across a restart or interrupted window.
    public func composerDraftReceipt(commandID: UUID, replacement: ComposerDraftReplacement, resolvingAbsent: Bool = false) async throws -> WorkspaceCommandReceipt? {
        _ = try await load()
        return try await inspectedCommandReceipt(commandID, payload: taskCommandPayload(.client(.replaceComposerDraft(replacement))), resolvingAbsent: resolvingAbsent)
    }
    private func inspectedCommandReceipt(_ commandID: UUID, payload: Data, resolvingAbsent: Bool) async throws -> WorkspaceCommandReceipt? {
        for attempt in 0..<4 {
            if let receipt = try await database.receipt(commandID, matching: payload) { return receipt }
            guard resolvingAbsent else { return nil }
            let base = try await database.revision()
            do {
                // This original-ID rejection is atomic with every writer's
                // command deduplication. A late original cannot apply afterward.
                return try await database.rejectCommand(commandID, matching: payload,
                    reason: "The earlier change was not admitted. Your current draft and saved data were kept.", expectedSequence: base.sequence)
            } catch WorkspaceCommitError.revisionChanged where attempt < 3 { continue }
        }
        throw WorkspaceCommitError.revisionChanged
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
        let receipt = try await enqueue(.beginWorktreePreparation(threadID: threadID, request: request, expectedSourcePath: thread.workspacePath, previousAttemptID: nil, incarnation: incarnation, reviewSetup: reviewSetup, claudeRuntimeConfiguration: try thread.claudeRuntimeConfiguration?.replacingWorkspace(request.destinationPath, physicalPath: ClaudeRuntimeValidation.physical(request.destinationPath, allowMissing: true))))
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
        if state.request.automaticBase != nil {
            guard AppMCPTaskContext.authority == nil else { throw WorkspaceCommandError("Retry this captured draft workspace explicitly in the native app.") }
            // Same original input, branch, folder and request; known plans are
            // inspected above. Unproven partial bytes are never removed/overwritten.
            let receipt = try await enqueue(.retryDefaultWorktree(threadID: threadID, attemptID: state.id))
            if let rejection = receipt.rejection { throw WorkspaceCommandError(rejection) }
            return receipt
        }
        let request = GitWorktreeRequest(sourcePath: state.request.sourcePath, destinationRoot: worktreesRoot.path, selection: state.request.selection, submodules: state.request.submodules,
            expectedSourceIdentity: state.request.expectedSourceIdentity, automaticBase: state.request.automaticBase)
        let receipt = try await enqueue(.beginWorktreePreparation(threadID: threadID, request: request, expectedSourcePath: thread.workspacePath, previousAttemptID: state.id, incarnation: incarnation, reviewSetup: state.setup != nil, claudeRuntimeConfiguration: try thread.claudeRuntimeConfiguration?.replacingWorkspace(request.destinationPath, physicalPath: ClaudeRuntimeValidation.physical(request.destinationPath, allowMissing: true))))
        if let rejection = receipt.rejection { throw WorkspaceCommandError(rejection) }; return receipt
    }
    private func enqueue(_ command: EngineCommand, id: UUID = UUID()) async throws -> WorkspaceCommandReceipt {
        guard loaded, !closing, fatalError == nil else { throw CoincideError(fatalError ?? "The workspace is closing.") }
        let admitted: EngineCommand
        if let authority = AppMCPTaskContext.authority {
            try Task.checkCancellation()
            switch command {
            case .client, .transcriptPlanImplementation, .scratchThreadAccepted, .promptSteeringAccepted, .conversationHistoryAccepted, .contextTransferAccepted, .beginWorktreePreparation, .delegatedTaskAccepted, .delegatedTaskCancel, .delegatedTaskObserved, .delegatedTaskWakePolicy:
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
            else { payload = try taskCommandPayload(envelope.command) }
            if let receipt = try await database.receipt(envelope.id, matching: payload) {
                envelope.continuation.resume(returning: receipt); return
            }
            for attempt in 0..<4 {
                let base = try await database.revision()
                if let fatalError { throw CoincideError(fatalError) }
                var decision: WorkspaceDecision
                do {
                    try envelope.mcpAdmission?.check()
                    if case .client(.threadActionUndo(let claim)) = envelope.command {
                        try threadActionUndos.validate(claim, commandID: envelope.id, now: Date())
                    }
                    let admissionCommands: [EngineCommand]
                    if case .appMCP(let authority, let commands) = envelope.command {
                        try validateAppMCPLiveAuthority(authority)
                        try AppMCPAdmission.validate(authority: authority, snapshot: base.snapshot, commands: commands)
                        admissionCommands = commands
                    } else if case .remoteEnvironment(let request, let preparation) = envelope.command {
                        if let owner = request.undoOwner { try validateRemoteThreadActionOwner(owner) }
                        if case .threadAction(let action) = request.command {
                            switch action { case .setPinned, .setArchived: guard request.undoOwner == action.binding else { throw RemoteEnvironmentAdmission.stale() }; case .undo: break }
                        }
                        if case .threadActions(let prepared) = preparation { try validateRemoteThreadActions(prepared, snapshot: base.snapshot) }
                        if case .checkpoint(let captured) = preparation {
                            try validateRemoteCheckpointPreparation(captured, snapshot: base.snapshot)
                        }
                        if case .lifecycle(let captured) = preparation { try validateRemoteLifecyclePreparation(captured, snapshot: base.snapshot) }
                        if case .projectScript(let captured) = preparation { try validateRemoteProjectScriptPreparation(captured, snapshot: base.snapshot) }
                        if case .history(let captured) = preparation {
                            try validateRemoteHistoryPreparation(captured, snapshot: base.snapshot)
                        }
                        if case .pullRequest(let captured) = preparation {
                            try validateRemotePullRequestPreparation(captured)
                        }
                        if case .worktree(let captured) = preparation,
                           threadIncarnations[captured.threadID] != captured.incarnation { throw RemoteEnvironmentAdmission.stale() }
                        if case .steering(let captured) = preparation { try validateRemoteSteeringPreparation(captured, snapshot: base.snapshot) }
                        let attachmentCapture: RemoteAttachmentSubmission?
                        switch preparation {
                        case .attachments(let value): attachmentCapture = value
                        case .steering(let value): attachmentCapture = .init(target: .init(environmentID: value.target.environmentID, projectID: value.target.projectID, threadID: value.target.threadID), incarnation: value.incarnation, records: value.records)
                        default: attachmentCapture = nil
                        }
                        if let captured = attachmentCapture {
                            guard threadIncarnations[captured.target.threadID] == captured.incarnation else { throw RemoteEnvironmentAdmission.stale() }
                            for expected in captured.records {
                                guard let actual = try await database.remoteAttachment(captured.target, id: expected.attachment.id),
                                      !actual.cancelled, actual.claimedBy == nil || actual.claimedBy == request.id,
                                      try RemoteAttachmentJournal.payload(actual.upload) == RemoteAttachmentJournal.payload(expected.upload),
                                      try RemoteAttachmentProtocol.payload(actual.attachment) == RemoteAttachmentProtocol.payload(expected.attachment) else { throw RemoteEnvironmentAdmission.stale() }
                            }
                        }
                        admissionCommands = try RemoteEnvironmentAdmission.commands(request, preparation: preparation, snapshot: base.snapshot)
                    } else { admissionCommands = [envelope.command] }
                    for command in admissionCommands {
                        try validateScratchAdmission(command, id: envelope.id, payload: payload, snapshot: base.snapshot)
                        if case .pullRequestCreationAccepted(let operation) = command { try validatePullRequestCreationThread(operation) }
                        if case .pullRequestActionAccepted(let operation) = command { try validatePullRequestActionThread(operation) }
                        if case .client(.workspaceLifecycle(.automaticallySettle(let proposal))) = command {
                            try validateOwnedWorkspaceLifecycleProposal(proposal, commandID: envelope.id, snapshot: base.snapshot)
                        }
                        if case .agentSessionImportAccepted(let admission) = command { try await validateAgentSessionImportAdmission(admission, snapshot: base.snapshot) }
                        if case .contextTransferAccepted(let review, _, _) = command { try validateContextTransferAcceptance(review, snapshot: base.snapshot) }
                        try validateContextCompactionAdmission(command, snapshot: base.snapshot)
                        try validateCodexDefaultCommand(command, snapshot: base.snapshot)
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
                    if case .conversationHistoryAccepted(let review, _, _) = envelope.command,
                       threadIncarnations[review.sourceThreadID] != review.sourceIncarnation {
                        throw WorkspaceCommandError("This conversation changed. Review its current history before continuing.")
                    }
                    if case .beginWorktreePreparation(let threadID, let request, _, _, let incarnation, _, _) = envelope.command,
                       (threadIncarnations[threadID] != incarnation || request.destinationRoot != worktreesRoot.path) {
                        throw WorkspaceCommandError("This conversation changed. Choose the worktree again in its current workspace.")
                    }
                    if !ownsPromptSteeringEvent(envelope.command) || !ownsPullRequestCheckoutEvent(envelope.command) || !ownsPullRequestCreationEvent(envelope.command) || !ownsPullRequestActionEvent(envelope.command) || !ownsCheckpointRestoreEvent(envelope.command) || !ownsHistoryEvent(envelope.command) || !ownsScriptEvent(envelope.command) || !ownsCheckpointEvent(envelope.command) {
                        decision = WorkspaceDecision(snapshot: base.snapshot)
                    } else if case .worktreeRecovered(let threadID, let attemptID, let incarnation, _) = envelope.command,
                       !ownsWorktree(threadID: threadID, attemptID: attemptID, incarnation: incarnation) {
                        decision = WorkspaceDecision(snapshot: base.snapshot)
                    } else if case .repositoryIdentityResolved(let projectID, let path, let incarnation, let requestID, _) = envelope.command,
                       !ownsIdentityRefresh(projectID: projectID, path: path, incarnation: incarnation, requestID: requestID) {
                        decision = WorkspaceDecision(snapshot: base.snapshot)
                    } else {
                        let admitted = scratchHistoryPublication(envelope.command, snapshot: base.snapshot)
                        decision = try WorkspaceDecision.make(admitted, id: envelope.id, snapshot: base.snapshot, now: Date())
                    }
                }
                catch where error is WorkspaceCommandError || error is AppMCPError || error is ContextTransferError || error is ContextHandoffError || error is DelegatedTaskError || error is TaskIsolationError || error is AgentSessionImportError || error is WorkspaceLifecycleError || error is ScheduledTaskError || error is ScratchWorkspaceError || error is RemoteLifecycleFailure || error is RemoteProjectScriptFailure || error is GitHubPullRequestActionError {
                    do {
                        let reason = (error as? WorkspaceCommandError)?.message ?? (error as? AppMCPError)?.localizedDescription ?? (error as? ContextTransferError)?.localizedDescription ?? (error as? ContextHandoffError)?.localizedDescription ?? (error as? DelegatedTaskError)?.localizedDescription ?? (error as? TaskIsolationError)?.localizedDescription ?? (error as? AgentSessionImportError)?.localizedDescription ?? (error as? WorkspaceLifecycleError)?.localizedDescription ?? (error as? ScheduledTaskError)?.localizedDescription ?? (error as? ScratchWorkspaceError)?.localizedDescription ?? (error as? GitHubPullRequestActionError)?.localizedDescription ?? AppMCPError(.unavailable).localizedDescription
                        let receipt = try await database.rejectCommand(envelope.id, matching: payload, reason: reason, expectedSequence: base.sequence)
                        envelope.continuation.resume(returning: receipt); return
                    } catch WorkspaceCommitError.revisionChanged where attempt < 3 { continue }
                }
                do {
                    try decision.snapshot.reconcileAgentSessionImports(previous: base.snapshot)
                    completedDuringCommit = []
                    removalCommitProjects = Set(base.snapshot.projects.map(\.id)).subtracting(decision.snapshot.projects.map(\.id))
                    removalCommitThreads = Set(base.snapshot.threads.map(\.id)).subtracting(decision.snapshot.threads.map(\.id))
                    scriptCommitRuns = Set(base.snapshot.threads.flatMap { old in
                        let next = decision.snapshot.threads.first(where: { $0.id == old.id })
                        return old.projectScripts.compactMap { owner, run in next?.projectScript(owner: owner) != run ? run.id : nil }
                    })
                    var committed = false
                    defer { finishCommitFence(removed: committed) }
                    let attachmentClaims: [RemoteAttachmentRecord]
                    if case .remoteEnvironment(_, .attachments(let captured)) = envelope.command { attachmentClaims = captured.records }
                    else if case .remoteEnvironment(_, .steering(let captured)) = envelope.command { attachmentClaims = captured.records }
                    else { attachmentClaims = [] }
                    let outcome = try await database.commitWithRemovedEffects(decision.snapshot, event: "workspace.command", commandID: envelope.id,
                        expectedSequence: base.sequence, effects: decision.effects, deduplicationPayload: payload, attachmentClaims: attachmentClaims)
                    let receipt = outcome.receipt
                    revision = .init(snapshot: decision.snapshot, sequence: receipt.sequence)
                    if case .remoteEnvironment(_, .checkpoint(let captured)) = envelope.command { remoteCheckpointCommitted(captured) }
                    if case .remoteEnvironment(let request, .history(let captured)) = envelope.command { remoteHistoryCommitted(captured, commandID: request.id) }
                    if case .remoteEnvironment(_, .pullRequest(let captured)) = envelope.command {
                        let reviewID: UUID?
                        switch captured.action {
                        case .creation(let operation, _): reviewID = operation.id
                        case .checkout(let operation, _): reviewID = operation.id
                        default: reviewID = nil
                        }
                        if let reviewID, let review = remotePullRequestReviews[reviewID] {
                            _ = discardRemotePullRequestReview(.init(target: review.target, reviewID: reviewID, digest: review.digest))
                        }
                    }
                    if let attemptID = decision.cancelCloneAttempt {
                        for (effectID, request) in effectRequests {
                            if case .projectClone(_, let plan) = request, plan.id == attemptID { effects[effectID]?.cancel() }
                        }
                    }
                    if let attemptID = decision.cancelWorktreeAttempt {
                        for (effectID, request) in effectRequests where request.worktreeAttemptID == attemptID { effects[effectID]?.cancel() }
                    }
                    for (effectID, request) in effectRequests {
                        if let threadID = request.threadID, let attemptID = request.worktreeAttemptID,
                           decision.snapshot.threads.contains(where: { $0.id == threadID && $0.workspacePreparation?.id == attemptID && $0.workspacePreparation?.cancelRequested == true }) { effects[effectID]?.cancel() }
                    }
                    if let operationID = decision.cancelPullRequestCheckoutOperation {
                        for (effectID, request) in effectRequests where request.pullRequestCheckoutOperationID == operationID { effects[effectID]?.cancel() }
                    }
                    codexDefaultReviews = codexDefaultReviews.filter { id, reviewed in
                        decision.snapshot.threads.contains { $0.id == id && $0.projectID == reviewed.projectID }
                    }
                    beginDecisionCleanup(decision, previous: base.snapshot, removedEffects: outcome.removedEffects)
                    recordContextTransferRetirement(envelope.command)
                    recordRemoteThreadActionDrain(envelope.command, id: envelope.id)
                    threadActionUndos.reconcile(snapshot: decision.snapshot, now: Date())
                    if let claim = ThreadActionUndoClaim.capture(envelope.command, id: envelope.id, previous: base.snapshot, next: decision.snapshot) {
                        threadActionUndos.record(claim, now: Date())
                        if case .remoteEnvironment(let request, _) = envelope.command, let owner = request.undoOwner, remoteThreadActionOwners[owner.leaseID] == owner {
                            _ = threadActionUndos.take(forwardID: envelope.id, ownerID: owner.leaseID, now: Date())
                        }
                    }
                    if case .remoteEnvironment(_, .threadActions(let prepared)) = envelope.command {
                        for claim in prepared.claims { threadActionUndos.consume(claim.id) }
                    }
                    if case .client(.threadActionUndo(let claim)) = envelope.command { threadActionUndos.consume(claim.id) }
                    committed = true
                    publish()
                    envelope.continuation.resume(returning: receipt)
                    scheduleEffects()
                    scheduleDelegatedTaskCompletions()
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
        pullRequestActionReviews = pullRequestActionReviews.filter { !removedProjects.contains($0.value.operation.projectID) }
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
        if project.scratch != nil { return nil }
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
        for project in revision.snapshot.projects where project.scratch == nil && (project.clone == nil || project.clone?.isReady == true) {
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
        case .conversationHistory: historyIncarnation = effect.request.threadID.flatMap { threadIncarnations[$0] }
        default: historyIncarnation = nil
        }
        let historyFilesIncarnation: UUID?
        if case .conversationHistoryFiles = effect.request { historyFilesIncarnation = effect.request.threadID.flatMap { threadIncarnations[$0] } }
        else { historyFilesIncarnation = nil }
        let actionIncarnation = effect.request.pullRequestActionOperationID == nil ? nil : effect.request.projectID.flatMap { projectIncarnations[$0] }
        let pullRequestIncarnation = effect.request.pullRequestCreationOperationID == nil ? nil : effect.request.projectID.flatMap { projectIncarnations[$0] }
        let checkoutIncarnation = effect.request.pullRequestCheckoutOperationID == nil ? nil : effect.request.projectID.flatMap { projectIncarnations[$0] }
        let restoreIncarnation = effect.request.checkpointRestoreOperationID == nil ? nil : effect.request.threadID.flatMap { threadIncarnations[$0] }
        defer {
            effects.removeValue(forKey: effect.id); effectRequests.removeValue(forKey: effect.id)
            if let id = effect.request.pullRequestActionOperationID { pullRequestActionReviews.removeValue(forKey: id) }
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
            let message = actionIncarnation != nil ? PullRequestActionOperation.failureMessage : checkoutIncarnation != nil ? PullRequestCheckoutOperation.failureMessage : pullRequestIncarnation != nil ? PullRequestCreationOperation.failureMessage : historyFilesIncarnation != nil ? ConversationHistoryFilesState.failureMessage : restoreIncarnation != nil ? RunCheckpointRestoreOperation.failureMessage : historyIncarnation != nil ? ConversationHistoryOperation.failureMessage : effect.request.checkpointOwner != nil ? ThreadRunCheckpointAttempt.failureMessage : effect.request.projectScriptRunID != nil ? ThreadProjectScriptRun.executionError(for: effect.request.projectScriptOwner?.role ?? .setup) : effect.request.projectID == nil && effect.request.worktreeAttemptID == nil ? error.localizedDescription : String(GitService.redactURLs(error.localizedDescription).prefix(4_000))
            result = .failed(message)
        }
        heartbeat.cancel()
        if !closing, fatalError == nil {
            do {
                let owned: Bool
                switch result {
                case .promptSteeringDelivered, .promptSteeringUnconfirmed, .promptSteeringUnsentCompleted, .succeeded, .stopped, .worktreeResolved, .worktreePrepared, .projectScriptResolved, .checkpointResolved, .checkpointCaptured, .checkpointUnavailable, .conversationHistoryConfirmed, .conversationHistoryUnconfirmed, .checkpointRestoreConfirmed, .checkpointRestoreUnconfirmed, .pullRequestCreationConfirmed, .pullRequestCreationUnconfirmed, .pullRequestActionConfirmed, .pullRequestActionUnconfirmed, .pullRequestCheckoutCompleted, .pullRequestCheckoutUnconfirmed: owned = try await database.settleEffect(effect.id, workerID: workerID)
                case .failed(let message): owned = try await database.settleEffect(effect.id, workerID: workerID, error: message)
                case .cancelled: owned = try await database.cancelEffect(effect.id, workerID: workerID, reason: "The targeted run or request is no longer active.")
                }
                guard owned else { await infrastructureFailed("Provider execution lost its workspace lease."); return }
                if let steeringIncarnation {
                    if !retiringEffects.contains(effect.id) { _ = try await enqueue(.promptSteeringEffectResult(effect.request, result, incarnation: steeringIncarnation)) }
                } else if let checkoutIncarnation {
                    if !retiringEffects.contains(effect.id) { _ = try await enqueue(.pullRequestCheckoutEffectResult(effect.request, result, incarnation: checkoutIncarnation)) }
                } else if let actionIncarnation {
                    if !retiringEffects.contains(effect.id) { _ = try await enqueue(.pullRequestActionEffectResult(effect.request, result, incarnation: actionIncarnation)) }
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
        if case .contextCompaction = request { return await performContextCompaction(request) }
        if case .promptSteering = request { return await performPromptSteering(request) }
        if case .pullRequestAction = request { return try await performPullRequestAction(request) }
        if case .pullRequestCreation = request { return try await performPullRequestCreation(request) }
        if case .pullRequestCheckout = request { return try await performPullRequestCheckout(request) }
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
        case .contextCompaction, .promptSteering, .pullRequestCheckout, .pullRequestCreation, .pullRequestAction, .conversationHistoryFiles, .checkpointRestore, .conversationHistory, .resolveRunCheckpoint, .captureRunCheckpoint, .resolveThreadScript, .startThreadScript, .resolveProjectScript, .startProjectScript, .resolveWorktree, .prepareWorktree, .projectClone: return .cancelled // Preparation/project actions are handled before thread lookup.
        case .providerStart(_, let runID, let capturedConfiguration, let prompt, let references):
            guard !revision.snapshot.isOriginalImportedSession(configuration: capturedConfiguration, threadID: thread.id) else {
                return .failed("This older import must continue in an independent Coincide copy. Send a new message after this turn stops.")
            }
            if thread.scratchWorkspace != nil { try scratchWorkspaces.validate(thread: thread) }
            var configuration = capturedConfiguration
            guard thread.activeRun?.id == runID, thread.activeRun?.stopRequested == false, !isCodexAuthenticationLocked(configuration) else { return .cancelled }
            guard !providerHistoryScopeLocked(configuration: configuration,
                nativeThreadID: configuration.nativeThreadID ?? thread.runHistory?.first(where: { $0.id == runID })?.providerThreadID ?? thread.providerThreadID) else { return .failed("This provider conversation is held by a pending history action.") }
            await awaitCheckpointDrains(threadID: thread.id)
            guard checkpointProviderReleased(threadID: thread.id, runID: runID) else { return .cancelled }
            var input = try await attachments.prepare(text: prompt, attachments: references ?? [])
            guard !closing, !stoppingEffects, !isCodexAuthenticationLocked(configuration),
                  revision.snapshot.workspaceReady(for: thread),
                  revision.snapshot.threads.first(where: { $0.id == thread.id })?.activeRun?.id == runID,
                  revision.snapshot.threads.first(where: { $0.id == thread.id })?.activeRun?.stopRequested == false else { return .cancelled }
            var configured = thread
            configured.provider = configuration.provider; configured.workspacePath = configuration.workspacePath
            configured.providerThreadID = configuration.nativeThreadID; configured.model = configuration.model; configured.reasoningEffort = configuration.reasoningEffort; configured.permission = configuration.permission
            configured.codexRuntimeConfiguration = configuration.codexRuntimeConfiguration; configured.claudeRuntimeConfiguration = configuration.claudeRuntimeConfiguration; configured.agentModeID = configuration.agentModeID
            configured.agentConfigValues = configuration.agentConfigValues
            configured.agentConfiguration = configuration.agentConfiguration
            var runtime = try await runtime(for: configured, runID: runID)
            if await waitForRemovalCommit(threadID: thread.id, projectID: thread.projectID) { return .cancelled }
            guard !closing, !stoppingEffects, !isCodexAuthenticationLocked(configuration), revision.snapshot.threads.first(where: { $0.id == thread.id })?.activeRun?.id == runID,
                  revision.snapshot.workspaceReady(for: thread),
                  revision.snapshot.threads.first(where: { $0.id == thread.id })?.activeRun?.stopRequested == false,
                  runtimes[thread.id]?.id == runtime.id else { return .cancelled }
            try Task.checkCancellation()
            guard !providerHistoryScopeLocked(configuration: configuration,
                nativeThreadID: configuration.nativeThreadID ?? revision.snapshot.threads.first(where: { $0.id == thread.id })?.runHistory?.first(where: { $0.id == runID })?.providerThreadID ?? configured.providerThreadID) else { return .failed("This provider conversation is held by a pending history action.") }
            var contextDelivery = thread.activeRun?.contextDelivery
            if let delivery = contextDelivery {
                let disposition = try await runtime.session.contextInputDisposition(input: input, thread: configured)
                guard ownsRun(threadID: thread.id, projectID: thread.projectID, runID: runID),
                      runtimes[thread.id]?.id == runtime.id,
                      revision.snapshot.threads.first(where: { $0.id == thread.id })?.activeRun?.stopRequested == false else { throw CancellationError() }
                if disposition == .nativeCommand {
                    let nativeFork = delivery.transferIDs.contains { revision.snapshot.contextTransfer($0)?.review.strategy == .nativeFork }
                    let refused = try await enqueue(.contextTransferDeferred(threadID: thread.id, runID: runID, deliveryID: delivery.id))
                    guard refused.rejection == nil else { throw ContextTransferError.staleReview }
                    contextDelivery = nil
                    if let current = revision.snapshot.threads.first(where: { $0.id == thread.id }) {
                        configured.activeRun = current.activeRun; configured.runHistory = current.runHistory
                    }
                    if nativeFork { throw WorkspaceCommandError("Send an ordinary message to complete the reviewed native fork before running a native command.") }
                }
            }
            if let delivery = contextDelivery {
                let retrieval = (appMCPEnabled || contextMCPEnabled) && runtime.session.supportsAppMCP && runtime.mcpScope?.capabilities.contains(.contextRead) == true
                let selection = try revision.snapshot.contextSelection(for: delivery, retrievalAvailable: retrieval)
                let prepared = try await enqueue(.contextTransferSelectionPrepared(threadID: thread.id, runID: runID, deliveryID: delivery.id, selection: selection))
                guard prepared.rejection == nil,
                      let saved = revision.snapshot.threads.first(where: { $0.id == thread.id })?.activeRun?.contextDelivery,
                      saved.id == delivery.id else { throw ContextTransferError.staleReview }
                contextDelivery = saved
            }
            if let delivery = contextDelivery {
                guard delivery.status == .reserved, delivery.runID == runID,
                      delivery.authoredText?.utf8.elementsEqual(prompt.utf8) == true,
                      ContextTransferProtocol.same(delivery.authoredAttachments ?? [], references ?? []) else { throw ContextTransferError.uncertain }
                let marker = try await enqueue(.contextTransferDispatching(threadID: thread.id, runID: runID, deliveryID: delivery.id, runtimeID: runtime.id))
                guard marker.rejection == nil else { throw ContextTransferError.uncertain }
                do {
                    let native = delivery.transferIDs.compactMap { revision.snapshot.contextTransfer($0)?.review.nativeReview }
                    if let review = native.first {
                        guard native.count == 1, delivery.transferIDs.count == 1 else { throw ContextTransferError.unavailable }
                        let snapshot = try await ContextTransferNativeDelivery.apply(review: review, configuration: configuration, session: runtime.session) { [weak self] publication in
                            guard let self else { throw CancellationError() }
                            let receipt = try await self.enqueue(.contextTransferNativeReserved(threadID: thread.id, runID: runID, deliveryID: delivery.id, publication: publication))
                            guard receipt.rejection == nil else { throw ContextTransferError.uncertain }
                        }
                        let receipt = try await enqueue(.contextTransferNativeReady(threadID: thread.id, runID: runID, deliveryID: delivery.id, snapshot: snapshot))
                        guard receipt.rejection == nil,
                              let current = revision.snapshot.threads.first(where: { $0.id == thread.id }), current.activeRun?.id == runID,
                              current.activeRun?.stopRequested == false else { throw ContextTransferError.uncertain }
                        configuration = current.activeRun!.configuration; configured.providerThreadID = snapshot.reference.nativeThreadID
                        configured.activeRun = current.activeRun; configured.runHistory = current.runHistory
                        configured.claudeResumeSelection = current.claudeResumeSelection; configured.claudeInheritedHead = current.claudeInheritedHead
                        if [.codex, .claude].contains(configuration.provider) {
                            let previous = runtime.id
                            await closeRuntime(thread.id, matching: previous)
                            guard ownsRun(threadID: thread.id, projectID: thread.projectID, runID: runID),
                                  revision.snapshot.threads.first(where: { $0.id == thread.id })?.activeRun?.stopRequested == false else { throw CancellationError() }
                            runtime = try await self.runtime(for: configured, runID: runID)
                            let rebound = try await enqueue(.contextTransferRuntimeRebound(threadID: thread.id, runID: runID, deliveryID: delivery.id, previousRuntimeID: previous, runtimeID: runtime.id))
                            guard rebound.rejection == nil else { throw ContextTransferError.uncertain }
                        }
                    } else {
                        input.historicalContext = .init(deliveryID: delivery.id, transferIDs: delivery.transferIDs, selection: delivery.selection)
                    }
                } catch {
                    _ = try? await enqueue(.contextTransferUncertain(threadID: thread.id, runID: runID, deliveryID: delivery.id))
                    throw error
                }
            }
            do {
            if configuration.provider == .claude, runtimes[thread.id]?.id == runtime.id {
                // Controls may be applied before a user-frame failure. Keep
                // the attempt so clearing effort still recreates its actor.
                runtimes[thread.id]?.claudeModelOptions = try ClaudeModelControl.options(in: configuration)
            }
            if configured.scratchWorkspace != nil { try scratchWorkspaces.validate(thread: configured) }
            try await runtime.session.send(input: input, thread: configured)
            if let delivery = contextDelivery {
                let receipt = try await enqueue(.contextTransferDelivered(threadID: thread.id, runID: runID, deliveryID: delivery.id))
                guard receipt.rejection == nil else { throw ContextTransferError.uncertain }
            }
            return .succeeded
            } catch {
                if let delivery = contextDelivery { _ = try? await enqueue(.contextTransferUncertain(threadID: thread.id, runID: runID, deliveryID: delivery.id)) }
                throw error
            }
        case .providerInterrupt(_, let runID):
            guard thread.activeRun?.id == runID else { return .cancelled }
            let expectedRuntimeID = runtimes[thread.id]?.id
            if let runtime = runtimes[thread.id], runtime.id == thread.runtimeID,
               runtime.codexBinding == thread.activeRun?.configuration.codexRuntimeBinding,
               thread.activeRun?.nativeTurnID != nil {
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
                if let task = revision.snapshot.delegatedTasks?.first(where: { $0.childThreadID == threadID && $0.request.isolation == .worktree }) { try await validateTaskIsolation(task, plan: plan) }
                return .worktreeResolved(plan)
            } catch {
                if await waitForRemovalCommit(threadID: threadID, projectID: thread.projectID) { throw CancellationError() }
                guard ownsWorktree(threadID: threadID, attemptID: attemptID, incarnation: incarnation) else { throw CancellationError() }
                throw error
            }
        case .prepareWorktree(_, let plan):
            guard state.plan == plan, state.phase == .preparing else { return .cancelled }
            do {
                if let task = revision.snapshot.delegatedTasks?.first(where: { $0.childThreadID == threadID && $0.request.isolation == .worktree }) { try await validateTaskIsolation(task, plan: plan) }
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
        let retired = contextTransferRetirements.values.filter { $0.threadID == thread.id }.map(\.task)
        for task in retired { await task.value }
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
        if let existing = runtimes[thread.id], existing.provider == thread.provider, existing.path == thread.workspacePath, existing.codexBinding == ProviderConfiguration(thread: thread).codexRuntimeBinding, claudeRuntimeMatches(existing, thread: thread) {
            let needsContextScope = contextMCPEnabled && thread.activeRun?.contextTransferIDs?.isEmpty == false && existing.session.supportsAppMCP
            if !appMCPEnabled, (existing.mcpScope != nil) != needsContextScope {
                // Context-only tools belong to one explicitly contextual run.
                // Resume the same captured native conversation without retaining
                // an unusable app-tool registration on an ordinary successor.
                await closeRuntime(thread.id, matching: existing.id)
                return try await runtime(for: thread, runID: runID)
            }
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
        var runtime = Runtime(id: id, projectID: thread.projectID, session: session, provider: thread.provider, path: thread.workspacePath, codexBinding: ProviderConfiguration(thread: thread).codexRuntimeBinding, claudeConfiguration: thread.claudeRuntimeConfiguration, claudeLaunchSelection: thread.activeRun?.configuration.claudeLaunchSelection, claudeNativeID: thread.providerThreadID)
        if thread.provider == .claude { runtime.claudeModelOptions = try ClaudeModelControl.options(in: configuration) }
        runtimes[thread.id] = runtime
        do { runtime.mcpScope = try await configureAppMCP(thread: thread, runID: runID, runtimeID: id, session: session, configuration: configuration) }
        catch { await closeRuntime(thread.id, matching: id); throw error }
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
        }
        if runtimes[thread.id]?.id == id { runtimes[thread.id] = runtime }
        else { runtime.reader?.cancel(); throw CancellationError() }
        return runtime
    }
    private func ownsRun(threadID: UUID, projectID: UUID, runID: UUID) -> Bool {
        guard !closing, !stoppingEffects, fatalError == nil,
              let thread = revision.snapshot.threads.first(where: { $0.id == threadID && $0.projectID == projectID }),
              thread.activeRun?.id == runID, thread.activeRun?.stopRequested == false,
              thread.activeRun.map({ !isCodexAuthenticationLocked($0.configuration) }) == true,
              revision.snapshot.workspaceReady(for: thread) else { return false }
        return true
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
        threadActionUndos.removeAll(); remoteThreadActionOwners.removeAll()
        guard fatalError == nil else { return }
        fatalError = "Workspace execution stopped: \(message)"; publish()
        // A lifecycle worker can be waiting on an envelope behind this failed
        // command. Cancel now; the inbox must advance before owned shutdown joins.
        await stopWorkspaceLifecycle()
        for task in effects.values { task.cancel() }
        cancelIdentityRefreshes()
        cancelCheckpointReads()
        for read in historyReads.values { read.cancel() }
        historyReviews = [:]
        checkpointRestoreReviews = [:]
        pullRequestCreationReviews = [:]; pullRequestCheckoutReviews = [:]; pullRequestActionReviews = [:]; codexDefaultReviews = [:]
        for read in pullRequestReads.values { read.cancel() }
        let inspections = worktreeInspections; worktreeInspections = [:]
        for inspection in inspections.values {
            inspection.task.cancel()
            _ = startCleanup(projectIDs: [inspection.projectID], threadIDs: [inspection.threadID], sessions: [], jobs: [Task { _ = try? await inspection.task.value }])
        }
        for id in Array(runtimes.keys) { await closeRuntime(id) }
        if let job = delegatedTaskDeliveryJob { await job.value }
        for job in Array(delegatedTaskDrains.values) { await job.value }
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
    public func models(provider: ProviderKind, codexRuntimeConfiguration: CodexRuntimeConfiguration? = nil, claudeRuntimeConfiguration: ClaudeRuntimeConfiguration? = nil) async throws -> [ProviderModel] {
        guard provider == .codex || codexRuntimeConfiguration == nil else { throw CodexRuntimeConfiguration.invalid() }
        guard provider == .claude || claudeRuntimeConfiguration == nil else { throw ClaudeRuntimeConfiguration.invalid() }
        try codexRuntimeConfiguration?.validate()
        try claudeRuntimeConfiguration?.validate()
        let path = claudeRuntimeConfiguration?.registeredWorkspacePath ?? FileManager.default.homeDirectoryForCurrentUser.path
        var thread = CodingThread(project: WorkspaceProject(path: path)); thread.provider = provider; thread.workspacePath = path
        thread.codexRuntimeConfiguration = codexRuntimeConfiguration
        thread.claudeRuntimeConfiguration = claudeRuntimeConfiguration
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
    public func models(thread: CodingThread) async throws -> [ProviderModel] {
        _ = try await load()
        guard !closing, !stoppingEffects,
              let current = revision.snapshot.threads.first(where: { $0.id == thread.id && $0.projectID == thread.projectID }),
              revision.snapshot.projects.contains(where: { $0.id == thread.projectID }),
              current.provider == thread.provider, current.workspacePath == thread.workspacePath, ProviderConfiguration(thread: current).codexRuntimeBinding == ProviderConfiguration(thread: thread).codexRuntimeBinding, current.claudeRuntimeConfiguration == thread.claudeRuntimeConfiguration else { throw CancellationError() }
        if !revision.snapshot.providerReady(for: current) {
            throw CoincideError("Wait for the workspace to finish preparing before refreshing this agent's models.")
        }
        return try await queryModels(thread: current, owned: true)
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
        guard thread.provider == .claude else { throw ProviderCommandError(.unsupported) }
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
    /// An active caller keeps its captured launch configuration even when the
    /// user edits future-turn preferences. Neutral metadata ownership avoids
    /// rebinding this read to that mutable header; all normal account/history/
    /// workspace locks and owned-session cancellation/drain still apply.
    func appMCPCapturedTaskModels(thread: CodingThread, context: AppMCPContext) async throws -> [ProviderModel] {
        _ = try await appMCPView(context)
        guard thread.id == context.scope.threadID,
              try TaskOrchestration.payload(ProviderConfiguration(thread: thread)) == TaskOrchestration.payload(context.configuration) else {
            throw AppMCPError(.staleCaller)
        }
        let rows = try await queryModels(thread: thread, owned: false)
        _ = try await appMCPView(context)
        return rows
    }
    private func queryModels(thread: CodingThread, owned: Bool) async throws -> [ProviderModel] {
        try await queryProviderMetadata(thread: thread, owned: owned) { try await $0.models() }
    }
    private func queryProviderMetadata<Value: Sendable>(thread: CodingThread, owned: Bool, joinOperation: Bool = false,
                                                       operation: @escaping @Sendable (any ProviderSession) async throws -> Value) async throws -> Value {
        if thread.scratchWorkspace != nil { try scratchWorkspaces.validate(thread: thread) }
        guard !isCodexAuthenticationLocked(.init(thread: thread)) else { throw Self.codexChanging() }
        if owned {
            if await waitForRemovalCommit(threadID: thread.id, projectID: thread.projectID) { throw CancellationError() }
            guard let current = revision.snapshot.threads.first(where: { $0.id == thread.id && $0.projectID == thread.projectID }),
                  current.provider == thread.provider, current.workspacePath == thread.workspacePath, ProviderConfiguration(thread: current).codexRuntimeBinding == ProviderConfiguration(thread: thread).codexRuntimeBinding, current.claudeRuntimeConfiguration == thread.claudeRuntimeConfiguration,
                  revision.snapshot.providerReady(for: current) else { throw CancellationError() }
        }
        guard !closing, !stoppingEffects, !isCodexAuthenticationLocked(.init(thread: thread)),
              !providerHistoryScopeLocked(configuration: .init(thread: thread), nativeThreadID: thread.providerThreadID),
              !revision.snapshot.isClaudeHistoryScopeLocked(configuration: .init(thread: thread), nativeThreadID: thread.providerThreadID),
              !revision.snapshot.isCheckpointRestoreLocked(path: thread.workspacePath), !revision.snapshot.isPullRequestCreationLocked(path: thread.workspacePath), !revision.snapshot.isPullRequestCheckoutLocked(path: thread.workspacePath) else { throw CancellationError() }
        var metadataLaunch = thread
        if metadataLaunch.provider == .codex || metadataLaunch.provider == .claude {
            // Metadata owns the original conversation binding, but it must not
            // ask the factory for a live turn's actor or carry its submissions.
            metadataLaunch.activeRun = nil; metadataLaunch.runtimeID = nil
            metadataLaunch.runtimeRequests = []; metadataLaunch.queuedTurns = []
            metadataLaunch.state = .idle
            if metadataLaunch.provider == .claude {
                metadataLaunch.providerThreadID = nil
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
              thread.provider == configuration.provider, thread.workspacePath == configuration.workspacePath, ProviderConfiguration(thread: thread).codexRuntimeBinding == configuration.codexRuntimeBinding, thread.claudeRuntimeConfiguration == configuration.claudeRuntimeConfiguration,
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
        threadActionUndos.removeAll(); remoteThreadActionOwners.removeAll()
        if let shutdownTask { await shutdownTask.value; return }
        let task = Task { await self.stopRuntime() }; shutdownTask = task
        await task.value
    }
    private func stopRuntime() async {
        if let initialization { _ = try? await initialization.value }
        guard !closing else { return }
        stoppingEffects = true
        await scheduledTaskService?.shutdown(); scheduledTaskService = nil
        await closeWorkspaceLifecycle()
        await closeAgentSessionImports()
        delegatedTaskDeliveryJob?.cancel()
        if loaded, fatalError == nil { _ = try? await enqueue(.pauseQueues) }
        closing = true
        let pullRequestReadJobs = Array(pullRequestReads.values); for read in pullRequestReadJobs { read.cancel() }
        pullRequestCreationReviews = [:]; pullRequestCheckoutReviews = [:]; pullRequestActionReviews = [:]; codexDefaultReviews = [:]
        let history = Array(historyReads.values); historyReads = [:]
        for read in history { read.cancel() }
        let unusedHistoryReviews = Array(historyReviews.values)
        historyReviews = [:]
        contextTransfersClosing = true; contextTransferReviews = [:]
        let unusedRestoreReviews = Array(checkpointRestoreReviews.values)
        checkpointRestoreReviews = [:]
        let inspections = Array(worktreeInspections.values); worktreeInspections = [:]
        for inspection in inspections { inspection.task.cancel() }
        cancelIdentityRefreshes()
        cancelCheckpointReads()
        let jobs = Array(effects.values); for job in jobs { job.cancel() }
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
        while !remoteThreadActionDrains.isEmpty { for task in remoteThreadActionDrains.values.map(\.1) { await task.value } }
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
                                          baseBranch: String?, isDraft: Bool, sourceThreadID: UUID? = nil) async throws -> GitHubPullRequestCreateReview {
        _ = try await load(); try Task.checkCancellation()
        if await waitForRemovalCommit(projectID: projectID) { throw CancellationError() }
        let canonical = URL(fileURLWithPath: workspacePath).standardizedFileURL.resolvingSymlinksInPath().path
        let source = sourceThreadID.flatMap { id in revision.snapshot.threads.first { $0.id == id } }
        let sourceIncarnation = sourceThreadID.flatMap { threadIncarnations[$0] }
        if let sourceThreadID {
            guard let source, source.id == sourceThreadID, source.projectID == projectID, !source.isArchived,
                  sourceIncarnation != nil, URL(fileURLWithPath: source.workspacePath).standardizedFileURL.resolvingSymlinksInPath().path.utf8.elementsEqual(canonical.utf8) else { throw GitHubPullRequestError(.staleReview) }
        }
        let registeredPath = source?.workspacePath ?? workspacePath
        guard !closing, !stoppingEffects, fatalError == nil,
              let project = revision.snapshot.projects.first(where: { $0.id == projectID }),
              let incarnation = projectIncarnations[projectID],
              revision.snapshot.ownsPullRequestWorkspace(projectID: projectID, workspacePath: registeredPath),
              !revision.snapshot.isPullRequestCreationLocked(path: workspacePath),
              !revision.snapshot.isCheckpointRestoreLocked(path: workspacePath) else {
            throw WorkspaceCommandError("Choose an available registered project checkout before reviewing a pull request.")
        }
        let session = try pullRequestFactory(URL(fileURLWithPath: workspacePath))
        let review = try await readPullRequest(projectID: projectID, incarnation: incarnation) {
            try await session.reviewCreate(title: title, body: body, baseBranch: baseBranch, isDraft: isDraft)
        }
        guard review.context.workspacePath == canonical,
              projectIncarnations[projectID] == incarnation else { throw GitHubPullRequestError(.staleReview) }
        if let source {
            guard threadIncarnations[source.id] == sourceIncarnation,
                  revision.snapshot.threads.contains(where: { $0.id == source.id && $0.projectID == source.projectID && !$0.isArchived && $0.createdAt == source.createdAt && $0.workspacePath.utf8.elementsEqual(source.workspacePath.utf8) }) else { throw GitHubPullRequestError(.staleReview) }
        }
        let operation = PullRequestCreationOperation(projectID: projectID, projectPath: project.path, sourceIncarnation: incarnation,
            review: review, registeredWorkspacePath: registeredPath, sourceThreadID: sourceThreadID)
        var admission = WorkspaceDecision(snapshot: revision.snapshot)
        try admission.acceptPullRequestCreation(operation)
        guard pullRequestRuntimeScopeAvailable(operation) else { throw WorkspaceCommandError("Finish workspace scripts and closing jobs before creating a pull request.") }
        pullRequestCreationReviews[review.id] = .init(operation: operation, digest: try pullRequestReviewDigest(review), sourceThreadIncarnation: sourceIncarnation, sourceThreadCreatedAt: source?.createdAt)
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
        try validatePullRequestCreationThread(prepared.operation)
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
    private func validatePullRequestCreationThread(_ operation: PullRequestCreationOperation) throws {
        guard let id = operation.sourceThreadID else { return }
        guard let prepared = pullRequestCreationReviews[operation.id], prepared.operation == operation,
              prepared.sourceThreadIncarnation == threadIncarnations[id], prepared.sourceThreadIncarnation != nil,
              let thread = revision.snapshot.threads.first(where: { $0.id == id && $0.projectID == operation.projectID && !$0.isArchived }),
              thread.createdAt == prepared.sourceThreadCreatedAt, thread.createdAt <= operation.review.reviewedAt,
              thread.workspacePath.utf8.elementsEqual(operation.registeredWorkspacePath.utf8) else { throw WorkspaceCommandError("The reviewed source conversation changed before pull request creation.") }
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
    public func preparePullRequestAction(projectID: UUID, workspacePath: String, action: GitHubPullRequestAction,
        reference: GitHubPullRequestReference, removeAgentCredits: Bool, sourceThreadID: UUID? = nil) async throws -> GitHubPullRequestActionReview {
        _ = try await load(); try Task.checkCancellation(); try reference.validate()
        if await waitForRemovalCommit(projectID: projectID) { throw CancellationError() }
        guard let project = revision.snapshot.projects.first(where: { $0.id == projectID }),
              let incarnation = projectIncarnations[projectID],
              revision.snapshot.ownsPullRequestWorkspace(projectID: projectID, workspacePath: workspacePath),
              !(revision.snapshot.pullRequestActions ?? []).contains(where: { $0.blocksAction && $0.review.state.reference == reference }) else {
            throw GitHubPullRequestActionError(.staleReview)
        }
        let source = sourceThreadID.flatMap { id in revision.snapshot.threads.first { $0.id == id } }
        let sourceIncarnation = sourceThreadID.flatMap { threadIncarnations[$0] }
        if let sourceThreadID {
            guard let source, source.id == sourceThreadID, source.projectID == projectID, !source.isArchived,
                  sourceIncarnation != nil, URL(fileURLWithPath: source.workspacePath).standardizedFileURL.resolvingSymlinksInPath().path.utf8.elementsEqual(URL(fileURLWithPath: workspacePath).standardizedFileURL.resolvingSymlinksInPath().path.utf8) else {
                throw GitHubPullRequestActionError(.staleReview)
            }
        }
        let session = try pullRequestActionFactory(URL(fileURLWithPath: workspacePath))
        let (review, proof) = try await readPullRequest(projectID: projectID, incarnation: incarnation) {
            let capture = TaskIsolationCapture()
            let proof = try await capture.capture(parentWorkspacePath: workspacePath, projectPath: project.path)
            let review = try await session.reviewAction(action, reference: reference, removeAgentCredits: removeAgentCredits)
            try await capture.validate(proof, requireCurrentHead: false)
            return (review, proof)
        }
        try review.validate()
        guard review.action == action, review.state.reference == reference,
              projectIncarnations[projectID] == incarnation else { throw GitHubPullRequestActionError(.staleReview) }
        let operation = PullRequestActionOperation(projectID: projectID, projectPath: project.path,
            registeredWorkspacePath: source?.workspacePath ?? workspacePath, repositoryPath: proof.sourceRepositoryPath,
            commonDirectoryPath: proof.commonDirectoryPath, sourceIncarnation: incarnation,
            sourceThreadID: sourceThreadID, review: review)
        let prepared = PreparedPullRequestAction(operation: operation, digest: try pullRequestActionDigest(review), proof: proof,
            sourceThreadIncarnation: sourceIncarnation, sourceThreadCreatedAt: source?.createdAt)
        pullRequestActionReviews[review.id] = prepared
        do {
            try validatePullRequestActionThread(operation)
            var decision = WorkspaceDecision(snapshot: revision.snapshot); try decision.acceptPullRequestAction(operation)
        } catch { pullRequestActionReviews.removeValue(forKey: review.id); throw error }
        return review
    }

    public func discardPullRequestActionReview(reviewID: UUID) {
        guard !acceptingPullRequestActions.contains(reviewID), revision.snapshot.pullRequestAction(reviewID) == nil else { return }
        pullRequestActionReviews.removeValue(forKey: reviewID)
    }

    @discardableResult public func beginPullRequestAction(projectID: UUID, review: GitHubPullRequestActionReview) async throws -> WorkspaceCommandReceipt {
        _ = try await load(); try Task.checkCancellation()
        // An original admission receipt survives project removal, a new process,
        // and loss of the UI reply. Never turn that read into another dispatch.
        if let existing = revision.snapshot.pullRequestAction(review.id) {
            guard existing.projectID == projectID, try pullRequestActionDigest(existing.review) == pullRequestActionDigest(review) else {
                throw WorkspaceCommitError.commandIDCollision
            }
            guard let receipt = try await database.receipt(review.id) else { throw GitHubPullRequestActionError(.refused) }
            return receipt
        }
        try review.validate()
        guard !closing, !stoppingEffects, fatalError == nil,
              let prepared = pullRequestActionReviews[review.id], prepared.operation.projectID == projectID else {
            throw GitHubPullRequestActionError(.staleReview)
        }
        guard prepared.digest == (try pullRequestActionDigest(review)) else { throw WorkspaceCommitError.commandIDCollision }
        try validatePullRequestActionThread(prepared.operation)
        let incarnation = prepared.operation.sourceIncarnation
        _ = try await readPullRequest(projectID: projectID, incarnation: incarnation) {
            try await TaskIsolationCapture().validate(prepared.proof, requireCurrentHead: false)
        }
        // Keep the prepared value through queued concurrent admissions. The
        // database compares their exact payload and returns the same receipt.
        acceptingPullRequestActions.insert(review.id)
        defer { acceptingPullRequestActions.remove(review.id) }
        return try await enqueue(.pullRequestActionAccepted(prepared.operation), id: review.id)
    }

    @discardableResult public func inspectPullRequestAction(operationID: UUID) async throws -> WorkspaceCommandReceipt {
        _ = try await load(); try Task.checkCancellation()
        guard let operation = revision.snapshot.pullRequestAction(operationID), operation.requiresAcknowledgment,
              let incarnation = projectIncarnations[operation.projectID] else { throw GitHubPullRequestActionError(.refused) }
        try revision.snapshot.validatePullRequestActionSource(operation)
        let session = try pullRequestActionFactory(URL(fileURLWithPath: operation.registeredWorkspacePath))
        let state = try await readPullRequest(projectID: operation.projectID, incarnation: incarnation) {
            try await session.actionState(operation.review.state.reference)
        }
        try state.validate()
        guard revision.snapshot.pullRequestAction(operationID) == operation else { throw GitHubPullRequestActionError(.staleReview) }
        let receipt = try await enqueue(.pullRequestActionInspected(operationID: operationID, incarnation: incarnation, state: state))
        if let rejection = receipt.rejection { throw WorkspaceCommandError(rejection) }
        return receipt
    }

    @discardableResult public func acknowledgePullRequestAction(operationID: UUID) async throws -> WorkspaceCommandReceipt {
        _ = try await load(); try Task.checkCancellation()
        let receipt = try await enqueue(.pullRequestActionAcknowledged(operationID: operationID))
        if let rejection = receipt.rejection { throw WorkspaceCommandError(rejection) }
        return receipt
    }

    private func pullRequestActionDigest(_ review: GitHubPullRequestActionReview) throws -> String {
        SHA256.hash(data: try encoder.encode(review)).map { String(format: "%02x", $0) }.joined()
    }

    private func validatePullRequestActionThread(_ operation: PullRequestActionOperation) throws {
        guard let prepared = pullRequestActionReviews[operation.id], prepared.operation == operation,
              projectIncarnations[operation.projectID] == operation.sourceIncarnation else { throw GitHubPullRequestActionError(.staleReview) }
        try revision.snapshot.validatePullRequestActionSource(operation)
        guard let id = operation.sourceThreadID else { return }
        guard prepared.sourceThreadIncarnation != nil, prepared.sourceThreadIncarnation == threadIncarnations[id],
              let thread = revision.snapshot.threads.first(where: { $0.id == id && $0.projectID == operation.projectID && !$0.isArchived }),
              thread.createdAt == prepared.sourceThreadCreatedAt, thread.createdAt <= operation.review.reviewedAt,
              thread.workspacePath.utf8.elementsEqual(operation.registeredWorkspacePath.utf8) else { throw GitHubPullRequestActionError(.staleReview) }
    }

    private func ownsPullRequestActionEvent(_ command: EngineCommand) -> Bool {
        switch command {
        case .pullRequestActionAccepted(let operation): return projectIncarnations[operation.projectID] == operation.sourceIncarnation
        case .pullRequestActionDispatching(let projectID, _, let incarnation): return projectIncarnations[projectID] == incarnation
        case .pullRequestActionEffectResult(let request, _, let incarnation): return request.projectID.map { projectIncarnations[$0] == incarnation } ?? false
        case .pullRequestActionInspected(let id, let incarnation, _): return revision.snapshot.pullRequestAction(id).map { projectIncarnations[$0.projectID] == incarnation } ?? false
        default: return true
        }
    }

    private func performPullRequestAction(_ request: WorkspaceEffectRequest) async throws -> EffectResult {
        guard case .pullRequestAction(let projectID, let operationID, let effectID) = request,
              let operation = revision.snapshot.pullRequestAction(operationID), operation.phase == .accepted,
              operation.effectID == effectID, operation.projectID == projectID,
              let prepared = pullRequestActionReviews[operationID] else { return .cancelled }
        var apiStarted = false
        do {
            try validatePullRequestActionThread(operation)
            try await TaskIsolationCapture().validate(prepared.proof, requireCurrentHead: false)
            try validatePullRequestActionThread(operation); try Task.checkCancellation()
            let session = try pullRequestActionFactory(URL(fileURLWithPath: operation.registeredWorkspacePath))
            let receipt = try await enqueue(.pullRequestActionDispatching(projectID: projectID, operationID: operationID, incarnation: operation.sourceIncarnation))
            guard receipt.rejection == nil, revision.snapshot.pullRequestAction(operationID)?.phase == .dispatching,
                  projectIncarnations[projectID] == operation.sourceIncarnation else { throw GitHubPullRequestActionError(.staleReview) }
            try Task.checkCancellation(); apiStarted = true
            let outcome = try await session.perform(operation.review)
            guard projectIncarnations[projectID] == operation.sourceIncarnation else { return .pullRequestActionUnconfirmed }
            var completed = operation; completed.phase = .succeeded; completed.outcome = outcome; try completed.validate()
            return .pullRequestActionConfirmed(outcome)
        } catch {
            // Workflow approval may have applied an earlier item. Neither a
            // partial GraphQL error nor a failed response proves a remote no-op.
            return apiStarted ? .pullRequestActionUnconfirmed : .failed(PullRequestActionOperation.failureMessage)
        }
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
        if case .defaultWorktreeSubmission(let input, _) = command {
            try validateCodexAuthenticationAdmission(.client(.submit(threadID: input.threadID, text: input.text)), snapshot: snapshot)
            return
        }
        if case .retryDefaultWorktree(let id, _) = command {
            try validateCodexAuthenticationAdmission(.client(.resumeQueue(threadID: id)), snapshot: snapshot)
            return
        }
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
        case .contextCompactionAccepted(let operation): configurations = [operation.configuration]
        case .promptSteeringAccepted(let operation): configurations = [operation.configuration]
        case .conversationHistoryAccepted(let review, _, _): configurations = [review.sourceConfiguration, review.targetConfiguration]
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
        revision.snapshot.isClaudeHistoryScopeLocked(configuration: configuration, nativeThreadID: nativeThreadID)
    }

    private static func claudeScopes(_ configuration: ProviderConfiguration) -> Set<ClaudeHistoryScope> {
        guard configuration.provider == .claude, let runtime = configuration.claudeRuntimeConfiguration,
              let native = configuration.nativeThreadID ?? configuration.claudeLaunchSelection?.nativeSessionID else { return [] }
        return [.init(configurationDirectory: runtime.configurationDirectory, nativeSessionID: native)]
    }

    private func claudeRuntimeMatches(_ runtime: Runtime, thread: CodingThread) -> Bool {
        guard thread.provider == .claude else { return runtime.claudeConfiguration == nil }
        let next = thread.activeRun?.configuration ?? ProviderConfiguration(thread: thread)
        var previous = next
        do { previous.agentConfiguration = try ClaudeModelControl.setting(runtime.claudeModelOptions ?? .init(), in: nil) }
        catch { return false }
        return runtime.claudeConfiguration == thread.claudeRuntimeConfiguration &&
            runtime.claudeLaunchSelection == thread.activeRun?.configuration.claudeLaunchSelection &&
            (runtime.claudeNativeID == nil || runtime.claudeNativeID == thread.providerThreadID) &&
            !ClaudeModelControl.requiresNewSession(previous: previous, next: next)
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
              !isCodexAuthenticationLocked(thread),
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
        case .delegatedTaskAccepted(let prepared):
            guard threadIncarnations[prepared.request.parentThreadID] == prepared.parentIncarnation,
                  runtimes[prepared.request.parentThreadID]?.id == prepared.parentRuntimeID,
                  prepared.worktree == nil || prepared.worktree?.destinationRoot == worktreesRoot.path else { throw DelegatedTaskError.staleParent }
        case .promptSteeringAccepted(let operation):
            guard threadIncarnations[operation.threadID] == operation.sourceIncarnation,
                  runtimes[operation.threadID]?.id == operation.runtimeID else { throw WorkspaceCommandError(AppMCPError(.staleCaller).localizedDescription) }
        case .conversationHistoryAccepted(let review, _, _):
            guard threadIncarnations[review.sourceThreadID] == review.sourceIncarnation else { throw WorkspaceCommandError(AppMCPError(.staleCaller).localizedDescription) }
        case .beginWorktreePreparation(let threadID, let request, _, _, let incarnation, _, _):
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
        }, contextRead: { [weak self] arguments, context in
            guard let self else { throw AppMCPError(.staleCaller) }
            return try await self.appMCPContextRead(arguments, context: context)
        }), allowedToolNames: appMCPEnabled ? nil : ["t3_context_read"])
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
        guard appMCPEnabled || contextMCPEnabled, !closing, !stoppingEffects, fatalError == nil else { throw AppMCPError(.unavailable) }
        if let mcpServer { return mcpServer }
        let task: Task<MCPHTTPServer, any Error>
        if let pending = mcpServerStart { task = pending }
        else {
            let registry = mcpRegistry, tools = appMCPTools()
            task = Task { [weak self] in
                guard let self else { throw AppMCPError(.staleCaller) }
                return try await MCPHTTPServer.start(registry: registry, tools: tools.descriptors, requestTimeout: .seconds(3_660), invoke: { [weak self] invocation in
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
        guard (appMCPEnabled || (contextMCPEnabled && thread.activeRun?.contextTransferIDs?.isEmpty == false)), session.supportsAppMCP else { return nil }
        let server = try await ensureAppMCPServer()
        guard ownsRun(threadID: thread.id, projectID: thread.projectID, runID: runID),
              runtimes[thread.id]?.id == runtimeID, let incarnation = threadIncarnations[thread.id] else { throw CancellationError() }
        let scope = MCPInvocationScope(threadID: thread.id, projectID: thread.projectID, provider: configuration.provider,
            runtimeID: runtimeID, incarnation: incarnation, providerInstanceID: try AppMCPAdmission.instanceID(configuration: configuration),
            workspacePath: configuration.workspacePath, permission: configuration.permission,
            capabilities: appMCPEnabled ? [.orchestration, .worktree, .contextRead] : [.contextRead])
        runtimes[thread.id]?.mcpScope = scope
        let credential = try await mcpRegistry.issue(scope: scope)
        do {
            guard ownsRun(threadID: thread.id, projectID: thread.projectID, runID: runID), runtimes[thread.id]?.mcpScope?.sessionID == scope.sessionID else { throw CancellationError() }
            try await session.configureAppMCP(AppMCPConnection(endpoint: server.endpoint, authorizationHeader: credential.authorizationHeader, scopeID: scope.sessionID,
                requiredToolName: appMCPEnabled ? "t3_thread_read" : "t3_context_read"))
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
    func remoteAttachmentThread(_ target: RemoteAttachmentTarget, allowArchived: Bool = false) async throws -> CodingThread {
        _ = try await load()
        guard !closing, !stoppingEffects, fatalError == nil,
              let thread = revision.snapshot.threads.first(where: { $0.id == target.threadID && $0.projectID == target.projectID }),
              allowArchived || !thread.isArchived,
              revision.snapshot.projects.contains(where: { $0.id == target.projectID }) else { throw RemoteAttachmentFailure(.invalidTarget) }
        return thread
    }
    func registerRemoteAttachment(_ request: RemoteAttachmentUploadRequest, attachment: ChatAttachment) async throws {
        _ = try await remoteAttachmentThread(request.target)
        try await database.publishRemoteAttachment(.init(upload: request, attachment: attachment, claimedBy: nil, cancelled: false))
    }
    func remoteAttachmentRecord(_ target: RemoteAttachmentTarget, id: UUID) async throws -> RemoteAttachmentRecord? {
        try await database.remoteAttachment(target, id: id)
    }
    func cancelRemoteAttachment(_ target: RemoteAttachmentTarget, id: UUID) async throws -> RemoteAttachmentRecord? {
        try await database.cancelRemoteAttachment(target, id: id)
    }
    func resolveRemoteAttachment(_ target: RemoteAttachmentTarget, id: UUID) async throws -> ChatAttachment {
        let thread = try await remoteAttachmentThread(target, allowArchived: true)
        if let row = try await database.remoteAttachment(target, id: id) {
            guard !row.cancelled else { throw RemoteAttachmentFailure(.notFound) }; return row.attachment
        }
        let refs = thread.draftAttachments + thread.queuedTurns.flatMap { $0.attachments ?? [] } + thread.messages.flatMap { $0.attachments ?? [] }
        guard let reference = refs.first(where: { $0.id == id }) else { throw RemoteAttachmentFailure(.notFound) }
        return reference
    }
    func prepareRemoteAttachmentSubmission(_ command: RemoteEnvironmentCommand) async throws -> RemoteEnvironmentPreparation {
        let target: RemoteAttachmentTarget, ids: [UUID]
        switch command {
        case .submitWithAttachments(let value, _, _, _, let uploads): target = value; ids = uploads
        case .submitComposerDraft(let input): target = input.target; ids = input.uploadedAttachmentIDs
        default: throw RemoteAttachmentFailure(.invalidRequest)
        }
        _ = try await remoteAttachmentThread(target)
        guard ids.count <= AttachmentLimits.count, Set(ids).count == ids.count,
              let incarnation = threadIncarnations[target.threadID] else { throw RemoteAttachmentFailure(.invalidRequest) }
        var records: [RemoteAttachmentRecord] = []
        for id in ids {
            guard let record = try await database.remoteAttachment(target, id: id), !record.cancelled else { throw RemoteAttachmentFailure(.notFound) }
            guard record.claimedBy == nil else { throw RemoteAttachmentFailure(.collision) }
            records.append(record)
        }
        return .attachments(.init(target: target, incarnation: incarnation, records: records))
    }
    /// Capture the same native intent/recovery proof used by local preparation,
    /// without committing under a generated command ID. The external UUID is
    /// committed once, after the final snapshot and incarnation guards.
    func prepareRemoteWorktree(_ command: RemoteEnvironmentCommand, expectedSourceIdentity: GitWorktreeNodeIdentity? = nil) async throws -> RemoteEnvironmentPreparation {
        _ = try await load()
        let target: RemoteWorkspaceTarget, attempt: UUID?
        switch command {
        case .prepareWorktree(let value, _, _, _, _): target = value; attempt = nil
        case .retryWorktree(let value, let id), .inspectWorktree(let value, let id): target = value; attempt = id
        default: return .none
        }
        if await waitForRemovalCommit(threadID: target.threadID) { throw CancellationError() }
        try Task.checkCancellation()
        let thread = try RemoteEnvironmentAdmission.worktreeTarget(target, environmentID: target.environmentID, snapshot: revision.snapshot)
        guard !stoppingEffects, let incarnation = threadIncarnations[thread.id] else { throw RemoteEnvironmentAdmission.stale() }
        if let setup = thread.workspacePreparation?.setup, scriptRuntimes[setup.id] != nil || scriptClosures[setup.id] != nil { throw RemoteEnvironmentAdmission.stale() }
        let previous = thread.workspacePreparation
        if let attempt {
            guard let state = previous, state.id == attempt, state.canRetry,
                  state.request.destinationRoot.utf8.elementsEqual(worktreesRoot.path.utf8), state.setup == nil else { throw RemoteEnvironmentAdmission.stale() }
            if let plan = state.plan {
                let session = try worktreeFactory(state.request), token = UUID()
                let task = Task { try await session.inspectCompletion(plan) }
                worktreeInspections[token] = .init(threadID: thread.id, projectID: thread.projectID, task: task)
                defer { worktreeInspections.removeValue(forKey: token) }
                let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
                if await waitForRemovalCommit(threadID: thread.id, projectID: thread.projectID) { throw CancellationError() }
                guard !task.isCancelled, ownsWorktree(threadID: thread.id, attemptID: state.id, incarnation: incarnation) else { throw RemoteEnvironmentAdmission.stale() }
                try Task.checkCancellation()
                if let result {
                    try ThreadWorkspacePreparation.validate(result: result, plan: plan)
                    return .worktree(.init(threadID: thread.id, incarnation: incarnation, expectedWorkspacePath: thread.workspacePath,
                        expectedAttemptID: state.id, request: nil, result: result, claudeRuntimeConfiguration: nil))
                }
            }
            if case .inspectWorktree = command {
                return .worktree(.init(threadID: thread.id, incarnation: incarnation, expectedWorkspacePath: thread.workspacePath,
                    expectedAttemptID: state.id, request: nil, result: nil, claudeRuntimeConfiguration: nil))
            }
        }
        let selection: GitWorktreeSelection, submodules: ProjectWorktreeSubmoduleMode, source: String
        if case .prepareWorktree(_, _, let expectedAttempt, let selected, let mode) = command {
            guard previous?.id == expectedAttempt else { throw RemoteEnvironmentAdmission.stale() }
            selection = selected; submodules = mode
            source = previous.flatMap { $0.canRetry ? $0.request.sourcePath : nil } ?? thread.workspacePath
        } else {
            guard let state = previous, state.id == attempt else { throw RemoteEnvironmentAdmission.stale() }
            selection = state.request.selection; submodules = state.request.submodules; source = state.request.sourcePath
        }
        let request = GitWorktreeRequest(sourcePath: source, destinationRoot: worktreesRoot.path, selection: selection, submodules: submodules,
            expectedSourceIdentity: command.inspectsWorktreeCompletion ? previous?.request.expectedSourceIdentity : expectedSourceIdentity)
        try request.validate()
        let claude = try thread.claudeRuntimeConfiguration?.replacingWorkspace(request.destinationPath,
            physicalPath: ClaudeRuntimeValidation.physical(request.destinationPath, allowMissing: true))
        return .worktree(.init(threadID: thread.id, incarnation: incarnation, expectedWorkspacePath: thread.workspacePath,
            expectedAttemptID: previous?.id, request: request, result: nil, claudeRuntimeConfiguration: claude))
    }
    func dispatchRemoteEnvironment(_ request: RemoteEnvironmentCommandRequest,
                                   preparation: RemoteEnvironmentPreparation) async throws -> WorkspaceCommandReceipt {
        _ = try await load()
        guard AppMCPTaskContext.authority == nil else { throw AppMCPError(.permissionDenied) }
        guard !stoppingEffects else { throw CancellationError() }
        let fenced: RunCheckpointRestoreReview?
        if case .checkpoint(let captured) = preparation, case .restore(let review, _) = captured.action,
           let native = checkpointRestoreReviews[review.id],
           try RemoteCheckpointProtocol.payload(native.review) == RemoteCheckpointProtocol.payload(review) {
            fenced = review
            acceptingCheckpointRestores.insert(review.id)
            remoteCheckpointAcceptances[review.id, default: 0] += 1
            remoteCheckpointOperations += 1
        } else { fenced = nil }
        let historyFence: ConversationHistoryReview?
        if case .history(let captured) = preparation, case .begin(let review, _, _, _) = captured.action,
           let native = historyReviews[review.id],
           try RemoteHistoryProtocol.payload(native.review) == RemoteHistoryProtocol.payload(review), !remoteHistoriesClosing {
            historyFence = review; acceptingHistoryReviews.insert(review.id)
            remoteHistoryAcceptances[review.id, default: 0] += 1; remoteHistoryOperations += 1
        } else { historyFence = nil }
        let contextFence: ContextTransferReview?
        if case .contextTransfer(let captured) = preparation, case .review(let review, _, _) = captured.action,
           let cached = contextTransferReviews[review.id], ContextTransferProtocol.same(cached, review), !contextTransfersClosing {
            contextFence = review; acceptingContextTransfers[review.id, default: 0] += 1; contextTransferOperations += 1
        } else { contextFence = nil }
        do {
            let receipt = try await enqueue(.remoteEnvironment(request, preparation: preparation), id: request.id)
            if let fenced { await finishRemoteCheckpointAcceptance(fenced) }
            if let historyFence { await finishRemoteHistoryAcceptance(historyFence) }
            if let contextFence { await finishContextTransferAcceptance(contextFence) }
            return receipt
        } catch {
            if let fenced { await finishRemoteCheckpointAcceptance(fenced) }
            if let historyFence { await finishRemoteHistoryAcceptance(historyFence) }
            if let contextFence { await finishContextTransferAcceptance(contextFence) }
            throw error
        }
    }
    func awaitRemotePullRequestCancellation(_ preparation: RemoteEnvironmentPreparation) async {
        if case .pullRequest(let captured) = preparation, case .cancelCheckout(let operation) = captured.action,
           let task = effects[operation.effectID] {
            // Both command queues are free before joining; the effect can
            // commit terminal evidence while unrelated Stop remains available.
            await task.value
        }
    }
    func awaitRemotePullRequestCancellation(_ request: RemoteEnvironmentCommandRequest) async {
        guard case .pullRequest(let target, .cancelCheckout(let operationID)) = request.command,
              let operation = revision.snapshot.pullRequestCheckout(operationID), operation.projectID == target.projectID,
              operation.review.registeredWorkspacePath.utf8.elementsEqual(target.workspacePath.utf8),
              let task = effects[operation.effectID] else { return }
        // Call only after the original payload has matched its durable receipt.
        // This path never recaptures a review, dispatches, or launches a job.
        await task.value
    }
    func remoteEnvironmentReceipt(_ request: RemoteEnvironmentCommandRequest) async throws -> WorkspaceCommandReceipt? {
        _ = try await load()
        return try await database.receipt(request.id, matching: RemoteEnvironmentProtocol.payload(request))
    }
}

extension WorkspaceEngine {
    private func remotePullRequestThread(_ target: RemoteWorkspaceTarget, requireBound: Bool = true) throws -> CodingThread {
        guard !closing, !stoppingEffects, fatalError == nil, !requireBound || target.rootID != nil,
              let thread = revision.snapshot.threads.first(where: { $0.id == target.threadID && $0.projectID == target.projectID }),
              !thread.isArchived, thread.workspacePath.utf8.elementsEqual(target.workspacePath.utf8),
              try RemotePullRequestProtocol.payload(ProviderConfiguration(thread: thread)) == RemotePullRequestProtocol.payload(target.configuration),
              revision.snapshot.ownsPullRequestWorkspace(projectID: target.projectID, workspacePath: target.workspacePath) else {
            throw RemotePullRequestFailure(.invalidTarget)
        }
        return thread
    }
    func readRemotePullRequest(_ request: RemotePullRequestReadRequest) async throws -> RemotePullRequestValue {
        _ = try await load(); _ = try remotePullRequestThread(request.target)
        guard let incarnation = projectIncarnations[request.target.projectID] else { throw RemotePullRequestFailure(.invalidTarget) }
        switch request.query {
        case .context: break
        case .list(let query): try query.validate()
        case .detail(let reference): try reference.validate()
        case .resolve(let reference):
            guard !reference.isEmpty, reference.utf8.count <= 8_192, !reference.contains("\0") else { throw RemotePullRequestFailure(.invalidRequest) }
        }
        let session = try pullRequestFactory(URL(fileURLWithPath: request.target.workspacePath))
        let result: RemotePullRequestValue = try await readPullRequest(projectID: request.target.projectID, incarnation: incarnation) {
            let context = try await session.context()
            try context.validate()
            guard context.workspacePath.utf8.elementsEqual(request.target.workspacePath.utf8) else { throw RemotePullRequestFailure(.invalidTarget) }
            switch request.query {
            case .context: return .context(context)
            case .list(let query):
                let page = try await session.list(query: query)
                guard page.items.count <= query.limit, Set(page.items.map(\.reference)).count == page.items.count,
                      page.items.allSatisfy({ $0.reference.repository == context.repository }) else { throw RemotePullRequestFailure(.invalidRequest) }
                for item in page.items { try item.validate() }
                return .page(page)
            case .detail(let reference):
                guard reference.repository == context.repository else { throw RemotePullRequestFailure(.invalidRequest) }
                let detail = try await session.detail(reference); try detail.validate()
                guard detail.summary.reference == reference else { throw RemotePullRequestFailure(.invalidRequest) }
                return .detail(detail)
            case .resolve(let reference):
                let normalized = reference.trimmingCharacters(in: .whitespacesAndNewlines)
                if normalized.hasPrefix("https://") {
                    guard let url = URLComponents(string: normalized), let host = url.host, url.user == nil, url.password == nil,
                          url.query == nil, url.fragment == nil, url.port == nil else { throw RemotePullRequestFailure(.invalidRequest) }
                    let parts = url.path.split(separator: "/")
                    guard parts.count == 4, parts[2] == "pull", let number = Int(parts[3]), number > 0,
                          try GitHubRepository(host: host, owner: String(parts[0]), name: String(parts[1])) == context.repository else { throw RemotePullRequestFailure(.invalidRequest) }
                }
                let detail = try await session.resolve(normalized); try detail.validate()
                guard detail.summary.reference.repository == context.repository else { throw RemotePullRequestFailure(.invalidRequest) }
                return .detail(detail)
            }
        }
        _ = try remotePullRequestThread(request.target)
        return result
    }
    func reviewRemotePullRequest(_ request: RemotePullRequestReviewRequest, busyWorktreePaths: [String]) async throws -> RemotePullRequestReview {
        _ = try await load(); let thread = try remotePullRequestThread(request.target)
        guard remotePullRequestReviews.count < 64 else { throw RemotePullRequestFailure(.limitExceeded) }
        let value: RemotePullRequestReviewValue
        switch request.intent {
        case .create(let title, let body, let base, let draft):
            value = .creation(try await reviewPullRequestCreation(projectID: thread.projectID, workspacePath: thread.workspacePath,
                title: title, body: body, baseBranch: base, isDraft: draft, sourceThreadID: thread.id))
        case .checkout(let reference, let mode, let submodules, let title):
            guard case .context(let context) = try await readRemotePullRequest(.init(target: request.target, query: .context)),
                  context.repository == reference.repository else { throw RemotePullRequestFailure(.invalidRequest) }
            value = .checkout(try await reviewPullRequestCheckout(projectID: thread.projectID, workspacePath: thread.workspacePath,
                reference: reference, mode: mode, configuration: request.target.configuration, checkpointPolicy: thread.checkpointPolicy,
                title: title, submodules: submodules, reviewSetup: false, busyWorktreePaths: busyWorktreePaths))
        }
        do {
            _ = try remotePullRequestThread(request.target)
            guard remotePullRequestReviews.count < 64, remotePullRequestReviews[value.id] == nil else { throw RemotePullRequestFailure(.limitExceeded) }
            let result = try RemotePullRequestReview(target: request.target, value: value)
            remotePullRequestReviews[result.id] = result
            return result
        } catch {
            switch value {
            case .creation(let review): discardPullRequestCreationReview(reviewID: review.id)
            case .checkout(let review): discardPullRequestCheckoutReview(reviewID: review.id)
            }
            throw error
        }
    }
    func discardRemotePullRequestReview(_ request: RemotePullRequestDiscardRequest) -> Bool {
        guard let saved = remotePullRequestReviews[request.reviewID], saved.digest == request.digest,
              (try? RemotePullRequestProtocol.payload(saved.target)) == (try? RemotePullRequestProtocol.payload(request.target)) else { return false }
        remotePullRequestReviews.removeValue(forKey: request.reviewID)
        switch saved.value {
        case .creation: discardPullRequestCreationReview(reviewID: saved.id)
        case .checkout: discardPullRequestCheckoutReview(reviewID: saved.id)
        }
        return true
    }
    func discardAllRemotePullRequestReviews() {
        for review in remotePullRequestReviews.values {
            switch review.value {
            case .creation: discardPullRequestCreationReview(reviewID: review.id)
            case .checkout: discardPullRequestCheckoutReview(reviewID: review.id)
            }
        }
        remotePullRequestReviews.removeAll()
    }
    func closeRemotePullRequests() async {
        let reads = Array(pullRequestReads.values)
        for read in reads { read.cancel() }
        for read in reads { await read.drain.value }
        discardAllRemotePullRequestReviews()
    }
    func prepareRemotePullRequest(_ command: RemoteEnvironmentCommand) async throws -> RemoteEnvironmentPreparation {
        _ = try await load()
        guard case .pullRequest(let target, let action) = command else { throw RemotePullRequestFailure(.invalidRequest) }
        _ = try remotePullRequestThread(target, requireBound: action.requiresBoundRoot)
        guard let incarnation = projectIncarnations[target.projectID] else { throw RemotePullRequestFailure(.invalidTarget) }
        let prepared: RemotePullRequestPreparation.Action
        switch action {
        case .begin(let id, let digest):
            guard let saved = remotePullRequestReviews[id], saved.digest == digest,
                  try RemotePullRequestProtocol.payload(saved.target) == RemotePullRequestProtocol.payload(target) else { throw RemotePullRequestFailure(.staleReview) }
            switch saved.value {
            case .creation(let review):
                guard let cached = pullRequestCreationReviews[id], try RemotePullRequestProtocol.payload(cached.operation.review) == RemotePullRequestProtocol.payload(review) else { throw RemotePullRequestFailure(.staleReview) }
                prepared = .creation(cached.operation, digest: digest)
            case .checkout(let review):
                guard let cached = pullRequestCheckoutReviews[id], try RemotePullRequestProtocol.payload(cached.operation.review) == RemotePullRequestProtocol.payload(review) else { throw RemotePullRequestFailure(.staleReview) }
                prepared = .checkout(cached.operation, digest: digest)
            }
        case .inspectCreation(let id), .acknowledgeCreation(let id):
            guard let operation = revision.snapshot.pullRequestCreation(id), operation.projectID == target.projectID,
                  operation.registeredWorkspacePath.utf8.elementsEqual(target.workspacePath.utf8), operation.phase == .unconfirmed,
                  operation.acknowledgedAt == nil else { throw RemotePullRequestFailure(.invalidTarget) }
            if case .inspectCreation = action {
                try revision.snapshot.validatePullRequestCreationSource(operation)
                let session = try pullRequestFactory(URL(fileURLWithPath: operation.workspacePath))
                let result = try await readPullRequest(projectID: operation.projectID, incarnation: incarnation) { try await session.reconcileCreate(operation.review) }
                prepared = .inspectCreation(operation, result)
            } else { prepared = .acknowledgeCreation(operation) }
        case .inspectCheckout(let id), .acknowledgeCheckout(let id), .cancelCheckout(let id):
            guard let operation = revision.snapshot.pullRequestCheckout(id), operation.projectID == target.projectID,
                  operation.review.registeredWorkspacePath.utf8.elementsEqual(target.workspacePath.utf8) else { throw RemotePullRequestFailure(.invalidTarget) }
            if case .cancelCheckout = action {
                guard operation.isWorking else { throw RemotePullRequestFailure(.invalidTarget) }
                prepared = .cancelCheckout(operation)
            } else {
                guard operation.phase == .unconfirmed, operation.acknowledgedAt == nil else { throw RemotePullRequestFailure(.invalidTarget) }
                if case .inspectCheckout = action {
                    try revision.snapshot.validatePullRequestCheckoutSource(operation)
                    let session = try pullRequestCheckoutFactory(operation.review.plan.request)
                    let result = try await readPullRequest(projectID: operation.projectID, incarnation: incarnation) { try await session.inspectCompletion(operation.review.plan) }
                    prepared = .inspectCheckout(operation, result)
                } else { prepared = .acknowledgeCheckout(operation) }
            }
        }
        _ = try remotePullRequestThread(target, requireBound: action.requiresBoundRoot)
        let result = RemotePullRequestPreparation(target: target, incarnation: incarnation, action: prepared)
        try validateRemotePullRequestPreparation(result)
        return .pullRequest(result)
    }
    private func validateRemotePullRequestPreparation(_ prepared: RemotePullRequestPreparation) throws {
        guard projectIncarnations[prepared.target.projectID] == prepared.incarnation else { throw RemoteEnvironmentAdmission.stale() }
        switch prepared.action {
        case .creation(let operation, let digest):
            guard operation.sourceIncarnation == prepared.incarnation, let review = remotePullRequestReviews[operation.id], review.digest == digest,
                  try RemotePullRequestProtocol.payload(review.target) == RemotePullRequestProtocol.payload(prepared.target),
                  try RemotePullRequestProtocol.payload(review.value) == RemotePullRequestProtocol.payload(RemotePullRequestReviewValue.creation(operation.review)),
                  pullRequestCreationReviews[operation.id]?.operation.effectID == operation.effectID,
                  pullRequestRuntimeScopeAvailable(operation) else { throw RemoteEnvironmentAdmission.stale() }
        case .checkout(let operation, let digest):
            guard operation.review.sourceIncarnation == prepared.incarnation, let review = remotePullRequestReviews[operation.id], review.digest == digest,
                  try RemotePullRequestProtocol.payload(review.target) == RemotePullRequestProtocol.payload(prepared.target),
                  try RemotePullRequestProtocol.payload(review.value) == RemotePullRequestProtocol.payload(RemotePullRequestReviewValue.checkout(operation.review)),
                  pullRequestCheckoutReviews[operation.id]?.operation.effectID == operation.effectID,
                  pullRequestCheckoutRuntimeScopeAvailable(operation) else { throw RemoteEnvironmentAdmission.stale() }
        default: break
        }
    }
}

extension WorkspaceEngine {
    func captureRemoteProjection() async throws -> WorkspaceUpdate {
        _ = try await load(); try Task.checkCancellation()
        guard !closing, !stoppingEffects, fatalError == nil else { throw RemoteProjectionFailure(.unavailable) }
        return .init(snapshot: revision.snapshot, sequence: revision.sequence)
    }
    private func beginRemoteCheckpointOperation() throws {
        guard !remoteCheckpointsClosing else { throw RemoteCheckpointFailure(.unavailable) }
        remoteCheckpointOperations += 1
    }
    private func finishRemoteCheckpointOperation() {
        remoteCheckpointOperations -= 1
        if remoteCheckpointOperations == 0 {
            let waiters = remoteCheckpointWaiters; remoteCheckpointWaiters = []
            for waiter in waiters { waiter.resume() }
        }
    }
    private func remoteCheckpointThread(_ target: RemoteWorkspaceTarget, requireBound: Bool = true) throws -> CodingThread {
        guard !closing, !stoppingEffects, !remoteCheckpointsClosing, fatalError == nil, !requireBound || target.rootID != nil,
              let thread = revision.snapshot.threads.first(where: { $0.id == target.threadID && $0.projectID == target.projectID }),
              !thread.isArchived, revision.snapshot.projects.contains(where: { $0.id == target.projectID }),
              thread.workspacePath.utf8.elementsEqual(target.workspacePath.utf8),
              try RemoteCheckpointProtocol.payload(ProviderConfiguration(thread: thread)) == RemoteCheckpointProtocol.payload(target.configuration) else {
            throw RemoteCheckpointFailure(.invalidTarget)
        }
        return thread
    }
    func readRemoteCheckpoint(_ request: RemoteCheckpointReadRequest) async throws -> RemoteCheckpointValue {
        try beginRemoteCheckpointOperation(); defer { finishRemoteCheckpointOperation() }
        _ = try await load(); let thread = try remoteCheckpointThread(request.target)
        switch request.query {
        case .inventory:
            let runs = (thread.runHistory ?? []).compactMap { record -> RemoteCheckpointRun? in
                guard let checkpoints = record.checkpoints else { return nil }
                var reasons: [UUID: String] = [:]
                let choices = [(RunCheckpointStage.baseline, checkpoints.baseline)] +
                    checkpoints.previousPostRunAttempts.map { (.postRun, $0) } + (checkpoints.postRun.map { [(.postRun, $0)] } ?? [])
                for (stage, attempt) in choices {
                    if let reason = revision.snapshot.checkpointRestoreUnavailableReason(threadID: thread.id, runID: record.id,
                        stage: stage, expectedAttemptID: attempt.id) { reasons[attempt.id] = reason }
                }
                return .init(id: record.id, baseline: checkpoints.baseline, postRun: checkpoints.postRun,
                    previousPostRunAttempts: checkpoints.previousPostRunAttempts, restoreUnavailableReasons: reasons)
            }
            let value = RemoteCheckpointValue.inventory(.init(policy: thread.effectiveCheckpointPolicy, runs: runs))
            guard try RemoteCheckpointProtocol.payload(value).count <= RemoteEnvironmentProtocol.maximumFrameBytes - 65_536 else { throw RemoteCheckpointFailure(.limitExceeded) }
            return value
        case .runDiff(let runID, let baselineID, let postID, let maxBytes):
            guard (1...1_048_576).contains(maxBytes), let checkpoints = thread.runHistory?.first(where: { $0.id == runID })?.checkpoints,
                  checkpoints.baseline.id == baselineID, checkpoints.postRun?.id == postID,
                  let baseline = checkpoints.baseline.receipt, let post = checkpoints.postRun?.receipt else { throw RemoteCheckpointFailure(.invalidRequest) }
            let value = try await runCheckpointDiff(threadID: thread.id, runID: runID, maxBytes: maxBytes)
            let current = try remoteCheckpointThread(request.target)
            guard let observed = current.runHistory?.first(where: { $0.id == runID })?.checkpoints,
                  observed.baseline.id == baselineID, observed.postRun?.id == postID,
                  try RemoteCheckpointProtocol.payload(observed.baseline.receipt) == RemoteCheckpointProtocol.payload(baseline),
                  try RemoteCheckpointProtocol.payload(observed.postRun?.receipt) == RemoteCheckpointProtocol.payload(post),
                  value.patch.utf8.count <= maxBytes else { throw RemoteCheckpointFailure(.invalidTarget) }
            return .diff(.init(runID: runID, baselineAttemptID: baselineID, postRunAttemptID: postID, patch: value.patch, truncated: value.truncated))
        }
    }
    func reviewRemoteCheckpoint(_ request: RemoteCheckpointReviewRequest) async throws -> RemoteCheckpointReview {
        try beginRemoteCheckpointOperation(); defer { finishRemoteCheckpointOperation() }
        _ = try await load(); _ = try remoteCheckpointThread(request.target)
        guard remoteCheckpointReviews.count < 32 else { throw RemoteCheckpointFailure(.limitExceeded) }
        let native = try await reviewCheckpointRestore(threadID: request.target.threadID, runID: request.runID,
            stage: request.stage, expectedAttemptID: request.attemptID)
        do {
            _ = try remoteCheckpointThread(request.target)
            guard remoteCheckpointReviews.count < 32, remoteCheckpointReviews[native.id] == nil else { throw RemoteCheckpointFailure(.limitExceeded) }
            let review = try RemoteCheckpointReview(target: request.target, value: native)
            guard try RemoteCheckpointProtocol.payload(review).count <= RemoteEnvironmentProtocol.maximumFrameBytes - 65_536 else { throw RemoteCheckpointFailure(.limitExceeded) }
            remoteCheckpointReviews[review.id] = review
            return review
        } catch { await discardCheckpointRestoreReview(reviewID: native.id); throw error }
    }
    func discardRemoteCheckpointReview(_ request: RemoteCheckpointDiscardRequest) async -> Bool {
        remoteCheckpointOperations += 1; defer { finishRemoteCheckpointOperation() }
        guard !acceptingCheckpointRestores.contains(request.reviewID),
              let saved = remoteCheckpointReviews[request.reviewID], saved.digest == request.digest,
              (try? RemoteCheckpointProtocol.payload(saved.target)) == (try? RemoteCheckpointProtocol.payload(request.target)) else { return false }
        remoteCheckpointReviews.removeValue(forKey: request.reviewID)
        await discardCheckpointRestoreReview(reviewID: request.reviewID)
        return true
    }
    private func finishRemoteCheckpointAcceptance(_ review: RunCheckpointRestoreReview) async {
        defer { finishRemoteCheckpointOperation() }
        let count = (remoteCheckpointAcceptances[review.id] ?? 1) - 1
        if count > 0 { remoteCheckpointAcceptances[review.id] = count; return }
        remoteCheckpointAcceptances.removeValue(forKey: review.id)
        acceptingCheckpointRestores.remove(review.id)
        if revision.snapshot.checkpointRestoreOperation(review.id) == nil {
            remoteCheckpointReviews.removeValue(forKey: review.id)
            await discardCheckpointRestoreReview(reviewID: review.id)
        }
    }
    func prepareRemoteCheckpoint(_ command: RemoteEnvironmentCommand) async throws -> RemoteEnvironmentPreparation {
        try beginRemoteCheckpointOperation(); defer { finishRemoteCheckpointOperation() }
        _ = try await load()
        guard case .checkpoint(let target, let action) = command else { throw RemoteCheckpointFailure(.invalidRequest) }
        let thread = try remoteCheckpointThread(target, requireBound: action.requiresBoundRoot)
        guard let incarnation = threadIncarnations[thread.id] else { throw RemoteCheckpointFailure(.invalidTarget) }
        let prepared: RemoteCheckpointPreparation.Action
        switch action {
        case .beginRestore(let id, let digest):
            guard let saved = remoteCheckpointReviews[id], saved.digest == digest,
                  try RemoteCheckpointProtocol.payload(saved.target) == RemoteCheckpointProtocol.payload(target) else { throw RemoteCheckpointFailure(.staleReview) }
            prepared = .restore(saved.value, digest: digest)
        case .inspectRestore(let id), .acknowledgeRestore(let id):
            guard let operation = revision.snapshot.checkpointRestoreOperation(id), operation.review.threadID == thread.id,
                  operation.review.projectID == thread.projectID, operation.review.workspacePath.utf8.elementsEqual(thread.workspacePath.utf8),
                  operation.phase == .unconfirmed, operation.acknowledgedAt == nil else { throw RemoteCheckpointFailure(.invalidTarget) }
            if case .acknowledgeRestore = action { prepared = .acknowledge(operation) }
            else {
                guard revision.snapshot.canReviewCheckpointRestore(threadID: thread.id, excludingOperationID: id),
                      try revision.snapshot.checkpointRestoreSourceFingerprint(threadID: thread.id) == operation.review.sourceFingerprint,
                      restoreRuntimeScopeIsolated(thread: thread, path: operation.review.gitReview.currentPlan.repositoryPath) else { throw RemoteCheckpointFailure(.invalidTarget) }
                let result = try await readCheckpointRestore(thread: thread) { try await $0.inspectRestore(review: operation.review.gitReview) }
                prepared = .inspect(operation, result)
            }
        case .retryPostRun(let runID, let attemptID), .continuePostRun(let runID, let attemptID):
            guard let held = thread.heldPostRunCheckpoint, held.runID == runID, held.attempt.id == attemptID,
                  !held.attempt.phase.isRunning else { throw RemoteCheckpointFailure(.invalidTarget) }
            if case .retryPostRun = action { prepared = .retry(runID: runID, attempt: held.attempt) }
            else { prepared = .proceed(runID: runID, attempt: held.attempt) }
        }
        let current = try remoteCheckpointThread(target, requireBound: action.requiresBoundRoot)
        let result = RemoteCheckpointPreparation(target: target, incarnation: incarnation, policy: thread.effectiveCheckpointPolicy, action: prepared)
        guard current.effectiveCheckpointPolicy == result.policy else { throw RemoteCheckpointFailure(.invalidTarget) }
        try validateRemoteCheckpointPreparation(result, snapshot: revision.snapshot)
        return .checkpoint(result)
    }
    func validateRemoteCheckpointPreparation(_ prepared: RemoteCheckpointPreparation, snapshot: WorkspaceSnapshot) throws {
        guard !remoteCheckpointsClosing, threadIncarnations[prepared.target.threadID] == prepared.incarnation else { throw RemoteEnvironmentAdmission.stale() }
        switch prepared.action {
        case .restore(let review, let digest):
            guard let cached = remoteCheckpointReviews[review.id], cached.digest == digest,
                  try RemoteCheckpointProtocol.payload(cached.target) == RemoteCheckpointProtocol.payload(prepared.target),
                  try RemoteCheckpointProtocol.payload(cached.value) == RemoteCheckpointProtocol.payload(review),
                  checkpointRestoreReviews[review.id]?.digest == (try checkpointRestoreDigest(review)),
                  review.sourceIncarnation == prepared.incarnation,
                  try snapshot.checkpointRestoreSourceFingerprint(threadID: review.threadID) == review.sourceFingerprint,
                  let thread = snapshot.threads.first(where: { $0.id == review.threadID }),
                  restoreRuntimeScopeIsolated(thread: thread, path: review.gitReview.currentPlan.repositoryPath) else { throw RemoteEnvironmentAdmission.stale() }
        case .inspect(let operation, _):
            guard let thread = snapshot.threads.first(where: { $0.id == operation.review.threadID }),
                  try snapshot.checkpointRestoreSourceFingerprint(threadID: thread.id) == operation.review.sourceFingerprint,
                  restoreRuntimeScopeIsolated(thread: thread, path: operation.review.gitReview.currentPlan.repositoryPath) else { throw RemoteEnvironmentAdmission.stale() }
        default: break
        }
    }
    private func remoteCheckpointCommitted(_ preparation: RemoteCheckpointPreparation) {
        guard case .restore(let review, _) = preparation.action, revision.snapshot.checkpointRestoreOperation(review.id) != nil else { return }
        remoteCheckpointReviews.removeValue(forKey: review.id)
        checkpointRestoreReviews.removeValue(forKey: review.id)
    }
    func closeRemoteCheckpoints() async {
        if let task = remoteCheckpointCloseTask { await task.value; return }
        remoteCheckpointsClosing = true
        let task = Task { await self.finishRemoteCheckpointClose() }
        remoteCheckpointCloseTask = task; await task.value
    }
    private func finishRemoteCheckpointClose() async {
        let reads = Array(checkpointReads.values)
        for read in reads { read.cancel() }
        for read in reads { await read.task.value }
        if remoteCheckpointOperations > 0 { await withCheckedContinuation { remoteCheckpointWaiters.append($0) } }
        let reviews = Array(remoteCheckpointReviews.values)
        remoteCheckpointReviews.removeAll()
        for review in reviews { await discardCheckpointRestoreReview(reviewID: review.id) }
    }
}

extension WorkspaceEngine {
    private func beginRemoteHistoryOperation() throws {
        guard !closing, !stoppingEffects, !remoteHistoriesClosing, fatalError == nil else { throw RemoteHistoryFailure(.unavailable) }
        remoteHistoryOperations += 1
    }
    private func finishRemoteHistoryOperation() {
        remoteHistoryOperations -= 1
        if remoteHistoryOperations == 0 {
            let waiting = remoteHistoryWaiters; remoteHistoryWaiters = []
            for waiter in waiting { waiter.resume() }
        }
    }
    // Internal observation for deterministic SQLite contention tests. This
    // exposes no native proof and does not participate in admission decisions.
    func remoteHistoryAdmissionState(reviewID: UUID) -> (acceptances: Int, committing: Bool) {
        (remoteHistoryAcceptances[reviewID] ?? 0, completedDuringCommit != nil)
    }
    private func remoteHistoryThread(_ target: RemoteWorkspaceTarget, requireBound: Bool = false) throws -> CodingThread {
        guard !closing, !stoppingEffects, !remoteHistoriesClosing, fatalError == nil, !requireBound || target.rootID != nil,
              let thread = revision.snapshot.threads.first(where: { $0.id == target.threadID && $0.projectID == target.projectID }),
              !thread.isArchived, thread.workspacePath.utf8.elementsEqual(target.workspacePath.utf8),
              try RemoteHistoryProtocol.payload(ProviderConfiguration(thread: thread)) == RemoteHistoryProtocol.payload(target.configuration) else { throw RemoteHistoryFailure(.invalidTarget) }
        return thread
    }
    func captureRemoteHistory(_ target: RemoteWorkspaceTarget) async throws -> WorkspaceUpdate {
        try beginRemoteHistoryOperation(); defer { finishRemoteHistoryOperation() }
        _ = try await load(); _ = try remoteHistoryThread(target)
        return .init(snapshot: revision.snapshot, sequence: revision.sequence)
    }
    func remoteHistoryFileRestoreAvailability(_ review: ConversationHistoryReview) throws -> RemoteProjectionAvailability {
        guard review.kind == .rewindBeforeRun else { return .init(allowed: false, reason: "Only a rewind can restore workspace files.") }
        guard let thread = revision.snapshot.threads.first(where: { $0.id == review.sourceThreadID }),
              ownsHistorySource(threadID: thread.id, incarnation: review.sourceIncarnation, fingerprint: review.sourceFingerprint),
              revision.snapshot.canReviewCheckpointRestore(threadID: thread.id) else { return .init(allowed: false, reason: "Finish other work using this workspace before reviewing file restoration.") }
        switch try revision.snapshot.conversationHistoryFileTarget(for: review) {
        case .unavailable(let reason): return .init(allowed: false, reason: reason.message)
        case .available(let target):
            return .init(allowed: restoreRuntimeScopeIsolated(thread: thread, path: target.receipt.plan.repositoryPath),
                reason: restoreRuntimeScopeIsolated(thread: thread, path: target.receipt.plan.repositoryPath) ? nil : "Another runtime owns the saved checkpoint's workspace.")
        }
    }
    private func remoteHistoryProofBytes() throws -> Int {
        try remoteHistoryReviews.values.reduce(0) { try $0 + RemoteHistoryProtocol.payload($1).count }
    }
    func reviewRemoteHistory(_ request: RemoteHistoryReviewRequest) async throws -> RemoteHistoryPreparedReview {
        try beginRemoteHistoryOperation(); defer { finishRemoteHistoryOperation() }
        _ = try await load(); _ = try remoteHistoryThread(request.target, requireBound: true)
        guard request.kind == .rewindBeforeRun || (request.files == .keep && !request.recallPromptOnSuccess),
              remoteHistoryReviews.count < RemoteHistoryProtocol.maximumLeases else { throw RemoteHistoryFailure(.invalidRequest) }
        var native = try await reviewConversationHistory(threadID: request.target.threadID, runID: request.runID, kind: request.kind,
            recallPromptOnSuccess: request.recallPromptOnSuccess)
        do {
            if request.files == .restore {
                let keep = native
                native = try await reviewConversationHistoryRestoringFiles(keep)
                await discardConversationHistoryReview(reviewID: keep.id)
            }
            _ = try remoteHistoryThread(request.target, requireBound: true); try Task.checkCancellation()
            struct Bound: Encodable { let target: RemoteWorkspaceTarget; let value: ConversationHistoryReview }
            let prepared = RemoteHistoryPreparedReview(target: request.target, native: native,
                digest: try RemoteHistoryProtocol.digest(Bound(target: request.target, value: native)))
            guard remoteHistoryReviews.count < RemoteHistoryProtocol.maximumLeases,
                  try RemoteHistoryProtocol.payload(prepared).count <= RemoteHistoryProtocol.maximumCacheBytes - remoteHistoryProofBytes() else { throw RemoteHistoryFailure(.limitExceeded) }
            remoteHistoryReviews[native.id] = prepared
            return prepared
        } catch { await discardConversationHistoryReview(reviewID: native.id); throw error }
    }
    func discardRemoteHistoryReview(_ request: RemoteHistoryDiscardRequest) async -> Bool {
        remoteHistoryOperations += 1; defer { finishRemoteHistoryOperation() }
        guard !acceptingHistoryReviews.contains(request.reviewID),
              let cached = remoteHistoryReviews[request.reviewID], cached.digest == request.digest,
              (try? RemoteHistoryProtocol.payload(cached.target)) == (try? RemoteHistoryProtocol.payload(request.target)) else { return false }
        remoteHistoryReviews.removeValue(forKey: request.reviewID)
        await discardConversationHistoryReview(reviewID: request.reviewID)
        return true
    }
    private func finishRemoteHistoryAcceptance(_ review: ConversationHistoryReview) async {
        defer { finishRemoteHistoryOperation() }
        let remaining = (remoteHistoryAcceptances[review.id] ?? 1) - 1
        if remaining > 0 { remoteHistoryAcceptances[review.id] = remaining; return }
        remoteHistoryAcceptances.removeValue(forKey: review.id); acceptingHistoryReviews.remove(review.id)
        if revision.snapshot.conversationHistoryOperation(review.id) == nil {
            remoteHistoryReviews.removeValue(forKey: review.id)
            await discardConversationHistoryReview(reviewID: review.id)
        }
    }
    func prepareRemoteHistory(_ command: RemoteEnvironmentCommand, commandID: UUID? = nil, originalPayload: Data? = nil) async throws -> RemoteEnvironmentPreparation {
        try beginRemoteHistoryOperation(); defer { finishRemoteHistoryOperation() }
        _ = try await load()
        guard case .history(let target, let action) = command else { throw RemoteHistoryFailure(.invalidRequest) }
        let thread = try remoteHistoryThread(target, requireBound: action.requiresBoundRoot)
        guard let incarnation = threadIncarnations[thread.id] else { throw RemoteHistoryFailure(.invalidTarget) }
        func operation(_ id: UUID) throws -> ConversationHistoryOperation {
            guard let value = revision.snapshot.conversationHistoryOperation(id), value.review.sourceThreadID == thread.id,
                  value.review.projectID == thread.projectID else { throw RemoteHistoryFailure(.invalidTarget) }
            return value
        }
        let prepared: RemoteHistoryPreparation.Action
        switch action {
        case .begin(let id, let digest, let title):
            guard let value = remoteHistoryReviews[id], value.digest == digest,
                  try RemoteHistoryProtocol.payload(value.target) == RemoteHistoryProtocol.payload(target) else { throw RemoteHistoryFailure(.staleReview) }
            let grant: ScratchHistoryForkGrant?
            if let commandID {
                grant = try prepareScratchHistoryFork(value.native, commandID: commandID)
                if grant != nil {
                    guard let originalPayload else { throw RemoteHistoryFailure(.invalidRequest) }
                    try recordScratchHistoryFork(grant, commandID: commandID, originalPayload: originalPayload)
                }
            } else { grant = nil }
            prepared = .begin(value.native, digest: digest, title: title, scratchFork: grant)
        case .inspectProvider(let id):
            let value = try operation(id)
            guard value.phase == .unconfirmed, revision.snapshot.canInspectConversationHistory(operationID: id) else { throw RemoteHistoryFailure(.invalidTarget) }
            prepared = .reconcile(value, try await prepareRemoteHistoryReconciliation(value, thread: thread, incarnation: incarnation))
        case .inspectFiles(let id):
            let value = try operation(id)
            guard value.phase == .applied, let files = value.files, files.phase == .unconfirmed, files.acknowledgedAt == nil,
                  restoreRuntimeScopeIsolated(thread: thread, path: files.review.gitReview.currentPlan.repositoryPath) else { throw RemoteHistoryFailure(.invalidTarget) }
            try revision.snapshot.validateConversationHistoryFilesSource(value)
            let observed = try await readCheckpointRestore(thread: thread) { try await $0.inspectRestore(review: files.review.gitReview) }
            prepared = .files(value, observed)
        case .acknowledgeFiles(let id): prepared = .acknowledge(try operation(id))
        case .recallPrompt(let id):
            let value = try operation(id)
            guard let run = thread.runHistory?.first(where: { $0.id == value.review.runID }), run.origin == .user,
                  let message = thread.messages.first(where: { $0.id == run.userMessageID && $0.role == .user && $0.runReference == .init(threadID: thread.id, runID: run.id) }) else { throw RemoteHistoryFailure(.invalidTarget) }
            prepared = .recall(value, message)
        case .dismissRecall(let id): prepared = .dismiss(try operation(id))
        case .inspectClaudeResume(let selectionID, let consumer):
            guard revision.snapshot.claudeResumeSelectionNeedsInspection(threadID: thread.id),
                  let configuration = thread.claudeRuntimeConfiguration, let selection = thread.claudeResumeSelection,
                  selection.id == selectionID, thread.claudeResumeConsumerRunID == consumer,
                  let run = thread.runHistory?.first(where: { $0.id == consumer }) else { throw RemoteHistoryFailure(.invalidTarget) }
            try await drainClaudeHistoryOwners(thread: thread)
            let result = try await readClaudeHistory(thread: thread) { _ in try ClaudeResumeInspection.inspect(configuration: configuration, selection: selection, run: run) }
            prepared = .claudeResume(selection, run, result)
        }
        _ = try remoteHistoryThread(target, requireBound: action.requiresBoundRoot)
        let result = RemoteHistoryPreparation(target: target, incarnation: incarnation, action: prepared)
        try validateRemoteHistoryPreparation(result, snapshot: revision.snapshot)
        return .history(result)
    }
    func validateRemoteHistoryPreparation(_ captured: RemoteHistoryPreparation, snapshot: WorkspaceSnapshot) throws {
        guard !remoteHistoriesClosing, threadIncarnations[captured.target.threadID] == captured.incarnation,
              let thread = snapshot.threads.first(where: { $0.id == captured.target.threadID }) else { throw RemoteEnvironmentAdmission.stale() }
        switch captured.action {
        case .begin(let review, let digest, _, _):
            guard let cached = remoteHistoryReviews[review.id], cached.digest == digest,
                  try RemoteHistoryProtocol.payload(cached.target) == RemoteHistoryProtocol.payload(captured.target),
                  try RemoteHistoryProtocol.payload(cached.native) == RemoteHistoryProtocol.payload(review),
                  historyReviews[review.id]?.digest == (try historyReviewDigest(review)),
                  ownsHistorySource(threadID: thread.id, incarnation: captured.incarnation, fingerprint: review.sourceFingerprint) else { throw RemoteEnvironmentAdmission.stale() }
            if let files = review.files {
                try snapshot.validateConversationHistoryFilesReview(review)
                guard restoreRuntimeScopeIsolated(thread: thread, path: files.gitReview.currentPlan.repositoryPath) else { throw RemoteEnvironmentAdmission.stale() }
            }
        case .reconcile(let operation, _):
            guard ownsHistorySource(threadID: thread.id, incarnation: captured.incarnation, fingerprint: operation.review.sourceFingerprint) else { throw RemoteEnvironmentAdmission.stale() }
            if operation.review.claude != nil {
                guard claudeHistoryScopeIsolated(thread: thread, additionalNativeIDs: Set(operation.claudeForkPublication.map { [$0.target.sessionID] } ?? [])) else { throw RemoteEnvironmentAdmission.stale() }
            }
        case .files(let operation, _):
            try snapshot.validateConversationHistoryFilesSource(operation)
            guard let files = operation.files, restoreRuntimeScopeIsolated(thread: thread, path: files.review.gitReview.currentPlan.repositoryPath) else { throw RemoteEnvironmentAdmission.stale() }
        case .claudeResume:
            guard claudeHistoryScopeIsolated(thread: thread) else { throw RemoteEnvironmentAdmission.stale() }
        default: break
        }
    }
    private func remoteHistoryCommitted(_ preparation: RemoteHistoryPreparation, commandID: UUID) {
        switch preparation.action {
        case .begin(let review, _, _, _):
            remoteHistoryReviews.removeValue(forKey: review.id); historyReviews.removeValue(forKey: review.id)
        case .reconcile(let operation, let result):
            let applied: Bool; if case .applied = result { applied = true } else { applied = false }
            if !applied, let files = operation.review.files {
                remoteHistoryTasks[commandID] = Task {
                    await self.discardCheckpointRestoreScratch(files.gitReview, threadID: operation.review.sourceThreadID, projectID: operation.review.projectID)
                    self.remoteHistoryTasks.removeValue(forKey: commandID)
                }
            }
        default: break
        }
    }
    func closeRemoteHistory() async {
        if let task = remoteHistoryCloseTask { await task.value; return }
        remoteHistoriesClosing = true
        let task = Task { await self.finishRemoteHistoryClose() }
        remoteHistoryCloseTask = task; await task.value
    }
    private func finishRemoteHistoryClose() async {
        let reads = Array(historyReads.values)
        for read in reads { read.cancel() }
        for read in reads { await read.drain.value }
        let fileReads = Array(checkpointReads.values)
        for read in fileReads { read.cancel() }
        for read in fileReads { await read.task.value }
        if remoteHistoryOperations > 0 { await withCheckedContinuation { remoteHistoryWaiters.append($0) } }
        let reviews = Array(remoteHistoryReviews.values); remoteHistoryReviews.removeAll()
        for cached in reviews { await discardConversationHistoryReview(reviewID: cached.native.id) }
        let tasks = Array(remoteHistoryTasks.values); remoteHistoryTasks.removeAll()
        for task in tasks { await task.value }
    }
    private func prepareRemoteHistoryReconciliation(_ operation: ConversationHistoryOperation, thread: CodingThread,
                                                    incarnation: UUID) async throws -> ConversationHistoryReconciliation {
        let expected = operation.review
        let result: ConversationHistoryReconciliation
        if let evidence = expected.claude {
            let publication = operation.claudeForkPublication
            try await drainClaudeHistoryOwners(thread: thread)
            result = try await readClaudeHistory(thread: thread) { service in
                if evidence.kind == .rewindBeforeRun {
                    let selected = try service.prepareRewind(review: evidence, selectionID: operation.id)
                    return .applied(try .init(reference: selected.reference, workspacePath: selected.workspacePath, historyMode: .nativeTranscript, claude: selected))
                }
                guard let publication else { throw ProviderHistoryError(.outcomeUncertain) }
                switch try service.inspectFork(review: evidence, publication: publication) {
                case .ready(let value): return .applied(try .init(reference: value.reference, workspacePath: value.workspacePath, historyMode: .nativeTranscript, claude: value))
                case .notStarted: return .claudeForkNotStarted(try service.snapshot(sessionID: evidence.source.reference.nativeThreadID, selection: evidence.source.selection))
                case .incomplete: throw ProviderHistoryError(.outcomeUncertain)
                }
            }
            guard claudeHistoryScopeIsolated(thread: thread, additionalNativeIDs: Set(publication.map { [$0.target.sessionID] } ?? [])) else { throw ProviderHistoryError(.historyChanged) }
        } else {
            let observed = try await readHistory(thread: thread) { session in
                let capabilities = try await session.historyCapabilities(threadID: expected.sourceReference.nativeThreadID)
                guard capabilities.reference == expected.sourceReference, capabilities.canRead, capabilities.canForkHead else { throw ProviderHistoryError(.notIdle) }
                let first = try await session.conversationSnapshot(threadID: expected.sourceReference.nativeThreadID)
                let last = try await session.conversationSnapshot(threadID: expected.sourceReference.nativeThreadID)
                guard first == last, first.reference == expected.sourceReference, first.historyMode == .paginated,
                      first.workspacePath == expected.sourceConfiguration.workspacePath else { throw ProviderHistoryError(.historyChanged) }
                return first
            }
            if observed.headTurnID == expected.reviewedHeadTurnID { result = .unchanged }
            else if observed.headTurnID == expected.expectedResultHeadTurnID { result = .applied(observed) }
            else { throw ProviderHistoryError(.historyChanged) }
        }
        guard ownsHistorySource(threadID: thread.id, incarnation: incarnation, fingerprint: expected.sourceFingerprint),
              let current = revision.snapshot.conversationHistoryOperation(operation.id),
              try RemoteHistoryProtocol.payload(current) == RemoteHistoryProtocol.payload(operation) else { throw ProviderHistoryError(.historyChanged) }
        return result
    }
}

extension WorkspaceEngine {
    public func reviewContextTransfer(_ request: ContextTransferReviewRequest) async throws -> ContextTransferReview {
        _ = try await load(); try Task.checkCancellation()
        guard !closing, !stoppingEffects, !contextTransfersClosing, fatalError == nil,
              let source = revision.snapshot.threads.first(where: { $0.id == request.sourceThreadID }),
              let sourceIncarnation = threadIncarnations[source.id],
              ContextTransferProtocol.same(ProviderConfiguration(thread: source), request.expectedConfiguration),
              !source.isArchived, revision.snapshot.workspaceReady(for: source),
              !revision.snapshot.isConversationHistoryLocked(threadID: source.id) else { throw ContextTransferError.unavailable }
        contextTransferOperations += 1
        defer { finishContextTransferOperation() }
        let point = try revision.snapshot.contextTransferSource(threadID: source.id, point: request.sourcePoint)
        let fingerprint = try revision.snapshot.contextTransferFingerprint(source, point: point)
        let targetID: UUID, projectID: UUID, base: ContextTransferResolvedPoint?, strategy: ContextTransferStrategy
        var target: ProviderConfiguration
        switch request.intent {
        case .fork(let destination): targetID = UUID(); projectID = source.projectID; base = nil; target = destination; strategy = .portableContext
        case .providerHandoff(let destination):
            guard !source.isBusy, source.queuedTurns.isEmpty, source.runtimeRequests.isEmpty,
                  destination.workspacePath.utf8.elementsEqual(source.workspacePath.utf8),
                  !WorkspaceSnapshot.sameContextProvider(destination, ProviderConfiguration(thread: source)) else { throw ContextTransferError.unavailable }
            targetID = source.id; projectID = source.projectID; base = nil; target = destination; strategy = .portableContext
        case .mergeBack(let expected):
            guard let lineage = source.contextTransferLineage,
                  let parent = revision.snapshot.threads.first(where: { $0.id == lineage.parentThreadID }),
                  ContextTransferProtocol.same(ProviderConfiguration(thread: parent), expected),
                  !parent.isArchived, revision.snapshot.workspaceReady(for: parent),
                  !revision.snapshot.isConversationHistoryLocked(threadID: parent.id) else { throw ContextTransferError.unavailable }
            targetID = parent.id; projectID = parent.projectID; base = lineage.basePoint; target = expected; strategy = .forkDeltaContext
        }
        target.nativeThreadID = nil; target.claudeLaunchSelection = nil
        var targetBinding: ContextTransferProviderBinding?
        if case .providerHandoff = request.intent {
            targetBinding = source.contextProviderBindings?.last(where: {
                WorkspaceSnapshot.sameContextProvider($0.configuration, target) &&
                !revision.snapshot.isOriginalImportedSession(configuration: $0.configuration, threadID: source.id)
            })
            target.nativeThreadID = targetBinding?.configuration.nativeThreadID
        }
        var messages = try revision.snapshot.contextTransferMessages(thread: source, through: point, ownRunsOnly: base != nil)
        var pendingReferences: [ContextTransferPendingReference] = []
        if case .providerHandoff = request.intent {
            let pending = revision.snapshot.pendingContextTransfers(threadID: source.id)
            guard pending.count <= 32 else { throw ContextTransferError.limit }
            pendingReferences = pending.map { .init(id: $0.id, digest: $0.review.digest) }
            messages.append(contentsOf: pending.flatMap { $0.review.messages })
            var seen = Set<Data>(); messages = messages.filter { seen.insert(Data($0.id.utf8)).inserted }
        }
        if let targetBinding { let known = Set(targetBinding.knownItemIDs); messages.removeAll { known.contains($0.id) } }
        guard try ContextTransferProtocol.payload(messages).count <= ContextTransferProtocol.maximumArchiveBytes else { throw ContextTransferError.limit }
        var native: ConversationHistoryReview?
        // Review proves a native exact boundary, not just same-provider names.
        // An active source can still transfer an earlier immutable portable point.
        if case .fork = request.intent, !source.isBusy, source.queuedTurns.isEmpty, source.runtimeRequests.isEmpty,
           [.codex, .claude].contains(source.provider), target.provider == source.provider,
           target.workspacePath.utf8.elementsEqual(source.workspacePath.utf8),
           target.codexRuntimeConfiguration == source.codexRuntimeConfiguration,
           target.claudeRuntimeConfiguration == source.claudeRuntimeConfiguration,
           let runID = point.runID, source.activeHistoryRuns.first(where: { $0.id == runID })?.status == .completed {
            do { native = try await reviewConversationHistory(threadID: source.id, runID: runID, kind: .forkAfterRun) }
            catch is CancellationError { throw CancellationError() }
            catch { native = nil }
        }
        guard !closing, !stoppingEffects, !contextTransfersClosing, fatalError == nil, !Task.isCancelled,
              let fresh = revision.snapshot.threads.first(where: { $0.id == source.id }),
              threadIncarnations[source.id] == sourceIncarnation,
              try revision.snapshot.contextTransferFingerprint(fresh, point: point) == fingerprint else {
            if let native { await discardConversationHistoryReview(reviewID: native.id) }
            throw ContextTransferError.staleReview
        }
        var review = ContextTransferReview(id: native?.id ?? UUID(), digest: "", request: request,
            sourcePoint: point, basePoint: base, targetThreadID: native?.targetThreadID ?? targetID, projectID: projectID,
            sourceConfiguration: .init(thread: source), targetConfiguration: target, targetProviderBinding: targetBinding,
            strategy: native == nil ? (targetBinding == nil ? strategy : .deltaContext) : .nativeFork, title: source.title + (base == nil ? " (fork)" : " context"),
            messages: messages, nativeReview: native, sourceFingerprint: fingerprint,
            sourceIncarnation: sourceIncarnation, targetIncarnation: threadIncarnations[targetID], reviewedAt: Date())
        if case .providerHandoff = request.intent { review.pendingSourceTransfers = pendingReferences }
        review.digest = try review.validatedDigest()
        do {
            try revision.snapshot.validateContextTransferReview(review)
            let bytes = try ContextTransferProtocol.payload(review).count
            let used = try contextTransferReviews.values.reduce(0) { try $0 + ContextTransferProtocol.payload($1).count }
            guard contextTransferReviews.count < ContextTransferProtocol.maximumReviews,
                  bytes <= ContextTransferProtocol.maximumReviewBytes - used else { throw ContextTransferError.limit }
            contextTransferReviews[review.id] = review
            return review
        } catch { if let native { await discardConversationHistoryReview(reviewID: native.id) }; throw error }
    }
    public func prepareContextTransferAcceptance(reviewID: UUID, digest: String) async throws -> ContextTransferReview {
        _ = try await load()
        guard let review = contextTransferReviews[reviewID], review.digest == digest else { throw ContextTransferError.staleReview }
        try validateContextTransferAcceptance(review, snapshot: revision.snapshot)
        return review
    }
    func validateContextTransferAcceptance(_ review: ContextTransferReview, snapshot: WorkspaceSnapshot) throws {
        guard !closing, !stoppingEffects, !contextTransfersClosing, fatalError == nil,
              let cached = contextTransferReviews[review.id], ContextTransferProtocol.same(cached, review),
              threadIncarnations[review.request.sourceThreadID] == review.sourceIncarnation,
              review.kind == .fork || threadIncarnations[review.targetThreadID] == review.targetIncarnation,
              try review.validatedDigest() == review.digest else { throw ContextTransferError.staleReview }
        try snapshot.validateContextTransferReview(review)
    }
    public func discardContextTransferReview(id: UUID, digest: String) async {
        guard acceptingContextTransfers[id, default: 0] == 0,
              let review = contextTransferReviews[id], review.digest == digest else { return }
        contextTransferReviews.removeValue(forKey: id)
        if let native = review.nativeReview { await discardConversationHistoryReview(reviewID: native.id) }
    }
    func prepareScratchContextTransfer(_ review: ContextTransferReview, commandID: UUID) throws -> ScratchWorkspaceAllocation? {
        guard review.kind == .fork, revision.snapshot.projects.first(where: { $0.id == review.projectID })?.scratch != nil else { return nil }
        try validateContextTransferAcceptance(review, snapshot: revision.snapshot)
        guard let owner = revision.snapshot.threads.first(where: {
            $0.projectID == review.projectID && !$0.isArchived && $0.scratchWorkspace != nil &&
            $0.workspacePath.utf8.elementsEqual(review.targetConfiguration.workspacePath.utf8)
        }), let source = owner.scratchWorkspace else { throw ScratchWorkspaceError() }
        try scratchWorkspaces.validate(thread: owner)
        return try scratchWorkspaces.reuse(source: source, commandID: commandID, threadID: review.targetThreadID)
    }
    func recordScratchContextTransfer(_ allocation: ScratchWorkspaceAllocation?, commandID: UUID, originalPayload: Data) throws {
        guard let allocation else { return }
        guard allocation.receipt.commandID == commandID else { throw ScratchWorkspaceError() }
        try scratchWorkspaces.recordPayload(allocation: allocation, payload: originalPayload)
    }
    private func capturedScratchContext(_ command: EngineCommand) -> (ContextTransferReview, String?, ScratchWorkspaceAllocation?)? {
        switch command {
        case .contextTransferAccepted(let review, let title, let allocation): return (review, title, allocation)
        case .appMCP(_, let commands) where commands.count == 1:
            if case .contextTransferAccepted(let review, let title, let allocation) = commands[0] { return (review, title, allocation) }; return nil
        default: return nil
        }
    }
    @discardableResult public func acceptContextTransfer(reviewID: UUID, digest: String, title: String? = nil, commandID: UUID = UUID()) async throws -> WorkspaceCommandReceipt {
        _ = try await load()
        if let payload = try scratchWorkspaces.submission(commandID) {
            guard let recorded = try? JSONDecoder().decode(EngineCommand.self, from: payload),
                  let (original, originalTitle, allocation) = capturedScratchContext(recorded), allocation?.receipt.commandID == commandID,
                  original.id == reviewID, original.digest == digest, ContextTransferProtocol.same(title, originalTitle) else { throw WorkspaceCommitError.commandIDCollision }
            if let receipt = try await database.receipt(commandID, matching: payload) { return receipt }
            return try await enqueue(recorded, id: commandID)
        }
        if let saved = revision.snapshot.contextTransfers?.first(where: { $0.commandID == commandID && $0.id == reviewID && $0.review.digest == digest }) {
            return try await enqueue(.contextTransferAccepted(review: saved.review, title: title), id: commandID)
        }
        let review = try await prepareContextTransferAcceptance(reviewID: reviewID, digest: digest)
        let allocation = try prepareScratchContextTransfer(review, commandID: commandID)
        let native = EngineCommand.contextTransferAccepted(review: review, title: title, scratchAllocation: allocation)
        let command: EngineCommand
        if let authority = AppMCPTaskContext.authority { command = .appMCP(authority: authority, commands: [native]) }
        else { command = native }
        try recordScratchContextTransfer(allocation, commandID: commandID, originalPayload: taskCommandPayload(command))
        acceptingContextTransfers[review.id, default: 0] += 1
        contextTransferOperations += 1
        do {
            let receipt = try await enqueue(command, id: commandID)
            await finishContextTransferAcceptance(review)
            return receipt
        } catch { await finishContextTransferAcceptance(review); throw error }
    }
    private func finishContextTransferAcceptance(_ review: ContextTransferReview) async {
        defer { finishContextTransferOperation() }
        let remaining = acceptingContextTransfers[review.id, default: 1] - 1
        if remaining > 0 { acceptingContextTransfers[review.id] = remaining; return }
        acceptingContextTransfers.removeValue(forKey: review.id)
        contextTransferReviews.removeValue(forKey: review.id)
        if let native = review.nativeReview { await discardConversationHistoryReview(reviewID: native.id) }
    }
    @discardableResult public func abandonContextTransfer(threadID: UUID, deliveryID: UUID, expectedTransferIDs: [UUID], commandID: UUID = UUID()) async throws -> WorkspaceCommandReceipt {
        let result = try await dispatch(.abandonContextTransfer(threadID: threadID, deliveryID: deliveryID, expectedTransferIDs: expectedTransferIDs), id: commandID)
        if result.rejection == nil { await awaitContextTransferRetirement(threadID: threadID, deliveryID: deliveryID) }
        return result
    }
    public func reviewContextTransfer(request: ContextTransferReviewRequest) async throws -> ContextTransferReview { try await reviewContextTransfer(request) }
    public func closeContextTransfers() async {
        contextTransfersClosing = true
        let unused = contextTransferReviews.values.filter { acceptingContextTransfers[$0.id, default: 0] == 0 }
        for review in unused { contextTransferReviews.removeValue(forKey: review.id); if let native = review.nativeReview { await discardConversationHistoryReview(reviewID: native.id) } }
        if contextTransferOperations > 0 { await withCheckedContinuation { contextTransferWaiters.append($0) } }
    }
    private func finishContextTransferOperation() {
        contextTransferOperations -= 1
        if contextTransferOperations == 0 { let waiters = contextTransferWaiters; contextTransferWaiters = []; for waiter in waiters { waiter.resume() } }
    }
    // Observation only: deterministic owned-writer contention tests can prove
    // the acceptance fence without inserting timing sleeps or commit hooks.
    func contextTransferAdmissionState(reviewID: UUID) -> (acceptances: Int, committing: Bool, closing: Bool) {
        (acceptingContextTransfers[reviewID, default: 0], completedDuringCommit != nil, contextTransfersClosing)
    }
    func awaitRemoteContextCompletion(_ request: RemoteEnvironmentCommandRequest) async {
        if case .contextTransfer(let target, .useFreshContext(let deliveryID, _)) = request.command {
            await awaitContextTransferRetirement(threadID: target.threadID, deliveryID: deliveryID)
        }
    }
    private func recordContextTransferRetirement(_ command: EngineCommand) {
        let threadID: UUID, deliveryID: UUID
        switch command {
        case .client(.abandonContextTransfer(let thread, let delivery, _)): threadID = thread; deliveryID = delivery
        case .remoteEnvironment(let request, _):
            guard case .contextTransfer(let target, .useFreshContext(let delivery, _)) = request.command else { return }
            threadID = target.threadID; deliveryID = delivery
        default: return
        }
        guard contextTransferRetirements[deliveryID] == nil else { return }
        // Capture only the cleanup owners present at this original commit.
        // A later receipt lookup cannot discover or close a successor runtime.
        let jobs = cleanupTasks.values.filter { $0.threadIDs.contains(threadID) }.map(\.task)
        guard !jobs.isEmpty else { return }
        let owner = UUID()
        let task = Task { [weak self] in
            for job in jobs { await job.value }
            await self?.contextTransferRetirementFinished(deliveryID: deliveryID, owner: owner)
        }
        contextTransferRetirements[deliveryID] = .init(id: owner, threadID: threadID, task: task)
    }
    private func contextTransferRetirementFinished(deliveryID: UUID, owner: UUID) {
        if contextTransferRetirements[deliveryID]?.id == owner { contextTransferRetirements.removeValue(forKey: deliveryID) }
    }
    private func awaitContextTransferRetirement(threadID: UUID, deliveryID: UUID) async {
        guard let retired = contextTransferRetirements[deliveryID], retired.threadID == threadID else { return }
        await retired.task.value
    }
}

// MARK: - Durable app-owned delegated work
extension WorkspaceEngine {
    public func createDelegatedTask(_ request: DelegatedTaskRequest, commandID: UUID = UUID()) async throws -> DelegatedTaskAcceptance {
        _ = try await load()
        if let old = revision.snapshot.delegatedTasks?.first(where: { $0.commandID == commandID }) {
            guard try TaskOrchestration.payload(old.request) == TaskOrchestration.payload(request),
                  let receipt = try await database.receipt(commandID) else { throw DelegatedTaskError.invalidRequest }
            return .init(taskID: old.id, childThreadID: old.childThreadID, childRunID: old.childRunID, receipt: receipt)
        }
        let prepared = try await prepareDelegatedTask(request, commandID: commandID)
        return try await dispatchPreparedDelegatedTask(prepared, commandID: commandID)
    }
    func prepareDelegatedTask(_ request: DelegatedTaskRequest, commandID: UUID) async throws -> DelegatedTaskPreparation {
        _ = try await load(); try Task.checkCancellation()
        guard !closing, !stoppingEffects, fatalError == nil,
              try TaskOrchestration.payload(request).count <= 1_048_576,
              !request.task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              request.task.utf16.count <= 120_000, !request.task.contains("\0"),
              request.title.map({ $0.utf16.count <= 512 && !$0.contains("\0") }) ?? true,
              request.configuration.nativeThreadID == nil, request.configuration.claudeLaunchSelection == nil,
              let parent = revision.snapshot.threads.first(where: { $0.id == request.parentThreadID && !$0.isArchived }),
              let run = parent.activeRun, run.id == request.parentRunID, !run.stopRequested,
              let incarnation = threadIncarnations[parent.id], let runtime = runtimes[parent.id], runtime.id == parent.runtimeID,
              try TaskOrchestration.payload(ProviderConfiguration(thread: parent)) == TaskOrchestration.payload(request.expectedConfiguration),
              request.configuration.workspacePath.utf8.elementsEqual(parent.workspacePath.utf8),
              AppMCPAdmission.permits(request.configuration.permission, ceiling: parent.permission),
              AppMCPAdmission.permits(request.configuration.permission, ceiling: run.configuration.permission),
              let project = revision.snapshot.projects.first(where: { $0.id == parent.projectID }) else { throw DelegatedTaskError.staleParent }
        let proof = request.isolation == .worktree ? try await TaskIsolationCapture().capture(parentWorkspacePath: parent.workspacePath, projectPath: project.path) : nil
        if let proof { try await TaskIsolationCapture().validate(proof, requireCurrentHead: true) }
        guard !closing, !stoppingEffects, threadIncarnations[parent.id] == incarnation,
              runtimes[parent.id]?.id == runtime.id,
              revision.snapshot.threads.first(where: { $0.id == parent.id })?.activeRun?.id == run.id,
              revision.snapshot.threads.first(where: { $0.id == parent.id })?.activeRun?.stopRequested == false else { throw DelegatedTaskError.staleParent }
        let taskID = TaskOrchestration.derivedID(commandID, "task")
        let worktree = proof.map { GitWorktreeRequest(id: TaskOrchestration.derivedID(commandID, "checkout"),
            sourcePath: $0.projectPath, destinationRoot: worktreesRoot.path,
            selection: .createBranch(name: "coincide-task-" + taskID.uuidString.lowercased(), baseRef: $0.baseCommit),
            expectedSourceIdentity: $0.projectIdentity) }
        var child = CodingThread(project: project, model: request.configuration.model)
        child.id = TaskOrchestration.derivedID(commandID, "child")
        var configuration = request.configuration
        configuration.workspacePath = worktree?.sourcePath ?? parent.workspacePath
        if let runtime = configuration.claudeRuntimeConfiguration { configuration.claudeRuntimeConfiguration = try runtime.replacingWorkspace(configuration.workspacePath) }
        child.applyContextConfiguration(configuration)
        child.title = request.title ?? "Delegated " + request.role.rawValue
        child.checkpointPolicy = parent.checkpointPolicy
        child.delegatedTaskLineage = .init(taskID: taskID, parentThreadID: parent.id, parentRunID: run.id,
            rootThreadID: parent.delegatedTaskLineage?.rootThreadID ?? parent.id)
        if let authority = AppMCPTaskContext.authority {
            child.createdByAppMCP = .init(sessionID: authority.sessionID, threadID: authority.threadID, runID: authority.runID)
        }
        return .init(request: request, child: child, parentIncarnation: incarnation, parentRuntimeID: runtime.id, isolation: proof, worktree: worktree)
    }
    func dispatchPreparedDelegatedTask(_ prepared: DelegatedTaskPreparation, commandID: UUID) async throws -> DelegatedTaskAcceptance {
        let receipt = try await enqueue(.delegatedTaskAccepted(prepared), id: commandID)
        if let rejection = receipt.rejection { throw WorkspaceCommandError(rejection) }
        guard let task = revision.snapshot.delegatedTasks?.first(where: { $0.commandID == commandID }) else { throw DelegatedTaskError.unavailable }
        return .init(taskID: task.id, childThreadID: task.childThreadID, childRunID: task.childRunID, receipt: receipt)
    }
    public func delegatedTaskStatus(parentThreadID: UUID, taskID: UUID, acknowledge: Bool = true) async throws -> DelegatedTaskStatusSnapshot {
        _ = try await load()
        guard let task = revision.snapshot.delegatedTasks?.first(where: { $0.id == taskID && $0.parentThreadID == parentThreadID }) else { throw DelegatedTaskError.notFound }
        if acknowledge, task.result != nil, ![.acknowledged, .delivered, .disposed].contains(task.completion.state) {
            let runID = revision.snapshot.threads.first(where: { $0.id == parentThreadID })?.activeRun?.id
            let receipt = try await enqueue(.delegatedTaskObserved(parentThreadID: parentThreadID, taskID: taskID, observingRunID: runID))
            if let rejection = receipt.rejection { throw WorkspaceCommandError(rejection) }
        }
        return try delegatedStatus(parentThreadID: parentThreadID, taskID: taskID)
    }
    private func delegatedStatus(parentThreadID: UUID, taskID: UUID, timedOut: Bool = false) throws -> DelegatedTaskStatusSnapshot {
        guard var task = revision.snapshot.delegatedTasks?.first(where: { $0.id == taskID && $0.parentThreadID == parentThreadID }) else { throw DelegatedTaskError.notFound }
        task.latestTerminalResult = revision.snapshot.delegatedTasks?.last(where: { $0.childThreadID == task.childThreadID && $0.result != nil && $0.result?.runID != task.result?.runID })?.result
        let child = revision.snapshot.threads.first { $0.id == task.childThreadID }
        let pending = child?.runtimeRequests.filter { !$0.responding } ?? []
        let later = child?.queuedTurns.contains { $0.id != task.childRunID && ![task.id].contains($0.delegatedTaskID ?? task.id) } == true ||
            (child?.activeRun.map { $0.id != task.childRunID && $0.delegatedTaskID != task.id } ?? false)
        return .init(task: task, hasPendingChildRuns: later && child?.queuePaused != true,
            pendingQuestions: task.status.isTerminal ? [] : pending.filter { $0.request.isQuestion },
            pendingApproval: task.status.isTerminal || task.completion.state == .disposed ? nil : pending.first { !$0.request.isQuestion }, waitTimedOut: timedOut, pendingApprovalRunID: task.status.isTerminal || task.completion.state == .disposed ? nil : child?.activeRun?.id)
    }
    public func waitForDelegatedTask(parentThreadID: UUID, taskID: UUID, timeoutMilliseconds: Int = TaskOrchestration.defaultWaitMilliseconds) async throws -> DelegatedTaskStatusSnapshot {
        _ = try await load()
        guard (0...TaskOrchestration.maximumWaitMilliseconds).contains(timeoutMilliseconds) else { throw DelegatedTaskError.invalidRequest }
        // Register before inspecting state so a terminal event cannot fall in a
        // read/subscribe gap. The newest snapshot is authoritative; no polling.
        let stream = updates()
        let initial = try delegatedStatus(parentThreadID: parentThreadID, taskID: taskID)
        if initial.task.result != nil { return try await delegatedTaskStatus(parentThreadID: parentThreadID, taskID: taskID, acknowledge: true) }
        if timeoutMilliseconds == 0 || !initial.pendingQuestions.isEmpty || initial.pendingApproval != nil {
            _ = try await enqueue(.delegatedTaskWakePolicy(parentThreadID: parentThreadID, taskID: taskID))
            return try delegatedStatus(parentThreadID: parentThreadID, taskID: taskID, timedOut: timeoutMilliseconds == 0 && initial.pendingQuestions.isEmpty && initial.pendingApproval == nil)
        }
        let winner: Bool
        do { winner = try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask { [weak self] in
                for await _ in stream {
                    try Task.checkCancellation()
                    guard let self else { throw CancellationError() }
                    let status = try await self.delegatedStatus(parentThreadID: parentThreadID, taskID: taskID)
                    if status.task.result != nil || !status.pendingQuestions.isEmpty || status.pendingApproval != nil { return false }
                }
                throw CancellationError()
            }
            group.addTask { try await Task.sleep(for: .milliseconds(timeoutMilliseconds)); return true }
            defer { group.cancelAll() }
            return try await group.next()!
        } } catch {
            _ = try? await Task.detached { [weak self] in
                guard let self else { return }
                _ = try await self.enqueue(.delegatedTaskWakePolicy(parentThreadID: parentThreadID, taskID: taskID))
            }.value
            throw error
        }
        let status = try delegatedStatus(parentThreadID: parentThreadID, taskID: taskID, timedOut: winner)
        if status.task.result == nil {
            _ = try await enqueue(.delegatedTaskWakePolicy(parentThreadID: parentThreadID, taskID: taskID))
            return status
        }
        return try await delegatedTaskStatus(parentThreadID: parentThreadID, taskID: taskID, acknowledge: true)
    }
    public func cancelDelegatedTask(parentThreadID: UUID, taskID: UUID, reason: String? = nil, commandID: UUID = UUID()) async throws -> WorkspaceCommandReceipt {
        _ = try await load()
        guard reason.map({ $0.utf16.count <= 2_000 && !$0.contains("\0") }) ?? true else { throw DelegatedTaskError.invalidRequest }
        let command = EngineCommand.delegatedTaskCancel(parentThreadID: parentThreadID, taskID: taskID, reason: reason)
        let dedupCommand = AppMCPTaskContext.authority.map { EngineCommand.appMCP(authority: $0, commands: [command]) } ?? command
        if let receipt = try await database.receipt(commandID, matching: try taskCommandPayload(dedupCommand)) {
            if let drain = delegatedTaskDrains[commandID] { await drain.value }; return receipt
        }
        guard let task = revision.snapshot.delegatedTasks?.first(where: { $0.id == taskID && $0.parentThreadID == parentThreadID }) else { throw DelegatedTaskError.notFound }
        let tree = revision.snapshot.delegatedTaskTree(task.id)
        let childIDs = Set(tree.map(\.childThreadID))
        let owners = childIDs.compactMap { id -> DelegatedTaskDrainOwner? in
            guard let run = revision.snapshot.threads.first(where: { $0.id == id })?.activeRun else { return nil }
            return .init(threadID: id, runID: run.id, runtimeID: runtimes[id]?.id)
        }
        let owned = childIDs.compactMap { id -> (UUID, UUID)? in runtimes[id].map { (id, $0.id) } }
        let ownedJobs = effectRequests.compactMap { id, request -> Task<Void, Never>? in
            guard request.threadID.map({ thread in tree.contains { $0.childThreadID == thread } }) == true else { return nil }; return effects[id]
        }
        let receipt = try await enqueue(command, id: commandID)
        if let rejection = receipt.rejection { throw WorkspaceCommandError(rejection) }
        let cleanup = cleanupTasks.values.filter { !$0.threadIDs.isDisjoint(with: childIDs) }.map(\.task)
        let drain = Task { [weak self] in
            guard let self else { return }
            for (threadID, runtimeID) in owned { await self.closeRuntime(threadID, matching: runtimeID) }
            for job in ownedJobs { job.cancel(); await job.value }
            for job in cleanup { await job.value }
        }
        delegatedTaskDrains[commandID] = drain
        await drain.value
        _ = try? await enqueue(.delegatedTaskDrained(owners), id: TaskOrchestration.derivedID(commandID, "drained"))
        delegatedTaskDrains.removeValue(forKey: commandID)
        return receipt
    }
    private func taskCommandPayload(_ command: EngineCommand) throws -> Data {
        switch command {
        case .agentSessionImportAccepted(let admission): return try agentSessionImportPayload(reviewID: admission.review.id, digest: admission.review.digest)
        case .delegatedTaskAccepted(let prepared): return try TaskOrchestration.payload(["delegatedTask": try TaskOrchestration.payload(prepared.request)])
        case .appMCP(_, let commands) where commands.count == 1:
            if case .delegatedTaskAccepted = commands[0] { return try taskCommandPayload(commands[0]) }
            if case .delegatedTaskCancel = commands[0] { return try taskCommandPayload(commands[0]) }
            return try encoder.encode(command)
        default: return try encoder.encode(command)
        }
    }
    private func scheduleDelegatedTaskCompletions() {
        delegatedTaskWakeGeneration &+= 1
        guard !closing, !stoppingEffects, fatalError == nil, delegatedTaskDeliveryJob == nil else { return }
        guard revision.snapshot.delegatedTasks?.contains(where: { task in
            task.result != nil && task.completion.state == .pending && revision.snapshot.threads.contains(where: { $0.id == task.parentThreadID && !$0.isArchived && !$0.queuePaused })
        }) == true else { return }
        delegatedTaskDeliveryJob = Task { [weak self] in
            guard let self else { return }; await self.deliverDelegatedCompletions()
        }
    }
    private func deliverDelegatedCompletions() async {
        let generation = delegatedTaskWakeGeneration
        defer {
            delegatedTaskDeliveryJob = nil
            // A child can settle while provider capability discovery awaits.
            // Revisit the latest ledger after this owned offer finishes, rather
            // than dropping that wake or concurrently offering it twice.
            if delegatedTaskWakeGeneration != generation { scheduleDelegatedTaskCompletions() }
        }
        let pending = (revision.snapshot.delegatedTasks ?? []).filter { $0.result != nil && $0.completion.state == .pending }
        for parentID in Set(pending.map(\.parentThreadID)) {
            guard !closing, !stoppingEffects,
                  let parent = revision.snapshot.threads.first(where: { $0.id == parentID && !$0.isArchived && !$0.queuePaused }) else { continue }
            // A blocking delegate wait owns terminal delivery while its exact
            // calling run remains live. Async and lost-wait tasks use the cohort.
            let tasks = Array(pending.filter { $0.parentThreadID == parentID && ($0.wakePolicy == .always || parent.activeRun?.id != $0.parentRunID) }.prefix(TaskOrchestration.maximumCohortTasks))
            guard !tasks.isEmpty else { continue }
            // A previously accepted/unknown notification is not retried, even if
            // provider support changes or the same helper reconnects.
            let activeCohorts = (revision.snapshot.delegatedTaskCohorts ?? []).filter { $0.threadID == parentID && $0.state == .claimed }
            if let queued = activeCohorts.first(where: { cohort in parent.queuedTurns.contains(where: { $0.id == cohort.inputID }) && cohort.steeringOperationID == nil }) {
                let additions = Array(tasks.prefix(max(0, TaskOrchestration.maximumCohortTasks - queued.taskIDs.count)))
                if !additions.isEmpty { _ = try? await enqueue(.delegatedTaskCompletionCoalesced(cohortID: queued.id, expectedTaskIDs: queued.taskIDs, taskIDs: additions.map(\.id))) }
                continue
            }
            guard activeCohorts.isEmpty, parent.activeRun?.delegatedCompletion == nil else { continue }
            let generation = ((revision.snapshot.delegatedTaskCohorts ?? []).filter { $0.threadID == parentID }.map(\.generation).max() ?? 0) + 1
            let anchor = tasks[0].parentRunID
            let id = TaskOrchestration.derivedID(anchor, "completion-\(generation)")
            let inputID = TaskOrchestration.derivedID(id, "input"), taskIDs = tasks.map(\.id)
            let reference = DelegatedTaskCompletionReference(cohortID: id, parentRunID: anchor, generation: generation, taskIDs: taskIDs)
            var cohort = DelegatedTaskCohort(id: id, threadID: parentID, parentRunID: anchor, generation: generation,
                disposition: .open, taskIDs: taskIDs, state: .claimed, inputID: inputID, createdAt: Date(), updatedAt: Date())
            var operation: PromptSteeringOperation?
            let availability = await promptSteeringAvailability(threadID: parentID)
            guard !closing, !stoppingEffects else { return }
            if availability.canSteer, let thread = revision.snapshot.threads.first(where: { $0.id == parentID }), let run = thread.activeRun,
               run.id == availability.runID, let target = availability.target, target.matches(run: run),
               let nativeID = thread.providerThreadID, let incarnation = threadIncarnations[parentID],
               let runtime = runtimes[parentID], runtime.id == thread.runtimeID {
                let input = QueuedTurn(id: inputID, text: TaskOrchestration.notice(taskIDs), configuration: run.configuration, createdAt: Date(),
                    checkpointPolicy: thread.effectiveCheckpointPolicy, preservesTitle: true,
                    delegatedTaskID: run.delegatedTaskID, delegatedCompletion: reference)
                operation = .init(id: TaskOrchestration.derivedID(id, "steering"), effectID: TaskOrchestration.derivedID(id, "effect"),
                    threadID: parentID, projectID: thread.projectID, sourceIncarnation: incarnation,
                    runtimeID: runtime.id, runID: run.id, nativeThreadID: nativeID, target: target, input: input,
                    messageID: "user-\(inputID.uuidString)", configuration: run.configuration, preservesComposer: true)
                cohort.steeringOperationID = operation?.id
            }
            if operation == nil, !revision.snapshot.pendingContextTransfers(threadID: parentID).isEmpty { continue }
            // Cohort/input/effect identities are stable once accepted. A refused
            // preflight attempt has no effect and must not burn that generation.
            _ = try? await enqueue(.delegatedTaskCompletionPrepared(cohort, operation))
        }
    }
    private func validateTaskIsolation(_ task: DelegatedTask, plan: GitWorktreePlan) async throws {
        guard let proof = task.isolationProof else { throw DelegatedTaskError.invalidRequest }
        try await TaskIsolationCapture().validate(proof)
        guard plan.sourcePath.utf8.elementsEqual(proof.projectPath.utf8), plan.sourceIdentity == proof.projectIdentity,
              plan.sourceGitDirectoryPath.utf8.elementsEqual(proof.projectGitDirectoryPath.utf8), plan.sourceGitDirectoryIdentity == proof.projectGitDirectoryIdentity,
              plan.commonDirectoryPath.utf8.elementsEqual(proof.commonDirectoryPath.utf8), plan.commonDirectoryIdentity == proof.commonDirectoryIdentity,
              plan.baseCommit == proof.baseCommit else { throw TaskIsolationError.changedRepository }
    }
}

extension WorkspaceEngine {
    /// Filesystem-only discovery from explicitly host-captured native profiles.
    /// A changed profile retires all prior read leases; it never starts a CLI.
    public func scanAgentSessions(profiles: [AgentSessionProfile]) async throws -> AgentSessionScanResult {
        _ = try await load(); try Task.checkCancellation()
        guard !closing, !stoppingEffects, !agentSessionImportsClosing else { throw CancellationError() }
        let digest = try AgentSessionImportProtocol.digest(profiles)
        if agentSessionScanner == nil || agentSessionProfilesDigest != digest {
            let previous = agentSessionScanner
            agentSessionScanner = try AgentSessionScanner(profiles: profiles,
                excludingWorkspaceRoots: [agentSessionDataRoot.path, worktreesRoot.path])
            agentSessionProfilesDigest = digest; agentSessionScannerGeneration = UUID()
            agentSessionScanResults = [:]; agentSessionScanOrder = []; agentSessionCompletedSources = [:]; agentSessionImportReviews = [:]
            if let previous { await previous.close() }
        }
        guard let scanner = agentSessionScanner, agentSessionProfilesDigest == digest else { throw AgentSessionImportError.staleScan }
        let generation = agentSessionScannerGeneration
        let result = try await scanner.scan(projects: revision.snapshot.projects)
        guard !closing, !stoppingEffects, !agentSessionImportsClosing, generation == agentSessionScannerGeneration else {
            await scanner.release(scanID: result.id); throw CancellationError()
        }
        agentSessionScanResults[result.id] = result; agentSessionScanOrder.append(result.id)
        while agentSessionScanOrder.count > 4, let first = agentSessionScanOrder.first { await releaseAgentSessionScan(first) }
        return result
    }

    public func prepareAgentSessionImport(scanID: UUID, projectID: UUID, expectedWorkspaceRoot: String, cursor: UUID? = nil) async throws -> AgentSessionImportPage {
        _ = try await load(); try Task.checkCancellation()
        guard !closing, !stoppingEffects, !agentSessionImportsClosing, let scanner = agentSessionScanner,
              let scan = agentSessionScanResults[scanID], scan.candidates.contains(where: { $0.path.utf8.elementsEqual(expectedWorkspaceRoot.utf8) }),
              let project = revision.snapshot.projects.first(where: { $0.id == projectID }),
              project.path.utf8.elementsEqual(expectedWorkspaceRoot.utf8), project.clone?.isReady ?? true,
              let incarnation = projectIncarnations[projectID], !removalCommitProjects.contains(projectID) else { throw AgentSessionImportError.changed }
        let generation = agentSessionScannerGeneration
        let key = scanID.uuidString + ":" + projectID.uuidString + ":" + Data(expectedWorkspaceRoot.utf8).base64EncodedString()
        if agentSessionCompletedSources[key] == nil {
            guard cursor == nil else { throw AgentSessionImportError.staleScan }
            agentSessionCompletedSources[key] = (revision.snapshot.agentSessionImports ?? [])
                .filter { $0.workspacePath.utf8.elementsEqual(expectedWorkspaceRoot.utf8) }.flatMap(\.sources)
        }
        let page = try await scanner.prepareImport(scanID: scanID, projectID: projectID, expectedWorkspaceRoot: expectedWorkspaceRoot,
            cursor: cursor, completedSources: agentSessionCompletedSources[key] ?? [])
        guard !closing, !stoppingEffects, !agentSessionImportsClosing, generation == agentSessionScannerGeneration,
              agentSessionScanResults[scanID] != nil, projectIncarnations[projectID] == incarnation,
              revision.snapshot.projects.contains(where: { $0.id == projectID && $0.path.utf8.elementsEqual(expectedWorkspaceRoot.utf8) }),
              !removalCommitProjects.contains(projectID) else { throw AgentSessionImportError.changed }
        for review in page.reviews {
            var configuration = review.profile.configuration
            configuration.provider = review.transcript.source.provider; configuration.workspacePath = expectedWorkspaceRoot
            configuration.nativeThreadID = review.transcript.providerSessionID
            configuration.model = review.transcript.model ?? configuration.model
            configuration.claudeLaunchSelection = nil
            if let runtime = configuration.claudeRuntimeConfiguration {
                configuration.claudeRuntimeConfiguration = try runtime.replacingWorkspace(expectedWorkspaceRoot, physicalPath: expectedWorkspaceRoot)
            }
            try configuration.codexRuntimeConfiguration?.validate(); try configuration.validateClaudeConfiguration()
            agentSessionImportReviews[review.id] = .init(review: review, configuration: configuration, projectIncarnation: incarnation)
        }
        return page
    }

    @discardableResult public func acceptAgentSessionImport(reviewID: UUID, digest: String, commandID: UUID = UUID()) async throws -> WorkspaceCommandReceipt {
        _ = try await load()
        let payload = try agentSessionImportPayload(reviewID: reviewID, digest: digest)
        // Original receipts win before volatile leases, native file reads or any
        // new provider/settings lookup, including after an app restart.
        if let receipt = try await database.receipt(commandID, matching: payload) { return receipt }
        guard !closing, !stoppingEffects, !agentSessionImportsClosing, let scanner = agentSessionScanner,
              let admission = agentSessionImportReviews[reviewID], admission.review.digest == digest else { throw AgentSessionImportError.staleScan }
        let generation = agentSessionScannerGeneration
        try await scanner.validate(admission.review)
        try Task.checkCancellation()
        guard !closing, !stoppingEffects, !agentSessionImportsClosing, generation == agentSessionScannerGeneration,
              agentSessionImportReviews[reviewID] == admission else { throw AgentSessionImportError.staleScan }
        let receipt = try await enqueue(.agentSessionImportAccepted(admission), id: commandID)
        agentSessionImportReviews.removeValue(forKey: reviewID)
        await scanner.release(reviewID: reviewID)
        if let rejection = receipt.rejection { throw WorkspaceCommandError(rejection) }
        return receipt
    }

    public func agentSessionImportReceipt(reviewID: UUID, digest: String, commandID: UUID, resolvingAbsent: Bool = false) async throws -> WorkspaceCommandReceipt? {
        _ = try await load()
        return try await inspectedCommandReceipt(commandID, payload: agentSessionImportPayload(reviewID: reviewID, digest: digest), resolvingAbsent: resolvingAbsent)
    }

    public func releaseAgentSessionScan(_ scanID: UUID) async {
        agentSessionScanResults.removeValue(forKey: scanID); agentSessionScanOrder.removeAll { $0 == scanID }
        agentSessionImportReviews = agentSessionImportReviews.filter { $0.value.review.scanID != scanID }
        agentSessionCompletedSources = agentSessionCompletedSources.filter { !$0.key.hasPrefix(scanID.uuidString + ":") }
        await agentSessionScanner?.release(scanID: scanID)
    }
    public func closeAgentSessionImports() async {
        agentSessionImportsClosing = true; agentSessionScannerGeneration = UUID()
        let scanner = agentSessionScanner; agentSessionScanner = nil; agentSessionProfilesDigest = nil
        agentSessionScanResults = [:]; agentSessionScanOrder = []; agentSessionCompletedSources = [:]; agentSessionImportReviews = [:]
        await scanner?.close()
    }
    private func agentSessionImportPayload(reviewID: UUID, digest: String) throws -> Data {
        guard digest.utf8.count == 64, digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw AgentSessionImportError.invalidRequest }
        struct Intent: Encodable { let kind = "agent-session-import-v1"; let reviewID: UUID; let digest: String }
        return try AgentSessionImportProtocol.payload(Intent(reviewID: reviewID, digest: digest))
    }
    private func validateAgentSessionImportAdmission(_ admission: AgentSessionImportAdmission, snapshot: WorkspaceSnapshot) async throws {
        guard !closing, !stoppingEffects, !agentSessionImportsClosing, let scanner = agentSessionScanner,
              agentSessionImportReviews[admission.review.id] == admission,
              projectIncarnations[admission.review.projectID] == admission.projectIncarnation,
              snapshot.projects.contains(where: { $0.id == admission.review.projectID && $0.path.utf8.elementsEqual(admission.review.expectedWorkspaceRoot.utf8) }),
              !removalCommitProjects.contains(admission.review.projectID), !isCodexAuthenticationLocked(admission.configuration) else { throw AgentSessionImportError.changed }
        let generation = agentSessionScannerGeneration
        try await scanner.validateAdmissionIdentity(admission.review)
        guard !closing, !stoppingEffects, !agentSessionImportsClosing, generation == agentSessionScannerGeneration,
              agentSessionImportReviews[admission.review.id] == admission,
              projectIncarnations[admission.review.projectID] == admission.projectIncarnation else { throw AgentSessionImportError.changed }
    }
}

extension WorkspaceEngine {
    func readRemoteSteering(_ target: RemoteWorkspaceTarget) async throws -> RemoteSteeringNativeRead {
        _ = try await load()
        func current() throws -> CodingThread {
            guard !closing, !stoppingEffects, fatalError == nil,
                  let thread = revision.snapshot.threads.first(where: { $0.id == target.threadID }), !thread.isArchived,
                  thread.projectID == target.projectID, thread.workspacePath.utf8.elementsEqual(target.workspacePath.utf8),
                  RemoteLifecycleProtocol.same(ProviderConfiguration(thread: thread), target.configuration) else { throw RemoteEnvironmentAdmission.stale() }
            return thread
        }
        let captured = try current(), incarnation = threadIncarnations[captured.id]
        let availability = await promptSteeringAvailability(threadID: captured.id)
        let thread = try current()
        guard let incarnation, threadIncarnations[thread.id] == incarnation,
              thread.activeRun?.id == captured.activeRun?.id, thread.runtimeID == captured.runtimeID,
              let project = revision.snapshot.projects.first(where: { $0.id == thread.projectID }) else { throw RemoteEnvironmentAdmission.stale() }
        return .init(sequence: revision.sequence, thread: thread, project: project, incarnation: incarnation, availability: availability,
                     operations: (revision.snapshot.promptSteerings ?? []).filter { $0.threadID == thread.id })
    }
    func prepareRemoteSteering(commandID: UUID, target: RemoteWorkspaceTarget, action: RemoteSteeringAction, incarnation: UUID) async throws -> RemoteSteeringPreparation {
        let source = try await readRemoteSteering(target), thread = source.thread, capture = action.capture
        guard source.incarnation == incarnation, thread.createdAt == capture.threadCreatedAt, source.project.createdAt == capture.projectCreatedAt else { throw RemoteEnvironmentAdmission.stale() }
        if case .acknowledge(_, let id, let digest) = action {
            guard let operation = source.operations.first(where: { $0.id == id }), operation.isUnconfirmed,
                  try RemoteSteeringProtocol.digest(operation) == digest else { throw RemoteEnvironmentAdmission.stale() }
            return .init(target: target, capture: capture, incarnation: incarnation, action: action)
        }
        guard thread.activeRun?.id == capture.runID, thread.runtimeID == capture.runtimeID,
              try thread.activeRun.map({ try RemoteSteeringProtocol.digest($0.configuration) }) == capture.activeConfigurationDigest else { throw RemoteEnvironmentAdmission.stale() }
        switch action {
        case .removeQueued(_, let id, let digest):
            guard let queued = thread.queuedTurns.first(where: { $0.id == id }), try RemoteSteeringProtocol.digest(queued) == digest else { throw RemoteEnvironmentAdmission.stale() }
            return .init(target: target, capture: capture, incarnation: incarnation, action: action, queueOrder: thread.queuedTurns.map(\.id))
        case .moveQueued(_, let id, let beforeID, let revision):
            guard capture.queueRevision == revision, try RemoteSteeringProtocol.queueRevision(thread.queuedTurns) == revision,
                  thread.queuedTurns.contains(where: { $0.id == id }), beforeID != id, beforeID == nil || thread.queuedTurns.contains(where: { $0.id == beforeID }) else { throw RemoteEnvironmentAdmission.stale() }
            return .init(target: target, capture: capture, incarnation: incarnation, action: action, queueOrder: thread.queuedTurns.map(\.id))
        default: break
        }
        let attachmentTarget = RemoteAttachmentTarget(environmentID: target.environmentID, projectID: thread.projectID, threadID: thread.id)
        var records: [RemoteAttachmentRecord] = []
        let ids = action.uploadedIDs
        guard ids.count <= AttachmentLimits.count, Set(ids).count == ids.count else { throw RemoteAttachmentFailure(.invalidRequest) }
        for id in ids {
            guard let record = try await database.remoteAttachment(attachmentTarget, id: id), !record.cancelled, record.claimedBy == nil else { throw RemoteAttachmentFailure(.notFound) }
            records.append(record)
        }
        if case .editQueued(_, let id, let digest, let text, let selected, _, let ordered) = action {
            guard let queued = thread.queuedTurns.first(where: { $0.id == id }), try RemoteSteeringProtocol.digest(queued) == digest,
                  queued.existingMessageID == nil, queued.contextDelivery == nil, text.utf16.count <= 120_000, !text.contains("\0") else { throw RemoteEnvironmentAdmission.stale() }
            let originals = queued.attachments ?? []
            guard Set(selected).count == selected.count, selected.allSatisfy({ id in originals.contains { $0.id == id } }) else { throw RemoteEnvironmentAdmission.stale() }
            let all = originals.filter { selected.contains($0.id) } + records.map(\.attachment)
            guard Set(all.map(\.id)).count == all.count, Set(ordered).count == ordered.count, Set(ordered) == Set(all.map(\.id)) else { throw RemoteEnvironmentAdmission.stale() }
            let attachments = ordered.compactMap { id in all.first { $0.id == id } }
            try AttachmentLimits.validate(attachments)
            return .init(target: target, capture: capture, incarnation: incarnation, action: action, records: records,
                         queuedEdit: .init(thread: thread, queued: queued, text: text, attachments: attachments))
        }
        guard source.availability.canSteer, let run = thread.activeRun, let native = thread.providerThreadID,
              let runtime = thread.runtimeID, let nativeTarget = source.availability.target else { throw WorkspaceCommandError(source.availability.unavailableReason ?? "The active turn cannot be steered.") }
        let input: QueuedTurn, queuedID: UUID?
        switch action {
        case .steerComposer(_, let value):
            try value.validate()
            guard value.target == attachmentTarget, value.threadCreatedAt == thread.createdAt, value.projectCreatedAt == source.project.createdAt,
                  RemoteLifecycleProtocol.same(value.expectedConfiguration, target.configuration),
                  RemoteComposerSubmission.textDigest(thread.draft) == value.expectedHostDraftDigest,
                  ComposerDraftSnapshot.sameAttachments(thread.draftAttachments, value.expectedDraftAttachments) else { throw RemoteEnvironmentAdmission.stale() }
            let originals = thread.draftAttachments.filter { value.selectedDraftAttachmentIDs.contains($0.id) } + records.map(\.attachment)
            let selected = value.orderedAttachmentIDs.compactMap { id in originals.first { $0.id == id } }
            guard selected.count == value.orderedAttachmentIDs.count else { throw RemoteEnvironmentAdmission.stale() }
            input = .init(id: TaskOrchestration.derivedID(commandID, "remote-steering-input"), text: value.text.trimmingCharacters(in: .whitespacesAndNewlines), configuration: run.configuration, createdAt: Date(), attachments: selected.isEmpty ? nil : selected, checkpointPolicy: thread.effectiveCheckpointPolicy)
            queuedID = nil
        case .steerQueued(_, let id, let digest):
            guard revision.snapshot.promptSteeringTargetReason(threadID: thread.id, queuedID: id) == nil,
                  let queued = thread.queuedTurns.first(where: { $0.id == id }), try RemoteSteeringProtocol.digest(queued) == digest else { throw RemoteEnvironmentAdmission.stale() }
            input = queued; queuedID = id
        default: throw RemoteEnvironmentAdmission.stale()
        }
        let operation = PromptSteeringOperation(id: RemoteSteeringProtocol.operationID(commandID), effectID: TaskOrchestration.derivedID(commandID, "remote-steering-effect"),
            threadID: thread.id, projectID: thread.projectID, sourceIncarnation: incarnation, runtimeID: runtime, runID: run.id,
            nativeThreadID: native, target: nativeTarget, input: input, messageID: "user-\(input.id.uuidString)", queuedID: queuedID, configuration: run.configuration)
        return .init(target: target, capture: capture, incarnation: incarnation, action: action, operation: operation, records: records)
    }
    func validateRemoteSteeringPreparation(_ prepared: RemoteSteeringPreparation, snapshot: WorkspaceSnapshot) throws {
        guard !closing, !stoppingEffects, threadIncarnations[prepared.target.threadID] == prepared.incarnation,
              let thread = snapshot.threads.first(where: { $0.id == prepared.target.threadID }), thread.createdAt == prepared.capture.threadCreatedAt,
              thread.projectID == prepared.target.projectID, thread.workspacePath.utf8.elementsEqual(prepared.target.workspacePath.utf8),
              snapshot.projects.first(where: { $0.id == thread.projectID })?.createdAt == prepared.capture.projectCreatedAt,
              RemoteLifecycleProtocol.same(ProviderConfiguration(thread: thread), prepared.target.configuration) else { throw RemoteEnvironmentAdmission.stale() }
        if case .acknowledge = prepared.action { return }
        guard thread.activeRun?.id == prepared.capture.runID, thread.runtimeID == prepared.capture.runtimeID,
              try thread.activeRun.map({ try RemoteSteeringProtocol.digest($0.configuration) }) == prepared.capture.activeConfigurationDigest else { throw RemoteEnvironmentAdmission.stale() }
        if prepared.queueOrder != nil {
            guard try RemoteSteeringProtocol.queueRevision(thread.queuedTurns) == prepared.capture.queueRevision else { throw RemoteEnvironmentAdmission.stale() }
        }
        if let operation = prepared.operation {
            guard runtimes[thread.id]?.id == operation.runtimeID, thread.activeRun.map(operation.matchesActiveRun) == true else { throw RemoteEnvironmentAdmission.stale() }
        }
    }
}

public extension WorkspaceEngine {
    func replaceQueuedInput(_ replacement: QueuedInputReplacement, commandID: UUID = UUID()) async throws -> WorkspaceCommandReceipt {
        _ = try await load()
        let receipt = try await enqueue(.queuedInputReplaced(replacement), id: commandID)
        if let rejection = receipt.rejection { throw WorkspaceCommandError(rejection) }
        return receipt
    }
}

extension WorkspaceEngine {
    func registerRemoteThreadActionOwner(_ binding: RemoteThreadActionBinding) {
        guard !closing, !stoppingEffects, remoteThreadActionOwners.count < 16 else { return }
        remoteThreadActionOwners[binding.leaseID] = binding
    }
    func releaseRemoteThreadActionOwner(_ binding: RemoteThreadActionBinding) {
        guard remoteThreadActionOwners[binding.leaseID] == binding else { return }
        remoteThreadActionOwners.removeValue(forKey: binding.leaseID)
        threadActionUndos.remove(ownerID: binding.leaseID)
    }
    func readRemoteThreadUndo(_ binding: RemoteThreadActionBinding) async throws -> RemoteThreadUndoNativeRead {
        _ = try await load()
        try validateRemoteThreadActionOwner(binding)
        threadActionUndos.reconcile(snapshot: revision.snapshot, now: Date())
        let native = threadActionUndos.owned(by: binding.leaseID, now: Date())
        return .init(sequence: revision.sequence, claims: native.claims, deadline: native.deadline)
    }
    func readRemoteThreadAction(_ target: RemoteWorkspaceTarget) async throws -> RemoteThreadActionNativeRead {
        _ = try await load()
        guard !closing, !stoppingEffects, let thread = revision.snapshot.threads.first(where: { $0.id == target.threadID }),
              thread.projectID == target.projectID, thread.workspacePath.utf8.elementsEqual(target.workspacePath.utf8),
              RemoteLifecycleProtocol.same(target.configuration, ProviderConfiguration(thread: thread)),
              let project = revision.snapshot.projects.first(where: { $0.id == thread.projectID }), let incarnation = threadIncarnations[thread.id] else { throw RemoteEnvironmentAdmission.stale() }
        return .init(sequence: revision.sequence, incarnation: incarnation, state: .init(thread: thread, project: project, draft: false), runID: thread.activeRun?.id, runtimeID: thread.runtimeID)
    }
    private func validateRemoteThreadActionOwner(_ binding: RemoteThreadActionBinding) throws {
        guard !closing, !stoppingEffects, fatalError == nil, remoteThreadActionOwners[binding.leaseID] == binding else { throw RemoteEnvironmentAdmission.stale() }
    }
    private func validateRemoteThreadActions(_ prepared: RemoteThreadActionsPreparation, snapshot: WorkspaceSnapshot) throws {
        try validateRemoteThreadActionOwner(prepared.binding)
        if let capture = prepared.capture {
            guard capture.target.environmentID == prepared.binding.environmentID, threadIncarnations[capture.target.threadID] == prepared.incarnation else { throw RemoteEnvironmentAdmission.stale() }
        } else {
            guard !prepared.claims.isEmpty, prepared.claims.count <= 128, prepared.deadline.map({ $0 > Date() }) == true else { throw RemoteEnvironmentAdmission.stale() }
            for claim in prepared.claims {
                try threadActionUndos.validate(claim, commandID: claim.id, now: Date())
                guard claim.ownerID == prepared.binding.leaseID, claim.isApplicable(to: snapshot) else { throw RemoteEnvironmentAdmission.stale() }
            }
        }
    }
}

extension WorkspaceEngine {
    private func recordRemoteThreadActionDrain(_ command: EngineCommand, id: UUID) {
        guard case .remoteEnvironment(let request, let preparation) = command else { return }
        var ids: Set<UUID> = [], settlements: Set<UUID> = []
        if case .threadAction(.setArchived(let capture, true)) = request.command { ids.insert(capture.target.threadID) }
        if case .threadActions(let prepared) = preparation {
            for claim in prepared.claims where claim.kind == .settle { ids.insert(claim.threadID); if let settlement = claim.after.settlementID { settlements.insert(settlement) } }
        }
        let jobs = cleanupTasks.values.filter { !$0.threadIDs.isDisjoint(with: ids) }.map(\.task) + settlements.compactMap { settlementClosures[$0] }
        guard !jobs.isEmpty else { return }
        let token = UUID()
        let task = Task { [weak self] in for job in jobs { await job.value }; await self?.remoteThreadActionDrained(id, token: token) }
        remoteThreadActionDrains[id] = (token, task)
    }
    private func remoteThreadActionDrained(_ id: UUID, token: UUID) { if remoteThreadActionDrains[id]?.0 == token { remoteThreadActionDrains.removeValue(forKey: id) } }
    func awaitRemoteThreadActionsCompletion(_ request: RemoteEnvironmentCommandRequest) async {
        // Only the exact original owned retirement task; receipt replay never
        // looks up or drains a replacement runtime.
        if let task = remoteThreadActionDrains[request.id]?.1 { await task.value }
    }
}


extension WorkspaceEngine {
    /// Compacts only a connection already owned by this engine. It never opens a
    /// runtime, resumes a CLI import, submits a chat prompt, or retries a request.
    public func compactContext(threadID: UUID, expectedConfiguration: ProviderConfiguration,
                               expectedRuntimeID: UUID) async throws -> WorkspaceUpdate {
        _ = try await load(); try Task.checkCancellation()
        guard !closing, !stoppingEffects, fatalError == nil else { throw WorkspaceCommandError(ProviderContextCompactionError(.notStarted).localizedDescription) }
        if let reason = revision.snapshot.contextCompactionUnavailableReason(threadID: threadID) { throw WorkspaceCommandError(reason) }
        guard let thread = revision.snapshot.threads.first(where: { $0.id == threadID }),
              ProviderConfiguration(thread: thread) == expectedConfiguration, thread.runtimeID == expectedRuntimeID,
              let incarnation = threadIncarnations[threadID], compactionRuntimeMatches(thread) else {
            throw WorkspaceCommandError(ProviderContextCompactionError(.notIdle).localizedDescription)
        }
        let operation = ContextCompactionOperation(thread: thread, incarnation: incarnation, runtimeID: expectedRuntimeID)
        let receipt = try await enqueue(.contextCompactionAccepted(operation))
        if let rejection = receipt.rejection { throw WorkspaceCommandError(rejection) }
        return current()
    }

    public func cancelContextCompaction(threadID: UUID, operationID: UUID) async throws -> WorkspaceUpdate {
        _ = try await load(); try Task.checkCancellation()
        let receipt = try await enqueue(.contextCompactionCancelled(threadID: threadID, operationID: operationID))
        if let rejection = receipt.rejection { throw WorkspaceCommandError(rejection) }
        return current()
    }

    private func compactionRuntimeMatches(_ thread: CodingThread) -> Bool {
        guard let runtime = runtimes[thread.id], runtime.id == thread.runtimeID,
              runtime.projectID == thread.projectID, runtime.provider == thread.provider,
              runtime.path == thread.workspacePath,
              runtime.codexBinding == ProviderConfiguration(thread: thread).codexRuntimeBinding,
              claudeRuntimeMatches(runtime, thread: thread) else { return false }
        return true
    }

    private func validateContextCompactionAdmission(_ command: EngineCommand, snapshot: WorkspaceSnapshot) throws {
        switch command {
        case .contextCompactionAccepted(let operation):
            guard threadIncarnations[operation.threadID] == operation.sourceIncarnation,
                  let thread = snapshot.threads.first(where: { $0.id == operation.threadID }), operation.matches(thread),
                  compactionRuntimeMatches(thread), !isCodexAuthenticationLocked(operation.configuration) else {
                throw WorkspaceCommandError(ProviderContextCompactionError(.notIdle).localizedDescription)
            }
        case .contextCompactionDispatching(let threadID, let operationID, let incarnation):
            guard threadIncarnations[threadID] == incarnation,
                  let operation = snapshot.contextCompaction(threadID: threadID), operation.id == operationID,
                  operation.sourceIncarnation == incarnation, operation.phase == .pending,
                  let thread = snapshot.threads.first(where: { $0.id == threadID }), operation.matches(thread),
                  compactionRuntimeMatches(thread), !isCodexAuthenticationLocked(operation.configuration) else {
                throw WorkspaceCommandError(ProviderContextCompactionError(.notStarted).localizedDescription)
            }
        default: break
        }
    }

    private func performContextCompaction(_ request: WorkspaceEffectRequest) async -> EffectResult {
        guard case .contextCompaction(let threadID, let operationID) = request,
              let operation = revision.snapshot.contextCompaction(threadID: threadID), operation.id == operationID,
              operation.phase == .pending, let runtime = runtimes[threadID] else { return .cancelled }
        do {
            try Task.checkCancellation()
            let receipt = try await enqueue(.contextCompactionDispatching(threadID: threadID, operationID: operationID, incarnation: operation.sourceIncarnation))
            guard receipt.rejection == nil else { return .failed(ProviderContextCompactionError(.notStarted).localizedDescription) }
            guard !closing, !stoppingEffects, fatalError == nil,
                  threadIncarnations[threadID] == operation.sourceIncarnation,
                  revision.snapshot.contextCompaction(threadID: threadID)?.id == operationID,
                  revision.snapshot.contextCompaction(threadID: threadID)?.phase == .running,
                  let thread = revision.snapshot.threads.first(where: { $0.id == threadID }), operation.matches(thread),
                  runtime.id == operation.runtimeID, compactionRuntimeMatches(thread),
                  !isCodexAuthenticationLocked(operation.configuration) else { return .failed(ProviderContextCompactionError(.notStarted).localizedDescription) }
            try Task.checkCancellation()
            let result = try await runtime.session.compactContext(thread: thread, operationID: operationID)
            guard result.provider == operation.provider, result.nativeThreadID == operation.configuration.nativeThreadID else {
                return .failed(ProviderContextCompactionError(.unconfirmed).localizedDescription)
            }
            return .succeeded
        } catch let error as ProviderContextCompactionError {
            return .failed(error.localizedDescription)
        } catch {
            // No arbitrary provider diagnostics, summaries or credentials enter
            // the durable operation or its public CLI status.
            return .failed(ProviderContextCompactionError(.unconfirmed).localizedDescription)
        }
    }
}
