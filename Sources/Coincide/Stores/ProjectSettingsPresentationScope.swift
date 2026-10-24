import CoincideCore
import Foundation

/// A file CAS cannot detect that repository discovery moved this project's settings
/// into a different namespace. Presentations retain this separate registered scope.
struct ProjectSettingsPresentationScope: Equatable {
    let projectID: UUID
    let createdAt: Date?
    let path: Data
    let candidateKeys: [Data]
    init(project: WorkspaceProject) {
        projectID = project.id; createdAt = project.createdAt; path = Data(project.path.utf8)
        candidateKeys = ProjectSettingsKey.candidates(for: project).map { Data($0.utf8) }
    }
    func matches(_ project: WorkspaceProject?) -> Bool {
        guard let project else { return false }
        return self == Self(project: project)
    }
    static var changedAfterWrite: CoincideError {
        CoincideError("The original settings write may have completed, but this project’s settings identity changed. Reopen project settings to inspect the result before editing again.")
    }
    static var changed: CoincideError {
        CoincideError("This project’s settings identity changed. Close this editor and reopen project settings before saving.")
    }
}
