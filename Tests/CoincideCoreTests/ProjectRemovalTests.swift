import CSQLite
import Foundation
import Testing
@testable import CoincideCore

private actor RemovalGate {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if released { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() { released = true; let saved = waiters; waiters = []; for waiter in saved { waiter.resume() } }
}
private actor RemovalCleanupProbe {
    private(set) var started = false
    private(set) var finished = false
    func begin() { started = true }
    func complete() { finished = true }
}
private struct RemovalPolicy: Sendable {
    var holdSend = false
    var holdClose = false
    var holdModels = false
}
private actor RemovalProvider: ProviderSession {
    nonisolated let events: AsyncStream<ProviderEvent>
    private let sink: AsyncStream<ProviderEvent>.Continuation
    private let policy: RemovalPolicy
    private let closeGate = RemovalGate(), modelsGate = RemovalGate()
    private var sendWaiter: CheckedContinuation<Void, any Error>?
    private var sendCancelled = false
    private var runID: UUID?
    private(set) var prompts: [String] = []
    private(set) var closeStarted = 0
    private(set) var closeFinished = false
    private(set) var modelsStarted = 0
    init(policy: RemovalPolicy) {
        self.policy = policy
        let pair = AsyncStream<ProviderEvent>.makeStream(); events = pair.stream; sink = pair.continuation
    }
    func models() async -> [ProviderModel] {
        modelsStarted += 1
        if policy.holdModels { await modelsGate.wait() }
        return [.init(id: "removal-fixture", name: "Removal fixture")]
    }
    func send(text: String, thread: CodingThread) async throws {
        prompts.append(text); runID = thread.activeRun?.id
        emit(.thread("removal-fixture-\(thread.id)")); emit(.turn(UUID().uuidString))
        if policy.holdSend {
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<Void, any Error>) in
                    if sendCancelled { waiter.resume(throwing: CancellationError()) }
                    else { sendWaiter = waiter }
                }
                try Task.checkCancellation()
            } onCancel: { Task { await self.cancelSend() } }
        }
    }
    func finish() { emit(.completed(.idle)) }
    func publish(_ event: ProviderEvent) { emit(event) }
    func interrupt() { cancelSend(); emit(.completed(.interrupted)) }
    func respond(_ request: ApprovalRequest, allow: Bool) { }
    func answer(_ request: ApprovalRequest, answers: [String: String]) { }
    func close() async {
        guard closeStarted == 0 else { return }
        closeStarted = 1; cancelSend(); sink.finish()
        if policy.holdClose { await closeGate.wait() }
        closeFinished = true
    }
    func release() async { await closeGate.release(); await modelsGate.release(); cancelSend() }
    private func cancelSend() {
        sendCancelled = true
        let saved = sendWaiter; sendWaiter = nil; saved?.resume(throwing: CancellationError())
    }
    private func emit(_ event: ProviderEvent) {
        if let runID { sink.yield(.context(runID: runID, event: event)) }
        else { sink.yield(event) }
    }
}
private actor RemovalClone: ProjectCloneSession {
    private let plan: GitClonePlan
    private var waiter: CheckedContinuation<Void, any Error>?
    private var progress: (@Sendable (GitCloneProgress) async -> Void)?
    private var cancelled = false
    private(set) var starts = 0
    private(set) var cancellations = 0
    init(plan: GitClonePlan) { self.plan = plan }
    func run(onProgress: @escaping @Sendable (GitCloneProgress) async -> Void) async throws {
        starts += 1; progress = onProgress
        let staging = URL(fileURLWithPath: plan.stagingPath)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data("Partial checkout bytes owned by the user\n".utf8).write(to: staging.appendingPathComponent("partial.bin"))
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<Void, any Error>) in
                if cancelled { waiter.resume(throwing: CancellationError()) }
                else { self.waiter = waiter }
            }
        } onCancel: { Task { await self.cancel() } }
    }
    func isCompleted() -> Bool { false }
    func reportLateProgress() async { await progress?(.init(stage: .checkout, percent: 100, detail: "Late completion", stalled: false)) }
    func cancel() {
        cancelled = true; cancellations += 1
        let saved = waiter; waiter = nil; saved?.resume(throwing: CancellationError())
    }
}
private final class RemovalHarness: @unchecked Sendable {
    private let lock = NSLock()
    private var policies: [UUID: RemovalPolicy] = [:]
    private var values: [UUID: [RemovalProvider]] = [:]
    private var clones: [UUID: RemovalClone] = [:]
    func configure(_ id: UUID, _ policy: RemovalPolicy) { lock.lock(); defer { lock.unlock() }; policies[id] = policy }
    func make(_ thread: CodingThread) -> any ProviderSession {
        lock.lock(); defer { lock.unlock() }
        let provider = RemovalProvider(policy: policies[thread.id] ?? .init())
        values[thread.id, default: []].append(provider); return provider
    }
    func clone(_ plan: GitClonePlan) -> RemovalClone {
        lock.lock(); defer { lock.unlock() }
        if let clone = clones[plan.id] { return clone }
        let clone = RemovalClone(plan: plan); clones[plan.id] = clone; return clone
    }
    func providers(_ id: UUID) -> [RemovalProvider] { lock.lock(); defer { lock.unlock() }; return values[id] ?? [] }
    func allProviders() -> [RemovalProvider] { lock.lock(); defer { lock.unlock() }; return values.values.flatMap { $0 } }
    func allClones() -> [RemovalClone] { lock.lock(); defer { lock.unlock() }; return Array(clones.values) }
    var count: Int { allProviders().count }
    func releaseAll() async {
        for provider in allProviders() { await provider.release() }
        for clone in allClones() { await clone.cancel() }
    }
}
private struct RemovalFixture {
    let root: URL
    let engine: WorkspaceEngine
    let harness: RemovalHarness
    var databaseURL: URL { root.appendingPathComponent("workspace.sqlite") }
    func project(_ name: String) throws -> WorkspaceProject {
        let folder = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return WorkspaceProject(path: folder.path)
    }
}
private func withRemoval(_ body: (RemovalFixture) async throws -> Void) async throws {
    let root = try temporaryWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
    let harness = RemovalHarness()
    let engine = try WorkspaceEngine(url: root.appendingPathComponent("workspace.sqlite"),
        providerFactory: { harness.make($0) }, cloneFactory: { harness.clone($0) })
    do {
        _ = try await engine.load(); try await body(.init(root: root, engine: engine, harness: harness))
        await harness.releaseAll(); await engine.shutdown()
    } catch { await harness.releaseAll(); await engine.shutdown(); throw error }
}
private func waitRemoval(_ condition: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while try await !condition() {
        guard ContinuousClock.now < deadline else { throw CoincideError("Project removal test timed out") }
        try await Task.sleep(for: .milliseconds(10))
    }
}
private func expectRemovalRejection(_ command: WorkspaceCommand, fixture f: RemovalFixture) async throws {
    let before = await f.engine.current(), database = try WorkspaceDatabase(url: f.databaseURL), id = UUID()
    let eventCount = try await database.journalEventCount()
    await #expect(throws: WorkspaceCommandError.self) { try await f.engine.dispatch(command, id: id) }
    let after = await f.engine.current()
    #expect(after.snapshot == before.snapshot && after.sequence == before.sequence && after.error == nil)
    #expect(try await database.journalEventCount() == eventCount)
    #expect(try await database.receipt(id)?.rejection != nil)
}

