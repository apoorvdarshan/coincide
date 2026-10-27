import Foundation

/// One Coincide thread driven through `codex app-server`, the JSON-RPC protocol T3 Code uses.
///
/// The Codex thread id is the session id. Model, effort, permissions and Plan mode travel with every
/// `turn/start`, so changes between turns need no restart.
@MainActor
final class CodexSession: AgentSession {
    let provider: ProviderKind = .codex
    private(set) var sessionID: String?
    var onEvent: ((AgentEvent) -> Void)?

    private let launch: AgentLaunch
    private let makeTransport: (AgentLaunch) -> CodexTransport
    private let interruptGracePeriod: Duration
    private var connection: CodexConnection?
    private var mapper: CodexEventMapper
    /// The model the thread reported, sent when the selection names none.
    private var threadModel: String?
    private var threadLoaded = false
    private var isShutDown = false
    private var turn: Turn?
    private var interruptWatchdog: Task<Void, Never>?
    private var approvals: [String: PendingApproval] = [:]
    /// Answers collected so far for `request_user_input` requests, by JSON-RPC id.
    private var questionSets: [JSONValue: QuestionSet] = [:]
    private let approvalPrefix = String(UUID().uuidString.prefix(8))
    private var approvalSerial = 0

    private struct Turn {
        let token = UUID()
        var id: String?
        /// `turn/started` arrived; Codex only accepts `turn/interrupt` after it.
        var started = false
        var interruptRequested = false
        var interruptSent = false
        var failure: String?
    }

    private struct PendingApproval {
        let rpcID: JSONValue
        let approval: CodexApproval
    }

    private struct QuestionSet {
        var unanswered: Set<String>
        var answers: [String: JSONValue]
    }

    convenience init(launch: AgentLaunch) {
        self.init(launch: launch, interruptGracePeriod: .seconds(5)) { launch in
            CodexProcessTransport(
                executable: launch.executable, workingDirectory: launch.workingDirectory, environment: launch.environment)
        }
    }

    /// `interruptGracePeriod` is how long Codex gets to confirm a stop before the process is replaced.
    init(launch: AgentLaunch, interruptGracePeriod: Duration, makeTransport: @escaping (AgentLaunch) -> CodexTransport) {
        self.launch = launch
        self.interruptGracePeriod = interruptGracePeriod
        self.makeTransport = makeTransport
        mapper = CodexEventMapper(workingDirectory: launch.workingDirectory.path)
    }

    // MARK: AgentSession

    func start() async throws {
        let connection = try await connect()
        try await openThread(on: connection)
    }

    func send(_ input: AgentTurnInput) async throws {
        guard !isShutDown else { throw AgentError.notRunning }
        guard turn == nil else {
            throw AgentError.providerError(String(localized: "Codex is still working on the previous message."))
        }
        let connection = try await connect()
        if !threadLoaded { try await openThread(on: connection) }
        guard let threadID = mapper.threadID else { throw AgentError.notRunning }
        let current = Turn()
        turn = current
        mapper.beginTurn()
        let params = CodexProtocol.turnStartParams(
            threadID: threadID, cwd: launch.workingDirectory.path, input: input, fallbackModel: threadModel)
        do {
            let result = try await connection.request("turn/start", params, timeout: .seconds(60))
            // Stopped or lost while waiting: the turn has already been reported.
            guard turn?.token == current.token else { return }
            guard let id = result.at("turn.id")?.string else {
                throw AgentError.protocolError(String(localized: "turn/start returned no turn id."))
            }
            adoptTurn(id, alreadyStarted: !(result.at("turn.startedAt")?.isNull ?? true))
        } catch {
            guard turn?.token == current.token else { return }
            turn = nil
            mapper.endTurn()
            throw error
        }
    }

    func respond(to approvalID: String, optionID: String) {
        guard let pending = approvals[approvalID], let response = pending.approval.responses[optionID] else { return }
        approvals[approvalID] = nil
        if let questionID = pending.approval.questionID {
            answer(pending.rpcID, approvalID: approvalID, questionID: questionID, with: response)
        } else {
            connection?.respond(to: pending.rpcID, result: response)
        }
    }

    func interrupt() {
        guard turn != nil, turn?.interruptRequested == false else { return }
        turn?.interruptRequested = true
        cancelApprovals()
        if turn?.started == true { sendInterrupt() }
        let grace = interruptGracePeriod
        interruptWatchdog = Task { [weak self] in
            try? await Task.sleep(for: grace)
            guard !Task.isCancelled else { return }
            self?.interruptTimedOut()
        }
    }

    func shutdown() {
        guard !isShutDown else { return }
        isShutDown = true
        interruptWatchdog?.cancel()
        interruptWatchdog = nil
        turn = nil
        approvals.removeAll()
        questionSets.removeAll()
        dropConnection()
    }

    // MARK: Process and thread

