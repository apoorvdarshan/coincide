import Foundation

/// What a thread schedule's thread can take when one of its runs comes due.
public enum ScheduleThreadState: Equatable, Sendable {
    /// Idle: the run is sent now.
    case ready
    /// A turn, a queued message, a usage-limit resume or background work is under way: the run waits for it.
    case busy
    case archived
    /// Deleted (or never loaded).
    case missing
}

/// Scheduling policy independent of timers and providers, with an injected wall clock for DST and restart tests.
///
/// A project task starts a new thread for each run (`makeThread`, `startThread`). A thread schedule sends its prompt
/// into its own thread (`deliver`) as a new message from the user; when that thread is busy at fire time the run waits,
/// once, until it is idle (`pendingDelivery`), rather than interrupting it or piling up runs.
@MainActor public final class TaskScheduler {
    public let store: ScheduledTaskStore
    public var onFailure: ((Error) -> Void)?
    private let now: () -> Date
    private let makeThread: (ScheduledTask) throws -> UUID
    private let startThread: (UUID, String) -> Void
    private let canStart: (ScheduledTask) -> Bool
    private let threadState: (UUID) -> ScheduleThreadState
    private let deliver: (ScheduledTask) throws -> Void
    private var ticking = false
    /// Failed runtime transitions must survive until storage recovers. No dispatch may pass these
    /// writes, otherwise an old active marker can stick forever or a skipped occurrence can launch.
    private var pendingTransitions: [UUID: ScheduledTask] = [:]

    public init(store: ScheduledTaskStore, now: @escaping () -> Date = Date.init,
        canStart: @escaping (ScheduledTask) -> Bool = { _ in true },
        makeThread: @escaping (ScheduledTask) throws -> UUID, startThread: @escaping (UUID, String) -> Void,
        threadState: @escaping (UUID) -> ScheduleThreadState = { _ in .ready },
        deliver: @escaping (ScheduledTask) throws -> Void = { _ in }) {
        self.store = store; self.now = now; self.makeThread = makeThread; self.startThread = startThread; self.canStart = canStart
        self.threadState = threadState; self.deliver = deliver
    }

    /// Relaunch and wake skip missed occurrences instead of creating a backlog. A prior process's active run is
    /// marked interrupted, never automatically resumed; an agent still running after machine sleep is preserved.
    /// A thread schedule's run that was waiting for its busy thread when Coincide quit is skipped like a missed one.
    public func resume(afterRelaunch: Bool) {
        let date = now()
        for saved in store.tasks {
            var task = pendingTransitions[saved.id] ?? saved
            var changed = false
            if afterRelaunch, task.activeThreadID != nil {
                task.activeThreadID = nil
                task.lastOutcome = .interrupted
                task.lastFinishedAt = date
                task.lastMessage = String(localized: "Coincide closed before the task finished. Open its thread to continue.")
                changed = true
            }
            if afterRelaunch, task.pendingDelivery != nil {
                task.pendingDelivery = nil
                task.lastOutcome = .missed
                task.lastMessage = String(localized: "A run was skipped: its thread was busy when Coincide closed.")
                changed = true
            }
            if let next = task.nextRunAt, next <= date {
                task.nextRunAt = task.recurrence.next(after: date)
                if task.activeThreadID == nil && task.lastOutcome != .interrupted && !task.isAwaitingApproval {
                    task.lastOutcome = .missed
                    task.lastMessage = String(localized: "A run was skipped while Coincide was closed or the Mac was asleep.")
                }
                changed = true
            }
            if changed { do { try persistTransition(task) } catch { onFailure?(error) } }
        }
    }

