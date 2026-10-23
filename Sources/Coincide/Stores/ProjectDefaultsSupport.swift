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
        var configuration: ProjectConfiguration?
        if project.clone.map({ !$0.isReady }) != true {
            let path = project.path
            configuration = await Task.detached { () -> ProjectConfiguration? in
                let files = WorkspaceFileService(root: URL(fileURLWithPath: path))
                let value = try? await ProjectConfigurationService.load(using: files).configuration
                await files.close(); return value
            }.value
        }
        return .init(threadEnvironmentMode: ProjectDefaultsResolver.threadEnvironmentMode(project: document.defaultThreadEnvMode,
                                                                                         app: projectSettings.appThreadEnvironmentMode, repository: configuration),
                     worktreeSubmodules: ProjectDefaultsResolver.worktreeSubmodules(project: document.worktreeSubmodules,
                                                                                  app: projectSettings.appWorktreeSubmodules, repository: configuration))
    }
    func projectDefaults(threadID: UUID) async -> ProjectResolvedDefaults? {
        guard let projectID = thread(threadID)?.projectID else { return nil }
        return await projectDefaults(projectID: projectID)
    }
}
