import Foundation
import Testing
@testable import CoincideCore

private actor CommandEnginePeer: ProviderSession {
    nonisolated let events: AsyncStream<ProviderEvent>
    private let continuation: AsyncStream<ProviderEvent>.Continuation
    private let inventory: ProviderCommandInventory
    private let held: Bool
    private var waiter: CheckedContinuation<Void, Never>?
    private(set) var reads: [Bool] = []
    private(set) var completedReads = 0
    private(set) var prompts = 0
    private(set) var closes = 0

    init(path: String, held: Bool, resultPath: String?) {
        (events, continuation) = AsyncStream.makeStream()
        self.held = held
        inventory = .init(cwd: resultPath ?? path,
            commands: [.init(name: "native-review", description: "Transient command description")],
            skills: [.init(name: "native-skill", path: "display-only/SKILL.md", nativeID: "actual-native-id")],
            problems: [.init(component: .skills, message: "One synthetic source is unavailable.")])
    }
    func models() -> [ProviderModel] { [] }
    func providerCommands(forceReload: Bool) async throws -> ProviderCommandInventory {
        reads.append(forceReload)
        defer { completedReads += 1 }
        if held {
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    if Task.isCancelled { continuation.resume() } else { waiter = continuation }
                }
            } onCancel: { Task { await self.release() } }
        }
        try Task.checkCancellation()
        return inventory
    }
    func send(text: String, thread: CodingThread) {
        prompts += 1
        if let run = thread.activeRun?.id {
            continuation.yield(.context(runID: run, event: .thread("ses_command_live")))
            continuation.yield(.context(runID: run, event: .turn("msg_command_live")))
        }
    }
    func interrupt() {}
    func respond(_ request: ApprovalRequest, allow: Bool) {}
    func answer(_ request: ApprovalRequest, answers: [String: String]) {}
    func close() { closes += 1; release(); continuation.finish() }
    func release() { let previous = waiter; waiter = nil; previous?.resume() }
}

private final class CommandEngineFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var captured: [CodingThread] = []
    private var owned: [CommandEnginePeer] = []
    let held: Bool
    let resultPath: String?
    init(held: Bool, resultPath: String?) { self.held = held; self.resultPath = resultPath }
    func make(_ thread: CodingThread) -> any ProviderSession {
        lock.withLock {
            let peer = CommandEnginePeer(path: thread.workspacePath, held: held, resultPath: resultPath)
            captured.append(thread); owned.append(peer)
            return peer
        }
    }
    var launches: [CodingThread] { lock.withLock { captured } }
    var peers: [CommandEnginePeer] { lock.withLock { owned } }
}

private struct CommandEngineFixture: Sendable {
    let root: URL
    let engine: WorkspaceEngine
    let factory: CommandEngineFactory
    let project: WorkspaceProject
    let thread: CodingThread
}

private func withCommandEngine(held: Bool = false, resultPath: String? = nil,
                               _ body: (CommandEngineFixture) async throws -> Void) async throws {
    let root = try temporaryWorkspace()
    defer { try? FileManager.default.removeItem(at: root) }
    let project = WorkspaceProject(path: root.path)
    var thread = CodingThread(project: project)
    thread.provider = .claude; thread.checkpointPolicy = .disabled
    let databaseURL = root.appendingPathComponent("workspace.sqlite")
    var snapshot = WorkspaceSnapshot(); snapshot.projects = [project]; snapshot.threads = [thread]
    try await WorkspaceDatabase(url: databaseURL).save(snapshot, event: "Provider command engine fixture")
    let factory = CommandEngineFactory(held: held, resultPath: resultPath)
    let engine = try WorkspaceEngine(url: databaseURL,
        providerFactory: { factory.make($0) }, identityResolver: { _ in nil })
    do {
        _ = try await engine.load()
        try await body(.init(root: root, engine: engine, factory: factory, project: project, thread: thread))
        for peer in factory.peers { await peer.release() }
        await engine.shutdown()
    } catch {
        for peer in factory.peers { await peer.release() }
        await engine.shutdown(); throw error
    }
}

