import Foundation
import Testing

@testable import CoincideKit

@MainActor
struct HandoffTests {
    private func thread(_ items: [TranscriptItem], sessions: [ProviderKind: ProviderSessionRef] = [:]) -> ChatThread {
        ChatThread(
            projectID: UUID(), selection: ModelSelection(provider: .claude, modelID: "default"), items: items,
            sessions: sessions)
    }

    @Test func freshThreadNeedsNoRecap() {
        let empty = thread([])
        #expect(Handoff.prompt(for: "hi", thread: empty, provider: .claude) == "hi")
    }

    @Test func currentSessionNeedsNoRecap() {
        let items = [
            TranscriptItem(kind: .user, text: "fix the bug", provider: .claude),
            TranscriptItem(kind: .assistant, text: "Done.", provider: .claude),
        ]
        let current = thread(items, sessions: [.claude: ProviderSessionRef(sessionID: "a", seenItemCount: 2)])
        #expect(Handoff.prompt(for: "next", thread: current, provider: .claude) == "next")
    }

    @Test func switchingProviderRecapsWhatItMissed() {
        let items = [
            TranscriptItem(kind: .user, text: "fix the bug", provider: .claude),
            TranscriptItem(kind: .assistant, text: "Fixed in App.swift.", provider: .claude, modelID: "opus"),
            TranscriptItem(kind: .tool, text: "ok", title: "Run `swift test`", category: .command, status: .completed, provider: .claude),
        ]
        let switched = thread(items, sessions: [.claude: ProviderSessionRef(sessionID: "a", seenItemCount: 3)])
        let prompt = Handoff.prompt(for: "now add tests", thread: switched, provider: .codex)
        #expect(prompt.contains("<conversation_handoff>"))
        #expect(prompt.contains("fix the bug"))
        #expect(prompt.contains("Claude Code (opus)"))
        #expect(prompt.contains("Run `swift test`"))
        #expect(prompt.hasSuffix("now add tests"))
    }

    @Test func returningProviderOnlyHearsNewTurns() {
        let items = [
            TranscriptItem(kind: .user, text: "first", provider: .claude),
            TranscriptItem(kind: .assistant, text: "claude answer", provider: .claude),
            TranscriptItem(kind: .user, text: "second", provider: .codex),
            TranscriptItem(kind: .assistant, text: "codex answer", provider: .codex),
        ]
        let back = thread(
            items,
            sessions: [
                .claude: ProviderSessionRef(sessionID: "a", seenItemCount: 2),
                .codex: ProviderSessionRef(sessionID: "b", seenItemCount: 4),
            ])
        let prompt = Handoff.prompt(for: "third", thread: back, provider: .claude)
        #expect(prompt.contains("codex answer"))
        #expect(!prompt.contains("claude answer"))
    }

    @Test func freshSessionAfterFailedResumeGetsItsOwnHistory() {
        let items = [
            TranscriptItem(kind: .user, text: "remember the word zebra", provider: .claude),
            TranscriptItem(kind: .assistant, text: "Noted.", provider: .claude),
        ]
        // ThreadRunner records the new session (seen nothing) before the prompt is built.
        let fresh = thread(items, sessions: [.claude: ProviderSessionRef(sessionID: "new", seenItemCount: 0)])
        let prompt = Handoff.prompt(for: "what word?", thread: fresh, provider: .claude)
        #expect(prompt.contains("zebra"))
        #expect(prompt.contains("joining an existing conversation"))
    }

    @Test func recapKeepsMostRecentWithinBudget() {
        let items = (0..<50).map { TranscriptItem(kind: .assistant, text: String(repeating: "x", count: 100) + "\($0)", provider: .codex) }
        let text = Handoff.transcript(items, budget: 1_000)
        #expect(text.contains("earlier entries omitted"))
        #expect(text.contains("x49"))
        #expect(!text.contains("x0\n"))
    }

    @Test func aLongReplyIsShortenedInsteadOfDroppingTheLastExchange() throws {
        let reply = "REPORT-START " + String(repeating: "line of the report\n", count: 1_600) + " REPORT-END"
        #expect(reply.count > Handoff.defaultBudget)
        let items = [
            TranscriptItem(kind: .user, text: "write the report", provider: .codex),
            TranscriptItem(kind: .assistant, text: reply, provider: .codex),
        ]
        let text = Handoff.transcript(items, budget: Handoff.defaultBudget)
        #expect(text.count <= Handoff.defaultBudget)
        #expect(text.contains("User:\nwrite the report"))
        #expect(text.contains("REPORT-START"))
        #expect(text.contains("REPORT-END"))
        #expect(!text.contains("earlier entries omitted"))

        let recap = try #require(Handoff.recap(thread: thread(items), provider: .claude))
        #expect(recap.contains("write the report") && recap.contains("REPORT-END"))
    }
}

