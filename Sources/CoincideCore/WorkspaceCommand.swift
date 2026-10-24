import Foundation

extension ProviderConfiguration {
    /// Swift String equality folds canonical Unicode spellings. Model-control
    /// admission compares the complete captured execution value as exact bytes.
    public func matchesModelControlCapture(_ expected: Self) -> Bool {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard let current = try? encoder.encode(self), let original = try? encoder.encode(expected) else { return false }
        return current == original
    }
}

public struct QueuedTurn: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var text: String
    public var configuration: ProviderConfiguration
    public var createdAt: Date
    public var attachments: [ChatAttachment]? = nil
    public var checkpointPolicy: RunCheckpointPolicy? = nil
    public var existingMessageID: String? = nil
    public var preservesTitle: Bool? = nil
    public var delegatedTaskID: UUID? = nil
    public var delegatedCompletion: DelegatedTaskCompletionReference? = nil
    public var delegatedTaskOwnershipRecorded: Bool? = nil
    public var contextTransferIDs: [UUID]? = nil
    public var contextDelivery: ContextTransferDelivery? = nil
}
public struct ActiveRun: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var configuration: ProviderConfiguration
    public var startedAt: Date
    public var stopRequested = false
    public var nativeTurnID: String?
    public var delegatedTaskID: UUID? = nil
    public var delegatedCompletion: DelegatedTaskCompletionReference? = nil
    public var delegatedTaskOwnershipRecorded: Bool? = nil
    public var contextTransferIDs: [UUID]? = nil
    public var contextDelivery: ContextTransferDelivery? = nil
}
public struct RuntimeRequest: Codable, Sendable, Equatable, Identifiable {
    public var request: ApprovalRequest
    public var responding = false
    public var sessionScoped: Bool?
    public var id: JSONValue { request.id }
}

public enum ThreadEdit: Codable, Sendable, Equatable {
    case title(String), model(String), provider(ProviderKind), permission(PermissionMode)
    case draft(String), pinned(Bool), archived(Bool), workspacePath(String)
    indirect case draftProject(DraftProjectAssignment)
    case agentMode(String?)
    case codexInteractionMode(CodexModeSelection)
    case checkpointPolicy(RunCheckpointPolicy)
    case codexModel(ProviderModel), codexReasoning(model: ProviderModel, effort: String?), codexDefaultModel(CodexDefaultModelSelection)
    indirect case codexServiceTier(model: ProviderModel, tier: String?, expected: ProviderConfiguration? = nil)
    case claudeModel(ProviderModel?)
    indirect case claudeModelOptions(model: ProviderModel, options: ClaudeModelOptions, expected: ProviderConfiguration? = nil)
    indirect case resetProviderModelOptions(expected: ProviderConfiguration? = nil)
    case codexRuntimeConfiguration(CodexRuntimeConfiguration)
    case codexProvider(CodexRuntimeConfiguration)
    case claudeProvider(ClaudeRuntimeConfiguration)
    case claudeRuntimeConfiguration(ClaudeRuntimeConfiguration)
    case claudeWorkspace(ClaudeRuntimeConfiguration)
}

/// Keep captured payloads off the stack while commands pass through admission,
/// steering and journal reduction. Codable cases and value semantics stay intact.
public indirect enum WorkspaceCommand: Codable, Sendable, Equatable {
    case addProject(WorkspaceProject)
    case addProjectWithThread(project: WorkspaceProject, thread: CodingThread)
    case renameProject(projectID: UUID, title: String)
    case removeProject(projectID: UUID, expectedThreadIDs: [UUID])
    case renameProjectGroup(groupKey: String, expectedProjects: [ProjectGroupMemberReference], title: String)
    case removeProjectGroup(groupKey: String, expectedProjects: [ProjectGroupMemberReference], expectedThreadIDs: [UUID])
    case setProjectExpanded(projectID: UUID, expanded: Bool)
    case setProjectSortMode(ProjectSortMode)
    case setProjectPinned(projectID: UUID, pinned: Bool)
    case setThreadSortMode(ThreadSortMode)
    case reorderThreads(threadIDs: [UUID], expectedOrder: [UUID])
    case setProjectGroupingMode(ProjectGroupingMode)
    case setProjectGroupingOverride(projectID: UUID, mode: ProjectGroupingMode?)
    case setProjectGroupExpanded(groupKey: String, expectedProjectIDs: [UUID], expanded: Bool)
    case setProjectGroupCheckout(groupKey: String, expectedProjectIDs: [UUID], projectID: UUID)
    case selectConversation(threadID: UUID?)
    case moveProject(projectID: UUID, before: UUID?, expectedOrder: [UUID])
    case reorderProjects(projectIDs: [UUID], expectedOrder: [UUID])
    case reorderProjectGroups(projectIDs: [UUID], expectedOrder: [UUID], expectedGroups: [String: [UUID]])
    case createThread(CodingThread)
    case editThread(UUID, ThreadEdit)
    case submitDefaultWorktree(DefaultWorktreeInput)
    case useCurrentCheckout(threadID: UUID, intentID: UUID)
    case submit(threadID: UUID, text: String)
    case submitFromAppMCP(threadID: UUID, text: String, queueEvenWhenIdle: Bool)
    case submitCapturedClaude(threadID: UUID, text: String, configuration: ClaudeRuntimeConfiguration)
    case interrupt(threadID: UUID)
    case interruptFromAppMCP(threadID: UUID, expectedRunID: UUID?, expectedRuntimeID: UUID?)
    case respond(threadID: UUID, requestID: JSONValue, response: ProviderApprovalResponse)
    case removeQueued(threadID: UUID, queuedID: UUID)
    case editQueued(threadID: UUID, queuedID: UUID)
    case replaceQueuedText(threadID: UUID, queuedID: UUID, expectedText: String, text: String)
    case moveQueued(threadID: UUID, queuedID: UUID, beforeID: UUID?, expectedOrder: [UUID])
    case resumeQueue(threadID: UUID)
    case addAttachments(threadID: UUID, attachments: [ChatAttachment])
    case removeAttachment(threadID: UUID, attachmentID: UUID)
    case scheduledTask(ScheduledTaskMutation)
    case replaceComposerDraft(ComposerDraftReplacement)
    case discardComposerDraft(ThreadDraftDiscard)
    case threadActionUndo(ThreadActionUndoClaim)
    case workspaceLifecycle(WorkspaceLifecycleAction)
    case setWorkspaceLifecyclePolicy(WorkspaceLifecyclePolicy)
    case startProjectClone(project: WorkspaceProject, thread: CodingThread)
    case cancelWorktreePreparation(UUID)
    case cancelProjectClone(UUID)
    case retryProjectClone(projectID: UUID, plan: GitClonePlan)
    case approveProjectScript(threadID: UUID, runID: UUID, expectedPlan: ProjectScriptExecutionPlan)
    case stopProjectScript(threadID: UUID, runID: UUID)
    case skipProjectScript(threadID: UUID, runID: UUID)
    case retryProjectScript(threadID: UUID, runID: UUID)
    case settleThread(threadID: UUID, expectedWorkspacePath: String, reviewScript: Bool)
    case resumeThread(threadID: UUID, generationID: UUID)
    case retryPostRunCheckpoint(threadID: UUID, runID: UUID, expectedAttemptID: UUID)
    case continueAfterPostRunCheckpoint(threadID: UUID, runID: UUID, expectedAttemptID: UUID)
    case recallConversationHistoryPrompt(operationID: UUID)
    case acknowledgePullRequestCreation(operationID: UUID)
    case acknowledgePullRequestCheckout(operationID: UUID)
    case acknowledgePromptSteering(operationID: UUID)
    case acknowledgeCheckpointRestore(operationID: UUID)
    case acknowledgeConversationHistoryFiles(operationID: UUID)
    case dismissConversationHistoryRecall(operationID: UUID)
    case abandonContextTransfer(threadID: UUID, deliveryID: UUID, expectedTransferIDs: [UUID])
}

// Captured history/checkpoint values can be large. Keep the internal command
// envelope indirect so decoding and broad switch dispatch copy an owned reference
// instead of reserving every case's maximum payload on the worker stack.
indirect enum EngineCommand: Codable, Sendable {
    case retryDefaultWorktree(threadID: UUID, attemptID: UUID)
    case defaultWorktreeSubmission(DefaultWorktreeInput, GitWorktreeRequest)
    case transcriptPlanImplementation(TranscriptPlanImplementation)
    case scratchThreadAccepted(ScratchThreadCreation)
    case agentSessionImportAccepted(AgentSessionImportAdmission)
    case delegatedTaskAccepted(DelegatedTaskPreparation)
    case delegatedTaskCancel(parentThreadID: UUID, taskID: UUID, reason: String?)
    case delegatedTaskDrained([DelegatedTaskDrainOwner])
    case delegatedTaskObserved(parentThreadID: UUID, taskID: UUID, observingRunID: UUID?)
    case delegatedTaskWakePolicy(parentThreadID: UUID, taskID: UUID)
    case delegatedTaskCompletionPrepared(DelegatedTaskCohort, PromptSteeringOperation?)
    case delegatedTaskCompletionCoalesced(cohortID: UUID, expectedTaskIDs: [UUID], taskIDs: [UUID])
    case contextTransferAccepted(review: ContextTransferReview, title: String?, scratchAllocation: ScratchWorkspaceAllocation? = nil)
    case contextTransferDispatching(threadID: UUID, runID: UUID, deliveryID: UUID, runtimeID: UUID)
    case contextTransferNativeReserved(threadID: UUID, runID: UUID, deliveryID: UUID, publication: ClaudeTranscriptPublication)
    case contextTransferNativeReady(threadID: UUID, runID: UUID, deliveryID: UUID, snapshot: ProviderConversationSnapshot)
    case contextTransferRuntimeRebound(threadID: UUID, runID: UUID, deliveryID: UUID, previousRuntimeID: UUID, runtimeID: UUID)
    case contextTransferDeferred(threadID: UUID, runID: UUID, deliveryID: UUID)
    case contextTransferSelectionPrepared(threadID: UUID, runID: UUID, deliveryID: UUID, selection: ContextHandoffSelection)
    case contextTransferDelivered(threadID: UUID, runID: UUID, deliveryID: UUID)
    case contextTransferUncertain(threadID: UUID, runID: UUID, deliveryID: UUID)
    case remoteEnvironment(RemoteEnvironmentCommandRequest, preparation: RemoteEnvironmentPreparation)
    case appMCP(authority: AppMCPCommandAuthority, commands: [EngineCommand])
    case appMCPTargetGuard(threadID: UUID, configuration: ProviderConfiguration)
    case appMCPRequestGuard(threadID: UUID, runtimeID: UUID?, runID: UUID?, request: ApprovalRequest)
    case client(WorkspaceCommand)
    case runtimeOpened(threadID: UUID, runID: UUID, runtimeID: UUID)
    case provider(threadID: UUID, runtimeID: UUID, event: ProviderEvent)
    case effectResult(WorkspaceEffectRequest, EffectResult)
    case beginWorktreePreparation(threadID: UUID, request: GitWorktreeRequest, expectedSourcePath: String, previousAttemptID: UUID?, incarnation: UUID, reviewSetup: Bool = false, claudeRuntimeConfiguration: ClaudeRuntimeConfiguration? = nil)
    case worktreeStarted(threadID: UUID, attemptID: UUID)
    case worktreeRecovered(threadID: UUID, attemptID: UUID, incarnation: UUID, result: GitWorktreeResult)
    case pauseQueues
    case codexAuthenticationPreparing(instanceID: UUID, threadIDs: Set<UUID>)
    case codexAccountConfigured(instanceID: UUID, binding: CodexAccountBinding?)
    case cloneStarted(projectID: UUID, attemptID: UUID)
    case cloneProgress(projectID: UUID, attemptID: UUID, progress: GitCloneProgress)
    case repositoryIdentityResolved(projectID: UUID, path: String, incarnation: UUID, requestID: UUID, identity: RepositoryIdentity?)
    case projectScriptStarted(threadID: UUID, attemptID: UUID, runID: UUID, incarnation: UUID)
    case projectScriptExited(threadID: UUID, attemptID: UUID, runID: UUID, incarnation: UUID, result: ProjectScriptCommandExit?)
    case projectScriptStopped(threadID: UUID, attemptID: UUID, runID: UUID, incarnation: UUID)
    case projectScriptEffectResult(WorkspaceEffectRequest, EffectResult, incarnation: UUID)
    case threadScriptStarted(threadID: UUID, owner: ProjectScriptOwner, runID: UUID, incarnation: UUID)
    case threadScriptExited(threadID: UUID, owner: ProjectScriptOwner, runID: UUID, incarnation: UUID, result: ProjectScriptCommandExit?)
    case threadScriptStopped(threadID: UUID, owner: ProjectScriptOwner, runID: UUID, incarnation: UUID)
    case threadResumed(threadID: UUID, generationID: UUID, incarnation: UUID)
    case runCheckpointEffectResult(WorkspaceEffectRequest, EffectResult, incarnation: UUID)
    case runCheckpointRecovered(threadID: UUID, runID: UUID, stage: RunCheckpointStage, attemptID: UUID, path: String, incarnation: UUID, receipt: GitCheckpointReceipt)
    case conversationHistoryAccepted(review: ConversationHistoryReview, title: String?, scratchFork: ScratchHistoryForkGrant? = nil)
    case conversationHistoryDispatching(threadID: UUID, operationID: UUID, incarnation: UUID)
    case conversationHistoryEffectResult(WorkspaceEffectRequest, EffectResult, incarnation: UUID)
    case conversationHistoryScratchForkHeld(ScratchHistoryForkHeldResult)
    case conversationHistoryClaudeForkReserved(operationID: UUID, publication: ClaudeTranscriptPublication, incarnation: UUID)
    case claudeResumeInspected(threadID: UUID, incarnation: UUID, selection: ClaudeResumeSelection, run: ThreadRunRecord, result: ClaudeResumeInspection)
    case conversationHistoryReconciled(operationID: UUID, incarnation: UUID, result: ConversationHistoryReconciliation)
    case conversationHistoryFilesDispatching(threadID: UUID, operationID: UUID, incarnation: UUID)
    case conversationHistoryFilesEffectResult(WorkspaceEffectRequest, EffectResult, incarnation: UUID)
    case conversationHistoryFilesInspected(operationID: UUID, incarnation: UUID, result: GitCheckpointRestoreInspection)
    case pullRequestCreationAccepted(PullRequestCreationOperation)
    case pullRequestCreationDispatching(projectID: UUID, operationID: UUID, incarnation: UUID)
    case pullRequestCreationEffectResult(WorkspaceEffectRequest, EffectResult, incarnation: UUID)
    case pullRequestCreationReconciled(operationID: UUID, incarnation: UUID, result: GitHubPullRequestCreateReconciliation)
    case pullRequestActionAccepted(PullRequestActionOperation)
    case pullRequestActionDispatching(projectID: UUID, operationID: UUID, incarnation: UUID)
    case pullRequestActionEffectResult(WorkspaceEffectRequest, EffectResult, incarnation: UUID)
    case pullRequestActionInspected(operationID: UUID, incarnation: UUID, state: GitHubPullRequestActionState)
    case pullRequestActionAcknowledged(operationID: UUID)
    case pullRequestCheckoutAccepted(PullRequestCheckoutOperation)
    case pullRequestCheckoutDispatching(projectID: UUID, operationID: UUID, incarnation: UUID)
    case pullRequestCheckoutEffectResult(WorkspaceEffectRequest, EffectResult, incarnation: UUID)
    case pullRequestCheckoutInspected(operationID: UUID, incarnation: UUID, result: GitHubPullRequestCheckoutInspection)
    case pullRequestCheckoutCancel(operationID: UUID)
    case queuedInputReplaced(QueuedInputReplacement)
    case remoteThreadUndo(RemoteThreadActionsPreparation)
    case contextCompactionAccepted(ContextCompactionOperation)
    case contextCompactionDispatching(threadID: UUID, operationID: UUID, incarnation: UUID)
    case contextCompactionCancelled(threadID: UUID, operationID: UUID)
    case promptSteeringAccepted(PromptSteeringOperation)
    case promptSteeringDispatching(operationID: UUID, incarnation: UUID)
    case promptSteeringEffectResult(WorkspaceEffectRequest, EffectResult, incarnation: UUID)
    case checkpointRestoreAccepted(review: RunCheckpointRestoreReview)
    case checkpointRestoreDispatching(threadID: UUID, operationID: UUID, incarnation: UUID)
    case checkpointRestoreEffectResult(WorkspaceEffectRequest, EffectResult, incarnation: UUID)
    case checkpointRestoreInspected(operationID: UUID, incarnation: UUID, result: GitCheckpointRestoreInspection)
}
enum EffectResult: Codable, Sendable {
    case succeeded, failed(String), cancelled, stopped, worktreeResolved(GitWorktreePlan), worktreePrepared(GitWorktreeResult), projectScriptResolved(ProjectScriptExecutionPlan?)
    case checkpointResolved(GitCheckpointPlan), checkpointCaptured(GitCheckpointReceipt, cleanupWarning: Bool), checkpointUnavailable
    case conversationHistoryConfirmed(ProviderConversationSnapshot), conversationHistoryUnconfirmed
    case checkpointRestoreConfirmed(GitCheckpointRestoreReceipt), checkpointRestoreUnconfirmed
    case pullRequestCreationConfirmed(GitHubPullRequestCreateOutcome), pullRequestCreationUnconfirmed
    case pullRequestActionConfirmed(GitHubPullRequestActionOutcome), pullRequestActionUnconfirmed
    case pullRequestCheckoutCompleted(GitHubPullRequestCheckoutResult), pullRequestCheckoutUnconfirmed
    case promptSteeringDelivered(ProviderSteeringReceipt), promptSteeringUnconfirmed, promptSteeringUnsentCompleted
}

