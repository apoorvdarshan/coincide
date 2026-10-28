import Foundation
import Testing

@testable import CoincideKit

/// A session whose start and send the test controls.
@MainActor
final class ScriptedSession: AgentSession, BackgroundWorkReporting {
    let provider: ProviderKind
    var sessionID: String?
    var onEvent: ((AgentEvent) -> Void)?
    var sent: [AgentTurnInput] = []
    var responses: [(id: String, option: String)] = []
    var interrupts = 0
    var isShutDown = false
    var hasBackgroundWork = false
    /// Runs inside `start`; it can wait on the test.
    var onStart: (ScriptedSession) async throws -> Void = { _ in }
    /// Runs inside `send` after the input is recorded.
    var onSend: (ScriptedSession, AgentTurnInput) async throws -> Void = { _, _ in }
    /// Called by `interrupt`.
    var onInterrupt: (ScriptedSession) -> Void = { $0.emit(.turnCompleted(.interrupted)) }
    var supportsSteering = false
    var steered: [AgentTurnInput] = []
    /// Runs inside `steer` after the input is recorded; throwing refuses the message.
    var onSteer: (ScriptedSession, AgentTurnInput) async throws -> Void = { _, _ in }

    init(provider: ProviderKind, id: String) {
        self.provider = provider
        sessionID = id
    }

    func emit(_ event: AgentEvent) { onEvent?(event) }

    func start() async throws {
        try await onStart(self)
        if let sessionID { emit(.sessionStarted(id: sessionID)) }
    }

    func send(_ input: AgentTurnInput) async throws {
        sent.append(input)
        try await onSend(self, input)
    }

    func steer(_ input: AgentTurnInput) async throws {
        steered.append(input)
        try await onSteer(self, input)
    }

    func respond(to approvalID: String, optionID: String) { responses.append((approvalID, optionID)) }
    func interrupt() {
        interrupts += 1
        onInterrupt(self)
    }
    func shutdown() { isShutDown = true }
}

@MainActor
final class ScriptedProvider: AgentProvider {
    let kind: ProviderKind
    let executableNames = ["sh"]
    let setupHint = ""
    var sessions: [ScriptedSession] = []
    var launches: [AgentLaunch] = []
    /// Configures each new session.
    var configure: (ScriptedSession) -> Void = { _ in }
    /// What `detect` reports.
    var status = ProviderStatus(state: .ready)

    init(kind: ProviderKind) { self.kind = kind }

    var last: ScriptedSession? { sessions.last }

    func detect(executable: URL?, environment: [String: String]) async -> ProviderStatus { status }
    func models(status: ProviderStatus, environment: [String: String]) async -> [ModelOption] { [] }
    func makeSession(_ launch: AgentLaunch) -> AgentSession {
        launches.append(launch)
        let session = ScriptedSession(provider: kind, id: launch.resumeSessionID ?? "\(kind.rawValue)-\(sessions.count + 1)")
        configure(session)
        sessions.append(session)
        return session
    }
}

/// Lets a test hold an async step until it says go.
@MainActor
final class Gate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
struct ThreadRunnerTests {
    private let store: AppStore
    private let claude = ScriptedProvider(kind: .claude)
    private let codex = ScriptedProvider(kind: .codex)
    private let runner: ThreadRunner
    private let threadID: UUID