@MainActor
struct StoreTests {
    private func makeStore() -> AppStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-tests-\(UUID().uuidString)")
        return AppStore(directory: dir)
    }

    @Test func threadsPersistAcrossReloads() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-tests-\(UUID().uuidString)")
        let store = AppStore(directory: dir)
        let project = store.addProject(at: URL(fileURLWithPath: "/tmp"))
        let thread = store.createThread(in: project.id)
        store.append(TranscriptItem(kind: .user, text: "hello"), to: thread.id)
        store.flush()

        let reloaded = AppStore(directory: dir)
        #expect(reloaded.projects.count == 1)
        #expect(reloaded.thread(thread.id)?.items.first?.text == "hello")
    }

    @Test func runningItemsAreClosedOnReload() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-tests-\(UUID().uuidString)")
        let store = AppStore(directory: dir)
        let project = store.addProject(at: URL(fileURLWithPath: "/tmp"))
        let thread = store.createThread(in: project.id)
        store.append(TranscriptItem(kind: .tool, title: "Run", status: .running), to: thread.id)
        store.flush()

        let reloaded = AppStore(directory: dir)
        #expect(reloaded.thread(thread.id)?.items.first?.status == .failed)
    }

    @Test func pinnedThreadsSortFirst() {
        let store = makeStore()
        let project = store.addProject(at: URL(fileURLWithPath: "/tmp"))
        let older = store.createThread(in: project.id)
        _ = store.createThread(in: project.id)
        store.updateThread(older.id) { $0.isPinned = true }
        #expect(store.threads(in: project.id).first?.id == older.id)
    }

    @Test func titleComesFromFirstLine() {
        #expect(ThreadRunner.title(from: "Fix the login bug\nmore details") == "Fix the login bug")
        let long = String(repeating: "word ", count: 30)
        #expect(ThreadRunner.title(from: long).count <= 60)
    }
}

@MainActor
struct RunnerQueueTests {
    @Test func messagesSentDuringATurnAreQueued() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-tests-\(UUID().uuidString)")
        let store = AppStore(directory: dir)
        let registry = ProviderRegistry(store: store, providers: [])
        let runner = ThreadRunner(store: store, registry: registry)
        let project = store.addProject(at: URL(fileURLWithPath: "/tmp"))
        let thread = store.createThread(in: project.id)
        runner.enqueue(threadID: thread.id, text: "later")
        #expect(runner.queuedMessages(thread.id).map(\.text) == ["later"])
        let id = runner.queuedMessages(thread.id)[0].id
        #expect(runner.removeQueued(threadID: thread.id, id: id)?.text == "later")
        #expect(runner.queuedMessages(thread.id).isEmpty)
    }

    @Test func missingProviderFailsTheTurnWithAnError() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-tests-\(UUID().uuidString)")
        let store = AppStore(directory: dir)
        let registry = ProviderRegistry(store: store, providers: [])
        let runner = ThreadRunner(store: store, registry: registry)
        let project = store.addProject(at: URL(fileURLWithPath: "/tmp"))
        let thread = store.createThread(in: project.id)
        await runner.send(threadID: thread.id, text: "hello")
        let items = store.thread(thread.id)?.items ?? []
        #expect(items.first?.kind == .user)
        #expect(items.last?.kind == .error)
        #expect(!runner.isRunning(thread.id))
        #expect(store.thread(thread.id)?.title == "hello")
    }
}

/// A scripted session for runner tests.
@MainActor
final class FakeSession: AgentSession {
    let provider: ProviderKind
    var sessionID: String?
    var onEvent: ((AgentEvent) -> Void)?
    var sent: [AgentTurnInput] = []
    var answers: [String: [String: [String]]] = [:]
    var script: [AgentEvent] = []

    init(provider: ProviderKind) { self.provider = provider }

    func start() async throws {
        sessionID = "fake-\(provider.rawValue)"
        onEvent?(.sessionStarted(id: sessionID!))
    }