    private func connect() async throws -> CodexConnection {
        if let connection { return connection }
        guard !isShutDown else { throw AgentError.notRunning }
        let connection = CodexConnection(transport: makeTransport(launch))
        connection.onNotification = { [weak self] method, params in self?.handleNotification(method, params) }
        connection.onRequest = { [weak self] id, method, params in
            self?.handleRequest(id: id, method: method, params: params)
        }
        connection.onClose = { [weak self, weak connection] status, stderrTail in
            guard let self, let connection, self.connection === connection else { return }
            self.connectionLost(status: status, stderrTail: stderrTail)
        }
        do {
            try connection.start()
        } catch {
            throw AgentError.providerError(String(localized: "Could not start Codex: \(error.localizedDescription)"))
        }
        self.connection = connection
        do {
            _ = try await connection.request("initialize", CodexProtocol.initializeParams(), timeout: .seconds(30))
            connection.notify("initialized")
        } catch {
            if self.connection === connection { dropConnection() }
            throw error
        }
        return connection
    }

    /// Resumes the known thread, or starts a new one when there is none or it cannot be resumed.
    private func openThread(on connection: CodexConnection) async throws {
        let cwd = launch.workingDirectory.path
        let model = CodexProtocol.modelID(launch.selection) ?? threadModel
        if let resumeID = sessionID ?? launch.resumeSessionID {
            mapper.threadID = resumeID
            do {
                try adoptThread(try await resume(resumeID, cwd: cwd, model: model, on: connection))
                return
            } catch CodexRPCError.server {
                mapper.threadID = nil
                let notice = String(localized: "The previous Codex session could not be resumed, so a new one was started.")
                emit(.notice(notice))
            }
        }
        let result = try await connection.request(
            "thread/start", CodexProtocol.threadStartParams(cwd: cwd, model: model), timeout: .seconds(60))
        try adoptThread(result)
    }

    private func resume(_ threadID: String, cwd: String, model: String?, on connection: CodexConnection) async throws
        -> JSONValue
    {
        let params = CodexProtocol.threadResumeParams(threadID: threadID, cwd: cwd, model: model)
        do {
            return try await connection.request("thread/resume", params, timeout: .seconds(60))
        } catch CodexRPCError.server(_, let message) where CodexProtocol.isArchivedError(message) {
            _ = try await connection.request("thread/unarchive", ["threadId": .string(threadID)], timeout: .seconds(30))
            return try await connection.request("thread/resume", params, timeout: .seconds(60))
        }
    }

    private func adoptThread(_ result: JSONValue) throws {
        guard let id = result.at("thread.id")?.string else {
            throw AgentError.protocolError(String(localized: "Codex returned no thread id."))
        }
        mapper.threadID = id
        sessionID = id
        threadLoaded = true
        threadModel = result["model"]?.string ?? threadModel
        emit(.sessionStarted(id: id))
        if let threadModel { emit(.modelResolved(threadModel)) }
    }

    private func dropConnection() {
        let old = connection
        connection = nil
        threadLoaded = false
        old?.close()
    }

    private func connectionLost(status: Int32, stderrTail: String) {
        connection = nil
        threadLoaded = false
        approvals.removeAll()
        questionSets.removeAll()
        let message = CodexPresentation.exitMessage(status: status, stderr: stderrTail)
        // A turn still waiting for `turn/start` fails through `send` instead.
        if let current = turn, current.id != nil {
            finishTurn(current.interruptRequested ? .interrupted : .failed(message))
        }
        emit(.sessionExited(error: message))
    }

    // MARK: Turns

    private func adoptTurn(_ id: String, alreadyStarted: Bool) {
        guard turn != nil, turn?.id == nil, id != mapper.previousTurnID else { return }
        turn?.id = id
        mapper.adoptTurn(id)
        if alreadyStarted { turn?.started = true }
        if turn?.started == true, turn?.interruptRequested == true { sendInterrupt() }
    }

    private func sendInterrupt() {
        guard let connection, let threadID = mapper.threadID, let id = turn?.id, turn?.interruptSent == false
        else { return }
        turn?.interruptSent = true
        Task {
            // A failed request leaves the turn to the watchdog.
            _ = try? await connection.request(
                "turn/interrupt", ["threadId": .string(threadID), "turnId": .string(id)], timeout: .seconds(10))
        }
    }

    private func interruptTimedOut() {
        guard turn?.interruptRequested == true else { return }
        finishTurn(.interrupted)
        // Codex did not stop in time; replace the process so the stuck turn cannot leak into the next one.
        dropConnection()
    }

    private func finishTurn(_ outcome: TurnOutcome) {
        guard turn != nil else { return }
        turn = nil
        interruptWatchdog?.cancel()
        interruptWatchdog = nil
        mapper.endTurn()
        approvals.removeAll()
        questionSets.removeAll()
        emit(.turnCompleted(outcome))
    }