    init() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-runner-\(UUID().uuidString)")
        store = AppStore(directory: dir)
        store.updateSettings { $0.checkpointsEnabled = false }
        let registry = ProviderRegistry(store: store, providers: [claude, codex])
        runner = ThreadRunner(store: store, registry: registry)
        runner.stopTimeout = 0.05
        let project = store.addProject(at: URL(fileURLWithPath: "/tmp"))
        threadID = store.createThread(in: project.id, selection: ModelSelection(provider: .claude, modelID: "m")).id
    }

    private var items: [TranscriptItem] { store.thread(threadID)?.items ?? [] }

    private func select(_ provider: ProviderKind) {
        store.updateThread(threadID) { $0.selection = ModelSelection(provider: provider, modelID: "m") }
    }

    /// Polls for up to ten seconds; the first send resolves the login shell's environment, which can be slow.
    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<1_000 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    /// Sends a message whose turn completes with a reply.
    private func completeTurn(_ text: String, reply: String) async {
        let provider = store.thread(threadID)!.selection.provider == .claude ? claude : codex
        provider.configure = { session in
            session.onSend = { session, _ in
                session.emit(.assistantText(itemID: UUID().uuidString, text: reply))
                session.emit(.turnCompleted(.completed))
            }
        }
        provider.sessions.forEach(provider.configure)
        await runner.send(threadID: threadID, text: text)
    }

    // MARK: Background work

    @Test func backgroundWorkOutlastsTheTurnAndEndsWithTheSession() async throws {
        await completeTurn("audit it", reply: "Started an agent.")
        let session = try #require(claude.sessions.first)
        var changes = 0
        let token = store.observe { if case .runState(let id) = $0, id == threadID { changes += 1 } }
        let task = BackgroundTask(id: "a1", title: "Audit the port", kind: .agent, toolCallID: "toolu_1")
        session.emit(.backgroundWork([task]))
        #expect(!runner.isRunning(threadID))
        #expect(runner.backgroundTasks(threadID).map(\.task) == [task])
        #expect(runner.backgroundTasks(threadID).first?.provider == .claude)
        // The same report again changes nothing.
        session.emit(.backgroundWork([task]))
        #expect(changes == 1)
        session.emit(.sessionExited(error: nil))
        #expect(runner.backgroundTasks(threadID).isEmpty)
        #expect(changes == 2)
        _ = token
    }

    // MARK: Starting and stopping

    @Test func aFolderThatIsGoneFailsTheTurn() async {
        let project = store.addProject(at: URL(fileURLWithPath: "/tmp/coincide-missing-\(UUID().uuidString)"))
        let thread = store.createThread(in: project.id, selection: ModelSelection(provider: .claude, modelID: "m"))
        await runner.send(threadID: thread.id, text: "hello")
        #expect(store.thread(thread.id)?.items.last?.text == "The project folder is missing.")
        #expect(claude.sessions.isEmpty)
        #expect(!runner.isRunning(thread.id))
    }

    @Test func stopWhileStartingEndsTheTurnAndANewSendSharesTheLaunch() async throws {
        let gate = Gate()
        claude.configure = { $0.onStart = { _ in await gate.wait() } }
        let first = Task { await runner.send(threadID: threadID, text: "one") }
        #expect(await eventually { claude.sessions.count == 1 })
        #expect(runner.isStarting(threadID))
        runner.stop(threadID: threadID)
        #expect(await eventually { !runner.isRunning(threadID) })
        #expect(items.last?.text == "Interrupted")

        // The next message waits for the same process instead of spawning a second one.
        let second = Task { await runner.send(threadID: threadID, text: "two") }
        try await Task.sleep(for: .milliseconds(30))
        gate.open()
        await first.value
        await second.value
        #expect(claude.sessions.count == 1)
        #expect(claude.last?.sent.map(\.message) == ["two"])
        #expect(runner.isRunning(threadID))
        #expect(runner.turn(threadID)?.userItemID == items.last { $0.kind == .user }?.id)
    }

    @Test func aProviderThatNeverConfirmsAStopIsShutDown() async {
        claude.configure = { $0.onInterrupt = { _ in } }
        await runner.send(threadID: threadID, text: "work")
        let session = claude.last
        runner.stop(threadID: threadID)
        #expect(session?.interrupts == 1)
        #expect(await eventually { !runner.isRunning(threadID) })
        #expect(session?.isShutDown == true)
        #expect(runner.liveProviders(threadID).isEmpty)
        // A late completion from the stopped session does not touch the next turn.
        claude.configure = { _ in }
        await runner.send(threadID: threadID, text: "next")
        session?.emit(.turnCompleted(.completed))
        #expect(runner.isRunning(threadID))
        #expect(claude.sessions.count == 2)
        #expect(claude.launches.last?.resumeSessionID == "claude-1")
    }

    @Test func aCompletionBeforeThePromptIsHandedOverIsIgnored() async {
        // A late completion of some earlier turn arrives while the session starts.
        claude.configure = { $0.onStart = { session in session.emit(.turnCompleted(.completed)) } }
        await runner.send(threadID: threadID, text: "one")
        #expect(runner.isRunning(threadID))
        #expect(claude.last?.sent.map(\.message) == ["one"])
    }

    @Test func aTurnStoppedWhileItsBeforeSnapshotIsTakenStillGetsAnAfterSnapshot() async throws {
        let repository = try await TestRepository.make()
        // Enough files that taking the snapshot outlasts the stop timeout.
        for index in 0..<500 { try repository.write("files/\(index).txt", "\(index)\n") }
        let checkpoints = CheckpointService(store: store, directory: try TestRepository.makeDirectory("checkpoints"))
        runner.checkpoints = checkpoints
        runner.stopTimeout = 0.001
        store.updateSettings { $0.checkpointsEnabled = true }
        let project = store.addProject(at: repository.url)
        let thread = store.createThread(in: project.id, selection: ModelSelection(provider: .claude, modelID: "m"))

        let sending = Task { await runner.send(threadID: thread.id, text: "one") }
        #expect(await eventually { runner.isCapturingCheckpoints })
        runner.stop(threadID: thread.id)
        #expect(await eventually { !runner.isRunning(thread.id) })
        await sending.value
        #expect(await eventually { !runner.isCapturingCheckpoints })
        // The turn ended before its prompt was sent, while its before snapshot was still being taken.
        #expect(claude.last?.sent.isEmpty == true)
        let turnID = try #require(store.thread(thread.id)?.items.first { $0.kind == .user }?.id)
        #expect(checkpoints.checkpoint(threadID: thread.id, userItemID: turnID)?.isComplete == true)
    }

    // MARK: Idle sessions

    @Test func anIdleSessionIsKeptWhileItsAgentRunsBackgroundWork() async {
        await completeTurn("one", reply: "The dev server runs in the background.")
        let session = claude.last!
        session.hasBackgroundWork = true
        let later = Date().addingTimeInterval(3_600)
        runner.shutDownIdleSessions(now: later)
        #expect(!session.isShutDown)
        #expect(runner.liveProviders(threadID) == [.claude])

        // Once the work ends, the session counts as idle from then on.
        session.hasBackgroundWork = false
        runner.shutDownIdleSessions(now: later.addingTimeInterval(60))
        #expect(!session.isShutDown)
        runner.shutDownIdleSessions(now: later.addingTimeInterval(3_600))
        #expect(session.isShutDown)
        #expect(runner.liveProviders(threadID).isEmpty)
    }

    // MARK: What each provider has seen

    @Test func aTurnThatNeverReachedTheProviderDoesNotCountAsSeen() async {
        await completeTurn("one", reply: "Claude did it")
        select(.codex)
        await completeTurn("two", reply: "Codex did it")
        select(.claude)
        let seen = store.thread(threadID)!.sessions[.claude]!.seenItemCount
        claude.last?.onSend = { _, _ in throw AgentError.providerError("rate limited") }
        await runner.send(threadID: threadID, text: "three")
        #expect(items.last?.kind == .error)
        #expect(store.thread(threadID)!.sessions[.claude]!.seenItemCount == seen)

        // The next prompt still recaps Codex's turn.
        claude.last?.onSend = { session, _ in session.emit(.turnCompleted(.completed)) }
        await runner.send(threadID: threadID, text: "four")
        let input = claude.last?.sent.last
        #expect(input?.message == "four")
        #expect(input?.handoffRecap?.contains("Codex did it") == true)
        #expect(input?.text.hasSuffix("\n\nfour") == true)
        #expect(store.thread(threadID)!.sessions[.claude]!.seenItemCount == items.count)
    }

    @Test func outputBeforeThePromptIsSentDoesNotCountAsDelivery() async {
        await completeTurn("one", reply: "Claude did it")
        select(.codex)
        await completeTurn("two", reply: "Codex did it")
        select(.claude)
        let seen = store.thread(threadID)!.sessions[.claude]!.seenItemCount
        runner.shutdown(threadID: threadID, provider: .claude)

        // While Claude's next process starts, it answers a finished background task on its own.
        let ownOutput: (ScriptedSession) -> Void = { session in
            session.emit(.agentTurnStarted(note: nil))
            session.emit(.assistantTextDelta(itemID: UUID().uuidString, delta: "The background tests passed."))
        }
        // The prompt then never reaches it: sending fails…
        claude.configure = { session in
            session.onStart = { ownOutput($0) }
            session.onSend = { _, _ in throw AgentError.providerError("could not relaunch") }
        }
        await runner.send(threadID: threadID, text: "three")
        #expect(items.last?.kind == .error)
        #expect(store.thread(threadID)!.sessions[.claude]!.seenItemCount == seen)

        // …or the process exits before the prompt is handed over.
        runner.shutdown(threadID: threadID, provider: .claude)
        claude.configure = { session in
            session.onStart = { session in
                ownOutput(session)
                throw AgentError.providerError("exited")
            }
        }
        await runner.send(threadID: threadID, text: "four")
        #expect(items.last?.kind == .error)
        #expect(store.thread(threadID)!.sessions[.claude]!.seenItemCount == seen)

        // The next prompt that gets through still recaps Codex's turn.
        claude.configure = { session in session.onSend = { session, _ in session.emit(.turnCompleted(.completed)) } }
        await runner.send(threadID: threadID, text: "five")
        #expect(claude.last?.sent.last?.handoffRecap?.contains("Codex did it") == true)
    }

    @Test func itemsCarryTheModelOfTheProviderThatMadeThem() async {
        await completeTurn("one", reply: "done")
        let session = claude.last!
        // The thread moved on to Codex; Claude then answers a finished background task on its own.
        store.updateThread(threadID) { $0.selection = ModelSelection(provider: .codex, modelID: "gpt") }
        session.emit(.agentTurnStarted(note: nil))
        session.emit(.assistantText(itemID: "bg", text: "The background tests passed."))
        session.emit(.turnCompleted(.completed))
        #expect(items.last { $0.kind == .assistant }?.modelID == "m")

        // Picking another model during a turn does not relabel the running turn's output.
        store.updateThread(threadID) { $0.selection = ModelSelection(provider: .claude, modelID: "m") }
        session.onSend = { _, _ in }
        await runner.send(threadID: threadID, text: "two")
        store.updateThread(threadID) { $0.selection = ModelSelection(provider: .claude, modelID: "other") }
        session.emit(.assistantText(itemID: "r2", text: "Working on it."))
        #expect(items.last?.modelID == "m")
    }

    @Test func theInputCarriesTheRecapForANewNativeSession() async {
        await completeTurn("one", reply: "Claude did it")
        select(.codex)
        await completeTurn("two", reply: "Codex did it")
        select(.claude)
        await completeTurn("three", reply: "ok")
        let input = claude.last?.sent.last
        #expect(input?.handoffRecap?.contains("Claude did it") == false)
        #expect(input?.handoffRecap?.contains("Codex did it") == true)
        #expect(input?.newSessionRecap?.contains("Claude did it") == true)
        #expect(input?.prompt(forNewSession: true).hasSuffix("\n\nthree") == true)
        #expect(input?.threadTitle == "one")
    }

    @Test func aNativeSessionReplacedWhileSendingStartsCountingAgain() async {
        await completeTurn("one", reply: "done")
        claude.last?.onSend = { session, _ in
            // Resuming failed while sending; the session started over.
            session.emit(.sessionStarted(id: "claude-new"))
            session.emit(.turnCompleted(.completed))
        }
        await runner.send(threadID: threadID, text: "two")
        #expect(store.thread(threadID)!.sessions[.claude] == ProviderSessionRef(sessionID: "claude-new", seenItemCount: items.count))
    }

    @Test func rewindingEndsTheLiveSession() async {
        await completeTurn("one", reply: "done")
        await completeTurn("two", reply: "done again")
        let second = items.last { $0.kind == .user }!
        store.truncate(threadID, from: second.id)
        claude.configure = { session in session.onSend = { session, _ in session.emit(.turnCompleted(.completed)) } }
        await runner.send(threadID: threadID, text: "two, edited")
        #expect(claude.sessions.count == 2)
        #expect(claude.sessions.first?.isShutDown == true)
        #expect(claude.launches.last?.resumeSessionID == nil)
        #expect(claude.last?.sent.last?.newSessionRecap?.contains("done") == true)
    }

    // MARK: Events between and after turns

    @Test func lateOutputIsSettled() async {
        await completeTurn("one", reply: "done")
        let session = claude.last!
        session.emit(.assistantTextDelta(itemID: "late", delta: "trailing"))
        #expect(items.last?.status == .completed)
        session.emit(.toolStarted(ToolCallInfo(id: "bg", category: .command, title: "Run `sleep`")))
        #expect(items.last?.status == .running)
        await completeTurn("two", reply: "done")
        #expect(items.first { $0.externalID == "bg" }?.status == .completed)
    }

    @Test func aToolFromAnEarlierTurnStillGetsLateOutput() async {
        claude.configure = { session in
            session.onSend = { session, _ in
                session.emit(.toolStarted(ToolCallInfo(id: "bg", category: .command, title: "Run `swift test` in the background")))
                session.emit(.toolCompleted(id: "bg", status: .completed, output: "Started in the background."))
                session.emit(.turnCompleted(.completed))
            }
        }
        await runner.send(threadID: threadID, text: "run the tests in the background")
        await completeTurn("meanwhile", reply: "ok")
        // The background command finishes after the next turn started.
        claude.last!.emit(.toolOutput(id: "bg", delta: "\nTests passed."))
        #expect(items.first { $0.externalID == "bg" }?.text == "Started in the background.\nTests passed.")

        // Another provider's tool with the same id is a different tool.
        select(.codex)
        await completeTurn("codex, go", reply: "ok")
        codex.last!.emit(.toolOutput(id: "bg", delta: "\nnot Claude's"))
        #expect(items.first { $0.externalID == "bg" }?.text == "Started in the background.\nTests passed.")
    }

    @Test func promptsOfAnEndedSessionAreClosed() async {
        await completeTurn("one", reply: "done")
        let session = claude.last!
        session.emit(.approvalRequested(ApprovalRequest(id: "a1", category: .command, title: "Run", options: ApprovalRequest.standardOptions)))
        // The same request again updates the open one.
        session.emit(.approvalRequested(ApprovalRequest(id: "a1", category: .command, title: "Run it", options: ApprovalRequest.standardOptions)))
        #expect(runner.pendingApprovals(threadID).map(\.title) == ["Run it"])
        session.emit(.sessionExited(error: "crashed"))
        #expect(runner.pendingApprovals(threadID).isEmpty)
        #expect(runner.liveProviders(threadID).isEmpty)
    }

    @Test func answeringAPromptWhoseSessionIsGoneClosesIt() async {
        await completeTurn("one", reply: "done")
        claude.last!.emit(.approvalRequested(ApprovalRequest(id: "a1", category: .command, title: "Run", options: ApprovalRequest.standardOptions)))
        let item = runner.pendingApprovals(threadID).first!
        runner.shutdown(threadID: threadID, provider: .claude)
        runner.respond(threadID: threadID, itemID: item.id, optionID: "allow")
        #expect(store.item(item.id, in: threadID)?.status == .declined)
    }

    @Test func toolOutputKeepsTheNewestPartOfLongOutput() async {
        claude.configure = { $0.onSend = { session, _ in session.emit(.toolStarted(ToolCallInfo(id: "t", category: .command, title: "Run"))) } }
        await runner.send(threadID: threadID, text: "go")
        let chunk = String(repeating: "é", count: 60_000)
        for index in 0..<3 { claude.last!.emit(.toolOutput(id: "t", delta: chunk + "\(index)")) }
        let text = items.last!.text
        #expect(text.utf8.count <= ThreadRunner.toolOutputLimit)
        #expect(text.hasSuffix("2"))
        #expect(text.unicodeScalars.allSatisfy { $0 == "é" || $0.properties.numericType != nil })
    }

    @Test func usageStartsEachTurnWithoutThePreviousTurnsCounts() async {
        claude.configure = { session in
            session.onSend = { session, _ in
                session.emit(.usage(TokenUsage(inputTokens: 100, outputTokens: 5, cachedInputTokens: 40, contextWindow: 1_000)))
                session.emit(.turnCompleted(.completed))
            }
        }
        await runner.send(threadID: threadID, text: "one")
        #expect(runner.usage[threadID] == TokenUsage(inputTokens: 100, outputTokens: 5, cachedInputTokens: 40, contextWindow: 1_000))
        claude.last?.onSend = { session, _ in
            session.emit(.usage(TokenUsage(inputTokens: 150)))
            session.emit(.turnCompleted(.completed))
        }
        // Another model: the old context window no longer applies either.
        store.updateThread(threadID) { $0.selection = ModelSelection(provider: .claude, modelID: "other") }
        await runner.send(threadID: threadID, text: "two")
        #expect(runner.usage[threadID] == TokenUsage(inputTokens: 150))
    }

    // MARK: Turns the agent starts

    @Test func aTurnTheAgentStartsRunsUntilItCompletes() async {
        await completeTurn("one", reply: "done")
        let session = claude.last!
        session.onSend = { session, _ in session.emit(.turnCompleted(.completed)) }
        session.emit(.agentTurnStarted(note: nil))
        #expect(runner.isRunning(threadID))
        #expect(!runner.isStarting(threadID))
        #expect(runner.turn(threadID)?.isAgentInitiated == true)
        #expect(items.last?.kind == .notice)
        // A message typed meanwhile waits for it.
        await runner.send(threadID: threadID, text: "follow up")
        #expect(runner.queuedMessages(threadID).count == 1)
        session.emit(.assistantText(itemID: "bg-reply", text: "The tests passed."))
        session.emit(.turnCompleted(.completed))
        #expect(await eventually { session.sent.count == 2 })
        #expect(session.sent.last?.message == "follow up")
        #expect(session.sent.last?.handoffRecap == nil)
    }

    @Test func stoppingATurnTheAgentStartedInterruptsIt() async {
        await completeTurn("one", reply: "done")
        let session = claude.last!
        session.emit(.agentTurnStarted(note: "Claude Code continued on its own."))
        runner.stop(threadID: threadID)
        #expect(session.interrupts == 1)
        #expect(!runner.isRunning(threadID))
        #expect(items.last?.text == "Interrupted")
    }

    @Test func anAgentTurnDuringAnotherTurnIsIgnored() async {
        await completeTurn("one", reply: "done")
        let claudeSession = claude.last!
        select(.codex)
        codex.configure = { _ in }
        await runner.send(threadID: threadID, text: "codex, go")
        claudeSession.emit(.agentTurnStarted(note: nil))
        claudeSession.emit(.turnCompleted(.completed))
        #expect(runner.turn(threadID)?.provider == .codex)
        #expect(runner.isRunning(threadID))
    }

    @Test func shutdownDuringALaunchShutsTheNewSessionDown() async {
        let gate = Gate()
        claude.configure = { $0.onStart = { _ in await gate.wait() } }
        let sending = Task { await runner.send(threadID: threadID, text: "one") }
        #expect(await eventually { claude.sessions.count == 1 })
        runner.shutdown(threadID: threadID)
        gate.open()
        await sending.value
        #expect(claude.last?.isShutDown == true)
        #expect(claude.last?.sent.isEmpty == true)
        #expect(!runner.isRunning(threadID))
        #expect(runner.liveProviders(threadID).isEmpty)
    }

    // MARK: Steering

    /// Starts a turn that runs until the test completes it, on a session that takes steering or not.
    private func startRunningTurn(_ text: String = "one", steering: Bool = true) async -> ScriptedSession {
        claude.configure = { $0.supportsSteering = steering }
        await runner.send(threadID: threadID, text: text)
        return claude.last!
    }

    @Test func steeringPutsTheMessageIntoTheRunningTurn() async {
        let session = await startRunningTurn()
        #expect(runner.canSteer(threadID))
        let turnID = runner.turn(threadID)!.userItemID
        session.emit(.assistantText(itemID: "a1", text: "Working on it"))

        let delivery = await runner.steer(threadID: threadID, text: "  Also update the README  ", imagePaths: ["/tmp/a.png"])
        #expect(delivery == .steered)
        let input = session.steered.last
        #expect(input?.message == "Also update the README")
        #expect(input?.handoffRecap == nil && input?.newSessionRecap == nil)
        #expect(input?.imagePaths == ["/tmp/a.png"])
        // Recorded as a user item of the running turn, after what the agent wrote so far.
        let steer = items.last!
        #expect(steer.kind == .user && steer.text == "Also update the README" && steer.provider == .claude)
        #expect(steer.attachments == ["/tmp/a.png"])
        // Marked, so the transcript keeps it inside the turn; the message that opened the turn is not.
        #expect(steer.steered == true && !steer.opensUserTurn)
        #expect(items.first { $0.id == turnID }?.steered == nil)
        #expect(runner.turn(threadID)?.userItemID == turnID)
        #expect(runner.turn(threadID)?.steeredItemIDs == [steer.id])
        #expect(runner.queuedMessages(threadID).isEmpty)
        #expect(session.sent.count == 1)

        session.emit(.assistantText(itemID: "a2", text: "Done, README too"))
        session.emit(.turnCompleted(.completed))
        #expect(!runner.isRunning(threadID))
        #expect(store.thread(threadID)!.sessions[.claude]!.seenItemCount == items.count)
    }

    @Test func agentsThatCannotSteerGetTheMessageAfterTheTurn() async {
        let session = await startRunningTurn(steering: false)
        #expect(!runner.canSteer(threadID))
        let delivery = await runner.steer(threadID: threadID, text: "two")
        #expect(delivery == .queued)
        #expect(session.steered.isEmpty)
        #expect(runner.queuedMessages(threadID).map(\.text) == ["two"])
        session.onSend = { session, _ in session.emit(.turnCompleted(.completed)) }
        session.emit(.turnCompleted(.completed))
        #expect(await eventually { session.sent.count == 2 })
        #expect(session.sent.last?.message == "two")
        // Sent after the turn, it opens a turn of its own.
        #expect(items.last { $0.kind == .user }?.opensUserTurn == true)
    }

    @Test func aMessageTheTurnRefusesWaitsForIt() async {
        let session = await startRunningTurn()
        session.onSteer = { _, _ in throw AgentError.providerError("not now") }
        let delivery = await runner.steer(threadID: threadID, text: "two")
        #expect(delivery == .queued)
        #expect(runner.queuedMessages(threadID).map(\.text) == ["two"])
        #expect(!items.contains { $0.text == "two" })
    }

    @Test func aMessageRefusedBecauseTheTurnEndedStartsTheNextTurn() async {
        let session = await startRunningTurn()
        session.onSteer = { session, _ in
            session.emit(.turnCompleted(.completed))
            throw AgentError.providerError("the turn is over")
        }
        session.onSend = { session, _ in session.emit(.turnCompleted(.completed)) }
        let delivery = await runner.steer(threadID: threadID, text: "two")
        #expect(delivery == .sent)
        #expect(session.sent.map(\.message) == ["one", "two"])
        #expect(runner.queuedMessages(threadID).isEmpty)
    }

    @Test func aSteerTakenAsTheTurnEndsCountsAsSeen() async {
        let session = await startRunningTurn()
        session.emit(.assistantText(itemID: "a1", text: "done"))
        // The agent took the message, but its turn ended while the steer was on its way.
        session.onSteer = { session, _ in session.emit(.turnCompleted(.completed)) }
        let delivery = await runner.steer(threadID: threadID, text: "two")
        #expect(delivery == .steered)
        #expect(!runner.isRunning(threadID))
        #expect(items.last?.kind == .user && items.last?.text == "two")
        // The agent took it into the turn that just ended, so it stays with that turn.
        #expect(items.last?.isSteered == true)
        #expect(session.sent.map(\.message) == ["one"])
        // The session has seen the message, so the next turn does not recap it.
        #expect(store.thread(threadID)!.sessions[.claude]!.seenItemCount == items.count)
    }

    @Test func steeringAnIdleThreadSendsAsUsual() async {
        claude.configure = { session in
            session.supportsSteering = true
            session.onSend = { session, _ in session.emit(.turnCompleted(.completed)) }
        }
        #expect(await runner.steer(threadID: threadID, text: "one") == .sent)
        #expect(await runner.steer(threadID: threadID, text: "   ") == nil)
        #expect(claude.last?.sent.map(\.message) == ["one"])
        #expect(claude.last?.steered.isEmpty == true)
    }

    @Test func onlyTheThreadsCurrentAgentWorkingOnAPromptCanBeSteered() async {
        let gate = Gate()
        claude.configure = { session in
            session.supportsSteering = true
            session.onStart = { _ in await gate.wait() }
        }
        let sending = Task { await runner.send(threadID: threadID, text: "one") }
        #expect(await eventually { runner.isRunning(threadID) })
        // Still starting: the agent has no prompt to steer yet.
        #expect(!runner.canSteer(threadID))
        #expect(await runner.steer(threadID: threadID, text: "early") == .queued)
        gate.open()
        await sending.value
        #expect(runner.canSteer(threadID))
        // A message for another agent waits for the turn instead.
        select(.codex)
        #expect(!runner.canSteer(threadID))
        select(.claude)
        runner.stop(threadID: threadID)
        #expect(!runner.canSteer(threadID))
    }

    @Test func aTurnTheAgentStartedItselfIsNotSteered() async {
        await completeTurn("one", reply: "done")
        let session = claude.last!
        session.supportsSteering = true
        session.emit(.agentTurnStarted(note: nil))
        #expect(!runner.canSteer(threadID))
    }

    @Test func aQueuedMessageCanBeSentIntoTheTurnAndKeepsItsPlaceIfRefused() async {
        let session = await startRunningTurn()
        runner.enqueue(threadID: threadID, text: "first")
        runner.enqueue(threadID: threadID, text: "second")
        runner.enqueue(threadID: threadID, text: "third")
        let queued = runner.queuedMessages(threadID)

        #expect(await runner.steerQueued(threadID: threadID, id: queued[1].id) == .steered)
        #expect(session.steered.map(\.message) == ["second"])
        #expect(runner.queuedMessages(threadID).map(\.text) == ["first", "third"])
        #expect(items.last?.text == "second" && items.last?.isSteered == true)

        session.onSteer = { _, _ in throw AgentError.providerError("not now") }
        #expect(await runner.steerQueued(threadID: threadID, id: queued[2].id) == .queued)
        #expect(runner.queuedMessages(threadID).map(\.id) == [queued[0].id, queued[2].id])
        #expect(await runner.steerQueued(threadID: threadID, id: UUID()) == nil)
    }

    // MARK: Context sent with a message

    /// The pull requests a message mentions reach the agent after the message, as in T3 Code, but the transcript
    /// keeps what the user wrote.
    @Test func contextReachesTheAgentButStaysOutOfTheTranscript() async {
        claude.configure = { session in session.onSend = { session, _ in session.emit(.turnCompleted(.completed)) } }
        await runner.send(threadID: threadID, text: "  Review #12  ", context: "<pull_request number=\"12\"/>")
        #expect(claude.last?.sent.last?.message == "Review #12\n\n<pull_request number=\"12\"/>")
        #expect(items.first { $0.kind == .user }?.text == "Review #12")
        await runner.send(threadID: threadID, text: "plain", context: "")
        #expect(claude.last?.sent.last?.message == "plain")
    }

    @Test func aQueuedMessageKeepsItsContext() async {
        let session = await startRunningTurn(steering: false)
        await runner.send(threadID: threadID, text: "two #3", context: "about 3")
        #expect(runner.queuedMessages(threadID).map(\.context) == ["about 3"])
        session.onSend = { session, _ in session.emit(.turnCompleted(.completed)) }
        session.emit(.turnCompleted(.completed))
        #expect(await eventually { session.sent.count == 2 })
        #expect(session.sent.last?.message == "two #3\n\nabout 3")
        #expect(items.last { $0.kind == .user }?.text == "two #3")
    }

    @Test func aSteeredMessageKeepsItsContext() async {
        let session = await startRunningTurn()
        #expect(await runner.steer(threadID: threadID, text: "also #3", context: "about 3") == .steered)
        #expect(session.steered.last?.message == "also #3\n\nabout 3")
        #expect(items.last?.text == "also #3")
        // A message the turn refuses waits in the queue with its context.
        session.onSteer = { _, _ in throw AgentError.providerError("not now") }
        #expect(await runner.steer(threadID: threadID, text: "later", context: "ctx") == .queued)
        #expect(runner.queuedMessages(threadID).last?.context == "ctx")
    }

    @Test func aQueuedMessageSentWhileIdleStartsATurn() async {
        let session = await startRunningTurn(steering: false)
        runner.enqueue(threadID: threadID, text: "later")
        let id = runner.queuedMessages(threadID)[0].id
        // Stopped: the queue waits for the user.
        runner.stop(threadID: threadID)
        #expect(runner.queuedMessages(threadID).count == 1)
        session.onSend = { session, _ in session.emit(.turnCompleted(.completed)) }
        #expect(await runner.steerQueued(threadID: threadID, id: id) == .sent)
        #expect(session.sent.last?.message == "later")
        #expect(runner.queuedMessages(threadID).isEmpty)
    }

    // MARK: Usage limits

    private func window(_ id: String, _ used: Double, kind: UsageLimitWindow.Kind = .session) -> UsageLimitWindow {
        UsageLimitWindow(id: id, kind: kind, label: id, usedPercent: used)
    }

    @Test func sessionsReportUsageLimitsPerProvider() async {
        await completeTurn("one", reply: "done")
        let session = claude.last!
        session.emit(.rateLimits([window("five_hour", 20), window("seven_day", 40, kind: .weekly)]))
        session.emit(.rateLimits([window("five_hour", 35)]))
        let limits = runner.usageLimits(for: .claude)
        #expect(limits?.windows.map(\.id) == ["five_hour", "seven_day"])
        #expect(limits?.windows.map(\.usedPercent) == [35, 40])
        #expect(runner.usageLimits(for: .codex) == nil)
        // Agents repeat unchanged windows with every token count; only changes are passed on.
        #expect(!runner.recordUsageLimits([window("five_hour", 35)], for: .claude))
        #expect(runner.recordUsageLimits([window("five_hour", 36)], for: .claude))
        #expect(!runner.recordUsageLimits([], for: .claude))
    }

    @Test func usageLimitsFromACheckAndFromSessionsCombine() async {
        let registry = ProviderRegistry(store: store, providers: [claude, codex])
        let runner = ThreadRunner(store: store, registry: registry)
        let checkedAt = Date()
        claude.status = ProviderStatus(
            state: .ready,
            usageLimits: UsageLimits(windows: [window("five_hour", 10), window("seven_day", 50, kind: .weekly)], checkedAt: checkedAt))
        await registry.refresh(.claude)
        #expect(runner.usageLimits(for: .claude)?.windows.map(\.usedPercent) == [10, 50])

        // A later report changes the window it names; the other keeps what the check read.
        runner.recordUsageLimits([window("five_hour", 30)], for: .claude, at: checkedAt.addingTimeInterval(60))
        #expect(runner.usageLimits(for: .claude)?.windows.map(\.usedPercent) == [30, 50])

        // A newer check reads every window afresh.
        claude.status.usageLimits = UsageLimits(windows: [window("five_hour", 5)], checkedAt: Date().addingTimeInterval(120))
        await registry.refresh(.claude)
        #expect(runner.usageLimits(for: .claude)?.windows.map(\.usedPercent) == [5])
    }
}

