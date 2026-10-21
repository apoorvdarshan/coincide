import Foundation
import Testing
@testable import CoincideCore

private actor RuntimeProvider: ProviderSession {
    nonisolated let events: AsyncStream<ProviderEvent>
    let continuation: AsyncStream<ProviderEvent>.Continuation
    var sent: [String] = []
    var modelsUsed: [String] = []
    var run: UUID?
    var waiting: CheckedContinuation<Void, any Error>?
    var closed = false
    var interrupts = 0
    var receivedAnswers: [String: String] = [:]
    init() { let pair = AsyncStream<ProviderEvent>.makeStream(); events = pair.stream; continuation = pair.continuation }
    func models() -> [ProviderModel] { [.init(id: "fixture", name: "Fixture")] }
    func send(text: String, thread: CodingThread) async throws {
        guard !closed else { throw CoincideError("Fixture session closed") }
        sent.append(text); modelsUsed.append(thread.model); run = thread.activeRun?.id
        emit(.thread("native-\(thread.id)"))
        if text.hasPrefix("approve") || text.hasPrefix("question") {
            let request = text.hasPrefix("question")
                ? ApprovalRequest(id: .string("question"), method: "item/tool/requestUserInput", params: .object(["questions": .array([.object(["id": .string("choice"), "question": .string("Which option?")])])]))
                : ApprovalRequest(id: .string("approval"), method: "item/commandExecution/requestApproval", params: .object(["command": .string("fixture")]))
            emit(.approval(request))
            try await withCheckedThrowingContinuation { waiting = $0 }
        }
        emit(.turn(UUID().uuidString))
        if text.hasPrefix("auto") { finish() }
    }
    func emit(_ event: ProviderEvent, id: UUID? = nil) {
        if let id = id ?? run { continuation.yield(.context(runID: id, event: event)) }
        else { continuation.yield(event) }
    }
    func finish() { emit(.message(.init(role: .assistant, text: "Fixture response"))); emit(.completed(.idle)) }
    func interrupt() { interrupts += 1; emit(.completed(.interrupted)) }
    func respond(_ request: ApprovalRequest, allow: Bool) {
        finish()
        let saved = waiting; waiting = nil; saved?.resume()
    }
    func answer(_ request: ApprovalRequest, answers: [String: String]) { receivedAnswers = answers; respond(request, allow: true) }
    func close() {
        closed = true; let saved = waiting; waiting = nil; saved?.resume(throwing: CancellationError()); continuation.finish()
    }
    func prompts() -> [String] { sent }
    func usedModels() -> [String] { modelsUsed }
    func interruptionCount() -> Int { interrupts }
    func answers() -> [String: String] { receivedAnswers }
    func crash() { continuation.yield(.connectionClosed("Fixture process lost")); continuation.finish() }
}

private final class RuntimeHarness: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UUID: [RuntimeProvider]] = [:]
    func make(_ thread: CodingThread) -> any ProviderSession {
        let value = RuntimeProvider()
        lock.lock(); values[thread.id, default: []].append(value); lock.unlock()
        return value
    }
    func providers(_ id: UUID) -> [RuntimeProvider] { lock.lock(); defer { lock.unlock() }; return values[id] ?? [] }
}
private struct RuntimeFixture {
    var root: URL
    var engine: WorkspaceEngine
    var harness: RuntimeHarness
    var project: WorkspaceProject
    var thread: CodingThread
}
private func withRuntime(_ body: (RuntimeFixture) async throws -> Void) async throws {
    let root = try temporaryWorkspace()
    defer { try? FileManager.default.removeItem(at: root) }
    let harness = RuntimeHarness(), project = WorkspaceProject(path: root.path)
    let thread = CodingThread(project: project)
    let engine = try WorkspaceEngine(url: root.appendingPathComponent("workspace.sqlite"), providerFactory: { harness.make($0) })
    do {
        _ = try await engine.load(); try await engine.dispatch(.addProject(project)); try await engine.dispatch(.createThread(thread))
        try await body(.init(root: root, engine: engine, harness: harness, project: project, thread: thread))
        await engine.shutdown()
    } catch { await engine.shutdown(); throw error }
}
private func waitRuntime(_ condition: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while try await !condition() {
        guard ContinuousClock.now < deadline else { throw CoincideError("Runtime test timed out") }
        try await Task.sleep(for: .milliseconds(10))
    }
}

