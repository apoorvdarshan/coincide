import AppKit
import Testing
@testable import Coincide
@testable import CoincideKit

@MainActor private final class ScheduledTestProvider: AgentProvider {
    let kind = ProviderKind.codex
    let executableNames = ["sh"]
    let setupHint = ""
    func detect(executable: URL?, environment: [String: String]) async -> ProviderStatus { ProviderStatus(state: .ready) }
    func models(status: ProviderStatus, environment: [String: String]) async -> [ModelOption] {
        [ModelOption(provider: .codex, modelID: "scheduled-test", displayName: "Test")]
    }
    func makeSession(_ launch: AgentLaunch) -> AgentSession { fatalError("These tests never launch an agent") }
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

    @Test func saveFailureKeepsThePromptAndTimeZoneEditable() throws {
        let directory = TemporaryDirectory("schedule-editor")
        let store = AppStore(directory: directory.url)
        let project = store.addProject(at: directory.url)
        let task = ScheduledTask(name: "Daily review", projectID: project.id, prompt: "Review the open changes",
            recurrence: TaskRecurrence(kind: .daily, timeZoneID: "UTC", hour: 9, minute: 15))
        let editor = ScheduledTaskEditor(task: task, projects: [project])
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
        var task = ScheduledTask(name: "Review", projectID: UUID(), prompt: "Review",
            recurrence: TaskRecurrence(timeZoneID: "Asia/Kolkata"))
        task.isPaused = true; task.lastOutcome = .failed
        #expect(ScheduledTasksViewController.state(task) == "Failed · Paused")
        #expect(ScheduledTasksViewController.date(Date(), task: task).contains("Asia/Kolkata"))
    }
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
}
