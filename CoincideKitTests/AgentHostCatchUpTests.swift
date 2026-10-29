import Foundation
import Testing

@testable import CoincideKit

/// The app quitting and coming back while its agents run in the agent host: `ThreadRunner` with hosted sessions,
/// over the in-process transport.
@MainActor
struct AgentHostCatchUpTests {
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "coincide-catch-up-\(UUID().uuidString)", isDirectory: true)
    private let store: AppStore
    private let claude = ScriptedProvider(kind: .claude)
    private let codex = ScriptedProvider(kind: .codex)
    private let registry: ProviderRegistry
    private let core: AgentHostCore
    private let threadID: UUID

    init() {
        store = AppStore(directory: directory.appendingPathComponent("data"))
        store.updateSettings { $0.checkpointsEnabled = false }
        registry = ProviderRegistry(store: store, providers: [claude, codex])
        core = Self.makeCore(directory: directory, claude: claude, codex: codex)
        let project = store.addProject(at: URL(fileURLWithPath: "/tmp"))
        threadID = store.createThread(in: project.id, selection: ModelSelection(provider: .claude, modelID: "m")).id
    }

    /// A host over the test's log folder; a second one is the host started again after the first exited.
    private static func makeCore(directory: URL, claude: ScriptedProvider, codex: ScriptedProvider) -> AgentHostCore {
        AgentHostCore(logDirectory: directory.appendingPathComponent("agent-host"), build: "1", version: "1.0") {
            launch, _ in (launch.provider == .codex ? codex : claude).makeSession(launch)
        }
    }

    /// One run of the app: a runner whose sessions run in the host, over its own connection.
    private struct AppRun {
        let runner: ThreadRunner
        let transport: LossyAgentHostTransport
        let client: AgentHostClient
    }

    private func launchApp(core: AgentHostCore? = nil) -> AppRun {
        let runner = ThreadRunner(store: store, registry: registry)
        runner.stopTimeout = 0.05
        let transport = LossyAgentHostTransport(InProcessAgentHostTransport(core: core ?? self.core))
        let client = AgentHostClient(transport: transport)
        runner.hostedSession = { [weak client] threadID, launch, account in
            client?.makeSession(
                key: AgentSessionKey(threadID: threadID, provider: launch.provider), launch: launch, account: account,
                thread: { AgentHostThreadInfo(title: "Thread", projectName: nil) })
        }
        return AppRun(runner: runner, transport: transport, client: client)
    }

    /// What `AgentHostController` does when it connects: take up every session the host kept.
    private func catchUp(_ run: AppRun) async throws {
        let welcome = try await run.transport.hello(AgentHostHello(build: "1", version: "1.0", notifiesWhileAppIsClosed: false))
        for info in welcome.sessions {
            let session = run.client.adopt(info, thread: { AgentHostThreadInfo(title: "Thread", projectName: nil) })
            let turnWasActive = info.hasBacklog ? info.turnWasActiveAtAcknowledged : info.isTurnActive
            #expect(run.runner.adopt(session, threadID: info.key.threadID, turnWasActive: turnWasActive))
            await run.client.attach(session)
        }
    }

    /// What quitting does: let go of the hosted sessions, tell the host how far the app got, disconnect.
    private func quit(_ run: AppRun) {
        run.runner.detachHostedSessions()
        run.client.flushAcknowledgements()
        run.transport.invalidate()
    }

    private var items: [TranscriptItem] { store.thread(threadID)?.items ?? [] }

    private func select(_ provider: ProviderKind) {
        store.updateThread(threadID) { $0.selection = ModelSelection(provider: provider, modelID: "m") }
    }

    private func scripted(_ provider: ProviderKind) -> ScriptedProvider { provider == .codex ? codex : claude }

    private func replies(_ provider: ProviderKind) -> [String] {
        items.filter { $0.kind == .assistant && $0.provider == provider }.map(\.text)
    }

    /// Every turn the agent is sent answers with "Re: <message>" and completes.
    private func answerEveryTurn(_ provider: ProviderKind, steering: Bool = false) {
        scripted(provider).configure = { session in
            session.supportsSteering = steering
            session.onSend = { session, input in
                session.emit(.assistantText(itemID: UUID().uuidString, text: "Re: \(input.message)"))
                session.emit(.turnCompleted(.completed))
            }
        }
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<1_000 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    @Test func aTurnRunningWhenTheAppQuitsGoesOnAndIsCaughtUpOn() async throws {
        claude.configure = { session in
            session.onSend = { session, _ in session.emit(.assistantTextDelta(itemID: "reply", delta: "Hel")) }
        }
        let first = launchApp()
        await first.runner.send(threadID: threadID, text: "hi")
        #expect(first.runner.isRunning(threadID))
        #expect(core.liveSessionCount == 1)
        // The app quits mid-turn. Nothing it shows is settled, and the agent keeps going.
        quit(first)
        #expect(!first.runner.isRunning(threadID))
        #expect(items.last?.status == .running)
        let agent = try #require(claude.last)
        #expect(!agent.isShutDown)
        let request = ApprovalRequest(id: "r1", category: .command, title: "Run tests?", options: ApprovalRequest.standardOptions)
        agent.emit(.assistantTextDelta(itemID: "reply", delta: "lo"))
        agent.emit(.approvalRequested(request))
        #expect(agent.responses.isEmpty)

        let second = launchApp()
        try await catchUp(second)
        #expect(second.runner.isRunning(threadID))
        // The reply continues the same item, and the approval waits to be answered.
        #expect(items.filter { $0.kind == .assistant }.map(\.text) == ["Hello"])
        let approval = try #require(items.last { $0.kind == .approval })
        #expect(approval.status == .waiting)
        #expect(items.filter { $0.kind == .approval }.count == 1)

        second.runner.respond(threadID: threadID, itemID: approval.id, optionID: "allow")
        #expect(await eventually { agent.responses.map(\.option) == ["allow"] })
        agent.emit(.assistantTextDelta(itemID: "reply", delta: "!"))
        agent.emit(.turnCompleted(.completed))
        #expect(await eventually { !second.runner.isRunning(threadID) })
        #expect(items.filter { $0.kind == .assistant }.map(\.text) == ["Hello!"])
        #expect(!items.contains { $0.status == .running || $0.status == .waiting })
        // The same native session is used for the next turn.
        await second.runner.send(threadID: threadID, text: "again")
        #expect(claude.sessions.count == 1)
        #expect(agent.sent.map(\.message) == ["hi", "again"])
    }

    @Test func aTurnThatEndedWhileTheAppWasClosedIsSettled() async throws {
        claude.configure = { session in
            session.onSend = { session, _ in session.emit(.assistantTextDelta(itemID: "reply", delta: "Working")) }
        }
        let first = launchApp()
        await first.runner.send(threadID: threadID, text: "hi")
        quit(first)
        let agent = try #require(claude.last)
        agent.emit(.assistantText(itemID: "reply", text: "Working. Done."))
        agent.emit(.turnCompleted(.completed))

        let second = launchApp()
        var finished: [TurnOutcome] = []
        second.runner.onTurnFinished = { _, outcome in finished.append(outcome) }
        try await catchUp(second)
        #expect(finished == [.completed])
        #expect(!second.runner.isRunning(threadID))
        #expect(items.filter { $0.kind == .assistant }.map(\.text) == ["Working. Done."])
        #expect(!items.contains { $0.status == .running })
        // Nothing is replayed twice by a later connection.
        let third = launchApp()
        second.client.flushAcknowledgements()
        try await catchUp(third)
        #expect(items.filter { $0.kind == .assistant }.count == 1)
    }

    @Test func aHostThatCrashedFailsTheTurnItRan() async throws {
        claude.configure = { session in
            session.onSend = { session, _ in session.emit(.assistantTextDelta(itemID: "reply", delta: "Half")) }
        }
        let first = launchApp()
        await first.runner.send(threadID: threadID, text: "hi")
        // The connection drops while the app runs: the turn ends rather than hanging.
        first.transport.invalidate()
        #expect(await eventually { !first.runner.isRunning(threadID) })
        #expect(items.last?.kind == .error)
    }

    @Test func sessionsRunInTheAppWithoutAHost() async throws {
        claude.configure = { session in
            session.onSend = { session, _ in session.emit(.turnCompleted(.completed)) }
        }
        let run = launchApp()
        run.runner.hostedSession = nil
        await run.runner.send(threadID: threadID, text: "hi")
        #expect(claude.sessions.count == 1)
        #expect(core.sessionInfos.isEmpty)
        #expect(run.runner.runningInAppThreadIDs.isEmpty)
    }

    @Test func onlyTurnsInTheAppCountAsStoppedByQuitting() async throws {
        let run = launchApp()
        await run.runner.send(threadID: threadID, text: "hi")
        #expect(run.runner.runningThreadIDs == [threadID])
        #expect(run.runner.runningInAppThreadIDs.isEmpty)
    }

    @Test func unfinishedItemsOfHostedThreadsAreNotSettledOnLaunch() throws {
        let item = TranscriptItem(kind: .approval, title: "Allow?", status: .waiting, provider: .claude)
        store.append(item, to: threadID)
        store.flush()
        let relaunched = AppStore(directory: directory.appendingPathComponent("data"))
        relaunched.threadsWithHostedAgents = [threadID]
        #expect(relaunched.item(item.id, in: threadID)?.status == .waiting)
        let without = AppStore(directory: directory.appendingPathComponent("data"))
        #expect(without.item(item.id, in: threadID)?.status == .declined)
    }

    // MARK: New turns after catching up

    private var key: AgentSessionKey { AgentSessionKey(threadID: threadID, provider: store.thread(threadID)!.selection.provider) }

    private var interruptedNotices: Int { items.count { $0.kind == .notice && $0.text == "Interrupted" } }

    private func tool(_ id: String) -> AgentEvent { .toolStarted(ToolCallInfo(id: id, category: .command, title: "Run tests")) }

    /// The incident: the app relaunched, caught up on a session that had ended, and the host then removed its fully
    /// applied log. The app went on remembering how far that log got, the host numbered the next log from 1 again,
    /// and every event of the next turn was dropped as already applied: no reply, and a turn that never ended.
    @Test(arguments: [ProviderKind.claude, .codex])
    func aNewTurnAfterTheAppCaughtUpShowsLive(_ provider: ProviderKind) async throws {
        select(provider)
        answerEveryTurn(provider)
        let first = launchApp()
        await first.runner.send(threadID: threadID, text: "hi")
        #expect(replies(provider) == ["Re: hi"])
        quit(first)
        // The agent ends while the app is closed (the host it ran in exited, say).
        try #require(scripted(provider).last).emit(.sessionExited(error: nil))

        let second = launchApp()
        try await catchUp(second)
        // Everything applied, the host lets go of the ended session and its log.
        #expect(await eventually { core.sessionInfos.isEmpty })
        await second.runner.send(threadID: threadID, text: "what was done?")
        #expect(await eventually { !second.runner.isRunning(threadID) })
        #expect(replies(provider) == ["Re: hi", "Re: what was done?"])
        #expect(scripted(provider).sessions.count == 2)
        #expect(interruptedNotices == 0)
        // And the turn after it.
        await second.runner.send(threadID: threadID, text: "status?")
        #expect(await eventually { replies(provider).last == "Re: status?" && !second.runner.isRunning(threadID) })
    }

    /// The same without a relaunch: a stop that timed out, an idle timeout or an access change ends the hosted
    /// session, and the next message starts another one for the same thread.
    @Test(arguments: [ProviderKind.claude, .codex])
    func aSessionStartedAgainForTheThreadShowsItsReplies(_ provider: ProviderKind) async throws {
        select(provider)
        answerEveryTurn(provider)
        let run = launchApp()
        await run.runner.send(threadID: threadID, text: "one")
        run.runner.shutdown(threadID: threadID)
        #expect(await eventually { core.sessionInfos.isEmpty })
        await run.runner.send(threadID: threadID, text: "two")
        #expect(await eventually { !run.runner.isRunning(threadID) })
        #expect(replies(provider) == ["Re: one", "Re: two"])
        #expect(scripted(provider).sessions.count == 2)
    }

    /// A host that exited and started again numbers a new log from 1; the app connected to it shows its events.
    @Test func aNewTurnInAHostStartedAgainShowsLive() async throws {
        answerEveryTurn(.claude)
        let first = launchApp()
        await first.runner.send(threadID: threadID, text: "one")
        quit(first)
        // The idle host retires, ending its sessions; launchd starts a new one for the next connection.
        core.retireWhenIdle()
        let restarted = Self.makeCore(directory: directory, claude: claude, codex: codex)
        let second = launchApp(core: restarted)
        let welcome = try await second.transport.hello(
            AgentHostHello(build: "1", version: "1.0", notifiesWhileAppIsClosed: false))
        for info in welcome.sessions {
            let session = second.client.adopt(info, thread: { AgentHostThreadInfo(title: "Thread", projectName: nil) })
            #expect(second.runner.adopt(session, threadID: info.key.threadID, turnWasActive: info.turnWasActiveAtAcknowledged))
            await second.client.attach(session)
        }
        #expect(await eventually { restarted.sessionInfos.isEmpty })
        await second.runner.send(threadID: threadID, text: "two")
        #expect(await eventually { !second.runner.isRunning(threadID) })
        #expect(replies(.claude) == ["Re: one", "Re: two"])
    }

    /// Steering a turn the app took up again after relaunching: the reply shows and the turn ends normally.
    @Test(arguments: [ProviderKind.claude, .codex])
    func aSteerIntoAReattachedTurnShowsItsReply(_ provider: ProviderKind) async throws {
        select(provider)
        scripted(provider).configure = { session in
            session.supportsSteering = true
            session.onSend = { session, _ in session.emit(.assistantTextDelta(itemID: "reply", delta: "Working")) }
            session.onSteer = { session, input in
                session.emit(.assistantText(itemID: "steer-reply", text: "Re: \(input.message)"))
                session.emit(.turnCompleted(.completed))
            }
        }
        let first = launchApp()
        await first.runner.send(threadID: threadID, text: "hi")
        quit(first)
        let agent = try #require(scripted(provider).last)
        agent.emit(.assistantTextDelta(itemID: "reply", delta: " on it"))

        let second = launchApp()
        try await catchUp(second)
        #expect(second.runner.isRunning(threadID))
        #expect(second.runner.canSteer(threadID))
        #expect(await second.runner.steer(threadID: threadID, text: "also this") == .steered)
        #expect(await eventually { !second.runner.isRunning(threadID) })
        #expect(replies(provider) == ["Working on it", "Re: also this"])
        #expect(items.contains { $0.kind == .user && $0.text == "also this" && $0.steered == true })
        #expect(interruptedNotices == 0)
        #expect(agent.interrupts == 0)
        #expect(scripted(provider).sessions.count == 1)
    }

    /// Pushes lost on the way: the next event shows the gap, and the missing ones are replayed from the host's log.
    @Test func pushesThatWentMissingAreReplayedFromTheHostLog() async throws {
        let run = launchApp()
        await run.runner.send(threadID: threadID, text: "hi")
        let agent = try #require(claude.last)
        run.transport.dropNext = 2
        agent.emit(.assistantTextDelta(itemID: "reply", delta: "Hel"))
        agent.emit(tool("t1"))
        agent.emit(.assistantTextDelta(itemID: "reply", delta: "lo"))
        #expect(await eventually { replies(.claude) == ["Hello"] })
        #expect(items.count { $0.kind == .tool } == 1)
        agent.emit(.turnCompleted(.completed))
        #expect(await eventually { !run.runner.isRunning(threadID) })
        // Catching up again applies nothing twice.
        await run.client.resync(key)
        #expect(replies(.claude) == ["Hello"])
        #expect(items.count { $0.kind == .tool } == 1)
    }

    /// A turn whose end went missing, with nothing after it to show the gap: the quiet turn check finds it.
    @Test func aTurnWhoseEndWentMissingStillEnds() async throws {
        let run = launchApp()
        run.client.quietTurnCheckInterval = 0.1
        await run.runner.send(threadID: threadID, text: "hi")
        let agent = try #require(claude.last)
        agent.emit(.assistantText(itemID: "reply", text: "Done"))
        run.transport.dropNext = 1
        agent.emit(.turnCompleted(.completed))
        #expect(run.runner.isRunning(threadID))
        #expect(await eventually { !run.runner.isRunning(threadID) })
        #expect(replies(.claude) == ["Done"])
        #expect(interruptedNotices == 0)
        #expect(!items.contains { $0.kind == .error })
    }

    /// A stop whose confirmation went missing is found by checking with the host, before the runner gives up on the
    /// turn and ends the agent.
    @Test func aStopWhoseConfirmationWentMissingIsFoundWithoutEndingTheAgent() async throws {
        let run = launchApp()
        run.runner.stopTimeout = 5
        run.client.interruptCheckDelay = 0.05
        await run.runner.send(threadID: threadID, text: "hi")
        let agent = try #require(claude.last)
        run.transport.dropNext = 1
        run.runner.stop(threadID: threadID)
        #expect(await eventually { agent.interrupts == 1 })
        #expect(await eventually { !run.runner.isRunning(threadID) })
        #expect(interruptedNotices == 1)
        #expect(!agent.isShutDown)
        #expect(core.liveSessionCount == 1)
    }

    /// Catching up a second time applies nothing twice.
    @Test func catchingUpTwiceAppliesNothingTwice() async throws {
        claude.configure = { session in
            session.onSend = { session, _ in session.emit(.assistantTextDelta(itemID: "reply", delta: "Hel")) }
        }
        let first = launchApp()
        await first.runner.send(threadID: threadID, text: "hi")
        quit(first)
        let agent = try #require(claude.last)
        agent.emit(.assistantTextDelta(itemID: "reply", delta: "lo"))
        agent.emit(tool("t1"))

        let second = launchApp()
        try await catchUp(second)
        await second.client.resync(key)
        _ = try await second.transport.perform(.attach(key: key, after: 0))
        #expect(replies(.claude) == ["Hello"])
        #expect(items.count { $0.kind == .tool } == 1)
        agent.emit(.turnCompleted(.completed))
        #expect(await eventually { !second.runner.isRunning(threadID) })
    }
}

