import Foundation
import Testing
@testable import CoincideCore

private final class WorkspaceLifecycleClock: @unchecked Sendable {
    private let lock = NSLock(); private var value: Date
    init(_ value: Date) { self.value = value }
    var now: Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value.addTimeInterval(seconds) } }
}
private actor WorkspaceLifecycleSleeper {
    struct Pending { let seconds: Double; let continuation: CheckedContinuation<Void, any Error> }
    private var pending: [UUID: Pending] = [:]
    private var observers: [(Double, CheckedContinuation<UUID, Never>)] = []
    func sleep(_ duration: Duration) async throws {
        let id = UUID(), parts = duration.components
        let seconds = Double(parts.seconds) + Double(parts.attoseconds) / 1_000_000_000_000_000_000
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = .init(seconds: seconds, continuation: continuation)
                var kept: [(Double, CheckedContinuation<UUID, Never>)] = []
                for (expected, observer) in observers { if abs(expected - seconds) < 0.001 { observer.resume(returning: id) } else { kept.append((expected, observer)) } }
                observers = kept
            }
        } onCancel: { Task { await self.cancel(id) } }
    }
    func waitFor(seconds: Double) async -> UUID {
        if let id = pending.first(where: { abs($0.value.seconds - seconds) < 0.001 })?.key { return id }
        return await withCheckedContinuation { observers.append((seconds, $0)) }
    }
    func fire(_ id: UUID) -> Bool { guard let value = pending.removeValue(forKey: id) else { return false }; value.continuation.resume(); return true }
    private func cancel(_ id: UUID) { pending.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError()) }
}
private actor WorkspaceLifecycleTimerWorld {
    var snapshot: WorkspaceSnapshot
    let clock: WorkspaceLifecycleClock
    var wakeCount = 0, proposals = 0
    private var wakeWaiters: [(Date, CheckedContinuation<Void, Never>)] = []
    init(now: Date, clock: WorkspaceLifecycleClock) {
        self.clock = clock
        let project = WorkspaceProject(path: "/private/owned-snooze-timer"), thread = CodingThread(project: project)
        snapshot = .init(); snapshot.projects = [project]; snapshot.threads = [thread]
        snapshot.workspaceLifecyclePolicy = .disabled
        snapshot.threads[0].workspaceLifecycle = .init(snoozedUntil: now.addingTimeInterval(10), snoozedAt: now)
    }
    func read() throws -> WorkspaceLifecycleSweepSnapshot {
        .init(facts: try snapshot.threads.compactMap { try snapshot.workspaceLifecycleFacts(threadID: $0.id) }, policy: .disabled)
    }
    func snooze(until: Date) throws {
        snapshot = try WorkspaceDecision.make(.client(.workspaceLifecycle(.snooze(threadID: snapshot.threads[0].id, until: until))), id: UUID(), snapshot: snapshot, now: clock.now).snapshot
    }
    func wake(_ wake: WorkspaceLifecycleExpiredSnooze) throws {
        snapshot = try WorkspaceDecision.make(.client(.workspaceLifecycle(.wakeExpired(wake))), id: wake.id, snapshot: snapshot, now: clock.now).snapshot
        wakeCount += 1
        var kept: [(Date, CheckedContinuation<Void, Never>)] = []
        for (until, waiter) in wakeWaiters {
            if snapshot.threads[0].workspaceLifecycle?.lastSnoozeWakeAt == until { waiter.resume() } else { kept.append((until, waiter)) }
        }
        wakeWaiters = kept
    }
    func waitUntilWoken(_ deadline: Date) async {
        if snapshot.threads[0].workspaceLifecycle?.lastSnoozeWakeAt == deadline { return }
        await withCheckedContinuation { wakeWaiters.append((deadline, $0)) }
    }
    func apply(_ proposal: ThreadAutoSettlementProposal) { proposals += 1 }
}

