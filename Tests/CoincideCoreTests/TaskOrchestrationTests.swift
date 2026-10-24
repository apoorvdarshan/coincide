import Foundation
import Testing
@testable import CoincideCore

actor DelegatedTaskTestPeer {
    struct Owner: Sendable { let runID: UUID; let events: AsyncStream<ProviderEvent>.Continuation }
    var owners: [UUID: Owner] = [:]
    private(set) var inputs: [UUID: [String]] = [:]
    private(set) var steers: [UUID: [String]] = [:]
    private(set) var closes: [UUID: Int] = [:]
    let supportsSteer: Bool
    let uncertainSteer: Bool
    private var holdSteeringObservation = false
    private var steeringObservationWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var steeringObservationEntered = false
    init(steer: Bool = false, uncertain: Bool = false) { supportsSteer = steer; uncertainSteer = uncertain }
    func receive(_ input: ProviderInput, thread: CodingThread, events: AsyncStream<ProviderEvent>.Continuation) throws {
        let runID = try #require(thread.activeRun?.id)
        inputs[thread.id, default: []].append(input.text)
        owners[thread.id] = .init(runID: runID, events: events)
        events.yield(.context(runID: runID, event: .thread(thread.providerThreadID ?? "task-native-" + thread.id.uuidString)))
        events.yield(.context(runID: runID, event: .turn("task-turn-" + runID.uuidString)))
    }
    func complete(_ threadID: UUID, text: String = "Final task result", intermediate: String? = nil) throws {
        let owner = try #require(owners[threadID])
        if let intermediate { owner.events.yield(.context(runID: owner.runID, event: .message(.init(role: .assistant, text: intermediate)))) }
        owner.events.yield(.context(runID: owner.runID, event: .message(.init(role: .assistant, text: text))))
        owner.events.yield(.context(runID: owner.runID, event: .completed(.idle)))
    }
    func interrupt(_ threadID: UUID) {
        guard let owner = owners[threadID] else { return }
        owner.events.yield(.context(runID: owner.runID, event: .completed(.interrupted)))
    }
    func steer(_ input: ProviderInput, thread: CodingThread, target: ProviderSteeringTarget) throws -> ProviderSteeringReceipt {
        steers[thread.id, default: []].append(input.text)
        if uncertainSteer { throw ProviderSteeringError(.outcomeUncertain) }
        return try .init(target: target)
    }
    func holdSteeringCapabilities() { holdSteeringObservation = true; steeringObservationEntered = false }
    func releaseSteeringCapabilities() {
        holdSteeringObservation = false; let waiters = steeringObservationWaiters; steeringObservationWaiters = []
        for waiter in waiters { waiter.resume() }
    }
    func capabilities(_ id: UUID) async -> ProviderSteeringCapabilities {
        if holdSteeringObservation {
            steeringObservationEntered = true
            await withCheckedContinuation { steeringObservationWaiters.append($0) }
        }
        return .init(supportsActiveSteering: supportsSteer, target: owners[id].map { .nativeTurn("task-turn-" + $0.runID.uuidString) })
    }
    func closed(_ id: UUID) { closes[id, default: 0] += 1 }
}
actor DelegatedTaskTestSession: ProviderSession {
    nonisolated let events: AsyncStream<ProviderEvent>
    let continuation: AsyncStream<ProviderEvent>.Continuation
    let peer: DelegatedTaskTestPeer, id: UUID
    init(peer: DelegatedTaskTestPeer, id: UUID) { self.peer = peer; self.id = id; (events, continuation) = AsyncStream.makeStream() }
    func models() async throws -> [ProviderModel] { [] }
    func send(text: String, thread: CodingThread) async throws { try await send(input: .init(text: text), thread: thread) }
    func send(input: ProviderInput, thread: CodingThread) async throws { try await peer.receive(input, thread: thread, events: continuation) }
    func interrupt() async throws { await peer.interrupt(id) }
    func respond(_ request: ApprovalRequest, allow: Bool) async throws { }
    func answer(_ request: ApprovalRequest, answers: [String: String]) async throws { }
    func steeringCapabilities() async -> ProviderSteeringCapabilities {
        await peer.capabilities(id)
    }
    func steer(input: ProviderInput, thread: CodingThread, target: ProviderSteeringTarget, clientMessageID: String) async throws -> ProviderSteeringReceipt { try await peer.steer(input, thread: thread, target: target) }
    func close() async { await peer.closed(id); continuation.finish() }
}
struct DelegatedTaskCoreFixture {
    let root: URL, database: URL, engine: WorkspaceEngine, peer: DelegatedTaskTestPeer, parentID: UUID
    static func make(steer: Bool = false, uncertain: Bool = false) async throws -> Self {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-task-core-" + UUID().uuidString).standardizedFileURL.resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let database = root.appendingPathComponent("workspace.sqlite"), peer = DelegatedTaskTestPeer(steer: steer, uncertain: uncertain)
        let engine = try WorkspaceEngine(url: database, providerFactory: { DelegatedTaskTestSession(peer: peer, id: $0.id) }, identityResolver: { _ in nil })
        do {
            _ = try await engine.load()
            let project = WorkspaceProject(path: root.path); var parent = CodingThread(project: project); parent.checkpointPolicy = .disabled
            _ = try await engine.dispatch(.addProjectWithThread(project: project, thread: parent))
            _ = try await engine.dispatch(.submit(threadID: parent.id, text: "Private parent history must not be copied"))
            try await taskEventually {
                let count = await peer.inputs[parent.id]?.count
                let turn = await engine.current().snapshot.threads.first(where: { $0.id == parent.id })?.activeRun?.nativeTurnID
                return count == 1 && turn != nil
            }
            return .init(root: root, database: database, engine: engine, peer: peer, parentID: parent.id)
        } catch { await engine.shutdown(); try? FileManager.default.removeItem(at: root); throw error }
    }
    func thread(_ id: UUID? = nil) async throws -> CodingThread { try #require(await engine.current().snapshot.threads.first { $0.id == (id ?? parentID) }) }
    func request(task: String = "Inspect only this self-contained brief", mode: DelegatedTaskMode = .async, parentID: UUID? = nil) async throws -> DelegatedTaskRequest {
        let parent = try await thread(parentID); var configuration = ProviderConfiguration(thread: parent)
        configuration.nativeThreadID = nil; configuration.claudeLaunchSelection = nil
        return .init(parentThreadID: parent.id, parentRunID: try #require(parent.activeRun?.id), expectedConfiguration: .init(thread: parent), configuration: configuration,
            task: task, title: "Captured task", role: .review, mode: mode)
    }
    func close() async { await engine.shutdown(); try? FileManager.default.removeItem(at: root) }
}
func taskEventually(_ predicate: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while try await !predicate() { guard ContinuousClock.now < deadline else { throw CoincideError("Delegated task fixture did not reach its bounded durable state.") }; await Task.yield() }
}

@Test(.timeLimit(.minutes(1))) func delegatedTaskFreshBriefUsesSoleOriginalUUIDCapturedSettingsAndRealProvenance() async throws {
    let f = try await DelegatedTaskCoreFixture.make()
    do {
        _ = try await f.engine.dispatch(.editThread(f.parentID, .draft("Preserve composer")))
        let request = try await f.request(), command = UUID()
        let accepted = try await f.engine.createDelegatedTask(request, commandID: command)
        #expect(accepted.receipt.commandID == command && accepted.taskID != command && accepted.childRunID != command)
        try await taskEventually { await f.peer.inputs[accepted.childThreadID]?.count == 1 }
        #expect(await f.peer.inputs[accepted.childThreadID] == [request.prompt])
        #expect(try await f.thread(accepted.childThreadID).messages.first?.text == request.prompt)
        #expect(try await f.thread().draft == "Preserve composer")
        #expect(try await f.engine.createDelegatedTask(request, commandID: command) == accepted)
        #expect(await f.peer.inputs[accepted.childThreadID]?.count == 1)
        let changed = try await f.request(task: "Changed immutable brief")
        await #expect(throws: DelegatedTaskError.invalidRequest) { try await f.engine.createDelegatedTask(changed, commandID: command) }
        try await f.peer.complete(accepted.childThreadID, text: "Final review", intermediate: "Interim analysis")
        try await taskEventually { await f.engine.current().snapshot.delegatedTasks?.first?.result != nil }
        let status = try await f.engine.delegatedTaskStatus(parentThreadID: f.parentID, taskID: accepted.taskID, acknowledge: false)
        #expect(status.task.result?.summary == "Final review")
        let transfers = await f.engine.current().snapshot.delegatedTaskTransfers ?? []
        #expect(transfers.count == 2 && transfers.contains { $0.id == status.task.result?.contextTransferID && $0.sourceRunID == accepted.childRunID && $0.kind == .subagentResult })
        #expect(try await WorkspaceDatabase(url: f.database).receipt(accepted.taskID) == nil)
    } catch { await f.close(); throw error }; await f.close()
}

@Test(.timeLimit(.minutes(1))) func delegatedTaskBlockingWaitAcknowledgesResultAndTimeoutUpgradesWakeWithoutStoppingChild() async throws {
    let f = try await DelegatedTaskCoreFixture.make()
    do {
        let accepted = try await f.engine.createDelegatedTask(f.request(mode: .wait))
        try await taskEventually { await f.peer.inputs[accepted.childThreadID]?.count == 1 }
        let timeout = try await f.engine.waitForDelegatedTask(parentThreadID: f.parentID, taskID: accepted.taskID, timeoutMilliseconds: 0)
        #expect(timeout.waitTimedOut && !timeout.task.status.isTerminal)
        #expect(try await f.thread(accepted.childThreadID).activeRun?.stopRequested == false)
        #expect(await f.engine.current().snapshot.delegatedTasks?.first?.wakePolicy == .always)
        let second = try await f.engine.createDelegatedTask(f.request(task: "Blocking terminal read", mode: .wait))
        try await taskEventually { await f.peer.inputs[second.childThreadID]?.count == 1 }
        try await f.peer.complete(second.childThreadID, text: "Read directly")
        try await taskEventually { await f.engine.current().snapshot.delegatedTasks?.first(where: { $0.id == second.taskID })?.result != nil }
        let result = try await f.engine.waitForDelegatedTask(parentThreadID: f.parentID, taskID: second.taskID, timeoutMilliseconds: 100)
        #expect(!result.waitTimedOut && result.task.result?.summary == "Read directly" && result.task.completion.state == .acknowledged)
        #expect(await f.engine.current().snapshot.delegatedTaskCohorts?.contains(where: { $0.taskIDs.contains(second.taskID) }) != true)
    } catch { await f.close(); throw error }; await f.close()
}

@Test(.timeLimit(.minutes(1))) func delegatedTaskQueuedCompletionCoalescesAndStatusAcknowledgementWithdrawsOnlyUnsentNotice() async throws {
    let f = try await DelegatedTaskCoreFixture.make()
    do {
        let a = try await f.engine.createDelegatedTask(f.request(task: "First parallel task"))
        let b = try await f.engine.createDelegatedTask(f.request(task: "Second parallel task"))
        try await taskEventually { let values = await f.peer.inputs; return values[a.childThreadID]?.count == 1 && values[b.childThreadID]?.count == 1 }
        try await f.peer.complete(a.childThreadID)
        try await taskEventually { try await f.thread().queuedTurns.count == 1 }
        try await f.peer.complete(b.childThreadID)
        try await taskEventually { try await f.thread().queuedTurns.first?.delegatedCompletion?.taskIDs.count == 2 }
        _ = try await f.engine.dispatch(.editThread(f.parentID, .draft("Later edited composer")))
        _ = try await f.engine.delegatedTaskStatus(parentThreadID: f.parentID, taskID: a.taskID)
        let remaining = try #require(try await f.thread().queuedTurns.first)
        #expect(remaining.delegatedCompletion?.taskIDs == [b.taskID] && !remaining.text.contains(a.taskID.uuidString.lowercased()))
        _ = try await f.engine.delegatedTaskStatus(parentThreadID: f.parentID, taskID: b.taskID)
        #expect(try await f.thread().queuedTurns.isEmpty)
        #expect(try await f.thread().draft == "Later edited composer")
    } catch { await f.close(); throw error }; await f.close()
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true]) func delegatedTaskSteeringUsesExactOwnedTurnAndUnknownDeliveryIsNeverRepeated(uncertain: Bool) async throws {
    let f = try await DelegatedTaskCoreFixture.make(steer: true, uncertain: uncertain)
    do {
        let accepted = try await f.engine.createDelegatedTask(f.request())
        try await taskEventually { await f.peer.inputs[accepted.childThreadID]?.count == 1 }
        try await f.peer.complete(accepted.childThreadID)
        try await taskEventually { await f.engine.current().snapshot.delegatedTasks?.first?.completion.state == (uncertain ? .uncertain : .delivered) }
        #expect(await f.peer.steers[f.parentID]?.count == 1)
        #expect(try await f.thread().queuedTurns.isEmpty)
        _ = try await f.engine.dispatch(.editThread(f.parentID, .draft("Unrelated edit")))
        _ = try await f.engine.delegatedTaskStatus(parentThreadID: f.parentID, taskID: accepted.taskID, acknowledge: false)
        #expect(await f.peer.steers[f.parentID]?.count == 1)
    } catch { await f.close(); throw error }; await f.close()
}

