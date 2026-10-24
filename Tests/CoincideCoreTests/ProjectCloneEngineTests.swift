import Foundation
import Testing
@testable import CoincideCore

/// Deliberately keeps its progress callback after exit so an old process can report late data.
private actor EngineClonePeer: ProjectCloneSession {
    private var completion = false
    private var waiter: CheckedContinuation<Void, any Error>?
    private var progress: (@Sendable (GitCloneProgress) async -> Void)?
    private var cancelled = false
    private(set) var starts = 0
    private(set) var cancellations = 0
    private(set) var inspections = 0

    func run(onProgress: @escaping @Sendable (GitCloneProgress) async -> Void) async throws {
        starts += 1; progress = onProgress
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if cancelled { continuation.resume(throwing: CancellationError()) }
                else { waiter = continuation }
            }
        } onCancel: { Task { await self.cancel() } }
    }
    func isCompleted() -> Bool { inspections += 1; return completion }
    func markCompleted() { completion = true }
    func succeed() {
        completion = true
        let saved = waiter; waiter = nil; saved?.resume()
    }
    func fail(_ message: String = "Deterministic clone failed") {
        let saved = waiter; waiter = nil; saved?.resume(throwing: CoincideError(message))
    }
    func report(_ value: GitCloneProgress) async { await progress?(value) }
    private func cancel() {
        cancelled = true; cancellations += 1
        let saved = waiter; waiter = nil; saved?.resume(throwing: CancellationError())
    }
}

private struct CloneProviderTurn: Sendable {
    let input: ProviderInput
    let model: String
    let permission: PermissionMode
}
private actor CloneEngineProvider: ProviderSession {
    nonisolated let events: AsyncStream<ProviderEvent>
    private let sink: AsyncStream<ProviderEvent>.Continuation
    private var runID: UUID?
    private(set) var turns: [CloneProviderTurn] = []
    init() { let pair = AsyncStream<ProviderEvent>.makeStream(); events = pair.stream; sink = pair.continuation }
    func models() -> [ProviderModel] { [] }
    func send(text: String, thread: CodingThread) throws { try send(input: .init(text: text), thread: thread) }
    func send(input: ProviderInput, thread: CodingThread) throws {
        runID = thread.activeRun?.id
        turns.append(.init(input: input, model: thread.model, permission: thread.permission))
        emit(.thread("clone-fixture-\(thread.id)")); emit(.turn(UUID().uuidString))
    }
    func finish() { emit(.completed(.idle)) }
    func interrupt() { emit(.completed(.interrupted)) }
    func respond(_ request: ApprovalRequest, allow: Bool) { }
    func answer(_ request: ApprovalRequest, answers: [String: String]) { }
    func close() { sink.finish() }
    private func emit(_ event: ProviderEvent) {
        if let runID { sink.yield(.context(runID: runID, event: event)) }
        else { sink.yield(event) }
    }
}

