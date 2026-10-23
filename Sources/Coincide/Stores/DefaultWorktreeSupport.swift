import CoincideCore
import Foundation

extension WorkspaceStore {
    /// Called only when authoring a new native project draft. Existing/imported
    /// threads never infer a workspace intent from a later preference change.
    func captureDraftWorkspaceIntent(project: WorkspaceProject, thread: CodingThread, isNewProject: Bool = false) async throws -> DraftWorkspaceIntent? {
        guard project.scratch == nil, thread.scratchWorkspace == nil else { return nil }
        let appFromOrigin = projectSettings.newWorktreesStartFromOrigin
        let defaults: ProjectResolvedDefaults
        if isNewProject {
            let document = await projectSettings.load(project)
            let files = WorkspaceFileService(root: URL(fileURLWithPath: project.path))
            let file: ProjectConfigurationDocument
            do { file = try await ProjectConfigurationService.load(using: files); await files.close() }
            catch { await files.close(); throw error }
            try Task.checkCancellation()
            defaults = .init(threadEnvironmentMode: ProjectDefaultsResolver.threadEnvironmentMode(project: document.defaultThreadEnvMode,
                app: projectSettings.appThreadEnvironmentMode, repository: file.configuration),
                worktreeSubmodules: ProjectDefaultsResolver.worktreeSubmodules(project: document.worktreeSubmodules,
                app: projectSettings.appWorktreeSubmodules, repository: file.configuration))
        } else {
            guard let value = await projectDefaults(projectID: project.id), projectDefaultsProjectIsCurrent(project) else { throw CancellationError() }
            defaults = value
        }
        guard defaults.threadEnvironmentMode.value == .worktree else { return nil }
        let fromOrigin = projectSettings.document(for: project).newWorktreesStartFromOrigin ?? appFromOrigin
        // Pinned T3 uses Local for the first conversation in a newly managed
        // project when the mode came from the global environment preference.
        if defaults.threadEnvironmentMode.source == .app,
           !snapshot.threads.contains(where: { $0.projectID == project.id }),
           URL(fileURLWithPath: project.path).deletingLastPathComponent().standardizedFileURL.path == managedProjectsRoot.standardizedFileURL.path {
            return nil
        }
        let value = try await DraftWorkspaceIntent.captureIfRepository(project: project, threadID: thread.id, threadCreatedAt: thread.createdAt, startFromOrigin: fromOrigin,
            submodules: defaults.worktreeSubmodules.value)
        try Task.checkCancellation()
        guard isNewProject || projectDefaultsProjectIsCurrent(project) else { throw CancellationError() }
        return value
    }

    func useCurrentCheckout(threadID: UUID, intentID: UUID) {
        guard let thread = thread(threadID), thread.draftWorkspaceIntent?.id == intentID else { return }
        performDraftWorkspaceOverride(.useCurrentCheckout(threadID: threadID, intentID: intentID))
    }
}
