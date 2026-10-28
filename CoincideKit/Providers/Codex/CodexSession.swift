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
    /// How many times the thread could not be resumed, so a new one was started in its place.
    private var replacedThreads = 0
    private var isShutDown = false
    private var turn: Turn?
    private var interruptWatchdog: Task<Void, Never>?
    private var approvals: [String: PendingApproval] = [:]
    private var questions: [String: PendingQuestions] = [:]
    private let requestPrefix = String(UUID().uuidString.prefix(8))
    private var requestSerial = 0
    private var modelsRequested = false
    private var rateLimitsRequested = false
    private var skillsRequested = false
    /// The skills Codex offers in the thread's folder, by name, with their files.
    private var skills: [String: String] = [:]

    private struct Turn {
        let token = UUID()
        var id: String?
        /// `turn/start` was sent, so Codex may be running it.
        var sent = false
        /// `turn/started` arrived; Codex only accepts `turn/interrupt` after it.
        var started = false
        var interruptRequested = false
        var interruptSent = false
        var failure: String?
        /// The last retry notice without its numbers, so a streak of retries is shown once.
        var retryKind: String?
    }

    private struct PendingApproval {
        let rpcID: JSONValue
        let approval: CodexApproval
        /// The turn it arrived in; requests that arrive between turns stay open until answered.
        let turnToken: UUID?
    }

    private struct PendingQuestions {
        let rpcID: JSONValue
        let input: CodexUserInput
        let turnToken: UUID?
    }

    convenience init(launch: AgentLaunch) {
        self.init(launch: launch, interruptGracePeriod: .seconds(5)) { launch in
            CodexProcessTransport(
                executable: launch.executable, workingDirectory: launch.workingDirectory, environment: launch.environment)
        }
    }

    /// `interruptGracePeriod` is how long Codex gets to confirm a stop before its process is ended.
    init(launch: AgentLaunch, interruptGracePeriod: Duration, makeTransport: @escaping (AgentLaunch) -> CodexTransport) {
        self.launch = launch
        self.interruptGracePeriod = interruptGracePeriod
        self.makeTransport = makeTransport
        mapper = CodexEventMapper(workingDirectory: launch.workingDirectory.path)
    }

    // MARK: AgentSession

    func start() async throws {
        let connection = try await connect()
        if !threadLoaded { try await openThread(on: connection) }
    }

    func send(_ input: AgentTurnInput) async throws {
        guard !isShutDown else { throw AgentError.notRunning }
        guard turn == nil else {
            throw AgentError.providerError(String(localized: "Codex is still working on the previous message."))
        }
        // Registered before any waiting, so a stop requested meanwhile is not lost.
        let current = Turn()
        turn = current
        let replaced = replacedThreads
        do {
            let connection = try await connect()
            // Codex may have unloaded the thread; resuming it can fail and start a new one.
            if !threadLoaded { try await openThread(on: connection) }
            guard turn?.token == current.token else { return }
            if turn?.interruptRequested == true {
                finishTurn(.interrupted)
                return
            }
            guard let threadID = mapper.threadID else { throw AgentError.notRunning }
            mapper.beginTurn()
            turn?.sent = true
            // A new thread has seen nothing of the conversation, so it gets the whole recap.
            var input = input
            if replacedThreads != replaced { input.text = input.prompt(forNewSession: true) }
            let params = CodexProtocol.turnStartParams(
                threadID: threadID, cwd: launch.workingDirectory.path, input: input, fallbackModel: threadModel,
                skills: skills)
            let result = try await connection.request("turn/start", params, timeout: .seconds(120))
            // Stopped or lost while waiting: the turn has already been reported.
            guard turn?.token == current.token else { return }
            guard let id = result.at("turn.id")?.string else {
                throw AgentError.protocolError(String(localized: "turn/start returned no turn id."))
            }
            adoptTurn(id, alreadyStarted: !(result.at("turn.startedAt")?.isNull ?? true))
        } catch {
            guard turn?.token == current.token else { return }
            let sent = turn?.sent == true
            turn = nil
            interruptWatchdog?.cancel()
            interruptWatchdog = nil
            mapper.endTurn()
            cancelPendingRequests(of: current.token)
            if sent, case CodexRPCError.timedOut = error {
                // Codex may still start the turn; end the process so it cannot run unseen.
                endProcess(error: error.localizedDescription)
            }
            throw error
        }
    }

    let supportsSteering = true
    /// How long a steer waits for Codex to name the turn it goes into.
    nonisolated static let steerWaitLimit: Duration = .seconds(10)

    /// Adds the message to the running turn with `turn/steer`, as T3 Code does. Codex only takes it once the turn
    /// has its id, so a steer sent before `turn/start` answers waits for it a little; Codex refuses the message when
    /// that turn is no longer the active one.
    func steer(_ input: AgentTurnInput) async throws {
        if let pending = turn, pending.id == nil, !pending.interruptRequested {
            let deadline = ContinuousClock.now + Self.steerWaitLimit
            while let current = turn, current.token == pending.token, current.id == nil, !current.interruptRequested,
                !isShutDown, ContinuousClock.now < deadline
            {
                try await Task.sleep(for: .milliseconds(50))
            }
        }
        guard !isShutDown, let connection, let threadID = mapper.threadID, let current = turn, current.sent,
            let turnID = current.id, !current.interruptRequested
        else {
            throw AgentError.providerError(String(localized: "Codex can't take a message for this turn now."))
        }
        let params: JSONValue = [
            "threadId": .string(threadID), "expectedTurnId": .string(turnID),
            "input": CodexProtocol.userInput(text: input.text, imagePaths: input.imagePaths, skills: skills),
        ]
        _ = try await connection.request("turn/steer", params, timeout: .seconds(30))
    }

    func respond(to approvalID: String, optionID: String) {
        guard let pending = approvals[approvalID], let response = pending.approval.responses[optionID] else { return }
        approvals[approvalID] = nil
        connection?.respond(to: pending.rpcID, result: response)
    }

    func answer(userInput requestID: String, answers: [String: [String]]) {
        guard let pending = questions.removeValue(forKey: requestID) else { return }
        connection?.respond(to: pending.rpcID, result: pending.input.response(to: answers))
    }

    func interrupt() {
        guard let current = turn, !current.interruptRequested else { return }
        turn?.interruptRequested = true
        cancelPendingRequests(of: current.token)
        // Before `turn/start` was sent, `send` stops the turn itself once it has a process.
        if current.started { sendInterrupt() }
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
            _ = try await connection.request("initialize", CodexProtocol.initializeParams(), timeout: .seconds(60))
            connection.notify("initialized")
        } catch {
            if self.connection === connection { dropConnection() }
            throw error
        }
        guard self.connection === connection else { throw CodexRPCError.closed(nil) }
        return connection
    }

    /// Resumes the known thread, or starts a new one when there is none or it cannot be resumed.
    private func openThread(on connection: CodexConnection) async throws {
        let cwd = launch.workingDirectory.path
        let model = CodexProtocol.modelID(launch.selection) ?? threadModel
        if let resumeID = sessionID ?? launch.resumeSessionID {
            do {
                try adoptThread(try await resume(resumeID, cwd: cwd, model: model, on: connection), on: connection)
                return
            } catch CodexRPCError.server(_, let message) {
                let result = try await connection.request(
                    "thread/start", CodexProtocol.threadStartParams(cwd: cwd, model: model), timeout: .seconds(120))
                try adoptThread(result, on: connection)
                replacedThreads += 1
                let notice = String(
                    localized: "The previous Codex session could not be resumed, so a new one was started. (\(message))")
                emit(.notice(notice))
                return
            }
        }
        let result = try await connection.request(
            "thread/start", CodexProtocol.threadStartParams(cwd: cwd, model: model), timeout: .seconds(60))
        try adoptThread(result, on: connection)
    }

    private func resume(_ threadID: String, cwd: String, model: String?, on connection: CodexConnection) async throws
        -> JSONValue
    {
        let params = CodexProtocol.threadResumeParams(threadID: threadID, cwd: cwd, model: model)
        do {
            return try await connection.request("thread/resume", params, timeout: .seconds(120))
        } catch CodexRPCError.server(_, let message) where CodexProtocol.isArchivedError(message) {
            _ = try await connection.request("thread/unarchive", ["threadId": .string(threadID)], timeout: .seconds(30))
            return try await connection.request("thread/resume", params, timeout: .seconds(120))
        }
    }

    private func adoptThread(_ result: JSONValue, on connection: CodexConnection) throws {
        guard self.connection === connection, !isShutDown else { throw CodexRPCError.closed(nil) }
        guard let id = result.at("thread.id")?.string else {
            throw AgentError.protocolError(String(localized: "Codex returned no thread id."))
        }
        mapper.threadID = id
        sessionID = id
        threadLoaded = true
        threadModel = result["model"]?.string ?? threadModel
        emit(.sessionStarted(id: id))
        if let threadModel { emit(.modelResolved(threadModel)) }
        reportModels(on: connection)
        reportRateLimits(on: connection)
        reportSkills(on: connection)
    }

    /// Lists the skills Codex offers in the thread's folder once per session, for the composer's `$` picker.
    private func reportSkills(on connection: CodexConnection) {
        guard !skillsRequested else { return }
        skillsRequested = true
        let cwd = launch.workingDirectory.path
        Task { [weak self] in
            guard let result = try? await connection.request("skills/list", ["cwds": [.string(cwd)]], timeout: .seconds(20))
            else { return }
            let skills = CodexProtocol.skills(fromList: result, cwd: cwd)
            guard let self else { return }
            self.skills = Dictionary(skills.compactMap { skill in skill.path.map { (skill.name, $0) } }) { first, _ in first }
            emit(.commandsDiscovered(skills))
        }
    }

    /// Reads the plan's usage windows once per session, so the composer's meter is current before the first turn;
    /// Codex reports changes itself while turns run.
    private func reportRateLimits(on connection: CodexConnection) {
        guard !rateLimitsRequested else { return }
        rateLimitsRequested = true
        Task { [weak self] in
            // A background read: Codex can skip looking up reset-credit details.
            guard let result = try? await connection.request(
                "account/rateLimits/read", ["excludeResetCreditDetails": true], timeout: .seconds(20))
            else { return }
            let windows = CodexUsageLimits.windows(fromRead: result)
            if !windows.isEmpty { self?.emit(.rateLimits(windows)) }
        }
    }

    /// Refreshes the model picker once per session from the catalog this process uses.
    private func reportModels(on connection: CodexConnection) {
        guard !modelsRequested else { return }
        modelsRequested = true
        Task { [weak self] in
            guard let models = try? await CodexProbe.modelList(connection), !models.isEmpty else { return }
            self?.emit(.modelsDiscovered(models))
        }
    }

    private func dropConnection() {
        let old = connection
        connection = nil
        threadLoaded = false
        approvals.removeAll()
        questions.removeAll()
        old?.close()
    }

    /// Ends the process for good and tells the runner, which resumes the thread in a new session next time.
    private func endProcess(error: String?) {
        guard !isShutDown else { return }
        emit(.sessionExited(error: error))
        shutdown()
    }

    private func connectionLost(status: Int32, stderrTail: String) {
        connection = nil
        threadLoaded = false
        approvals.removeAll()
        questions.removeAll()
        let message = CodexPresentation.exitMessage(status: status, stderr: stderrTail)
        // A turn whose `turn/start` has no answer yet fails through `send` instead.
        if let current = turn, current.id != nil {
            finishTurn(current.interruptRequested ? .interrupted : .failed(message))
        }
        emit(.sessionExited(error: message))
        isShutDown = true
    }

    // MARK: Turns

    private func adoptTurn(_ id: String, alreadyStarted: Bool) {
        guard turn != nil, turn?.id == nil, !mapper.isFinished(id) else { return }
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
        // Codex did not stop in time; end its process so the stuck turn cannot leak into the next one.
        endProcess(error: nil)
    }

    private func finishTurn(_ outcome: TurnOutcome) {
        guard let current = turn else { return }
        turn = nil
        interruptWatchdog?.cancel()
        interruptWatchdog = nil
        mapper.endTurn()
        // The transcript shows prompts left open by the turn as declined; tell Codex the same.
        cancelPendingRequests(of: current.token)
        emit(.turnCompleted(outcome))
    }

    private func isCurrentTurn(_ id: String?) -> Bool {
        guard let id, let turn, turn.sent else { return false }
        return turn.id == id || (turn.id == nil && !mapper.isFinished(id))
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
            guard isOurThread, let current = turn, current.sent,
                params["turnId"]?.string.map({ isCurrentTurn($0) }) ?? true
            else { return }
            let message = CodexPresentation.errorMessage(params["error"]) ?? String(localized: "Codex reported an error.")
            if params["willRetry"]?.bool == true {
                // "Reconnecting... 2/5" after "1/5" adds nothing new.
                let kind = message.filter { !$0.isNumber }
                guard kind != current.retryKind else { return }
                turn?.retryKind = kind
                emit(.notice(message))
            } else {
                turn?.failure = message
            }
        case "serverRequest/resolved":
            if let requestID = params["requestId"] { requestResolved(requestID) }
        case "thread/closed":
            // Codex unloaded the idle thread; the next turn resumes it.
            if isOurThread { threadLoaded = false }
        case "account/rateLimits/updated":
            // The account's limits, whichever thread's turn spent them.
            let windows = CodexUsageLimits.windows(from: params["rateLimits"])
            if !windows.isEmpty { emit(.rateLimits(windows)) }
        default:
            for event in mapper.handle(method: method, params: params) { emit(event) }
        }
    }

    // MARK: Requests from Codex

    private func handleRequest(id: JSONValue, method: String, params: JSONValue) {
        guard let connection else { return }
        requestSerial += 1
        let requestID = "\(requestPrefix)-\(requestSerial)"
        let changes = params["itemId"]?.string.flatMap { mapper.fileChanges(for: $0) }
        let action = CodexServerRequests.action(
            method: method, params: params, requestID: requestID, presentation: mapper.presentation,
            fileChanges: changes)
        // A prompt that arrives while stopping is turned down right away.
        let stopping = turn?.interruptRequested == true
        let thread = params["threadId"]?.string ?? params["conversationId"]?.string
        let fromSubagent = thread != nil && mapper.threadID != nil && thread != mapper.threadID
        switch action {
        case .respond(let result):
            connection.respond(to: id, result: result)
        case .reject(let message):
            connection.respondError(to: id, code: -32601, message: message)
        case .approval(var approval):
            guard !stopping else { return connection.respond(to: id, result: approval.cancelResponse) }
            if fromSubagent { approval.request.title = String(localized: "Subagent: \(approval.request.title)") }
            approvals[requestID] = PendingApproval(rpcID: id, approval: approval, turnToken: turn?.token)
            emit(.approvalRequested(approval.request))
        case .userInput(var input):
            guard !stopping else { return connection.respond(to: id, result: input.dismissResponse) }
            if fromSubagent {
                input.request.title = input.request.title.map { String(localized: "Subagent: \($0)") }
                    ?? String(localized: "A subagent has a question")
            }
            questions[requestID] = PendingQuestions(rpcID: id, input: input, turnToken: turn?.token)
            emit(.userInputRequested(input.request))
        }
    }

    /// Answers the prompts a turn left open with their "stop" choice, so Codex is not left waiting.
    private func cancelPendingRequests(of turnToken: UUID) {
        for (requestID, pending) in approvals.sorted(by: { $0.key < $1.key }) where pending.turnToken == turnToken {
            approvals[requestID] = nil
            connection?.respond(to: pending.rpcID, result: pending.approval.cancelResponse)
        }
        for (requestID, pending) in questions.sorted(by: { $0.key < $1.key }) where pending.turnToken == turnToken {
            questions[requestID] = nil
            connection?.respond(to: pending.rpcID, result: pending.input.dismissResponse)
        }
    }

    /// Codex settled a request itself, for example because the turn ended.
    private func requestResolved(_ rpcID: JSONValue) {
        for (requestID, pending) in approvals.sorted(by: { $0.key < $1.key }) where pending.rpcID == rpcID {
            approvals[requestID] = nil
            emit(.approvalResolved(id: requestID))
        }
        for (requestID, pending) in questions.sorted(by: { $0.key < $1.key }) where pending.rpcID == rpcID {
            questions[requestID] = nil
            emit(.userInputResolved(id: requestID))
        }
    }

    private func emit(_ event: AgentEvent) {
        guard !isShutDown else { return }
        onEvent?(event)
    }
}