private final class CloneEngineHarness: @unchecked Sendable {
    private let lock = NSLock()
    private var clones: [UUID: EngineClonePeer] = [:]
    private var providers: [UUID: [CloneEngineProvider]] = [:]
    private var createdProviderPaths: [String] = []
    func peer(_ id: UUID) -> EngineClonePeer {
        lock.lock(); defer { lock.unlock() }
        if let existing = clones[id] { return existing }
        let peer = EngineClonePeer(); clones[id] = peer; return peer
    }
    func makeProvider(_ thread: CodingThread) -> any ProviderSession {
        lock.lock(); defer { lock.unlock() }
        let provider = CloneEngineProvider(); providers[thread.id, default: []].append(provider)
        createdProviderPaths.append(thread.workspacePath); return provider
    }
    func sessions(_ threadID: UUID) -> [CloneEngineProvider] {
        lock.lock(); defer { lock.unlock() }; return providers[threadID] ?? []
    }
    func providerPaths() -> [String] { lock.lock(); defer { lock.unlock() }; return createdProviderPaths }
}
private struct CloneEngineFixture {
    let root: URL
    let engine: WorkspaceEngine
    let harness: CloneEngineHarness
    var databaseURL: URL { root.appendingPathComponent("workspace.sqlite") }
    func plan(_ name: String = "checkout") throws -> GitClonePlan {
        try GitClonePlan.prepare(source: "https://example.invalid/native.git", destination: root.appendingPathComponent(name))
    }
    func project(_ plan: GitClonePlan) -> WorkspaceProject {
        var project = WorkspaceProject(path: plan.destinationPath); project.clone = .init(plan: plan); return project
    }
    func start(_ plan: GitClonePlan) async throws -> (WorkspaceProject, CodingThread) {
        let project = project(plan), thread = CodingThread(project: project)
        try await engine.dispatch(.startProjectClone(project: project, thread: thread))
        return (project, thread)
    }
}
private func withCloneEngine(_ body: (CloneEngineFixture) async throws -> Void) async throws {
    let root = try temporaryWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
    let harness = CloneEngineHarness()
    let engine = try WorkspaceEngine(url: root.appendingPathComponent("workspace.sqlite"),
        providerFactory: { harness.makeProvider($0) }, cloneFactory: { harness.peer($0.id) })
    do {
        _ = try await engine.load(); try await body(.init(root: root, engine: engine, harness: harness))
        await engine.shutdown()
    } catch { await engine.shutdown(); throw error }
}
private func waitCloneEngine(_ condition: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while try await !condition() {
        guard ContinuousClock.now < deadline else { throw CoincideError("Clone engine test timed out") }
        try await Task.sleep(for: .milliseconds(10))
    }
}

@Test(.timeLimit(.minutes(1))) func projectCloneGatesTurnsUntilCheckoutAndPreservesFIFOConfigurationAndAttachments() async throws {
    try await withCloneEngine { f in
        let plan = try f.plan(), peer = f.harness.peer(plan.id)
        let (project, thread) = try await f.start(plan)
        try await waitCloneEngine { await peer.starts == 1 }
        let note = try await f.engine.attachments.importData(Data("Frozen first attachment".utf8), name: "context.txt")
        let image = try await f.engine.attachments.importData(attachmentImageData(), name: "queued.png")
        try await f.engine.dispatch(.editThread(thread.id, .model("first-model")))
        try await f.engine.dispatch(.addAttachments(threadID: thread.id, attachments: [note]))
        try await f.engine.dispatch(.submit(threadID: thread.id, text: "first prompt"))
        try await f.engine.dispatch(.editThread(thread.id, .model("second-model")))
        try await f.engine.dispatch(.editThread(thread.id, .permission(.autoAcceptEdits)))
        try await f.engine.dispatch(.addAttachments(threadID: thread.id, attachments: [image]))
        try await f.engine.dispatch(.submit(threadID: thread.id, text: "second prompt"))
        try await f.engine.dispatch(.editThread(thread.id, .model("future-model")))
        try await f.engine.dispatch(.editThread(thread.id, .draft("Unsent composer text")))
        let waiting = await f.engine.current().snapshot
        #expect(!waiting.workspaceReady(for: thread) && waiting.projects.first { $0.id == project.id }?.clone?.isRunning == true)
        #expect(waiting.threads[0].messages.isEmpty && waiting.threads[0].activeRun == nil)
        #expect(waiting.threads[0].queuedTurns.map(\.text) == ["first prompt", "second prompt"])
        #expect(f.harness.sessions(thread.id).isEmpty)

        // This fake publishes no Git checkout; provide its ready local directory so
        // automatic observations truthfully report a non-Git workspace.
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: plan.destinationPath), withIntermediateDirectories: true)
        await peer.succeed()
        try await waitCloneEngine { await f.harness.sessions(thread.id).first?.turns.count == 1 }
        let provider = try #require(f.harness.sessions(thread.id).first)
        let first = try #require(await provider.turns.first)
        #expect(first.input.text.hasPrefix("first prompt") && first.input.text.contains("context.txt") && first.input.text.contains(note.id.uuidString))
        #expect(try await f.engine.attachments.data(for: note) == Data("Frozen first attachment".utf8))
        #expect(first.model == "first-model" && first.permission == .supervised && first.input.images.isEmpty)
        #expect(await f.engine.current().snapshot.threads[0].messages.first?.attachments == [note])
        await provider.finish()
        try await waitCloneEngine { await provider.turns.count == 2 }
        let second = await provider.turns[1]
        #expect(second.input.text.hasPrefix("second prompt") && second.input.text.contains("queued.png"))
        #expect(second.model == "second-model" && second.permission == .autoAcceptEdits)
        #expect(second.input.images.count == 1)
        let secondRunID = try #require(await f.engine.current().snapshot.threads[0].activeRun?.id)
        await provider.finish()
        // Provider idle precedes the automatic post-run observation's durable
        // result. Compare the projection only after this exact run has settled.
        try await waitCloneEngine {
            let snapshot = await f.engine.current().snapshot
            let current = snapshot.threads[0]
            let record = current.runHistory?.first { $0.id == secondRunID }
            return current.state == .idle && current.activeRun == nil && current.queuedTurns.isEmpty &&
                snapshot.providerReady(for: current) && record?.status == .completed &&
                record?.checkpoints?.postRun?.phase == .unavailable &&
                record?.checkpoints?.postRun?.unavailableReason == .notRepository
        }
        let ready = await f.engine.current().snapshot
        #expect(ready.workspaceReady(for: ready.threads[0]) && ready.threads[0].queuedTurns.isEmpty)
        #expect(ready.threads[0].draft == "Unsent composer text")
        #expect(ready.threads[0].messages.filter { $0.role == .user }.map(\.text) == ["first prompt", "second prompt"])
        #expect(ready.threads[0].messages.last(where: { $0.role == .user })?.attachments == [image])
        let database = try WorkspaceDatabase(url: f.databaseURL)
        #expect(try await database.rebuildProjection().snapshot == ready)
    }
}