@Test(.timeLimit(.minutes(1))) func projectRemovalRejectsStaleOrMalformedConfirmationWithoutStoppingItsLiveProvider() async throws {
    try await withRemoval { f in
        let project = try f.project("confirmed"), first = CodingThread(project: project), archived = CodingThread(project: project)
        try await f.engine.dispatch(.addProjectWithThread(project: project, thread: first))
        try await f.engine.dispatch(.createThread(archived))
        try await f.engine.dispatch(.editThread(archived.id, .archived(true)))
        try await f.engine.dispatch(.submit(threadID: first.id, text: "Keep running while confirmation is open"))
        try await waitRemoval { await f.engine.current().snapshot.threads.first { $0.id == first.id }?.activeRun?.nativeTurnID != nil }
        let provider = try #require(f.harness.providers(first.id).first)
        let appeared = CodingThread(project: project)
        try await f.engine.dispatch(.createThread(appeared))
        for expected in [[first.id, archived.id], [first.id, archived.id, appeared.id, appeared.id], [], [UUID(), archived.id, appeared.id]] {
            try await expectRemovalRejection(.removeProject(projectID: project.id, expectedThreadIDs: expected), fixture: f)
            #expect(await provider.closeStarted == 0)
        }
        #expect(await provider.prompts == ["Keep running while confirmation is open"])
        try await f.engine.dispatch(.editThread(appeared.id, .draft("The new conversation remains editable")))
        #expect(await f.engine.current().snapshot.threads.first { $0.id == appeared.id }?.draft == "The new conversation remains editable")
        await provider.finish()
    }
}