/// The in-process transport, with pushes that can be made to go missing.
@MainActor
final class LossyAgentHostTransport: AgentHostTransport {
    var onPush: ((AgentHostPush) -> Void)?
    var onDisconnect: (() -> Void)?
    let inner: InProcessAgentHostTransport
    /// How many of the next events to lose.
    var dropNext = 0

    init(_ inner: InProcessAgentHostTransport) {
        self.inner = inner
        inner.onPush = { [weak self] push in self?.forward(push) }
        inner.onDisconnect = { [weak self] in self?.onDisconnect?() }
    }

    private func forward(_ push: AgentHostPush) {
        guard case .events(let key, var events) = push else { return }
        while dropNext > 0, !events.isEmpty {
            events.removeFirst()
            dropNext -= 1
        }
        if !events.isEmpty { onPush?(.events(key: key, events)) }
    }

    func hello(_ hello: AgentHostHello) async throws -> AgentHostWelcome { try await inner.hello(hello) }
    func perform(_ command: AgentHostCommand) async throws -> AgentHostReply { try await inner.perform(command) }
    func retireWhenIdle() { inner.retireWhenIdle() }
    func invalidate() { inner.invalidate() }
    func acknowledgeSynchronously(_ acknowledgements: [AgentSessionKey: Int], timeout: TimeInterval) {
        inner.acknowledgeSynchronously(acknowledgements, timeout: timeout)
    }
}
