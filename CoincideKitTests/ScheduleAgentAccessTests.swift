import Foundation
import Testing
@testable import CoincideKit

private func at(_ string: String) -> Date { ISO8601DateFormatter().date(from: string)! }

@MainActor @Suite(.serialized) struct ScheduleAgentAccessTests {
    private func create(_ name: String = "Standup", time: String = "09:00") -> ScheduleRequest {
        .create(name: name, prompt: "Post the standup", schedule: ["kind": "daily", "time": .string(time)])
    }

    @Test func nothingRunsUntilTheUserAllowsItFromTheCard() throws {
        let fixture = AgentFixture()
        defer { fixture.cleanUp() }
        let reply = try fixture.access.handle(create(), threadID: fixture.threadA)
        #expect(reply["status"]?.string == "pending approval")
        let id = try #require(reply["id"]?.string.flatMap(UUID.init(uuidString:)))
        let task = try #require(fixture.store.task(id))
        #expect(task.isAwaitingApproval && task.createdByAgent == true && task.threadID == fixture.threadA)
        let card = try #require(fixture.cards[fixture.threadA]?.last)
        #expect(card.kind == .approval && card.status == .waiting && card.provider == nil)
        #expect(card.approval?.requestID == ScheduleAgentAccess.requestPrefix + id.uuidString)
        #expect(ScheduleAgentAccess.taskID(ofRequest: card.approval!.requestID) == id)
        #expect(card.approval?.options.map(\.id) == ["decline", "edit", "allow"])
        #expect(card.detail?.contains("Post the standup") == true)
        #expect(task.proposal?.itemID == card.id)

        // Due, ticked, asked to run now or resumed by the agent: still nothing.
        fixture.now = fixture.due
        fixture.scheduler.tick()
        #expect(throws: ScheduleError.awaitingApproval) { try fixture.access.handle(.runNow(id), threadID: fixture.threadA) }
        _ = try fixture.access.handle(.resume(id), threadID: fixture.threadA)
        fixture.scheduler.tick()
        #expect(fixture.delivered.isEmpty)
        // Editing opens the editor and leaves the card waiting.
        #expect(fixture.access.respond(threadID: fixture.threadA, itemID: card.id, optionID: "edit") == .edit(id))
        #expect(fixture.card(card.id)?.status == .waiting)

        #expect(fixture.access.respond(threadID: fixture.threadA, itemID: card.id, optionID: "allow") == .allowed(id))
        #expect(fixture.card(card.id)?.status == .completed)
        #expect(fixture.store.task(id)?.isActive == true && fixture.store.task(id)?.proposal == nil)
        fixture.now = fixture.due.addingTimeInterval(86_400)
        fixture.scheduler.tick()
        #expect(fixture.delivered.map(\.id) == [id])
    }

    @Test func declineRemovesANewScheduleAndKeepsAnOldOneAsItWas() throws {
        let fixture = AgentFixture()
        defer { fixture.cleanUp() }
        let created = try fixture.access.handle(create(), threadID: fixture.threadA)
        let id = try #require(created["id"]?.string.flatMap(UUID.init(uuidString:)))
        let card = try #require(fixture.cards[fixture.threadA]?.last)
        #expect(fixture.access.respond(threadID: fixture.threadA, itemID: card.id, optionID: "decline") == .declined)
        #expect(fixture.store.task(id) == nil)
        #expect(fixture.card(card.id)?.status == .declined)
        // Answering a card whose schedule is gone just closes it.
        #expect(fixture.access.respond(threadID: fixture.threadA, itemID: card.id, optionID: "allow") == .gone)

        // A change to an allowed schedule waits too; the schedule keeps running as it was meanwhile.
        fixture.approves = false
        let active = try fixture.access.handle(create("Daily"), threadID: fixture.threadA)
        let activeID = try #require(active["id"]?.string.flatMap(UUID.init(uuidString:)))
        #expect(fixture.store.task(activeID)?.isActive == true)
        fixture.approves = true
        let changed = try fixture.access.handle(
            .update(id: activeID, name: nil, prompt: "Something else", schedule: ["kind": "daily", "time": "18:00"]),
            threadID: fixture.threadA)
        #expect(changed["pendingChange"]?["prompt"]?.string == "Something else")
        #expect(fixture.store.task(activeID)?.prompt == "Post the standup")
        #expect(fixture.store.task(activeID)?.recurrence.hour == 9)
        let changeCard = try #require(fixture.cards[fixture.threadA]?.last)
        fixture.now = fixture.due
        fixture.scheduler.tick()
        #expect(fixture.delivered.last?.prompt == "Post the standup")
        #expect(fixture.access.respond(threadID: fixture.threadA, itemID: changeCard.id, optionID: "decline") == .declined)
        #expect(fixture.store.task(activeID)?.prompt == "Post the standup" && fixture.store.task(activeID)?.proposal == nil)

        // Allowed, it takes effect.
        _ = try fixture.access.handle(.update(id: activeID, name: "Evening", prompt: nil, schedule: nil), threadID: fixture.threadA)
        let rename = try #require(fixture.cards[fixture.threadA]?.last)
        _ = fixture.access.respond(threadID: fixture.threadA, itemID: rename.id, optionID: "allow")
        #expect(fixture.store.task(activeID)?.name == "Evening")
    }

