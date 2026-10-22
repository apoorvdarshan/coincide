import Foundation
import Testing
@testable import CoincideCore

private actor SkillEnginePeer: ProviderSession {
    nonisolated let events: AsyncStream<ProviderEvent>
    private let sink: AsyncStream<ProviderEvent>.Continuation
    private let inventory: ProviderSkillInventory
    private let hold: Bool
    private var waiter: CheckedContinuation<Void, Never>?
    private(set) var reloads: [Bool] = []
    private(set) var prompts = 0
    private(set) var closes = 0
    init(path: String, hold: Bool, resultPath: String?) {
        (events, sink) = AsyncStream.makeStream(); self.hold = hold
        inventory = .init(cwd: resultPath ?? path,
            skills: [.init(name: "workspace-skill", path: "display-only/SKILL.md", description: "Transient skill fixture", scope: "repo")],
            problems: [.init(message: "One unavailable fixture source")])
    }
    func models() -> [ProviderModel] { [] }
    func codexSkills(forceReload: Bool) async -> ProviderSkillInventory {
        reloads.append(forceReload)
        if hold { await withCheckedContinuation { waiter = $0 } }
        return inventory
    }
    func send(text: String, thread: CodingThread) {
        prompts += 1
        if let runID = thread.activeRun?.id {
            sink.yield(.context(runID: runID, event: .thread("skill-fixture-session")))
            sink.yield(.context(runID: runID, event: .turn("skill-fixture-turn")))
        }
    }
    func interrupt() {}
    func respond(_ request: ApprovalRequest, allow: Bool) {}
    func answer(_ request: ApprovalRequest, answers: [String: String]) {}
    func close() { closes += 1; sink.finish(); release() }
    func release() { let saved = waiter; waiter = nil; saved?.resume() }
}

private final class SkillEngineFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var captures: [CodingThread] = []
    private var peers: [SkillEnginePeer] = []
    let hold: Bool
    let resultPath: String?
    init(hold: Bool, resultPath: String?) { self.hold = hold; self.resultPath = resultPath }
    func make(_ thread: CodingThread) -> any ProviderSession {
        lock.withLock {
            let peer = SkillEnginePeer(path: thread.workspacePath, hold: hold, resultPath: resultPath)
            captures.append(thread); peers.append(peer); return peer
        }
    }
    var launches: [CodingThread] { lock.withLock { captures } }
    var sessions: [SkillEnginePeer] { lock.withLock { peers } }
}

private struct SkillEngineFixture: Sendable {
    let root: URL
    let engine: WorkspaceEngine
    let factory: SkillEngineFactory
    let project: WorkspaceProject
    let thread: CodingThread
}

private func withSkillEngine(hold: Bool = false, resultPath: String? = nil, owned: Bool = false,
                             _ body: (SkillEngineFixture) async throws -> Void) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-skill-engine-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let project = WorkspaceProject(path: root.path)
    var thread = CodingThread(project: project); thread.checkpointPolicy = .disabled
    if owned {
        thread.codexRuntimeConfiguration = .init(instanceID: UUID(), selection: .custom, executable: "/fixture/codex",
            homeDirectory: root.appendingPathComponent("shared-home").path, authenticationMode: .ownedChatGPT,
            accountBinding: .init(profileID: UUID(), generation: UUID()))
    }
    let factory = SkillEngineFactory(hold: hold, resultPath: resultPath)
    let engine = try WorkspaceEngine(url: root.appendingPathComponent("workspace.sqlite"),
        providerFactory: { factory.make($0) }, identityResolver: { _ in nil })
    do {
        _ = try await engine.load()
        try await engine.dispatch(.addProjectWithThread(project: project, thread: thread))
        try await body(.init(root: root, engine: engine, factory: factory, project: project, thread: thread))
        for peer in factory.sessions { await peer.release() }
        await engine.shutdown()
    } catch {
        for peer in factory.sessions { await peer.release() }
        await engine.shutdown(); throw error
    }
}

