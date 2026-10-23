import Foundation

extension WorkspaceDecision {
    /// Native worktree admission has its own frame. Delegation composes this
    /// exact helper without retaining the broad general reducer underneath it.
    @inline(never)
    mutating func beginWorktreePreparation(threadID: UUID, request: GitWorktreeRequest,
        expectedSourcePath: String, previousAttemptID: UUID?, reviewSetup: Bool,
        claudeRuntimeConfiguration: ClaudeRuntimeConfiguration?, piRuntimeConfiguration: PiRuntimeConfiguration?, now: Date) throws {
        guard !snapshot.pullRequestCheckoutReservedIDs.union(snapshot.promptSteeringReservedIDs).contains(request.id) else { throw WorkspaceCommandError("This workspace preparation identity is reserved by a pull request checkout.") }
        guard !snapshot.isPullRequestCheckoutLocked(threadID: threadID),
              !snapshot.isPullRequestCheckoutLocked(path: request.sourcePath),
              !snapshot.isPullRequestCheckoutLocked(path: request.destinationPath),
              !snapshot.isPullRequestCreationLocked(threadID: threadID),
              !snapshot.isPullRequestCreationLocked(path: request.sourcePath),
              !snapshot.isPullRequestCreationLocked(path: request.destinationPath),
              !snapshot.isCheckpointRestoreLocked(threadID: threadID),
              !snapshot.isCheckpointRestoreLocked(path: request.sourcePath),
              !snapshot.isCheckpointRestoreLocked(path: request.destinationPath) else { throw WorkspaceCommandError("A checkpoint restoration is holding these workspace files.") }
        guard !snapshot.isConversationHistoryLocked(threadID: threadID) else { throw WorkspaceCommandError("Finish or inspect this conversation's history action before changing its workspace.") }
        do { try request.validate() } catch { throw WorkspaceCommandError("Choose a valid local worktree destination and branch.") }
        guard let i = snapshot.threads.firstIndex(where: { $0.id == threadID }) else { throw WorkspaceCommandError("This conversation no longer exists.") }
        var thread = snapshot.threads[i]
        guard thread.workspacePath == expectedSourcePath, thread.settlement == nil, !thread.isBusy, !thread.isArchived, thread.messages.isEmpty,
              snapshot.projects.contains(where: { $0.id == thread.projectID && ($0.clone == nil || $0.clone?.isReady == true) }) else {
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
        let allIDs = snapshot.threads.compactMap(\.workspacePreparation).flatMap { $0.previousAttempts.map { $0.request.id } + [$0.id] }
        guard !allIDs.contains(request.id), !snapshot.cloneAttemptIDs.contains(request.id) else { throw WorkspaceCommandError("This workspace preparation identity is already in use.") }
        thread.workspacePreparation = .init(request: request, now: now, previousAttempts: history, reviewSetup: reviewSetup)
        if let previous = thread.claudeRuntimeConfiguration {
            guard let captured = claudeRuntimeConfiguration,
                  captured == (try previous.replacingWorkspace(request.destinationPath, physicalPath: captured.workspacePath)) else { throw ClaudeRuntimeConfiguration.invalid() }
            thread.claudeRuntimeConfiguration = captured
        } else if claudeRuntimeConfiguration != nil { throw ClaudeRuntimeConfiguration.invalid() }
        if let selected = thread.piConfiguration, let previous = selected.runtime {
            let captured: PiRuntimeConfiguration
            do {
                guard let value = piRuntimeConfiguration,
                      value == (try previous.replacingWorkspace(request.destinationPath, physicalPath: value.workspacePath)) else { throw PiRuntimeConfiguration.invalid() }
                captured = value
            } catch { throw WorkspaceCommandError("The Pi runtime changed before worktree preparation.") }
            thread.piConfiguration = .init(instanceID: selected.instanceID, executable: selected.executable,
                model: selected.model, thinkingLevel: selected.thinkingLevel, runtime: captured)
        } else if piRuntimeConfiguration != nil { throw WorkspaceCommandError("The Pi runtime changed before worktree preparation.") }
        thread.claudeResumeSelection = nil; thread.claudeResumeConsumerRunID = nil; thread.claudeInheritedHead = nil
        thread.workspacePath = request.destinationPath; if thread.codexModelSelectionSource == .cliDefault { thread.codexModelSelectionSource = .explicitModel }; thread.providerThreadID = nil; thread.runtimeID = nil
        thread.runtimeRequests = []; thread.providerMetadata = nil; thread.providerActivity = nil
        for j in thread.queuedTurns.indices {
            if let previous = thread.queuedTurns[j].configuration.claudeRuntimeConfiguration {
                guard let captured = claudeRuntimeConfiguration else { throw ClaudeRuntimeConfiguration.invalid() }
                thread.queuedTurns[j].configuration.claudeRuntimeConfiguration = try previous.replacingWorkspace(request.destinationPath, physicalPath: captured.workspacePath)
            }
            if let selected = thread.queuedTurns[j].configuration.piConfiguration, let previous = selected.runtime {
                guard let captured = piRuntimeConfiguration else { throw WorkspaceCommandError("The queued Pi runtime changed before worktree preparation.") }
                let replaced: PiRuntimeConfiguration
                do { replaced = try previous.replacingWorkspace(request.destinationPath, physicalPath: captured.workspacePath) }
                catch { throw WorkspaceCommandError("The queued Pi runtime changed before worktree preparation.") }
                thread.queuedTurns[j].configuration.piConfiguration = .init(instanceID: selected.instanceID, executable: selected.executable,
                    model: selected.model, thinkingLevel: selected.thinkingLevel, runtime: replaced)
            }
            thread.queuedTurns[j].configuration.claudeLaunchSelection = nil
            thread.queuedTurns[j].configuration.workspacePath = request.destinationPath
            thread.queuedTurns[j].configuration.nativeThreadID = nil
        }
        thread.updatedAt = now; snapshot.threads[i] = thread; closeRuntimes.insert(thread.id)
        effects.append(.init(id: request.id, request: .resolveWorktree(threadID: threadID, request: request)))
    }
    @inline(never)
    static func reduceWorktreePreparation(_ command: EngineCommand, snapshot: WorkspaceSnapshot, now: Date) throws -> Self {
        guard case .beginWorktreePreparation(let threadID, let request, let source, let previous, _, let reviewSetup, let claude, let pi) = command else { throw WorkspaceCommandError("This workspace command was routed incorrectly.") }
        var decision = Self(snapshot: snapshot)
        try decision.beginWorktreePreparation(threadID: threadID, request: request, expectedSourcePath: source,
            previousAttemptID: previous, reviewSetup: reviewSetup, claudeRuntimeConfiguration: claude, piRuntimeConfiguration: pi, now: now)
        return decision
    }
}
