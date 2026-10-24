import Foundation
@testable import CoincideCore

/// Historical storage fixtures exercise retained decoding, reducer, and adapter
/// contracts without reopening admission of providers removed from the app.
/// WorkspaceDatabase still validates the complete snapshot before persisting it.
func saveLegacyProviderFixture(project: WorkspaceProject, threads: [CodingThread],
                               acpAgents: [ACPAgentConfiguration] = [], at url: URL) async throws {
    var snapshot = WorkspaceSnapshot()
    snapshot.projects = [project]
    snapshot.threads = threads
    snapshot.acpAgents = acpAgents
    let database = try WorkspaceDatabase(url: url)
    try await database.save(snapshot, event: "Historical provider compatibility fixture")
}
