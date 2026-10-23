import Foundation

/// Prepared only on the host; these values are not accepted by the wire codec.
enum RemoteEnvironmentPreparation: Codable, Sendable {
    case none
    case refused
    case project(WorkspaceProject)
    case thread(CodingThread)
    case worktree(RemoteWorktreePreparation)
    case attachments(RemoteAttachmentSubmission)
}

enum RemoteEnvironmentAdmission {
    static func action(_ request: RemoteEnvironmentCommandRequest, preparation: RemoteEnvironmentPreparation,
                       snapshot: WorkspaceSnapshot) throws -> WorkspaceCommand {
        if case .refused = preparation {
            throw WorkspaceCommandError("The remote request was refused before execution. Refresh its target or runtime configuration before trying a new command.")
        }
        switch request.command {
        case .addProject(let id, _, let title):
            guard case .project(let project) = preparation, project.id == id, project.clone == nil,
                  title == nil || project.name == title,
                  !snapshot.projects.contains(where: { $0.id == id || $0.path == project.path }) else { throw stale() }
            return .addProject(project)
        case .createThread(let id, let projectID, let provider, let title, let model, let permission):
            guard case .thread(let thread) = preparation, thread.id == id, thread.projectID == projectID,
                  [.codex, .claude].contains(provider), thread.provider == provider, thread.title == title,
                  thread.model == model, thread.permission == permission,
                  let project = snapshot.projects.first(where: { $0.id == projectID }), project.clone == nil,
                  thread.workspacePath == project.path, thread.messages.isEmpty, thread.activeRun == nil,
                  thread.runtimeID == nil, thread.providerThreadID == nil else { throw stale() }
            return .createThread(thread)
        case .editThread(let id, let edit, let captured):
            try configuration(id, captured: captured, snapshot: snapshot)
            let translated: ThreadEdit
            switch edit { case .draft(let value): translated = .draft(value)
            case .title(let value): translated = .title(value)
            case .model(let value): translated = .model(value)
            case .permission(let value): translated = .permission(value) }
            return .editThread(id, translated)
        case .submit(let id, let text, let captured):
            try configuration(id, captured: captured, snapshot: snapshot)
            guard try target(id, snapshot: snapshot).draftAttachments.isEmpty else { throw stale() }
            return .submit(threadID: id, text: text)
        case .resumeQueue(let id, let captured):
            try configuration(id, captured: captured, snapshot: snapshot)
            return .resumeQueue(threadID: id)
        case .stop(let id, let runID, let runtimeID):
            let thread = try target(id, snapshot: snapshot)
            guard thread.activeRun?.id == runID, thread.runtimeID == runtimeID,
                  thread.activeRun?.stopRequested == false else { throw stale() }
            return .interrupt(threadID: id)
        case .respond(let id, let runID, let runtimeID, let request, let response):
            let thread = try target(id, snapshot: snapshot)
            guard thread.runtimeID == runtimeID, thread.activeRun?.id == runID,
                  thread.runtimeRequests.contains(where: { $0.request == request && !$0.responding }) else { throw stale() }
            return .respond(threadID: id, requestID: request.id, response: response)
        case .prepareWorktree, .retryWorktree, .cancelWorktree, .inspectWorktree, .submitWithAttachments:
            throw stale()
        }
    }
    static func commands(_ request: RemoteEnvironmentCommandRequest, preparation: RemoteEnvironmentPreparation,
                         snapshot: WorkspaceSnapshot) throws -> [EngineCommand] {
        if case .submitWithAttachments(let owner, let text, let configuration, let expectedDraft, let ids) = request.command {
            guard case .attachments(let captured) = preparation, captured.target == owner,
                  owner.environmentID == request.environmentID, let thread = snapshot.threads.first(where: { $0.id == owner.threadID }),
                  !thread.isArchived, thread.projectID == owner.projectID,
                  ProviderConfiguration(thread: thread) == configuration,
                  thread.workspacePath.utf8.elementsEqual(configuration.workspacePath.utf8),
                  try RemoteAttachmentProtocol.payload(thread.draftAttachments) == RemoteAttachmentProtocol.payload(expectedDraft), Set(ids).count == ids.count,
                  captured.records.map(\.attachment.id) == ids,
                  captured.records.allSatisfy({ $0.upload.target == owner && !$0.cancelled && ($0.claimedBy == nil || $0.claimedBy == request.id) }) else { throw stale() }
            do { try AttachmentLimits.validate(expectedDraft + captured.records.map(\.attachment)) } catch { throw stale() }
            let additions = captured.records.map(\.attachment)
            return (additions.isEmpty ? [] : [.client(.addAttachments(threadID: owner.threadID, attachments: additions))]) + [.client(.submit(threadID: owner.threadID, text: text))]
        }
        guard request.command.isWorktreeCommand else { return [.client(try action(request, preparation: preparation, snapshot: snapshot))] }
        if case .refused = preparation { throw stale() }
        let target: RemoteWorkspaceTarget, expectedAttempt: UUID?
        switch request.command {
        case .prepareWorktree(let value, _, let attempt, _, _): target = value; expectedAttempt = attempt
        case .retryWorktree(let value, let attempt), .cancelWorktree(let value, let attempt), .inspectWorktree(let value, let attempt):
            target = value; expectedAttempt = attempt
        default: throw stale()
        }
        let thread = try worktreeTarget(target, environmentID: request.environmentID, snapshot: snapshot)
        if let expectedAttempt { guard thread.workspacePreparation?.id == expectedAttempt else { throw stale() } }
        if case .cancelWorktree = request.command { return [.client(.cancelWorktreePreparation(thread.id))] }
        guard case .worktree(let captured) = preparation,
              captured.threadID == thread.id,
              captured.expectedWorkspacePath.utf8.elementsEqual(thread.workspacePath.utf8),
              captured.expectedAttemptID == thread.workspacePreparation?.id else { throw stale() }
        switch request.command {
        case .prepareWorktree(_, _, let expectedAttempt, let selection, let submodules):
            guard expectedAttempt == thread.workspacePreparation?.id, let native = captured.request, native.selection == selection,
                  native.submodules == submodules else { throw stale() }
            return [.beginWorktreePreparation(threadID: thread.id, request: native, expectedSourcePath: thread.workspacePath,
                previousAttemptID: nil, incarnation: captured.incarnation, reviewSetup: false,
                claudeRuntimeConfiguration: captured.claudeRuntimeConfiguration)]
        case .retryWorktree, .inspectWorktree:
            guard let state = thread.workspacePreparation, state.canRetry else { throw stale() }
            if let result = captured.result {
                guard let plan = state.plan else { throw stale() }
                do { try ThreadWorkspacePreparation.validate(result: result, plan: plan) } catch { throw stale() }
                if case .inspectWorktree = request.command {
                    return [.worktreeRecovered(threadID: thread.id, attemptID: state.id, incarnation: captured.incarnation, result: result)]
                }
                return [.effectResult(.prepareWorktree(threadID: thread.id, plan: plan), .worktreePrepared(result))]
            }
            if case .inspectWorktree = request.command { guard captured.request == nil else { throw stale() }; return [] }
            guard let native = captured.request, native.selection == state.request.selection,
                  native.submodules == state.request.submodules else { throw stale() }
            return [.beginWorktreePreparation(threadID: thread.id, request: native, expectedSourcePath: thread.workspacePath,
                previousAttemptID: state.id, incarnation: captured.incarnation, reviewSetup: false,
                claudeRuntimeConfiguration: captured.claudeRuntimeConfiguration)]
        default: throw stale()
        }
    }
    static func worktreeTarget(_ target: RemoteWorkspaceTarget, environmentID: UUID, snapshot: WorkspaceSnapshot) throws -> CodingThread {
        let thread = try self.target(target.threadID, snapshot: snapshot)
        guard target.environmentID == environmentID, thread.projectID == target.projectID,
              target.workspacePath.utf8.elementsEqual(thread.workspacePath.utf8),
              target.configuration == ProviderConfiguration(thread: thread) else { throw stale() }
        return thread
    }
    private static func configuration(_ id: UUID, captured: ProviderConfiguration, snapshot: WorkspaceSnapshot) throws {
        let thread = try target(id, snapshot: snapshot)
        guard ProviderConfiguration(thread: thread) == captured else { throw stale() }
    }
    private static func target(_ id: UUID, snapshot: WorkspaceSnapshot) throws -> CodingThread {
        guard let thread = snapshot.threads.first(where: { $0.id == id }), !thread.isArchived,
              [.codex, .claude].contains(thread.provider) else { throw stale() }
        return thread
    }
    static func stale() -> WorkspaceCommandError {
        .init("The remote target changed. Refresh its configuration, active run or pending request before acting.")
    }
}