    @Test func aNewerRequestReplacesTheWaitingCard() throws {
        let fixture = AgentFixture()
        defer { fixture.cleanUp() }
        let created = try fixture.access.handle(create(), threadID: fixture.threadA)
        let id = try #require(created["id"]?.string.flatMap(UUID.init(uuidString:)))
        let first = try #require(fixture.cards[fixture.threadA]?.last)
        _ = try fixture.access.handle(.update(id: id, name: nil, prompt: nil, schedule: ["kind": "weekdays", "time": "08:00"]), threadID: fixture.threadA)
        let second = try #require(fixture.cards[fixture.threadA]?.last)
        #expect(first.id != second.id)
        #expect(fixture.card(first.id)?.status == .declined)
        #expect(fixture.store.task(id)?.recurrence.kind == .weekdays && fixture.store.task(id)?.proposal?.itemID == second.id)
        #expect(fixture.store.task(id)?.isAwaitingApproval == true)
        // The user's own editor allows it with their changes.
        var edited = try #require(fixture.store.task(id))
        edited.name = "Mine now"
        try fixture.access.approve(id, edited: edited)
        #expect(fixture.store.task(id)?.name == "Mine now" && fixture.store.task(id)?.isActive == true)
        #expect(fixture.card(second.id)?.status == .completed)
    }

    @Test func oneThreadCantSeeOrTouchAnothersSchedules() throws {
        let fixture = AgentFixture()
        defer { fixture.cleanUp() }
        fixture.approves = false
        let mine = try fixture.access.handle(create(), threadID: fixture.threadA)
        let id = try #require(mine["id"]?.string.flatMap(UUID.init(uuidString:)))
        let project = ScheduledTask(name: "Project", projectID: fixture.project, prompt: "P", recurrence: TaskRecurrence(), now: fixture.now)
        try fixture.scheduler.save(project)

        #expect(try fixture.access.handle(.list, threadID: fixture.threadA)["schedules"]?.array?.count == 1)
        #expect(try fixture.access.handle(.list, threadID: fixture.threadB)["schedules"]?.array?.isEmpty == true)
        for target in [id, project.id] {
            for request: ScheduleRequest in [
                .pause(target), .resume(target), .delete(target), .runNow(target),
                .update(id: target, name: "Taken", prompt: nil, schedule: nil),
            ] {
                #expect(throws: ScheduleError.notFound, "\(request)") { try fixture.access.handle(request, threadID: fixture.threadB) }
            }
        }
        #expect(fixture.store.task(id)?.name == "Standup" && fixture.store.task(id)?.isActive == true)
        #expect(fixture.store.task(project.id) != nil)
        // A thread's own requests work, and a deleted thread can't create any.
        _ = try fixture.access.handle(.pause(id), threadID: fixture.threadA)
        #expect(fixture.store.task(id)?.isPaused == true)
        #expect(throws: ScheduleError.threadMissing) { try fixture.access.handle(create(), threadID: UUID()) }
    }

    @Test func creationIsRateLimitedAndCappedPerThread() throws {
        let fixture = AgentFixture()
        defer { fixture.cleanUp() }
        fixture.approves = false
        for index in 0..<ScheduleAgentAccess.maximumChangesPerWindow {
            _ = try fixture.access.handle(create("Task \(index)"), threadID: fixture.threadA)
        }
        #expect(throws: ScheduleError.rateLimited) { try fixture.access.handle(create("One more"), threadID: fixture.threadA) }
        // Another thread has its own allowance.
        _ = try fixture.access.handle(create("Elsewhere"), threadID: fixture.threadB)
        fixture.now = fixture.now.addingTimeInterval(ScheduleAgentAccess.rateWindow + 1)
        for index in 5..<ScheduleAgentAccess.maximumPerThread {
            _ = try fixture.access.handle(create("Task \(index)"), threadID: fixture.threadA)
            fixture.now = fixture.now.addingTimeInterval(ScheduleAgentAccess.rateWindow)
        }
        #expect(throws: ScheduleError.limitReached(ScheduleAgentAccess.maximumPerThread)) {
            try fixture.access.handle(create("Eleventh"), threadID: fixture.threadA)
        }
        #expect(fixture.access.tasks(in: fixture.threadA).count == ScheduleAgentAccess.maximumPerThread)

