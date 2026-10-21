import CoincideCore
import Foundation
import Testing
@testable import Coincide

@MainActor @Test(.timeLimit(.minutes(1)))
func movingAProjectGroupPreservesInterleavedUnmovedCheckouts() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-group-move-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let database = root.appendingPathComponent("workspace.sqlite")
    var projects: [WorkspaceProject] = [], identities: [String: RepositoryIdentity] = [:]
    for name in ["A1", "B1", "A2", "B2", "C"] {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var project = WorkspaceProject(path: url.path)
        if name != "C" {
            let remote = try #require(RepositoryIdentity.normalizedRemote("https://example.invalid/Team/" + String(name.prefix(1)) + ".git"))
            let identity = try RepositoryIdentity(remote: remote, remoteName: "origin", rootPath: project.path, projectRelativePath: "")
            project.repositoryIdentity = identity; identities[project.path] = identity
        }
        projects.append(project)
    }
    let resolverValues = identities
    var initial = WorkspaceSnapshot(); initial.projects = projects
    let storage = try WorkspaceDatabase(url: database)
    _ = try await storage.commit(initial, event: "fixture.interleaved-groups", commandID: UUID())
    let engine = try WorkspaceEngine(url: database, identityResolver: { resolverValues[$0.path] })
    let store = WorkspaceStore(engine: engine, managedProjectsRoot: root.appendingPathComponent("Projects"))
    await store.load()
    do {
        store.setProjectSortMode(.manual)
        let deadline = ContinuousClock.now + .seconds(8)
        while store.projectSortMode != .manual {
            guard ContinuousClock.now < deadline else { throw CoincideError("Manual grouping did not settle.") }
            try await Task.sleep(for: .milliseconds(10))
        }
        let groupC = try #require(store.projectGroup(containing: projects[4].id))
        store.moveProjectGroups(fromOffsets: IndexSet(integer: 0), toOffset: 0)
        store.moveProjectGroups(fromOffsets: IndexSet(integer: 0), toOffset: 1)
        // A later accepted command drains the UI command queue before checking the no-op drops.
        store.newThread(projectID: projects[4].id)
        let barrier = ContinuousClock.now + .seconds(8)
        while store.snapshot.threads.count != 1 {
            guard ContinuousClock.now < barrier else { throw CoincideError("Group move barrier did not settle.") }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.snapshot.projects.map(\.id) == projects.map(\.id))
        store.moveProjectGroups(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        let moved = ContinuousClock.now + .seconds(8)
        while store.snapshot.projects.first?.id != projects[4].id {
            guard ContinuousClock.now < moved else { throw CoincideError("Group move did not settle.") }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.snapshot.projects.map(\.id) == [projects[4].id, projects[0].id, projects[1].id, projects[2].id, projects[3].id])
        #expect(store.orderedProjectGroups.first?.key == groupC.key)
        store.setProjectGroupingMode(.separate)
        let separate = ContinuousClock.now + .seconds(8)
        while store.orderedProjectGroups.count != 5 {
            guard ContinuousClock.now < separate else { throw CoincideError("Separate checkout mode did not settle.") }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.orderedProjectGroups.map { $0.representative.id } == [projects[4].id, projects[0].id, projects[1].id, projects[2].id, projects[3].id])
        #expect(store.errorMessage == nil)
        await store.shutdown()
    } catch { await store.shutdown(); throw error }
}
