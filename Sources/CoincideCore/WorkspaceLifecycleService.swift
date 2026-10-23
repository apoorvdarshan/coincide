import Foundation

public struct WorkspaceLifecycleSweepSnapshot: Sendable {
    public let facts: [ThreadWorkspaceLifecycleFacts]
    public let policy: WorkspaceLifecyclePolicy
    public let bindingID: UUID
    public init(facts: [ThreadWorkspaceLifecycleFacts], policy: WorkspaceLifecyclePolicy, bindingID: UUID = UUID()) { self.facts = facts; self.policy = policy; self.bindingID = bindingID }
}

/// Owns only readonly policy/PR observation work and exact proposal admission.
/// It cannot send input, run setup, resume a queue or restart a retired provider.
public actor WorkspaceLifecycleService {
    public typealias Read = @Sendable () async throws -> WorkspaceLifecycleSweepSnapshot
    public typealias Lookup = @Sendable (ThreadWorkspaceLifecycleFacts) async throws -> [WorkspaceLifecyclePullRequestObservation]
    public typealias Apply = @Sendable (ThreadAutoSettlementProposal) async throws -> Void
    public typealias Wake = @Sendable (WorkspaceLifecycleExpiredSnooze) async throws -> Void
    public typealias Sleep = @Sendable (Duration) async throws -> Void
    private let read: Read, lookup: Lookup, apply: Apply
    private let wake: Wake
    private let sleep: Sleep
    private let now: @Sendable () -> Date
    private let interval: Duration
    private var timer: Task<Void, Never>?, worker: Task<Void, Never>?
    private var closeDrain: Task<Void, Never>?
    private var timerGeneration = UUID(), timerDeadline: Date?, started = false
    private var allPending = false, pending: Set<UUID> = [], closed = false
    public init(read: @escaping Read, lookup: @escaping Lookup, apply: @escaping Apply, wake: @escaping Wake,
                interval: Duration = .seconds(60), now: @escaping @Sendable () -> Date = { Date() },
                sleep: Sleep? = nil) {
        self.read = read; self.lookup = lookup; self.apply = apply; self.wake = wake; self.interval = interval; self.now = now
        self.sleep = sleep ?? Self.namedStaticSleep
    }
    private static func namedStaticSleep(_ duration: Duration) async throws { try await Task.sleep(for: duration) }
    public func start() {
        guard !closed, !started else { return }; started = true
        requestSweep()
        armTimer(nextWake: nil)
    }
    public func requestSweep(threadID: UUID? = nil) {
        guard !closed else { return }
        if let threadID { pending.insert(threadID) } else { allPending = true }
        guard worker == nil else { return }
        worker = Task { [weak self] in await self?.sweepLoop() }
    }
    public func drain() async {
        while let current = worker { await current.value }
    }
    public func stop() -> Task<Void, Never> {
        if let closeDrain { return closeDrain }
        closed = true; allPending = false; pending = []
        let timer = timer, worker = worker
        timer?.cancel(); worker?.cancel()
        self.timer = nil
        let drain = Task { await timer?.value; await worker?.value }
        closeDrain = drain; return drain
    }
    public func close() async { await stop().value }
    private func armTimer(nextWake: Date?) {
        guard started, !closed else { return }
        let instant = now(), parts = interval.components
        let seconds = max(0.001, Double(parts.seconds) + Double(parts.attoseconds) / 1_000_000_000_000_000_000)
        let deadline = min(instant.addingTimeInterval(seconds), nextWake ?? .distantFuture)
        if timer != nil, timerDeadline == deadline { return }
        timer?.cancel(); timerDeadline = deadline; timerGeneration = UUID()
        let generation = timerGeneration, delay = max(0, deadline.timeIntervalSince(instant))
        let sleep = sleep
        timer = Task { [weak self] in
            do { try await sleep(.seconds(delay)); try Task.checkCancellation() } catch { return }
            await self?.timerFired(generation)
        }
    }
    private func timerFired(_ generation: UUID) {
        guard !closed, generation == timerGeneration else { return }
        timer = nil; timerDeadline = nil; requestSweep(); armTimer(nextWake: nil)
    }
    private func sweepLoop() async {
        defer { worker = nil }
        while !closed && !Task.isCancelled && (allPending || !pending.isEmpty) {
            let selected: Set<UUID>? = allPending ? nil : pending
            allPending = false; pending = []
            do {
                let snapshot = try await read()
                try Task.checkCancellation(); try snapshot.policy.validate()
                guard !closed else { continue }
                let instant = now()
                armTimer(nextWake: snapshot.facts.compactMap { $0.lifecycle?.snoozedUntil }.filter { $0 > instant }.min())
                for facts in snapshot.facts where selected?.contains(facts.id) ?? true {
                    try Task.checkCancellation(); guard !closed else { return }
                    let instant = now()
                    if let until = facts.lifecycle?.snoozedUntil, let at = facts.lifecycle?.snoozedAt, until <= instant {
                        do { try await wake(.init(threadID: facts.id, expectedUntil: until, expectedSnoozedAt: at)) }
                        catch is CancellationError { if closed || Task.isCancelled { return } }
                        catch { }
                        continue
                    }
                    guard snapshot.policy.enabled else { continue }
                    guard WorkspaceLifecyclePolicyDecision.isAutoSettlementCandidate(facts, now: instant) else { continue }
                    do {
                        // An existing unknown/open linked request blocks age
                        // settlement too. No callback runs for unlinked threads.
                        let observations = facts.pullRequests.isEmpty ? [] : try await lookup(facts)
                        try Task.checkCancellation(); guard !closed else { return }
                        if var proposal = try WorkspaceLifecyclePolicyDecision.proposal(facts: facts, policy: snapshot.policy, observations: observations, now: now()) {
                            proposal.bindToSnapshot(snapshot.bindingID)
                            try await apply(proposal)
                        }
                    } catch is CancellationError { if closed || Task.isCancelled { return }; continue }
                    catch { continue } // A failed observation does not settle that thread.
                }
            } catch is CancellationError { if closed || Task.isCancelled { return }; continue }
            catch { continue }
        }
    }
}