        // At most three cards wait in a thread at once.
        fixture.approves = true
        for index in 0..<ScheduleAgentAccess.maximumWaitingPerThread {
            _ = try fixture.access.handle(create("Waiting \(index)"), threadID: fixture.threadB)
        }
        #expect(throws: ScheduleError.self) { try fixture.access.handle(create("Too many"), threadID: fixture.threadB) }
    }

    @Test func withoutApprovalSchedulesRunAtOnceAndTheInstructionsSaySo() throws {
        let fixture = AgentFixture()
        defer { fixture.cleanUp() }
        fixture.approves = false
        let reply = try fixture.access.handle(create(), threadID: fixture.threadA)
        #expect(reply["status"]?.string == "active")
        #expect(fixture.cards.isEmpty)
        fixture.now = fixture.due
        fixture.scheduler.tick()
        #expect(fixture.delivered.count == 1)
        let config = URL(fileURLWithPath: "/tmp/it's/schedule.curl")
        let off = ScheduleAgentAccess.instructions(configuration: config, requiresApproval: false, timeZone: TimeZone(identifier: "Asia/Kolkata")!)
        let on = ScheduleAgentAccess.instructions(configuration: config, requiresApproval: true, timeZone: .current)
        #expect(off.contains("take effect at once") && !off.contains("pending approval"))
        #expect(on.contains("pending approval") && on.contains("<coincide_schedule>"))
        #expect(off.contains("Asia/Kolkata") && off.contains("'/tmp/it'\\''s/schedule.curl'"))
        #expect(on.contains("only when the user asks"))
    }
}

@MainActor private final class AgentFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-schedule-agents-\(UUID())")
    let due = at("2026-10-28T09:00:00Z")
    var now = at("2026-10-28T08:00:00Z")
    let project = UUID(), threadA = UUID(), threadB = UUID()
    var approves = true
    var delivered: [ScheduledTask] = []
    var cards: [UUID: [TranscriptItem]] = [:]
    let store: ScheduledTaskStore
    lazy var scheduler = TaskScheduler(store: store, now: { [unowned self] in now },
        makeThread: { _ in UUID() }, startThread: { _, _ in },
        threadState: { [unowned self] id in id == threadA || id == threadB ? .ready : .missing },
        deliver: { [unowned self] task in delivered.append(task) })
    lazy var access: ScheduleAgentAccess = {
        let access = ScheduleAgentAccess(scheduler: scheduler, now: { [unowned self] in now })
        access.requiresApproval = { [unowned self] in approves }
        access.defaultTimeZone = { TimeZone(identifier: "UTC")! }
        access.projectOf = { [unowned self] id in id == threadA || id == threadB ? project : nil }
        access.appendCard = { [unowned self] thread, item in cards[thread, default: []].append(item) }
        access.updateCard = { [unowned self] thread, itemID, change in
            guard let index = cards[thread]?.firstIndex(where: { $0.id == itemID }) else { return }
            change(&cards[thread]![index])
        }
        return access
    }()

    init() { store = ScheduledTaskStore(directory: directory) }

    func card(_ id: UUID) -> TranscriptItem? { cards.values.joined().first { $0.id == id } }
    func cleanUp() { try? FileManager.default.removeItem(at: directory) }
}

