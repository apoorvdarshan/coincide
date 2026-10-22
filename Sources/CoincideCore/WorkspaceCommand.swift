import Foundation

public struct QueuedTurn: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var text: String
    public var configuration: ProviderConfiguration
    public var createdAt: Date
    public var attachments: [ChatAttachment]? = nil
    public var checkpointPolicy: RunCheckpointPolicy? = nil
}
public struct ActiveRun: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var configuration: ProviderConfiguration
    public var startedAt: Date
    public var stopRequested = false
    public var nativeTurnID: String?
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
    case acpAgent(ACPAgentConfiguration), agentMode(String?)
    case agentConfig(id: String, value: String?)
    case agentConfiguration(id: String, value: JSONValue?)
    case resetAgentOptions
    case checkpointPolicy(RunCheckpointPolicy)
}

public enum WorkspaceCommand: Codable, Sendable, Equatable {
    case addProject(WorkspaceProject)
    case addProjectWithThread(project: WorkspaceProject, thread: CodingThread)
    case renameProject(projectID: UUID, title: String)
    case removeProject(projectID: UUID, expectedThreadIDs: [UUID])
    case renameProjectGroup(groupKey: String, expectedProjects: [ProjectGroupMemberReference], title: String)
    case removeProjectGroup(groupKey: String, expectedProjects: [ProjectGroupMemberReference], expectedThreadIDs: [UUID])
    case setProjectExpanded(projectID: UUID, expanded: Bool)
    case setProjectSortMode(ProjectSortMode)
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
    case submit(threadID: UUID, text: String)
    case interrupt(threadID: UUID)
    case respond(threadID: UUID, requestID: JSONValue, response: ProviderApprovalResponse)
    case removeQueued(threadID: UUID, queuedID: UUID)
    case editQueued(threadID: UUID, queuedID: UUID)
    case resumeQueue(threadID: UUID)
    case addAttachments(threadID: UUID, attachments: [ChatAttachment])
    case removeAttachment(threadID: UUID, attachmentID: UUID)
    case saveACPAgent(ACPAgentConfiguration)
    case removeACPAgent(UUID)
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
    case acknowledgeCheckpointRestore(operationID: UUID)
    case acknowledgeConversationHistoryFiles(operationID: UUID)
    case dismissConversationHistoryRecall(operationID: UUID)
}

enum EngineCommand: Codable, Sendable {
    case client(WorkspaceCommand)
    case runtimeOpened(threadID: UUID, runID: UUID, runtimeID: UUID)
    case provider(threadID: UUID, runtimeID: UUID, event: ProviderEvent)
    case effectResult(WorkspaceEffectRequest, EffectResult)
    case beginWorktreePreparation(threadID: UUID, request: GitWorktreeRequest, expectedSourcePath: String, previousAttemptID: UUID?, incarnation: UUID, reviewSetup: Bool = false)
    case worktreeStarted(threadID: UUID, attemptID: UUID)
    case worktreeRecovered(threadID: UUID, attemptID: UUID, incarnation: UUID, result: GitWorktreeResult)
    case pauseQueues
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
    case conversationHistoryAccepted(review: ConversationHistoryReview, title: String?)
    case conversationHistoryDispatching(threadID: UUID, operationID: UUID, incarnation: UUID)
    case conversationHistoryEffectResult(WorkspaceEffectRequest, EffectResult, incarnation: UUID)
    case conversationHistoryReconciled(operationID: UUID, incarnation: UUID, result: ConversationHistoryReconciliation)
    case conversationHistoryFilesDispatching(threadID: UUID, operationID: UUID, incarnation: UUID)
    case conversationHistoryFilesEffectResult(WorkspaceEffectRequest, EffectResult, incarnation: UUID)
    case conversationHistoryFilesInspected(operationID: UUID, incarnation: UUID, result: GitCheckpointRestoreInspection)
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
}

struct WorkspaceDecision: Sendable {
    var snapshot: WorkspaceSnapshot
    var effects: [PendingWorkspaceEffect] = []
    var closeRuntimes: Set<UUID> = []
    // Kept for existing single-runtime decision inspections.
    var closeRuntime: UUID? { closeRuntimes.first }
    var cancelCloneAttempt: UUID?
    var cancelWorktreeAttempt: UUID?

