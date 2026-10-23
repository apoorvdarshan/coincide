import Foundation

/// Prepared only on the host; these values are not accepted by the wire codec.
enum RemoteEnvironmentPreparation: Codable, Sendable {
    case none
    case refused
    case project(WorkspaceProject)
    case thread(CodingThread)
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
        }
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
        let action = try RemoteEnvironmentAdmission.action(request, preparation: preparation, snapshot: snapshot)
        do { return try make(.client(action), id: id, snapshot: snapshot, now: now) }
        catch let error as WorkspaceCommandError { throw error }
        catch { throw WorkspaceCommandError("The remote request was refused before execution because its values or target are invalid.") }
    }
}