@Test(.timeLimit(.minutes(1))) func projectRemovalCascadesArchivedThreadsReplaysReceiptAndPersistsWithoutDeletingAnyWorkspaceFiles() async throws {
    try await withRemoval { f in
        let project = try f.project("remove"), other = try f.project("survivor")
        let worktree = f.root.appendingPathComponent("worktrees/owned", isDirectory: true)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        let checkoutFile = URL(fileURLWithPath: project.path).appendingPathComponent("user.txt"), worktreeFile = worktree.appendingPathComponent("uncommitted.txt")
        let checkoutBytes = Data("Checkout: user edits 🌍\n".utf8), worktreeBytes = Data([0, 3, 5, 255, 13, 10])
        try checkoutBytes.write(to: checkoutFile); try worktreeBytes.write(to: worktreeFile)
        var active = CodingThread(project: project); active.workspacePath = worktree.path
        let archived = CodingThread(project: project), survivor = CodingThread(project: other)
        try await f.engine.dispatch(.addProjectWithThread(project: project, thread: CodingThread(project: project)))
        let initialID = try #require(await f.engine.current().snapshot.threads.first?.id)
        try await f.engine.dispatch(.createThread(active)); try await f.engine.dispatch(.createThread(archived))
        try await f.engine.dispatch(.editThread(archived.id, .archived(true)))
        try await f.engine.dispatch(.addProjectWithThread(project: other, thread: survivor))
        try await f.engine.dispatch(.setProjectSortMode(.manual))
        try await f.engine.dispatch(.setProjectExpanded(projectID: project.id, expanded: false))
        try await f.engine.dispatch(.setProjectExpanded(projectID: other.id, expanded: false))
        let attachmentBytes = Data("Recovery attachment must remain\n".utf8)
        let attachment = try await f.engine.attachments.importData(attachmentBytes, name: "recovery.txt")
        try await f.engine.dispatch(.addAttachments(threadID: active.id, attachments: [attachment]))
        try await f.engine.dispatch(.editThread(active.id, .draft("Removed only from the current workspace")))
        let before = await f.engine.current().snapshot, id = UUID()
        let command = WorkspaceCommand.removeProject(projectID: project.id, expectedThreadIDs: [archived.id, initialID, active.id])
        let receipt = try await f.engine.dispatch(command, id: id)
        await f.engine.awaitProjectRemovalCleanup(projectID: project.id)
        let removed = await f.engine.current().snapshot
        #expect(removed.projects == [other] && removed.threads == before.threads.filter { $0.projectID != project.id })
        #expect(removed.effectiveSidebarPreferences == SidebarPreferences(sortMode: .manual, collapsedProjectIDs: [other.id]))
        #expect(try Data(contentsOf: checkoutFile) == checkoutBytes && Data(contentsOf: worktreeFile) == worktreeBytes)
        #expect(try await f.engine.attachments.data(for: attachment) == attachmentBytes)
        try await f.engine.dispatch(.editThread(survivor.id, .draft("A newer surviving draft")))
        let newer = await f.engine.current()
        #expect(try await f.engine.dispatch(command, id: id) == receipt)
        #expect(await f.engine.current().snapshot == newer.snapshot)
        #expect(await f.engine.current().sequence == newer.sequence)
        do {
            try await f.engine.dispatch(.removeProject(projectID: other.id, expectedThreadIDs: [survivor.id]), id: id)
            Issue.record("A removal command identity accepted another project's payload.")
        } catch WorkspaceCommitError.commandIDCollision { }
        try await expectRemovalRejection(command, fixture: f)
        let expected = await f.engine.current().snapshot, database = try WorkspaceDatabase(url: f.databaseURL)
        let events = try await database.journal().filter { $0.commandID == id }
        #expect(events.filter { if case .threadRemoved = $0.event { true } else { false } }.count == 3)
        #expect(events.filter { if case .projectRemoved = $0.event { true } else { false } }.count == 1)
        #expect(try await database.rebuildProjection().snapshot == expected)
        // Removal is not secure erasure: preceding history and attachment references remain recoverable.
        #expect(try await database.journal().contains { if case .threadMetadataUpserted(let thread) = $0.event { thread.draft == "Removed only from the current workspace" } else { false } })
        await f.engine.shutdown()
        let reopened = try WorkspaceEngine(url: f.databaseURL, providerFactory: { f.harness.make($0) })
        do {
            #expect(try await reopened.load() == expected)
            #expect(try await reopened.dispatch(command, id: id) == receipt)
            #expect(try await reopened.attachments.data(for: attachment) == attachmentBytes)
            await reopened.shutdown()
        } catch { await reopened.shutdown(); throw error }
        #expect(try Data(contentsOf: checkoutFile) == checkoutBytes && Data(contentsOf: worktreeFile) == worktreeBytes)
        #expect(f.harness.count == 0)
    }
}

