import Foundation

/// Scheduling policy independent of timers and providers, with an injected wall clock for DST and restart tests.
@MainActor public final class TaskScheduler {
    public let store: ScheduledTaskStore
    public var onFailure: ((Error) -> Void)?
    private let now: () -> Date
    private let makeThread: (ScheduledTask) throws -> UUID
    private let startThread: (UUID, String) -> Void
    private let canStart: (ScheduledTask) -> Bool
    private var ticking = false

    public init(store: ScheduledTaskStore, now: @escaping () -> Date = Date.init,
        canStart: @escaping (ScheduledTask) -> Bool = { _ in true },
        makeThread: @escaping (ScheduledTask) throws -> UUID, startThread: @escaping (UUID, String) -> Void) {
        self.store = store; self.now = now; self.makeThread = makeThread; self.startThread = startThread; self.canStart = canStart
    }

    /// Relaunch and wake skip missed occurrences instead of creating a backlog. A prior process's active run is
    /// marked interrupted, never automatically resumed; an agent still running after machine sleep is preserved.
    public func resume(afterRelaunch: Bool) {
        let date = now()
        for var task in store.tasks {
            var changed = false
            if afterRelaunch, task.activeThreadID != nil {
                task.activeThreadID = nil
                task.lastOutcome = .interrupted
                task.lastFinishedAt = date
                task.lastMessage = String(localized: "Coincide closed before the task finished. Open its thread to continue.")
                changed = true
            }
            if let next = task.nextRunAt, next <= date {
                task.nextRunAt = task.recurrence.next(after: date)
                if task.activeThreadID == nil && task.lastOutcome != .interrupted {
                    task.lastOutcome = .missed
                    task.lastMessage = String(localized: "A run was skipped while Coincide was closed or the Mac was asleep.")
                }
                changed = true
            }
            if changed { do { try store.save(task) } catch { onFailure?(error) } }
        }
    }

    public func save(_ value: ScheduledTask) throws {
        var task = value
        guard task.isValid else { throw ScheduleError.invalidTask }
        let old = store.task(task.id)
        if task.recurrence.kind == .once, task.recurrence.date <= now(), old?.recurrence != task.recurrence, task.activeThreadID == nil {
            throw ScheduleError.pastDate
        }
        if var current = old {
            // An editor may have been open while a run started or finished. Preserve live execution state.
            current.name = task.name; current.projectID = task.projectID; current.prompt = task.prompt
            current.recurrence = task.recurrence; current.isPaused = task.isPaused
            task = current
        }
        if old == nil || old?.recurrence != task.recurrence || old?.isPaused == true && !task.isPaused {
            task.nextRunAt = task.recurrence.next(after: now())
        }
        try store.save(task)
    }

    public func setPaused(_ id: UUID, _ paused: Bool) throws {
        guard var task = store.task(id) else { return }
        task.isPaused = paused
        if !paused { task.nextRunAt = task.recurrence.next(after: now()) }
        try store.save(task)
    }

    public func tick() {
        guard !ticking else { return }
        ticking = true
        defer { ticking = false }
        let date = now()
        for var task in store.tasks where !task.isPaused && (task.nextRunAt ?? .distantFuture) <= date {
            do {
                if task.activeThreadID != nil || !canStart(task) {
                    // Continued work and quota resumes consume overlapping slots too; never queue a late run.
                    task.nextRunAt = task.recurrence.next(after: date)
                    try store.save(task)
                } else { try run(task.id, manual: false) }
            } catch { onFailure?(error) }
        }
    }

    public func runNow(_ id: UUID) throws { try run(id, manual: true) }

    private func run(_ id: UUID, manual: Bool) throws {
        guard var task = store.task(id) else { return }
        guard task.activeThreadID == nil, canStart(task) else { throw ScheduleError.alreadyRunning }
        let date = now()
        let occurrence = manual ? date : (task.nextRunAt ?? date)
        if !manual, let consumed = task.lastFiredOccurrence, occurrence <= consumed {
            task.nextRunAt = task.recurrence.next(after: date)
            try store.save(task)
            return
        }
        // Advance before launching, so a crash cannot submit the same scheduled occurrence twice.
        if task.recurrence.kind == .once { task.nextRunAt = nil }
        else if !manual || (task.nextRunAt ?? .distantPast) <= date {
            task.nextRunAt = task.recurrence.next(after: date)
        }
        do {
            let threadID = try makeThread(task)
            task.activeThreadID = threadID
            task.lastThreadID = threadID
            task.lastRunAt = date
            task.lastFiredOccurrence = occurrence
            task.lastOutcome = nil
            task.lastMessage = nil
            task.lastFinishedAt = nil
            try store.save(task)
            startThread(threadID, task.prompt)
        } catch {
            task.activeThreadID = nil
            task.lastOutcome = .failed
            task.lastMessage = error.localizedDescription
            task.lastFinishedAt = date
            // Invalid configuration needs attention, rather than retrying every timer tick.
            task.isPaused = true
            try store.save(task)
            throw error
        }
    }

    public func finished(threadID: UUID, outcome: ScheduledTask.Outcome, message: String? = nil) {
        guard var task = store.tasks.first(where: { $0.activeThreadID == threadID }) else { return }
        let date = now()
        task.activeThreadID = nil
        task.lastOutcome = outcome
        task.lastMessage = message
        task.lastFinishedAt = date
        // A long run consumes any slots it overlaps; the next run is always in the future.
        if (task.nextRunAt ?? .distantFuture) <= date { task.nextRunAt = task.recurrence.next(after: date) }
        do { try store.save(task) } catch { onFailure?(error) }
    }
}