extension WorkspaceDecision {
    @inline(never)
    static func reduceRemoteEnvironment(_ command: EngineCommand, id: UUID, snapshot: WorkspaceSnapshot, now: Date) throws -> Self {
        guard case .remoteEnvironment(let request, let preparation) = command else { throw RemoteEnvironmentAdmission.stale() }
        let commands = try RemoteEnvironmentAdmission.commands(request, preparation: preparation, snapshot: snapshot)
        guard commands.count <= 2 else { throw RemoteEnvironmentAdmission.stale() }
        do {
            var combined = Self(snapshot: snapshot)
            for action in commands {
                let next = try make(action, id: id, snapshot: combined.snapshot, now: now, validatingLedger: false)
                combined.snapshot = next.snapshot; combined.effects += next.effects; combined.closeRuntimes.formUnion(next.closeRuntimes)
                if let cancel = next.cancelCloneAttempt {
                    guard combined.cancelCloneAttempt == nil || combined.cancelCloneAttempt == cancel else { throw RemoteEnvironmentAdmission.stale() }
                    combined.cancelCloneAttempt = cancel
                }
                if let cancel = next.cancelWorktreeAttempt {
                    guard combined.cancelWorktreeAttempt == nil || combined.cancelWorktreeAttempt == cancel else { throw RemoteEnvironmentAdmission.stale() }
                    combined.cancelWorktreeAttempt = cancel
                }
            }
            guard Set(combined.effects.map(\.id)).count == combined.effects.count else { throw RemoteEnvironmentAdmission.stale() }
            return try finalizedRemoteBatch(combined)
        }
        catch let error as WorkspaceCommandError { throw error }
        catch { throw WorkspaceCommandError("The remote request was refused before execution because its values or target are invalid.") }
    }
}