@Test(.timeLimit(.minutes(1))) func emptyProjectRemovalAcceptsEmptyConfirmationAndLeavesOtherProjectsAndSavedSortModeUntouched() async throws {
    try await withRemoval { f in
        let empty = try f.project("empty"), first = try f.project("first"), last = try f.project("last")
        for project in [first, empty, last] { try await f.engine.dispatch(.addProject(project)) }
        try await f.engine.dispatch(.setProjectSortMode(.createdAt))
        try await f.engine.dispatch(.setProjectExpanded(projectID: empty.id, expanded: false))
        let command = WorkspaceCommand.removeProject(projectID: empty.id, expectedThreadIDs: []), id = UUID()
        let receipt = try await f.engine.dispatch(command, id: id)
        await f.engine.awaitProjectRemovalCleanup(projectID: empty.id)
        let removed = await f.engine.current().snapshot
        #expect(removed.projects == [first, last] && removed.threads.isEmpty)
        #expect(removed.effectiveSidebarPreferences == SidebarPreferences(sortMode: .createdAt))
        #expect(FileManager.default.fileExists(atPath: empty.path) && f.harness.count == 0)
        #expect(try await f.engine.dispatch(command, id: id) == receipt)
        try await expectRemovalRejection(command, fixture: f)
        let database = try WorkspaceDatabase(url: f.databaseURL)
        #expect(try await database.effects().isEmpty)
        #expect(try await database.rebuildProjection().snapshot == removed)
    }
}

@Test func removalTransactionRollsBackPendingCancellationAndPreservesRunningLeaseUntilItsOwnerSettles() async throws {
    let root = try temporaryWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
    let project = WorkspaceProject(path: root.appendingPathComponent("remove").path), other = WorkspaceProject(path: root.appendingPathComponent("keep").path)
    let first = CodingThread(project: project), second = CodingThread(project: project), survivor = CodingThread(project: other)
    var snapshot = WorkspaceSnapshot(); snapshot.projects = [project, other]; snapshot.threads = [first, second, survivor]
    snapshot.sidebarPreferences = .init(sortMode: .manual, collapsedProjectIDs: [project.id])
    let url = root.appendingPathComponent("workspace.sqlite"), database = try WorkspaceDatabase(url: url)
    let running = PendingWorkspaceEffect(request: .providerInterrupt(threadID: first.id, runID: UUID()))
    let pending = PendingWorkspaceEffect(request: .providerInterrupt(threadID: second.id, runID: UUID()))
    let unrelated = PendingWorkspaceEffect(request: .providerInterrupt(threadID: survivor.id, runID: UUID()))
    _ = try await database.commit(snapshot, event: "fixture", commandID: UUID(), effects: [running, pending, unrelated])
    let worker = UUID(), leased = try #require(try await database.claimNextEffect(workerID: worker))
    #expect(leased.id == running.id)
    let before = try await database.revision(), effectsBefore = try await database.effects(), count = try await database.journalEventCount(), commandID = UUID()
    let decision = try WorkspaceDecision.make(.client(.removeProject(projectID: project.id, expectedThreadIDs: [second.id, first.id])), id: commandID, snapshot: snapshot, now: Date())
    try removalSQL(url, "CREATE TRIGGER fail_removal BEFORE INSERT ON events BEGIN SELECT RAISE(ABORT,'removal transaction fixture'); END")
    await #expect(throws: (any Error).self) {
        try await database.commit(decision.snapshot, event: "project.remove", commandID: commandID, expectedSequence: before.sequence)
    }
    #expect(try await database.revision() == before)
    #expect(try await database.effects() == effectsBefore)
    #expect(try await database.journalEventCount() == count)
    #expect(try await database.receipt(commandID) == nil)
    #expect(try await WorkspaceDatabase(url: url).load() == before.snapshot)
    try removalSQL(url, "DROP TRIGGER fail_removal")
    _ = try await database.commit(decision.snapshot, event: "project.remove", commandID: commandID, expectedSequence: before.sequence)
    let effects = try await database.effects()
    #expect(effects.first { $0.id == running.id } == leased)
    #expect(effects.first { $0.id == pending.id }?.status == .cancelled)
    #expect(effects.first { $0.id == unrelated.id } == effectsBefore.first { $0.id == unrelated.id })
    #expect(try await database.cancelEffect(running.id, workerID: worker, reason: "Removed project cleanup"))
    #expect(try await database.claimNextEffect(workerID: UUID())?.id == unrelated.id)
    #expect(try await database.rebuildProjection().snapshot == decision.snapshot)
}