@Test(.timeLimit(.minutes(1))) func runtimeApprovalsDoNotBlockBehindStartAcknowledgement() async throws {
    try await withRuntime { f in
        try await f.engine.dispatch(.submit(threadID: f.thread.id, text: "approve first"))
        try await waitRuntime { await f.engine.current().snapshot.threads[0].runtimeRequests.count == 1 }
        try await f.engine.dispatch(.respond(threadID: f.thread.id, requestID: .string("approval"), response: .decision(true)))
        try await waitRuntime { await f.engine.current().snapshot.threads[0].state == .idle }
        let thread = await f.engine.current().snapshot.threads[0]
        #expect(thread.activeRun == nil && thread.runtimeRequests.isEmpty)
        #expect(thread.messages.filter { $0.role == .assistant }.count == 1)
        try await Task.sleep(for: .milliseconds(30))
        #expect(await f.engine.current().snapshot.threads[0].state == .idle) // Late turn acknowledgement stays idle.
    }
}

@Test(.timeLimit(.minutes(1))) func runtimeQueuesInOrderAndKeepsCapturedModel() async throws {
    try await withRuntime { f in
        try await f.engine.dispatch(.submit(threadID: f.thread.id, text: "first"))
        try await waitRuntime { await f.harness.providers(f.thread.id).first?.prompts().count == 1 }
        try await f.engine.dispatch(.editThread(f.thread.id, .model("captured")))
        try await f.engine.dispatch(.submit(threadID: f.thread.id, text: "second"))
        try await f.engine.dispatch(.submit(threadID: f.thread.id, text: "third"))
        try await f.engine.dispatch(.editThread(f.thread.id, .model("new preference")))
        #expect(await f.engine.current().snapshot.threads[0].queuedTurns.count == 2)
        let provider = try #require(f.harness.providers(f.thread.id).first)
        await provider.finish()
        try await waitRuntime { await provider.prompts().count == 2 }
        await provider.finish()
        try await waitRuntime { await provider.prompts().count == 3 }
        #expect(await provider.prompts() == ["first", "second", "third"])
        #expect(await provider.usedModels() == ["", "captured", "captured"])
        await provider.finish()
        try await waitRuntime { await f.engine.current().snapshot.threads[0].state == .idle }
        #expect(await f.engine.current().snapshot.threads[0].messages.filter { $0.role == .user }.map(\.text) == ["first", "second", "third"])
    }
}

@Test(.timeLimit(.minutes(1))) func runtimeStopDuringStartupHoldsQueueAndResumeCreatesNewRuntime() async throws {
    try await withRuntime { f in
        try await f.engine.dispatch(.submit(threadID: f.thread.id, text: "approve startup"))
        try await waitRuntime { await f.engine.current().snapshot.threads[0].runtimeRequests.count == 1 }
        try await f.engine.dispatch(.submit(threadID: f.thread.id, text: "second"))
        try await f.engine.dispatch(.interrupt(threadID: f.thread.id))
        try await waitRuntime { await f.engine.current().snapshot.threads[0].state == .interrupted }
        let stopped = await f.engine.current().snapshot.threads[0]
        #expect(stopped.queuePaused && stopped.queuedTurns.map(\.text) == ["second"])
        try await f.engine.dispatch(.resumeQueue(threadID: f.thread.id))
        try await waitRuntime { f.harness.providers(f.thread.id).count == 2 }
        let resumed = try #require(f.harness.providers(f.thread.id).last)
        try await waitRuntime { await resumed.prompts() == ["second"] }
        await resumed.finish()
        try await waitRuntime { await f.engine.current().snapshot.threads[0].state == .idle }
    }
}

