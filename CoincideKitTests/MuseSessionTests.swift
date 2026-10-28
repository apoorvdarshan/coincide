import Foundation
import Testing

@testable import CoincideKit

/// An in-memory `muse serve`: answers requests by method (echoing command ids, as Muse does) and lets tests push the
/// notifications and requests Muse sends.
@MainActor
final class FakeMuseTransport: MuseTransport {
    enum Reply {
        case result(JSONValue)
        case error(code: Int, kind: String, message: String)
        case silent
    }

    var onLine: ((String) -> Void)?
    var onExit: ((Int32, String) -> Void)?
    let arguments: [String]
    let workingDirectory: URL?
    private(set) var sent: [JSONValue] = []
    private(set) var isClosed = false
    var handlers: [String: (JSONValue) -> Reply] = [:]
    var queued: [String: [Reply]] = [:]

    init(arguments: [String] = [], workingDirectory: URL? = nil) {
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        let ack: (JSONValue) -> Reply = { params in .result(["commandId": params["commandId"] ?? nil, "status": "accepted"]) }
        handlers["initialize"] = { _ in .result(MuseFixtures.initializeResult) }
        handlers["session/start"] = { params in
            .result(["session": ["sessionId": params["sessionId"] ?? nil, "modelId": params["modelId"] ?? "muse-spark-1.3-contributor", "status": "idle"]])
        }
        handlers["session/resume"] = { params in
            .result(["session": ["sessionId": params["sessionId"] ?? nil, "modelId": "muse-spark-1.3-contributor", "status": "idle"], "history": ["items": []], "pendingRequests": []])
        }
        handlers["turn/start"] = { params in
            .result(["commandId": params["commandId"] ?? nil, "status": "accepted", "turnId": params["commandId"] ?? nil, "startedNewTurn": true, "disposition": "started"])
        }
        handlers["turn/steer"] = { params in .result(["commandId": params["commandId"] ?? nil, "status": "accepted", "turnId": params["expectedTurnId"] ?? nil]) }
        handlers["session/compact"] = { params in .result(["commandId": params["commandId"] ?? nil, "status": "accepted"]) }
        for method in ["approval/decide", "turn/interrupt", "session/setModel", "session/setApprovalMode", "userInput/answer", "userInput/cancel"] {
            handlers[method] = ack
        }
        handlers["usage/read"] = { _ in .result([:]) }
        handlers["model/list"] = { _ in .result(["providerId": "meta", "models": []]) }
    }

    func start() throws {}

    func send(_ line: String) {
        guard let message = JSONValue.parse(line) else { return }
        sent.append(message)
        guard let id = message["id"], let method = message["method"]?.string else { return }
        let reply: Reply
        if var queue = queued[method], !queue.isEmpty {
            reply = queue.removeFirst()
            queued[method] = queue
        } else {
            reply = handlers[method]?(message["params"] ?? .null) ?? .silent
        }
        let response: JSONValue
        switch reply {
        case .result(let result): response = ["jsonrpc": "2.0", "id": id, "result": result]
        case .error(let code, let kind, let text):
            response = ["jsonrpc": "2.0", "id": id, "error": ["code": .number(Double(code)), "message": .string(text), "data": ["kind": .string(kind)]]]
        case .silent: return
        }
        Task { @MainActor [weak self] in self?.onLine?(response.compactJSON) }
    }

    func close() {
        isClosed = true
    }

    /// Delivers recorded frames as they are.
    func deliver(_ lines: [String]) {
        for line in lines { onLine?(line) }
    }

    func notify(_ method: String, _ params: JSONValue) {
        onLine?(JSONValue.object(["jsonrpc": "2.0", "method": .string(method), "params": params]).compactJSON)
    }

    func crash(status: Int32, stderr: String) {
        onExit?(status, stderr)
    }

    /// The params of every request Coincide sent for `method`.
    func requests(_ method: String) -> [JSONValue] {
        sent.filter { $0["method"]?.string == method && $0["id"] != nil }.map { $0["params"] ?? .null }
    }

    var methods: [String] { sent.compactMap { $0["method"]?.string } }

    /// Coincide's answers to requests Muse sent, by id.
    func responses(to id: Int) -> [JSONValue] {
        sent.filter { $0["id"]?.int == id && $0["method"] == nil }
    }

    /// Answers a request that was left unanswered (`.silent`).
    func answer(_ method: String, with result: JSONValue) {
        guard let id = sent.last(where: { $0["method"]?.string == method })?["id"] else { return }
        onLine?(JSONValue.object(["jsonrpc": "2.0", "id": id, "result": result]).compactJSON)
    }
}

@MainActor
private final class MuseEventLog {
    var events: [AgentEvent] = []

    var completions: [TurnOutcome] {
        events.compactMap { event -> TurnOutcome? in
            guard case .turnCompleted(let outcome) = event else { return nil }
            return outcome
        }
    }

    var approvals: [ApprovalRequest] {
        events.compactMap { event -> ApprovalRequest? in
            guard case .approvalRequested(let request) = event else { return nil }
            return request
        }
    }

    var questions: [UserInputRequest] {
        events.compactMap { event -> UserInputRequest? in
            guard case .userInputRequested(let request) = event else { return nil }
            return request
        }
    }

    var notices: [String] {
        events.compactMap { event -> String? in
            guard case .notice(let text) = event else { return nil }
            return text
        }
    }

    var failure: String? {
        completions.lazy.compactMap { outcome -> String? in
            guard case .failed(let message) = outcome else { return nil }
            return message
        }.first
    }
}