struct WorkspaceDecision: Sendable {
    var snapshot: WorkspaceSnapshot
    var effects: [PendingWorkspaceEffect] = []
    var closeRuntimes: Set<UUID> = []
    // Kept for existing single-runtime decision inspections.
    var closeRuntime: UUID? { closeRuntimes.first }
    var cancelCloneAttempt: UUID?
    var cancelWorktreeAttempt: UUID?
    var cancelPullRequestCheckoutOperation: UUID?

    @inline(never)
    private static func validateModelControlCapture(_ expected: ProviderConfiguration?, thread: CodingThread) throws {
        if let expected, !ProviderConfiguration(thread: thread).matchesModelControlCapture(expected) {
            throw WorkspaceCommandError("This conversation's model controls changed. Your current settings and draft were kept.")
        }
    }

    private struct GeneralReduction {
        let decision: WorkspaceDecision
        let requiresFinalization: Bool
    }

    /// Full ledger validation may encode retained checkpoint receipts. It must
    /// run after the general mutation switch releases its temporary buffers.
    @inline(never)
    static func make(_ command: EngineCommand, id: UUID, snapshot: WorkspaceSnapshot, now: Date, validatingLedger: Bool = true) throws -> Self {
        try guardPullRequestActionPhysicalTransitions(command, snapshot: snapshot)
        let reduced: GeneralReduction
        switch command {
        case .contextCompactionAccepted, .contextCompactionDispatching, .contextCompactionCancelled, .effectResult(.contextCompaction, _):
            reduced = .init(decision: try reduceContextCompaction(command, snapshot: snapshot, now: now), requiresFinalization: true)
        case .effectResult(let request, let result) where request.checkpointOwner != nil,
             .runCheckpointEffectResult(let request, let result, _) where request.checkpointOwner != nil,
             .projectScriptEffectResult(let request, let result, _) where request.checkpointOwner != nil:
            reduced = .init(decision: reduceCheckpointResult(request, result: result, snapshot: snapshot, now: now), requiresFinalization: true)
        case .client(.retryPostRunCheckpoint), .client(.continueAfterPostRunCheckpoint):
            reduced = .init(decision: try reducePostRunCheckpointChange(command, id: id, snapshot: snapshot, now: now), requiresFinalization: true)
        case .promptSteeringAccepted(let operation):
            reduced = .init(decision: try reducePromptSteeringAccepted(operation, snapshot: snapshot), requiresFinalization: true)
        case .client(.scheduledTask(let mutation)):
            var prepared = Self(snapshot: snapshot)
            try prepared.prepareClientCommand(.scheduledTask(mutation), commandID: id, now: now)
            reduced = .init(decision: try reduceScheduledTask(mutation, id: id, snapshot: prepared.snapshot, now: now), requiresFinalization: true)
        case .retryDefaultWorktree(let threadID, let attemptID):
            reduced = .init(decision: try reduceDefaultWorktreeRetry(threadID: threadID, attemptID: attemptID, snapshot: snapshot, now: now), requiresFinalization: true)
        case .defaultWorktreeSubmission(let input, let request):
            reduced = .init(decision: try reduceDefaultWorktree(input, request: request, id: id, snapshot: snapshot, now: now), requiresFinalization: true)
        case .remoteThreadUndo(let prepared):
            var decision = Self(snapshot: snapshot)
            for claim in prepared.claims.reversed() { try decision.applyThreadActionUndo(claim, id: claim.id, now: now) }
            reduced = .init(decision: decision, requiresFinalization: true)
        case .queuedInputReplaced(let edit):
            reduced = .init(decision: try reduceQueuedInputReplacement(edit, commandID: id, snapshot: snapshot, now: now), requiresFinalization: true)
        case .client(.workspaceLifecycle(let action)):
            var decision = Self(snapshot: snapshot)
            try decision.applyWorkspaceLifecycle(action, commandID: id, now: now, policy: snapshot.workspaceLifecyclePolicy ?? .init())
            reduced = .init(decision: decision, requiresFinalization: true)
        case .client(.setWorkspaceLifecyclePolicy(let policy)):
            try policy.validate()
            var decision = Self(snapshot: snapshot); decision.snapshot.workspaceLifecyclePolicy = policy
            reduced = .init(decision: decision, requiresFinalization: true)
        case .agentSessionImportAccepted(let admission):
            var decision = Self(snapshot: snapshot)
            try decision.acceptAgentSessionImport(admission, id: id, now: now)
            reduced = .init(decision: decision, requiresFinalization: true)
        case .transcriptPlanImplementation(let request):
            reduced = .init(decision: try reduceTranscriptPlanImplementation(request, id: id, snapshot: snapshot, now: now), requiresFinalization: true)
        case .client(.threadActionUndo(let claim)):
            var decision = Self(snapshot: snapshot)
            try decision.applyThreadActionUndo(claim, id: id, now: now)
            reduced = .init(decision: decision, requiresFinalization: true)
        case .client(.discardComposerDraft(let discard)):
            guard snapshot.threads.contains(where: { $0.id == discard.expected.threadID && $0.createdAt == discard.threadCreatedAt }) else {
                throw WorkspaceCommandError("The conversation changed before its draft was discarded.")
            }
            let replacement = ComposerDraftReplacement(expected: discard.expected, text: "", attachments: [])
            var decision = Self(snapshot: snapshot)
            try decision.prepareClientCommand(.replaceComposerDraft(replacement), commandID: id, now: now)
            try decision.replaceComposerDraft(replacement)
            reduced = .init(decision: decision, requiresFinalization: true)
        case .scratchThreadAccepted(let creation):
            reduced = .init(decision: try reduceScratchThreadCreation(creation, id: id, snapshot: snapshot, now: now), requiresFinalization: true)
        case .client(.replaceComposerDraft(let replacement)):
            var decision = Self(snapshot: snapshot)
            try decision.prepareClientCommand(.replaceComposerDraft(replacement), commandID: id, now: now)
            try decision.replaceComposerDraft(replacement)
            reduced = .init(decision: decision, requiresFinalization: true)
        case .worktreeRecovered:
            reduced = .init(decision: try reduceWorktreeRecovery(command, snapshot: snapshot, now: now), requiresFinalization: true)
        case .beginWorktreePreparation:
            reduced = .init(decision: try reduceWorktreePreparation(command, snapshot: snapshot, now: now), requiresFinalization: true)
        case .delegatedTaskAccepted, .delegatedTaskCancel, .delegatedTaskDrained, .delegatedTaskObserved, .delegatedTaskWakePolicy, .delegatedTaskCompletionPrepared, .delegatedTaskCompletionCoalesced:
            reduced = .init(decision: try reduceDelegatedTask(command, id: id, snapshot: snapshot, now: now), requiresFinalization: true)
        case .contextTransferAccepted, .contextTransferDispatching, .contextTransferNativeReserved, .contextTransferNativeReady, .contextTransferRuntimeRebound, .contextTransferDeferred, .contextTransferSelectionPrepared, .contextTransferDelivered, .contextTransferUncertain, .client(.abandonContextTransfer):
            reduced = .init(decision: try reduceContextTransfer(command, id: id, snapshot: snapshot, now: now), requiresFinalization: true)
        case .remoteEnvironment:
            return try reduceRemoteEnvironment(command, id: id, snapshot: snapshot, now: now)
        case .appMCPRequestGuard, .appMCPTargetGuard, .appMCP:
            return try reduceAppMCPCommand(command, id: id, snapshot: snapshot, now: now)
        case .provider(let threadID, let runtimeID, let event):
            reduced = try reduceProvider(event, threadID: threadID, runtimeID: runtimeID, snapshot: snapshot, now: now)
        case .conversationHistoryAccepted, .conversationHistoryDispatching, .conversationHistoryEffectResult, .conversationHistoryScratchForkHeld, .conversationHistoryClaudeForkReserved,
             .conversationHistoryReconciled, .client(.recallConversationHistoryPrompt):
            reduced = .init(decision: try reduceConversationHistory(command, id: id, snapshot: snapshot, now: now), requiresFinalization: true)
        case .conversationHistoryFilesDispatching, .conversationHistoryFilesEffectResult, .conversationHistoryFilesInspected,
             .client(.acknowledgeConversationHistoryFiles), .client(.dismissConversationHistoryRecall):
            reduced = .init(decision: try reduceConversationHistoryFiles(command, id: id, snapshot: snapshot, now: now), requiresFinalization: true)
        case .checkpointRestoreAccepted, .checkpointRestoreDispatching, .checkpointRestoreEffectResult,
             .checkpointRestoreInspected, .client(.acknowledgeCheckpointRestore):
            reduced = .init(decision: try reduceCheckpointRestore(command, id: id, snapshot: snapshot, now: now), requiresFinalization: true)
        case .pullRequestCheckoutAccepted, .pullRequestCheckoutDispatching, .pullRequestCheckoutEffectResult,
             .pullRequestCheckoutInspected, .pullRequestCheckoutCancel, .client(.acknowledgePullRequestCheckout):
            reduced = .init(decision: try reducePullRequestCheckout(command, id: id, snapshot: snapshot, now: now), requiresFinalization: true)
        case .pullRequestActionAccepted, .pullRequestActionDispatching, .pullRequestActionEffectResult,
             .pullRequestActionInspected, .pullRequestActionAcknowledged:
            reduced = .init(decision: try reducePullRequestAction(command, snapshot: snapshot, now: now), requiresFinalization: true)
        case .client(.addProjectWithThread), .client(.startProjectClone):
            reduced = .init(decision: try reduceProjectRegistration(command, id: id, snapshot: snapshot, now: now), requiresFinalization: true)
        case .client(.submit), .client(.submitFromAppMCP), .client(.submitCapturedClaude):
            reduced = .init(decision: try reduceSubmission(command, id: id, snapshot: snapshot, now: now), requiresFinalization: true)
        case .codexAuthenticationPreparing, .codexAccountConfigured:
            reduced = .init(decision: try reduceCodexAuthentication(command, snapshot: snapshot, now: now), requiresFinalization: true)
        case .projectScriptStarted(let thread, let attempt, let run, let token):
            return try make(.threadScriptStarted(threadID: thread, owner: .setup(attemptID: attempt), runID: run, incarnation: token), id: id, snapshot: snapshot, now: now)
        case .projectScriptExited(let thread, let attempt, let run, let token, let result):
            return try make(.threadScriptExited(threadID: thread, owner: .setup(attemptID: attempt), runID: run, incarnation: token, result: result), id: id, snapshot: snapshot, now: now)
        case .projectScriptStopped(let thread, let attempt, let run, let token):
            return try make(.threadScriptStopped(threadID: thread, owner: .setup(attemptID: attempt), runID: run, incarnation: token), id: id, snapshot: snapshot, now: now)
        default:
            reduced = try makeGeneral(command, id: id, snapshot: snapshot, now: now)
        }
        var decision = reduced.decision
        if decision.snapshot.contextCompactionOperations != nil {
            let retained = Set(decision.snapshot.threads.map(\.id))
            decision.snapshot.contextCompactionOperations?.removeAll { !retained.contains($0.threadID) }
        }
        if case .client(let action) = command { decision.reconcileWorkspaceLifecycle(previous: snapshot, command: action, now: now) }
        try decision.snapshot.reconcileAgentSessionImports(previous: snapshot)
        guard reduced.requiresFinalization && validatingLedger else { return decision }
        return try finalized(decision)
    }
    @inline(never)
    private static func reduceContextCompaction(_ command: EngineCommand, snapshot: WorkspaceSnapshot, now: Date) throws -> Self {
        var decision = Self(snapshot: snapshot)
        switch command {
        case .contextCompactionAccepted(let operation): try decision.acceptContextCompaction(operation)
        case .contextCompactionDispatching(let threadID, let operationID, let incarnation):
            try decision.dispatchContextCompaction(threadID: threadID, operationID: operationID, incarnation: incarnation, now: now)
        case .contextCompactionCancelled(let threadID, let operationID):
            try decision.cancelContextCompaction(threadID: threadID, operationID: operationID, now: now)
        case .effectResult(.contextCompaction(let threadID, let operationID), let result):
            decision.finishContextCompaction(threadID: threadID, operationID: operationID, result: result, now: now)
        default: throw WorkspaceCommandError("This context compaction was routed incorrectly.")
        }
        return decision
    }

    /// A post-run checkpoint can advance a queued turn and inspect retained
    /// history proofs. Do that outside the broad mutation/effect switches: their
    /// debug value temporaries otherwise exhaust a cooperative worker's stack.
    @inline(never)
    private static func reduceCheckpointResult(_ request: WorkspaceEffectRequest, result: EffectResult,
                                               snapshot: WorkspaceSnapshot, now: Date) -> Self {
        var decision = Self(snapshot: snapshot)
        decision.finishCheckpoint(request, result: result, now: now)
        return decision
    }

    /// Unoptimized builds keep every pattern the broad mutation switch tests on
    /// the stack until it returns, so a late case can exhaust a worker's stack.
    @inline(never)
    private static func reducePromptSteeringAccepted(_ operation: PromptSteeringOperation, snapshot: WorkspaceSnapshot) throws -> Self {
        var decision = Self(snapshot: snapshot)
        try decision.acceptPromptSteering(operation)
        return decision
    }

    /// Retry/Continue of a held post-run checkpoint also releases the queued
    /// turn, so keep it outside the broad mutation frame for the same reason.
    @inline(never)
    private static func reducePostRunCheckpointChange(_ command: EngineCommand, id: UUID, snapshot: WorkspaceSnapshot, now: Date) throws -> Self {
        var decision = Self(snapshot: snapshot)
        guard case .client(let action) = command else { throw WorkspaceCommandError("This checkpoint action was routed incorrectly.") }
        try decision.prepareClientCommand(action, commandID: id, now: now)
        switch action {
        case .retryPostRunCheckpoint(let threadID, let runID, let expected):
            try decision.changePostRunCheckpoint(threadID: threadID, runID: runID, expectedAttemptID: expected, retry: true, now: now)
        case .continueAfterPostRunCheckpoint(let threadID, let runID, let expected):
            try decision.changePostRunCheckpoint(threadID: threadID, runID: runID, expectedAttemptID: expected, retry: false, now: now)
        default: throw WorkspaceCommandError("This checkpoint action was routed incorrectly.")
        }
        return decision
    }

    /// Inspection can complete an interrupted checkout while retaining its
    /// paused queue. Keep this small path out of the general mutation frame:
    /// provider readiness may copy large history proof values beneath it.
    @inline(never)
    private static func reduceWorktreeRecovery(_ command: EngineCommand, snapshot: WorkspaceSnapshot, now: Date) throws -> Self {
        guard case .worktreeRecovered(let threadID, let attemptID, _, let result) = command else {
            throw WorkspaceCommandError("This worktree recovery was routed incorrectly.")
        }
        var decision = Self(snapshot: snapshot)
        if let i = decision.snapshot.threads.firstIndex(where: { $0.id == threadID }),
           let state = decision.snapshot.threads[i].workspacePreparation, state.id == attemptID, !state.isReady, let plan = state.plan {
            decision.snapshot.threads[i].queuePaused = true
            decision.finished(.prepareWorktree(threadID: threadID, plan: plan), result: .worktreePrepared(result), now: now)
        }
        return decision
    }
    /// Only the host's closed remote command adapter uses deferred validation;
    /// every native reducer still checks its own action admission normally.
    static func finalizedRemoteBatch(_ decision: Self) throws -> Self { try finalized(decision) }