@Test(.timeLimit(.minutes(1))) func delegatedTaskCancellationChecksWholeTreeBeforeStoppingAndOldReceiptCannotDrainNewChildRuntime() async throws {
    let f = try await DelegatedTaskCoreFixture.make()
    do {
        let accepted = try await f.engine.createDelegatedTask(f.request())
        try await taskEventually { await f.peer.inputs[accepted.childThreadID]?.count == 1 }
        let unrelatedInput = UUID()
        _ = try await f.engine.dispatch(.submit(threadID: accepted.childThreadID, text: "Preserve this independent queued user input"), id: unrelatedInput)
        let queuedBeforeCancel = try #require(try await f.thread(accepted.childThreadID).queuedTurns.first { $0.id == unrelatedInput })
        #expect(queuedBeforeCancel.delegatedTaskID == nil && queuedBeforeCancel.delegatedTaskOwnershipRecorded == true)
        _ = try await f.engine.dispatch(.editThread(accepted.childThreadID, .permission(.fullAccess)))
        await #expect(throws: WorkspaceCommandError.self) { try await f.engine.cancelDelegatedTask(parentThreadID: f.parentID, taskID: accepted.taskID) }
        #expect(try await f.thread(accepted.childThreadID).activeRun?.stopRequested == false)
        _ = try await f.engine.dispatch(.editThread(accepted.childThreadID, .permission(.supervised)))
        let command = UUID()
        let receipt = try await f.engine.cancelDelegatedTask(parentThreadID: f.parentID, taskID: accepted.taskID, commandID: command)
        #expect(receipt.rejection == nil)
        try await taskEventually { try await f.thread(accepted.childThreadID).activeRun == nil }
        let held = try await f.thread(accepted.childThreadID)
        #expect(held.queuePaused && held.queuedTurns.contains { $0.id == unrelatedInput && $0.text == "Preserve this independent queued user input" })
        let oldCloses = await f.peer.closes[accepted.childThreadID] ?? 0
        _ = try await f.engine.dispatch(.resumeQueue(threadID: accepted.childThreadID))
        try await taskEventually { await f.peer.inputs[accepted.childThreadID]?.count == 2 }
        #expect(await f.peer.inputs[accepted.childThreadID]?.last == "Preserve this independent queued user input")
        #expect(try await f.engine.cancelDelegatedTask(parentThreadID: f.parentID, taskID: accepted.taskID, commandID: command) == receipt)
        #expect(await f.peer.closes[accepted.childThreadID] == oldCloses)
        #expect(try await f.thread(accepted.childThreadID).activeRun?.stopRequested == false)
    } catch { await f.close(); throw error }; await f.close()
}