@Test(.timeLimit(.minutes(1))) func removingProjectCancelsRunningAndPendingProviderStartsWithoutStartingQueuedWorkOrStoppingAnotherProject() async throws {
    try await withRemoval { f in
        let project = try f.project("many-running"), other = try f.project("unrelated")
        let threads = (0..<10).map { _ in CodingThread(project: project) }, survivor = CodingThread(project: other)
        try await f.engine.dispatch(.addProject(project))
        try await f.engine.dispatch(.addProjectWithThread(project: other, thread: survivor))
        for thread in threads {
            f.harness.configure(thread.id, .init(holdSend: true))
            try await f.engine.dispatch(.createThread(thread))
            try await f.engine.dispatch(.submit(threadID: thread.id, text: "Gated start \(thread.id)"))
        }
        let database = try WorkspaceDatabase(url: f.databaseURL)
        try await waitRemoval {
            let effects = try await database.effects().filter { if case .providerStart = $0.request { true } else { false } }
            let providers = f.harness.allProviders()
            guard effects.filter({ $0.status == .running }).count == 8,
                  effects.filter({ $0.status == .pending }).count == 2, providers.count == 8 else { return false }
            for provider in providers { if await provider.prompts.count != 1 { return false } }
            return true
        }
        let madeBefore = f.harness.count
        #expect(madeBefore == 8)
        try await f.engine.dispatch(.submit(threadID: threads[0].id, text: "Must never become a second provider send"))
        try await f.engine.dispatch(.removeProject(projectID: project.id, expectedThreadIDs: threads.map(\.id)))
        await f.engine.awaitProjectRemovalCleanup(projectID: project.id)
        #expect(f.harness.count == madeBefore)
        #expect(await f.engine.current().snapshot.projects == [other])
        #expect(await f.engine.current().error == nil)
        let cancelled = try await database.effects().filter { if case .providerStart = $0.request { true } else { false } }
        #expect(cancelled.count == 10 && cancelled.allSatisfy { $0.status == .cancelled })
        for provider in f.harness.allProviders() {
            #expect(await provider.closeFinished)
            #expect(await provider.prompts.count == 1)
        }
        try await f.engine.dispatch(.submit(threadID: survivor.id, text: "Unrelated work still starts"))
        try await waitRemoval { await f.harness.providers(survivor.id).first?.prompts == ["Unrelated work still starts"] }
        let provider = try #require(f.harness.providers(survivor.id).first)
        #expect(await provider.closeStarted == 0)
        await provider.finish()
    }
}

