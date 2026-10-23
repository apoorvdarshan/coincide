import CoincideCore
import Foundation

struct ProjectResolvedDefaults: Sendable, Equatable {
    let threadEnvironmentMode: ProjectResolvedSetting<ProjectThreadEnvironmentMode>
    let worktreeSubmodules: ProjectResolvedSetting<ProjectWorktreeSubmoduleMode>
}

extension WorkspaceStore {
    /// Resolves repository-declarable defaults for a project: its override, the app default, the
    /// checkout's t3.json, then T3's built-in values. Reading t3.json never executes anything.
    func projectDefaults(projectID: UUID) async -> ProjectResolvedDefaults? {
        guard let project = snapshot.projects.first(where: { $0.id == projectID }) else { return nil }
        let document = await projectSettings.load(project)
        guard projectDefaultsProjectIsCurrent(project) else { return nil }
        let configuration = await projectDefaultsConfiguration(project)
        guard projectDefaultsProjectIsCurrent(project) else { return nil }
        return .init(threadEnvironmentMode: ProjectDefaultsResolver.threadEnvironmentMode(project: document.defaultThreadEnvMode,
                                                                                         app: projectSettings.appThreadEnvironmentMode, repository: configuration),
                     worktreeSubmodules: ProjectDefaultsResolver.worktreeSubmodules(project: document.worktreeSubmodules,
                                                                                  app: projectSettings.appWorktreeSubmodules, repository: configuration))
    }
    func projectDefaults(threadID: UUID) async -> ProjectResolvedDefaults? {
        guard let captured = thread(threadID) else { return nil }
        let result = await projectDefaults(projectID: captured.projectID)
        guard !Task.isCancelled, let current = thread(threadID), current.createdAt == captured.createdAt,
              current.projectID == captured.projectID, current.workspacePath.utf8.elementsEqual(captured.workspacePath.utf8),
              current.workspacePreparation?.id == captured.workspacePreparation?.id else { return nil }
        return result
    }
}
