import Foundation
import Testing

@testable import CoincideKit

private func scratchDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("coincide-agent-host-\(UUID().uuidString)", isDirectory: true)
}

/// Collects what the host pushes, as an app would.
@MainActor
private final class Recorder: AgentHostSubscriber {
    var events: [LoggedAgentEvent] = []
    func deliver(_ push: AgentHostPush) {
        if case .events(_, let batch) = push { events += batch }
    }
}

@MainActor
struct AgentEventLogTests {
    private let directory = scratchDirectory()
    private let key = AgentSessionKey(threadID: UUID(), provider: .claude)

    @Test func appendsInOrderAndSurvivesReopening() {
        let store = AgentEventLogStore(directory: directory)
        let log = store.open(key)
        log.append(.sessionStarted(id: "s1"), turnActive: false)
        log.append(nil, turnActive: true)
        log.append(.assistantTextDelta(itemID: "a", delta: "Hi"), turnActive: true)
        #expect(log.lastSequence == 3)

        let reopened = AgentEventLogStore(directory: directory).open(key)
        #expect(reopened.backlog.map(\.sequence) == [1, 2, 3])
        #expect(reopened.backlog.last?.event == .assistantTextDelta(itemID: "a", delta: "Hi"))
        #expect(reopened.backlog.last?.turnActive == true)
        #expect(AgentEventLogStore(directory: directory).existingKeys() == [key])
    }

    @Test func acknowledgingDropsAppliedEventsAndRemembersTheTurn() {
        let log = AgentEventLogStore(directory: directory).open(key)
        log.append(.sessionStarted(id: "s1"), turnActive: false)
        log.append(nil, turnActive: true)
        log.append(.assistantText(itemID: "a", text: "Done"), turnActive: true)
        log.acknowledge(2)
        #expect(log.events(after: 0).map(\.sequence) == [3])
        #expect(log.turnWasActiveAtAcknowledged)

        let reopened = AgentEventLogStore(directory: directory).open(key)
        #expect(reopened.acknowledgedSequence == 2)
        #expect(reopened.turnWasActiveAtAcknowledged)
        #expect(reopened.backlog.map(\.sequence) == [3])
        // Fully applied, the file empties but sequence numbers keep counting.
        reopened.acknowledge(3)
        let again = AgentEventLogStore(directory: directory).open(key)
        #expect(again.backlog.isEmpty)
        #expect(again.lastSequence == 3)
        #expect(again.append(.notice("next"), turnActive: false).sequence == 4)
    }

    @Test func skipsALineCutShortByACrash() throws {
        let log = AgentEventLogStore(directory: directory).open(key)
        log.append(.notice("one"), turnActive: false)
        log.append(.notice("two"), turnActive: false)
        let url = directory.appendingPathComponent("\(key).jsonl")
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"sequence":3,"date":1,"ev"#.utf8))
        try handle.close()
        let reopened = AgentEventLogStore(directory: directory).open(key)
        #expect(reopened.backlog.map(\.sequence) == [1, 2])
    }

    @Test func keepsTheSequenceOfAnEventThisVersionCannotRead() throws {
        let json = #"{"sequence":7,"date":0,"event":{"somethingNew":{"x":1}},"turnActive":true}"#
        let event = try AgentHostWire.decode(LoggedAgentEvent.self, from: Data(json.utf8))
        #expect(event.sequence == 7)
        #expect(event.event == nil)
        #expect(event.turnActive)
    }

    @Test func eventsRoundTripThroughTheWireFormat() throws {
        let events: [AgentEvent] = [
            .toolStarted(ToolCallInfo(id: "t", category: .command, title: "Run", detail: "ls")),
            .approvalRequested(ApprovalRequest(id: "r", category: .command, title: "Allow?", options: ApprovalRequest.standardOptions)),
            .turnCompleted(.failed("boom")),
            .backgroundWork([BackgroundTask(id: "b", title: "server", kind: .command)]),
            .commandsDiscovered([ProviderCommand(name: "compact", kind: .skill)]),
            .sessionExited(error: nil),
        ]
        for event in events {
            #expect(try AgentHostWire.decode(AgentEvent.self, from: AgentHostWire.encode(event)) == event)
        }
    }
}

