import AppKit
import Testing
@testable import Coincide
@testable import CoincideKit

@MainActor private final class ScheduledTestProvider: AgentProvider {
    let kind = ProviderKind.codex
    let executableNames = ["sh"]
    let setupHint = ""
    var sessions: [ScheduledTestSession] = []
    func detect(executable: URL?, environment: [String: String]) async -> ProviderStatus { ProviderStatus(state: .ready) }
    func models(status: ProviderStatus, environment: [String: String]) async -> [ModelOption] {
        [ModelOption(provider: .codex, modelID: "scheduled-test", displayName: "Test")]
    }
    func makeSession(_ launch: AgentLaunch) -> AgentSession {
        let session = ScheduledTestSession()
        sessions.append(session)
        return session
    }
}

/// No subprocess: the turn completes while its reported subagent keeps working.
@MainActor private final class ScheduledTestSession: AgentSession, BackgroundWorkReporting {
    let provider = ProviderKind.codex
    let sessionID: String? = UUID().uuidString
    var onEvent: ((AgentEvent) -> Void)?
    private(set) var hasBackgroundWork = false
    func start() async throws { onEvent?(.sessionStarted(id: sessionID!)) }
    func send(_ input: AgentTurnInput) async throws {
        hasBackgroundWork = true
        onEvent?(.backgroundWork([BackgroundTask(id: "audit", title: "Review changes", kind: .agent)]))
        onEvent?(.turnCompleted(.completed))
    }
    func finishBackgroundWork() {
        hasBackgroundWork = false
        onEvent?(.backgroundWork([]))
    }
    func respond(to approvalID: String, optionID: String) {}
    func interrupt() { onEvent?(.turnCompleted(.interrupted)) }
    func shutdown() {}
}

@MainActor @Suite(.serialized) struct ScheduledTaskUITests {
    @Test func eachRunCreatesAFreshThreadAndFallbackPreservesAccessSettings() async throws {
        let directory = TemporaryDirectory("scheduled-task-ui")
        let store = AppStore(directory: directory.url)
        store.updateSettings { $0.defaultSelection = ModelSelection(provider: .claude, modelID: "unavailable"); $0.defaultAccessMode = .approval }
        let registry = ProviderRegistry(store: store, providers: [ScheduledTestProvider()])
        await registry.refresh()
        let runner = ThreadRunner(store: store, registry: registry)
        let service = ScheduledTasks(store: store, registry: registry, runner: runner)
        let project = store.addProject(at: directory.url)
        let existing = store.createThread(in: project.id)
        let task = ScheduledTask(name: "Review", projectID: project.id, prompt: "Review changes", recurrence: TaskRecurrence())
        let first = try service.makeThread(for: task), second = try service.makeThread(for: task)
        #expect(first != second && first != existing.id && second != existing.id)
        #expect(store.thread(first)?.selection.provider == .codex)
        #expect(store.thread(first)?.selection.modelID == "scheduled-test")
        #expect(store.thread(first)?.accessMode == .approval)
        #expect(store.thread(first)?.items.isEmpty == true)
        #expect(!runner.isRunning(first))
    }

    @Test func scheduledRunsInheritCurrentProjectDefaultsWithoutChangingEarlierThreads() async throws {
        let directory = TemporaryDirectory("scheduled-project-defaults")
        let store = AppStore(directory: directory.url)
        store.updateSettings {
            $0.defaultAccessMode = .approval
        }
        let registry = ProviderRegistry(store: store, providers: [ScheduledTestProvider()])
        await registry.refresh()
        let runner = ThreadRunner(store: store, registry: registry)
        let service = ScheduledTasks(store: store, registry: registry, runner: runner)
        let project = store.addProject(at: directory.url)
        store.updateProject(project.id) {
            $0.threadDefaults = ProjectThreadDefaults(
                selection: ModelSelection(provider: .claude, modelID: "unavailable"),
                accessMode: .fullAccess, interactionMode: .plan)
        }
        let task = ScheduledTask(name: "Review", projectID: project.id, prompt: "Review changes", recurrence: TaskRecurrence())
        let first = try service.makeThread(for: task)
        #expect(store.thread(first)?.selection.provider == .codex)
        #expect(store.thread(first)?.selection.modelID == "scheduled-test")
        #expect(store.thread(first)?.accessMode == .fullAccess)
        #expect(store.thread(first)?.interactionMode == .plan)
        store.updateProject(project.id) { $0.threadDefaults = nil }
        let second = try service.makeThread(for: task)
        #expect(second != first)
        #expect(store.thread(second)?.accessMode == .approval)
        #expect(store.thread(second)?.interactionMode == .build)
        #expect(store.thread(first)?.accessMode == .fullAccess)
        #expect(store.thread(first)?.interactionMode == .plan)
    }