@Test(.timeLimit(.minutes(1))) func delegatedTaskNestedResultsWaitForParentContinuationAndExplicitFollowupKeepsOriginalResultImmutable() async throws {
    let f = try await DelegatedTaskCoreFixture.make()
    do {
        let a = try await f.engine.createDelegatedTask(f.request(task: "Parent child"))
        try await taskEventually {
            let count = await f.peer.inputs[a.childThreadID]?.count
            let ready = try await f.thread(a.childThreadID).activeRun?.nativeTurnID != nil
            return count == 1 && ready
        }
        let b = try await f.engine.createDelegatedTask(f.request(task: "Nested child", parentID: a.childThreadID))
        try await taskEventually { await f.peer.inputs[b.childThreadID]?.count == 1 }
        try await f.peer.complete(a.childThreadID, text: "Before nested result")
        try await taskEventually { await f.engine.current().snapshot.delegatedTasks?.first(where: { $0.id == a.taskID })?.workState == .waitingForChildren }
        try await f.peer.complete(b.childThreadID, text: "Nested final")
        try await taskEventually { await f.peer.inputs[a.childThreadID]?.count == 2 }
        #expect(await f.engine.current().snapshot.delegatedTasks?.first(where: { $0.id == a.taskID })?.result == nil)
        try await f.peer.complete(a.childThreadID, text: "Parent final after nested result")
        try await taskEventually { await f.engine.current().snapshot.delegatedTasks?.first(where: { $0.id == a.taskID })?.result != nil }
        let original = try #require(await f.engine.current().snapshot.delegatedTasks?.first(where: { $0.id == a.taskID })?.result)
        #expect(original.summary == "Parent final after nested result")
        _ = try await f.engine.dispatch(.submit(threadID: a.childThreadID, text: "Explicit second review round"))
        try await taskEventually { await f.peer.inputs[a.childThreadID]?.count == 3 }
        try await f.peer.complete(a.childThreadID, text: "Later round final")
        try await taskEventually { await f.engine.current().snapshot.delegatedTasks?.contains(where: { $0.childThreadID == a.childThreadID && $0.isFollowup == true && $0.result != nil }) == true }
        let status = try await f.engine.delegatedTaskStatus(parentThreadID: f.parentID, taskID: a.taskID, acknowledge: false)
        #expect(status.task.result == original && status.task.latestTerminalResult?.summary == "Later round final")
    } catch { await f.close(); throw error }; await f.close()
}