@Test(.timeLimit(.minutes(1))) func failedCloneKeepsWaitingPromptsAndRetryIgnoresPreviousAttemptProgress() async throws {
    try await withCloneEngine { f in
        let plan = try f.plan(), firstPeer = f.harness.peer(plan.id)
        let (project, thread) = try await f.start(plan)
        try await waitCloneEngine { await firstPeer.starts == 1 }
        try await f.engine.dispatch(.submit(threadID: thread.id, text: "Run after retry"))
        try await f.engine.dispatch(.editThread(thread.id, .draft("Keep my unsent draft")))
        await firstPeer.fail("Fixture remote is unavailable")
        try await waitCloneEngine { await f.engine.current().snapshot.projects[0].clone?.phase == .failed }
        let failed = await f.engine.current().snapshot
        #expect(failed.projects[0].clone?.error?.contains("Fixture remote is unavailable") == true)
        #expect(failed.threads[0].queuedTurns.map(\.text) == ["Run after retry"] && failed.threads[0].messages.isEmpty)
        #expect(f.harness.sessions(thread.id).isEmpty)
        let retry = try f.plan(), retryPeer = f.harness.peer(retry.id)
        try await f.engine.dispatch(.retryProjectClone(projectID: project.id, plan: retry))
        try await waitCloneEngine { await retryPeer.starts == 1 }
        await #expect(throws: (any Error).self) {
            try await f.engine.dispatch(.retryProjectClone(projectID: project.id, plan: retry))
        }
        let newProgress = GitCloneProgress(stage: .receiving, percent: 23, detail: "Current attempt", stalled: false)
        await retryPeer.report(newProgress)
        await firstPeer.report(.init(stage: .checkout, percent: 99, detail: "Stale attempt", stalled: true))
        let running = await f.engine.current().snapshot.projects[0].clone
        #expect(running?.plan.id == retry.id && running?.progress == newProgress)
        #expect(running?.previousPlans.contains(plan) == true && running?.error == nil)
        await retryPeer.succeed()
        try await waitCloneEngine { await f.harness.sessions(thread.id).first?.turns.count == 1 }
        let provider = try #require(f.harness.sessions(thread.id).first)
        #expect(await provider.turns.first?.input.text == "Run after retry")
        #expect(await f.engine.current().snapshot.threads[0].draft == "Keep my unsent draft")
        await provider.finish()
        try await waitCloneEngine { await f.engine.current().snapshot.threads[0].state == .idle }
    }
}