struct AgentHostHandshakeTests {
    private func hello(build: String = "10", protocolVersion: Int = 1, oldest: Int = 1) -> AgentHostHello {
        AgentHostHello(
            protocolVersion: protocolVersion, oldestSupportedProtocol: oldest, build: build, version: "1.0",
            notifiesWhileAppIsClosed: true)
    }

    private func welcome(build: String = "10", protocolVersion: Int = 1, oldest: Int = 1, busy: Bool = false)
        -> AgentHostWelcome
    {
        AgentHostWelcome(
            protocolVersion: protocolVersion, oldestSupportedProtocol: oldest, build: build, version: "1.0", isBusy: busy,
            sessions: [])
    }

    @Test func sameBuildIsUsed() {
        #expect(AgentHostCompatibility.evaluate(app: hello(), host: welcome()) == .use)
    }

    @Test func anOlderCompatibleHostKeepsRunningUntilIdle() {
        #expect(AgentHostCompatibility.evaluate(app: hello(build: "11"), host: welcome(build: "10", busy: true)) == .useAndReplaceWhenIdle)
        #expect(
            AgentHostCompatibility.evaluate(app: hello(build: "11", protocolVersion: 2, oldest: 1), host: welcome(build: "10"))
                == .useAndReplaceWhenIdle)
    }

    @Test func anIncompatibleHostIsReplacedOnlyWhenIdle() {
        let app = hello(build: "20", protocolVersion: 3, oldest: 3)
        #expect(AgentHostCompatibility.evaluate(app: app, host: welcome(build: "10", busy: false)) == .replaceNow)
        #expect(AgentHostCompatibility.evaluate(app: app, host: welcome(build: "10", busy: true)) == .runInProcessUntilIdle)
        // The other way round: a newer host that no longer speaks this app's protocol.
        let newer = welcome(build: "30", protocolVersion: 5, oldest: 4, busy: true)
        #expect(AgentHostCompatibility.evaluate(app: hello(), host: newer) == .runInProcessUntilIdle)
    }

    @Test func anUnknownCommandIsRefusedNotMisread() {
        let json = #"{"teleport":{"key":{}}}"#
        #expect((try? AgentHostWire.decode(AgentHostCommand.self, from: Data(json.utf8))) == nil)
    }
}

struct AgentHostFallbackTests {
    private func plan(
        on: Bool = true, development: Bool = false, optIn: Bool = false, team: String? = "ABCDE12345",
        status: AgentHostRegistrationStatus = .enabled
    ) -> AgentHostPlan {
        AgentHostPlan.decide(isTurnedOn: on, isDevelopmentBuild: development, developmentOptIn: optIn, team: team, status: status)
    }

    @Test func connectsOrRegistersASignedRelease() {
        #expect(plan() == .connect)
        #expect(plan(status: .notRegistered) == .registerThenConnect)
        #expect(plan(status: .notFound) == .registerThenConnect)
    }

    @Test func runsInTheAppWhenTheHostCannotBeUsed() {
        #expect(plan(on: false) == .runInApp(.turnedOff))
        #expect(plan(team: nil) == .runInApp(.unsignedBuild))
        #expect(plan(status: .requiresApproval) == .runInApp(.needsApproval))
        #expect(plan(development: true) == .runInApp(.developmentBuild))
        #expect(plan(development: true, optIn: true) == .connect)
        #expect(plan(development: true, optIn: true, team: nil) == .runInApp(.unsignedBuild))
    }
}

struct AgentHostLifecycleTests {
    private let lifecycle = AgentHostLifecycle(grace: 30)
    private let now = Date(timeIntervalSince1970: 1_000)

    @Test func staysWhileBusyOrConnected() {
        #expect(!lifecycle.shouldExit(clients: 0, isBusy: true, retireRequested: true, idleSince: .distantPast, now: now))
        #expect(!lifecycle.shouldExit(clients: 1, isBusy: false, retireRequested: false, idleSince: nil, now: now))
    }

    @Test func exitsAfterTheGraceOrWhenRetired() {
        #expect(!lifecycle.shouldExit(clients: 0, isBusy: false, retireRequested: false, idleSince: now - 10, now: now))
        #expect(lifecycle.shouldExit(clients: 0, isBusy: false, retireRequested: false, idleSince: now - 30, now: now))
        #expect(lifecycle.shouldExit(clients: 1, isBusy: false, retireRequested: true, idleSince: nil, now: now))
    }
}