@Test(.timeLimit(.minutes(1))) func delegatedTaskProcessLossPublishesInterruptedResultWithoutReplayingChildOrParentNotification() async throws {
    let f = try await DelegatedTaskCoreFixture.make()
    var replacement: WorkspaceEngine?
    do {
        let accepted = try await f.engine.createDelegatedTask(f.request(mode: .wait))
        try await taskEventually { await f.peer.inputs[accepted.childThreadID]?.count == 1 }
        await f.engine.shutdown()
        let before = await f.peer.inputs
        let fresh = try WorkspaceEngine(url: f.database, providerFactory: { DelegatedTaskTestSession(peer: f.peer, id: $0.id) }, identityResolver: { _ in nil })
        replacement = fresh
        let recovered = try await fresh.load()
        let task = try #require(recovered.delegatedTasks?.first { $0.id == accepted.taskID })
        #expect(task.status == .interrupted && task.result?.status == .interrupted && task.wakePolicy == .always)
        #expect(recovered.delegatedTaskTransfers?.contains(where: { $0.id == task.result?.contextTransferID }) == true)
        #expect(await f.peer.inputs == before)
        #expect(recovered.threads.allSatisfy { $0.activeRun == nil })
        #expect(recovered.delegatedTaskCohorts?.isEmpty != false)
        #expect(try await fresh.createDelegatedTask(task.request, commandID: task.commandID) == accepted)
        #expect(await f.peer.inputs == before)
    } catch { await replacement?.shutdown(); await f.close(); throw error }
    await replacement?.shutdown(); await f.close()
}