    @Test func backgroundSubagentOutlastingTheTurnSkipsTheNextScheduledSlot() async throws {
        let directory = TemporaryDirectory("scheduled-background-work")
        let store = AppStore(directory: directory.url)
        store.updateSettings {
            $0.checkpointsEnabled = false
            $0.generatesThreadTitles = false
            $0.defaultSelection = ModelSelection(provider: .codex, modelID: "scheduled-test")
        }
        let provider = ScheduledTestProvider()
        let registry = ProviderRegistry(store: store, providers: [provider])
        await registry.refresh()
        let runner = ThreadRunner(store: store, registry: registry)
        let project = store.addProject(at: directory.url)
        let firstOccurrence = ISO8601DateFormatter().date(from: "2026-10-28T09:00:00Z")!
        var now = firstOccurrence.addingTimeInterval(-3600)
        let service = ScheduledTasks(store: store, registry: registry, runner: runner, now: { now })
        let task = ScheduledTask(name: "Review", projectID: project.id, prompt: "Review changes",
            recurrence: TaskRecurrence(kind: .daily, timeZoneID: "UTC", hour: 9), now: now)
        try service.scheduler.save(task)
        service.start()
        defer { service.stop(); runner.shutdownAll(); store.flush() }

        now = firstOccurrence
        service.scheduler.tick()
        try await waitForRuns(1, service: service, provider: provider, taskID: task.id)
        let last = try #require(service.schedules.task(task.id))
        let threadID = try #require(last.lastThreadID)
        #expect(!runner.isRunning(threadID))
        #expect(!runner.backgroundTasks(threadID).isEmpty)
        #expect(service.hasActiveWork(last))

        now = firstOccurrence.addingTimeInterval(86_400)
        service.scheduler.tick()
        #expect(service.schedules.task(task.id)?.lastThreadID == threadID)
        #expect(service.schedules.task(task.id)?.nextRunAt == firstOccurrence.addingTimeInterval(172_800))
        #expect(throws: ScheduleError.self) { try service.scheduler.runNow(task.id) }

        try #require(provider.sessions.first).finishBackgroundWork()
        #expect(!service.hasActiveWork(last))
        service.scheduler.tick()
        #expect(service.schedules.task(task.id)?.activeThreadID == nil)
        #expect(provider.sessions.count == 1)
        now = firstOccurrence.addingTimeInterval(172_800)
        service.scheduler.tick()
        try await waitForRuns(2, service: service, provider: provider, taskID: task.id)
        #expect(service.schedules.task(task.id)?.lastThreadID != threadID)
    }