@Test(.timeLimit(.minutes(1))) func runtimeDeduplicatesCommandsAndRetainsRejections() async throws {
    try await withRuntime { f in
        let id = UUID(), command = WorkspaceCommand.submit(threadID: f.thread.id, text: "auto once")
        let first = try await f.engine.dispatch(command, id: id)
        try await waitRuntime { await f.engine.current().snapshot.threads[0].state == .idle }
        try await f.engine.dispatch(.editThread(f.thread.id, .title("Newer title")))
        let second = try await f.engine.dispatch(command, id: id)
        #expect(first == second)
        #expect(await f.harness.providers(f.thread.id).first?.prompts() == ["auto once"])
        let badID = UUID()
        await #expect(throws: (any Error).self) { try await f.engine.dispatch(.editThread(f.thread.id, .title("")), id: badID) }
        let database = try WorkspaceDatabase(url: f.root.appendingPathComponent("workspace.sqlite"))
        #expect(try await database.receipt(badID)?.rejection != nil)
        await #expect(throws: (any Error).self) { try await f.engine.dispatch(.editThread(f.thread.id, .title("Different")), id: badID) }
        #expect(await f.engine.current().snapshot.threads[0].title == "Newer title")
    }
}

@Test(.timeLimit(.minutes(1))) func runtimeControlEffectsHaveCapacityWhenStartsAwaitApprovals() async throws {
    try await withRuntime { f in
        var ids = [f.thread.id]
        for _ in 0..<8 { let thread = CodingThread(project: f.project); ids.append(thread.id); try await f.engine.dispatch(.createThread(thread)) }
        for id in ids { try await f.engine.dispatch(.submit(threadID: id, text: "approve capacity")) }
        try await waitRuntime { await f.engine.current().snapshot.threads.filter { !$0.runtimeRequests.isEmpty }.count == 8 }
        for id in ids.prefix(8) { try await f.engine.dispatch(.respond(threadID: id, requestID: .string("approval"), response: .decision(true))) }
        let last = try #require(ids.last)
        try await waitRuntime { await f.engine.current().snapshot.threads.first { $0.id == last }?.runtimeRequests.count == 1 }
        try await f.engine.dispatch(.respond(threadID: last, requestID: .string("approval"), response: .decision(true)))
        try await waitRuntime { await f.engine.current().snapshot.threads.allSatisfy { $0.state == .idle } }
    }
}

@Test func runtimeRejectsStaleEpochsAndLateRunEvents() throws {
    let project = WorkspaceProject(path: "/tmp"), live = UUID(), run = UUID()
    var thread = CodingThread(project: project)
    thread.runtimeID = live; thread.activeRun = .init(id: run, configuration: .init(thread: thread), startedAt: Date()); thread.state = .running
    var value = WorkspaceSnapshot(); value.projects = [project]; value.threads = [thread]
    let wrongEpoch = try WorkspaceDecision.make(.provider(threadID: thread.id, runtimeID: UUID(), event: .completed(.idle)), id: UUID(), snapshot: value, now: Date())
    #expect(wrongEpoch.snapshot == value)
    let wrongRun = try WorkspaceDecision.make(.provider(threadID: thread.id, runtimeID: live, event: .context(runID: UUID(), event: .completed(.idle))), id: UUID(), snapshot: value, now: Date())
    #expect(wrongRun.snapshot == value)
}

@Test(.timeLimit(.minutes(1))) func runtimeNativeInterruptPausesQueueWithoutLosingSession() async throws {
    try await withRuntime { f in
        try await f.engine.dispatch(.submit(threadID: f.thread.id, text: "first"))
        try await waitRuntime { await f.engine.current().snapshot.threads[0].activeRun?.nativeTurnID != nil }
        try await f.engine.dispatch(.submit(threadID: f.thread.id, text: "second"))
        try await f.engine.dispatch(.interrupt(threadID: f.thread.id))
        try await waitRuntime { await f.engine.current().snapshot.threads[0].state == .interrupted }
        let provider = try #require(f.harness.providers(f.thread.id).first)
        #expect(await provider.interruptionCount() == 1)
        try await f.engine.dispatch(.resumeQueue(threadID: f.thread.id))
        try await waitRuntime { await provider.prompts().count == 2 }
        #expect(f.harness.providers(f.thread.id).count == 1)
    }
}