    func send(_ input: AgentTurnInput) async throws {
        sent.append(input)
        for event in script { onEvent?(event) }
    }

    func respond(to approvalID: String, optionID: String) {}
    func answer(userInput requestID: String, answers: [String: [String]]) { self.answers[requestID] = answers }
    func interrupt() { onEvent?(.turnCompleted(.interrupted)) }
    func shutdown() {}
}

@MainActor
final class FakeProvider: AgentProvider {
    let kind: ProviderKind
    let executableNames = ["sh"]
    let setupHint = ""
    var lastSession: FakeSession?
    var script: [AgentEvent] = []

    init(kind: ProviderKind) { self.kind = kind }

    func detect(executable: URL?, environment: [String: String]) async -> ProviderStatus { ProviderStatus(state: .ready) }
    func models(status: ProviderStatus, environment: [String: String]) async -> [ModelOption] { [] }
    func makeSession(_ launch: AgentLaunch) -> AgentSession {
        let session = FakeSession(provider: kind)
        session.script = script
        lastSession = session
        return session
    }
}

@MainActor
struct RunnerEventTests {
    private func setUp(_ provider: FakeProvider) -> (AppStore, ThreadRunner, ChatThread) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-tests-\(UUID().uuidString)")
        let store = AppStore(directory: dir)
        let registry = ProviderRegistry(store: store, providers: [provider])
        let runner = ThreadRunner(store: store, registry: registry)
        let project = store.addProject(at: URL(fileURLWithPath: "/tmp"))
        var thread = store.createThread(in: project.id, selection: ModelSelection(provider: provider.kind, modelID: "m"))
        store.updateSettings { $0.checkpointsEnabled = false }
        thread = store.thread(thread.id)!
        return (store, runner, thread)
    }

    @Test func streamedTurnBecomesTranscriptItems() async {
        let provider = FakeProvider(kind: .claude)
        provider.script = [
            .assistantTextDelta(itemID: "m1", delta: "Hel"),
            .assistantTextDelta(itemID: "m1", delta: "lo"),
            .toolStarted(ToolCallInfo(id: "t1", category: .command, title: "Run `ls`")),
            .toolOutput(id: "t1", delta: "a.txt\n"),
            .toolCompleted(id: "t1", status: .completed, output: nil),
            .turnCompleted(.completed),
        ]
        let (store, runner, thread) = setUp(provider)
        await runner.send(threadID: thread.id, text: "hi")
        let items = store.thread(thread.id)!.items
        #expect(items.map(\.kind) == [.user, .assistant, .tool])
        #expect(items[1].text == "Hello")
        #expect(items[2].text == "a.txt\n")
        #expect(items[2].status == .completed)
        #expect(!runner.isRunning(thread.id))
        #expect(store.thread(thread.id)!.sessions[.claude]?.seenItemCount == 3)
    }

    @Test func questionsAreAnsweredThroughTheSession() async {
        let provider = FakeProvider(kind: .codex)
        let request = UserInputRequest(
            id: "q1", questions: [UserQuestion(id: "db", prompt: "Which database?", options: [.init(label: "Postgres")])])
        provider.script = [.userInputRequested(request)]
        let (store, runner, thread) = setUp(provider)
        await runner.send(threadID: thread.id, text: "set up storage")
        let question = runner.pendingQuestions(thread.id).first
        #expect(question?.questions?.questions.first?.prompt == "Which database?")
        runner.answer(threadID: thread.id, itemID: question!.id, answers: ["db": ["Postgres"]])
        #expect(provider.lastSession?.answers["q1"] == ["db": ["Postgres"]])
        #expect(store.item(question!.id, in: thread.id)?.status == .completed)
        #expect(runner.pendingQuestions(thread.id).isEmpty)
    }

    @Test func continuedSessionKeepsWhatItHasSeen() async {
        let provider = FakeProvider(kind: .pi)
        provider.script = [.turnCompleted(.completed)]
        let (store, runner, thread) = setUp(provider)
        await runner.send(threadID: thread.id, text: "one")
        let seen = store.thread(thread.id)!.sessions[.pi]!.seenItemCount
        provider.lastSession?.onEvent?(.sessionContinued(id: "forked"))
        #expect(store.thread(thread.id)!.sessions[.pi] == ProviderSessionRef(sessionID: "forked", seenItemCount: seen))
    }
}
