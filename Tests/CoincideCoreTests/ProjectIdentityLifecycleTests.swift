import Foundation
import Testing
@testable import CoincideCore

private actor GroupIdentitySource {
    private var values: [String: RepositoryIdentity] = [:]
    private var held: Set<String> = [], failures: Set<String> = []
    private var pending: [String: [CheckedContinuation<RepositoryIdentity?, any Error>]] = [:]
    private(set) var calls: [String] = []
    private(set) var cancellations: Set<String> = []
    func set(_ path: String, value: RepositoryIdentity?, hold: Bool = false, fail: Bool = false) {
        values[path] = value
        if hold { held.insert(path) } else { held.remove(path) }
        if fail { failures.insert(path) } else { failures.remove(path) }
    }
    func resolve(_ url: URL) async throws -> RepositoryIdentity? {
        let path = url.path; calls.append(path)
        if held.contains(path) {
            // Deliberately ignores cancellation until release, exposing late owner-result races.
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { pending[path, default: []].append($0) }
            } onCancel: { Task { await self.recordCancellation(path) } }
        }
        if failures.contains(path) { throw CoincideError("Deterministic metadata failure") }
        return values[path]
    }
    func release(_ path: String, value: RepositoryIdentity?) {
        held.remove(path); let waiters = pending.removeValue(forKey: path) ?? []
        for waiter in waiters { waiter.resume(returning: value) }
    }
    func failHeld(_ path: String) {
        held.remove(path); let waiters = pending.removeValue(forKey: path) ?? []
        for waiter in waiters { waiter.resume(throwing: CoincideError("Late metadata fixture failure")) }
    }
    func releaseAll() {
        held = []; let waiters = pending; pending = [:]
        for (path, values) in waiters { for waiter in values { waiter.resume(returning: self.values[path]) } }
    }
    private func recordCancellation(_ path: String) { cancellations.insert(path) }
}
private actor GroupLifecycleProbe {
    private(set) var finished = false
    func finish() { finished = true }
}
private actor GroupLifecycleClone: ProjectCloneSession {
    private var waiter: CheckedContinuation<Void, any Error>?
    private var completed = false, cancelled = false
    private(set) var started = false
    func run(onProgress: @escaping @Sendable (GitCloneProgress) async -> Void) async throws {
        started = true
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            if completed { return }
            try await withCheckedThrowingContinuation { (saved: CheckedContinuation<Void, any Error>) in
                if cancelled { saved.resume(throwing: CancellationError()) } else { waiter = saved }
            }
        } onCancel: { Task { await self.cancel() } }
    }
    func isCompleted() -> Bool { completed }
    func succeed() { completed = true; let saved = waiter; waiter = nil; saved?.resume() }
    private func cancel() { cancelled = true; let saved = waiter; waiter = nil; saved?.resume(throwing: CancellationError()) }
}
private struct GroupLifecycleFixture: Sendable {
    let root: URL, engine: WorkspaceEngine, source: GroupIdentitySource, clone: GroupLifecycleClone
    var url: URL { root.appendingPathComponent("workspace.sqlite") }
    func project(_ name: String) throws -> WorkspaceProject {
        let path = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        return WorkspaceProject(path: path.path)
    }
    func identity(_ project: WorkspaceProject, remote: String) throws -> RepositoryIdentity {
        try RepositoryIdentity(remote: #require(RepositoryIdentity.normalizedRemote(remote)), remoteName: "origin", rootPath: project.path, projectRelativePath: "")
    }
}
private func withGroupLifecycle(_ body: (GroupLifecycleFixture) async throws -> Void) async throws {
    let root = try temporaryWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
    let source = GroupIdentitySource(), clone = GroupLifecycleClone()
    let engine = try WorkspaceEngine(url: root.appendingPathComponent("workspace.sqlite"),
        providerFactory: { _ in throw CoincideError("This fixture must not start a provider.") }, cloneFactory: { _ in clone }, identityResolver: { try await source.resolve($0) })
    do {
        _ = try await engine.load()
        try await body(.init(root: root, engine: engine, source: source, clone: clone))
        await source.releaseAll(); await clone.succeed(); await engine.shutdown()
    } catch { await source.releaseAll(); await clone.succeed(); await engine.shutdown(); throw error }
}
private func groupEventually(_ condition: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while try await !condition() {
        guard ContinuousClock.now < deadline else { throw CoincideError("Grouping lifecycle fixture timed out.") }
        try await Task.sleep(for: .milliseconds(10))
    }
}

@Test(.timeLimit(.minutes(1))) func projectIdentityAutomaticallyRefreshesRegistrationAndLoadWithoutChangingThreadOrProjectActivity() async throws {
    try await withGroupLifecycle { f in
        let a = try f.project("a"), b = try f.project("b")
        let identityA = try f.identity(a, remote: "https://github.com/Team/Repo.git"), identityB = try f.identity(b, remote: "git@github.com:Team/Repo.git")
        await f.source.set(a.path, value: identityA); await f.source.set(b.path, value: identityB)
        var thread = CodingThread(project: a); thread.draft = "Preserved unsent draft"
        try await f.engine.dispatch(.addProjectWithThread(project: a, thread: thread)); try await f.engine.dispatch(.addProject(b))
        try await groupEventually { await f.engine.current().snapshot.projectGroups.count == 1 }
        let snapshot = await f.engine.current().snapshot
        #expect(snapshot.projects.map(\.createdAt) == [a.createdAt, b.createdAt] && snapshot.projects.map(\.updatedAt) == [a.updatedAt, b.updatedAt])
        #expect(snapshot.threads == [thread] && snapshot.projectGroups[0].memberProjectIDs == [a.id, b.id])
        let database = try WorkspaceDatabase(url: f.url), count = try await database.journalEventCount()
        #expect(try await f.engine.refreshRepositoryIdentity(projectID: a.id) == identityA)
        #expect(try await database.journalEventCount() == count)
        #expect(try await database.effects().isEmpty)
        #expect(try await database.rebuildProjection().snapshot == snapshot)
        await f.engine.shutdown()
        let changedA = try f.identity(a, remote: "https://github.com/Team/Changed.git")
        await f.source.set(a.path, value: changedA)
        let reopened = try WorkspaceEngine(url: f.url, identityResolver: { try await f.source.resolve($0) })
        do {
            _ = try await reopened.load()
            try await groupEventually { await reopened.current().snapshot.projects.first { $0.id == a.id }?.repositoryIdentity == changedA }
            #expect(await reopened.current().snapshot.threads == [thread])
            #expect(await reopened.current().snapshot.projects.first { $0.id == a.id }?.updatedAt == a.updatedAt)
            await reopened.shutdown()
        } catch { await f.source.releaseAll(); await reopened.shutdown(); throw error }
    }
}

@Test(.timeLimit(.minutes(1))) func identityFailureIsNonfatalAndPreservesKnownMetadataWhileSuccessfulNilClearsIt() async throws {
    try await withGroupLifecycle { f in
        let project = try f.project("nonfatal"), identity = try f.identity(project, remote: "https://github.com/Team/Repo.git")
        await f.source.set(project.path, value: identity)
        try await f.engine.dispatch(.addProject(project))
        _ = try await f.engine.refreshRepositoryIdentity(projectID: project.id)
        let before = await f.engine.current()
        await f.source.set(project.path, value: nil, fail: true)
        await #expect(throws: CoincideError.self) { try await f.engine.refreshRepositoryIdentity(projectID: project.id) }
        let failed = await f.engine.current()
        #expect(failed.snapshot == before.snapshot && failed.error == nil)
        let unrelated = try f.project("unrelated")
        try await f.engine.dispatch(.addProject(unrelated))
        await f.source.set(project.path, value: nil)
        #expect(try await f.engine.refreshRepositoryIdentity(projectID: project.id) == nil)
        let after = await f.engine.current().snapshot
        #expect(after.projects.first { $0.id == project.id }?.repositoryIdentity == nil)
        #expect(after.projects.first { $0.id == project.id }?.updatedAt == project.updatedAt)
        #expect(try await WorkspaceDatabase(url: f.url).effects().isEmpty)
        // A structurally valid result for another folder is also a nonfatal discovery failure.
        let wrong = try RepositoryIdentity(remote: #require(RepositoryIdentity.normalizedRemote("https://github.com/Team/Repo.git")), remoteName: "origin", rootPath: unrelated.path, projectRelativePath: "")
        await f.source.set(project.path, value: wrong)
        await #expect(throws: CoincideError.self) { try await f.engine.refreshRepositoryIdentity(projectID: project.id) }
        #expect(await f.engine.current().error == nil)
        #expect(await f.engine.current().snapshot.projects.first { $0.id == project.id }?.repositoryIdentity == nil)
    }
}

@Test(.timeLimit(.minutes(1))) func projectIdentityRemovalCancelsAndFencesLateDiscoveryAcrossIdenticalProjectAndThreadReaddition() async throws {
    try await withGroupLifecycle { f in
        let project = try f.project("late"), survivor = try f.project("survivor"), thread = CodingThread(project: project)
        let old = try f.identity(project, remote: "https://github.com/Old/Repository.git"), fresh = try f.identity(project, remote: "https://gitlab.com/New/Repository.git")
        await f.source.set(project.path, value: old, hold: true)
        try await f.engine.dispatch(.addProjectWithThread(project: project, thread: thread))
        try await f.engine.dispatch(.addProject(survivor))
        try await groupEventually { await f.source.calls.contains(project.path) }
        try await f.engine.dispatch(.removeProject(projectID: project.id, expectedThreadIDs: [thread.id]))
        let probe = GroupLifecycleProbe()
        let cleanup = Task { await f.engine.awaitProjectRemovalCleanup(projectID: project.id); await probe.finish() }
        try await groupEventually { await f.source.cancellations.contains(project.path) }
        #expect(await probe.finished == false)
        await f.source.set(project.path, value: fresh)
        try await f.engine.dispatch(.addProjectWithThread(project: project, thread: thread))
        try await f.engine.dispatch(.setProjectSortMode(.manual))
        #expect(await f.engine.current().snapshot.projects.map(\.id) == [survivor.id, project.id])
        await f.source.release(project.path, value: old)
        await cleanup.value
        #expect(try await f.engine.refreshRepositoryIdentity(projectID: project.id) == fresh)
        let snapshot = await f.engine.current().snapshot
        #expect(snapshot.projects.first { $0.id == project.id }?.repositoryIdentity == fresh && snapshot.threads == [thread])
        #expect(await f.engine.current().error == nil)
        let journal = try await WorkspaceDatabase(url: f.url).journal()
        #expect(!journal.contains { record in if case .projectUpserted(let value) = record.event { return value.repositoryIdentity == old }; return false })
        #expect(try await WorkspaceDatabase(url: f.url).effects().isEmpty)
    }
}

@Test(.timeLimit(.minutes(1))) func identityShutdownWaitsForCancelledDiscoveryAndNeverPersistsItsLateResult() async throws {
    try await withGroupLifecycle { f in
        let project = try f.project("shutdown"), identity = try f.identity(project, remote: "https://github.com/Team/Repo.git")
        await f.source.set(project.path, value: identity, hold: true)
        try await f.engine.dispatch(.addProject(project))
        try await groupEventually { await f.source.calls.contains(project.path) }
        let probe = GroupLifecycleProbe(), closing = Task { await f.engine.shutdown(); await probe.finish() }
        try await groupEventually { await f.source.cancellations.contains(project.path) }
        #expect(await probe.finished == false)
        await f.source.release(project.path, value: identity)
        await closing.value
        #expect(await probe.finished)
        #expect(try await WorkspaceDatabase(url: f.url).load().projects.first?.repositoryIdentity == nil)
    }
}

@Test(.timeLimit(.minutes(1))) func lateIdentityResolverFailureAfterRemovalIsCancellationAndDoesNotPoisonReaddedProject() async throws {
    try await withGroupLifecycle { f in
        let project = try f.project("late-failure"), identity = try f.identity(project, remote: "https://github.com/Team/Repo.git")
        await f.source.set(project.path, value: identity, hold: true)
        try await f.engine.dispatch(.addProject(project))
        try await groupEventually { await f.source.calls.contains(project.path) }
        let request = Task { try await f.engine.refreshRepositoryIdentity(projectID: project.id) }
        try await f.engine.dispatch(.removeProject(projectID: project.id, expectedThreadIDs: []))
        try await f.engine.dispatch(.setProjectSortMode(.manual))
        await f.source.failHeld(project.path)
        await #expect(throws: CancellationError.self) { try await request.value }
        await f.engine.awaitProjectRemovalCleanup(projectID: project.id)
        #expect(await f.engine.current().snapshot.projects.isEmpty)
        #expect(await f.engine.current().error == nil)
        await f.source.set(project.path, value: identity)
        try await f.engine.dispatch(.addProject(project))
        #expect(try await f.engine.refreshRepositoryIdentity(projectID: project.id) == identity)
        #expect(await f.engine.current().error == nil)
    }
}

@Test(.timeLimit(.minutes(1))) func identityDiscoveryWaitsForCloneReadinessAndAutomaticallyRunsAfterSuccessfulPublication() async throws {
    try await withGroupLifecycle { f in
        let destination = f.root.appendingPathComponent("cloned")
        let plan = try GitClonePlan.prepare(source: "/tmp/grouping-source", destination: destination)
        var project = WorkspaceProject(path: plan.destinationPath); project.clone = .init(plan: plan)
        let thread = CodingThread(project: project), identity = try f.identity(project, remote: "https://github.com/Team/Repo.git")
        await f.source.set(project.path, value: identity)
        try await f.engine.dispatch(.startProjectClone(project: project, thread: thread))
        await #expect(throws: CancellationError.self) { try await f.engine.refreshRepositoryIdentity(projectID: project.id) }
        #expect(await f.source.calls.isEmpty)
        let group = try #require(await f.engine.current().snapshot.projectGroups.first)
        await #expect(throws: WorkspaceCommandError.self) {
            try await f.engine.dispatch(.setProjectGroupCheckout(groupKey: group.key, expectedProjectIDs: group.memberProjectIDs, projectID: project.id))
        }
        try await groupEventually { await f.clone.started }
        await f.clone.succeed()
        try await groupEventually { await f.engine.current().snapshot.projects.first?.repositoryIdentity == identity }
        #expect(await f.source.calls == [project.path])
        #expect(await f.engine.current().snapshot.threads == [thread])
        #expect(await f.engine.current().error == nil)
    }
}