@Test(.timeLimit(.minutes(1))) func runtimeProcessLossPreservesQueueAndConcurrentEdits() async throws {
    try await withRuntime { f in
        try await f.engine.dispatch(.submit(threadID: f.thread.id, text: "first"))
        try await waitRuntime { await f.engine.current().snapshot.threads[0].activeRun?.nativeTurnID != nil }
        try await f.engine.dispatch(.submit(threadID: f.thread.id, text: "second"))
        let provider = try #require(f.harness.providers(f.thread.id).first)
        async let pin = f.engine.dispatch(.editThread(f.thread.id, .pinned(true)))
        async let draft = f.engine.dispatch(.editThread(f.thread.id, .draft("Unsent draft")))
        await provider.crash()
        _ = try await (pin, draft)
        try await waitRuntime { await f.engine.current().snapshot.threads[0].state == .failed }
        let state = await f.engine.current().snapshot.threads[0]
        #expect(state.queuePaused && state.queuedTurns.map(\.text) == ["second"])
        #expect(state.isPinned && state.draft == "Unsent draft" && state.runtimeID == nil)
    }
}

@Test(.timeLimit(.minutes(1))) func runtimeRestartRetainsQueueAndHasExclusiveOwnership() async throws {
    try await withRuntime { f in
        #expect(throws: (any Error).self) { try WorkspaceEngine(url: f.root.appendingPathComponent("workspace.sqlite")) }
        try await f.engine.dispatch(.submit(threadID: f.thread.id, text: "approve restart"))
        try await waitRuntime { await f.engine.current().snapshot.threads[0].runtimeRequests.count == 1 }
        try await f.engine.dispatch(.submit(threadID: f.thread.id, text: "second"))
        await f.engine.shutdown()
        let reopened = try WorkspaceEngine(url: f.root.appendingPathComponent("workspace.sqlite"), providerFactory: { f.harness.make($0) })
        do {
            let state = try await reopened.load().threads[0]
            #expect(state.state == .interrupted && state.activeRun == nil && state.runtimeRequests.isEmpty && state.runtimeID == nil)
            #expect(state.queuePaused && state.queuedTurns.map(\.text) == ["second"])
            let database = try WorkspaceDatabase(url: f.root.appendingPathComponent("workspace.sqlite"))
            #expect(try await database.effects().allSatisfy { $0.status != .pending && $0.status != .running })
            await reopened.shutdown()
        } catch { await reopened.shutdown(); throw error }
    }
}

@Test(.timeLimit(.minutes(1))) func runtimeQuestionsUseDurableResponseEffects() async throws {
    try await withRuntime { f in
        try await f.engine.dispatch(.submit(threadID: f.thread.id, text: "question first"))
        try await waitRuntime { await f.engine.current().snapshot.threads[0].runtimeRequests.count == 1 }
        await #expect(throws: (any Error).self) { try await f.engine.dispatch(.respond(threadID: f.thread.id, requestID: .string("question"), response: .decision(true))) }
        await #expect(throws: (any Error).self) { try await f.engine.dispatch(.respond(threadID: f.thread.id, requestID: .string("question"), response: .answers([:]))) }
        try await f.engine.dispatch(.respond(threadID: f.thread.id, requestID: .string("question"), response: .answers(["choice": "A"])))
        try await waitRuntime { await f.engine.current().snapshot.threads[0].state == .idle }
        #expect(await f.harness.providers(f.thread.id).first?.answers() == ["choice": "A"])
    }
}