@MainActor
struct AgentHostCoreTests {
    private let directory = scratchDirectory()
    private let claude = ScriptedProvider(kind: .claude)
    private let key = AgentSessionKey(threadID: UUID(), provider: .claude)
    private let thread = AgentHostThreadInfo(title: "Fix the build", projectName: "coincide")

    private func makeCore(grace: TimeInterval = 30) -> AgentHostCore {
        AgentHostCore(
            logDirectory: directory, build: "1", version: "1.0", lifecycle: AgentHostLifecycle(grace: grace)
        ) { [claude] launch, _ in claude.makeSession(launch) }
    }

    private var launch: AgentLaunch {
        AgentLaunch(
            provider: .claude, executable: URL(fileURLWithPath: "/bin/sh"), environment: [:],
            workingDirectory: URL(fileURLWithPath: "/tmp"), resumeSessionID: nil,
            selection: ModelSelection(provider: .claude, modelID: "m"), accessMode: .approval, interactionMode: .build)
    }

    private var input: AgentTurnInput {
        AgentTurnInput(
            text: "hello", selection: ModelSelection(provider: .claude, modelID: "m"), accessMode: .approval,
            interactionMode: .build)
    }

    @Test func runsATurnAndPushesItsEvents() async throws {
        let core = makeCore()
        let app = Recorder()
        let client = core.connect(app)
        guard case .started(let info) = await core.perform(.start(key: key, launch: launch, account: .defaultAccount(for: .claude), thread: thread), from: client)
        else { Issue.record("not started"); return }
        #expect(info.isLive)
        #expect(await core.perform(.send(key: key, input: input, thread: thread), from: client).isOK)
        #expect(claude.last?.sent.map(\.text) == ["hello"])
        #expect(core.isBusy)
        claude.last?.emit(.assistantText(itemID: "a", text: "Hi"))
        claude.last?.emit(.turnCompleted(.completed))
        #expect(!core.isBusy)
        // sessionStarted, the turn's note, the reply and the end.
        #expect(app.events.compactMap(\.event) == [.sessionStarted(id: "claude-1"), .assistantText(itemID: "a", text: "Hi"), .turnCompleted(.completed)])
        #expect(app.events.map(\.sequence) == [1, 2, 3, 4])
        #expect(app.events.map(\.turnActive) == [false, true, true, false])
    }

    @Test func anAppThatComesBackCatchesUpOnWhatHappenedMeanwhile() async throws {
        let core = makeCore()
        let first = Recorder()
        let client = core.connect(first)
        _ = await core.perform(.start(key: key, launch: launch, account: .defaultAccount(for: .claude), thread: thread), from: client)
        _ = await core.perform(.send(key: key, input: input, thread: thread), from: client)
        _ = await core.perform(.acknowledge(key: key, sequence: 2), from: client)
        // The app quits mid-turn; the agent keeps going and asks for approval.
        core.disconnect(client)
        let request = ApprovalRequest(id: "r1", category: .command, title: "Run tests?", options: ApprovalRequest.standardOptions)
        claude.last?.emit(.assistantTextDelta(itemID: "a", delta: "Working"))
        claude.last?.emit(.approvalRequested(request))
        #expect(core.isBusy)
        #expect(claude.last?.isShutDown == false)

        let second = Recorder()
        let again = core.connect(second)
        guard case .sessions(let sessions) = await core.perform(.list, from: again), let info = sessions.first else {
            Issue.record("no sessions")
            return
        }
        #expect(info.isLive)
        #expect(info.acknowledgedSequence == 2)
        #expect(info.turnWasActiveAtAcknowledged)
        #expect(info.pendingApprovals == [request])
        _ = await core.perform(.attach(key: key, after: info.acknowledgedSequence), from: again)
        #expect(second.events.compactMap(\.event) == [.assistantTextDelta(itemID: "a", delta: "Working"), .approvalRequested(request)])
        // Answered from the app that came back; nothing was approved without it.
        #expect(claude.last?.responses.isEmpty == true)
        _ = await core.perform(.respond(key: key, approvalID: "r1", optionID: "allow", text: nil), from: again)
        #expect(claude.last?.responses.map(\.option) == ["allow"])
        claude.last?.emit(.turnCompleted(.completed))
        #expect(second.events.last?.event == .turnCompleted(.completed))
    }