@Test(.timeLimit(.minutes(1))) func cancelledCloneHoldsQueueAndResumeBeforeReadinessDoesNotStartProvider() async throws {
    try await withCloneEngine { f in
        let plan = try f.plan(), peer = f.harness.peer(plan.id)
        let (project, thread) = try await f.start(plan)
        try await waitCloneEngine { await peer.starts == 1 }
        try await f.engine.dispatch(.submit(threadID: thread.id, text: "Preserve through cancellation"))
        try await f.engine.dispatch(.cancelProjectClone(project.id))
        try await waitCloneEngine { await f.engine.current().snapshot.projects[0].clone?.phase == .cancelled }
        #expect(await peer.cancellations == 1)
        let cancelled = await f.engine.current().snapshot.threads[0]
        #expect(cancelled.queuePaused && cancelled.messages.isEmpty && cancelled.queuedTurns.count == 1)
        let retry = try f.plan(), retryPeer = f.harness.peer(retry.id)
        try await f.engine.dispatch(.retryProjectClone(projectID: project.id, plan: retry))
        try await waitCloneEngine { await retryPeer.starts == 1 }
        try await f.engine.dispatch(.resumeQueue(threadID: thread.id))
        #expect(f.harness.sessions(thread.id).isEmpty)
        #expect(await f.engine.current().snapshot.threads[0].activeRun == nil)
        await retryPeer.succeed()
        try await waitCloneEngine { await f.harness.sessions(thread.id).first?.turns.count == 1 }
        let provider = try #require(f.harness.sessions(thread.id).first)
        await provider.finish()
        try await waitCloneEngine { await f.engine.current().snapshot.threads[0].state == .idle }
    }
}

@Test(.timeLimit(.minutes(1))) func cloneStartIsIdempotentAndCanonicalDestinationCannotBeClaimedTwice() async throws {
    try await withCloneEngine { f in
        let plan = try f.plan(), project = f.project(plan), thread = CodingThread(project: project), commandID = UUID()
        let command = WorkspaceCommand.startProjectClone(project: project, thread: thread)
        let first = try await f.engine.dispatch(command, id: commandID)
        try await waitCloneEngine { await f.harness.peer(plan.id).starts == 1 }
        let duplicate = try await f.engine.dispatch(command, id: commandID)
        #expect(first == duplicate)
        let alias = f.root.appendingPathComponent("parent-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: f.root)
        let conflictPlan = try GitClonePlan.prepare(source: plan.source, destination: alias.appendingPathComponent("checkout"))
        #expect(conflictPlan.destinationPath == plan.destinationPath)
        let conflictProject = f.project(conflictPlan), conflictThread = CodingThread(project: conflictProject)
        await #expect(throws: (any Error).self) {
            try await f.engine.dispatch(.startProjectClone(project: conflictProject, thread: conflictThread))
        }
        let state = await f.engine.current().snapshot
        #expect(state.projects.count == 1 && state.threads.count == 1)
        let database = try WorkspaceDatabase(url: f.databaseURL)
        let effects = try await database.effects(commandID: commandID)
        #expect(effects.count == 1 && effects[0].request.projectID == project.id && effects[0].request.threadID == nil)
        #expect(await f.harness.peer(plan.id).starts == 1)
        await f.harness.peer(plan.id).succeed()
        try await waitCloneEngine { await f.engine.current().snapshot.projects[0].clone?.isReady == true }
        try await f.engine.dispatch(.cancelProjectClone(project.id))
        #expect(await f.engine.current().snapshot.projects[0].clone?.phase == .completed)
        #expect(await f.harness.peer(plan.id).cancellations == 0)
    }
}