    public func save(_ value: ScheduledTask) throws {
        try retryTransitions()
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
            // Pausing or resuming by hand takes over from a pause Coincide made.
            if current.isPaused != old?.isPaused { current.pauseReason = nil }
            if current.isPaused { current.pendingDelivery = nil }
            task = current
        }
        if old == nil || old?.recurrence != task.recurrence {
            task.nextRunAt = task.recurrence.next(after: now())
        } else if old?.isPaused == true && !task.isPaused {
            task.nextRunAt = nextAfterUnpausing(task)
        }
        try store.save(task)
    }

    public func setPaused(_ id: UUID, _ paused: Bool) throws {
        try retryTransitions()
        guard var task = store.task(id) else { return }
        if !paused, let threadID = task.threadID {
            switch threadState(threadID) {
            case .missing: throw ScheduleError.threadMissing
            case .archived: throw ScheduleError.threadArchived
            case .ready, .busy: break
            }
        }
        task.isPaused = paused
        task.pauseReason = nil
        if paused { task.pendingDelivery = nil } else { task.nextRunAt = nextAfterUnpausing(task) }
        try store.save(task)
    }

    /// Pauses thread schedules whose thread was archived or deleted, saying why, and resumes the ones Coincide paused
    /// once their thread is back. Schedules the user paused stay paused.
    public func reconcileThreads() {
        for saved in store.tasks {
            guard let threadID = saved.threadID else { continue }
            var task = pendingTransitions[saved.id] ?? saved
            let state = threadState(threadID)
            let reason: ScheduledTask.PauseReason? =
                switch state {
                case .archived: .threadArchived
                case .missing: .threadDeleted
                case .ready, .busy: nil
                }
            if let reason, !task.isPaused || (task.pauseReason != nil && task.pauseReason != reason) {
                task.isPaused = true
                task.pauseReason = reason
                task.pendingDelivery = nil
            } else if reason == nil, task.isPaused, task.pauseReason != nil {
                task.isPaused = false
                task.pauseReason = nil
                task.nextRunAt = nextAfterUnpausing(task)
            } else {
                continue
            }
            do { try persistTransition(task) } catch { onFailure?(error) }
        }
    }

    public func tick() {
        guard !ticking else { return }
        ticking = true
        defer { ticking = false }
        do { try retryTransitions() } catch { onFailure?(error); return }
        let date = now()
        for var task in store.tasks where task.isActive {
            let due = (task.nextRunAt ?? .distantFuture) <= date
            guard due || task.pendingDelivery != nil else { continue }
            do {
                if task.threadID != nil {
                    try fireThreadSchedule(task.id, manual: false)
                } else if task.activeThreadID != nil || !canStart(task) {
                    // Continued work and quota resumes consume overlapping slots too; never queue a late run.
                    task.nextRunAt = task.recurrence.next(after: date)
                    try persistTransition(task)
                } else { try run(task.id, manual: false) }
            } catch {
                onFailure?(error)
                if !pendingTransitions.isEmpty { return }
            }
        }
    }

    public func runNow(_ id: UUID) throws {
        try retryTransitions()
        guard let task = store.task(id) else { return }
        guard !task.isAwaitingApproval else { throw ScheduleError.awaitingApproval }
        if task.threadID != nil { try fireThreadSchedule(id, manual: true) } else { try run(id, manual: true) }
    }

    private func run(_ id: UUID, manual: Bool) throws {
        guard var task = store.task(id) else { return }
        guard task.activeThreadID == nil, canStart(task) else { throw ScheduleError.alreadyRunning }
        let date = now()
        let occurrence = manual ? date : (task.nextRunAt ?? date)
        if !manual, let consumed = task.lastFiredOccurrence, occurrence <= consumed {
            task.nextRunAt = task.recurrence.next(after: date)
            try persistTransition(task)
            return
        }
        // Advance before launching, so a crash cannot submit the same scheduled occurrence twice.
        advance(&task, manual: manual, at: date)
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
            try fail(&task, error, at: date)
            throw error
        }
    }

    /// A thread schedule's run: sent into its thread now when the thread is idle, otherwise kept until it is. An
    /// occurrence that comes due while one already waits is skipped, so a long busy spell sends one run, not a backlog.
    private func fireThreadSchedule(_ id: UUID, manual: Bool) throws {
        guard var task = store.task(id), let threadID = task.threadID else { return }
        let date = now()
        let due = (task.nextRunAt ?? .distantFuture) <= date
        let state = threadState(threadID)
        switch state {
        case .missing, .archived:
            // Paused, saying why; a timer tick has nothing else to report.
            reconcileThreads()
            if manual { throw state == .missing ? ScheduleError.threadMissing : ScheduleError.threadArchived }
        case .busy:
            if manual || due {
                let occurrence = manual ? date : (task.nextRunAt ?? date)
                if !manual, let consumed = task.lastFiredOccurrence, occurrence <= consumed {
                    task.nextRunAt = task.recurrence.next(after: date)
                } else {
                    if task.pendingDelivery == nil { task.pendingDelivery = occurrence }
                    // Consumed before it is sent, so a crash cannot send the same occurrence twice.
                    task.lastFiredOccurrence = max(task.lastFiredOccurrence ?? .distantPast, occurrence)
                    advance(&task, manual: manual, at: date)
                }
                try persistTransition(task)
            }
        case .ready:
            let occurrence: Date
            if let pending = task.pendingDelivery, !manual {
                occurrence = pending
                if due { advance(&task, manual: false, at: date) }
            } else {
                occurrence = manual ? date : (task.nextRunAt ?? date)
                if !manual, task.pendingDelivery == nil, let consumed = task.lastFiredOccurrence, occurrence <= consumed {
                    task.nextRunAt = task.recurrence.next(after: date)
                    try persistTransition(task)
                    return
                }
                advance(&task, manual: manual, at: date)
            }
            task.pendingDelivery = nil
            task.activeThreadID = threadID
            task.lastThreadID = threadID
            task.lastRunAt = date
            task.lastFiredOccurrence = max(task.lastFiredOccurrence ?? .distantPast, occurrence)
            task.lastOutcome = nil
            task.lastMessage = nil
            task.lastFinishedAt = nil
            do {
                try store.save(task)
                try deliver(task)
            } catch {
                try fail(&task, error, at: date)
                throw error
            }
        }
    }

    private func advance(_ task: inout ScheduledTask, manual: Bool, at date: Date) {
        if task.recurrence.kind == .once { task.nextRunAt = nil }
        else if !manual || (task.nextRunAt ?? .distantPast) <= date {
            task.nextRunAt = task.recurrence.next(after: date)
        }
    }

    private func fail(_ task: inout ScheduledTask, _ error: Error, at date: Date) throws {
        task.activeThreadID = nil
        task.pendingDelivery = nil
        task.lastOutcome = .failed
        task.lastMessage = error.localizedDescription
        task.lastFinishedAt = date
        // Invalid configuration needs attention, rather than retrying every timer tick.
        task.isPaused = true
        try persistTransition(task)
    }

    public func finished(threadID: UUID, outcome: ScheduledTask.Outcome, message: String? = nil) {
        guard var task = store.tasks.lazy.map({ self.pendingTransitions[$0.id] ?? $0 })
            .first(where: { $0.activeThreadID == threadID }) else { return }
        let date = now()
        task.activeThreadID = nil
        task.lastOutcome = outcome
        task.lastMessage = message
        task.lastFinishedAt = date
        // A long run consumes any slots it overlaps; the next run is always in the future.
        if (task.nextRunAt ?? .distantFuture) <= date, task.threadID == nil { task.nextRunAt = task.recurrence.next(after: date) }
        do { try persistTransition(task) } catch { onFailure?(error) }
    }

    // MARK: Approval

    /// Records what an agent asked to change, with its approval card. A schedule still waiting to be allowed takes the
    /// change at once (it can't run anyway); an allowed one keeps running as it was until the user allows it.
    public func propose(_ id: UUID, _ proposal: ScheduleProposal) throws {
        try retryTransitions()
        guard var task = store.task(id) else { throw ScheduleError.notFound }
        task.proposal = proposal
        if task.isAwaitingApproval {
            task.name = proposal.name; task.prompt = proposal.prompt
            if task.recurrence != proposal.recurrence {
                task.recurrence = proposal.recurrence
                task.nextRunAt = proposal.recurrence.next(after: now())
            }
        }
        try store.save(task)
    }

    /// Allows what an agent created or changed: `edited` when the user changed it first, else as proposed.
    public func approve(_ id: UUID, edited: ScheduledTask? = nil) throws {
        try retryTransitions()
        guard var task = store.task(id) else { throw ScheduleError.notFound }
        if let proposal = task.proposal {
            task.name = proposal.name; task.prompt = proposal.prompt; task.recurrence = proposal.recurrence
        }
        if let edited {
            task.name = edited.name; task.prompt = edited.prompt; task.recurrence = edited.recurrence; task.isPaused = edited.isPaused
        }
        guard task.isValid else { throw ScheduleError.invalidTask }
        if task.recurrence.kind == .once, task.recurrence.date <= now() { throw ScheduleError.pastDate }
        task.proposal = nil
        task.awaitingApproval = nil
        task.nextRunAt = task.recurrence.next(after: now())
        try store.save(task)
    }

    /// Declines what an agent asked for: a new schedule goes away, a change is dropped and the schedule stays as it was.
    public func decline(_ id: UUID) throws {
        try retryTransitions()
        guard var task = store.task(id) else { return }
        if task.isAwaitingApproval {
            try store.delete(id)
        } else if task.proposal != nil {
            task.proposal = nil
            try store.save(task)
        }
    }

    private func nextAfterUnpausing(_ task: ScheduledTask) -> Date? {
        // Run Now consumes a one-time occurrence even before its original date. Pause/Resume and
        // ordinary edits must not rearm it; choosing a different occurrence explicitly may do so.
        if task.recurrence.kind == .once, task.nextRunAt == nil { return nil }
        return task.recurrence.next(after: now())
    }

    private func persistTransition(_ task: ScheduledTask) throws {
        pendingTransitions[task.id] = task
        try store.save(task)
        pendingTransitions[task.id] = nil
    }

    private func retryTransitions() throws {
        let date = now()
        for (id, var task) in pendingTransitions {
            // Deleting a task remains effective even if an earlier completion could not be saved.
            guard store.task(id) != nil else { pendingTransitions[id] = nil; continue }
            if let next = task.nextRunAt, next <= date { task.nextRunAt = task.recurrence.next(after: date) }
            try persistTransition(task)
        }
    }
}
