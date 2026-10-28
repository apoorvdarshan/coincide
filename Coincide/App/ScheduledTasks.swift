import AppKit
import CoincideKit

/// App lifetime and provider integration. Timers stop during sleep; no daemon or login item is installed.
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

    lazy var scheduler = TaskScheduler(store: schedules, now: clock,
        canStart: { [unowned self] in !self.hasActiveWork($0) },
        makeThread: { [unowned self] task in try self.makeThread(for: task) },
        startThread: { [unowned self] id, prompt in Task { await self.runner.send(threadID: id, text: prompt) } })

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
            case .runState(let id) where self.schedules.tasks.contains(where: { $0.lastThreadID == id }): self.changed()
            case .projects: self.changed()
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
            }
        })
        let center = NSWorkspace.shared.notificationCenter
        workspaceTokens.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.timer?.invalidate(); self?.timer = nil }
        })
        workspaceTokens.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduler.resume(afterRelaunch: false); self?.startTimer() }
        })
        scheduler.resume(afterRelaunch: true)
        startTimer()
    }

    func stop() {
        timer?.invalidate(); timer = nil
        tokens.forEach(NotificationCenter.default.removeObserver); tokens.removeAll()
        workspaceTokens.forEach(NSWorkspace.shared.notificationCenter.removeObserver); workspaceTokens.removeAll()
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

    /// Continued turns, quota resumes and background commands/subagents all block the next occurrence.
    func hasActiveWork(_ task: ScheduledTask) -> Bool {
        guard let id = task.lastThreadID else { return false }
        return runner.isRunning(id) || runner.scheduledResumes[id] != nil || !runner.backgroundTasks(id).isEmpty
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

    private func changed() { NotificationCenter.default.post(name: Self.didChange, object: self) }
}