@Test func delegatedTaskCancellationBeforeBaselineReleaseCannotLeaveTerminalPendingProviderStart() throws {
    var f = RunHistoryFixture(); try f.submit("Parent"); try f.connect(); try f.event(.thread("native-parent")); try f.event(.turn("parent-turn"))
    let parent = f.thread, command = UUID(), taskID = TaskOrchestration.derivedID(command, "task")
    var configuration = ProviderConfiguration(thread: parent); configuration.nativeThreadID = nil
    var child = CodingThread(project: f.snapshot.projects[0]); child.id = TaskOrchestration.derivedID(command, "child"); child.checkpointPolicy = .automatic
    child.applyContextConfiguration(configuration)
    child.delegatedTaskLineage = .init(taskID: taskID, parentThreadID: parent.id, parentRunID: parent.activeRun!.id, rootThreadID: parent.id)
    let request = DelegatedTaskRequest(parentThreadID: parent.id, parentRunID: parent.activeRun!.id, expectedConfiguration: .init(thread: parent), configuration: configuration, task: "Never release provider")
    let prepared = DelegatedTaskPreparation(request: request, child: child, parentIncarnation: UUID(), parentRuntimeID: f.runtimeID, isolation: nil, worktree: nil)
    let accepted = try f.command(.delegatedTaskAccepted(prepared), id: command)
    #expect(accepted.effects.contains { if case .resolveRunCheckpoint = $0.request { return true }; return false })
    let stopped = try f.command(.delegatedTaskCancel(parentThreadID: parent.id, taskID: taskID, reason: nil))
    let final = try #require(stopped.snapshot.threads.first { $0.id == child.id })
    #expect(final.activeRun == nil && final.runHistory?.first?.checkpoints?.pendingStart == nil)
    #expect(final.runHistory?.first?.status == .interrupted && final.runHistory?.first?.checkpoints?.baseline.phase == .interrupted)
    #expect(stopped.effects.allSatisfy { if case .providerStart = $0.request { return false }; return true })
    try WorkspaceJournal.validate(stopped.snapshot)
}