    @Test func notifiesOnlyWhileNoAppListens() async throws {
        let core = makeCore()
        var attention: [AgentHostAttention.Kind] = []
        core.onAttention = { attention.append($0.kind) }
        let app = Recorder()
        let client = core.connect(app)
        _ = core.hello(AgentHostHello(build: "1", version: "1.0", notifiesWhileAppIsClosed: true))
        _ = await core.perform(.start(key: key, launch: launch, account: .defaultAccount(for: .claude), thread: thread), from: client)
        _ = await core.perform(.send(key: key, input: input, thread: thread), from: client)
        claude.last?.emit(.approvalRequested(ApprovalRequest(id: "r", category: .command, title: "Allow?", options: [])))
        #expect(attention.isEmpty)
        core.disconnect(client)
        claude.last?.emit(.approvalRequested(ApprovalRequest(id: "r2", category: .command, title: "Edit?", options: [])))
        claude.last?.emit(.turnCompleted(.completed))
        #expect(attention == [.approval(title: "Edit?"), .finished])
    }

    @Test func exitsOnceIdleAndAloneButNeverMidTurn() async throws {
        let core = makeCore(grace: 0)
        var exited = 0
        core.onExit = { exited += 1 }
        let app = Recorder()
        let client = core.connect(app)
        _ = await core.perform(.start(key: key, launch: launch, account: .defaultAccount(for: .claude), thread: thread), from: client)
        _ = await core.perform(.send(key: key, input: input, thread: thread), from: client)
        core.disconnect(client)
        core.evaluateLifecycle(now: Date().addingTimeInterval(3_600))
        #expect(exited == 0)
        claude.last?.emit(.turnCompleted(.completed))
        core.evaluateLifecycle(now: Date().addingTimeInterval(3_600))
        #expect(exited == 1)
        #expect(claude.last?.isShutDown == true)
    }

    @Test func backgroundWorkKeepsTheHostAlive() async throws {
        let core = makeCore(grace: 0)
        var exited = false
        core.onExit = { exited = true }
        let app = Recorder()
        let client = core.connect(app)
        _ = await core.perform(.start(key: key, launch: launch, account: .defaultAccount(for: .claude), thread: thread), from: client)
        claude.last?.hasBackgroundWork = true
        core.disconnect(client)
        core.evaluateLifecycle(now: Date().addingTimeInterval(3_600))
        #expect(!exited)
        claude.last?.hasBackgroundWork = false
        core.evaluateLifecycle(now: Date().addingTimeInterval(3_600))
        #expect(exited)
    }

    @Test func theSessionInfoListsTheBackgroundWorkLastReported() async throws {
        let core = makeCore()
        let client = core.connect(Recorder())
        _ = await core.perform(.start(key: key, launch: launch, account: .defaultAccount(for: .claude), thread: thread), from: client)
        let task = BackgroundTask(
            id: "a1", title: "Audit the port", kind: .agent, toolCallID: "toolu_1", startedAt: Date(timeIntervalSince1970: 1_800_000_000),
            agentType: "general-purpose", progress: "Running the tests")
        claude.last?.emit(.backgroundWork([task]))
        #expect(core.sessionInfos.first?.backgroundTasks == [task])
        // It reaches an app over the wire, details and all.
        let info = try #require(core.sessionInfos.first)
        #expect(try AgentHostWire.decode(AgentHostSessionInfo.self, from: AgentHostWire.encode(info)) == info)
        claude.last?.emit(.backgroundWork([]))
        #expect(core.sessionInfos.first?.backgroundTasks == [])
        claude.last?.emit(.backgroundWork([task]))
        claude.last?.emit(.sessionExited(error: nil))
        #expect(core.sessionInfos.first?.backgroundTasks == [])
    }