private func commandEngineEventually(_ predicate: () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(4)
    while !(await predicate()) {
        guard ContinuousClock.now < deadline else { throw CoincideError("The command metadata fixture did not reach its owned boundary.") }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@Test(.timeLimit(.minutes(1)))
func providerCommandsEngineUsesSeparateCapturedActorWithoutRetargetingActiveRun() async throws {
    try await withCommandEngine { f in
        try await f.engine.dispatch(.submit(threadID: f.thread.id, text: "An existing foreground input"))
        try await commandEngineEventually { await f.engine.current().snapshot.threads.first?.activeRun?.nativeTurnID != nil }
        let before = await f.engine.current()
        let thread = try #require(before.snapshot.threads.first)
        let inventory = try await f.engine.commands(thread: thread, forceReload: true)
        let after = await f.engine.current()
        #expect(inventory.cwd == thread.workspacePath && inventory.isPartial)
        #expect(inventory.commands.first?.promptToken == "/native-review")
        #expect(inventory.skills.first?.nativeID == "actual-native-id")
        #expect(before.sequence == after.sequence && before.snapshot == after.snapshot)
        #expect(f.factory.launches.count == 2)
        let launch = try #require(f.factory.launches.last)
        #expect(launch.activeRun == nil && launch.runtimeID == nil && launch.providerThreadID == nil)
        #expect(launch.runtimeRequests.isEmpty && launch.queuedTurns.isEmpty)
        #expect(launch.claudeRuntimeConfiguration == thread.claudeRuntimeConfiguration)
        let live = try #require(f.factory.peers.first), metadata = try #require(f.factory.peers.last)
        let prompts = await live.prompts, closes = await live.closes
        let reads = await metadata.reads, completed = await metadata.completedReads
        let metadataCloses = await metadata.closes, metadataPrompts = await metadata.prompts
        #expect(prompts == 1 && closes == 0)
        #expect(reads == [true] && completed == 1 && metadataCloses == 1 && metadataPrompts == 0)
        let journal = try await WorkspaceDatabase(url: f.root.appendingPathComponent("workspace.sqlite")).journal()
        #expect(!String(describing: journal).contains("Transient command description"))
    }
}

@Test(.timeLimit(.minutes(1)), arguments: ["agent", "provider", "reopen", "cancel"])
func providerCommandsEngineFencesChangedCaptureIncarnationAndJoinsCanceledRead(change: String) async throws {
    try await withCommandEngine(held: true) { f in
        let read = Task { try await f.engine.commands(thread: f.thread) }
        do {
            try await commandEngineEventually { await f.factory.peers.first?.reads == [false] }
            switch change {
            case "agent": try await f.engine.dispatch(.editThread(f.thread.id, .agentMode("plan")))
            case "provider": try await f.engine.dispatch(.editThread(f.thread.id, .provider(.codex)))
            case "reopen":
                try await f.engine.dispatch(.removeProject(projectID: f.project.id, expectedThreadIDs: [f.thread.id]))
                await f.engine.awaitProjectRemovalCleanup(projectID: f.project.id)
                // Reuse both public identities with a new conversation.
                // The retired metadata read must not publish into that replacement.
                var replacement = CodingThread(project: f.project); replacement.id = f.thread.id
                try await f.engine.dispatch(.addProjectWithThread(project: f.project, thread: replacement))
            default: read.cancel()
            }
            for peer in f.factory.peers { await peer.release() }
            await #expect(throws: CancellationError.self) { try await read.value }
            let peer = try #require(f.factory.peers.first)
            let completed = await peer.completedReads, closes = await peer.closes, prompts = await peer.prompts
            #expect(completed == 1 && closes == 1 && prompts == 0)
            let current = await f.engine.current()
            #expect(current.error == nil)
            if change == "reopen" {
                let replacement = try #require(current.snapshot.threads.first { $0.id == f.thread.id })
                #expect(replacement.provider == .codex && replacement.messages.isEmpty && replacement.activeRun == nil)
            }
        } catch {
            read.cancel(); for peer in f.factory.peers { await peer.release() }; _ = await read.result
            throw error
        }
    }
}

@Test(.timeLimit(.minutes(1)))
func providerCommandsEngineIdleDiscoveryIsTransientAndForeignInventoryFailsClosed() async throws {
    try await withCommandEngine { f in
        let before = await f.engine.current()
        let inventory = try await f.engine.commands(thread: f.thread)
        let after = await f.engine.current()
        #expect(inventory.commands.count == 1)
        #expect(before.sequence == after.sequence && before.snapshot == after.snapshot)
        let launch = try #require(f.factory.launches.first)
        #expect(launch.claudeRuntimeConfiguration == f.thread.claudeRuntimeConfiguration)
        let peer = try #require(f.factory.peers.first)
        let prompts = await peer.prompts, completed = await peer.completedReads
        #expect(prompts == 0 && completed == 1)
    }
    try await withCommandEngine(resultPath: "/") { f in
        let before = await f.engine.current()
        await #expect(throws: ProviderCommandError(.invalidResponse)) { try await f.engine.commands(thread: f.thread) }
        let after = await f.engine.current()
        #expect(before.sequence == after.sequence && before.snapshot == after.snapshot)
        try await f.engine.dispatch(.editThread(f.thread.id, .provider(.codex)))
        let state = await f.engine.current(), count = f.factory.launches.count
        let unsupported = try #require(state.snapshot.threads.first)
        await #expect(throws: ProviderCommandError(.unsupported)) { try await f.engine.commands(thread: unsupported) }
        #expect(f.factory.launches.count == count)
    }
}