@Test(.timeLimit(.minutes(1))) func delegatedTaskNoticeCannotStartProviderAheadOfPendingExplicitContextHandoff() async throws {
    let f = try await DelegatedTaskCoreFixture.make()
    do {
        let accepted = try await f.engine.createDelegatedTask(f.request())
        try await taskEventually { await f.peer.inputs[accepted.childThreadID]?.count == 1 }
        let parentRunID = try #require(try await f.thread().activeRun?.id)
        try await f.peer.complete(f.parentID, text: "Completed parent boundary")
        try await taskEventually { try await f.thread().activeRun == nil }
        let parent = try await f.thread(); var destination = ProviderConfiguration(thread: parent)
        destination.provider = .claude; destination.model = ""; destination.nativeThreadID = nil
        let review = try await f.engine.reviewContextTransfer(.init(sourceThreadID: parent.id, expectedConfiguration: .init(thread: parent), sourcePoint: .run(parentRunID), intent: .providerHandoff(destination: destination)))
        _ = try await f.engine.acceptContextTransfer(reviewID: review.id, digest: review.digest)
        try await f.peer.complete(accepted.childThreadID, text: "Task while context waits")
        try await taskEventually { await f.engine.current().snapshot.delegatedTasks?.first?.result != nil }
        #expect(await f.peer.inputs[f.parentID]?.count == 1)
        #expect(try await f.thread().queuedTurns.isEmpty)
        _ = try await f.engine.dispatch(.submit(threadID: f.parentID, text: "Explicit handoff input"))
        try await taskEventually { await f.peer.inputs[f.parentID]?.count == 2 }
        #expect(await f.peer.inputs[f.parentID]?.last == "Explicit handoff input")
        try await f.peer.complete(f.parentID, text: "After explicit context")
        try await taskEventually { await f.peer.inputs[f.parentID]?.count == 3 }
        #expect(await f.peer.inputs[f.parentID]?.last?.contains("Use task_status") == true)
    } catch { await f.close(); throw error }; await f.close()
}