@MainActor
struct AccessDowngradeRunnerTests {
    @Test func aFullAccessSessionIsRestartedWhenTheThreadAsksForApproval() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-tests-\(UUID().uuidString)")
        let store = AppStore(directory: dir)
        let provider = FakeProvider(kind: .codex)
        provider.script = [.turnCompleted(.completed)]
        let runner = ThreadRunner(store: store, registry: ProviderRegistry(store: store, providers: [provider]))
        store.updateSettings { $0.checkpointsEnabled = false }
        let project = store.addProject(at: FileManager.default.temporaryDirectory)
        let thread = store.createThread(in: project.id, selection: ModelSelection(provider: .codex, modelID: "m"))
        store.updateThread(thread.id) { $0.accessMode = .fullAccess }
        await runner.send(threadID: thread.id, text: "one")
        let first = provider.lastSession
        store.updateThread(thread.id) { $0.accessMode = .approval }
        await runner.send(threadID: thread.id, text: "two")
        #expect(provider.lastSession !== first)
        #expect(provider.lastSession?.sent.last?.accessMode == .approval)
    }
}

/// A session whose start never finishes, like an agent blocked on a macOS permission prompt.
@MainActor
private final class StalledSession: AgentSession {
    let provider: ProviderKind
    var sessionID: String?
    var onEvent: ((AgentEvent) -> Void)?
    init(provider: ProviderKind) { self.provider = provider }
    func start() async throws { try await Task.sleep(for: .seconds(30)) }
    func send(_ input: AgentTurnInput) async throws {}
    func respond(to approvalID: String, optionID: String) {}
    func interrupt() {}
    func shutdown() {}
}

