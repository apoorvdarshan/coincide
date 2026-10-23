import Darwin
import Foundation
import os

/// Counts output batches and input writes. SwiftTerm reports output on its parse
/// thread, so the count is lock-protected rather than main-actor state.
public final class TerminalActivityCounter: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: UInt64(0))
    public init() {}
    public var value: UInt64 { state.withLock { $0 } }
    public func increment() { state.withLock { $0 &+= 1 } }
}

/// Polls each running shell's process table off the main actor, about once a
/// second while anything may be running. Like T3, a session becomes quiet after
/// two idle samples with an unchanged activity mark, and quiet sessions are only
/// re-sampled every `quietSampleEvery` ticks until input or output arrives.
@MainActor
public final class TerminalActivityMonitor {
    public typealias Sampler = @Sendable (pid_t) -> TerminalProcessActivity?
    private struct Quiet { let pid: pid_t; let mark: UInt64; let snapshots: Int }
    private let interval: Duration
    private let quietSampleEvery: Int
    private let sampler: Sampler
    private let sessions: @MainActor () -> [LocalTerminalSession]
    private var quiet: [UUID: Quiet] = [:]
    private var skippedQuietTicks = 0
    private var task: Task<Void, Never>?
    private var generation = UUID()

    public init(interval: Duration = .seconds(1), quietSampleEvery: Int = 30,
                sampler: @escaping Sampler = { TerminalProcessInspector.inspect(shellPID: $0) },
                sessions: @escaping @MainActor () -> [LocalTerminalSession]) {
        self.interval = interval; self.quietSampleEvery = max(1, quietSampleEvery)
        self.sampler = sampler; self.sessions = sessions
    }

    /// Starts polling if a shell may be running; polling stops by itself when none are.
    public func wake() {
        guard task == nil, !running.isEmpty else { return }
        task = Task { [weak self, interval] in
            while !Task.isCancelled {
                guard let more = await self?.refresh(), more, !Task.isCancelled else { break }
                do { try await Task.sleep(for: interval) } catch { break }
            }
            // Main-actor continuation: no session can be added between the last
            // empty refresh and clearing the task.
            if !Task.isCancelled { self?.task = nil }
        }
    }

    /// Cancels polling until the next `wake()`.
    public func stop() { generation = UUID(); task?.cancel(); task = nil; quiet.removeAll(); skippedQuietTicks = 0 }

    /// One polling tick. Returns whether any session is still running.
    @discardableResult public func refresh() async -> Bool {
        let owner = generation
        let candidates = running
        guard !candidates.isEmpty else { quiet.removeAll(); return false }
        if candidates.allSatisfy(isQuiet), skippedQuietTicks < quietSampleEvery - 1 {
            skippedQuietTicks += 1; return true
        }
        skippedQuietTicks = 0
        let requests = candidates.map { (session: $0, pid: $0.processID, mark: $0.activityMark) }
        let sampler = sampler, pids = requests.map(\.pid)
        let samples = await Task.detached(priority: .utility) { pids.map { sampler($0) } }.value
        guard generation == owner, !Task.isCancelled else { return false }
        for (request, sample) in zip(requests, samples) {
            let session = request.session, previous = quiet.removeValue(forKey: session.id)
            guard let sample, session.lifecycle == .running, session.processID == request.pid else { continue }
            session.updateActivity(sample)
            if !sample.hasRunningSubprocess, session.activityMark == request.mark {
                let repeated = previous?.pid == request.pid && previous?.mark == request.mark
                quiet[session.id] = .init(pid: request.pid, mark: request.mark, snapshots: repeated ? 2 : 1)
            }
        }
        return true
    }

    /// Inspects now instead of trusting the last poll. Returns the sessions that are
    /// still at an idle prompt with an unchanged activity mark after sampling.
    public func idleSessions(_ candidates: [LocalTerminalSession]) async -> [LocalTerminalSession] {
        let owner = generation
        let requests = candidates.filter { $0.lifecycle == .running && !$0.isCommand && $0.processID > 0 }
            .map { (session: $0, pid: $0.processID, mark: $0.activityMark, generation: $0.displayGeneration, executable: $0.idleExecutableIdentity) }
        guard !requests.isEmpty else { return [] }
        let sampler = sampler, native = requests.map { (pid: $0.pid, executable: $0.executable) }
        let samples = await Task.detached(priority: .userInitiated) {
            native.map { (sample: sampler($0.pid), proof: TerminalProcessInspector.idleProof(shellPID: $0.pid, expectedExecutable: $0.executable)) }
        }.value
        guard generation == owner, !Task.isCancelled else { return [] }
        return zip(requests, samples).compactMap { request, observed in
            guard let sample = observed.sample else { return nil }
            let session = request.session
            guard session.lifecycle == .running, session.processID == request.pid else { return nil }
            session.updateActivity(sample)
            guard sample.canCloseWhenIdle, let proof = observed.proof,
                  session.recordIdleObservation(proof, generation: request.generation, mark: request.mark) else { return nil }
            return session
        }
    }

    private var running: [LocalTerminalSession] {
        sessions().filter { $0.lifecycle == .running && $0.processID > 0 }
    }
    private func isQuiet(_ session: LocalTerminalSession) -> Bool {
        guard let state = quiet[session.id] else { return false }
        return state.snapshots == 2 && state.pid == session.processID && state.mark == session.activityMark &&
            !session.activity.hasRunningSubprocess
    }
}
