import Foundation

/// Moving an unstarted chat changes its folder, never its identity or composer contents.
public struct DraftProjectAssignment: Codable, Sendable, Equatable {
    public let sourceProjectID: UUID
    public let threadCreatedAt: Date
    public let expectedConfiguration: ProviderConfiguration
    public let targetProject: WorkspaceProject
    public let claudeRuntime: ClaudeRuntimeConfiguration?

    public init(thread: CodingThread, targetProject: WorkspaceProject, physicalWorkspacePath: String) throws {
        sourceProjectID = thread.projectID
        threadCreatedAt = thread.createdAt
        expectedConfiguration = .init(thread: thread)
        self.targetProject = targetProject
        claudeRuntime = try thread.claudeRuntimeConfiguration?.replacingWorkspace(
            targetProject.path, physicalPath: physicalWorkspacePath)
    }
}

extension WorkspaceSnapshot {
    public func canAssignProjectToDraft(threadID: UUID) -> Bool {
        guard let thread = threads.first(where: { $0.id == threadID }),
              let project = projects.first(where: { $0.id == thread.projectID }),
              project.scratch == nil, thread.scratchWorkspace == nil,
              !thread.isArchived, thread.state == .idle, !thread.isBusy, thread.activeRun == nil,
              thread.messages.isEmpty, thread.queuedTurns.isEmpty, (thread.runHistory ?? []).isEmpty,
              thread.providerThreadID == nil, thread.runtimeID == nil, thread.runtimeRequests.isEmpty,
              thread.providerActivity == nil, thread.providerMetadata == nil,
              thread.claudeResumeSelection == nil, thread.claudeResumeConsumerRunID == nil,
              thread.claudeInheritedHead == nil, thread.contextTransferLineage == nil, (thread.contextProviderBindings ?? []).isEmpty,
              thread.forkedFromHistoryOperationID == nil, thread.delegatedTaskLineage == nil,
              thread.createdByAppMCP == nil, thread.transcriptPlanSource == nil,
              thread.pullRequestCheckoutOperationID == nil, thread.workspacePreparation == nil,
              thread.settlement == nil, thread.workspaceLifecycle == nil, workspaceReady(for: thread),
              !isConversationHistoryLocked(threadID: threadID),
              !isCheckpointRestoreLocked(threadID: threadID),
              !isPullRequestCreationLocked(threadID: threadID),
              !isPullRequestCheckoutLocked(threadID: threadID) else { return false }
        guard !(agentSessionImports ?? []).contains(where: { $0.threadID == threadID }),
              !(contextTransfers ?? []).contains(where: { $0.sourceThreadID == threadID || $0.targetThreadID == threadID }),
              !(conversationHistoryOperations ?? []).contains(where: { $0.review.sourceThreadID == threadID || $0.review.targetThreadID == threadID }),
              !(checkpointRestoreOperations ?? []).contains(where: { $0.review.threadID == threadID }),
              !(promptSteerings ?? []).contains(where: { $0.threadID == threadID }),
              !(pullRequestCreations ?? []).contains(where: { $0.sourceThreadID == threadID }),
              !(pullRequestCheckouts ?? []).contains(where: { $0.targetThreadID == threadID }),
              !(delegatedTasks ?? []).contains(where: { $0.parentThreadID == threadID || $0.childThreadID == threadID || $0.request.configurationSourceThreadID == threadID }),
              !(delegatedTaskTransfers ?? []).contains(where: { $0.sourceThreadID == threadID || $0.targetThreadID == threadID }),
              !(scheduler?.tasks ?? []).contains(where: { $0.source.threadID == threadID }),
              !(scheduler?.occurrences ?? []).contains(where: { $0.threadID == threadID }) else { return false }
        return true
    }
}

extension WorkspaceDecision {
    mutating func assignDraftProject(_ assignment: DraftProjectAssignment, thread: inout CodingThread) throws {
        guard snapshot.canAssignProjectToDraft(threadID: thread.id),
              thread.projectID == assignment.sourceProjectID, thread.createdAt == assignment.threadCreatedAt,
              ProviderConfiguration(thread: thread) == assignment.expectedConfiguration,
              let project = snapshot.projects.first(where: { $0.id == assignment.targetProject.id }),
              project == assignment.targetProject, project.scratch == nil, project.clone?.isReady ?? true,
              project.path.hasPrefix("/"), !project.path.contains("://") else {
            throw WorkspaceCommandError("Choose a project in a new chat before sending its first message.")
        }
        for path in [thread.workspacePath, project.path] {
            guard !snapshot.isCheckpointRestoreLocked(path: path),
                  !snapshot.isPullRequestCreationLocked(path: path),
                  !snapshot.isPullRequestCheckoutLocked(path: path),
                  !(snapshot.pullRequestActions ?? []).contains(where: { operation in
                      operation.isWorking && operation.scopePaths.contains { WorkspaceSnapshot.checkpointRestorePathsOverlap(path, $0) }
                  }) else { throw WorkspaceCommandError("Wait for the folder's current operation to finish before choosing this project.") }
        }
        if let previous = thread.claudeRuntimeConfiguration {
            guard let runtime = assignment.claudeRuntime,
                  runtime == (try previous.replacingWorkspace(project.path, physicalPath: runtime.workspacePath)) else {
                throw WorkspaceCommandError("The Claude workspace changed. Choose the project again.")
            }
            thread.claudeRuntimeConfiguration = runtime
        } else if assignment.claudeRuntime != nil {
            throw WorkspaceCommandError("The selected agent changed. Choose the project again.")
        }
        thread.projectID = project.id
        thread.workspacePath = project.path
        thread.draftWorkspaceIntent = nil
        // A displayed CLI default is now a deliberate selection: keep that same
        // model instead of rereading a different folder's default behind the user.
        if thread.codexModelSelectionSource == .cliDefault { thread.codexModelSelectionSource = .explicitModel }
        closeRuntimes.insert(thread.id)
    }
}