private func skillEngineEventually(_ predicate: () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(4)
    while !(await predicate()) {
        guard ContinuousClock.now < deadline else { throw CoincideError("The skill metadata fixture did not reach its expected boundary.") }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@Test(.timeLimit(.minutes(1)))
func providerSkillsEngineDiscoveryIsTransientAndCannotRetargetALiveActor() async throws {
    try await withSkillEngine { f in
        try await f.engine.dispatch(.submit(threadID: f.thread.id, text: "Existing active turn"))
        try await skillEngineEventually { await f.engine.current().snapshot.threads.first?.activeRun?.nativeTurnID != nil }
        let source = try #require(await f.engine.current().snapshot.threads.first)
        let before = await f.engine.current()
        let inventory = try await f.engine.skills(thread: source, forceReload: true)
        let after = await f.engine.current()
        #expect(inventory.cwd == source.workspacePath && inventory.isPartial)
        #expect(inventory.skills.map(\.promptToken) == ["$workspace-skill"])
        #expect(after.sequence == before.sequence && after.snapshot == before.snapshot)
        #expect(f.factory.launches.count == 2)
        let launch = try #require(f.factory.launches.last)
        #expect(launch.id == source.id && launch.providerThreadID == source.providerThreadID)
        #expect(launch.activeRun == nil && launch.runtimeID == nil && launch.queuedTurns.isEmpty && launch.runtimeRequests.isEmpty)
        #expect(launch.codexRuntimeConfiguration == source.codexRuntimeConfiguration)
        let live = try #require(f.factory.sessions.first), metadata = try #require(f.factory.sessions.last)
        let livePrompts = await live.prompts, liveCloses = await live.closes
        let reloads = await metadata.reloads, metadataPrompts = await metadata.prompts, metadataCloses = await metadata.closes
        #expect(livePrompts == 1 && liveCloses == 0)
        #expect(reloads == [true] && metadataPrompts == 0 && metadataCloses == 1)
        let journal = try await WorkspaceDatabase(url: f.root.appendingPathComponent("workspace.sqlite")).journal()
        #expect(!String(describing: journal).contains("Transient skill fixture"))
    }
}

@Test(.timeLimit(.minutes(1)), arguments: ["runtime", "provider", "reopen", "cancel"])
func providerSkillsEngineRejectsRetiredReadsAcrossScopeChanges(change: String) async throws {
    try await withSkillEngine(hold: true) { f in
        let read = Task { try await f.engine.skills(thread: f.thread) }
        do {
            try await skillEngineEventually { await f.factory.sessions.first?.reloads == [false] }
            switch change {
            case "runtime":
                try await f.engine.dispatch(.editThread(f.thread.id, .codexRuntimeConfiguration(
                    .init(instanceID: UUID(), selection: .custom, executable: "/fixture/other-codex"))))
            case "provider": try await f.engine.dispatch(.editThread(f.thread.id, .provider(.claude)))
            case "reopen":
                try await f.engine.dispatch(.removeProject(projectID: f.project.id, expectedThreadIDs: [f.thread.id]))
                await f.engine.awaitProjectRemovalCleanup(projectID: f.project.id)
                try await f.engine.dispatch(.addProjectWithThread(project: f.project, thread: f.thread))
            default: read.cancel()
            }
            for peer in f.factory.sessions { await peer.release() }
            await #expect(throws: CancellationError.self) { try await read.value }
            #expect(await f.factory.sessions.first?.closes == 1)
            #expect(await f.engine.current().error == nil)
        } catch {
            read.cancel(); for peer in f.factory.sessions { await peer.release() }; _ = await read.result
            throw error
        }
    }
}

@Test(.timeLimit(.minutes(1)))
func providerSkillsEngineRejectsForeignWorkspaceAndUnsupportedProviderWithoutMutatingState() async throws {
    try await withSkillEngine(resultPath: "/") { f in
        let before = await f.engine.current()
        do { _ = try await f.engine.skills(thread: f.thread); Issue.record("Foreign skill inventory was accepted.") }
        catch let error as ProviderSkillError { #expect(error.kind == .invalidResponse) }
        let after = await f.engine.current()
        #expect(after.sequence == before.sequence && after.snapshot == before.snapshot)
        try await f.engine.dispatch(.editThread(f.thread.id, .provider(.claude)))
        let current = try #require(await f.engine.current().snapshot.threads.first)
        let count = f.factory.launches.count
        do { _ = try await f.engine.skills(thread: current); Issue.record("Claude was queried through the Codex skill protocol.") }
        catch let error as ProviderSkillError { #expect(error.kind == .unsupported) }
        #expect(f.factory.launches.count == count)
    }
}

@Test(.timeLimit(.minutes(1)))
func providerSkillsEngineAccountLeaseRejectsDiscoveryBeforeFactoryAdmission() async throws {
    try await withSkillEngine(owned: true) { f in
        let configuration = try #require(f.thread.codexRuntimeConfiguration)
        let lease = try await f.engine.beginCodexAuthentication(configuration: configuration)
        do {
            await #expect(throws: WorkspaceCommandError.self) { try await f.engine.skills(thread: f.thread) }
            #expect(f.factory.launches.isEmpty)
            await f.engine.endCodexAuthentication(leaseID: lease)
            #expect(try await f.engine.skills(thread: f.thread).skills.count == 1)
        } catch { await f.engine.endCodexAuthentication(leaseID: lease); throw error }
    }
}