@Test(.timeLimit(.minutes(1))) func cloneInFlightDoesNotBlockAnotherProjectsProviderOrWorkspaceCommands() async throws {
    try await withCloneEngine { f in
        let plan = try f.plan(), peer = f.harness.peer(plan.id)
        let (_, cloningThread) = try await f.start(plan)
        try await waitCloneEngine { await peer.starts == 1 }
        try await f.engine.dispatch(.submit(threadID: cloningThread.id, text: "Waiting for files"))
        let local = WorkspaceProject(path: f.root.path), live = CodingThread(project: local)
        try await f.engine.dispatch(.addProject(local)); try await f.engine.dispatch(.createThread(live))
        try await f.engine.dispatch(.submit(threadID: live.id, text: "Independent work"))
        try await waitCloneEngine { await f.harness.sessions(live.id).first?.turns.count == 1 }
        try await f.engine.dispatch(.editThread(cloningThread.id, .pinned(true)))
        let provider = try #require(f.harness.sessions(live.id).first)
        #expect(await provider.turns.first?.input.text == "Independent work")
        #expect(f.harness.sessions(cloningThread.id).isEmpty)
        await provider.finish()
        try await waitCloneEngine { await f.engine.current().snapshot.threads.first { $0.id == live.id }?.state == .idle }
        #expect(await f.engine.current().snapshot.threads.first { $0.id == cloningThread.id }?.isPinned == true)
        #expect(await peer.starts == 1)
        try await f.engine.dispatch(.cancelProjectClone((await f.engine.current().snapshot.projects.first { $0.clone != nil })!.id))
        try await waitCloneEngine { await peer.cancellations == 1 }
    }
}

@Test(.timeLimit(.minutes(1))) func cloningWorkspaceRejectsCodexModelDiscoveryBeforeStartingAProcessAndNeutralDiscoveryStillWorks() async throws {
    try await withCloneEngine { f in
        let plan = try f.plan(), peer = f.harness.peer(plan.id)
        let (_, thread) = try await f.start(plan)
        try await waitCloneEngine { await peer.starts == 1 }
        let configured = try #require(await f.engine.current().snapshot.threads.first { $0.id == thread.id })
        #expect(configured.provider == .codex && !FileManager.default.fileExists(atPath: configured.workspacePath))
        await #expect(throws: CoincideError.self) { try await f.engine.models(thread: configured) }
        #expect(f.harness.sessions(thread.id).isEmpty && f.harness.providerPaths().isEmpty)
        #expect(await f.engine.current().error == nil)

        // Global provider discovery has an existing home-directory context, independent of the clone.
        #expect(try await f.engine.models(provider: .codex).isEmpty)
        #expect(f.harness.providerPaths() == [FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path])
        #expect(f.harness.sessions(thread.id).isEmpty)
        await peer.succeed()
        try await waitCloneEngine { await f.engine.current().snapshot.projects[0].clone?.isReady == true }
    }
}