@Test func runtimeQueuedEditAndRemovalPreserveExistingDraft() throws {
    let project = WorkspaceProject(path: "/tmp"), thread = CodingThread(project: WorkspaceProject(path: "/tmp"))
    var value = WorkspaceSnapshot(); value.projects = [project]
    var adjusted = thread; adjusted.projectID = project.id; value.threads = [adjusted]
    func decide(_ command: WorkspaceCommand, id: UUID = UUID()) throws { value = try WorkspaceDecision.make(.client(command), id: id, snapshot: value, now: Date()).snapshot }
    try decide(.submit(threadID: thread.id, text: "first"))
    let second = UUID(), third = UUID()
    try decide(.submit(threadID: thread.id, text: "second"), id: second)
    try decide(.submit(threadID: thread.id, text: "third"), id: third)
    try decide(.editThread(thread.id, .draft("Keep my draft")))
    #expect(throws: (any Error).self) { try decide(.editQueued(threadID: thread.id, queuedID: second)) }
    #expect(value.threads[0].draft == "Keep my draft" && value.threads[0].queuedTurns.count == 2)
    try decide(.removeQueued(threadID: thread.id, queuedID: third))
    try decide(.editThread(thread.id, .draft("")))
    try decide(.editQueued(threadID: thread.id, queuedID: second))
    #expect(value.threads[0].draft == "second" && value.threads[0].queuedTurns.isEmpty)
}

@Test(.timeLimit(.minutes(1))) func runtimeRecoversCrashWithoutReplayingProviderEffects() async throws {
    let root = try temporaryWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("workspace.sqlite"), project = WorkspaceProject(path: root.path)
    var thread = CodingThread(project: project)
    let runID = UUID(), configuration = ProviderConfiguration(thread: thread)
    thread.state = .running; thread.activeRun = .init(id: runID, configuration: configuration, startedAt: Date()); thread.runtimeID = UUID()
    thread.queuedTurns = [.init(id: UUID(), text: "Still queued", configuration: configuration, createdAt: Date())]
    var snapshot = WorkspaceSnapshot(); snapshot.projects = [project]; snapshot.threads = [thread]
    let database = try WorkspaceDatabase(url: url)
    _ = try await database.commit(snapshot, event: "fixture.crash", commandID: UUID(), effects: [.init(request: .providerStart(threadID: thread.id, runID: runID, configuration: configuration, prompt: "Do not replay"))])
    _ = try await database.claimNextEffect(workerID: UUID())
    let harness = RuntimeHarness(), engine = try WorkspaceEngine(url: url, providerFactory: { harness.make($0) })
    do {
        let state = try await engine.load().threads[0]
        #expect(state.state == .interrupted && state.queuePaused && state.activeRun == nil && state.runtimeID == nil)
        #expect(state.queuedTurns.map(\.text) == ["Still queued"] && harness.providers(thread.id).isEmpty)
        #expect(try await database.effects().allSatisfy { $0.status == .cancelled })
        await engine.shutdown()
    } catch { await engine.shutdown(); throw error }
}

@Test(.timeLimit(.minutes(1))) func runtimeStopsExecutionWhenEffectOwnershipIsLost() async throws {
    try await withRuntime { f in
        try await f.engine.dispatch(.submit(threadID: f.thread.id, text: "approve lease"))
        try await waitRuntime { await f.engine.current().snapshot.threads[0].runtimeRequests.count == 1 }
        let database = try WorkspaceDatabase(url: f.root.appendingPathComponent("workspace.sqlite"))
        _ = try await database.cancelEffectsAfterProcessLoss(reason: "Fixture lease loss")
        let provider = try #require(f.harness.providers(f.thread.id).first)
        await provider.respond(.init(id: .string("approval"), method: "item/commandExecution/requestApproval", params: .object([:])), allow: true)
        try await waitRuntime { await f.engine.current().error?.contains("lease") == true }
        #expect(try await database.effects().allSatisfy { $0.status == .cancelled })
        await #expect(throws: (any Error).self) { try await f.engine.dispatch(.submit(threadID: f.thread.id, text: "must not execute")) }
    }
}