    /// A live owned gh child holds its physical directories against transitions
    /// that may rebind them. Provider streaming and ordinary edits remain free.
    @inline(never)
    private static func guardPullRequestActionPhysicalTransitions(_ command: EngineCommand, snapshot: WorkspaceSnapshot) throws {
        guard snapshot.pullRequestActions?.contains(where: \.isWorking) == true else { return }
        func requireAvailable(_ paths: [String]) throws {
            guard !paths.contains(where: { snapshot.isPullRequestActionWorking(path: $0) }) else {
                throw WorkspaceCommandError("Wait for the pull request action to stop before changing its checkout.")
            }
        }
        switch command {
        case .client(.workspaceLifecycle(let action)):
            try Self(snapshot: snapshot).guardPullRequestActions(.workspaceLifecycle(action))
        case .defaultWorktreeSubmission(let input, let request):
            try requireAvailable([input.intent.sourcePath, request.destinationPath])
        case .retryDefaultWorktree(let threadID, _):
            if let state = snapshot.threads.first(where: { $0.id == threadID })?.workspacePreparation { try requireAvailable([state.request.sourcePath, state.destinationPath]) }
        case .beginWorktreePreparation(let id, let request, let source, _, _, _, _):
            try requireAvailable([request.sourcePath, request.destinationPath, source] + snapshot.threads.filter { $0.id == id }.map(\.workspacePath))
        case .pullRequestCheckoutAccepted(let operation):
            try requireAvailable(operation.scopePaths + operation.coordinationPaths)
        case .pullRequestCreationAccepted(let operation):
            try requireAvailable(operation.scopePaths)
        case .checkpointRestoreAccepted(let review):
            try requireAvailable([review.workspacePath, review.gitReview.currentPlan.repositoryPath, review.gitReview.currentPlan.commonDirectoryPath])
        default: break
        }
    }

    @inline(never)
    private static func reducePullRequestAction(_ command: EngineCommand, snapshot: WorkspaceSnapshot, now: Date) throws -> Self {
        var decision = Self(snapshot: snapshot)
        switch command {
        case .pullRequestActionAccepted(let operation):
            try decision.acceptPullRequestAction(operation)
        case .pullRequestActionDispatching(let projectID, let operationID, let incarnation):
            try decision.dispatchPullRequestAction(projectID: projectID, operationID: operationID, incarnation: incarnation, now: now)
        case .pullRequestActionEffectResult(let request, let result, let incarnation):
            decision.finishPullRequestAction(request, result: result, incarnation: incarnation, now: now)
        case .pullRequestActionInspected(let operationID, _, let state):
            try decision.inspectPullRequestAction(operationID: operationID, state: state, now: now)
        case .pullRequestActionAcknowledged(let operationID):
            try decision.acknowledgePullRequestAction(operationID: operationID, now: now)
        default: throw WorkspaceCommandError("This workspace command was routed incorrectly.")
        }
        return decision
    }

    /// Provider events have their own frame: the broad admission switch owns
    /// many large captured values that must not stay on the stack while a
    /// terminal event validates history and starts its FIFO successor.
    @inline(never)
    private static func reduceProvider(_ event: ProviderEvent, threadID: UUID, runtimeID: UUID,
                                       snapshot: WorkspaceSnapshot, now: Date) throws -> GeneralReduction {
        var decision = Self(snapshot: snapshot)
        guard !snapshot.isCheckpointRestoreLocked(threadID: threadID),
              !snapshot.isPullRequestCreationLocked(threadID: threadID),
              !snapshot.isPullRequestCheckoutLocked(threadID: threadID) else {
            return .init(decision: decision, requiresFinalization: false)
        }
        do { try decision.receive(event, threadID: threadID, runtimeID: runtimeID, now: now) }
        catch let error as CoincideError {
            try decision.receive(.failure(error.localizedDescription), threadID: threadID, runtimeID: runtimeID, now: now)
        }
        return .init(decision: decision, requiresFinalization: true)
    }

    @inline(never)
    private static func finalized(_ value: Self) throws -> Self {
        var decision = value
        try decision.reconcileDelegatedTasks(now: Date())
        decision.snapshot.reconcileGroupingPreferences()
        try WorkspaceJournal.validate(decision.snapshot)
        return decision
    }

    @inline(never)
    private static func reduceConversationHistory(_ command: EngineCommand, id: UUID, snapshot: WorkspaceSnapshot, now: Date) throws -> Self {
        var decision = Self(snapshot: snapshot)
        if case .client(let action) = command { try decision.prepareClientCommand(action, commandID: id, now: now) }
        switch command {
        case .conversationHistoryAccepted(let review, let title, let grant):
            try decision.acceptConversationHistory(review, title: title, scratchFork: grant, commandID: id, now: now)
        case .conversationHistoryDispatching(let threadID, let operationID, let incarnation):
            try decision.dispatchConversationHistory(threadID: threadID, operationID: operationID, incarnation: incarnation, now: now)
        case .conversationHistoryEffectResult(let request, let result, let incarnation):
            decision.finishConversationHistory(request, result: result, incarnation: incarnation, now: now)
        case .conversationHistoryScratchForkHeld(let held):
            decision.holdScratchHistoryFork(held, now: now)
        case .conversationHistoryClaudeForkReserved(let operationID, let publication, let incarnation):
            try decision.recordClaudeHistoryForkPublication(operationID: operationID, publication: publication, incarnation: incarnation, now: now)
        case .conversationHistoryReconciled(let operationID, _, let result):
            try decision.reconcileConversationHistory(operationID: operationID, result: result, now: now)
        case .client(.recallConversationHistoryPrompt(let operationID)):
            try decision.recallConversationHistoryPrompt(operationID: operationID, now: now)
        default: throw WorkspaceCommandError("This workspace command was routed incorrectly.")
        }
        return decision
    }

    @inline(never)
    private static func reduceConversationHistoryFiles(_ command: EngineCommand, id: UUID, snapshot: WorkspaceSnapshot, now: Date) throws -> Self {
        var decision = Self(snapshot: snapshot)
        if case .client(let action) = command { try decision.prepareClientCommand(action, commandID: id, now: now) }
        switch command {
        case .conversationHistoryFilesDispatching(let threadID, let operationID, let incarnation):
            try decision.dispatchConversationHistoryFiles(threadID: threadID, operationID: operationID, incarnation: incarnation, now: now)
        case .conversationHistoryFilesEffectResult(let request, let result, let incarnation):
            decision.finishConversationHistoryFiles(request, result: result, incarnation: incarnation, now: now)
        case .conversationHistoryFilesInspected(let operationID, _, let result):
            try decision.inspectConversationHistoryFiles(operationID: operationID, result: result, now: now)
        case .client(.acknowledgeConversationHistoryFiles(let operationID)):
            try decision.acknowledgeConversationHistoryFiles(operationID: operationID, now: now)
        case .client(.dismissConversationHistoryRecall(let operationID)):
            try decision.dismissConversationHistoryRecall(operationID: operationID, now: now)
        default: throw WorkspaceCommandError("This workspace command was routed incorrectly.")
        }
        return decision
    }

    @inline(never)
    private static func reduceCheckpointRestore(_ command: EngineCommand, id: UUID, snapshot: WorkspaceSnapshot, now: Date) throws -> Self {
        var decision = Self(snapshot: snapshot)
        if case .client(let action) = command { try decision.prepareClientCommand(action, commandID: id, now: now) }
        switch command {
        case .checkpointRestoreAccepted(let review):
            try decision.acceptCheckpointRestore(review, now: now)
        case .checkpointRestoreDispatching(let threadID, let operationID, let incarnation):
            try decision.dispatchCheckpointRestore(threadID: threadID, operationID: operationID, incarnation: incarnation, now: now)
        case .checkpointRestoreEffectResult(let request, let result, let incarnation):
            decision.finishCheckpointRestore(request, result: result, incarnation: incarnation, now: now)
        case .checkpointRestoreInspected(let operationID, let incarnation, let result):
            try decision.inspectCheckpointRestore(operationID: operationID, incarnation: incarnation, result: result, now: now)
        case .client(.acknowledgeCheckpointRestore(let operationID)):
            try decision.acknowledgeCheckpointRestore(operationID: operationID, now: now)
        default: throw WorkspaceCommandError("This workspace command was routed incorrectly.")
        }
        return decision
    }

    /// Checkout validation parses remote URLs. Keep those nested Foundation
    /// calls outside the broad mutation switch's unrelated value temporaries.
    @inline(never)
    private static func reducePullRequestCheckout(_ command: EngineCommand, id: UUID, snapshot: WorkspaceSnapshot, now: Date) throws -> Self {
        var decision = Self(snapshot: snapshot)
        if case .client(let action) = command { try decision.prepareClientCommand(action, commandID: id, now: now) }
        switch command {
        case .pullRequestCheckoutAccepted(let operation):
            try decision.acceptPullRequestCheckout(operation)
        case .pullRequestCheckoutDispatching(let project, let operation, let incarnation):
            try decision.dispatchPullRequestCheckout(projectID: project, operationID: operation, incarnation: incarnation, now: now)
        case .pullRequestCheckoutEffectResult(let request, let result, let incarnation):
            try decision.finishPullRequestCheckout(request, result: result, incarnation: incarnation, now: now)
        case .pullRequestCheckoutInspected(let operation, _, let result):
            try decision.inspectPullRequestCheckout(operationID: operation, result: result, now: now)
        case .pullRequestCheckoutCancel(let operation):
            try decision.cancelPullRequestCheckout(operationID: operation, now: now)
            decision.cancelPullRequestCheckoutOperation = operation
        case .client(.acknowledgePullRequestCheckout(let operation)):
            try decision.acknowledgePullRequestCheckout(operationID: operation, now: now)
        default: throw WorkspaceCommandError("This workspace command was routed incorrectly.")
        }
        return decision
    }

    @inline(never)
    private static func reduceProjectRegistration(_ command: EngineCommand, id: UUID, snapshot: WorkspaceSnapshot, now: Date) throws -> Self {
        var decision = Self(snapshot: snapshot)
        if case .client(let action) = command { try decision.prepareClientCommand(action, commandID: id, now: now) }
        switch command {
        case .client(.addProjectWithThread(let project, let thread)):
            guard project.clone == nil, thread.projectID == project.id, thread.workspacePath == project.path,
                  !decision.snapshot.projects.contains(where: { $0.id == project.id || $0.path == project.path }) else {
                throw WorkspaceCommandError("This project is already open, or its first conversation uses another workspace.")
            }
            decision.snapshot.projects.append(project)
            try decision.prepareClientCommand(.createThread(thread), commandID: id, now: now)
            try decision.insertNewThread(thread)
            decision.snapshot.reconcileGroupingPreferences()
            try WorkspaceJournal.validate(decision.snapshot)
        case .client(.startProjectClone(var project, let thread)):
            guard let submitted = project.clone else { throw WorkspaceCommandError("Choose a repository to clone.") }
            do { try submitted.plan.validate() } catch { throw WorkspaceCommandError(error.localizedDescription) }
            guard submitted.plan.destinationPath == project.path, thread.projectID == project.id, thread.workspacePath == project.path,
                  !decision.snapshot.projects.contains(where: { $0.id == project.id || $0.path == project.path }),
                  !decision.snapshot.cloneAttemptIDs.contains(submitted.plan.id) else { throw WorkspaceCommandError("This project or clone destination is already in use.") }
            project.clone = .init(plan: submitted.plan, now: now)
            decision.snapshot.projects.append(project)
            try decision.prepareClientCommand(.createThread(thread), commandID: id, now: now)
            try decision.insertNewThread(thread)
            decision.snapshot.reconcileGroupingPreferences()
            try WorkspaceJournal.validate(decision.snapshot)
            decision.effects.append(.init(id: submitted.plan.id, request: .projectClone(projectID: project.id, plan: submitted.plan)))
        default: throw WorkspaceCommandError("This workspace command was routed incorrectly.")
        }
        return decision
    }

    @inline(never)
    private static func reduceScratchThreadCreation(_ creation: ScratchThreadCreation, id: UUID, snapshot: WorkspaceSnapshot, now: Date) throws -> Self {
        try creation.validate()
        let allocation = creation.allocation, thread = creation.thread
        guard allocation.receipt.commandID == id else { throw ScratchWorkspaceError() }
        var decision = Self(snapshot: snapshot)
        if let project = snapshot.projects.first(where: { $0.id == allocation.project.id }) {
            guard project.scratch == allocation.project.scratch, project.path.utf8.elementsEqual(allocation.project.path.utf8) else { throw ScratchWorkspaceError() }
        } else {
            guard !snapshot.projects.contains(where: { $0.scratch != nil || $0.path.utf8.elementsEqual(allocation.project.path.utf8) }) else { throw ScratchWorkspaceError() }
            try decision.prepareClientCommand(.addProject(allocation.project), commandID: id, now: now, allowScratch: true)
            decision.snapshot.projects.append(allocation.project)
        }
        try decision.prepareClientCommand(.createThread(thread), commandID: id, now: now, allowScratch: true)
        try decision.insertNewThread(thread, allowScratch: true)
        for edit in creation.modelEdits {
            let next = try make(.client(.editThread(thread.id, edit)), id: id, snapshot: decision.snapshot, now: now, validatingLedger: false)
            decision.snapshot = next.snapshot; decision.effects += next.effects; decision.closeRuntimes.formUnion(next.closeRuntimes)
        }
        if creation.selectsConversation {
            var preferences = decision.snapshot.effectiveSidebarPreferences
            preferences.selectedThreadID = thread.id; decision.snapshot.sidebarPreferences = preferences
        }
        guard let prompt = creation.prompt else { return decision }
        let action = WorkspaceCommand.submitFromAppMCP(threadID: thread.id, text: prompt, queueEvenWhenIdle: false)
        var submitted = try reduceSubmission(.client(action), id: id, snapshot: decision.snapshot, now: now)
        submitted.closeRuntimes.formUnion(decision.closeRuntimes)
        submitted.reconcileWorkspaceLifecycle(previous: snapshot, command: action, now: now)
        return submitted
    }

    /// Submitting input must not retain the broad mutation switch's unrelated
    /// captured values while checking readiness and starting a native run.
    @inline(never)
    private static func reduceTranscriptPlanImplementation(_ request: TranscriptPlanImplementation, id: UUID, snapshot: WorkspaceSnapshot, now: Date) throws -> Self {
        let action = try request.command(in: snapshot)
        var admission = Self(snapshot: snapshot)
        // Source locks are checked even when the actual input goes to a new
        // conversation; no second command receipt or history fork is created.
        try admission.prepareClientCommand(.submit(threadID: request.threadID, text: ""), commandID: id, now: now)
        if let destination = try request.destinationThread(in: snapshot, now: now) {
            let scratch = request.scratchAllocation
            guard scratch == nil || scratch?.receipt.commandID == id else { throw ScratchWorkspaceError() }
            try admission.prepareClientCommand(.createThread(destination), commandID: id, now: now, allowScratch: scratch != nil)
            try admission.insertNewThread(destination, allowScratch: scratch != nil)
        } else if let index = admission.snapshot.threads.firstIndex(where: { $0.id == request.threadID }),
                  admission.snapshot.threads[index].provider == .codex,
                  admission.snapshot.threads[index].agentModeID == CodexInteractionMode.plan.rawValue {
            // Native collaboration mode is sticky. Persist explicit Default in
            // the same decision as its first implementation input.
            admission.snapshot.threads[index].agentModeID = CodexInteractionMode.default.rawValue
        }
        var decision = try reduceSubmission(.client(action), id: id, snapshot: admission.snapshot, now: now)
        decision.closeRuntimes.formUnion(admission.closeRuntimes)
        decision.reconcileWorkspaceLifecycle(previous: snapshot, command: action, now: now)
        return decision
    }