@MainActor
private final class StalledProvider: AgentProvider {
    let kind: ProviderKind = .claude
    let executableNames = ["sh"]
    let setupHint = ""
    func detect(executable: URL?, environment: [String: String]) async -> ProviderStatus { ProviderStatus(state: .ready) }
    func models(status: ProviderStatus, environment: [String: String]) async -> [ModelOption] { [] }
    func makeSession(_ launch: AgentLaunch) -> AgentSession { StalledSession(provider: kind) }
}

@MainActor
struct SlowStartNoticeTests {
    @Test func aSlowAgentStartExplainsFolderPermissions() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-tests-\(UUID().uuidString)")
        let store = AppStore(directory: dir)
        let runner = ThreadRunner(store: store, registry: ProviderRegistry(store: store, providers: [StalledProvider()]))
        runner.slowStartNoticeDelay = .milliseconds(100)
        var slowStarts: [ProviderKind] = []
        runner.onSlowStart = { _, provider in slowStarts.append(provider) }
        store.updateSettings { $0.checkpointsEnabled = false }
        let project = store.addProject(at: FileManager.default.temporaryDirectory)
        let thread = store.createThread(in: project.id, selection: ModelSelection(provider: .claude, modelID: "m"))
        let sending = Task { await runner.send(threadID: thread.id, text: "hi") }
        try await Task.sleep(for: .milliseconds(600))
        let notice = store.thread(thread.id)?.items.last { $0.kind == .notice }
        #expect(notice?.text.contains("Files and Folders") == true)
        #expect(slowStarts == [.claude])
        runner.stop(threadID: thread.id)
        sending.cancel()
    }
}

@MainActor
struct ThreadTitleTests {
    @Test func aTitleIsTakenFromTheAgentsJSONAndTidied() {
        #expect(ThreadTitles.title(fromReply: #"Sure. {"title": "  \"Remember the login email.\" "}"#) == "Remember the login email")
        #expect(ThreadTitles.title(fromReply: #"{"title": "Fix   flaky\nupload test"}"#) == "Fix flaky")
        #expect(ThreadTitles.title(fromReply: #"{"name": "nope"}"#) == nil)
        #expect(ThreadTitles.title(fromReply: #"{"title": " … "}"#) == "…")
        let long = ThreadTitles.title(fromReply: #"{"title": "\#(String(repeating: "word ", count: 30))"}"#)
        #expect(long?.count == 60 && long?.hasSuffix("…") == true)
    }

    @Test func thePromptCarriesTheMessage() {
        let prompt = ThreadTitles.prompt(message: "Make the login screen remember the email")
        #expect(prompt.contains("<message>\nMake the login screen remember the email\n</message>"))
        #expect(prompt.contains("\"title\""))
    }
}