@Test(.timeLimit(.minutes(1)))
func workspaceLifecycleOwnedTimerRearmsForFreshSnoozeAndPublishesExactExpiryWithoutAnyProviderTurn() async throws {
    let initial = Date(timeIntervalSince1970: 2_000_000_000), clock = WorkspaceLifecycleClock(initial)
    let sleeper = WorkspaceLifecycleSleeper(), world = WorkspaceLifecycleTimerWorld(now: initial, clock: clock)
    let service = WorkspaceLifecycleService(read: { try await world.read() }, lookup: { _ in [] }, apply: { await world.apply($0) },
        wake: { try await world.wake($0) }, now: { clock.now }, sleep: { try await sleeper.sleep($0) })
    do {
        await service.start()
        let oldTimer = await sleeper.waitFor(seconds: 10)
        clock.advance(1); let freshDeadline = initial.addingTimeInterval(20)
        try await world.snooze(until: freshDeadline)
        await service.requestSweep(); await service.drain()
        let freshTimer = await sleeper.waitFor(seconds: 19)
        #expect(oldTimer != freshTimer)
        // Cancellation/generation ownership prevents the old scheduled wake
        // from clearing a newer, explicitly restamped snooze.
        _ = await sleeper.fire(oldTimer)
        #expect(await world.snapshot.threads[0].workspaceLifecycle?.snoozedUntil == freshDeadline)
        clock.advance(19)
        #expect(await sleeper.fire(freshTimer))
        await world.waitUntilWoken(freshDeadline)
        await service.drain()
        let snapshot = await world.snapshot, wakes = await world.wakeCount, proposals = await world.proposals
        #expect(snapshot.threads[0].workspaceLifecycle?.lastSnoozeWakeAt == freshDeadline)
        #expect(wakes == 1 && proposals == 0)
        #expect(snapshot.threads[0].activeRun == nil && snapshot.threads[0].settlement == nil)
    } catch { await service.close(); throw error }; await service.close()
}

private actor WorkspaceLifecycleOwnershipCancellation {
    private var entered = false, released = false
    private var held: CheckedContinuation<Void, Never>?, observers: [CheckedContinuation<Void, Never>] = []
    func lookup() async throws {
        entered = true; let observers = observers; self.observers = []; for observer in observers { observer.resume() }
        if !released { await withCheckedContinuation { held = $0 } }
        throw CancellationError() // Only this callback lost its former owner.
    }
    func waitUntilEntered() async { if !entered { await withCheckedContinuation { observers.append($0) } } }
    func cancelOwnership() { released = true; held?.resume(); held = nil }
}
private actor WorkspaceLifecyclePendingSweepWorld {
    let first: ThreadWorkspaceLifecycleFacts, second: ThreadWorkspaceLifecycleFacts
    var reads = 0, applied: [UUID] = []
    init(now: Date) throws {
        let old = now.addingTimeInterval(-5 * 86_400), project = UUID()
        let link = WorkspaceLifecyclePullRequestLink(id: UUID(), reference: try .init(repository: .init(owner: "acme", name: "owned"), number: 1), linkedAt: old)
        first = .init(id: UUID(), projectID: project, workspacePath: "/private/owned-a", configurationDigest: String(repeating: "a", count: 64), createdAt: old, updatedAt: old, pullRequests: [link])
        second = .init(id: UUID(), projectID: project, workspacePath: "/private/owned-b", configurationDigest: String(repeating: "b", count: 64), createdAt: old, updatedAt: old)
    }
    func read() -> WorkspaceLifecycleSweepSnapshot { reads += 1; return .init(facts: reads == 1 ? [first] : [second], policy: .init()) }
    func apply(_ proposal: ThreadAutoSettlementProposal) { applied.append(proposal.threadID) }
}

@Test(.timeLimit(.minutes(1)))
func workspaceLifecycleQueuedSweepSurvivesPriorLookupOwnershipCancellationWithoutWaitingForTimer() async throws {
    let now = Date(timeIntervalSince1970: 2_000_000_000), gate = WorkspaceLifecycleOwnershipCancellation()
    let world = try WorkspaceLifecyclePendingSweepWorld(now: now)
    let service = WorkspaceLifecycleService(read: { await world.read() }, lookup: { _ in try await gate.lookup(); return [] },
        apply: { await world.apply($0) }, wake: { _ in }, now: { now })
    let a = await world.first.id, b = await world.second.id
    await service.requestSweep(threadID: a)
    await gate.waitUntilEntered()
    await service.requestSweep(threadID: b)
    await gate.cancelOwnership()
    await service.drain()
    let reads = await world.reads, applied = await world.applied
    #expect(reads == 2 && applied == [b])
    await service.close()
}

@Test(.timeLimit(.minutes(1)))
func workspaceLifecycleStopPublishesDrainWithoutWaitingOnAnInboxBoundCallback() async throws {
    let now = Date(timeIntervalSince1970: 2_000_000_000), gate = WorkspaceLifecycleOwnershipCancellation()
    let world = try WorkspaceLifecyclePendingSweepWorld(now: now)
    let service = WorkspaceLifecycleService(read: {
        _ = await world.read()
        let second = await world.second
        return .init(facts: [second], policy: .init())
    }, lookup: { _ in [] }, apply: { _ in try await gate.lookup() }, wake: { _ in }, now: { now })
    await service.requestSweep(); await gate.waitUntilEntered()
    // This callback models an enqueue behind the command stopping the service.
    // Stop must return its owned join before the inbox can release that enqueue.
    let drain = await service.stop()
    await service.requestSweep()
    await gate.cancelOwnership(); await drain.value; await service.close()
    #expect(await world.reads == 1)
    #expect(await world.applied.isEmpty)
}