    @inline(never)
    private static func reduceSubmission(_ command: EngineCommand, id: UUID, snapshot: WorkspaceSnapshot, now: Date) throws -> Self {
        var decision = Self(snapshot: snapshot)
        guard case .client(let action) = command else { throw WorkspaceCommandError("This workspace command was routed incorrectly.") }
        try decision.prepareClientCommand(action, commandID: id, now: now)
        if let threadID = action.threadID { try decision.prepareImportedConversationCopy(threadID: threadID, commandID: id, now: now) }
            guard let threadID = action.threadID, let index = decision.snapshot.threads.firstIndex(where: { $0.id == threadID }) else { throw WorkspaceCommandError("This conversation no longer exists.") }
            var thread = decision.snapshot.threads[index]
        switch action {
            case .submit(_, let text), .submitFromAppMCP(_, let text, _), .submitCapturedClaude(_, let text, _):
                guard thread.draftWorkspaceIntent == nil else { throw WorkspaceCommandError("Prepare the captured worktree or explicitly choose this checkout before sending.") }
                let independent: Bool
                let queueEvenWhenIdle: Bool
                if case .submitFromAppMCP(_, _, let queue) = action { independent = true; queueEvenWhenIdle = queue }
                else { independent = false; queueEvenWhenIdle = false }
                if case .submitCapturedClaude(_, _, let configuration) = action {
                    try configuration.validate()
                    guard thread.provider == .claude, configuration.registeredWorkspacePath == thread.workspacePath,
                          thread.claudeRuntimeConfiguration == nil || thread.claudeRuntimeConfiguration == configuration else { throw ClaudeRuntimeConfiguration.invalid() }
                    thread.claudeRuntimeConfiguration = configuration
                }
                guard thread.claudeResumeConsumerRunID == nil || thread.isBusy else {
                    throw WorkspaceCommandError("Inspect the previous Claude resume attempt before sending another message.")
                }
                let text = independent ? text : text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (!independent && !thread.draftAttachments.isEmpty)), !thread.isArchived else { throw WorkspaceCommandError("Enter a message or attach a file in an active conversation.") }
                guard text.utf16.count <= 120_000 else { throw WorkspaceCommandError("Messages can contain up to 120,000 characters. Shorten the draft or attach it as a file.") }
                var queued = QueuedTurn(id: id, text: text, configuration: .init(thread: thread), createdAt: now,
                                        attachments: independent || thread.draftAttachments.isEmpty ? nil : thread.draftAttachments, checkpointPolicy: thread.effectiveCheckpointPolicy,
                                        preservesTitle: (independent || thread.transcriptPlanSource != nil) && thread.title != "New thread" ? true : nil)
                try decision.captureContextTransfers(for: &queued, thread: thread, now: now)
                if !independent { thread.draft = ""; thread.draftAttachments = [] }
                if thread.settlement != nil {
                    thread.queuedTurns.append(queued); thread.requestSettlementResume(now: now)
                }
                else if queueEvenWhenIdle || (independent && !thread.queuedTurns.isEmpty) || thread.isBusy || decision.snapshot.isPromptSteeringHoldingQueue(threadID: thread.id) || !decision.snapshot.providerReady(for: thread) {
                    if !queueEvenWhenIdle, thread.queuedTurns.isEmpty, !thread.isBusy, !decision.snapshot.isPromptSteeringHoldingQueue(threadID: thread.id), thread.workspacePreparation?.cancelRequested != true, thread.workspacePreparation?.phase != .cancelled, thread.workspacePreparation?.phase != .interrupted,
                       ![.interrupted, .cancelled, .stopping].contains(thread.workspacePreparation?.setup?.phase) { thread.queuePaused = false }
                    if queueEvenWhenIdle && !thread.isBusy { thread.queuePaused = true }
                    thread.queuedTurns.append(queued)
                }
                else {
                    if thread.queuedTurns.isEmpty { thread.queuePaused = false }
                    decision.start(queued, in: &thread, now: now)
                }
            default: throw WorkspaceCommandError("This workspace command was routed incorrectly.")
        }
            if thread != decision.snapshot.threads[index] {
                if case .editThread(_, .draft) = action {} else { thread.updatedAt = now }
            }
            decision.snapshot.threads[index] = thread
        return decision
    }

    @inline(never)
    private static func makeGeneral(_ command: EngineCommand, id: UUID, snapshot: WorkspaceSnapshot, now: Date) throws -> GeneralReduction {
        var decision = Self(snapshot: snapshot)
        // Unoptimized builds reserve the broad mutation switch's temporaries on
        // entry (~230 KB). Send the frequent per-conversation actions, provider
        // events and effect results straight to their reducers instead.
        switch command {
        case .client(let action):
            try decision.prepareClientCommand(action, commandID: id, now: now)
            if action.isThreadClientAction {
                try mutateThreadClient(action, decision: &decision, id: id, now: now)
                return .init(decision: decision, requiresFinalization: true)
            }
        case .provider(let threadID, let runtimeID, let event):
            return try reduceProvider(event, threadID: threadID, runtimeID: runtimeID, snapshot: snapshot, now: now)
        case .effectResult(let request, let result), .projectScriptEffectResult(let request, let result, _), .runCheckpointEffectResult(let request, let result, _):
            decision.finished(request, result: result, now: now)
            return .init(decision: decision, requiresFinalization: true)
        default: break
        }
        return try mutateGeneral(command, id: id, prepared: decision, snapshot: snapshot, now: now)
    }

    /// Admission runs before the broad mutation switch allocates its captured
    /// value temporaries. Preserve the original snapshot for cases that need it.
    @inline(never)
    private static func mutateGeneral(_ command: EngineCommand, id: UUID, prepared: Self, snapshot: WorkspaceSnapshot, now: Date) throws -> GeneralReduction {
        var decision = prepared
        switch command {
        case .transcriptPlanImplementation: throw WorkspaceCommandError("This plan action was routed incorrectly.")
        case .scratchThreadAccepted: throw WorkspaceCommandError("This scratch allocation was routed incorrectly.")
        case .agentSessionImportAccepted: throw AgentSessionImportError.invalidRequest
        case .client(.workspaceLifecycle), .client(.setWorkspaceLifecyclePolicy):
            return .init(decision: try make(command, id: id, snapshot: snapshot, now: now), requiresFinalization: false)
        case .delegatedTaskAccepted, .delegatedTaskCancel, .delegatedTaskDrained, .delegatedTaskObserved, .delegatedTaskWakePolicy, .delegatedTaskCompletionPrepared, .delegatedTaskCompletionCoalesced:
            throw DelegatedTaskError.invalidRequest
        case .contextTransferAccepted, .contextTransferDispatching, .contextTransferNativeReserved, .contextTransferNativeReady, .contextTransferRuntimeRebound, .contextTransferDeferred, .contextTransferSelectionPrepared, .contextTransferDelivered, .contextTransferUncertain, .client(.abandonContextTransfer):
            return .init(decision: try make(command, id: id, snapshot: snapshot, now: now), requiresFinalization: false)
        case .conversationHistoryAccepted, .conversationHistoryDispatching, .conversationHistoryEffectResult, .conversationHistoryScratchForkHeld, .conversationHistoryClaudeForkReserved,
             .conversationHistoryReconciled, .client(.recallConversationHistoryPrompt),
             .conversationHistoryFilesDispatching, .conversationHistoryFilesEffectResult, .conversationHistoryFilesInspected,
             .client(.acknowledgeConversationHistoryFiles), .client(.dismissConversationHistoryRecall),
             .checkpointRestoreAccepted, .checkpointRestoreDispatching, .checkpointRestoreEffectResult,
             .checkpointRestoreInspected, .client(.acknowledgeCheckpointRestore),
             .pullRequestCheckoutAccepted, .pullRequestCheckoutDispatching, .pullRequestCheckoutEffectResult,
             .pullRequestCheckoutInspected, .pullRequestCheckoutCancel, .client(.acknowledgePullRequestCheckout),
             .pullRequestActionAccepted, .pullRequestActionDispatching, .pullRequestActionEffectResult,
             .pullRequestActionInspected, .pullRequestActionAcknowledged,
             .client(.addProjectWithThread), .client(.startProjectClone),
             .client(.submit), .client(.submitFromAppMCP), .client(.submitCapturedClaude), .appMCP, .appMCPTargetGuard, .appMCPRequestGuard, .remoteEnvironment,
             .codexAuthenticationPreparing, .codexAccountConfigured,
             .projectScriptStarted, .projectScriptExited, .projectScriptStopped:
            return .init(decision: try make(command, id: id, snapshot: snapshot, now: now), requiresFinalization: false)
        case .queuedInputReplaced, .remoteThreadUndo: break
        case .promptSteeringAccepted(let operation): try decision.acceptPromptSteering(operation)
        case .promptSteeringDispatching(let operation, let incarnation): try decision.dispatchPromptSteering(operationID: operation, incarnation: incarnation, now: now)
        case .promptSteeringEffectResult(let request, let result, let incarnation): try decision.finishPromptSteering(request, result: result, incarnation: incarnation, now: now)
        case .client(.acknowledgePromptSteering(let operation)): try decision.acknowledgePromptSteering(operationID: operation, now: now)
        case .pullRequestCreationAccepted(let operation):
            try decision.acceptPullRequestCreation(operation)
        case .pullRequestCreationDispatching(let projectID, let operationID, let incarnation):
            try decision.dispatchPullRequestCreation(projectID: projectID, operationID: operationID, incarnation: incarnation, now: now)
        case .pullRequestCreationEffectResult(let request, let result, let incarnation):
            decision.finishPullRequestCreation(request, result: result, incarnation: incarnation, now: now)
        case .pullRequestCreationReconciled(let operationID, _, let result):
            try decision.reconcilePullRequestCreation(operationID: operationID, result: result, now: now)
        case .client(.acknowledgePullRequestCreation(let operationID)):
            try decision.acknowledgePullRequestCreation(operationID: operationID, now: now)
        case .client(.retryPostRunCheckpoint(let threadID, let runID, let expected)):
            try decision.changePostRunCheckpoint(threadID: threadID, runID: runID, expectedAttemptID: expected, retry: true, now: now)
        case .client(.continueAfterPostRunCheckpoint(let threadID, let runID, let expected)):
            try decision.changePostRunCheckpoint(threadID: threadID, runID: runID, expectedAttemptID: expected, retry: false, now: now)
        case .runCheckpointRecovered(let threadID, let runID, let stage, let attemptID, let path, _, let receipt):
            if let i = decision.snapshot.threads.firstIndex(where: { $0.id == threadID && $0.workspacePath == path }),
               let attempt = decision.snapshot.threads[i].runCheckpoint(runID: runID, stage: stage), attempt.id == attemptID,
               attempt.phase == .interrupted, attempt.plan == receipt.plan {
                decision.snapshot.threads[i].updateCheckpoint(runID: runID, stage: stage) { $0.receipt = receipt; $0.phase = .ready; $0.error = nil; $0.cleanupWarning = ThreadRunCheckpointAttempt.cleanupWarningMessage; $0.updatedAt = now }
                // Restart already held restored work. Inspection must not override a
                // newer explicit submit/resume intent, and never starts work itself.
            }
        case .defaultWorktreeSubmission, .retryDefaultWorktree:
            throw WorkspaceCommandError("This worktree input was routed incorrectly.")
        case .beginWorktreePreparation:
            return .init(decision: try reduceWorktreePreparation(command, snapshot: snapshot, now: now), requiresFinalization: true)
        case .claudeResumeInspected(let threadID, _, let selection, let run, let result):
            guard let i = decision.snapshot.threads.firstIndex(where: { $0.id == threadID }),
                  !decision.snapshot.threads[i].isBusy,
                  decision.snapshot.threads[i].claudeResumeSelection == selection,
                  decision.snapshot.threads[i].claudeResumeConsumerRunID == run.id,
                  decision.snapshot.threads[i].runHistory?.first(where: { $0.id == run.id }) == run,
                  decision.snapshot.threads[i].claudeRuntimeConfiguration == run.configuration.claudeRuntimeConfiguration else {
                throw WorkspaceCommandError("The Claude resume attempt changed. Inspect it again.")
            }
            decision.snapshot.threads[i].claudeResumeConsumerRunID = nil
            if result == .consumed { decision.snapshot.threads[i].claudeResumeSelection = nil }
            decision.snapshot.threads[i].queuePaused = true
            decision.snapshot.threads[i].updatedAt = now
        case .client(.settleThread(let threadID, let expectedPath, let review)):
            guard let i = decision.snapshot.threads.firstIndex(where: { $0.id == threadID }),
                  decision.snapshot.threads[i].workspacePath == expectedPath, !decision.snapshot.threads[i].isArchived else {
                throw WorkspaceCommandError("This conversation changed. Settle it in its current workspace.")
            }
            if decision.snapshot.threads[i].settlement != nil { return .init(decision: decision, requiresFinalization: false) }
            guard decision.snapshot.canSettle(threadID: threadID) else {
                throw WorkspaceCommandError("Finish or stop the current turn, clear queued messages and questions, and finish workspace setup before settling.")
            }
            var thread = decision.snapshot.threads[i]
            var settlement = ThreadSettlement(id: id, settledAt: now, reviewScript: review)
            if var script = settlement.script {
                if !decision.snapshot.permitsSettleScript(for: thread) { script.phase = .skipped; script.endedAt = now }
                else { decision.effects.append(.init(request: .resolveThreadScript(threadID: threadID, owner: .settlement(generationID: settlement.id), runID: script.id))) }
                settlement.script = script
            }
            thread.settlement = settlement; thread.queuePaused = true; thread.updatedAt = now
            thread.runtimeID = nil; thread.runtimeRequests = []; thread.providerActivity = nil
            decision.snapshot.threads[i] = thread; decision.closeRuntimes.insert(threadID)
        case .client(.resumeThread(let threadID, let generationID)):
            guard let i = decision.snapshot.threads.firstIndex(where: { $0.id == threadID }),
                  decision.snapshot.threads[i].settlement?.id == generationID, !decision.snapshot.threads[i].isArchived else {
                throw WorkspaceCommandError("This settlement changed. Resume the current conversation.")
            }
            decision.snapshot.threads[i].requestSettlementResume(now: now)
        case .threadResumed(let threadID, let generationID, _):
            if let i = decision.snapshot.threads.firstIndex(where: { $0.id == threadID }),
               decision.snapshot.threads[i].settlement?.id == generationID,
               decision.snapshot.threads[i].settlement?.phase == .resuming {
                var thread = decision.snapshot.threads[i]; thread.settlement = nil
                if thread.isArchived { thread.queuePaused = true }
                decision.snapshot.threads[i] = thread; decision.startNext(in: &thread, now: now); decision.snapshot.threads[i] = thread
            }
        case .client(.approveProjectScript(let threadID, let runID, let expected)):
            guard let i = decision.snapshot.threads.firstIndex(where: { $0.id == threadID }),
                  let owner = decision.snapshot.threads[i].projectScriptOwner(runID: runID),
                  var run = decision.snapshot.threads[i].projectScript(owner: owner), run.canApprove, run.plan == expected,
                  expected.id == runID, decision.snapshot.permitsScriptAction(owner: owner, thread: decision.snapshot.threads[i]) else {
                throw WorkspaceCommandError("This project script changed. Review its current command before running.")
            }
            do { try expected.validate() } catch { throw WorkspaceCommandError("The project script plan is invalid. Review it again.") }
            run.phase = .starting; run.error = nil; run.updatedAt = now
            decision.snapshot.threads[i].setProjectScript(run, owner: owner)
            decision.effects.append(.init(request: owner.startRequest(threadID: threadID, plan: expected)))
        case .client(.stopProjectScript(let threadID, let runID)), .client(.skipProjectScript(let threadID, let runID)), .client(.retryProjectScript(let threadID, let runID)):
            guard let i = decision.snapshot.threads.firstIndex(where: { $0.id == threadID }),
                  let owner = decision.snapshot.threads[i].projectScriptOwner(runID: runID),
                  var run = decision.snapshot.threads[i].projectScript(owner: owner), run.phase != .stopping,
                  decision.snapshot.threads[i].settlement?.phase != .resuming else { throw WorkspaceCommandError("This script attempt changed. Refresh its status.") }
            let action: ProjectScriptStopAction
            switch command {
            case .client(.skipProjectScript):
                guard run.canSkip else { throw WorkspaceCommandError("This script attempt no longer needs to be skipped.") }; action = .skip
            case .client(.retryProjectScript):
                guard run.canRetry, decision.snapshot.workspaceReady(for: decision.snapshot.threads[i]), !decision.snapshot.threads[i].isBusy,
                      decision.snapshot.permitsScriptAction(owner: owner, thread: decision.snapshot.threads[i]) else { throw WorkspaceCommandError("Stop the current turn before reviewing the script again.") }; action = .retry
            default: action = .cancel
            }
            run.phase = .stopping; run.pendingAction = action; run.updatedAt = now
            if run.commandExit != .exited(0) { decision.snapshot.threads[i].queuePaused = true }
            decision.snapshot.threads[i].setProjectScript(run, owner: owner)
        case .threadScriptStarted(let threadID, let owner, let runID, _):
            if let i = decision.snapshot.threads.firstIndex(where: { $0.id == threadID }),
               var run = decision.snapshot.threads[i].projectScript(owner: owner), run.id == runID, run.phase == .starting {
                run.phase = .running; run.startedAt = now; run.updatedAt = now
                decision.snapshot.threads[i].setProjectScript(run, owner: owner)
                var thread = decision.snapshot.threads[i]; decision.startNext(in: &thread, now: now); decision.snapshot.threads[i] = thread
            }
        case .threadScriptExited(let threadID, let owner, let runID, _, let result):
            if let i = decision.snapshot.threads.firstIndex(where: { $0.id == threadID }),
               var run = decision.snapshot.threads[i].projectScript(owner: owner), run.id == runID, run.phase == .running {
                run.commandExit = result; run.phase = result == .exited(0) ? .succeeded : .failed
                run.error = result == .exited(0) ? nil : ThreadProjectScriptRun.executionError(for: owner.role); run.endedAt = now; run.updatedAt = now
                decision.snapshot.threads[i].setProjectScript(run, owner: owner)
                if owner.role == .setup, !run.providerReleased { decision.snapshot.threads[i].queuePaused = true }
                var thread = decision.snapshot.threads[i]; decision.startNext(in: &thread, now: now); decision.snapshot.threads[i] = thread
            }
        case .threadScriptStopped(let threadID, let owner, let runID, _):
            if let i = decision.snapshot.threads.firstIndex(where: { $0.id == threadID }),
               var run = decision.snapshot.threads[i].projectScript(owner: owner), run.id == runID, run.phase == .stopping, let action = run.pendingAction {
                run.pendingAction = nil; run.updatedAt = now; run.endedAt = now; run.error = nil
                switch action {
                case .cancel: run.phase = run.commandExit == .exited(0) ? .succeeded : .cancelled
                case .skip: run.phase = .skipped; if owner.role == .setup { decision.snapshot.threads[i].queuePaused = false }
                case .retry:
                    let previous = run.previousPlans + (run.plan.map { [$0] } ?? [])
                    run = .init(now: now); run.phase = .discovering; run.previousPlans = previous
                    if owner.role == .setup { decision.snapshot.threads[i].queuePaused = false }
                    decision.effects.append(.init(request: owner.resolveRequest(threadID: threadID, runID: run.id)))
                }
                decision.snapshot.threads[i].setProjectScript(run, owner: owner)
                var thread = decision.snapshot.threads[i]; decision.startNext(in: &thread, now: now); decision.snapshot.threads[i] = thread
            }
        case .worktreeRecovered:
            throw WorkspaceCommandError("This worktree recovery was routed incorrectly.")
        case .worktreeStarted(let threadID, let attemptID):
            if let i = decision.snapshot.threads.firstIndex(where: { $0.id == threadID }), var state = decision.snapshot.threads[i].workspacePreparation,
               state.id == attemptID, state.phase == .queued, !state.cancelRequested {
                state.phase = .resolving; state.updatedAt = now; decision.snapshot.threads[i].workspacePreparation = state
            }
        case .client(.cancelWorktreePreparation(let threadID)):
            guard let i = decision.snapshot.threads.firstIndex(where: { $0.id == threadID }), var state = decision.snapshot.threads[i].workspacePreparation else { throw WorkspaceCommandError("This conversation has no workspace preparation to cancel.") }
            if state.isRunning, !state.cancelRequested {
                state.cancelRequested = true; state.updatedAt = now; decision.snapshot.threads[i].workspacePreparation = state
                decision.snapshot.threads[i].queuePaused = true; decision.cancelWorktreeAttempt = state.id
            }
        case .client(.renameProjectGroup(let key, let expected, let requested)):
            let group = try decision.validatedGroup(key, expectedProjects: expected)
            let title: String
            do { title = try ManagedProjectService.validatedName(requested) }
            catch { throw WorkspaceCommandError(error.localizedDescription) }
            let ids = Set(group.memberProjectIDs)
            for i in decision.snapshot.projects.indices where ids.contains(decision.snapshot.projects[i].id) && decision.snapshot.projects[i].name != title {
                decision.snapshot.projects[i].name = title; decision.snapshot.projects[i].updatedAt = now
            }
        case .client(.removeProjectGroup(let key, let expected, let expectedThreads)):
            let group = try decision.validatedGroup(key, expectedProjects: expected)
            let ids = Set(group.memberProjectIDs)
            let threads = Set(decision.snapshot.threads.filter { ids.contains($0.projectID) }.map(\.id))
            guard Set(expectedThreads).count == expectedThreads.count, Set(expectedThreads) == threads else {
                throw WorkspaceCommandError("This project's conversations changed. Review all current active and archived conversations before removing the group.")
            }
            decision.snapshot.projects.removeAll { ids.contains($0.id) }
            decision.snapshot.threads.removeAll { ids.contains($0.projectID) }
            decision.closeRuntimes.formUnion(threads)
        case .client(.selectConversation(let threadID)):
            guard threadID.map({ id in decision.snapshot.threads.contains { $0.id == id } }) ?? true else { throw WorkspaceCommandError("This conversation is no longer available.") }
            var preferences = decision.snapshot.effectiveSidebarPreferences
            if preferences.selectedThreadID != threadID { preferences.selectedThreadID = threadID; decision.snapshot.sidebarPreferences = preferences }
        case .client(.setProjectGroupingMode(let mode)):
            var preferences = decision.snapshot.effectiveSidebarPreferences
            if preferences.groupingMode != mode { preferences.groupingMode = mode; decision.snapshot.sidebarPreferences = preferences }
        case .client(.setProjectGroupingOverride(let projectID, let mode)):
            guard let key = decision.snapshot.physicalProjectKey(for: projectID) else { throw WorkspaceCommandError("This checkout is no longer available.") }
            var preferences = decision.snapshot.effectiveSidebarPreferences
            if preferences.groupingOverrides[key] != mode { preferences.groupingOverrides[key] = mode; decision.snapshot.sidebarPreferences = preferences }
        case .client(.setProjectGroupExpanded(let key, let expected, let expanded)):
            let group = try decision.validatedGroup(key, expected: expected)
            var preferences = decision.snapshot.effectiveSidebarPreferences
            preferences.groupExpandedByKey[key] = expanded
            let ids = Set(group.memberProjectIDs)
            preferences.collapsedProjectIDs.removeAll { ids.contains($0) }
            if !expanded { preferences.collapsedProjectIDs += group.memberProjectIDs }
            preferences.collapsedProjectIDs.sort { $0.uuidString < $1.uuidString }
            decision.snapshot.sidebarPreferences = preferences
        case .client(.setProjectGroupCheckout(let key, let expected, let projectID)):
            let group = try decision.validatedGroup(key, expected: expected)
            guard group.memberProjectIDs.contains(projectID), let project = decision.snapshot.projects.first(where: { $0.id == projectID }),
                  project.clone == nil || project.clone?.isReady == true else { throw WorkspaceCommandError("Choose an available checkout whose clone has finished.") }
            var preferences = decision.snapshot.effectiveSidebarPreferences; preferences.activeProjectByGroup[key] = projectID
            decision.snapshot.sidebarPreferences = preferences
        case .repositoryIdentityResolved(let projectID, let path, _, _, let identity):
            if let i = decision.snapshot.projects.firstIndex(where: { $0.id == projectID && $0.path == path && ($0.clone == nil || $0.clone?.isReady == true) }) {
                try WorkspaceJournal.validateRepositoryIdentity(identity, project: decision.snapshot.projects[i])
                decision.snapshot.projects[i].repositoryIdentity = identity
            }
        case .client(.removeProject(let projectID, let expectedThreadIDs)):
            guard decision.snapshot.projects.contains(where: { $0.id == projectID }) else { throw WorkspaceCommandError("This project is no longer available.") }
            let threadIDs = Set(decision.snapshot.threads.filter { $0.projectID == projectID }.map(\.id))
            guard Set(expectedThreadIDs).count == expectedThreadIDs.count, Set(expectedThreadIDs) == threadIDs else {
                throw WorkspaceCommandError("This project's conversations changed. Review the current active and archived conversations before removing it.")
            }
            decision.snapshot.projects.removeAll { $0.id == projectID }
            decision.snapshot.threads.removeAll { $0.projectID == projectID }
            if var preferences = decision.snapshot.sidebarPreferences {
                preferences.collapsedProjectIDs.removeAll { $0 == projectID }; decision.snapshot.sidebarPreferences = preferences
            }
            decision.closeRuntimes.formUnion(threadIDs)
        case .client(.renameProject(let projectID, let requested)):
            let title: String
            do { title = try ManagedProjectService.validatedName(requested) }
            catch { throw WorkspaceCommandError(error.localizedDescription) }
            guard let index = decision.snapshot.projects.firstIndex(where: { $0.id == projectID }) else { throw WorkspaceCommandError("This project is no longer available.") }
            if decision.snapshot.projects[index].name != title {
                decision.snapshot.projects[index].name = title
                decision.snapshot.projects[index].updatedAt = now
            }
        case .client(.setProjectExpanded(let projectID, let expanded)):
            guard decision.snapshot.projects.contains(where: { $0.id == projectID }) else { throw WorkspaceCommandError("This project is no longer available.") }
            var preferences = decision.snapshot.effectiveSidebarPreferences
            if decision.snapshot.isProjectExpanded(projectID) != expanded {
                preferences.collapsedProjectIDs.removeAll { $0 == projectID }
                if !expanded { preferences.collapsedProjectIDs.append(projectID) }
                preferences.collapsedProjectIDs.sort { $0.uuidString < $1.uuidString }
                decision.snapshot.sidebarPreferences = preferences
            }
        case .client(.setProjectSortMode(let mode)):
            var preferences = decision.snapshot.effectiveSidebarPreferences
            if preferences.sortMode != mode {
                preferences.sortMode = mode; decision.snapshot.sidebarPreferences = preferences
            }
        case .client(.setProjectPinned(let id, let pinned)):
            guard decision.snapshot.projects.contains(where: { $0.id == id }) else { throw WorkspaceCommandError("This project is no longer available.") }
            var preferences = decision.snapshot.effectiveSidebarPreferences
            preferences.pinnedProjectIDs.removeAll { $0 == id }
            if pinned { preferences.pinnedProjectIDs.append(id) }
            decision.snapshot.sidebarPreferences = preferences
        case .client(.setThreadSortMode(let mode)):
            var preferences = decision.snapshot.effectiveSidebarPreferences
            if mode == .manual, preferences.threadOrder.isEmpty {
                preferences.threadOrder = decision.snapshot.orderedThreads.map(\.id)
            }
            preferences.threadSortMode = mode
            decision.snapshot.sidebarPreferences = preferences
        case .client(.reorderThreads(let order, let expected)):
            guard decision.snapshot.effectiveSidebarPreferences.threadSortMode == .manual else { throw WorkspaceCommandError("Choose Custom sorting before moving chats.") }
            guard decision.snapshot.customThreadOrder == expected,
                  order.count == expected.count, Set(order) == Set(expected) else { throw WorkspaceCommandError("The chat order changed. Try moving the chat again.") }
            var preferences = decision.snapshot.effectiveSidebarPreferences
            preferences.threadOrder = order
            decision.snapshot.sidebarPreferences = preferences
        case .client(.moveProject(let projectID, let before, let expected)):
            try decision.validateProjectOrder(expected)
            guard expected.contains(projectID), before.map({ expected.contains($0) }) ?? true else { throw WorkspaceCommandError("The project being moved is no longer available.") }
            if before != projectID {
                var order = expected.filter { $0 != projectID }
                let index = before.flatMap { order.firstIndex(of: $0) } ?? order.endIndex
                order.insert(projectID, at: index)
                decision.reorderProjects(order)
            }
        case .client(.reorderProjects(let order, let expected)):
            try decision.validateProjectOrder(expected)
            guard order.count == expected.count, Set(order) == Set(expected) else { throw WorkspaceCommandError("Move only the projects currently shown in Manual order.") }
            decision.reorderProjects(order)
        case .client(.reorderProjectGroups(let order, let expected, let expectedGroups)):
            try decision.validateProjectOrder(expected)
            let groups = decision.snapshot.projectGroups
            guard Set(expectedGroups.keys) == Set(groups.map(\.key)), groups.allSatisfy({ group in
                guard let ids = expectedGroups[group.key] else { return false }
                return Set(ids).count == ids.count && Set(ids) == Set(group.memberProjectIDs)
            }) else { throw WorkspaceCommandError("The project groups changed. Review the current groups and try moving again.") }
            guard order.count == expected.count, Set(order) == Set(expected) else { throw WorkspaceCommandError("Move only the projects currently shown in Manual order.") }
            decision.reorderProjects(order)
        case .client(.cancelProjectClone(let projectID)):
            guard let i = decision.snapshot.projects.firstIndex(where: { $0.id == projectID }), var clone = decision.snapshot.projects[i].clone else { throw WorkspaceCommandError("This project has no clone to cancel.") }
            if clone.isRunning, !clone.cancelRequested {
                clone.cancelRequested = true; clone.updatedAt = now; decision.snapshot.projects[i].clone = clone
                decision.cancelCloneAttempt = clone.id
                for j in decision.snapshot.threads.indices where decision.snapshot.threads[j].projectID == projectID { decision.snapshot.threads[j].queuePaused = true }
            }
        case .client(.retryProjectClone(let projectID, let plan)):
            do { try plan.validate() } catch { throw WorkspaceCommandError(error.localizedDescription) }
            guard let i = decision.snapshot.projects.firstIndex(where: { $0.id == projectID }), let old = decision.snapshot.projects[i].clone,
                  old.canRetry, old.plan.source == plan.source, old.plan.destinationPath == plan.destinationPath,
                  !decision.snapshot.cloneAttemptIDs.contains(plan.id) else { throw WorkspaceCommandError("This clone cannot be retried now. Refresh its status first.") }
            decision.snapshot.projects[i].clone = .init(plan: plan, now: now, previousPlans: old.previousPlans + [old.plan])
            decision.effects.append(.init(id: plan.id, request: .projectClone(projectID: projectID, plan: plan)))
        case .client(.addProject(let project)):
            guard project.clone == nil else { throw WorkspaceCommandError("Use Clone Repository to create a cloning project.") }
            if decision.snapshot.projects.contains(where: { $0.path == project.path }) { return .init(decision: decision, requiresFinalization: false) }
            guard !decision.snapshot.projects.contains(where: { $0.id == project.id }) else { throw WorkspaceCommandError("This project identity is already in use.") }
            decision.snapshot.projects.append(project)
        case .client(.createThread(let thread)):
            try decision.insertNewThread(thread)
        case .client(let action):
            try mutateThreadClient(action, decision: &decision, id: id, now: now)
        case .runtimeOpened(let threadID, let runID, let runtimeID):
            if let i = decision.snapshot.threads.firstIndex(where: { $0.id == threadID }), decision.snapshot.threads[i].activeRun?.id == runID {
                decision.snapshot.threads[i].runtimeID = runtimeID
            }
        case .provider(let threadID, let runtimeID, let event):
            return try reduceProvider(event, threadID: threadID, runtimeID: runtimeID, snapshot: snapshot, now: now)
        case .effectResult(let request, let result), .projectScriptEffectResult(let request, let result, _), .runCheckpointEffectResult(let request, let result, _):
            decision.finished(request, result: result, now: now)
        case .pauseQueues:
            for i in (decision.snapshot.promptSteerings ?? []).indices where decision.snapshot.promptSteerings?[i].isWorking == true { decision.snapshot.promptSteerings?[i].fallbackAllowed = false }
            for i in decision.snapshot.threads.indices where !decision.snapshot.threads[i].queuedTurns.isEmpty { decision.snapshot.threads[i].queuePaused = true }
        case .cloneStarted(let projectID, let attemptID):
            if let i = decision.snapshot.projects.firstIndex(where: { $0.id == projectID }), var clone = decision.snapshot.projects[i].clone,
               clone.id == attemptID, clone.isRunning, !clone.cancelRequested {
                clone.phase = .running; clone.updatedAt = now; decision.snapshot.projects[i].clone = clone
            }
        case .cloneProgress(let projectID, let attemptID, var progress):
            if let i = decision.snapshot.projects.firstIndex(where: { $0.id == projectID }), var clone = decision.snapshot.projects[i].clone,
               clone.id == attemptID, clone.isRunning, !clone.cancelRequested {
                progress.percent = progress.percent.map { min(100, max(0, $0)) }
                progress.detail = progress.detail.map { String(GitService.redactURLs($0).prefix(500)) }
                clone.progress = progress; clone.updatedAt = now; decision.snapshot.projects[i].clone = clone
            }
        case .contextCompactionAccepted, .contextCompactionDispatching, .contextCompactionCancelled:
            // Routed before this switch; kept last so it adds no pattern cost.
            return .init(decision: try reduceContextCompaction(command, snapshot: snapshot, now: now), requiresFinalization: true)
        }
        return .init(decision: decision, requiresFinalization: true)
    }

    /// The per-conversation client switch gets its own frame: unoptimized builds
    /// reserve every case's temporaries on entry, which put ~300 KB on the stack
    /// of every command routed through the broad mutation switch.
    @inline(never)
    private static func mutateThreadClient(_ action: WorkspaceCommand, decision: inout Self, id: UUID, now: Date) throws {
        guard let threadID = action.threadID, let index = decision.snapshot.threads.firstIndex(where: { $0.id == threadID }) else { throw WorkspaceCommandError("This conversation no longer exists.") }
        var thread = decision.snapshot.threads[index]
        switch action {
        case .editThread(_, let edit):
            switch edit {
            case .draftProject(let assignment):
                try decision.assignDraftProject(assignment, thread: &thread)
            case .codexRuntimeConfiguration(let configuration):
                guard thread.provider == .codex, !thread.isBusy, thread.messages.isEmpty, thread.queuedTurns.isEmpty,
                      thread.providerThreadID == nil, thread.runtimeRequests.isEmpty else {
                    throw WorkspaceCommandError("Change the Codex runtime in a new, empty conversation.")
                }
                do { try configuration.validate() } catch { throw WorkspaceCommandError(CodexRuntimeConfiguration.invalid().localizedDescription) }
                decision.closeRuntimes.insert(thread.id); thread.codexRuntimeConfiguration = configuration
                thread.model = ""; thread.reasoningEffort = nil; thread.codexReasoningPreferences = nil; thread.codexModelSelectionSource = nil
                thread.providerMetadata = nil; thread.runtimeID = nil
            case .checkpointPolicy(let value): thread.checkpointPolicy = value
            case .codexModel(let model): try thread.selectCodexModel(model)
            case .codexReasoning(let model, let effort): try thread.selectCodexReasoning(model: model, effort: effort)
            case .codexDefaultModel(let selection): try thread.selectCodexDefaultModel(selection)
            case .title(let title):
                let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty else { throw WorkspaceCommandError("A conversation title cannot be empty.") }; thread.title = title
            case .model(let model):
                if thread.model != model { thread.reasoningEffort = nil; thread.codexModelSelectionSource = nil }
                thread.model = model
            case .permission(let mode): thread.permission = mode
            case .agentMode(let mode): thread.agentModeID = mode
            case .codexInteractionMode(let selection): try selection.apply(to: &thread)
            case .claudeRuntimeConfiguration(let configuration):
                try configuration.validate()
                guard thread.provider == .claude, thread.claudeRuntimeConfiguration == nil,
                      configuration.registeredWorkspacePath == thread.workspacePath else { throw ClaudeRuntimeConfiguration.invalid() }
                thread.claudeRuntimeConfiguration = configuration
            case .provider, .codexProvider, .claudeProvider:
                let kind: ProviderKind, codexConfiguration: CodexRuntimeConfiguration?, claudeConfiguration: ClaudeRuntimeConfiguration?
                if case .provider(let value) = edit { kind = value; codexConfiguration = nil; claudeConfiguration = nil }
                else if case .codexProvider(let value) = edit {
                    do { try value.validate() }
                    catch { throw WorkspaceCommandError(CodexRuntimeConfiguration.invalid().localizedDescription) }
                    kind = .codex; codexConfiguration = value; claudeConfiguration = nil
                } else if case .claudeProvider(let value) = edit {
                    try value.validate()
                    guard value.registeredWorkspacePath == thread.workspacePath else { throw ClaudeRuntimeConfiguration.invalid() }
                    kind = .claude; codexConfiguration = nil; claudeConfiguration = value
                } else { throw WorkspaceCommandError("The provider selection is invalid.") }
                guard !thread.isBusy, thread.messages.isEmpty, thread.queuedTurns.isEmpty else { throw WorkspaceCommandError("Start a new conversation to change providers.") }
                decision.closeRuntimes.insert(thread.id); thread.provider = kind; thread.agentModeID = nil; thread.agentConfigValues = nil; thread.agentConfiguration = nil; thread.providerMetadata = nil; thread.providerActivity = nil; thread.runtimeRequests = []; thread.model = ""; thread.reasoningEffort = nil; thread.codexModelSelectionSource = nil; thread.providerThreadID = nil; thread.runtimeID = nil
                thread.codexRuntimeConfiguration = codexConfiguration
                thread.claudeRuntimeConfiguration = claudeConfiguration; thread.claudeResumeSelection = nil
                thread.claudeResumeConsumerRunID = nil; thread.claudeInheritedHead = nil
            case .codexServiceTier(let model, let tier, let expected):
                try Self.validateModelControlCapture(expected, thread: thread)
                try thread.selectCodexServiceTier(model: model, tier: tier)
            case .claudeModel(let model): try thread.selectClaudeModel(model)
            case .claudeModelOptions(let model, let options, let expected):
                try Self.validateModelControlCapture(expected, thread: thread)
                try thread.selectClaudeModelOptions(options, model: model)
            case .resetProviderModelOptions(let expected):
                try Self.validateModelControlCapture(expected, thread: thread)
                let key: String
                switch thread.provider { case .codex: key = CodexServiceTier.configurationKey; case .claude: key = ClaudeModelControl.configurationKey }
                thread.agentConfiguration?.removeValue(forKey: key)
                if thread.agentConfiguration?.isEmpty == true { thread.agentConfiguration = nil }
            case .draft(let value): thread.draft = value
            case .pinned(let value): thread.isPinned = value
            case .archived(let value):
                guard !thread.isBusy else { throw WorkspaceCommandError("Stop the running turn before archiving this conversation.") }
                thread.isArchived = value
                if value {
                    for record in thread.runHistory ?? [] {
                        for stage in [RunCheckpointStage.baseline, .postRun] {
                            thread.updateCheckpoint(runID: record.id, stage: stage) { attempt in
                                if attempt.phase.isRunning { attempt.phase = .interrupted; attempt.error = ThreadRunCheckpointAttempt.interruptedMessage; attempt.updatedAt = now }
                            }
                        }
                    }
                    thread.queuePaused = true; decision.closeRuntimes.insert(thread.id); thread.runtimeID = nil; thread.runtimeRequests = []; thread.providerActivity = nil
                    if var preparation = thread.workspacePreparation, var setup = preparation.setup {
                        if setup.commandExit != .exited(0) { setup.phase = .cancelled }
                        else { setup.phase = .succeeded }
                        setup.pendingAction = nil; setup.error = nil; setup.updatedAt = now; setup.endedAt = now
                        preparation.setup = setup; thread.workspacePreparation = preparation
                    }
                    if var run = thread.settlement?.script {
                        run.phase = run.commandExit == .exited(0) ? .succeeded : .cancelled
                        run.pendingAction = nil; run.error = nil; run.updatedAt = now; run.endedAt = now
                        thread.settlement?.script = run
                    }
                }
            case .workspacePath, .claudeWorkspace:
                let path: String, captured: ClaudeRuntimeConfiguration?
                if case .workspacePath(let value) = edit { path = value; captured = nil }
                else if case .claudeWorkspace(let value) = edit { path = value.registeredWorkspacePath; captured = value }
                else { throw ClaudeRuntimeConfiguration.invalid() }
                guard thread.settlement == nil else { throw WorkspaceCommandError("Resume this conversation before changing its workspace.") }
                if thread.workspacePreparation != nil {
                    guard path == thread.workspacePath else { throw WorkspaceCommandError("Use Choose Worktree to change a prepared conversation's workspace.") }
                    break
                }
                guard !thread.isBusy, thread.messages.isEmpty, thread.queuedTurns.isEmpty else { throw WorkspaceCommandError("Change the workspace before sending the first message.") }
                guard decision.snapshot.workspaceReady(for: thread) else { throw WorkspaceCommandError("Wait for the clone before changing workspaces.") }
                if let previous = thread.claudeRuntimeConfiguration {
                    guard let captured, captured == (try previous.replacingWorkspace(path, physicalPath: captured.workspacePath)) else {
                        throw WorkspaceCommandError("Choose this Claude workspace through its captured runtime.")
                    }
                    thread.claudeRuntimeConfiguration = captured
                } else if captured != nil { throw ClaudeRuntimeConfiguration.invalid() }
                thread.claudeResumeSelection = nil; thread.claudeResumeConsumerRunID = nil; thread.claudeInheritedHead = nil
                thread.draftWorkspaceIntent = nil
                thread.workspacePath = path; if thread.codexModelSelectionSource == .cliDefault { thread.codexModelSelectionSource = .explicitModel }; thread.providerThreadID = nil; decision.closeRuntimes.insert(thread.id); thread.runtimeID = nil; thread.runtimeRequests = []; thread.providerActivity = nil; thread.providerMetadata = nil
            }
        case .useCurrentCheckout(_, let intentID):
            guard thread.draftWorkspaceIntent?.id == intentID, thread.draftWorkspaceIntent?.threadID == thread.id,
                  thread.draftWorkspaceIntent?.threadCreatedAt == thread.createdAt, thread.messages.isEmpty, thread.queuedTurns.isEmpty,
                  thread.workspacePreparation == nil, !thread.isBusy else { throw WorkspaceCommandError("This workspace choice changed. Reopen the draft before changing it.") }
            thread.draftWorkspaceIntent = nil
        case .submitDefaultWorktree, .submit, .submitFromAppMCP, .submitCapturedClaude:
            throw WorkspaceCommandError("This workspace command was routed incorrectly.")
        case .interrupt, .interruptFromAppMCP:
            if let operation = decision.snapshot.contextCompaction(threadID: thread.id), operation.isWorking {
                if case .interruptFromAppMCP = action {
                    throw WorkspaceCommandError("Stop context compaction using its exact operation identity.")
                }
                try decision.cancelContextCompaction(threadID: thread.id, operationID: operation.id, now: now)
                thread = decision.snapshot.threads[index]
                break
            }
            if case .interruptFromAppMCP(_, let runID, let runtimeID) = action {
                guard thread.activeRun?.id == runID, thread.runtimeID == runtimeID else { throw WorkspaceCommandError("The target turn changed before Stop was accepted.") }
            }
            thread.queuePaused = true
            if var run = thread.activeRun, !run.stopRequested {
                run.stopRequested = true; thread.activeRun = run
                thread.updateRunRecord()
                if thread.runHistory?.first(where: { $0.id == run.id })?.checkpoints?.providerReleased == false {
                    thread.updateCheckpoint(runID: run.id, stage: .baseline) { $0.phase = .interrupted; $0.error = ThreadRunCheckpointAttempt.interruptedMessage; $0.updatedAt = now }
                    thread.finishRunRecord(status: .interrupted, reason: .forcedStop, now: now)
                    if let i = thread.runHistory?.firstIndex(where: { $0.id == run.id }) { thread.runHistory?[i].checkpoints?.pendingStart = nil }
                    thread.activeRun = nil; thread.state = .interrupted
                } else { decision.effects.append(.init(id: id, request: .providerInterrupt(threadID: thread.id, runID: run.id))) }
            }
        case .respond(_, let requestID, let response):
            guard let i = thread.runtimeRequests.firstIndex(where: { $0.id == requestID }), !thread.runtimeRequests[i].responding else {
                throw WorkspaceCommandError("This provider request is no longer awaiting a response.")
            }
            let sessionScoped = thread.runtimeRequests[i].sessionScoped == true
            guard sessionScoped ? thread.runtimeID != nil : (thread.activeRun != nil && thread.activeRun?.stopRequested == false) else { throw WorkspaceCommandError("This provider request is no longer awaiting a response.") }
            let request = thread.runtimeRequests[i].request
            switch response {
            case .decision(let allow):
                if request.isClaudeQuestion {
                    guard thread.provider == .claude, !allow, request.claudeQuestion != nil else {
                        throw WorkspaceCommandError("Answer the Claude questions or cancel them.")
                    }
                } else { guard !request.isQuestion else { throw WorkspaceCommandError("Answer this question before continuing.") } }
            case .answers(let answers):
                if request.isClaudeQuestion {
                    guard thread.provider == .claude, let question = request.claudeQuestion else { throw WorkspaceCommandError("This Claude question is no longer available.") }
                    _ = try question.response(answers: answers)
                } else {
                    guard request.isQuestion, request.questions.allSatisfy({ !(answers[$0["id"].string ?? ""] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { throw WorkspaceCommandError("Answer every required question.") }
                }
            case .selections(let selections):
                if request.isClaudeQuestion {
                    guard thread.provider == .claude, let question = request.claudeQuestion else { throw WorkspaceCommandError("This Claude question is no longer available.") }
                    _ = try question.response(selections: selections)
                } else { throw WorkspaceCommandError("This selectable question is no longer valid.") }
            case .selectionsWithNotes(let selections, let notes):
                guard request.isClaudeQuestion else { throw WorkspaceCommandError("This provider question does not accept notes.") }
                guard thread.provider == .claude, let question = request.claudeQuestion else { throw WorkspaceCommandError("This Claude question is no longer available.") }
                _ = try question.response(selections: selections, notes: notes)
            }
            thread.runtimeRequests[i].responding = true
            if sessionScoped, let runtimeID = thread.runtimeID {
                decision.effects.append(.init(id: id, request: .providerSessionRespond(threadID: thread.id, runtimeID: runtimeID, request: request, response: response)))
            } else if let run = thread.activeRun {
                decision.effects.append(.init(id: id, request: .providerRespond(threadID: thread.id, runID: run.id, request: request, response: response)))
            }
        case .removeQueued(_, let queuedID):
            try decision.releaseContextReservation(thread.queuedTurns.first { $0.id == queuedID })
            thread.queuedTurns.removeAll { $0.id == queuedID }
        case .editQueued(_, let queuedID):
            guard thread.draft.isEmpty, thread.draftAttachments.isEmpty, let item = thread.queuedTurns.first(where: { $0.id == queuedID }) else { throw WorkspaceCommandError("Clear the composer before editing a queued message.") }
            try decision.releaseContextReservation(item)
            thread.draft = item.text; thread.draftAttachments = item.attachments ?? []; thread.queuedTurns.removeAll { $0.id == queuedID }
        case .replaceQueuedText(_, let queuedID, let expected, let text):
            guard let position = thread.queuedTurns.firstIndex(where: { $0.id == queuedID }),
                  thread.queuedTurns[position].text == expected, thread.queuedTurns[position].existingMessageID == nil, thread.queuedTurns[position].contextDelivery == nil,
                  text.utf16.count <= 100_000, !text.contains("\0"),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || thread.queuedTurns[position].attachments?.isEmpty == false else {
                throw WorkspaceCommandError("This queued input changed or retains an earlier steering acceptance. Read its current state before editing.")
            }
            thread.queuedTurns[position].text = text
        case .moveQueued(_, let queuedID, let beforeID, let expected):
            guard thread.queuedTurns.map(\.id) == expected, Set(expected).count == expected.count,
                  queuedID != beforeID, let position = thread.queuedTurns.firstIndex(where: { $0.id == queuedID }),
                  beforeID == nil || thread.queuedTurns.contains(where: { $0.id == beforeID }) else {
                throw WorkspaceCommandError("The queue changed. Read its current order before moving this input.")
            }
            let item = thread.queuedTurns.remove(at: position)
            if let beforeID, let destination = thread.queuedTurns.firstIndex(where: { $0.id == beforeID }) {
                thread.queuedTurns.insert(item, at: destination)
            } else { thread.queuedTurns.append(item) }
        case .resumeQueue:
            guard !decision.snapshot.isOriginalImportedSession(thread) else {
                throw WorkspaceCommandError("Remove the queued messages from this older import, then send them again to continue in an independent Coincide copy.")
            }
            guard thread.claudeResumeConsumerRunID == nil else { throw WorkspaceCommandError("Inspect the previous Claude resume attempt before resuming queued messages.") }
            guard !thread.isBusy, !thread.isArchived else { throw WorkspaceCommandError("Wait for the current turn before resuming the queue.") }
            thread.queuePaused = false; decision.startNext(in: &thread, now: now)
        case .addAttachments(_, let attachments):
            guard !thread.isArchived else { throw WorkspaceCommandError("Restore this conversation before attaching files.") }
            do { try AttachmentLimits.validate(thread.draftAttachments + attachments) }
            catch { throw WorkspaceCommandError(error.localizedDescription) }
            thread.draftAttachments += attachments
        case .removeAttachment(_, let attachmentID): thread.draftAttachments.removeAll { $0.id == attachmentID }
        case .abandonContextTransfer, .replaceComposerDraft, .discardComposerDraft, .threadActionUndo, .workspaceLifecycle, .setWorkspaceLifecyclePolicy: break // Routed through their atomic reducers above.
        case .scheduledTask, .acknowledgePromptSteering, .acknowledgePullRequestCheckout, .acknowledgePullRequestCreation, .acknowledgeConversationHistoryFiles, .dismissConversationHistoryRecall, .acknowledgeCheckpointRestore, .recallConversationHistoryPrompt, .retryPostRunCheckpoint, .continueAfterPostRunCheckpoint, .settleThread, .resumeThread, .approveProjectScript, .stopProjectScript, .skipProjectScript, .retryProjectScript, .addProject, .addProjectWithThread, .renameProject, .removeProject, .renameProjectGroup, .removeProjectGroup, .setProjectExpanded, .setProjectSortMode, .setProjectPinned, .setThreadSortMode, .reorderThreads, .setProjectGroupingMode, .setProjectGroupingOverride, .setProjectGroupExpanded, .setProjectGroupCheckout, .selectConversation, .moveProject, .reorderProjects, .reorderProjectGroups, .createThread, .startProjectClone, .cancelWorktreePreparation, .cancelProjectClone, .retryProjectClone: break
        }
        if thread != decision.snapshot.threads[index] {
            if case .editThread(_, .draft) = action {} else { thread.updatedAt = now }
        }
        decision.snapshot.threads[index] = thread
    }
    mutating func prepareClientCommand(_ action: WorkspaceCommand, commandID: UUID, now: Date, allowScratch: Bool = false) throws {
        try validateContextCompactionCommand(action)
        if !allowScratch { try validateScratchClientCommand(action) }
        try validateContextTransferCommand(action)
        preventDelayedPromptSteering(action, now: now)
        try validatePromptSteeringCommand(action, commandID: commandID)
        try validateConversationHistoryLocks(action)
        try validateCheckpointRestoreLocks(action)
        try validatePullRequestCreationLocks(action)
        try validatePullRequestCheckoutLocks(action)
        try guardPullRequestActions(action)
    }
    /// Compound registration shares the same insertion rules without entering
    /// the complete reducer a second time on the same task stack.
    private mutating func insertNewThread(_ thread: CodingThread, allowScratch: Bool = false) throws {
        if !allowScratch { try validateScratchClientCommand(.createThread(thread)) }
        guard snapshot.projects.contains(where: { $0.id == thread.projectID }), !snapshot.threads.contains(where: { $0.id == thread.id }),
              thread.messages.isEmpty, !thread.isBusy, thread.queuedTurns.isEmpty, (thread.runHistory ?? []).isEmpty, thread.workspacePreparation == nil else { throw WorkspaceCommandError("A new conversation needs an existing project and a unique identity.") }
        guard snapshot.workspaceReady(for: thread) || snapshot.projects.first(where: { $0.id == thread.projectID })?.path == thread.workspacePath else { throw WorkspaceCommandError("Wait for the clone before choosing another workspace.") }
        if let intent = thread.draftWorkspaceIntent {
            guard thread.scratchWorkspace == nil, intent.threadID == thread.id, intent.threadCreatedAt == thread.createdAt,
                  intent.projectID == thread.projectID,
                  let project = snapshot.projects.first(where: { $0.id == thread.projectID }), project.scratch == nil, project.createdAt == intent.projectCreatedAt,
                  project.path.utf8.elementsEqual(intent.sourcePath.utf8), thread.workspacePath.utf8.elementsEqual(intent.sourcePath.utf8) else {
                throw WorkspaceCommandError("The new draft’s workspace choice belongs to another conversation or checkout.")
            }
            do { try intent.sourceProof.validate(); try WorktreeValidation.branch(intent.baseBranch) }
            catch let error as CoincideError { throw WorkspaceCommandError(error.localizedDescription) }
        }
        var thread = thread; thread.runtimeID = nil; thread.runtimeRequests = []; thread.providerActivity = nil
        snapshot.threads.insert(thread, at: 0)
    }
    private func validatedGroup(_ key: String, expected: [UUID]) throws -> ProjectGroup {
        guard let group = snapshot.projectGroups.first(where: { $0.key == key }), Set(expected).count == expected.count,
              Set(expected) == Set(group.memberProjectIDs) else { throw WorkspaceCommandError("This project's checkouts changed. Review the current group and try again.") }
        return group
    }
    private func validatedGroup(_ key: String, expectedProjects: [ProjectGroupMemberReference]) throws -> ProjectGroup {
        let group = try validatedGroup(key, expected: expectedProjects.map(\.id))
        let paths = Dictionary(uniqueKeysWithValues: group.memberProjectReferences.map { ($0.id, $0.path) })
        guard expectedProjects.allSatisfy({ paths[$0.id] == $0.path }) else {
            throw WorkspaceCommandError("This project's checkout paths changed. Review the current checkouts before changing the group.")
        }
        return group
    }
    private func validateProjectOrder(_ expected: [UUID]) throws {
        guard snapshot.effectiveSidebarPreferences.sortMode == .manual else { throw WorkspaceCommandError("Choose Manual sorting before moving projects.") }
        guard snapshot.projects.map(\.id) == expected else { throw WorkspaceCommandError("The project order changed. Try moving the project again.") }
    }
    private mutating func reorderProjects(_ order: [UUID]) {
        let projects = Dictionary(uniqueKeysWithValues: snapshot.projects.map { ($0.id, $0) })
        snapshot.projects = order.compactMap { projects[$0] }
    }

    private mutating func start(_ queued: QueuedTurn, in thread: inout CodingThread, now: Date) {
        var configuration = queued.configuration; configuration.nativeThreadID = thread.providerThreadID
        if configuration.provider == .claude, let selection = thread.claudeResumeSelection,
           thread.claudeResumeConsumerRunID == nil {
            configuration.claudeLaunchSelection = selection
            thread.claudeResumeConsumerRunID = queued.id
        }
        thread.activeRun = ActiveRun(id: queued.id, configuration: configuration, startedAt: now,
                                     delegatedTaskID: queued.delegatedTaskID, delegatedCompletion: queued.delegatedCompletion, delegatedTaskOwnershipRecorded: queued.delegatedTaskOwnershipRecorded,
                                     contextTransferIDs: queued.contextTransferIDs, contextDelivery: queued.contextDelivery)
        if thread.messages.isEmpty && queued.preservesTitle != true { thread.title = queued.text.isEmpty ? (queued.attachments?.first?.name ?? "Attachments") : String(queued.text.prefix(80)) }
        var message: ChatMessage
        if let existingID = queued.existingMessageID, let index = thread.messages.firstIndex(where: { $0.id == existingID }) {
            message = thread.messages.remove(at: index); message.submissionError = nil
        } else {
            message = ChatMessage(id: "user-\(queued.id.uuidString)", role: .user, text: queued.text, attachments: queued.attachments); message.createdAt = queued.createdAt
        }
        message.runReference = .init(threadID: thread.id, runID: queued.id)
        thread.messages.append(message); thread.state = .running; thread.runtimeRequests.removeAll { $0.sessionScoped != true }
        if queued.checkpointPolicy == .automatic {
            let baseline = ThreadRunCheckpointAttempt(workspacePath: configuration.workspacePath, now: now)
            let checkpoints = ThreadRunCheckpoints(baseline: baseline, pendingStart: .init(configuration: configuration, prompt: queued.text, attachments: queued.attachments))
            if let run = thread.activeRun { thread.beginRunRecord(run, origin: .user, userMessageID: message.id, checkpoints: checkpoints, attributesMessages: true) }
            effects.append(.init(request: .resolveRunCheckpoint(threadID: thread.id, runID: queued.id, stage: .baseline, attemptID: baseline.id)))
        } else {
            if let run = thread.activeRun { thread.beginRunRecord(run, origin: .user, userMessageID: message.id, attributesMessages: true) }
            effects.append(.init(id: queued.id, request: .providerStart(threadID: thread.id, runID: queued.id, configuration: configuration, prompt: queued.text, attachments: queued.attachments)))
        }
    }
    mutating func startNext(in thread: inout CodingThread, now: Date) {
        if snapshot.isOriginalImportedSession(thread) {
            // A saved pre-copy queue must never restart the source CLI session.
            thread.queuePaused = true
            if let index = snapshot.threads.firstIndex(where: { $0.id == thread.id }) { snapshot.threads[index] = thread }
            return
        }
        if let i = snapshot.threads.firstIndex(where: { $0.id == thread.id }) { snapshot.threads[i] = thread }
        // These pure local gates cannot start work. Avoid materializing native
        // history proofs for a paused/empty queue, including read-only recovery.
        guard !thread.queuePaused, !thread.isBusy, !thread.isArchived, !thread.queuedTurns.isEmpty,
              thread.claudeResumeConsumerRunID == nil,
              !snapshot.isPromptSteeringHoldingQueue(threadID: thread.id), snapshot.providerReady(for: thread) else { return }
        let queued = thread.queuedTurns.removeFirst(); start(queued, in: &thread, now: now)
    }
    private mutating func receive(_ scopedEvent: ProviderEvent, threadID: UUID, runtimeID: UUID, now: Date) throws {
        guard !snapshot.isConversationHistoryLocked(threadID: threadID) else { return }
        guard let index = snapshot.threads.firstIndex(where: { $0.id == threadID }), snapshot.threads[index].runtimeID == runtimeID else { return }
        if let operation = snapshot.contextCompaction(threadID: threadID), operation.isWorking {
            switch scopedEvent {
            case .failure, .connectionClosed:
                finishContextCompaction(threadID: threadID, operationID: operation.id, result: .cancelled, now: now)
            default: break
            }
            return // Maintenance summaries and events never enter the public conversation.
        }
        // Validate every scope before taking the mutable thread copy. Unwrapping
        // metadata does not mutate the snapshot or need another reducer frame.
        var event = scopedEvent
        var hasVerifiedRunContext = false
        while case .context(let runID, let inner) = event {
            guard snapshot.threads[index].activeRun?.id == runID else { return }
            event = inner; hasVerifiedRunContext = true
        }
        if case .thread(let nativeID) = event {
            let owner = snapshot.threads[index]
            let configuration = owner.activeRun?.configuration ?? ProviderConfiguration(thread: owner)
            if snapshot.isClaudeHistoryScopeLocked(configuration: configuration, nativeThreadID: nativeID) {
                event = .connectionClosed("This provider conversation is held by another conversation's pending history action.")
            }
        }
        var thread = snapshot.threads[index]
        if let run = thread.activeRun, thread.runHistory?.first(where: { $0.id == run.id })?.checkpoints?.providerReleased == false {
            // Idle-session metadata may arrive while a baseline is being saved. It cannot
            // acknowledge, finish or append content to a provider turn never dispatched.
            switch event { case .configuration, .thread, .runEntity: break; default: return }
        }
        switch event {
        case .usage(let observation):
            guard hasVerifiedRunContext, let run = thread.activeRun,
                  let record = thread.runHistory?.firstIndex(where: { $0.id == run.id }),
                  thread.runHistory?[record].removedByHistoryOperationID == nil,
                  (try? observation.validate(provider: run.configuration.provider, runID: run.id)) != nil,
                  observation.canReplace(thread.runHistory?[record].providerUsage) else { return }
            thread.runHistory?[record].providerUsage = observation
        case .claudeHistoryEvidence(let evidence):
            guard thread.provider == .claude, thread.activeRun?.id == evidence.runID else { return }
            try thread.mergeClaudeHistoryEvidence(evidence)
        case .steeringCapabilitiesChanged:
            guard thread.activeRun != nil else { return }
            thread.steeringCapabilityRevision = (thread.steeringCapabilityRevision ?? 0) &+ 1
        case .runEntity: return // Entities are attributed only to the active run.
        case .entity(let update):
            let attributedRun = thread.activeRun?.id
            if let i = thread.messages.firstIndex(where: { $0.providerEntity?.key == update.key }) {
                guard thread.messages[i].removedByHistoryOperationID == nil else { return }
                let entity = try update.apply(to: thread.messages[i].providerEntity)
                thread.messages[i].providerEntity = entity
                if thread.messages[i].role != .user || !thread.messages[i].id.hasPrefix("user-") { thread.messages[i].text = entity.text }
            } else {
                let entity = try update.apply(to: nil)
                var message = ChatMessage(id: entity.key.messageID, role: entity.role, text: entity.text)
                message.createdAt = now; message.providerEntity = entity
                message.runReference = attributedRun.map { .init(threadID: thread.id, runID: $0) }
                thread.messages.append(message)
            }
        case .configuration(let metadata): thread.providerMetadata = metadata
        case .thread(let native): thread.providerThreadID = native; thread.updateRunRecord()
        case .turn(let native):
            thread.activeRun?.nativeTurnID = native // A late acknowledgement never changes idle to running.
            thread.updateRunRecord()
        case .delta(let itemID, let role, let text):
            guard thread.activeRun != nil else { return }
            if let i = thread.messages.firstIndex(where: { $0.id == itemID }) {
                guard thread.messages[i].removedByHistoryOperationID == nil, thread.messages[i].promptSteeringID == nil else { return }
                thread.messages[i].text += text
            }
            else { thread.appendRunMessage(id: itemID, role: role, text: text) }
        case .message(var message):
            guard thread.activeRun != nil else { return }
            // Removal markers and run attribution are app-owned audit metadata.
            message.removedByHistoryOperationID = nil; message.promptSteeringID = nil
            if let i = thread.messages.firstIndex(where: { $0.id == message.id }) {
                guard thread.messages[i].removedByHistoryOperationID == nil else { return }
                message.runReference = thread.messages[i].runReference
                message.removedByHistoryOperationID = thread.messages[i].removedByHistoryOperationID
                message.promptSteeringID = thread.messages[i].promptSteeringID
                if message.promptSteeringID != nil {
                    message.role = thread.messages[i].role; message.text = thread.messages[i].text
                    message.attachments = thread.messages[i].attachments; message.createdAt = thread.messages[i].createdAt
                    message.submissionError = thread.messages[i].submissionError
                }
                thread.messages[i] = message
            } else {
                message.runReference = thread.activeRun.map { .init(threadID: thread.id, runID: $0.id) }
                thread.messages.append(message)
            }
        case .approval(let request):
            guard thread.activeRun != nil, thread.activeRun?.stopRequested == false else { return }
            if !thread.runtimeRequests.contains(where: { $0.id == request.id }) { thread.runtimeRequests.append(.init(request: request)) }
            thread.state = .awaitingApproval
            thread.updateRunRecord(status: .awaitingApproval)
        case .approvalDismissed(let id):
            thread.runtimeRequests.removeAll { $0.id == id }
            if thread.activeRun != nil { thread.state = thread.runtimeRequests.isEmpty ? .running : .awaitingApproval }
            thread.updateRunRecord(status: thread.state == .awaitingApproval ? .awaitingApproval : .running)
        case .completed(let state):
            guard thread.activeRun != nil else { return }
            let stopped = thread.activeRun?.stopRequested == true
            let status: ThreadRunStatus = stopped || state == .interrupted ? .interrupted : state == .idle ? .completed : state == .failed ? .failed : .unknown
            if status == .completed, let run = thread.activeRun,
               thread.claudeResumeConsumerRunID == run.id, let selected = thread.claudeResumeSelection,
               run.configuration.claudeLaunchSelection == selected,
               run.configuration.claudeRuntimeConfiguration == thread.claudeRuntimeConfiguration,
               let evidence = thread.runHistory?.first(where: { $0.id == run.id })?.claude,
               evidence.terminalStatus == .completed, evidence.nativeSessionID == selected.nativeSessionID,
               evidence.observedInputIDs.contains(evidence.openingInputID) {
                thread.claudeResumeSelection = nil; thread.claudeResumeConsumerRunID = nil
            }
            thread.finishRunRecord(status: status, reason: .providerCompleted, now: now)
            if let runID = thread.activeRun?.id { requestPostRunCheckpoint(runID: runID, in: &thread, now: now) }
            thread.activeRun = nil; thread.runtimeRequests.removeAll { $0.sessionScoped != true }; thread.state = stopped ? .interrupted : state
            if stopped || state != .idle || thread.claudeResumeConsumerRunID != nil { thread.queuePaused = true }
            else { startNext(in: &thread, now: now) }
        case .failure(let message), .connectionClosed(let message):
            closeRuntimes.insert(thread.id); thread.runtimeID = nil
            thread.providerActivity = nil
            if thread.activeRun != nil {
                thread.state = thread.activeRun?.stopRequested == true ? .interrupted : .failed
                let reason: ThreadRunEndReason
                if case .connectionClosed = event { reason = .connectionLost } else { reason = .providerFailure }
                thread.finishRunRecord(status: thread.state == .interrupted ? .interrupted : .failed, reason: reason, now: now)
                if thread.state == .interrupted, let runID = thread.activeRun?.id {
                    requestPostRunCheckpoint(runID: runID, in: &thread, now: now); closeRuntimes.insert(thread.id); thread.runtimeID = nil
                }
                thread.appendRunMessage(role: .system, text: message)
            }
            thread.activeRun = nil; thread.runtimeRequests = []; thread.queuePaused = true
        case .context: break
        }
        if thread != snapshot.threads[index] { thread.updatedAt = now }
        snapshot.threads[index] = thread
    }
    private mutating func finished(_ request: WorkspaceEffectRequest, result: EffectResult, now: Date) {
        if case .contextCompaction(let threadID, let operationID) = request {
            finishContextCompaction(threadID: threadID, operationID: operationID, result: result, now: now); return
        }
        if request.promptSteeringOperationID != nil || request.conversationHistoryOperationID != nil || request.checkpointRestoreOperationID != nil || request.conversationHistoryFilesOperationID != nil || request.pullRequestCreationOperationID != nil || request.pullRequestActionOperationID != nil || request.pullRequestCheckoutOperationID != nil { return }
        if request.checkpointOwner != nil { finishCheckpoint(request, result: result, now: now); return }
        if case .projectClone(let projectID, let plan) = request {
            guard let i = snapshot.projects.firstIndex(where: { $0.id == projectID }), var clone = snapshot.projects[i].clone,
                  clone.id == plan.id, !clone.isReady else { return }
            switch result {
            case .succeeded:
                clone.phase = .completed; clone.error = nil; clone.progress = .init(stage: .checkout, percent: 100, detail: nil, stalled: false)
            case .failed(let message): clone.phase = .failed; clone.error = String(GitService.redactURLs(message).prefix(4_000))
            case .promptSteeringDelivered, .promptSteeringUnconfirmed, .promptSteeringUnsentCompleted, .pullRequestCheckoutCompleted, .pullRequestCheckoutUnconfirmed, .pullRequestCreationConfirmed, .pullRequestCreationUnconfirmed, .pullRequestActionConfirmed, .pullRequestActionUnconfirmed, .checkpointRestoreConfirmed, .checkpointRestoreUnconfirmed, .conversationHistoryConfirmed, .conversationHistoryUnconfirmed, .worktreeResolved, .worktreePrepared, .projectScriptResolved, .checkpointResolved, .checkpointCaptured, .checkpointUnavailable: return
            case .cancelled, .stopped:
                clone.phase = clone.cancelRequested ? .cancelled : .interrupted; clone.error = nil
            }
            clone.cancelRequested = false; clone.progress.stalled = false; clone.updatedAt = now; clone.endedAt = now
            snapshot.projects[i].clone = clone
            if clone.isReady {
                for index in snapshot.threads.indices where snapshot.threads[index].projectID == projectID {
                    var thread = snapshot.threads[index]; startNext(in: &thread, now: now); snapshot.threads[index] = thread
                }
            }
            return
        }
        guard let index = snapshot.threads.firstIndex(where: { $0.id == request.threadID }) else { return }
        var thread = snapshot.threads[index]
        if let runID = request.projectScriptRunID, let owner = request.projectScriptOwner {
            guard var run = thread.projectScript(owner: owner), run.id == runID else { return }
            switch (request, result) {
            case (_, .projectScriptResolved(let plan)) where run.phase == .discovering:
                run.plan = plan; run.phase = plan == nil ? .skipped : .awaitingApproval; run.error = nil
                if plan == nil { run.endedAt = now }
            case (_, .failed) where [.discovering, .starting].contains(run.phase):
                run.phase = .failed; run.error = run.plan == nil ? ThreadProjectScriptRun.discoveryError(for: owner.role) : ThreadProjectScriptRun.executionError(for: owner.role)
                run.endedAt = now; thread.queuePaused = true
            case (_, .cancelled) where [.discovering, .starting].contains(run.phase):
                run.phase = .interrupted; run.error = ThreadProjectScriptRun.interruptedError(for: owner.role); run.endedAt = now; thread.queuePaused = true
            default: return
            }
            run.updatedAt = now; thread.setProjectScript(run, owner: owner)
            snapshot.threads[index] = thread; startNext(in: &thread, now: now); snapshot.threads[index] = thread; return
        }
        if let attemptID = request.worktreeAttemptID {
            guard var state = thread.workspacePreparation, state.id == attemptID, !state.isReady else { return }
            switch (request, result) {
            case (.resolveWorktree(_, let saved), .worktreeResolved(let plan)) where saved == state.request && plan.request == saved && !state.cancelRequested && state.isRunning:
                state.plan = plan; state.phase = .preparing; state.error = nil; state.updatedAt = now
                thread.workspacePreparation = state; snapshot.threads[index] = thread
                effects.append(.init(request: .prepareWorktree(threadID: thread.id, plan: plan))); return
            case (.prepareWorktree(_, let plan), .worktreePrepared(let result)) where state.plan == plan:
                state.result = result; state.phase = .completed; state.error = nil
                if state.cancelRequested || thread.workspacePreparation?.phase == .cancelled || thread.workspacePreparation?.phase == .interrupted { thread.queuePaused = true }
                if var setup = state.setup, setup.phase == .waitingForCheckout {
                    setup.phase = state.permitsProjectSetup ? .discovering : .skipped
                    setup.updatedAt = now
                    if setup.phase == .skipped { setup.endedAt = now }
                    state.setup = setup
                    if state.permitsProjectSetup { effects.append(.init(request: .resolveProjectScript(threadID: thread.id, attemptID: state.id, runID: setup.id))) }
                }
            case (_, .failed(let error)) where state.isRunning:
                state.phase = state.cancelRequested ? .cancelled : .failed
                state.error = String(GitService.redactURLs(error).prefix(4_000))
            case (_, .cancelled) where state.isRunning, (_, .stopped) where state.isRunning, (.resolveWorktree, .worktreeResolved) where state.isRunning:
                state.phase = state.cancelRequested ? .cancelled : .interrupted; state.error = nil
            default: return
            }
            state.cancelRequested = false; state.updatedAt = now; state.endedAt = now
            thread.workspacePreparation = state; thread.updatedAt = now
            // Readiness observes the just-completed value before taking a captured FIFO turn.
            snapshot.threads[index] = thread
            if state.isReady { startNext(in: &thread, now: now) }
            snapshot.threads[index] = thread; return
        }
        switch request {
        case .contextCompaction, .promptSteering, .pullRequestCheckout, .pullRequestCreation, .pullRequestAction, .conversationHistoryFiles, .checkpointRestore, .conversationHistory, .resolveRunCheckpoint, .captureRunCheckpoint, .resolveThreadScript, .startThreadScript, .resolveProjectScript, .startProjectScript, .resolveWorktree, .prepareWorktree, .projectClone: break // Project-owned effects are handled before thread lookup.
        case .providerSessionRespond(_, let runtimeID, let request, _):
            guard thread.runtimeID == runtimeID, let i = thread.runtimeRequests.firstIndex(where: { $0.id == request.id && $0.sessionScoped == true }) else { return }
            if case .succeeded = result { thread.runtimeRequests.remove(at: i) }
            else {
                thread.runtimeRequests[i].responding = false
                if case .failed(let message) = result { thread.appendRunMessage(role: .system, text: message) }
            }
        case .providerStart(_, let runID, _, _, _):
            guard thread.activeRun?.id == runID else { return }
            if case .failed(let message) = result {
                restoreUndispatchedContext(in: &thread)
                thread.state = thread.activeRun?.stopRequested == true ? .interrupted : .failed
                thread.finishRunRecord(status: thread.state == .interrupted ? .interrupted : .failed, reason: .startFailed, now: now)
                thread.activeRun = nil; thread.runtimeRequests = []; thread.providerActivity = nil; thread.queuePaused = true
                thread.appendRunMessage(role: .system, text: message, runID: runID); closeRuntimes.insert(thread.id); thread.runtimeID = nil
            }
        case .providerInterrupt(_, let runID):
            guard thread.activeRun?.id == runID else { return }
            guard case .stopped = result else { return }
            restoreUndispatchedContext(in: &thread)
            thread.finishRunRecord(status: .interrupted, reason: .forcedStop, now: now)
            requestPostRunCheckpoint(runID: runID, in: &thread, now: now)
            thread.activeRun = nil; thread.runtimeRequests = []; thread.state = .interrupted; thread.queuePaused = true
            thread.runtimeID = nil; closeRuntimes.insert(thread.id)
            thread.providerActivity = nil
        case .providerRespond(_, let runID, let request, _):
            guard thread.activeRun?.id == runID, let i = thread.runtimeRequests.firstIndex(where: { $0.id == request.id }) else { return }
            if case .succeeded = result { thread.runtimeRequests.remove(at: i) }
            else {
                thread.runtimeRequests[i].responding = false
                if case .failed(let message) = result { thread.appendRunMessage(role: .system, text: message) }
            }
            thread.state = thread.runtimeRequests.isEmpty ? .running : .awaitingApproval
            thread.updateRunRecord(status: thread.state == .awaitingApproval ? .awaitingApproval : .running)
        }
        if thread != snapshot.threads[index] { thread.updatedAt = now }
        snapshot.threads[index] = thread
    }
}

extension WorkspaceCommand {
    var threadID: UUID? {
        switch self {
        case .submitDefaultWorktree(let input): input.threadID
        case .useCurrentCheckout(let id, _): id
        case .workspaceLifecycle(let action): action.threadID
        case .scheduledTask: nil
        case .setWorkspaceLifecyclePolicy: nil
        case .replaceComposerDraft(let replacement): replacement.expected.threadID
        case .discardComposerDraft(let discard): discard.expected.threadID
        case .threadActionUndo(let claim): claim.threadID
        case .abandonContextTransfer(let id, _, _): id
        case .acknowledgePromptSteering, .acknowledgePullRequestCheckout, .acknowledgePullRequestCreation, .acknowledgeConversationHistoryFiles, .dismissConversationHistoryRecall, .acknowledgeCheckpointRestore, .recallConversationHistoryPrompt, .addProject, .addProjectWithThread, .renameProject, .removeProject, .renameProjectGroup, .removeProjectGroup, .setProjectExpanded, .setProjectSortMode, .setProjectPinned, .setThreadSortMode, .reorderThreads, .setProjectGroupingMode, .setProjectGroupingOverride, .setProjectGroupExpanded, .setProjectGroupCheckout, .selectConversation, .moveProject, .reorderProjects, .reorderProjectGroups, .createThread, .startProjectClone, .cancelWorktreePreparation, .cancelProjectClone, .retryProjectClone: nil
        case .retryPostRunCheckpoint(let id, _, _), .continueAfterPostRunCheckpoint(let id, _, _), .settleThread(let id, _, _), .resumeThread(let id, _), .approveProjectScript(let id, _, _), .stopProjectScript(let id, _), .skipProjectScript(let id, _), .retryProjectScript(let id, _), .editThread(let id, _), .submit(let id, _), .submitFromAppMCP(let id, _, _), .submitCapturedClaude(let id, _, _), .interrupt(let id), .interruptFromAppMCP(let id, _, _), .respond(let id, _, _), .removeQueued(let id, _), .editQueued(let id, _), .replaceQueuedText(let id, _, _, _), .moveQueued(let id, _, _, _), .resumeQueue(let id), .addAttachments(let id, _), .removeAttachment(let id, _): id
        }
    }
}

private extension WorkspaceDecision {
    @inline(never)
    static func reduceCodexAuthentication(_ command: EngineCommand, snapshot: WorkspaceSnapshot, now: Date) throws -> Self {
        var decision = Self(snapshot: snapshot)
        switch command {
        case .codexAuthenticationPreparing(let instanceID, let retainedOwners):
            for index in decision.snapshot.threads.indices {
                var thread = decision.snapshot.threads[index]
                guard retainedOwners.contains(thread.id) || thread.ownedCodexInstances.contains(instanceID) else { continue }
                guard !decision.snapshot.isConversationHistoryLocked(threadID: thread.id),
                      !decision.snapshot.isCheckpointRestoreLocked(path: thread.workspacePath),
                      !decision.snapshot.isPullRequestCreationLocked(path: thread.workspacePath),
                      !decision.snapshot.isPullRequestCheckoutLocked(path: thread.workspacePath) else {
                    throw WorkspaceCommandError("Finish Codex history and workspace operations before changing the account.")
                }
                let ownsActiveRun = thread.activeRun?.configuration.ownedCodexInstanceID == instanceID
                if var run = thread.activeRun, ownsActiveRun {
                    run.stopRequested = true; thread.activeRun = run; thread.updateRunRecord()
                    if thread.runHistory?.first(where: { $0.id == run.id })?.checkpoints?.providerReleased == false {
                        thread.updateCheckpoint(runID: run.id, stage: .baseline) {
                            $0.phase = .interrupted; $0.error = ThreadRunCheckpointAttempt.interruptedMessage; $0.updatedAt = now
                        }
                        if let record = thread.runHistory?.firstIndex(where: { $0.id == run.id }) {
                            thread.runHistory?[record].checkpoints?.pendingStart = nil
                        }
                    }
                    thread.finishRunRecord(status: .interrupted, reason: .forcedStop, now: now)
                    decision.requestPostRunCheckpoint(runID: run.id, in: &thread, now: now)
                    thread.activeRun = nil; thread.state = .interrupted
                }
                // Accepted input keeps its exact account capture. Ending an
                // account mutation never replays or recaptures this queue.
                thread.queuePaused = true
                if retainedOwners.contains(thread.id) || ownsActiveRun {
                    thread.runtimeID = nil; thread.runtimeRequests = []; thread.providerActivity = nil
                    decision.closeRuntimes.insert(thread.id)
                }
                thread.updatedAt = now; decision.snapshot.threads[index] = thread
            }
            for index in (decision.snapshot.promptSteerings ?? []).indices {
                guard decision.snapshot.promptSteerings?[index].configuration.ownedCodexInstanceID == instanceID else { continue }
                decision.snapshot.promptSteerings?[index].fallbackAllowed = false
            }
        case .codexAccountConfigured(let instanceID, let binding):
            for index in decision.snapshot.threads.indices {
                var thread = decision.snapshot.threads[index]
                guard thread.provider == .codex, let configuration = thread.codexRuntimeConfiguration,
                      configuration.authenticationMode == .ownedChatGPT, configuration.instanceID == instanceID else { continue }
                guard thread.activeRun?.configuration.ownedCodexInstanceID != instanceID else { throw WorkspaceCommandError("Wait for Codex sessions to close before changing the account.") }
                thread.codexRuntimeConfiguration = configuration.replacingAccountBinding(binding)
                thread.queuePaused = true; thread.updatedAt = now; decision.snapshot.threads[index] = thread
            }
        default: throw WorkspaceCommandError("This workspace command was routed incorrectly.")
        }
        return decision
    }
}

private extension WorkspaceCommand {
    /// Actions reduced only by `mutateThreadClient`; keep in sync with its switch.
    var isThreadClientAction: Bool {
        switch self {
        case .editThread, .useCurrentCheckout, .interrupt, .interruptFromAppMCP, .respond, .removeQueued, .editQueued,
             .replaceQueuedText, .moveQueued, .resumeQueue, .addAttachments, .removeAttachment: true
        default: false
        }
    }
}
