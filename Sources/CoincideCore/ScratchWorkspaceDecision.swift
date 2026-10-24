import Foundation

extension WorkspaceDecision {
    /// Snapshot metadata may display a receipt; only the internal, disk-checked
    /// scratch admission can register one or use the reserved root for creation.
    func validateScratchClientCommand(_ action: WorkspaceCommand) throws {
        func reserved(_ path: String) -> Bool {
            snapshot.projects.compactMap(\.scratch).contains { receipt in
                path.utf8.elementsEqual(receipt.rootPath.utf8) || path.hasPrefix(receipt.rootPath + "/")
            }
        }
        func ordinary(_ project: WorkspaceProject) throws {
            guard project.scratch == nil, !reserved(project.path) else { throw ScratchWorkspaceError("Use New Conversation Without a Project for the app-owned scratch root.") }
        }
        switch action {
        case .addProject(let project): try ordinary(project)
        case .addProjectWithThread(let project, let thread), .startProjectClone(let project, let thread):
            try ordinary(project)
            guard thread.scratchWorkspace == nil, !reserved(thread.workspacePath) else { throw ScratchWorkspaceError() }
        case .createThread(let thread):
            guard thread.scratchWorkspace == nil, !reserved(thread.workspacePath),
                  snapshot.projects.first(where: { $0.id == thread.projectID })?.scratch == nil else { throw ScratchWorkspaceError("Allocate this conversation through the owned scratch service.") }
        case .editThread(let id, let edit):
            guard let thread = snapshot.threads.first(where: { $0.id == id }) else { return }
            let path: String?
            switch edit {
            case .workspacePath(let value): path = value
            case .claudeWorkspace(let value): path = value.registeredWorkspacePath
            default: path = nil
            }
            if let path {
                if let receipt = thread.scratchWorkspace {
                    guard path.utf8.elementsEqual(receipt.workspacePath.utf8) else { throw ScratchWorkspaceError("Scratch conversations keep their original folder. Start another conversation to change workspaces.") }
                } else if reserved(path) { throw ScratchWorkspaceError() }
            }
        default: break
        }
    }
}