@MainActor @Suite(.serialized) struct ScheduleBridgeTests {
    @Test func eachThreadGetsAPrivateConfigWithTheTokenInAHeaderAndOnlyItsOwnPath() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-schedule-bridge-\(UUID())")
        var handled: [(ScheduleRequest, UUID)] = []
        let bridge = ScheduleBridge(directory: directory) { request, thread in
            handled.append((request, thread))
            return ["ok": true]
        }
        defer { bridge.stop() }
        let threadA = UUID(), threadB = UUID()
        let accessA = try await bridge.enable(threadID: threadA)
        let accessB = try await bridge.enable(threadID: threadB)
        let attributes = try FileManager.default.attributesOfItem(atPath: accessA.configuration.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let folder = try FileManager.default.attributesOfItem(atPath: accessA.directory.path)
        #expect((folder[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        let config = try String(contentsOf: accessA.configuration, encoding: .utf8)
        let token = try #require(config.components(separatedBy: "Bearer ").last?.components(separatedBy: "\"").first)
        let url = try #require(config.components(separatedBy: "url = \"").last?.components(separatedBy: "\"").first)
        #expect(token.count == 64 && !url.contains(token))
        #expect(url.hasSuffix("/schedule/" + threadA.uuidString))
        let port = try #require(bridge.listeningPort)
        let host = "127.0.0.1:\(port)"
        let list = Data(#"{"action":"list"}"#.utf8)

        let (ok, status) = bridge.answer(path: "/schedule/\(threadA)", host: host, authorization: "Bearer \(token)", body: list)
        #expect(status == 200 && ok["ok"]?.bool == true)
        #expect(handled.count == 1 && handled.first?.1 == threadA && handled.first?.0 == .list)
        // Thread A's token opens nothing of thread B's, a wrong token nothing at all, and another host is refused.
        for (path, auth, host) in [
            ("/schedule/\(threadB)", "Bearer \(token)", host), ("/schedule/\(threadA)", "Bearer \(String(repeating: "0", count: 64))", host),
            ("/schedule/\(threadA)", "Bearer \(token)", "localhost:\(port)"), ("/computer-use/\(threadA)", "Bearer \(token)", host),
        ] {
            #expect(bridge.answer(path: path, host: host, authorization: auth, body: list).1 == 403)
        }
        #expect(handled.count == 1)
        // Malformed bodies never reach the handler.
        #expect(bridge.answer(path: "/schedule/\(threadA)", host: host, authorization: "Bearer \(token)", body: Data("{".utf8)).1 == 400)
        #expect(handled.count == 1)
        // Revoking a thread removes its config and its access.
        bridge.disable(threadID: threadB)
        #expect(!FileManager.default.fileExists(atPath: accessB.configuration.path))
        #expect(bridge.access(for: threadB) == nil)
        #expect(bridge.answer(path: "/schedule/\(threadA)", host: host, authorization: "Bearer \(token)", body: list).1 == 200)
    }
}

@MainActor @Suite(.serialized) struct LocalApprovalTests {
    /// A schedule's approval card has no provider: no agent session answers it, a relaunch doesn't close it, and the
    /// runner hands the user's answer to the scheduler.
    @Test func coincidesOwnApprovalsSurviveRelaunchAndGoToTheirOwner() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-local-approval-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let folder = directory.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = AppStore(directory: directory)
        let project = store.addProject(at: folder)
        let thread = store.createThread(in: project.id)
        let task = ScheduledTask(name: "N", projectID: project.id, prompt: "P", recurrence: TaskRecurrence(), threadID: thread.id)
        let card = ScheduleAgentAccess.card(for: task, isChange: false, now: Date())
        _ = store.append(card, to: thread.id)
        let agentPrompt = TranscriptItem(kind: .approval, title: "Run ls", status: .waiting, provider: .claude,
            approval: ApprovalInfo(requestID: "r1", options: [ApprovalOption(id: "ok", label: "OK", kind: .allowOnce)]))
        _ = store.append(agentPrompt, to: thread.id)
        store.flush()

        let reopened = AppStore(directory: directory)
        let items = try #require(reopened.thread(thread.id)?.items)
        #expect(items.first { $0.id == card.id }?.status == .waiting)
        #expect(items.first { $0.id == agentPrompt.id }?.status == .declined)

        let registry = ProviderRegistry(store: reopened, providers: [])
        let runner = ThreadRunner(store: reopened, registry: registry)
        var answered: [(UUID, UUID, String)] = []
        runner.localApprovals[ScheduleAgentAccess.requestPrefix] = { answered.append(($0, $1, $2)) }
        runner.respond(threadID: thread.id, itemID: card.id, optionID: "allow")
        #expect(answered.count == 1 && answered.first?.1 == card.id && answered.first?.2 == "allow")
        // Without an owner, nothing answers it and it stays open.
        runner.localApprovals.removeAll()
        runner.respond(threadID: thread.id, itemID: card.id, optionID: "allow")
        #expect(reopened.item(card.id, in: thread.id)?.status == .waiting)
        reopened.flush()
    }
}