    private func waitForRuns(_ count: Int, service: ScheduledTasks, provider: ScheduledTestProvider, taskID: UUID) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while (provider.sessions.count < count || service.schedules.task(taskID)?.activeThreadID != nil), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(provider.sessions.count == count)
        try #require(service.schedules.task(taskID)?.activeThreadID == nil)
    }

    @Test func saveFailureKeepsThePromptAndTimeZoneEditable() throws {
        let directory = TemporaryDirectory("schedule-editor")
        let store = AppStore(directory: directory.url)
        let project = store.addProject(at: directory.url)
        let task = ScheduledTask(name: "Daily review", projectID: project.id, prompt: "Review the open changes",
            recurrence: TaskRecurrence(kind: .daily, timeZoneID: "UTC", hour: 9, minute: 15))
        let editor = ScheduledTaskEditor(task: task, isNew: false, store: store)
        let prompt = try #require(descendants(editor.view).compactMap { $0 as? NSTextView }.first)
        let save = try #require(descendants(editor.view).compactMap { $0 as? NSButton }.first { $0.title == "Save" })
        var attempted: ScheduledTask?
        editor.onSave = { value in attempted = value; throw ScheduleError.storage("Fixture failure") }
        save.performClick(nil)
        #expect(attempted?.prompt == task.prompt)
        #expect(attempted?.recurrence.timeZoneID == "UTC")
        #expect(attempted?.recurrence.hour == 9 && attempted?.recurrence.minute == 15)
        #expect(prompt.isEditable && prompt.string == task.prompt)
        #expect(descendants(editor.view).compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("Fixture failure") })
    }

    @Test func nextRunShowsTheSchedulesZoneAndFailedPausedStateIsVisible() {
        // A zone other than the Mac's, whose name the time then carries.
        let zone = TimeZone.current.identifier == "Asia/Kolkata" ? "Europe/Paris" : "Asia/Kolkata"
        var task = ScheduledTask(name: "Review", projectID: UUID(), prompt: "Review",
            recurrence: TaskRecurrence(timeZoneID: zone))
        task.isPaused = true; task.lastOutcome = .failed
        #expect(SchedulePresentation.status(task, isRunning: false)?.label == "Failed · Paused")
        #expect(SchedulePresentation.fullTime(Date(), zoneID: task.recurrence.timeZoneID).contains(zone))
        #expect(!SchedulePresentation.fullTime(Date(), zoneID: TimeZone.current.identifier).contains("("))
    }

    /// A thread schedule sends its prompt into its own thread, marked with its name, with the thread's own agent,
    /// model and access. While the thread is busy (here, a subagent outlasting the turn) the next run waits, then goes.
    @Test func threadSchedulesSendIntoTheirThreadAndWaitWhileItIsBusy() async throws {
        let directory = TemporaryDirectory("scheduled-thread")
        let store = AppStore(directory: directory.url)
        store.updateSettings {
            $0.checkpointsEnabled = false
            $0.generatesThreadTitles = false
            $0.defaultSelection = ModelSelection(provider: .codex, modelID: "scheduled-test")
        }
        let provider = ScheduledTestProvider()
        let registry = ProviderRegistry(store: store, providers: [provider])
        await registry.refresh()
        let runner = ThreadRunner(store: store, registry: registry)
        let project = store.addProject(at: directory.url)
        let thread = store.createThread(in: project.id)
        store.updateThread(thread.id) { $0.accessMode = .approval }
        let first = ISO8601DateFormatter().date(from: "2026-10-28T09:00:00Z")!
        var now = first.addingTimeInterval(-3600)
        let service = ScheduledTasks(store: store, registry: registry, runner: runner, now: { now })
        let task = ScheduledTask(name: "Standup", projectID: project.id, prompt: "Post the standup",
            recurrence: TaskRecurrence(kind: .daily, timeZoneID: "UTC", hour: 9), threadID: thread.id, now: now)
        try service.scheduler.save(task)
        service.start()
        defer { service.stop(); runner.shutdownAll(); store.flush() }

        now = first
        service.scheduler.tick()
        try await waitUntil { store.thread(thread.id)?.items.contains { $0.kind == .user } == true && !runner.isRunning(thread.id) }
        let message = try #require(store.thread(thread.id)?.items.first { $0.kind == .user })
        #expect(message.text == "Post the standup")
        #expect(message.schedule == TranscriptItem.ScheduleMark(id: task.id, name: "Standup"))
        #expect(store.threads(in: project.id).count == 1)
        #expect(store.thread(thread.id)?.accessMode == .approval)
        #expect(service.schedules.task(task.id)?.lastThreadID == thread.id)
        #expect(service.threadState(thread.id) == .busy)

        now = first.addingTimeInterval(86_400)
        service.scheduler.tick()
        #expect(service.schedules.task(task.id)?.pendingDelivery != nil)
        #expect(store.thread(thread.id)?.items.filter { $0.kind == .user }.count == 1)
        try #require(provider.sessions.first).finishBackgroundWork()
        #expect(service.threadState(thread.id) == .ready)
        service.scheduler.tick()
        try await waitUntil { store.thread(thread.id)?.items.filter { $0.kind == .user }.count == 2 }
        #expect(service.schedules.task(task.id)?.pendingDelivery == nil)

        // Archiving the thread pauses the schedule, and unarchiving resumes it.
        store.updateThread(thread.id) { $0.isArchived = true }
        store.notify(.threadList)
        #expect(service.schedules.task(task.id)?.pauseReason == .threadArchived)
        store.updateThread(thread.id) { $0.isArchived = false }
        store.notify(.threadList)
        #expect(service.schedules.task(task.id)?.isActive == true)
    }

    /// A thread schedule's editor names its thread, previews a valid cron expression's next runs and refuses to save
    /// one that runs too often.
    @Test func theEditorPreviewsCronAndNamesTheThread() throws {
        let directory = TemporaryDirectory("schedule-editor-thread")
        let store = AppStore(directory: directory.url)
        let project = store.addProject(at: directory.url)
        let thread = store.createThread(in: project.id)
        store.updateThread(thread.id) { $0.title = "Release prep" }
        let task = ScheduledTask(name: "Weekday check", projectID: project.id, prompt: "Check CI",
            recurrence: TaskRecurrence(kind: .cron, timeZoneID: "UTC", cron: "0 9 * * 1-5"), threadID: thread.id)
        let editor = ScheduledTaskEditor(task: task, isNew: false, store: store)
        let labels = descendants(editor.view).compactMap { $0 as? NSTextField }
        #expect(labels.contains { $0.stringValue.contains("Release prep") })
        let preview = try #require(labels.first { $0.accessibilityLabel() == "Next runs" })
        #expect(preview.stringValue.contains("Custom schedule: 0 9 * * 1-5"))
        let save = try #require(descendants(editor.view).compactMap { $0 as? NSButton }.first { $0.title == "Save" })
        #expect(save.isEnabled)
        let cron = try #require(labels.first { $0.accessibilityLabel() == "Cron expression" })
        cron.stringValue = "* * * * *"
        NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: cron)
        editor.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: cron))
        #expect(preview.stringValue == "Runs must be at least 5 minutes apart.")
        #expect(!save.isEnabled)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(condition())
    }
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
}
