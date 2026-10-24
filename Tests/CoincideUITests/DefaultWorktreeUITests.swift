import CoincideCore
import Darwin
import Foundation
import Testing
@testable import Coincide

@MainActor private func defaultWorkspaceUIEventually(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while !condition() {
        guard ContinuousClock.now < deadline else { throw CoincideError("The private native workspace choice did not settle.") }
        try await Task.sleep(for: .milliseconds(5))
    }
}
private actor DefaultWorkspaceUINoProvider: ProviderSession {
    nonisolated let events: AsyncStream<ProviderEvent> = AsyncStream { $0.finish() }
    func models() -> [ProviderModel] { [] }
    func send(text: String, thread: CodingThread) throws { throw CoincideError("This private draft-only fixture must not send input.") }
    func interrupt() { }
    func respond(_ request: ApprovalRequest, allow: Bool) { }
    func answer(_ request: ApprovalRequest, answers: [String: String]) { }
    func close() { }
}
@MainActor private struct DefaultWorkspaceUIFixture {
    let root: URL, checkout: URL, database: URL
    let project: WorkspaceProject
    let settings: ProjectSettingsStore
    let defaults: UserDefaults
    let suite: String
    let store: WorkspaceStore
    let engine: WorkspaceEngine
    static func make(repositoryOverride: Bool, earlierThread: Bool, appMode: ProjectThreadEnvironmentMode? = .worktree,
                     legacyIntent: Bool = false) async throws -> Self {
        let physical = try #require(realpath(FileManager.default.temporaryDirectory.path, nil)); defer { free(physical) }
        let root = URL(fileURLWithPath: String(cString: physical)).appendingPathComponent("coincide-default-worktree-ui-" + UUID().uuidString)
        let managed = root.appendingPathComponent("Managed"), checkout = managed.appendingPathComponent("Project")
        let home = root.appendingPathComponent("PrivateHome")
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let git = try #require(ProcessChannel.findExecutable("git"))
        let environment = ["PATH": git.deletingLastPathComponent().path + ":/usr/bin:/bin", "HOME": home.path,
            "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_TERMINAL_PROMPT": "0", "LC_ALL": "C"]
        for arguments in [["init", "--initial-branch=topic-source"], ["config", "user.name", "Private Native Fixture"],
                          ["config", "user.email", "private@example.invalid"], ["config", "commit.gpgsign", "false"]] {
            let result = try await CommandRunner.run(git.path, arguments, cwd: checkout, environment: environment)
            #expect(result.status == 0)
        }
        try Data("source\n".utf8).write(to: checkout.appendingPathComponent("README.txt"))
        if repositoryOverride { try Data(#"{"defaultThreadEnvMode":"worktree","worktreeSubmodules":"none"}"#.utf8).write(to: checkout.appendingPathComponent("t3.json")) }
        for arguments in [["add", "."], ["commit", "-m", "Private native source"]] {
            let result = try await CommandRunner.run(git.path, arguments, cwd: checkout, environment: environment)
            #expect(result.status == 0)
        }
        let project = WorkspaceProject(path: checkout.path), database = root.appendingPathComponent("workspace.sqlite")
        var snapshot = WorkspaceSnapshot(); snapshot.projects = [project]
        if earlierThread || legacyIntent {
            var thread = CodingThread(project: project)
            if legacyIntent {
                // Existing persisted choices remain readable and can still be
                // changed explicitly to the local checkout. New chat admission
                // no longer captures the retired automatic-worktree defaults.
                let captured = try await DraftWorkspaceIntent.captureIfRepository(
                    project: project, threadID: thread.id, threadCreatedAt: thread.createdAt,
                    startFromOrigin: true, submodules: .none)
                thread.draftWorkspaceIntent = captured
            }
            snapshot.threads = [thread]
        }
        _ = try await WorkspaceDatabase(url: database).commit(snapshot, event: "private fixture", commandID: UUID())
        let suite = "coincide-default-worktree-" + UUID().uuidString, defaults = try #require(UserDefaults(suiteName: suite))
        let settings = ProjectSettingsStore(root: ProjectSettingsFiles.root(dataRoot: root), defaults: defaults)
        settings.appThreadEnvironmentMode = appMode
        let engine = try WorkspaceEngine(url: database, providerFactory: { _ in DefaultWorkspaceUINoProvider() }, identityResolver: { _ in nil })
        let store = WorkspaceStore(engine: engine, managedProjectsRoot: managed, projectSettingsStore: settings)
        await store.load()
        return .init(root: root, checkout: checkout, database: database, project: project, settings: settings, defaults: defaults, suite: suite, store: store, engine: engine)
    }
    func cleanup() async {
        await store.shutdown(); defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor @Test func legacyWorktreeDraftKeepsCapturedOriginAndExplicitLocalChoiceSurvivesRestartWithoutChangingDraft() async throws {
    let f = try await DefaultWorkspaceUIFixture.make(repositoryOverride: true, earlierThread: false, legacyIntent: true)
    do {
        #expect(f.settings.newWorktreesStartFromOrigin)
        let created = try #require(f.store.snapshot.threads.first), intent = try #require(created.draftWorkspaceIntent)
        #expect(intent.startFromOrigin && intent.baseBranch == "topic-source" && intent.submodules == .none)
        let source = try Data(contentsOf: f.checkout.appendingPathComponent("README.txt"))
        f.settings.newWorktreesStartFromOrigin = false; f.settings.appThreadEnvironmentMode = .local
        #expect(f.store.thread(created.id)?.draftWorkspaceIntent == intent)
        f.store.setDraft("preserve unsent 🧪 /tmp/source", id: created.id)
        f.store.useCurrentCheckout(threadID: created.id, intentID: intent.id)
        try await defaultWorkspaceUIEventually { f.store.thread(created.id)?.draftWorkspaceIntent == nil }
        #expect(f.store.thread(created.id)?.draft == "preserve unsent 🧪 /tmp/source")
        #expect(f.store.thread(created.id)?.workspacePath == created.workspacePath)
        await f.store.shutdown()
        let engine = try WorkspaceEngine(url: f.database, providerFactory: { _ in DefaultWorkspaceUINoProvider() }, identityResolver: { _ in nil })
        let reopened = WorkspaceStore(engine: engine, projectSettingsStore: ProjectSettingsStore(root: f.settings.root, defaults: f.defaults))
        await reopened.load()
        #expect(reopened.thread(created.id)?.draftWorkspaceIntent == nil)
        #expect(reopened.thread(created.id)?.draft == "preserve unsent 🧪 /tmp/source")
        #expect(reopened.thread(created.id)?.workspacePreparation == nil && reopened.thread(created.id)?.messages.isEmpty == true)
        #expect(try Data(contentsOf: f.checkout.appendingPathComponent("README.txt")) == source)
        await reopened.shutdown(); await f.cleanup()
    } catch { await f.cleanup(); throw error }
}

@MainActor @Test(arguments: [true, false])
func retainedProjectOriginSettingsPersistWithoutChangingNewChatLocalCheckout(value: Bool) async throws {
    let f = try await DefaultWorkspaceUIFixture.make(repositoryOverride: true, earlierThread: false)
    do {
        f.settings.newWorktreesStartFromOrigin = !value
        _ = try await f.settings.update(f.project) { $0.newWorktreesStartFromOrigin = value }
        _ = try await f.settings.update(f.project) { $0.worktreeSubmodules = ProjectWorktreeSubmoduleMode.none }
        let loaded = try ProjectSettingsFiles.load(root: f.settings.root, keys: ProjectSettingsKey.candidates(for: f.project))
        let stored = try #require(loaded)
        #expect(stored.document.newWorktreesStartFromOrigin == value)
        #expect(stored.document.worktreeSubmodules == ProjectWorktreeSubmoduleMode.none)
        f.store.newThread(projectID: f.project.id)
        try await defaultWorkspaceUIEventually { f.store.snapshot.threads.count == 1 }
        let created = try #require(f.store.snapshot.threads.first)
        // The app preference outranks repository defaults, and a managed
        // project's first chat stays on its local checkout.
        #expect(created.draftWorkspaceIntent == nil && created.workspacePath == f.project.path)
        #expect(created.workspacePreparation == nil && created.messages.isEmpty && created.queuedTurns.isEmpty)
        let reloadedSettings = ProjectSettingsStore(root: f.settings.root, defaults: f.defaults)
        #expect(reloadedSettings.newWorktreesStartFromOrigin == !value)
        let reloaded = try ProjectSettingsFiles.load(root: reloadedSettings.root, keys: ProjectSettingsKey.candidates(for: f.project))
        let reread = try #require(reloaded)
        #expect(reread.document.newWorktreesStartFromOrigin == value)
        await f.cleanup()
    } catch { await f.cleanup(); throw error }
}

@MainActor @Test
func defaultWorktreeNeverCapturesIntentForEitherScratchMarker() async throws {
    let f = try await DefaultWorkspaceUIFixture.make(repositoryOverride: true, earlierThread: false)
    do {
        let allocation = try await f.engine.prepareScratchWorkspace(commandID: UUID(), threadID: UUID())
        let projectMarked = CodingThread(project: allocation.project)
        let projectIntent = try await f.store.captureDraftWorkspaceIntent(project: allocation.project, thread: projectMarked)
        #expect(projectIntent == nil)
        var threadMarked = CodingThread(project: f.project)
        threadMarked.scratchWorkspace = allocation.receipt
        let threadIntent = try await f.store.captureDraftWorkspaceIntent(project: f.project, thread: threadMarked)
        #expect(threadIntent == nil)
        await f.cleanup()
    } catch { await f.cleanup(); throw error }
}

@MainActor @Test(arguments: ["first-managed-global", "later-managed-global", "first-managed-project", "local"])
func newChatsCaptureWorktreeIntentOnlyAfterTheFirstManagedChatAndKeepLegacyEmptyThreads(mode: String) async throws {
    let earlier = mode == "later-managed-global", repository = mode == "first-managed-project"
    let f = try await DefaultWorkspaceUIFixture.make(repositoryOverride: repository, earlierThread: earlier, appMode: mode == "local" ? .local : .worktree)
    do {
        let oldIDs = Set(f.store.snapshot.threads.map(\.id))
        #expect(f.store.snapshot.threads.allSatisfy { $0.draftWorkspaceIntent == nil })
        f.store.newThread(projectID: f.project.id)
        try await defaultWorkspaceUIEventually { f.store.snapshot.threads.count == oldIDs.count + 1 }
        let fresh = try #require(f.store.snapshot.threads.first(where: { !oldIDs.contains($0.id) }))
        #expect((fresh.draftWorkspaceIntent != nil) == earlier)
        #expect(fresh.workspacePath == f.project.path)
        #expect(fresh.workspacePreparation == nil && fresh.messages.isEmpty && fresh.queuedTurns.isEmpty)
        #expect(f.store.snapshot.threads.filter { oldIDs.contains($0.id) }.allSatisfy { $0.draftWorkspaceIntent == nil })
        await f.cleanup()
    } catch { await f.cleanup(); throw error }
}