@Test(.timeLimit(.minutes(1))) func removalCleanupWaitsForEveryDetachedRuntimeWhileUnrelatedCommandsRemainResponsive() async throws {
    try await withRemoval { f in
        let project = try f.project("slow-close"), other = try f.project("keep-open")
        let first = CodingThread(project: project), second = CodingThread(project: project), survivor = CodingThread(project: other)
        try await f.engine.dispatch(.addProjectWithThread(project: project, thread: first))
        try await f.engine.dispatch(.createThread(second))
        try await f.engine.dispatch(.addProjectWithThread(project: other, thread: survivor))
        for thread in [first, second] {
            f.harness.configure(thread.id, .init(holdClose: true))
            try await f.engine.dispatch(.submit(threadID: thread.id, text: "Owned live runtime"))
        }
        try await waitRemoval { await f.engine.current().snapshot.threads.filter { $0.projectID == project.id }.allSatisfy { $0.activeRun?.nativeTurnID != nil } }
        let providers = [try #require(f.harness.providers(first.id).first), try #require(f.harness.providers(second.id).first)]
        let id = UUID(), command = WorkspaceCommand.removeProject(projectID: project.id, expectedThreadIDs: [first.id, second.id])
        let receipt = try await f.engine.dispatch(command, id: id)
        for provider in providers { try await waitRemoval { await provider.closeStarted == 1 } }
        let probe = RemovalCleanupProbe()
        let cleanup = Task { await probe.begin(); await f.engine.awaitProjectRemovalCleanup(projectID: project.id); await probe.complete() }
        try await waitRemoval { await probe.started }
        #expect(await f.engine.current().snapshot.projects == [other])
        // A close gate cannot hold the serial command inbox or another project's execution.
        try await f.engine.dispatch(.editThread(survivor.id, .draft("Edited while two processes close")))
        try await f.engine.dispatch(.submit(threadID: survivor.id, text: "Independent provider starts while cleanup waits"))
        try await waitRemoval { await f.harness.providers(survivor.id).first?.prompts.count == 1 }
        #expect(try await f.engine.dispatch(command, id: id) == receipt)
        #expect(await probe.finished == false)
        for provider in providers { #expect(await provider.closeFinished == false) }
        for provider in providers { await provider.release() }
        await cleanup.value
        #expect(await probe.finished)
        for provider in providers { #expect(await provider.closeStarted == 1); #expect(await provider.closeFinished) }
        #expect(await f.engine.current().error == nil)
        let survivorProvider = try #require(f.harness.providers(survivor.id).first)
        #expect(await survivorProvider.closeStarted == 0)
        await survivorProvider.finish()
    }
}

@Test(.timeLimit(.minutes(1))) func removalClosesOwnedModelDiscoveryRejectsLateResultsAfterSameIDsReopenAndKeepsNeutralDiscoveryAvailable() async throws {
    try await withRemoval { f in
        let project = try f.project("models"), thread = CodingThread(project: project)
        try await f.engine.dispatch(.addProjectWithThread(project: project, thread: thread))
        f.harness.configure(thread.id, .init(holdModels: true))
        let models = Task { try await f.engine.models(thread: thread) }
        try await waitRemoval { await f.harness.providers(thread.id).first?.modelsStarted == 1 }
        let metadata = try #require(f.harness.providers(thread.id).first)
        try await f.engine.dispatch(.removeProject(projectID: project.id, expectedThreadIDs: [thread.id]))
        await f.engine.awaitProjectRemovalCleanup(projectID: project.id)
        #expect(await metadata.closeFinished)
        let beforeStale = f.harness.count
        await #expect(throws: (any Error).self) { try await f.engine.models(thread: thread) }
        #expect(f.harness.count == beforeStale)
        // Reopening the folder with the same UUIDs must not restore the retired metadata token.
        try await f.engine.dispatch(.addProjectWithThread(project: project, thread: thread))
        #expect(await f.engine.current().snapshot.projects == [project])
        #expect(await f.engine.current().snapshot.threads == [thread])
        #expect(try await f.engine.models(provider: .codex).map(\.id) == ["removal-fixture"])
        await metadata.release()
        await #expect(throws: CancellationError.self) { try await models.value }
        #expect(await f.engine.current().snapshot.projects == [project])
        #expect(f.harness.providers(thread.id).count == 1)
        #expect(await f.engine.current().error == nil)
    }
}

@Test(.timeLimit(.minutes(1))) func removingRunningCloneCancelsItsOwnedTaskIgnoresLateAttemptsAndPreservesCheckoutStagingAndAttachments() async throws {
    try await withRemoval { f in
        let plan = try GitClonePlan.prepare(source: "https://example.invalid/native.git", destination: f.root.appendingPathComponent("checkout"))
        var project = WorkspaceProject(path: plan.destinationPath); project.clone = .init(plan: plan)
        let thread = CodingThread(project: project), clone = f.harness.clone(plan)
        try await f.engine.dispatch(.startProjectClone(project: project, thread: thread))
        let partial = URL(fileURLWithPath: plan.stagingPath).appendingPathComponent("partial.bin")
        try await waitRemoval { await clone.starts == 1 && FileManager.default.fileExists(atPath: partial.path) }
        let partialBytes = try Data(contentsOf: partial)
        let checkout = URL(fileURLWithPath: plan.destinationPath)
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        let checkoutFile = checkout.appendingPathComponent("appeared-after-clone-start.txt"), checkoutBytes = Data("Never delete newly added files\n".utf8)
        try checkoutBytes.write(to: checkoutFile)
        let attachmentBytes = Data("Queued clone attachment\n".utf8)
        let attachment = try await f.engine.attachments.importData(attachmentBytes, name: "queued.txt")
        try await f.engine.dispatch(.addAttachments(threadID: thread.id, attachments: [attachment]))
        try await f.engine.dispatch(.submit(threadID: thread.id, text: "Never run after removal"))
        let request = WorkspaceEffectRequest.projectClone(projectID: project.id, plan: plan)
        try await f.engine.dispatch(.removeProject(projectID: project.id, expectedThreadIDs: [thread.id]))
        await f.engine.awaitProjectRemovalCleanup(projectID: project.id)
        #expect(await clone.cancellations >= 1)
        #expect(f.harness.providers(thread.id).isEmpty)
        let beforeLate = await f.engine.current()
        await clone.reportLateProgress(); await f.engine.drainCommands()
        #expect(await f.engine.current().snapshot == beforeLate.snapshot)
        #expect(await f.engine.current().sequence == beforeLate.sequence)
        let stale: [EngineCommand] = [
            .cloneStarted(projectID: project.id, attemptID: plan.id),
            .cloneProgress(projectID: project.id, attemptID: plan.id, progress: .init(stage: .checkout, percent: 100, detail: nil, stalled: false)),
            .effectResult(request, .succeeded), .effectResult(request, .failed("Late failed clone")), .effectResult(request, .cancelled),
            .runtimeOpened(threadID: thread.id, runID: UUID(), runtimeID: UUID()),
            .provider(threadID: thread.id, runtimeID: UUID(), event: .activity(.init(id: UUID(), state: .running))),
            .provider(threadID: thread.id, runtimeID: UUID(), event: .message(.init(role: .assistant, text: "Late transcript"))),
            .provider(threadID: thread.id, runtimeID: UUID(), event: .completed(.idle)),
            .effectResult(.providerStart(threadID: thread.id, runID: UUID(), configuration: .init(thread: thread), prompt: "Late start"), .failed("Late provider failure")),
        ]
        for event in stale {
            let decision = try WorkspaceDecision.make(event, id: UUID(), snapshot: beforeLate.snapshot, now: Date())
            #expect(decision.snapshot == beforeLate.snapshot && decision.effects.isEmpty)
        }
        #expect(try Data(contentsOf: partial) == partialBytes && Data(contentsOf: checkoutFile) == checkoutBytes)
        #expect(try await f.engine.attachments.data(for: attachment) == attachmentBytes)
        let database = try WorkspaceDatabase(url: f.databaseURL)
        #expect(try await database.effects().allSatisfy { $0.status == .cancelled })
        #expect(try await database.rebuildProjection().snapshot == beforeLate.snapshot)
        #expect(await f.engine.current().error == nil)
    }
}

private func removalSQL(_ url: URL, _ statement: String) throws {
    var connection: OpaquePointer?
    guard sqlite3_open(url.path, &connection) == SQLITE_OK else { throw CoincideError("Removal fixture database could not open") }
    defer { sqlite3_close(connection) }
    sqlite3_busy_timeout(connection, 1_000)
    guard sqlite3_exec(connection, statement, nil, nil, nil) == SQLITE_OK else { throw CoincideError("Removal fixture SQL failed") }
}