    @Test func anOlderHostsSessionInfoSaysOnlyWhetherWorkRuns() throws {
        let key = AgentSessionKey(threadID: UUID(), provider: .claude)
        var info = AgentHostSessionInfo(
            key: key, isLive: true, sessionID: "s", supportsSteering: true, hasBackgroundWork: true, lastSequence: 3,
            acknowledgedSequence: 3, turnWasActiveAtAcknowledged: false, isTurnActive: false, pendingApprovals: [],
            pendingQuestions: [])
        var json = try #require(JSONSerialization.jsonObject(with: AgentHostWire.encode(info)) as? [String: Any])
        json["backgroundTasks"] = nil
        let older = try AgentHostWire.decode(AgentHostSessionInfo.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(older.backgroundTasks == nil)
        // Shown as one unnamed task until the session reports its work again.
        #expect(AgentHostClient.backgroundTasks(of: older).map(\.kind) == [.other])
        info.hasBackgroundWork = false
        #expect(AgentHostClient.backgroundTasks(of: info).isEmpty)
        info.backgroundTasks = [BackgroundTask(id: "b", title: "npm run dev", kind: .command)]
        #expect(AgentHostClient.backgroundTasks(of: info).map(\.title) == ["npm run dev"])
        info.isLive = false
        #expect(AgentHostClient.backgroundTasks(of: info).isEmpty)
    }

    @Test func retiringWaitsForTheTurnEvenWithTheAppConnected() async throws {
        let core = makeCore()
        var exited = false
        core.onExit = { exited = true }
        let app = Recorder()
        let client = core.connect(app)
        _ = await core.perform(.start(key: key, launch: launch, account: .defaultAccount(for: .claude), thread: thread), from: client)
        _ = await core.perform(.send(key: key, input: input, thread: thread), from: client)
        core.retireWhenIdle()
        #expect(!exited)
        claude.last?.emit(.turnCompleted(.completed))
        #expect(exited)
        // The connected app learns its idle session ended with the host.
        #expect(app.events.last?.event == .sessionExited(error: nil))
    }

    @Test func aHostThatStartsAgainEndsWhatTheLastOneLeftRunning() async throws {
        let core = makeCore()
        let crashed = Recorder()
        let client = core.connect(crashed)
        _ = await core.perform(.start(key: key, launch: launch, account: .defaultAccount(for: .claude), thread: thread), from: client)
        _ = await core.perform(.send(key: key, input: input, thread: thread), from: client)
        claude.last?.emit(.assistantTextDelta(itemID: "a", delta: "Half"))
        // The host crashes: a new one finds the log, but not the session.
        let restarted = makeCore()
        let app = Recorder()
        let again = restarted.connect(app)
        guard case .sessions(let sessions) = await restarted.perform(.list, from: again), let info = sessions.first else {
            Issue.record("no sessions")
            return
        }
        #expect(!info.isLive)
        #expect(info.hasBacklog)
        _ = await restarted.perform(.attach(key: key, after: 0), from: again)
        #expect(app.events.last?.event == .sessionExited(error: String(localized: "The agent host stopped unexpectedly.")))
        // Once applied, the ended session's log is gone.
        _ = await restarted.perform(.acknowledge(key: key, sequence: info.lastSequence + 1), from: again)
        #expect(restarted.sessionInfos.isEmpty)
        #expect(AgentEventLogStore(directory: directory).existingKeys().isEmpty)
    }

    @Test func startingAgainKeepsTheRunningSession() async throws {
        let core = makeCore()
        let app = Recorder()
        let client = core.connect(app)
        _ = await core.perform(.start(key: key, launch: launch, account: .defaultAccount(for: .claude), thread: thread), from: client)
        _ = await core.perform(.start(key: key, launch: launch, account: .defaultAccount(for: .claude), thread: thread), from: client)
        #expect(claude.sessions.count == 1)
        _ = await core.perform(.shutdown(key: key), from: client)
        #expect(claude.last?.isShutDown == true)
        #expect(core.sessionInfos.isEmpty)
    }

    @Test func aFailedStartLeavesNothingBehind() async throws {
        claude.configure = { $0.onStart = { _ in throw AgentError.providerError("no login") } }
        let core = makeCore()
        let app = Recorder()
        let client = core.connect(app)
        let reply = await core.perform(.start(key: key, launch: launch, account: .defaultAccount(for: .claude), thread: thread), from: client)
        guard case .failure(let message) = reply else {
            Issue.record("started")
            return
        }
        #expect(message == "no login")
        #expect(core.sessionInfos.isEmpty)
        #expect(!core.isBusy)
    }
}

extension AgentHostReply {
    fileprivate var isOK: Bool {
        if case .ok = self { return true }
        return false
    }
}