    private func isCurrentTurn(_ id: String?) -> Bool {
        guard let id, let turn else { return false }
        return turn.id == id || (turn.id == nil && id != mapper.previousTurnID)
    }

    // MARK: Notifications

    private func handleNotification(_ method: String, _ params: JSONValue) {
        let isOurThread = mapper.threadID != nil && params["threadId"]?.string == mapper.threadID
        switch method {
        case "turn/started":
            guard isOurThread, let id = params.at("turn.id")?.string, isCurrentTurn(id) else { return }
            if turn?.id == nil { adoptTurn(id, alreadyStarted: true) }
            turn?.started = true
            if turn?.interruptRequested == true { sendInterrupt() }
        case "turn/completed":
            guard isOurThread, let completed = params["turn"], isCurrentTurn(completed["id"]?.string), let current = turn
            else { return }
            let status = completed["status"]?.string
            if status == "interrupted" || current.interruptRequested {
                finishTurn(.interrupted)
            } else if status == "failed" {
                let message = current.failure ?? CodexPresentation.errorMessage(completed["error"])
                finishTurn(.failed(message ?? String(localized: "Codex could not finish the turn.")))
            } else {
                finishTurn(.completed)
            }
        case "error":
            guard isOurThread, turn != nil, params["turnId"]?.string.map({ isCurrentTurn($0) }) ?? true else { return }
            let message = CodexPresentation.errorMessage(params["error"]) ?? String(localized: "Codex reported an error.")
            if params["willRetry"]?.bool == true {
                emit(.notice(message))
            } else {
                turn?.failure = message
            }
        case "serverRequest/resolved":
            if let requestID = params["requestId"] { requestResolved(requestID) }
        case "thread/closed":
            // Codex unloaded the idle thread; the next turn resumes it.
            if isOurThread { threadLoaded = false }
        default:
            for event in mapper.handle(method: method, params: params) { emit(event) }
        }
    }

    // MARK: Requests from Codex

    private func handleRequest(id: JSONValue, method: String, params: JSONValue) {
        guard let connection else { return }
        approvalSerial += 1
        let approvalID = "\(approvalPrefix)-\(approvalSerial)"
        let changes = params["itemId"]?.string.flatMap { mapper.fileChanges(for: $0) }
        switch CodexServerRequests.action(
            method: method, params: params, approvalID: approvalID, presentation: mapper.presentation,
            fileChanges: changes)
        {
        case .respond(let result):
            connection.respond(to: id, result: result)
        case .reject(let message):
            connection.respondError(to: id, code: -32601, message: message)
        case .approval(let approval):
            // A request that arrives while stopping is turned down right away.
            guard turn?.interruptRequested != true else {
                connection.respond(to: id, result: approval.cancelResponse)
                return
            }
            approvals[approval.request.id] = PendingApproval(rpcID: id, approval: approval)
            emit(.approvalRequested(approval.request))
        case .questions(let questions, let answered, let notices):
            for notice in notices { emit(.notice(notice)) }
            guard !questions.isEmpty, turn?.interruptRequested != true else {
                connection.respond(to: id, result: ["answers": .object(answered)])
                return
            }
            questionSets[id] = QuestionSet(unanswered: Set(questions.map(\.request.id)), answers: answered)
            for question in questions {
                approvals[question.request.id] = PendingApproval(rpcID: id, approval: question)
                emit(.approvalRequested(question.request))
            }
        }
    }

    private func answer(_ rpcID: JSONValue, approvalID: String, questionID: String, with answer: JSONValue) {
        guard var set = questionSets[rpcID] else { return }
        set.answers[questionID] = answer
        set.unanswered.remove(approvalID)
        guard set.unanswered.isEmpty else {
            questionSets[rpcID] = set
            return
        }
        questionSets[rpcID] = nil
        connection?.respond(to: rpcID, result: ["answers": .object(set.answers)])
    }

    /// Answers every open prompt with its "stop" choice so Codex is not left waiting.
    private func cancelApprovals() {
        let pending = approvals
        approvals.removeAll()
        for (approvalID, entry) in pending.sorted(by: { $0.key < $1.key }) {
            if let questionID = entry.approval.questionID {
                answer(entry.rpcID, approvalID: approvalID, questionID: questionID, with: entry.approval.cancelResponse)
            } else {
                connection?.respond(to: entry.rpcID, result: entry.approval.cancelResponse)
            }
        }
    }

    /// Codex settled a request itself, for example because the turn ended.
    private func requestResolved(_ rpcID: JSONValue) {
        questionSets[rpcID] = nil
        for approvalID in approvals.keys.sorted() where approvals[approvalID]?.rpcID == rpcID {
            approvals[approvalID] = nil
            emit(.approvalResolved(id: approvalID))
        }
    }

    private func emit(_ event: AgentEvent) {
        guard !isShutDown else { return }
        onEvent?(event)
    }
}