@Test(.timeLimit(.minutes(1))) func cloneRestartPausesWaitingQueueAndNeverReexecutesLostProcess() async throws {
    let root = try temporaryWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("workspace.sqlite"), harness = CloneEngineHarness()
    let plan = try GitClonePlan.prepare(source: "https://example.invalid/native.git", destination: root.appendingPathComponent("checkout"))
    var project = WorkspaceProject(path: plan.destinationPath); project.clone = .init(plan: plan); project.clone?.phase = .running
    var thread = CodingThread(project: project); thread.draft = "Retain unsent text"
    thread.queuedTurns = [.init(id: UUID(), text: "Never replay automatically", configuration: .init(thread: thread), createdAt: Date())]
    var snapshot = WorkspaceSnapshot(); snapshot.projects = [project]; snapshot.threads = [thread]
    let database = try WorkspaceDatabase(url: url)
    _ = try await database.commit(snapshot, event: "fixture.lost-clone", commandID: UUID(),
                                 effects: [.init(id: plan.id, request: .projectClone(projectID: project.id, plan: plan))])
    let engine = try WorkspaceEngine(url: url, providerFactory: { harness.makeProvider($0) }, cloneFactory: { harness.peer($0.id) })
    do {
        let recovered = try await engine.load()
        #expect(recovered.projects[0].clone?.phase == .interrupted)
        #expect(recovered.threads[0].queuePaused && recovered.threads[0].queuedTurns.count == 1)
        #expect(recovered.threads[0].draft == "Retain unsent text" && recovered.threads[0].messages.isEmpty)
        #expect(await harness.peer(plan.id).starts == 0)
        #expect(harness.sessions(thread.id).isEmpty)
        #expect(try await database.effects().allSatisfy { $0.status == .cancelled })
        #expect(try await database.rebuildProjection().snapshot == recovered)
        await engine.shutdown()
    } catch { await engine.shutdown(); throw error }
}

@Test(.timeLimit(.minutes(1))) func cloneRestartReconcilesPublishedCheckoutWithoutRecloningOrAutomaticallySending() async throws {
    let root = try temporaryWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("workspace.sqlite"), harness = CloneEngineHarness()
    let plan = try GitClonePlan.prepare(source: "https://example.invalid/native.git", destination: root.appendingPathComponent("checkout"))
    var project = WorkspaceProject(path: plan.destinationPath); project.clone = .init(plan: plan); project.clone?.phase = .running
    var thread = CodingThread(project: project)
    thread.queuedTurns = [.init(id: UUID(), text: "Send only after explicit resume", configuration: .init(thread: thread), createdAt: Date())]
    var snapshot = WorkspaceSnapshot(); snapshot.projects = [project]; snapshot.threads = [thread]
    let database = try WorkspaceDatabase(url: url)
    _ = try await database.commit(snapshot, event: "fixture.promoted-before-crash", commandID: UUID(),
                                 effects: [.init(id: plan.id, request: .projectClone(projectID: project.id, plan: plan))])
    await harness.peer(plan.id).markCompleted()
    let engine = try WorkspaceEngine(url: url, providerFactory: { harness.makeProvider($0) }, cloneFactory: { harness.peer($0.id) })
    do {
        let recovered = try await engine.load()
        #expect(recovered.projects[0].clone?.phase == .completed && recovered.workspaceReady(for: recovered.threads[0]))
        #expect(recovered.threads[0].queuePaused && recovered.threads[0].messages.isEmpty)
        #expect(await harness.peer(plan.id).starts == 0 && harness.sessions(thread.id).isEmpty)
        try await engine.dispatch(.resumeQueue(threadID: thread.id))
        try await waitCloneEngine { await harness.sessions(thread.id).first?.turns.count == 1 }
        let provider = try #require(harness.sessions(thread.id).first)
        #expect(await provider.turns.first?.input.text == "Send only after explicit resume")
        await provider.finish()
        try await waitCloneEngine { await engine.current().snapshot.threads[0].state == .idle }
        let replayed = try await database.rebuildProjection().snapshot, current = await engine.current().snapshot
        #expect(replayed == current)
        await engine.shutdown()
    } catch { await engine.shutdown(); throw error }
}

