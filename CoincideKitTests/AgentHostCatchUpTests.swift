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
    private let registry: ProviderRegistry
    private let core: AgentHostCore
    private let threadID: UUID

    init() {
        store = AppStore(directory: directory.appendingPathComponent("data"))
        store.updateSettings { $0.checkpointsEnabled = false }
        registry = ProviderRegistry(store: store, providers: [claude])
        core = AgentHostCore(
            logDirectory: directory.appendingPathComponent("agent-host"), build: "1", version: "1.0"
        ) { [claude] launch, _ in claude.makeSession(launch) }
        let project = store.addProject(at: URL(fileURLWithPath: "/tmp"))
        threadID = store.createThread(in: project.id, selection: ModelSelection(provider: .claude, modelID: "m")).id
    }

    /// One run of the app: a runner whose sessions run in the host, over its own connection.
    private struct AppRun {
        let runner: ThreadRunner
        let transport: InProcessAgentHostTransport
        let client: AgentHostClient
    }

    private func launchApp() -> AppRun {
        let runner = ThreadRunner(store: store, registry: registry)
        runner.stopTimeout = 0.05
        let transport = InProcessAgentHostTransport(core: core)
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

    /// The report of background work the app already applied is not replayed, so it comes with the session instead.
    @Test func backgroundWorkStillShowsWhenTheAppComesBack() async throws {
        claude.configure = { session in
            session.onSend = { session, _ in
                session.emit(.backgroundWork([BackgroundTask(id: "a1", title: "Audit the port", kind: .agent, toolCallID: "toolu_1")]))
            }
        }
        let audit = BackgroundTask(id: "a1", title: "Audit the port", kind: .agent, toolCallID: "toolu_1")
        let first = launchApp()
        await first.runner.send(threadID: threadID, text: "audit it in the background")
        let agent = try #require(claude.last)
        agent.emit(.turnCompleted(.completed))
        #expect(await eventually { !first.runner.isRunning(threadID) })
        #expect(first.runner.backgroundTasks(threadID).map(\.task) == [audit])
        quit(first)

        let second = launchApp()
        try await catchUp(second)
        #expect(second.runner.backgroundTasks(threadID).map(\.task) == [audit])
        #expect(!second.runner.isRunning(threadID))
        agent.emit(.backgroundWork([]))
        #expect(await eventually { second.runner.backgroundTasks(threadID).isEmpty })

        // A report made while the app was closed is caught up on like any event, and wins over the snapshot.
        quit(second)
        let tests = BackgroundTask(id: "b1", title: "Run the tests", kind: .command)
        agent.emit(.backgroundWork([audit]))
        agent.emit(.backgroundWork([tests]))
        let third = launchApp()
        try await catchUp(third)
        #expect(await eventually { third.runner.backgroundTasks(threadID).map(\.task) == [tests] })
        #expect(third.runner.backgroundTasks(threadID).map(\.task) == [tests])
        // Work ends with the session.
        agent.emit(.sessionExited(error: nil))
        #expect(await eventually { third.runner.backgroundTasks(threadID).isEmpty })
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
}
