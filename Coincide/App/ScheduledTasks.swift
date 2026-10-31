import AppKit
import CoincideKit

/// App lifetime and provider integration. Timers stop during sleep; no daemon or login item is installed.
///
/// Schedules fire only while Coincide runs. The background agent host (`CoincideAgentHost`) keeps a turn that is
/// already running alive after Coincide quits, but it can't start one: it owns provider sessions, not threads,
/// transcripts or the runner's recaps, so firing schedules from it would mean moving the turn runner and the store
/// into it. A run missed while Coincide was closed is skipped and reported, never sent late.
///
/// Thread schedules send their prompt into their own thread (`deliver`), bots' conversations included, and every
/// thread's agent can manage its own thread's schedules through `coincide_schedule` (`ScheduleBridge`,
/// `ScheduleAgentAccess`), which Settings › General can make wait for the user's approval.
final class ScheduledTasks {
    static let shared = ScheduledTasks()
    static let didChange = Notification.Name("coincide.scheduledTasksChanged")
    let schedules: ScheduledTaskStore
    private(set) var lastError: String?
    private let appStore: AppStore
    private let registry: ProviderRegistry
    private let runner: ThreadRunner
    private var timer: Timer?
    private var tokens: [NSObjectProtocol] = []
    private var workspaceTokens: [NSObjectProtocol] = []
    private var started = false
    private var storeObservation: ObservationToken?
    private let clock: () -> Date
    /// Opens the editor for a schedule an agent asked for, from its approval card's Edit button. The main window sets it.
    var onEditProposal: ((ScheduledTask) -> Void)?

    lazy var scheduler = TaskScheduler(store: schedules, now: clock,
        canStart: { [unowned self] in !self.hasActiveWork($0) },
        makeThread: { [unowned self] task in try self.makeThread(for: task) },
        startThread: { [unowned self] id, prompt in
            // Each run's thread opens with the schedule's message, marked with its name.
            let mark = self.schedules.tasks.first { $0.activeThreadID == id }.map { TranscriptItem.ScheduleMark(id: $0.id, name: $0.name) }
            Task { await self.runner.send(threadID: id, text: prompt, schedule: mark) }
        },
        threadState: { [unowned self] in self.threadState($0) },
        deliver: { [unowned self] task in try self.deliver(task) })

    lazy var agents: ScheduleAgentAccess = {
        let access = ScheduleAgentAccess(scheduler: scheduler, now: clock)
        access.requiresApproval = { [unowned self] in self.appStore.settings.approvesAgentSchedules }
        access.projectOf = { [unowned self] in self.appStore.summary($0)?.projectID }
        access.appendCard = { [unowned self] threadID, item in _ = self.appStore.append(item, to: threadID) }
        access.updateCard = { [unowned self] threadID, itemID, change in self.appStore.updateItem(itemID, in: threadID, change) }
        return access
    }()

    private(set) lazy var bridge = ScheduleBridge { [unowned self] request, threadID in
        guard self.appStore.summary(threadID) != nil else { throw ScheduleError.threadMissing }
        return try self.agents.handle(request, threadID: threadID)
    }

    init(store: AppStore = .shared, registry: ProviderRegistry = .shared, runner: ThreadRunner = .shared,
        now: @escaping () -> Date = Date.init) {
        appStore = store; self.registry = registry; self.runner = runner; clock = now
        schedules = ScheduledTaskStore(directory: store.directory)
        schedules.onChange = { [weak self] in self?.changed() }
    }

