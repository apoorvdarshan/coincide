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

    init(kind: ProviderKind) { self.kind = kind }

    var last: ScriptedSession? { sessions.last }

    func detect(executable: URL?, environment: [String: String]) async -> ProviderStatus { ProviderStatus(state: .ready) }
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
}