@Test func delegatedTaskCapacityReservesEscapedResultsBeforeAnyProviderWork() throws {
    let project = WorkspaceProject(path: "/private/tmp/coincide-task-capacity")
    let parent = CodingThread(project: project), configuration = ProviderConfiguration(thread: parent), now = Date(timeIntervalSince1970: 1_700_000_000)
    var snapshot = WorkspaceSnapshot(); snapshot.projects = [project]; snapshot.threads = [parent]; snapshot.delegatedTasks = []
    let escaped = String(repeating: "\u{0001}", count: 1_024)
    #expect(try TaskOrchestration.payload(escaped).count >= escaped.utf8.count * 6)
    for _ in 0..<5 {
        let command = UUID(), id = TaskOrchestration.derivedID(command, "task")
        let request = DelegatedTaskRequest(parentThreadID: parent.id, parentRunID: UUID(), expectedConfiguration: configuration, configuration: configuration, task: "Reserved result capacity")
        snapshot.delegatedTasks!.append(.init(id: id, commandID: command, parentThreadID: parent.id, parentRunID: request.parentRunID,
            childThreadID: UUID(), childRunID: UUID(), parentTaskID: nil, request: request, createdAt: now, updatedAt: now,
            status: .running, workState: .working, wakePolicy: .always, completion: .init()))
    }
    try TaskOrchestration.requireCapacity(snapshot)
    let another = snapshot.delegatedTasks![0]
    snapshot.delegatedTasks!.append(another)
    #expect(throws: DelegatedTaskError.limit) { try TaskOrchestration.requireCapacity(snapshot) }
    // The rejected admission is small today; its future worst-case encoded
    // result is what must be refused, before any model or setup process starts.
    #expect(try TaskOrchestration.ledgerBytes(snapshot) < 1_024 * 1_024)
}

@Test(.timeLimit(.minutes(1))) func delegatedTaskConcurrentCompletionDuringCapabilityAwaitCannotLoseItsParentWake() async throws {
    let f = try await DelegatedTaskCoreFixture.make()
    do {
        let a = try await f.engine.createDelegatedTask(f.request(task: "Completion before held capability read"))
        let b = try await f.engine.createDelegatedTask(f.request(task: "Completion during held capability read"))
        try await taskEventually { let values = await f.peer.inputs; return values[a.childThreadID]?.count == 1 && values[b.childThreadID]?.count == 1 }
        await f.peer.holdSteeringCapabilities()
        try await f.peer.complete(a.childThreadID, text: "First result")
        try await taskEventually { await f.peer.steeringObservationEntered }
        try await f.peer.complete(b.childThreadID, text: "Concurrent result")
        try await taskEventually { await f.engine.current().snapshot.delegatedTasks?.first(where: { $0.id == b.taskID })?.result != nil }
        await f.peer.releaseSteeringCapabilities()
        try await taskEventually { try await f.thread().queuedTurns.first?.delegatedCompletion?.taskIDs.count == 2 }
        let queued = try #require(try await f.thread().queuedTurns.first)
        #expect(Set(queued.delegatedCompletion?.taskIDs ?? []) == Set([a.taskID, b.taskID]))
        #expect(try await f.thread().queuedTurns.count == 1)
        #expect(await f.peer.inputs[f.parentID]?.count == 1)
    } catch { await f.peer.releaseSteeringCapabilities(); await f.close(); throw error }
    await f.peer.releaseSteeringCapabilities(); await f.close()
}