@Test(.timeLimit(.minutes(1))) func explicitCloneRetryChecksCompletionBeforeAllocatingAnotherAttempt() async throws {
    try await withCloneEngine { f in
        let plan = try f.plan(), peer = f.harness.peer(plan.id)
        let (project, thread) = try await f.start(plan)
        try await waitCloneEngine { await peer.starts == 1 }
        try await f.engine.dispatch(.submit(threadID: thread.id, text: "Resume after reconciled completion"))
        await peer.fail("Completion acknowledgement was lost")
        try await waitCloneEngine { await f.engine.current().snapshot.projects[0].clone?.phase == .failed }
        await peer.markCompleted()
        try await f.engine.retryProjectClone(project.id)
        try await waitCloneEngine { await f.engine.current().snapshot.projects[0].clone?.isReady == true }
        #expect(await f.engine.current().snapshot.projects[0].clone?.plan == plan)
        #expect(await f.engine.current().snapshot.projects[0].clone?.previousPlans.isEmpty == true)
        #expect(await peer.starts == 1)
        let database = try WorkspaceDatabase(url: f.databaseURL)
        #expect(try await database.effects().filter { $0.request.projectID == project.id }.count == 1)
    }
}

@Test(.timeLimit(.minutes(1))) func cloneCredentialURLsAreRejectedBeforeJournalAndEffectPersistence() async throws {
    try await withCloneEngine { f in
        // Intentionally fake credentials on the reserved .invalid domain exercise persistence refusal.
        let safe = try f.plan(), marker = "fixture-password-do-not-persist"
        let malicious = try JSONDecoder().decode(GitClonePlan.self, from: JSONSerialization.data(withJSONObject: [
            "id": safe.id.uuidString, "source": "https://unit-test:\(marker)@example.invalid/native.git",
            "destinationPath": safe.destinationPath, "stagingPath": safe.stagingPath,
        ]))
        let project = f.project(malicious), thread = CodingThread(project: project)
        await #expect(throws: (any Error).self) {
            try await f.engine.dispatch(.startProjectClone(project: project, thread: thread))
        }
        let snapshot = await f.engine.current().snapshot
        #expect(snapshot.projects.isEmpty && snapshot.threads.isEmpty)
        #expect(await f.engine.current().error == nil)
        let database = try WorkspaceDatabase(url: f.databaseURL)
        #expect(try await database.effects().isEmpty)
        let encoded = try JSONEncoder().encode(snapshot)
        #expect(!String(decoding: encoded, as: UTF8.self).contains(marker))
        for suffix in ["", "-wal"] {
            let file = URL(fileURLWithPath: f.databaseURL.path + suffix)
            if FileManager.default.fileExists(atPath: file.path) { #expect(try Data(contentsOf: file).range(of: Data(marker.utf8)) == nil) }
        }
    }
}

@Test func retriedCloneRejectsAllPreviousAttemptLifecycleEventsAndResults() throws {
    let root = try temporaryWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
    let destination = root.appendingPathComponent("checkout")
    let old = try GitClonePlan.prepare(source: "https://example.invalid/native.git", destination: destination)
    let current = try GitClonePlan.prepare(source: old.source, destination: destination)
    var project = WorkspaceProject(path: current.destinationPath)
    project.clone = .init(plan: current, previousPlans: [old]); project.clone?.phase = .running
    project.clone?.progress = .init(stage: .receiving, percent: 24, detail: "Current attempt")
    var snapshot = WorkspaceSnapshot(); snapshot.projects = [project]; snapshot.threads = [CodingThread(project: project)]
    let events: [EngineCommand] = [
        .cloneStarted(projectID: project.id, attemptID: old.id),
        .cloneProgress(projectID: project.id, attemptID: old.id, progress: .init(stage: .checkout, percent: 100)),
        .effectResult(.projectClone(projectID: project.id, plan: old), .succeeded),
        .effectResult(.projectClone(projectID: project.id, plan: old), .failed("Late old error")),
        .effectResult(.projectClone(projectID: project.id, plan: old), .cancelled),
    ]
    for event in events {
        let decision = try WorkspaceDecision.make(event, id: UUID(), snapshot: snapshot, now: Date())
        #expect(decision.snapshot == snapshot && decision.effects.isEmpty)
    }
}