    func start() {
        guard !started else { return }
        started = true
        storeObservation = appStore.observe { [weak self] change in
            guard let self else { return }
            switch change {
            case .runState(let id) where self.schedules.tasks.contains(where: { $0.lastThreadID == id || $0.threadID == id }):
                self.changed()
            case .projects: self.changed()
            case .threadList:
                // Archiving, unarchiving, deleting or restoring a thread pauses or resumes its schedules.
                self.scheduler.reconcileThreads()
                for id in self.schedules.tasks.compactMap(\.threadID) where self.appStore.summary(id) == nil {
                    self.bridge.disable(threadID: id)
                }
                self.changed()
            default: break
            }
        }
        scheduler.onFailure = { [weak self] error in self?.lastError = error.localizedDescription; self?.changed() }
        tokens.append(NotificationCenter.default.addObserver(forName: ThreadRunner.turnFinishedNotification, object: runner, queue: .main) { [weak self] note in
            guard let id = note.userInfo?["threadID"] as? UUID, let outcome = note.userInfo?["outcome"] as? TurnOutcome else { return }
            MainActor.assumeIsolated {
                switch outcome {
                case .completed: self?.scheduler.finished(threadID: id, outcome: .completed)
                case .interrupted: self?.scheduler.finished(threadID: id, outcome: .interrupted)
                case .failed(let message): self?.scheduler.finished(threadID: id, outcome: .failed, message: message)
                }
                // A run that waited for this thread goes once the runner has sent what the user queued there.
                guard self?.schedules.tasks.contains(where: { $0.threadID == id && $0.pendingDelivery != nil }) == true else { return }
                DispatchQueue.main.async { self?.scheduler.tick() }
            }
        })
        let center = NSWorkspace.shared.notificationCenter
        workspaceTokens.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.timer?.invalidate(); self?.timer = nil }
        })
        workspaceTokens.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduler.resume(afterRelaunch: false); self?.startTimer() }
        })
        runner.ephemeralRuntimeContexts["schedule"] = { [weak self] id in self?.runtimeContext(for: id) }
        runner.localApprovals[ScheduleAgentAccess.requestPrefix] = { [weak self] threadID, itemID, optionID in
            self?.respond(threadID: threadID, itemID: itemID, optionID: optionID)
        }
        Task { [weak self] in
            do { try await self?.bridge.prepare() } catch { self?.lastError = error.localizedDescription }
        }
        scheduler.resume(afterRelaunch: true)
        scheduler.reconcileThreads()
        startTimer()
    }

    func stop() {
        timer?.invalidate(); timer = nil
        tokens.forEach(NotificationCenter.default.removeObserver); tokens.removeAll()
        workspaceTokens.forEach(NSWorkspace.shared.notificationCenter.removeObserver); workspaceTokens.removeAll()
        runner.ephemeralRuntimeContexts.removeValue(forKey: "schedule")
        runner.localApprovals.removeValue(forKey: ScheduleAgentAccess.requestPrefix)
        bridge.stop()
        started = false
        storeObservation = nil
    }

    private func startTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduler.tick() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    // MARK: Runs

    /// Continued turns, quota resumes and background commands/subagents all block the next occurrence.
    func hasActiveWork(_ task: ScheduledTask) -> Bool {
        guard let id = task.threadID ?? task.lastThreadID else { return false }
        return runner.isRunning(id) || runner.scheduledResumes[id] != nil || !runner.backgroundTasks(id).isEmpty
    }

    /// Whether a thread schedule's run can go into its thread now. Messages the user queued there go first.
    func threadState(_ id: UUID) -> ScheduleThreadState {
        guard let thread = appStore.summary(id) else { return .missing }
        if thread.isArchived { return .archived }
        if runner.isRunning(id) || runner.scheduledResumes[id] != nil || !runner.backgroundTasks(id).isEmpty
            || !runner.queuedMessages(id).isEmpty
        {
            return .busy
        }
        return .ready
    }

    /// Sends a thread schedule's prompt into its thread as the user's next message, with the thread's own agent,
    /// model, access and mode, marked with the schedule's name.
    func deliver(_ task: ScheduledTask) throws {
        guard let id = task.threadID, let thread = appStore.summary(id) else { throw ScheduleError.threadMissing }
        guard registry.status(thread.selection.provider).state == .ready else { throw ScheduleError.unavailableProvider }
        let mark = TranscriptItem.ScheduleMark(id: task.id, name: task.name)
        Task { await runner.send(threadID: id, text: task.prompt, schedule: mark) }
    }

    /// `createThread` applies project defaults; the ready-provider fallback retains those access/interaction modes.
    func makeThread(for task: ScheduledTask) throws -> UUID {
        guard let project = appStore.project(task.projectID), FileManager.default.fileExists(atPath: project.url.path) else {
            throw ScheduleError.missingProject
        }
        guard !registry.readyKinds.isEmpty else { throw ScheduleError.unavailableProvider }
        let thread = appStore.createThread(in: project.id)
        let selection = registry.usableSelection(preferring: thread.selection)
        guard registry.status(selection.provider).state == .ready else {
            appStore.deleteThread(thread.id)
            throw ScheduleError.unavailableProvider
        }
        appStore.updateThread(thread.id) { $0.selection = selection }
        appStore.flush()
        return thread.id
    }

    // MARK: Agents

    /// The `coincide_schedule` block added to a message an agent gets in `id`, with the thread's capability.
    func runtimeContext(for id: UUID) -> String? {
        guard appStore.summary(id) != nil, let access = bridge.enableNow(threadID: id) else { return nil }
        return ScheduleAgentAccess.instructions(
            configuration: access.configuration, requiresApproval: appStore.settings.approvesAgentSchedules, timeZone: .current)
    }

    /// The user's answer on an approval card, from the Mac's banner or Coincide Remote's.
    func respond(threadID: UUID, itemID: UUID, optionID: String) {
        switch agents.respond(threadID: threadID, itemID: itemID, optionID: optionID) {
        case .edit(let id):
            guard var task = schedules.task(id) else { return }
            if let proposal = task.proposal {
                task.name = proposal.name; task.prompt = proposal.prompt; task.recurrence = proposal.recurrence
            }
            onEditProposal?(task)
        case .allowed, .declined, .gone:
            break
        }
        changed()
    }

    /// Saves what the user changed in the editor: allowing it too when it was an agent's request.
    func save(_ task: ScheduledTask) throws {
        if schedules.task(task.id)?.proposal != nil { try agents.approve(task.id, edited: task) } else { try scheduler.save(task) }
    }

    /// Deletes a schedule, closing an approval card still waiting for it.
    func delete(_ id: UUID) throws {
        guard let task = schedules.task(id) else { return }
        try schedules.delete(id)
        agents.deleted(task)
    }

    // MARK: Queries

    /// The thread's schedules, soonest first.
    func tasks(inThread id: UUID) -> [ScheduledTask] {
        schedules.tasks.filter { $0.threadID == id }.sorted(by: Self.soonestFirst)
    }

    /// The thread's next run, among its active schedules.
    func nextRun(inThread id: UUID) -> (date: Date, task: ScheduledTask)? {
        schedules.tasks.filter { $0.threadID == id && $0.isActive }
            .compactMap { task in (task.pendingDelivery ?? task.nextRunAt).map { ($0, task) } }
            .min { $0.0 < $1.0 }
    }

    static func soonestFirst(_ lhs: ScheduledTask, _ rhs: ScheduledTask) -> Bool {
        let left = lhs.isActive ? lhs.nextRunAt ?? .distantFuture : .distantFuture
        let right = rhs.isActive ? rhs.nextRunAt ?? .distantFuture : .distantFuture
        return left == right ? lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending : left < right
    }

    private func changed() { NotificationCenter.default.post(name: Self.didChange, object: self) }
}