    static func make(_ command: EngineCommand, id: UUID, snapshot: WorkspaceSnapshot, now: Date) throws -> Self {
        var decision = Self(snapshot: snapshot)
        if case .client(let action) = command { try decision.validateConversationHistoryLocks(action); try decision.validateCheckpointRestoreLocks(action) }
        if case .provider(let threadID, _, _) = command, snapshot.isCheckpointRestoreLocked(threadID: threadID) { return decision }
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
        case .conversationHistoryAccepted(let review, let title):
            try decision.acceptConversationHistory(review, title: title, now: now)
        case .conversationHistoryDispatching(let threadID, let operationID, let incarnation):
            try decision.dispatchConversationHistory(threadID: threadID, operationID: operationID, incarnation: incarnation, now: now)
        case .conversationHistoryEffectResult(let request, let result, let incarnation):
            decision.finishConversationHistory(request, result: result, incarnation: incarnation, now: now)
        case .conversationHistoryReconciled(let operationID, _, let result):
            try decision.reconcileConversationHistory(operationID: operationID, result: result, now: now)
        case .client(.recallConversationHistoryPrompt(let operationID)):
            try decision.recallConversationHistoryPrompt(operationID: operationID, now: now)
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
        case .beginWorktreePreparation(let threadID, let request, let expectedSourcePath, let previousAttemptID, _, let reviewSetup):
            guard !decision.snapshot.isCheckpointRestoreLocked(threadID: threadID),
                  !decision.snapshot.isCheckpointRestoreLocked(path: request.sourcePath),
                  !decision.snapshot.isCheckpointRestoreLocked(path: request.destinationPath) else { throw WorkspaceCommandError("A checkpoint restoration is holding these workspace files.") }
            guard !decision.snapshot.isConversationHistoryLocked(threadID: threadID) else { throw WorkspaceCommandError("Finish or inspect this conversation's history action before changing its workspace.") }
            do { try request.validate() } catch { throw WorkspaceCommandError("Choose a valid local worktree destination and branch.") }
            guard let i = decision.snapshot.threads.firstIndex(where: { $0.id == threadID }) else { throw WorkspaceCommandError("This conversation no longer exists.") }
            var thread = decision.snapshot.threads[i]
            guard thread.workspacePath == expectedSourcePath, thread.settlement == nil, !thread.isBusy, !thread.isArchived, thread.messages.isEmpty,
                  decision.snapshot.projects.contains(where: { $0.id == thread.projectID && ($0.clone == nil || $0.clone?.isReady == true) }) else {
                throw WorkspaceCommandError("Prepare the workspace before the first turn, in an available conversation.")
            }
            var history: [ThreadWorkspacePreparationAttempt] = []
            if let previousAttemptID {
                guard let old = thread.workspacePreparation, old.id == previousAttemptID, old.canRetry,
                      old.request.sourcePath == request.sourcePath, old.request.selection == request.selection,
                      old.request.submodules == request.submodules,
                      old.request.destinationRoot == request.destinationRoot else { throw WorkspaceCommandError("This workspace preparation changed. Refresh its status before retrying.") }
                history = old.previousAttempts + [.init(request: old.request, plan: old.plan, setup: old.setup)]
            } else {
                guard thread.queuedTurns.isEmpty else { throw WorkspaceCommandError("Clear queued messages before choosing another workspace.") }
                if let old = thread.workspacePreparation {
                    guard !old.isRunning, request.sourcePath == (old.canRetry ? old.request.sourcePath : expectedSourcePath) else { throw WorkspaceCommandError("Wait for the current workspace preparation to finish or cancel it first.") }
                    history = old.previousAttempts + [.init(request: old.request, plan: old.plan, setup: old.setup)]
                } else {
                    guard request.sourcePath == expectedSourcePath else { throw WorkspaceCommandError("The source workspace changed. Choose the worktree again.") }
                }
            }
            let allIDs = decision.snapshot.threads.compactMap(\.workspacePreparation).flatMap { $0.previousAttempts.map { $0.request.id } + [$0.id] }
            guard !allIDs.contains(request.id), !decision.snapshot.cloneAttemptIDs.contains(request.id) else { throw WorkspaceCommandError("This workspace preparation identity is already in use.") }
            thread.workspacePreparation = .init(request: request, now: now, previousAttempts: history, reviewSetup: reviewSetup)
            thread.workspacePath = request.destinationPath; thread.providerThreadID = nil; thread.runtimeID = nil
            thread.runtimeRequests = []; thread.providerMetadata = nil; thread.providerActivity = nil
            for j in thread.queuedTurns.indices {
                thread.queuedTurns[j].configuration.workspacePath = request.destinationPath
                thread.queuedTurns[j].configuration.nativeThreadID = nil
            }
            thread.updatedAt = now; decision.snapshot.threads[i] = thread; decision.closeRuntimes.insert(thread.id)
            decision.effects.append(.init(id: request.id, request: .resolveWorktree(threadID: threadID, request: request)))
        case .client(.settleThread(let threadID, let expectedPath, let review)):
            guard let i = decision.snapshot.threads.firstIndex(where: { $0.id == threadID }),
                  decision.snapshot.threads[i].workspacePath == expectedPath, !decision.snapshot.threads[i].isArchived else {
                throw WorkspaceCommandError("This conversation changed. Settle it in its current workspace.")
            }
            if decision.snapshot.threads[i].settlement != nil { return decision }
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
        case .projectScriptStarted(let thread, let attempt, let run, let token):
            return try make(.threadScriptStarted(threadID: thread, owner: .setup(attemptID: attempt), runID: run, incarnation: token), id: id, snapshot: snapshot, now: now)
        case .projectScriptExited(let thread, let attempt, let run, let token, let result):
            return try make(.threadScriptExited(threadID: thread, owner: .setup(attemptID: attempt), runID: run, incarnation: token, result: result), id: id, snapshot: snapshot, now: now)
        case .projectScriptStopped(let thread, let attempt, let run, let token):
            return try make(.threadScriptStopped(threadID: thread, owner: .setup(attemptID: attempt), runID: run, incarnation: token), id: id, snapshot: snapshot, now: now)
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
        case .worktreeRecovered(let threadID, let attemptID, _, let result):
            if let i = decision.snapshot.threads.firstIndex(where: { $0.id == threadID }),
               let state = decision.snapshot.threads[i].workspacePreparation, state.id == attemptID, !state.isReady, let plan = state.plan {
                decision.snapshot.threads[i].queuePaused = true
                decision.finished(.prepareWorktree(threadID: threadID, plan: plan), result: .worktreePrepared(result), now: now)
            }
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
        case .client(.addProjectWithThread(let project, let thread)):
            guard project.clone == nil, thread.projectID == project.id, thread.workspacePath == project.path,
                  !decision.snapshot.projects.contains(where: { $0.id == project.id || $0.path == project.path }) else {
                throw WorkspaceCommandError("This project is already open, or its first conversation uses another workspace.")
            }
            decision.snapshot.projects.append(project)
            decision = try Self.make(.client(.createThread(thread)), id: id, snapshot: decision.snapshot, now: now)
        case .client(.startProjectClone(var project, let thread)):
            guard let submitted = project.clone else { throw WorkspaceCommandError("Choose a repository to clone.") }
            do { try submitted.plan.validate() } catch { throw WorkspaceCommandError(error.localizedDescription) }
            guard submitted.plan.destinationPath == project.path, thread.projectID == project.id, thread.workspacePath == project.path,
                  !decision.snapshot.projects.contains(where: { $0.id == project.id || $0.path == project.path }),
                  !decision.snapshot.cloneAttemptIDs.contains(submitted.plan.id) else { throw WorkspaceCommandError("This project or clone destination is already in use.") }
            project.clone = .init(plan: submitted.plan, now: now)
            decision.snapshot.projects.append(project)
            decision = try Self.make(.client(.createThread(thread)), id: id, snapshot: decision.snapshot, now: now)
            decision.effects.append(.init(id: submitted.plan.id, request: .projectClone(projectID: project.id, plan: submitted.plan)))
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
        case .client(.saveACPAgent(let agent)):
            do { try agent.validate() } catch { throw WorkspaceCommandError(error.localizedDescription) }
            if let i = decision.snapshot.acpAgents.firstIndex(where: { $0.id == agent.id }) { decision.snapshot.acpAgents[i] = agent }
            else { decision.snapshot.acpAgents.append(agent) }
        case .client(.removeACPAgent(let id)): decision.snapshot.acpAgents.removeAll { $0.id == id }
        case .client(.addProject(let project)):
            guard project.clone == nil else { throw WorkspaceCommandError("Use Clone Repository to create a cloning project.") }
            if decision.snapshot.projects.contains(where: { $0.path == project.path }) { return decision }
            guard !decision.snapshot.projects.contains(where: { $0.id == project.id }) else { throw WorkspaceCommandError("This project identity is already in use.") }
            decision.snapshot.projects.append(project)
        case .client(.createThread(let thread)):
            guard decision.snapshot.projects.contains(where: { $0.id == thread.projectID }), !decision.snapshot.threads.contains(where: { $0.id == thread.id }),
                  thread.messages.isEmpty, !thread.isBusy, thread.queuedTurns.isEmpty, (thread.runHistory ?? []).isEmpty, thread.workspacePreparation == nil else { throw WorkspaceCommandError("A new conversation needs an existing project and a unique identity.") }
            guard decision.snapshot.workspaceReady(for: thread) || decision.snapshot.projects.first(where: { $0.id == thread.projectID })?.path == thread.workspacePath else { throw WorkspaceCommandError("Wait for the clone before choosing another workspace.") }
            if thread.provider == .acp {
                guard let agent = thread.acpAgent, decision.snapshot.acpAgents.contains(agent) else { throw WorkspaceCommandError("Choose a saved ACP agent for this conversation.") }
            }
            var thread = thread; thread.runtimeID = nil; thread.runtimeRequests = []; thread.providerActivity = nil
            decision.snapshot.threads.insert(thread, at: 0)
        case .client(let action):
            guard let threadID = action.threadID, let index = decision.snapshot.threads.firstIndex(where: { $0.id == threadID }) else { throw WorkspaceCommandError("This conversation no longer exists.") }
            var thread = decision.snapshot.threads[index]
            switch action {
            case .editThread(_, let edit):
                switch edit {
                case .checkpointPolicy(let value): thread.checkpointPolicy = value
                case .title(let title):
                    let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !title.isEmpty else { throw WorkspaceCommandError("A conversation title cannot be empty.") }; thread.title = title
                case .model(let model): thread.model = model
                case .permission(let mode): thread.permission = mode
                case .agentMode(let mode): thread.agentModeID = mode
                case .agentConfig(let id, let value):
                    guard thread.provider == .acp else { throw WorkspaceCommandError("Choose an ACP agent first.") }
                    var values = thread.agentConfigValues ?? [:]; values[id] = value; thread.agentConfigValues = values.isEmpty ? nil : values
                case .agentConfiguration(let id, let value):
                    guard thread.provider == .acp else { throw WorkspaceCommandError("Choose an ACP agent first.") }
                    if let value { guard value.string != nil || value == .bool(true) || value == .bool(false) else { throw WorkspaceCommandError("Choose a supported agent configuration value.") } }
                    var values = thread.agentConfiguration ?? [:]; values[id] = value; thread.agentConfiguration = values.isEmpty ? nil : values
                    thread.agentConfigValues?.removeValue(forKey: id)
                case .resetAgentOptions:
                    guard thread.provider == .acp else { throw WorkspaceCommandError("Choose an ACP agent first.") }
                    thread.agentConfigValues = nil; thread.agentConfiguration = nil; thread.agentModeID = nil; thread.model = ""
                case .provider(let kind):
                    guard kind != .acp else { throw WorkspaceCommandError("Choose a configured ACP agent.") }
                    guard !thread.isBusy, thread.messages.isEmpty, thread.queuedTurns.isEmpty else { throw WorkspaceCommandError("Start a new conversation to change providers.") }
                    decision.closeRuntimes.insert(thread.id); thread.provider = kind; thread.acpAgent = nil; thread.agentModeID = nil; thread.agentConfigValues = nil; thread.agentConfiguration = nil; thread.providerMetadata = nil; thread.providerActivity = nil; thread.runtimeRequests = []; thread.model = ""; thread.providerThreadID = nil; thread.runtimeID = nil
                case .acpAgent(let agent):
                    guard !thread.isBusy, thread.messages.isEmpty, thread.queuedTurns.isEmpty else { throw WorkspaceCommandError("Start a new conversation to change agents.") }
                    guard decision.snapshot.acpAgents.contains(agent) else { throw WorkspaceCommandError("Save this agent in Settings first.") }
                    decision.closeRuntimes.insert(thread.id); thread.provider = .acp; thread.acpAgent = agent; thread.agentModeID = nil; thread.agentConfigValues = nil; thread.providerMetadata = nil
                    thread.model = ""; thread.providerThreadID = nil; thread.runtimeID = nil
                    thread.agentConfiguration = nil; thread.providerActivity = nil; thread.runtimeRequests = []
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
                case .workspacePath(let path):
                    guard thread.settlement == nil else { throw WorkspaceCommandError("Resume this conversation before changing its workspace.") }
                    if thread.workspacePreparation != nil {
                        guard path == thread.workspacePath else { throw WorkspaceCommandError("Use Choose Worktree to change a prepared conversation's workspace.") }
                        break
                    }
                    guard !thread.isBusy, thread.messages.isEmpty, thread.queuedTurns.isEmpty else { throw WorkspaceCommandError("Change the workspace before sending the first message.") }
                    guard decision.snapshot.workspaceReady(for: thread) else { throw WorkspaceCommandError("Wait for the clone before changing workspaces.") }
                    thread.workspacePath = path; thread.providerThreadID = nil; decision.closeRuntimes.insert(thread.id); thread.runtimeID = nil; thread.runtimeRequests = []; thread.providerActivity = nil; thread.providerMetadata = nil
                }
            case .submit(_, let text):
                let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard (!text.isEmpty || !thread.draftAttachments.isEmpty), !thread.isArchived else { throw WorkspaceCommandError("Enter a message or attach a file in an active conversation.") }
                guard text.utf16.count <= 120_000 else { throw WorkspaceCommandError("Messages can contain up to 120,000 characters. Shorten the draft or attach it as a file.") }
                let queued = QueuedTurn(id: id, text: text, configuration: .init(thread: thread), createdAt: now,
                                        attachments: thread.draftAttachments.isEmpty ? nil : thread.draftAttachments, checkpointPolicy: thread.effectiveCheckpointPolicy)
                thread.draft = ""; thread.draftAttachments = []
                if thread.settlement != nil {
                    thread.queuedTurns.append(queued); thread.requestSettlementResume(now: now)
                }
                else if thread.isBusy || !decision.snapshot.providerReady(for: thread) {
                    if thread.queuedTurns.isEmpty, !thread.isBusy, thread.workspacePreparation?.cancelRequested != true, thread.workspacePreparation?.phase != .cancelled, thread.workspacePreparation?.phase != .interrupted,
                       ![.interrupted, .cancelled, .stopping].contains(thread.workspacePreparation?.setup?.phase) { thread.queuePaused = false }
                    thread.queuedTurns.append(queued)
                }
                else {
                    if thread.queuedTurns.isEmpty { thread.queuePaused = false }
                    decision.start(queued, in: &thread, now: now)
                }
            case .interrupt:
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
                case .option(let id):
                    guard request.method == "session/request_permission", (request.params["options"].array ?? []).contains(where: { $0["optionId"].string == id }) else {
                        throw WorkspaceCommandError("This permission option is no longer available.")
                    }
                case .decision: guard !request.isQuestion else { throw WorkspaceCommandError("Answer this question before continuing.") }
                case .answers(let answers):
                    guard request.isQuestion, request.questions.allSatisfy({ !(answers[$0["id"].string ?? ""] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { throw WorkspaceCommandError("Answer every required question.") }
                }
                thread.runtimeRequests[i].responding = true
                if sessionScoped, let runtimeID = thread.runtimeID {
                    decision.effects.append(.init(id: id, request: .providerSessionRespond(threadID: thread.id, runtimeID: runtimeID, request: request, response: response)))
                } else if let run = thread.activeRun {
                    decision.effects.append(.init(id: id, request: .providerRespond(threadID: thread.id, runID: run.id, request: request, response: response)))
                }
            case .removeQueued(_, let queuedID): thread.queuedTurns.removeAll { $0.id == queuedID }
            case .editQueued(_, let queuedID):
                guard thread.draft.isEmpty, thread.draftAttachments.isEmpty, let item = thread.queuedTurns.first(where: { $0.id == queuedID }) else { throw WorkspaceCommandError("Clear the composer before editing a queued message.") }
                thread.draft = item.text; thread.draftAttachments = item.attachments ?? []; thread.queuedTurns.removeAll { $0.id == queuedID }
            case .resumeQueue:
                guard !thread.isBusy, !thread.isArchived else { throw WorkspaceCommandError("Wait for the current turn before resuming the queue.") }
                thread.queuePaused = false; decision.startNext(in: &thread, now: now)
            case .addAttachments(_, let attachments):
                guard !thread.isArchived else { throw WorkspaceCommandError("Restore this conversation before attaching files.") }
                do { try AttachmentLimits.validate(thread.draftAttachments + attachments) }
                catch { throw WorkspaceCommandError(error.localizedDescription) }
                thread.draftAttachments += attachments
            case .removeAttachment(_, let attachmentID): thread.draftAttachments.removeAll { $0.id == attachmentID }
            case .acknowledgeConversationHistoryFiles, .dismissConversationHistoryRecall, .acknowledgeCheckpointRestore, .recallConversationHistoryPrompt, .retryPostRunCheckpoint, .continueAfterPostRunCheckpoint, .settleThread, .resumeThread, .approveProjectScript, .stopProjectScript, .skipProjectScript, .retryProjectScript, .addProject, .addProjectWithThread, .renameProject, .removeProject, .renameProjectGroup, .removeProjectGroup, .setProjectExpanded, .setProjectSortMode, .setProjectGroupingMode, .setProjectGroupingOverride, .setProjectGroupExpanded, .setProjectGroupCheckout, .selectConversation, .moveProject, .reorderProjects, .reorderProjectGroups, .createThread, .saveACPAgent, .removeACPAgent, .startProjectClone, .cancelWorktreePreparation, .cancelProjectClone, .retryProjectClone: break
            }
            if thread != decision.snapshot.threads[index] {
                if case .editThread(_, .draft) = action {} else { thread.updatedAt = now }
            }
            decision.snapshot.threads[index] = thread
        case .runtimeOpened(let threadID, let runID, let runtimeID):
            if let i = decision.snapshot.threads.firstIndex(where: { $0.id == threadID }), decision.snapshot.threads[i].activeRun?.id == runID {
                decision.snapshot.threads[i].runtimeID = runtimeID
            }
        case .provider(let threadID, let runtimeID, let event):
            do { try decision.receive(event, threadID: threadID, runtimeID: runtimeID, now: now) }
            catch let error as CoincideError {
                try decision.receive(.failure(error.localizedDescription), threadID: threadID, runtimeID: runtimeID, now: now)
            }
        case .effectResult(let request, let result), .projectScriptEffectResult(let request, let result, _), .runCheckpointEffectResult(let request, let result, _):
            decision.finished(request, result: result, now: now)
        case .pauseQueues:
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
        }
        decision.snapshot.reconcileGroupingPreferences()
        try WorkspaceJournal.validate(decision.snapshot)
        return decision
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
        thread.activeRun = ActiveRun(id: queued.id, configuration: configuration, startedAt: now)
        if thread.messages.isEmpty { thread.title = queued.text.isEmpty ? (queued.attachments?.first?.name ?? "Attachments") : String(queued.text.prefix(80)) }
        var message = ChatMessage(id: "user-\(queued.id.uuidString)", role: .user, text: queued.text, attachments: queued.attachments); message.createdAt = queued.createdAt
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
        if let i = snapshot.threads.firstIndex(where: { $0.id == thread.id }) { snapshot.threads[i] = thread }
        guard snapshot.providerReady(for: thread), !thread.isBusy, !thread.queuePaused, !thread.isArchived, !thread.queuedTurns.isEmpty else { return }
        let queued = thread.queuedTurns.removeFirst(); start(queued, in: &thread, now: now)
    }
    private mutating func receive(_ event: ProviderEvent, threadID: UUID, runtimeID: UUID, now: Date) throws {
        guard !snapshot.isConversationHistoryLocked(threadID: threadID) else { return }
        guard let index = snapshot.threads.firstIndex(where: { $0.id == threadID }), snapshot.threads[index].runtimeID == runtimeID else { return }
        var thread = snapshot.threads[index]
        if case .context(let runID, let inner) = event {
            guard thread.activeRun?.id == runID else { return }
            try receive(inner, threadID: threadID, runtimeID: runtimeID, now: now); return
        }
        if let run = thread.activeRun, thread.runHistory?.first(where: { $0.id == run.id })?.checkpoints?.providerReleased == false {
            // Idle-session metadata may arrive while a baseline is being saved. It cannot
            // acknowledge, finish or append content to a provider turn never dispatched.
            switch event { case .sessionApproval, .sessionApprovalDismissed, .configuration, .thread: break; default: return }
        }
        switch event {
        case .submissionFailed(let id, let reason):
            if let i = thread.messages.firstIndex(where: { $0.id == id && $0.role == .user }) { thread.messages[i].submissionError = reason; thread.queuePaused = true }
        case .activity(let activity):
            if activity.state != .idle, thread.activeRun == nil,
               thread.runHistory?.contains(where: { $0.status.isTerminal && ($0.id == activity.id || $0.turnIDs.contains(activity.id.uuidString)) }) == true { return }
            thread.providerActivity = activity
            if activity.state != .idle {
                if thread.activeRun == nil {
                    let run = ActiveRun(id: activity.id, configuration: .init(thread: thread), startedAt: now)
                    thread.activeRun = run
                    let baseline = ThreadRunCheckpointAttempt(workspacePath: thread.workspacePath, phase: .unavailable, now: now, unavailableReason: .agentInitiated)
                    thread.beginRunRecord(run, origin: .agent, checkpoints: thread.effectiveCheckpointPolicy == .automatic ? .init(baseline: baseline, providerReleased: true) : nil, attributesMessages: true)
                }
                thread.activeRun?.nativeTurnID = activity.id.uuidString
                thread.state = activity.state == .requiresAction ? .awaitingApproval : .running
                thread.updateRunRecord(status: activity.state == .requiresAction ? .awaitingApproval : .running)
            } else if activity.finishesRun, let run = thread.activeRun, run.nativeTurnID == activity.id.uuidString {
                let reason = activity.stopReason?.string
                let normalCompletion = ["end_turn", "max_tokens", "max_turn_requests", "refusal"].contains(reason ?? "")
                let status: ThreadRunStatus = run.stopRequested || reason == "cancelled" ? .interrupted : reason == "error" ? .failed : normalCompletion ? .completed : .unknown
                thread.finishRunRecord(status: status, reason: .providerActivity, now: now, providerStopReason: reason)
                requestPostRunCheckpoint(runID: run.id, in: &thread, now: now)
                thread.activeRun = nil; thread.runtimeRequests.removeAll { $0.sessionScoped != true }
                if run.stopRequested || reason == "cancelled" { thread.state = .interrupted }
                else if reason == "error" {
                    thread.state = .failed
                    thread.appendRunMessage(role: .system, text: activity.error?["message"].string ?? "The agent stopped because of an error.", runID: run.id)
                } else { thread.state = .idle }
                if thread.state == .idle, normalCompletion, reason != "end_turn" {
                    thread.appendRunMessage(role: .system, text: "The agent stopped: \((reason ?? "").replacingOccurrences(of: "_", with: " ")).", runID: run.id)
                }
                if thread.state != .idle || !normalCompletion { thread.queuePaused = true }
                else { startNext(in: &thread, now: now) }
            }
        case .sessionApproval(let request):
            if !thread.runtimeRequests.contains(where: { $0.id == request.id }) { thread.runtimeRequests.append(.init(request: request, sessionScoped: true)) }
        case .sessionApprovalDismissed(let id): thread.runtimeRequests.removeAll { $0.id == id && $0.sessionScoped == true }
        case .entity(let update):
            if let i = thread.messages.firstIndex(where: { $0.providerEntity?.key == update.key }) {
                guard thread.messages[i].removedByHistoryOperationID == nil else { return }
                let entity = try update.apply(to: thread.messages[i].providerEntity)
                thread.messages[i].providerEntity = entity
                if thread.messages[i].role != .user || !thread.messages[i].id.hasPrefix("user-") { thread.messages[i].text = entity.text }
            } else {
                let entity = try update.apply(to: nil)
                var message = ChatMessage(id: entity.key.messageID, role: entity.role, text: entity.text)
                message.createdAt = now; message.providerEntity = entity
                message.runReference = thread.activeRun.map { .init(threadID: thread.id, runID: $0.id) }
                thread.messages.append(message)
            }
        case .associateEntity(let key, let clientID):
            guard key.type == "user_message", let target = thread.messages.firstIndex(where: { $0.id == clientID && $0.role == .user }),
                  thread.messages[target].removedByHistoryOperationID == nil,
                  !thread.messages.contains(where: { $0.providerEntity?.key == key && $0.removedByHistoryOperationID != nil }) else { return }
            guard thread.messages[target].providerEntity == nil || thread.messages[target].providerEntity?.key == key else { throw CoincideError("The agent changed an accepted message identity.") }
            let echoed = thread.messages.firstIndex(where: { $0.providerEntity?.key == key })
            let entity = echoed.flatMap { thread.messages[$0].providerEntity } ?? ProviderEntity(key: key)
            thread.messages[target].providerEntity = entity
            if let echoed, echoed != target { thread.messages.remove(at: echoed) }
        case .configuration(let metadata): thread.providerMetadata = metadata
        case .thread(let native): thread.providerThreadID = native; thread.updateRunRecord()
        case .turn(let native):
            thread.activeRun?.nativeTurnID = native // A late acknowledgement never changes idle to running.
            thread.updateRunRecord()
        case .delta(let itemID, let role, let text):
            guard thread.activeRun != nil else { return }
            if let i = thread.messages.firstIndex(where: { $0.id == itemID }) {
                guard thread.messages[i].removedByHistoryOperationID == nil else { return }
                thread.messages[i].text += text
            }
            else { thread.appendRunMessage(id: itemID, role: role, text: text) }
        case .message(var message):
            guard thread.activeRun != nil else { return }
            // Removal markers and run attribution are app-owned audit metadata.
            message.removedByHistoryOperationID = nil
            if let i = thread.messages.firstIndex(where: { $0.id == message.id }) {
                guard thread.messages[i].removedByHistoryOperationID == nil else { return }
                message.runReference = thread.messages[i].runReference
                message.removedByHistoryOperationID = thread.messages[i].removedByHistoryOperationID
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
            thread.finishRunRecord(status: status, reason: .providerCompleted, now: now)
            if let runID = thread.activeRun?.id { requestPostRunCheckpoint(runID: runID, in: &thread, now: now) }
            thread.activeRun = nil; thread.runtimeRequests = []; thread.state = stopped ? .interrupted : state
            if stopped || state != .idle { thread.queuePaused = true }
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
        if request.conversationHistoryOperationID != nil || request.checkpointRestoreOperationID != nil || request.conversationHistoryFilesOperationID != nil { return }
        if request.checkpointOwner != nil { finishCheckpoint(request, result: result, now: now); return }
        if case .projectClone(let projectID, let plan) = request {
            guard let i = snapshot.projects.firstIndex(where: { $0.id == projectID }), var clone = snapshot.projects[i].clone,
                  clone.id == plan.id, !clone.isReady else { return }
            switch result {
            case .succeeded:
                clone.phase = .completed; clone.error = nil; clone.progress = .init(stage: .checkout, percent: 100, detail: nil, stalled: false)
            case .failed(let message): clone.phase = .failed; clone.error = String(GitService.redactURLs(message).prefix(4_000))
            case .checkpointRestoreConfirmed, .checkpointRestoreUnconfirmed, .conversationHistoryConfirmed, .conversationHistoryUnconfirmed, .worktreeResolved, .worktreePrepared, .projectScriptResolved, .checkpointResolved, .checkpointCaptured, .checkpointUnavailable: return
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
        case .conversationHistoryFiles, .checkpointRestore, .conversationHistory, .resolveRunCheckpoint, .captureRunCheckpoint, .resolveThreadScript, .startThreadScript, .resolveProjectScript, .startProjectScript, .resolveWorktree, .prepareWorktree, .projectClone: break // Project-owned effects are handled before thread lookup.
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
                thread.state = thread.activeRun?.stopRequested == true ? .interrupted : .failed
                thread.finishRunRecord(status: thread.state == .interrupted ? .interrupted : .failed, reason: .startFailed, now: now)
                thread.activeRun = nil; thread.runtimeRequests = []; thread.providerActivity = nil; thread.queuePaused = true
                thread.appendRunMessage(role: .system, text: message, runID: runID); closeRuntimes.insert(thread.id); thread.runtimeID = nil
            }
        case .providerInterrupt(_, let runID):
            guard thread.activeRun?.id == runID else { return }
            guard case .stopped = result else { return }
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

private extension WorkspaceCommand {
    var threadID: UUID? {
        switch self {
        case .acknowledgeConversationHistoryFiles, .dismissConversationHistoryRecall, .acknowledgeCheckpointRestore, .recallConversationHistoryPrompt, .addProject, .addProjectWithThread, .renameProject, .removeProject, .renameProjectGroup, .removeProjectGroup, .setProjectExpanded, .setProjectSortMode, .setProjectGroupingMode, .setProjectGroupingOverride, .setProjectGroupExpanded, .setProjectGroupCheckout, .selectConversation, .moveProject, .reorderProjects, .reorderProjectGroups, .createThread, .saveACPAgent, .removeACPAgent, .startProjectClone, .cancelWorktreePreparation, .cancelProjectClone, .retryProjectClone: nil
        case .retryPostRunCheckpoint(let id, _, _), .continueAfterPostRunCheckpoint(let id, _, _), .settleThread(let id, _, _), .resumeThread(let id, _), .approveProjectScript(let id, _, _), .stopProjectScript(let id, _), .skipProjectScript(let id, _), .retryProjectScript(let id, _), .editThread(let id, _), .submit(let id, _), .interrupt(let id), .respond(let id, _, _), .removeQueued(let id, _), .editQueued(let id, _), .resumeQueue(let id), .addAttachments(let id, _), .removeAttachment(let id, _): id
        }
    }
}