private struct TimedOut: Error {}

@MainActor
private func waitUntil(_ timeout: Duration = .seconds(2), _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else { throw TimedOut() }
        try await Task.sleep(for: .milliseconds(5))
    }
}

/// Lets queued replies arrive.
@MainActor
private func settle() async {
    for _ in 0..<20 { await Task.yield() }
    try? await Task.sleep(for: .milliseconds(20))
}

@MainActor
final class MuseSessionTests {
    private let log = MuseEventLog()
    private var transports: [FakeMuseTransport] = []
    private var prepared: [FakeMuseTransport] = []
    /// The session's access mode, which turns use unless a test changes it.
    private var access: AccessMode = .fullAccess
    private let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-muse-\(UUID().uuidString)")

    private static let model = "muse-spark-1.3-contributor"
    private static let timing = MuseSession.Timing(
        initialize: .seconds(2), request: .seconds(2), turnStart: .seconds(2), interruptGrace: .milliseconds(200),
        steerWait: .seconds(1))

    init() throws {
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: scratch)
    }

    private var transport: FakeMuseTransport { transports.last! }

    /// A session whose minted ids follow `ids`, then `id-1`, `id-2`, …
    private func makeSession(
        ids: [String] = [], resume: String? = nil, access: AccessMode = .fullAccess, mode: InteractionMode = .build,
        workingDirectory: URL? = nil
    ) -> MuseSession {
        self.access = access
        var remaining = ids
        var counter = 0
        let minted = MuseIDs {
            if !remaining.isEmpty { return remaining.removeFirst() }
            counter += 1
            return "id-\(counter)"
        }
        let launch = AgentLaunch(
            provider: .muse, executable: URL(fileURLWithPath: "/opt/muse/bin/muse"), environment: ["PATH": "/bin"],
            workingDirectory: workingDirectory ?? scratch, resumeSessionID: resume,
            selection: ModelSelection(provider: .muse, modelID: Self.model, effort: "high"), accessMode: access,
            interactionMode: mode)
        let session = MuseSession(launch: launch, ids: minted, timing: Self.timing) { [unowned self] arguments, directory in
            let transport = self.prepared.isEmpty
                ? FakeMuseTransport(arguments: arguments, workingDirectory: directory)
                : self.prepared.removeFirst()
            self.transports.append(transport)
            return transport
        }
        let log = log
        session.onEvent = { log.events.append($0) }
        return session
    }

    private func input(
        _ text: String = "Respond with the following text: fixture simple ok", model: String = MuseSessionTests.model,
        effort: String? = "high", access: AccessMode? = nil, mode: InteractionMode = .build, images: [String] = []
    ) -> AgentTurnInput {
        AgentTurnInput(
            text: text, imagePaths: images, selection: ModelSelection(provider: .muse, modelID: model, effort: effort),
            accessMode: access ?? self.access, interactionMode: mode)
    }

    /// Starts a session and a turn, returning the turn id Coincide minted.
    private func startTurn(_ session: MuseSession, _ input: AgentTurnInput? = nil) async throws -> String {
        try await session.start()
        try await session.send(input ?? self.input())
        return try #require(transport.requests("turn/start").last?["commandId"]?.string)
    }

    private func item(_ id: String, kind: String, turn: String, revision: Int = 1, status: String = "inProgress", _ fields: [String: JSONValue] = [:]) -> JSONValue {
        var item: [String: JSONValue] = [
            "itemId": .string(id), "kind": .string(kind), "turnId": .string(turn), "revision": .number(Double(revision)),
            "status": .string(status),
        ]
        for (key, value) in fields { item[key] = value }
        return .object(item)
    }

    private func approval(_ turn: String?, sourceIndex: Int = 0, subagent: Bool = false, session: String = "id-1") -> JSONValue {
        var params: [String: JSONValue] = [
            "sessionId": .string(session), "approvalId": "approval-1",
            "currentRequirementId": ["approvalId": "approval-1", "sourceIndex": .number(Double(sourceIndex))],
            "availableChoices": [
                ["choiceId": "once", "label": "Allow once", "decision": "approved", "scope": "once"],
                ["choiceId": "deny", "label": "Deny", "decision": "denied", "scope": "once"],
            ],
            "subject": ["kind": "shell", "command": "touch result.txt"],
        ]
        if let turn { params["turnId"] = .string(turn) }
        if subagent { params["subagentOrigin"] = ["subagentId": "child-1"] }
        return .object(params)
    }

    // MARK: Starting and resuming

    @Test func startLaunchesTheHostAndStartsASessionAsT3Does() async throws {
        let session = makeSession(ids: MuseFixtures.simpleIDs)
        try await session.start()
        #expect(transport.arguments == ["serve", "--trust-workspace", "--disable-sandbox"])
        #expect(transport.workingDirectory?.path == MuseProtocol.canonicalPath(scratch.path))
        #expect(Array(transport.methods.prefix(3)) == ["initialize", "initialized", "session/start"])
        let start = try #require(transport.requests("session/start").first)
        #expect(start == [
            "sessionId": .string(MuseFixtures.simpleSessionID), "workspaceRoot": .string(MuseProtocol.canonicalPath(scratch.path)),
            "modelId": .string(Self.model), "providerId": "meta", "approvalMode": "allowAll", "permissionProfile": ":unrestricted",
            "commandId": .string(MuseFixtures.simpleIDs[1]),
        ])
        #expect(session.sessionID == MuseFixtures.simpleSessionID)
        #expect(Array(log.events.prefix(2)) == [.sessionStarted(id: MuseFixtures.simpleSessionID), .modelResolved(Self.model)])
    }

    @Test func approvalModeAsksBeforeUnmatchedActions() async throws {
        let session = makeSession(access: .approval)
        try await session.start()
        #expect(transport.arguments == ["serve", "--trust-workspace"])
        let start = try #require(transport.requests("session/start").first)
        #expect(start["approvalMode"] == "promptUnmatched")
        #expect(start["permissionProfile"] == ":ask-me")
    }

    @Test func aSavedSessionIsResumedWithTheHostsApprovalMode() async throws {
        let session = makeSession(resume: "saved-session", access: .approval)
        try await session.start()
        #expect(transport.requests("session/start").isEmpty)
        let resume = try #require(transport.requests("session/resume").first)
        #expect(resume["sessionId"] == "saved-session")
        #expect(resume["excludeItems"] == true)
        #expect(resume["permissionProfile"] == ":ask-me")
        #expect(transport.requests("session/setApprovalMode").first?["mode"] == "promptUnmatched")
        #expect(session.sessionID == "saved-session")
        #expect(log.events.first == .sessionStarted(id: "saved-session"))
        #expect(log.notices.isEmpty)
    }

    @Test func aSessionMuseNoLongerHasIsReplacedAndTheTurnGetsTheWholeRecap() async throws {
        let first = FakeMuseTransport(arguments: ["serve", "--trust-workspace", "--disable-sandbox"])
        prepared = [first]
        let session = makeSession(resume: "gone")
        try await session.start()
        // Muse dropped the session between turns; the next turn's resume fails and a new session takes its place.
        first.notify("session/closed", ["sessionId": "gone", "reason": "evicted"])
        let second = FakeMuseTransport(arguments: ["serve", "--trust-workspace", "--disable-sandbox"])
        second.queued["session/resume"] = [.error(code: -32040, kind: "sessionNotFound", message: "session gone not found")]
        prepared = [second]
        try await session.send(AgentTurnInput(
            message: "Continue", handoffRecap: nil, newSessionRecap: "RECAP",
            selection: ModelSelection(provider: .muse, modelID: Self.model), accessMode: .fullAccess, interactionMode: .build))
        #expect(first.isClosed)
        // id-1 and id-2 were the resume and approval-mode commands, id-3 is the turn, id-4 the resume Muse refused.
        #expect(session.sessionID == "id-5")
        #expect(log.events.contains(.sessionStarted(id: "id-5")))
        #expect(log.notices == ["The previous Muse Code session could not be resumed, so a new one was started. (session gone not found)"])
        let text = try #require(second.requests("turn/start").first?.at("input")?[0]?["text"]?.string)
        #expect(text.hasPrefix("RECAP"))
        #expect(text.hasSuffix("Continue"))
    }

    @Test func aHostSpeakingAnotherProtocolIsRefused() async throws {
        let unsupported = FakeMuseTransport()
        unsupported.handlers["initialize"] = { _ in .result(["schema": ["fingerprint": "x", "version": 2]]) }
        prepared = [unsupported]
        let session = makeSession()
        await #expect(throws: AgentError.self) { try await session.start() }
        #expect(unsupported.isClosed)
        #expect(unsupported.requests("session/start").isEmpty)
    }

    // MARK: Turns

    @Test func recordedTurnStreamsAndCompletesOnce() async throws {
        let session = makeSession(ids: MuseFixtures.simpleIDs)
        let turnID = try await startTurn(session)
        #expect(turnID == MuseFixtures.simpleIDs[2])
        let start = try #require(transport.requests("turn/start").first)
        #expect(start["input"] == [["type": "text", "text": "Respond with the following text: fixture simple ok"]])
        #expect(start["displayText"] == "Respond with the following text: fixture simple ok")
        #expect(start["workspaceRoots"] == [.string(MuseProtocol.canonicalPath(scratch.path))])
        #expect(start["ifBusy"] == "queue")
        #expect(start["reasoningEffort"] == "high")
        log.events.removeAll()
        transport.deliver(MuseFixtures.simple)
        transport.deliver(MuseFixtures.simple.suffix(1))
        #expect(log.events.filter { if case .usage = $0 { false } else { true } } == [
            .assistantTextDelta(itemID: "0a68e576-f554-4700-8853-a68ad2b7179b", delta: "fixture simple ok"),
            .assistantText(itemID: "0a68e576-f554-4700-8853-a68ad2b7179b", text: "fixture simple ok"),
            .turnCompleted(.completed),
        ])
        #expect(log.events.contains(.usage(TokenUsage(inputTokens: 32374, contextWindow: 1_007_997))))
        #expect(log.events.contains(.usage(TokenUsage(outputTokens: 24, cachedInputTokens: 0, costUSD: 0.0032398))))
    }

    @Test func aChangedModelIsSetBeforeTheTurnAndAnUnchangedOneIsNot() async throws {
        let session = makeSession()
        _ = try await startTurn(session)
        #expect(transport.requests("session/setModel").isEmpty)
        transport.notify("turn/completed", ["sessionId": "id-1", "turnId": "id-3", "terminal": "completed"])
        try await session.send(input(model: "muse-wonder-1.0", effort: "turbo"))
        let setModel = try #require(transport.requests("session/setModel").first)
        #expect(setModel["model"] == ["modelId": "muse-wonder-1.0", "providerId": "meta"])
        #expect(transport.methods.lastIndex(of: "session/setModel")! < transport.methods.lastIndex(of: "turn/start")!)
        // An effort Muse does not know is left to the session's default.
        #expect(transport.requests("turn/start").last?["reasoningEffort"] == nil)
        #expect(log.events.contains(.modelResolved("muse-wonder-1.0")))
    }

    @Test func changingAccessStartsANewHostThatResumesTheSession() async throws {
        let session = makeSession()
        _ = try await startTurn(session)
        let first = transport
        transport.notify("turn/completed", ["sessionId": "id-1", "turnId": "id-3", "terminal": "completed"])
        try await session.send(input("Ask first", access: .approval))
        #expect(first.isClosed)
        #expect(transports.count == 2)
        #expect(transport.arguments == ["serve", "--trust-workspace"])
        #expect(transport.requests("session/resume").first?["sessionId"] == "id-1")
        #expect(transport.requests("session/resume").first?["permissionProfile"] == ":ask-me")
        #expect(transport.requests("session/setApprovalMode").first?["mode"] == "promptUnmatched")
        #expect(transport.requests("turn/start").first?.at("input")?[0]?["text"] == "Ask first")
        // id-5 and id-6 resumed the session on the new host; this turn is id-4.
        transport.notify("turn/completed", ["sessionId": "id-1", "turnId": "id-4", "terminal": "completed"])
        try await session.send(input("And again", access: .approval))
        #expect(transports.count == 2)
    }

    @Test func textGenerationRunsMuseReadOnlyWithThePromptAsIs() async throws {
        // Muse threads never run in Plan mode (it has none); commit messages and pull request text ask for it.
        #expect(!ProviderKind.muse.supportsPlanMode)
        #expect(ProviderKind.muse.interactionMode(for: .plan) == .build)
        #expect(ProviderKind.muse.supportsTextGeneration)
        #expect(ProviderKind.muse.accessModes == [.fullAccess, .approval])
        let session = makeSession(access: .approval, mode: .plan)
        try await session.start()
        #expect(transport.arguments == ["serve", "--trust-workspace", "--disable-shell", "--disable-write"])
        try await session.send(input("Write a commit message as JSON.", mode: .plan))
        #expect(transports.count == 1)
        #expect(transport.requests("turn/start").first?["input"] == [["type": "text", "text": "Write a commit message as JSON."]])
    }

    @Test func imagesTravelInlineWithANoteOfTheirPath() async throws {
        let image = scratch.appendingPathComponent("shot.png")
        try Data([0x89, 0x50, 0x4e, 0x47]).write(to: image)
        let session = makeSession()
        _ = try await startTurn(session, input("Look", images: [image.path, "/missing.png"]))
        let parts = try #require(transport.requests("turn/start").first?["input"]?.array)
        #expect(parts.count == 2)
        #expect(parts[0]["text"]?.string?.contains("is saved at: \(image.path)") == true)
        #expect(parts[1] == ["type": "image", "base64Data": "iVBORw==", "mediaType": "image/png"])
    }

    @Test func failedTurnsShowMusesReasonWithAHintForInaccessibleModels() async throws {
        let session = makeSession()
        let turnID = try await startTurn(session)
        transport.notify(
            "turn/completed",
            ["sessionId": "id-1", "turnId": .string(turnID), "terminal": "failed", "error": ["message": "Model muse-x does not exist or you lack access to it."]])
        let failure = try #require(log.failure)
        #expect(failure.hasPrefix("Model muse-x does not exist or you lack access to it.\n\nPick another model"))
    }

    @Test func aRefusedTurnStartFailsTheSendWithTheSameHint() async throws {
        let refusing = FakeMuseTransport()
        refusing.queued["turn/start"] = [.error(code: -32602, kind: "invalidParams", message: "Model muse-x does not exist or you lack access.")]
        prepared = [refusing]
        let session = makeSession()
        try await session.start()
        await #expect(throws: AgentError.self) { try await session.send(self.input()) }
        // The same session takes the next turn.
        try await session.send(input())
        #expect(refusing.requests("turn/start").count == 2)
    }

    @Test func anOverloadedHostIsAskedAgainWithTheSameCommandID() async throws {
        let busy = FakeMuseTransport()
        busy.queued["turn/start"] = [.error(code: -32001, kind: "overloaded", message: "busy")]
        prepared = [busy]
        let session = makeSession()
        _ = try await startTurn(session)
        let attempts = busy.requests("turn/start")
        #expect(attempts.count == 2)
        #expect(attempts[0]["commandId"] == attempts[1]["commandId"])
    }

    /// A reset an hour from now, in milliseconds, as Muse reports it.
    private static func resetSoon() -> (date: Date, milliseconds: JSONValue) {
        let seconds = (Date().timeIntervalSince1970 + 3600).rounded(.down)
        return (Date(timeIntervalSince1970: seconds), .number(seconds * 1000))
    }

    @Test func aQuotaStopSaysWhenTheExhaustedWindowResets() async throws {
        let session = makeSession()
        let turnID = try await startTurn(session)
        let reset = Self.resetSoon()
        transport.notify(
            "usage/changed",
            ["observedAtMs": 1, "tier": "tier-1", "window": ["usedPercent": 103, "windowDurationMins": 300, "resetsAtMs": reset.milliseconds], "weekly": ["usedPercent": 5, "resetsAtMs": reset.milliseconds]])
        let quota = "API error 429: Subscription quota exhausted. Your usage window resets soon. (rate_limit_error)"
        transport.notify(
            "turn/completed",
            ["sessionId": "id-1", "turnId": .string(turnID), "terminal": "failed", "reason": .string(quota), "error": ["kind": "modelError", "message": .string(quota)]])
        let failure = try #require(log.failure)
        #expect(failure == "Muse Code usage limit reached. It resets \(reset.date.formatted(date: .abbreviated, time: .shortened)).\n\n\(quota)")
    }

    @Test func aStopMuseTypesAsQuotaSaysWhenItsQuotaResets() async throws {
        let session = makeSession()
        let turnID = try await startTurn(session)
        let reset = Self.resetSoon()
        transport.notify(
            "turn/completed",
            ["sessionId": "id-1", "turnId": .string(turnID), "terminal": "failed", "error": ["message": "Model request refused.", "quota": ["limitKind": "tierLimit", "resetsAtMs": reset.milliseconds]]])
        let failure = try #require(log.failure)
        #expect(failure.hasPrefix("Muse Code usage limit reached. It resets \(reset.date.formatted(date: .abbreviated, time: .shortened))."))
    }

    @Test func aPlainRateLimitIsAnOrdinaryFailureAndUnreadableUsageIsSkipped() async throws {
        let session = makeSession()
        let turnID = try await startTurn(session)
        transport.notify("usage/changed", ["window": "not usage"])
        transport.notify(
            "turn/completed",
            ["sessionId": "id-1", "turnId": .string(turnID), "terminal": "failed", "error": ["message": "API error 429: Rate limit exceeded. (rate_limit_error)"]])
        #expect(log.failure == "API error 429: Rate limit exceeded. (rate_limit_error)")
        #expect(!log.events.contains { if case .rateLimits = $0 { true } else { false } })
        #expect(!transport.isClosed)
    }

    @Test func usageReportsBecomeTheComposersLimits() async throws {
        let session = makeSession()
        try await session.start()
        transport.notify(
            "usage/changed",
            ["observedAtMs": 1, "tier": "tier-1", "window": ["usedPercent": 40, "windowDurationMins": 300, "resetsAtMs": 1_791_465_557_000], "weekly": ["usedPercent": 5, "resetsAtMs": 1_791_763_200_000]])
        let windows = log.events.compactMap { event -> [UsageLimitWindow]? in
            guard case .rateLimits(let windows) = event else { return nil }
            return windows
        }
        #expect(windows.last?.map(\.usedPercent) == [40, 5])
    }

    @Test func todoListsBecomeTheTurnsPlan() async throws {
        let session = makeSession()
        _ = try await startTurn(session)
        transport.notify(
            "session/todoListChanged",
            ["sessionId": "id-1", "items": [["text": "Investigate", "status": "completed"], ["text": "Fix", "status": "inProgress"]]])
        #expect(log.events.last == .plan(text: "- [x] Investigate\n- [ ] Fix _(in progress)_"))
    }

    @Test func retriesAreNoticed() async throws {
        let session = makeSession()
        let turnID = try await startTurn(session)
        transport.notify(
            "turn/retryScheduled",
            ["sessionId": "id-1", "turnId": .string(turnID), "nextAttempt": 2, "maxAttempts": 5, "reason": "overloaded", "retryDelayMs": 100])
        #expect(log.notices == ["Muse Code is retrying this turn (attempt 2 of 5): overloaded"])
    }

    @Test func aDeliveryGapFailsTheTurnAndTheNextTurnResumesOnANewHost() async throws {
        let session = makeSession()
        _ = try await startTurn(session)
        let first = transport
        transport.notify("view/gap", ["sessionId": "id-1"])
        #expect(log.failure?.contains("lost part of this turn") == true)
        #expect(first.isClosed)
        try await session.send(input())
        #expect(transports.count == 2)
        #expect(transport.requests("session/resume").first?["sessionId"] == "id-1")
    }

    @Test func aHostThatExitsFailsTheTurnWithItsLastWords() async throws {
        let session = makeSession()
        _ = try await startTurn(session)
        transport.crash(status: 1, stderr: "\u{1B}[31mfatal: out of memory\u{1B}[0m\n")
        #expect(log.failure == "Muse Code exited unexpectedly (status 1).\nfatal: out of memory")
        #expect(log.events.last == .sessionExited(error: "Muse Code exited unexpectedly (status 1).\nfatal: out of memory"))
        await #expect(throws: AgentError.self) { try await session.send(self.input()) }
    }

    // MARK: Stopping and steering

    @Test func recordedStopEndsTheTurnAsInterrupted() async throws {
        let session = makeSession(ids: MuseFixtures.interruptIDs)
        let turnID = try await startTurn(session)
        session.interrupt()
        try await waitUntil { !self.transport.requests("turn/interrupt").isEmpty }
        let stop = try #require(transport.requests("turn/interrupt").first)
        #expect(stop["turnId"] == .string(turnID))
        #expect(stop["commandId"] == .string(MuseFixtures.interruptIDs[3]))
        transport.deliver(MuseFixtures.interrupt)
        #expect(log.completions == [.interrupted])
    }

    @Test func stopAlsoEndsATurnMuseRanInsideThisOne() async throws {
        let session = makeSession()
        let turnID = try await startTurn(session)
        transport.notify("turn/started", ["sessionId": "id-1", "turnId": "report-1"])
        transport.notify("item/started", ["sessionId": "id-1", "item": item("m", kind: "agentMessage", turn: "report-1", ["text": "Report"])])
        #expect(log.events.contains(.assistantText(itemID: "m", text: "Report")))
        session.interrupt()
        try await waitUntil { self.transport.requests("turn/interrupt").count == 2 }
        #expect(transport.requests("turn/interrupt").map { $0["turnId"] } == ["report-1", .string(turnID)])
        // The joined turn ending does not end this one.
        transport.notify("turn/completed", ["sessionId": "id-1", "turnId": "report-1", "terminal": "cancelled"])
        #expect(log.completions.isEmpty)
        transport.notify("turn/completed", ["sessionId": "id-1", "turnId": .string(turnID), "terminal": "cancelled"])
        #expect(log.completions == [.interrupted])
    }

    @Test func aStopMuseDoesNotConfirmEndsTheHost() async throws {
        let session = makeSession()
        _ = try await startTurn(session)
        session.interrupt()
        try await waitUntil { self.log.completions == [.interrupted] }
        #expect(log.events.last == .sessionExited(error: nil))
        #expect(transport.isClosed)
    }

    @Test func aStopBeforeMuseAdmittedTheTurnIsSentOnceItDoes() async throws {
        let slow = FakeMuseTransport()
        slow.handlers["turn/start"] = { _ in .silent }
        prepared = [slow]
        let session = makeSession()
        try await session.start()
        let sending = Task { try await session.send(self.input()) }
        try await waitUntil { !slow.requests("turn/start").isEmpty }
        session.interrupt()
        #expect(slow.requests("turn/interrupt").isEmpty)
        let turnID = try #require(slow.requests("turn/start").first?["commandId"])
        slow.answer("turn/start", with: ["commandId": turnID, "status": "accepted", "turnId": turnID])
        try await sending.value
        try await waitUntil { !slow.requests("turn/interrupt").isEmpty }
        #expect(slow.requests("turn/interrupt").first?["turnId"] == turnID)
    }

    @Test func steeringNamesTheRunningTurn() async throws {
        let session = makeSession()
        let turnID = try await startTurn(session)
        #expect(session.supportsSteering)
        try await session.steer(input("Focus on the parser", effort: "max"))
        let steer = try #require(transport.requests("turn/steer").first)
        #expect(steer["expectedTurnId"] == .string(turnID))
        #expect(steer["input"] == [["type": "text", "text": "Focus on the parser"]])
        #expect(steer["reasoningEffort"] == "max")
        transport.notify("turn/completed", ["sessionId": "id-1", "turnId": .string(turnID), "terminal": "completed"])
        await #expect(throws: AgentError.self) { try await session.steer(self.input("Too late")) }
    }

    // MARK: Approvals and questions

    @Test func recordedApprovalIsAskedOnceAndAnsweredWithMusesChoice() async throws {
        let session = makeSession(ids: MuseFixtures.permissionIDs, access: .approval)
        _ = try await startTurn(session)
        let split = try #require(MuseFixtures.permission.firstIndex { $0.contains(#""method":"approval/updated""#) })
        transport.deliver(Array(MuseFixtures.permission[..<split]))
        // Muse asks as a request (answered empty) and as a notification; the prompt shows once.
        #expect(transport.responses(to: 1) == [["jsonrpc": "2.0", "id": 1, "result": [:]]])
        let request = try #require(log.approvals.first)
        #expect(log.approvals.count == 1)
        #expect(request.id == "01a11a6d-4730-75f1-bc60-4e5df1a3cdc0")
        #expect(request.title == "Run `touch muse-approved.txt`")
        #expect(request.options.map(\.id) == ["allow_once", "allow_local_prefix", "abort"])
        session.respond(to: request.id, optionID: "allow_once")
        try await waitUntil { !self.transport.requests("approval/decide").isEmpty }
        let decide = try #require(transport.requests("approval/decide").first)
        #expect(decide == [
            "sessionId": .string(MuseFixtures.permissionSessionID), "approvalId": "01a11a6d-4730-75f1-bc60-4e5df1a3cdc0",
            "requirementId": ["approvalId": "01a11a6d-4730-75f1-bc60-4e5df1a3cdc0", "sourceIndex": 0], "choiceId": "allow_once",
            "commandId": .string(MuseFixtures.permissionIDs[3]),
        ])
        transport.deliver(Array(MuseFixtures.permission[split...]))
        // Muse's update and resolution of what the user answered add no prompt and close nothing.
        #expect(log.approvals.count == 1)
        #expect(!log.events.contains { if case .approvalResolved = $0 { true } else { false } })
        #expect(log.events.contains(.toolStarted(ToolCallInfo(
            id: "01a11a6d-4730-75f1-bc60-4e5df1a3cdc0", category: .command, title: "Run `touch muse-approved.txt`",
            detail: "touch muse-approved.txt"))))
        #expect(log.events.contains(.assistantText(itemID: "ae8db1e0-7a51-4efc-a025-8ae43f755700", text: "DONE")))
        #expect(log.completions == [.completed])
    }

    @Test func theLatestRequirementIsAnsweredAndALaterStageGetsItsOwnPrompt() async throws {
        let session = makeSession(access: .approval)
        let turnID = try await startTurn(session)
        transport.notify("approval/requested", approval(turnID))
        transport.notify("approval/updated", approval(turnID, sourceIndex: 1))
        // An unanswered prompt takes the newer requirement in place.
        #expect(log.approvals.map(\.id) == ["approval-1", "approval-1"])
        session.respond(to: "approval-1", optionID: "once")
        try await waitUntil { !self.transport.requests("approval/decide").isEmpty }
        #expect(transport.requests("approval/decide").first?["requirementId"] == ["approvalId": "approval-1", "sourceIndex": 1])
        #expect(transport.requests("approval/decide").first?["choiceId"] == "once")
        // The next stage of the chained command asks again.
        transport.notify("approval/updated", approval(turnID, sourceIndex: 2))
        #expect(log.approvals.last?.id == "approval-1#1")
        session.respond(to: "approval-1#1", optionID: "deny")
        try await waitUntil { self.transport.requests("approval/decide").count == 2 }
        #expect(transport.requests("approval/decide").last?["requirementId"] == ["approvalId": "approval-1", "sourceIndex": 2])
        transport.notify("approval/resolved", ["sessionId": "id-1", "approvalId": "approval-1", "decision": "denied"])
        #expect(!log.events.contains { if case .approvalResolved = $0 { true } else { false } })
    }

    @Test func anApprovalMuseSettlesItselfIsClosed() async throws {
        let session = makeSession(access: .approval)
        let turnID = try await startTurn(session)
        transport.notify("approval/requested", approval(turnID))
        transport.notify("approval/resolved", ["sessionId": "id-1", "approvalId": "approval-1", "decision": "approved"])
        #expect(log.events.last == .approvalResolved(id: "approval-1"))
        // A late repeat does not bring it back.
        transport.notify("approval/requested", approval(turnID))
        #expect(log.approvals.count == 1)
    }

    @Test func approvalsOfOtherTurnsOrSessionsAreIgnored() async throws {
        let session = makeSession(access: .approval)
        _ = try await startTurn(session)
        transport.notify("approval/requested", approval("other-turn"))
        transport.notify("approval/requested", approval(nil, session: "other-session"))
        #expect(log.approvals.isEmpty)
    }

    @Test func aRefusedDecisionAsksAgain() async throws {
        let refusing = FakeMuseTransport()
        refusing.queued["approval/decide"] = [.error(code: -32050, kind: "approvalStale", message: "stale")]
        prepared = [refusing]
        let session = makeSession(access: .approval)
        let turnID = try await startTurn(session)
        refusing.notify("approval/requested", approval(turnID))
        session.respond(to: "approval-1", optionID: "once")
        try await waitUntil { self.log.approvals.count == 2 }
        #expect(log.notices == ["Muse Code did not take that answer: stale"])
    }

    @Test func aWorkflowChildsApprovalIsAnsweredForItInFullAccess() async throws {
        let session = makeSession(access: .fullAccess)
        _ = try await startTurn(session)
        transport.notify("approval/requested", approval("child-run", subagent: true))
        try await waitUntil { !self.transport.requests("approval/decide").isEmpty }
        #expect(transport.requests("approval/decide").first?["choiceId"] == "once")
        #expect(log.approvals.isEmpty)
    }

    @Test func aWorkflowChildsApprovalOutlivesTheTurn() async throws {
        let session = makeSession(access: .approval)
        let turnID = try await startTurn(session)
        transport.notify("approval/requested", approval("child-run", subagent: true))
        let shown = try #require(log.approvals.first)
        #expect(log.approvals.map(\.title) == ["Subagent: Run `touch result.txt`"])
        transport.notify("turn/completed", ["sessionId": "id-1", "turnId": .string(turnID), "terminal": "completed"])
        // The turn's open prompts close with it, so the child's is asked again, between turns.
        #expect(log.events.suffix(2) == [.turnCompleted(.completed), .approvalRequested(shown)])
        session.respond(to: "approval-1", optionID: "once")
        try await waitUntil { !self.transport.requests("approval/decide").isEmpty }
    }

    @Test func questionsAreAnsweredWithLabelsAndANote() async throws {
        let session = makeSession(access: .approval)
        let turnID = try await startTurn(session)
        let params: JSONValue = [
            "sessionId": "id-1", "userInputId": "question-1", "turnId": .string(turnID),
            "questions": [["id": "approach", "header": "Approach", "question": "Which approach?", "options": [["label": "Small"], ["label": "Large"]], "selection": ["mode": "single"]]],
        ]
        transport.notify("userInput/requested", params)
        #expect(log.questions.map(\.id) == ["question-1"])
        session.answer(userInput: "question-1", answers: ["approach": ["Small", "Keep tests focused"]])
        try await waitUntil { !self.transport.requests("userInput/answer").isEmpty }
        #expect(transport.requests("userInput/answer").first?["answers"] == [["questionId": "approach", "selectedLabel": "Small", "note": "Keep tests focused"]])
        transport.notify("userInput/settled", ["sessionId": "id-1", "userInputId": "question-1"])
        #expect(!log.events.contains(.userInputResolved(id: "question-1")))
    }

    @Test func dismissedQuestionsAreCancelledAndOnesMuseSettlesAreClosed() async throws {
        let session = makeSession(access: .approval)
        let turnID = try await startTurn(session)
        func ask(_ id: String) {
            transport.notify(
                "userInput/requested",
                ["sessionId": "id-1", "userInputId": .string(id), "turnId": .string(turnID), "questions": [["id": "q", "header": "", "question": "?", "options": [], "selection": ["mode": "single"]]]])
        }
        ask("dismissed")
        session.answer(userInput: "dismissed", answers: [:])
        try await waitUntil { !self.transport.requests("userInput/cancel").isEmpty }
        #expect(transport.requests("userInput/cancel").first?["userInputId"] == "dismissed")
        ask("settled")
        transport.notify("userInput/settled", ["sessionId": "id-1", "userInputId": "settled"])
        #expect(log.events.last == .userInputResolved(id: "settled"))
    }

    // MARK: Background work, subagents and compaction

    @Test func recordedWorkflowRunsOnAfterItsTurnAndMuseReportsOnItsOwn() async throws {
        let session = makeSession(ids: MuseFixtures.workflowIDs)
        _ = try await startTurn(session)
        let end = try #require(MuseFixtures.workflow.firstIndex { $0.contains(#""method":"turn/completed""#) })
        transport.deliver(Array(MuseFixtures.workflow[...end]))
        #expect(log.completions == [.completed])
        #expect(session.hasBackgroundWork)
        let workflow = "e1f5bbdc-9a2d-52c5-8501-9b6ef280aa94"
        #expect(log.events.contains(.toolStarted(ToolCallInfo(id: workflow, category: .task, title: "Workflow: ping-pong"))))
        log.events.removeAll()
        let report = try #require(MuseFixtures.workflow.lastIndex { $0.contains(#""method":"turn/started""#) })
        transport.deliver(Array(MuseFixtures.workflow[(end + 1)..<report]))
        #expect(!session.hasBackgroundWork)
        // The workflow script's result is its final summary.
        #expect(log.events.last == .toolCompleted(id: workflow, status: .completed, output: #"{"status":"ok"}"#))
        #expect(log.events.contains(.toolUpdated(ToolCallInfo(id: workflow, category: .task, title: "Workflow: ping-pong", detail: "✓ ping\n✓ pong"))))
        log.events.removeAll()
        transport.deliver(Array(MuseFixtures.workflow[report...]))
        #expect(log.events.first == .agentTurnStarted(note: "Muse Code continued after background work finished."))
        #expect(log.events.contains(.assistantText(itemID: "1dce55ee-a7f9-4472-afea-21fee9d1ce79", text: "The workflow with `ping` and `pong` agents is complete.")))
        #expect(log.completions == [.completed])
    }

    @Test func backgroundWorkEndsWithItsHost() async throws {
        let session = makeSession()
        let turnID = try await startTurn(session)
        transport.notify("item/started", ["sessionId": "id-1", "item": item("a", kind: "subagent", turn: turnID, ["objective": "Look around"])])
        transport.notify("turn/completed", ["sessionId": "id-1", "turnId": .string(turnID), "terminal": "completed"])
        #expect(session.hasBackgroundWork)
        transport.crash(status: 9, stderr: "")
        #expect(!session.hasBackgroundWork)
    }

    @Test func recordedSubagentShowsItsResultButNotItsOwnSessionsItems() async throws {
        let session = makeSession(ids: MuseFixtures.subagentIDs)
        _ = try await startTurn(session)
        transport.deliver(MuseFixtures.subagent)
        let subagent = "01a12d17-81f1-7990-b8c5-4aec1f46ac18"
        #expect(log.events.contains(.toolStarted(ToolCallInfo(
            id: subagent, category: .task, title: "Subagent: Reply with exactly: Hello", detail: "Reply with exactly: Hello"))))
        #expect(log.events.contains(.toolCompleted(id: subagent, status: .completed, output: "Hello")))
        // The child's reply streams in its own session (its turn is the child session) and is not the parent's.
        #expect(!log.events.contains { event in
            if case .assistantText(let id, _) = event { id == "3e525e25-801f-492a-b669-2b34a3535bbb" } else { false }
        })
        #expect(log.events.contains(.assistantText(itemID: "e1b204f3-79cd-4c84-9d0e-21a0e399b4cb", text: "Hello")))
        #expect(log.events.contains(.toolStarted(ToolCallInfo(id: "01a12d17-81c8-7072-8b72-2992c403773f", category: .task, title: "Start a subagent", detail: JSONValue.parse(#"{"command_id":"hello-spawn-001","objective":"Reply with exactly: Hello","role":"hello agent"}"#)?.prettyJSON))))
        #expect(log.completions == [.completed])
    }

    @Test func compactUsesMusesCompactionAndEndsWithIt() async throws {
        let session = makeSession()
        try await session.start()
        try await session.send(input("/compact"))
        let compact = try #require(transport.requests("session/compact").first)
        let turnID = try #require(compact["commandId"]?.string)
        #expect(transport.requests("turn/start").isEmpty)
        transport.notify("item/started", ["sessionId": "id-1", "item": item("c", kind: "compaction", turn: "earlier-run")])
        #expect(log.events.last == .toolStarted(ToolCallInfo(id: "c", category: .other, title: "Compact the conversation")))
        transport.notify("item/completed", ["sessionId": "id-1", "item": item("c", kind: "compaction", turn: "earlier-run", revision: 2, status: "completed", ["outcome": "compacted"])])
        #expect(log.completions == [.completed])
        #expect(turnID == "id-3")
    }

    @Test func aCompactionWithNothingToCompactFails() async throws {
        let empty = FakeMuseTransport()
        empty.handlers["session/compact"] = { params in .result(["commandId": params["commandId"] ?? nil, "status": "noop", "reason": "no_compactable_history"]) }
        prepared = [empty]
        let session = makeSession()
        try await session.start()
        try await session.send(input("/compact"))
        #expect(log.failure == "Muse Code has no conversation to compact yet.")
        try await session.send(input())
        #expect(empty.requests("turn/start").count == 1)
    }

    @Test func stoppingACompactionEndsItsHost() async throws {
        let session = makeSession()
        try await session.start()
        try await session.send(input("/compact"))
        let first = transport
        session.interrupt()
        #expect(log.completions == [.interrupted])
        #expect(first.isClosed)
        try await session.send(input())
        #expect(transports.count == 2)
        #expect(transport.requests("session/resume").first?["sessionId"] == "id-1")
    }
}
