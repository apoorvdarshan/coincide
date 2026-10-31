import CoincideRemoteKit
import Foundation
import Testing

@testable import Coincide
@testable import CoincideKit

/// Thread schedules on Coincide Remote: the optional fields that carry them, which older phones and Macs ignore, the
/// phone's grouping and header clock, and the Mac's side of creating and listing them.
@MainActor
struct RemoteThreadScheduleTests {
    private let encoder = RemoteProtocol.makeEncoder()
    private let decoder = RemoteProtocol.makeDecoder()

    private func json(_ value: some Encodable) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: encoder.encode(value)) as? [String: Any] ?? [:]
    }

    // MARK: Compatibility

    @Test func newFieldsAreOptionalBothWays() throws {
        let selection = RemoteSelection(provider: "claude", modelID: "opus", modelName: "Opus")
        // A thread without schedules, and a message no schedule sent, send nothing new: an older phone sees what it did.
        let plain = RemoteThreadSummary(id: UUID(), projectID: UUID(), title: "T", selection: selection)
        #expect(try json(plain)["scheduleCount"] == nil && json(plain)["nextScheduledRun"] == nil)
        let item = RemoteItem(id: UUID(), index: 0, kind: .user, text: "Hi")
        #expect(try json(item)["scheduleName"] == nil)
        let task = RemoteScheduledTask(id: UUID(), name: "N", projectID: UUID(), prompt: "P", recurrence: RemoteTaskRecurrence())
        for key in ["threadID", "botID", "needsApproval", "createdByAgent"] { #expect(try json(task)[key] == nil, "\(key)") }

        // Set, they cross the wire unchanged.
        let next = Date(timeIntervalSince1970: 1_800_000_000)
        var scheduled = plain
        scheduled.scheduleCount = 2
        scheduled.nextScheduledRun = next
        let summary = try decoder.decode(RemoteThreadSummary.self, from: encoder.encode(scheduled))
        #expect(summary.scheduleCount == 2 && summary.nextScheduledRun == next && summary.hasSchedules)
        var marked = item
        marked.scheduleName = "Standup"
        #expect(try decoder.decode(RemoteItem.self, from: encoder.encode(marked)).scheduleName == "Standup")
        let thread = UUID(), bot = UUID()
        let threadTask = RemoteScheduledTask(
            id: UUID(), name: "N", projectID: UUID(), prompt: "P", recurrence: RemoteTaskRecurrence(), threadID: thread, botID: bot,
            needsApproval: true, createdByAgent: true)
        let decoded = try decoder.decode(RemoteScheduledTask.self, from: encoder.encode(threadTask))
        #expect(decoded.threadID == thread && decoded.botID == bot && decoded.needsApproval == true && decoded.createdByAgent == true)
        let draft = RemoteScheduledTaskDraft(name: "N", projectID: UUID(), prompt: "P", recurrence: nil, threadID: thread)
        #expect(try decoder.decode(RemoteScheduledTaskDraft.self, from: encoder.encode(draft)).threadID == thread)

        // What an older Mac sends reads as a project task on a thread without schedules.
        let old = #"{"id":"\#(UUID())","name":"N","projectID":"\#(UUID())","prompt":"P","isPaused":false,"state":"scheduled","stateText":"Scheduled","scheduleText":"Daily","canRunNow":true}"#
        let oldTask = try decoder.decode(RemoteScheduledTask.self, from: Data(old.utf8))
        #expect(oldTask.threadID == nil && !oldTask.isThreadSchedule && oldTask.needsApproval == nil)
        let oldDraft = #"{"name":"N","projectID":"\#(UUID())","prompt":"P","isPaused":false}"#
        #expect(try decoder.decode(RemoteScheduledTaskDraft.self, from: Data(oldDraft.utf8)).threadID == nil)
    }

    // MARK: Phone

    @Test func theListGroupsByBotThreadAndProjectSoonestFirst() {
        let now = Date()
        let project = UUID(), thread = UUID(), botThread = UUID(), bot = UUID()
        func task(_ name: String, hours: Double, thread: UUID? = nil, bot: UUID? = nil, paused: Bool = false) -> RemoteScheduledTask {
            RemoteScheduledTask(
                id: UUID(), name: name, projectID: project, prompt: "P", recurrence: RemoteTaskRecurrence(), isPaused: paused,
                nextRunAt: now.addingTimeInterval(hours * 3600), threadID: thread, botID: bot)
        }
        let groups = RemoteScheduleOwner.groups([
            task("Project", hours: 3), task("Late", hours: 9, thread: thread), task("Paused", hours: 0.5, thread: thread, paused: true),
            task("Bot", hours: 1, thread: botThread, bot: bot), task("Early", hours: 2, thread: thread),
        ])
        #expect(groups.map(\.owner) == [.bot(bot), .thread(thread), .project(project)])
        #expect(groups[1].tasks.map(\.name) == ["Early", "Late", "Paused"])
    }

    @Test func theHeaderClockSaysTheNextRunShortly() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let now = calendar.date(bySettingHour: 8, minute: 0, second: 0, of: Date())!
        var summary = RemoteThreadSummary(
            id: UUID(), projectID: UUID(), title: "T", selection: RemoteSelection(provider: "claude", modelID: "m", modelName: "M"))
        #expect(summary.compactNextRun(now: now) == nil && !summary.hasSchedules)
        summary.scheduleCount = 1
        let today = now.addingTimeInterval(3600)
        summary.nextScheduledRun = today
        #expect(summary.compactNextRun(now: now, calendar: calendar) == today.formatted(date: .omitted, time: .shortened))
        let soon = calendar.date(byAdding: .day, value: 2, to: today)!
        summary.nextScheduledRun = soon
        #expect(summary.compactNextRun(now: now, calendar: calendar)?.hasSuffix(soon.formatted(date: .omitted, time: .shortened)) == true)
    }

    // MARK: Mac

    @Test func thePhoneCreatesAThreadScheduleAndSeesItsClockAndBot() throws {
        let data = TemporaryDirectory("remote-thread-schedules")
        let store = AppStore(directory: data.url)
        let registry = ProviderRegistry(store: store, providers: [])
        let runner = ThreadRunner(store: store, registry: registry)
        let adapter = RemoteStoreAdapter(store: store, runner: runner, registry: registry, services: RemoteSessionTests.services(store: store))
        let project = store.addProject(at: data.url)
        let thread = store.createThread(in: project.id)
        let tomorrow = Date().addingTimeInterval(86_400)

        let list = try adapter.saveScheduledTask(
            RemoteScheduledTaskDraft(
                name: "Standup", projectID: UUID(), prompt: "Summarize.",
                recurrence: RemoteTaskRecurrence(kind: .daily, date: tomorrow, hour: 9, minute: 0), threadID: thread.id))
        let task = try #require(list.tasks.first)
        #expect(task.threadID == thread.id && task.projectID == project.id && task.botID == nil)
        #expect(task.scheduleText.contains("9"))
        let summary = try #require(store.summary(thread.id).map(adapter.summary))
        #expect(summary.scheduleCount == 1 && summary.nextScheduledRun == adapter.schedules.schedules.task(task.id)?.nextRunAt)

        // Editing it from the phone keeps it in its thread.
        let edited = try adapter.saveScheduledTask(
            RemoteScheduledTaskDraft(id: task.id, name: "Morning standup", projectID: UUID(), prompt: "Summarize.", recurrence: nil))
        #expect(edited.tasks.first?.threadID == thread.id && edited.tasks.first?.name == "Morning standup")

        // A schedule an agent made waits for approval and can't be run from the phone.
        var proposed = try #require(adapter.schedules.schedules.task(task.id))
        proposed.awaitingApproval = true
        proposed.createdByAgent = true
        try adapter.schedules.schedules.save(proposed)
        let waiting = try #require(adapter.scheduledTasks().tasks.first)
        #expect(waiting.needsApproval == true && waiting.createdByAgent == true && !waiting.canRunNow)

        // A new thread schedule needs its thread to exist.
        #expect(throws: RemoteError.self) {
            try adapter.saveScheduledTask(
                RemoteScheduledTaskDraft(
                    name: "N", projectID: project.id, prompt: "P", recurrence: RemoteTaskRecurrence(kind: .daily, date: tomorrow),
                    threadID: UUID()))
        }

        // The message a schedule sent carries its name.
        let message = TranscriptItem(kind: .user, text: "Summarize.", schedule: .init(id: task.id, name: "Morning standup"))
        #expect(RemoteStoreAdapter.item(message, index: 0).scheduleName == "Morning standup")
        #expect(RemoteStoreAdapter.item(TranscriptItem(kind: .user, text: "Hi"), index: 0).scheduleName == nil)
    }

    @Test func aBotsScheduleNamesItsBot() throws {
        let data = TemporaryDirectory("remote-bot-schedules")
        let store = AppStore(directory: data.url)
        let registry = ProviderRegistry(store: store, providers: [])
        let runner = ThreadRunner(store: store, registry: registry)
        let adapter = RemoteStoreAdapter(store: store, runner: runner, registry: registry, services: RemoteSessionTests.services(store: store))
        let bot = store.addBot(
            Bot(name: "Brulee", avatar: BotAvatar(character: .brulee), persona: "", selection: ModelSelection(provider: .claude, modelID: "default"),
                folder: data.url.path))
        let conversation = try #require(store.startConversation(with: bot.id))
        let list = try adapter.saveScheduledTask(
            RemoteScheduledTaskDraft(
                name: "Weekend plan", projectID: UUID(), prompt: "Plan Saturday.",
                recurrence: RemoteTaskRecurrence(kind: .daily, date: Date().addingTimeInterval(86_400)), threadID: conversation.id))
        #expect(list.tasks.first?.botID == bot.id)
        #expect(list.tasks.first.map(RemoteScheduleOwner.init) == .bot(bot.id))
    }
}
