import Foundation

/// One Coincide thread driven through `muse serve`, the MSP connection T3 Code's Muse provider uses.
///
/// Coincide mints the Muse session id (a UUIDv7, as T3 does) and keeps it as the thread's session id. The model
/// travels with each turn (`session/setModel` when it changes) and so does the reasoning effort. The access mode is a
/// flag of the host process, so a turn that changes it starts a new host, which resumes the same session.
///
/// Muse has no Plan mode (`ProviderKind.supportsPlanMode`), so threads run it in build mode. Only commit messages and
/// pull request text ask for Plan mode; for those Muse runs without its shell and file-writing tools, as T3 Code's
/// Muse text generation does.
@MainActor
final class MuseSession: AgentSession, BackgroundWorkReporting {
    let provider: ProviderKind = .muse
    private(set) var sessionID: String?
    var onEvent: ((AgentEvent) -> Void)?
    let supportsSteering = true

    struct Timing {
        var initialize: Duration = .seconds(20)
        var request: Duration = .seconds(30)
        var turnStart: Duration = .seconds(120)
        /// How long Muse gets to confirm a stop before its host is ended.
        var interruptGrace: Duration = .seconds(10)
        /// How long a steer waits for Muse to admit the turn it goes into.
        var steerWait: Duration = .seconds(10)

        static let standard = Timing()
    }

    typealias MakeTransport = @MainActor (_ arguments: [String], _ workingDirectory: URL) -> MuseTransport

    private let launch: AgentLaunch
    private let makeTransport: MakeTransport
    private let ids: MuseIDs
    private let timing: Timing
    /// The working directory with symlinks resolved, as Muse requires.
    private let workspaceRoot: String
    private var connection: MuseConnection?
    private var hostMode: MuseProtocol.HostMode?
    private var sessionLoaded = false
    /// The session's model as Muse last reported or was told.
    private var sessionModel: String?
    /// How many times the session could not be resumed, so a new one was started in its place.
    private var replacedSessions = 0
    private var isShutDown = false
    private var mapper: MuseEventMapper
    private var turn: Turn?
    /// Turns that ended. A turn Muse starts with one of these ids is an echo, not a turn of its own.
    private var finishedTurns: Set<String> = []
    private var interruptWatchdog: Task<Void, Never>?
    /// Approvals Muse is waiting on, by approval id.
    private var approvals: [String: PendingApproval] = [:]
    /// Approvals Muse settled, which a late repeat must not bring back (T3's `settledRequests`).
    private var settledApprovals: Set<String> = []
    private var questions: [String: PendingQuestion] = [:]
    private var settledQuestions: Set<String> = []
    /// The latest subscription usage, for when a quota stop lifts.
    private var subscriptionUsage: MuseSubscriptionUsage?
    private var extrasRequested = false

    private struct Turn {
        let token = UUID()
        /// The Muse turn: the id Coincide minted for `turn/start` (Muse derives the turn id from it), or the one
        /// Muse acknowledged.
        var nativeID: String
        /// Muse turns that run as part of this one: Muse first runs a turn it had queued, such as a background
        /// report, so its items belong here and Stop ends it too.
        var joined: Set<String> = []
        /// `turn/start` or `session/compact` was sent.
        var sent = false
        /// Muse acknowledged it; it only takes a steer or a stop after that.
        var admitted = false
        var interruptRequested = false
        var interruptSent = false
        /// `/compact`: the turn ends when the compaction does.
        var compact = false
        var turnIDs: Set<String> { joined.union([nativeID]) }
    }

    private struct PendingApproval {
        var approval: MuseApproval
        /// The id the transcript knows the prompt by: Muse's approval id, then one per later stage of a chained command.
        var requestID: String
        var stage = 0
        /// The requirement the user (or Coincide, for a workflow child in full access) answered; Muse settles it with
        /// `approval/resolved`, or asks about the next one.
        var answered: JSONValue?
        /// The turn it arrived in; nil between turns.
        var turnToken: UUID?
        var shown: Bool
    }

    private struct PendingQuestion {
        var input: MuseUserInput
        var turnToken: UUID?
        var answered = false
    }

    convenience init(launch: AgentLaunch) {
        self.init(launch: launch, ids: .uuidV7(), timing: .standard) { arguments, directory in
            MuseProcessTransport(
                executable: launch.executable, arguments: arguments, workingDirectory: directory,
                environment: launch.environment)
        }
    }

    init(launch: AgentLaunch, ids: MuseIDs, timing: Timing, makeTransport: @escaping MakeTransport) {
        self.launch = launch
        self.ids = ids
        self.timing = timing
        self.makeTransport = makeTransport
        workspaceRoot = MuseProtocol.canonicalPath(launch.workingDirectory.path)
        mapper = MuseEventMapper(workingDirectory: launch.workingDirectory.path)
    }

    var hasBackgroundWork: Bool { !mapper.background.isEmpty }

    // MARK: AgentSession

    func start() async throws {
        let mode = MuseProtocol.HostMode(accessMode: launch.accessMode, interactionMode: launch.interactionMode)
        let connection = try await connect(mode)
        if !sessionLoaded { try await openSession(on: connection, mode: mode, selection: launch.selection) }
    }

    func send(_ input: AgentTurnInput) async throws {
        guard !isShutDown else { throw AgentError.notRunning }
        guard turn == nil else {
            throw AgentError.providerError(String(localized: "Muse Code is still working on the previous message."))
        }
        let compact = input.imagePaths.isEmpty && MuseProtocol.isCompactCommand(input.message)
        // Registered before any waiting, so a stop requested meanwhile is not lost.
        let current = Turn(nativeID: ids.next(), compact: compact)
        turn = current
        let replaced = replacedSessions
        do {
            let mode = MuseProtocol.HostMode(accessMode: input.accessMode, interactionMode: input.interactionMode)
            // The access mode (and text generation's read-only mode) are flags of the host: a change starts a new
            // one, which resumes the session.
            if connection != nil, hostMode != mode { dropConnection() }
            let connection = try await connect(mode)
            if !sessionLoaded { try await openSession(on: connection, mode: mode, selection: input.selection) }
            guard turn?.token == current.token else { return }
            if turn?.interruptRequested == true { return finishTurn(.interrupted) }
            guard let sessionID else { throw AgentError.notRunning }
            if compact {
                try await startCompaction(current, sessionID: sessionID, on: connection)
                return
            }
            try await applyModel(input.selection, sessionID: sessionID, on: connection)
            guard turn?.token == current.token else { return }
            if turn?.interruptRequested == true { return finishTurn(.interrupted) }
            // A new session has seen nothing of the conversation, so it gets the whole recap.
            let message = replacedSessions != replaced ? input.prompt(forNewSession: true) : input.text
            let parts = try inputParts(text: message, imagePaths: input.imagePaths)
            var params: [String: JSONValue] = [
                "sessionId": .string(sessionID), "input": .array(parts),
                "displayText": .string(TerminalText.nonEmpty(input.message) ?? "Image attachment"),
                // Resumed sessions keep their earlier roots; pin edits to this checkout (T3).
                "workspaceRoots": [.string(workspaceRoot)], "ifBusy": "queue",
            ]
            if let effort = MuseProtocol.reasoningEffort(input.selection) { params["reasoningEffort"] = .string(effort) }
            turn?.sent = true
            let result = try await connection.command(
                "turn/start", .object(params), commandID: current.nativeID, attempts: 3, timeout: timing.turnStart)
            // Stopped, ended or lost while waiting: the turn has already been reported.
            guard turn?.token == current.token else { return }
            guard let turnID = result["turnId"]?.string, !turnID.isEmpty else {
                throw AgentError.protocolError(String(localized: "Muse Code returned no turn id."))
            }
            admit(turnID)
        } catch {
            guard turn?.token == current.token else { return }
            let sent = turn?.sent == true
            turn = nil
            interruptWatchdog?.cancel()
            interruptWatchdog = nil
            mapper.endTurn()
            finishedTurns.formUnion(current.turnIDs)
            if sent, case MuseRPCError.timedOut = error {
                // Muse may still start the turn; end the host so it cannot run unseen.
                endProcess(error: error.localizedDescription)
            }
            throw MuseProtocol.explained(error)
        }
    }

    /// Adds the message to the running turn with `turn/steer`, which names the turn it is meant for, so it never lands
    /// in another (T3). A steer sent before Muse admitted the turn waits for that a little.
    func steer(_ input: AgentTurnInput) async throws {
        if let pending = turn, !pending.admitted, !pending.interruptRequested {
            let deadline = ContinuousClock.now + timing.steerWait
            while let current = turn, current.token == pending.token, !current.admitted, !current.interruptRequested,
                !isShutDown, ContinuousClock.now < deadline
            {
                try await Task.sleep(for: .milliseconds(50))
            }
        }
        guard !isShutDown, let connection, let sessionID, let current = turn, current.admitted, !current.compact,
            !current.interruptRequested
        else {
            throw AgentError.providerError(String(localized: "Muse Code can't take a message for this turn now."))
        }
        let parts = try inputParts(text: input.text, imagePaths: input.imagePaths)
        var params: [String: JSONValue] = [
            "sessionId": .string(sessionID), "expectedTurnId": .string(current.nativeID), "input": .array(parts),
        ]
        if let effort = MuseProtocol.reasoningEffort(input.selection) { params["reasoningEffort"] = .string(effort) }
        let result = try await connection.command("turn/steer", .object(params), timeout: timing.request)
        // Muse names the turn that took the message; follow it, so its items show and Stop ends it.
        if let id = result["turnId"]?.string, id != current.nativeID, turn?.token == current.token {
            turn?.joined.insert(id)
        }
    }

    func respond(to approvalID: String, optionID: String) {
        guard let match = approvals.first(where: { $0.value.requestID == approvalID }), match.value.answered == nil,
            let choice = match.value.approval.choices.first(where: { $0.id == optionID })
        else { return }
        decide(match.key, choice: choice)
    }

    func answer(userInput requestID: String, answers: [String: [String]]) {
        guard let pending = questions[requestID], !pending.answered, let connection, let sessionID else { return }
        questions[requestID]?.answered = true
        let method: String
        var params: [String: JSONValue] = ["sessionId": .string(sessionID), "userInputId": .string(requestID)]
        if !answers.isEmpty, let payload = pending.input.answers(answers) {
            method = "userInput/answer"
            params["answers"] = payload
        } else {
            // Dismissed, or a question left without an answer, which Muse would refuse: the tool call sees a decline.
            method = "userInput/cancel"
            params["reason"] = .string(
                answers.isEmpty ? "The user dismissed the questions." : "The user did not answer every question.")
        }
        Task { [weak self] in
            do {
                _ = try await connection.command(method, .object(params), timeout: self?.timing.request ?? .seconds(30))
            } catch {
                self?.answerFailed(requestID, error: error)
            }
        }
    }

    func interrupt() {
        guard let current = turn, !current.interruptRequested else { return }
        turn?.interruptRequested = true
        if current.compact {
            // Muse cannot stop a compaction; ending its host does (T3). The next turn starts a new host.
            finishTurn(.interrupted)
            dropConnection()
            return
        }
        // Before Muse admitted the turn, `send` stops it once the acknowledgement arrives.
        if current.admitted { sendInterrupt() }
        let grace = timing.interruptGrace
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

    // MARK: Host and session

    private func connect(_ mode: MuseProtocol.HostMode) async throws -> MuseConnection {
        if let connection { return connection }
        guard !isShutDown else { throw AgentError.notRunning }
        let transport = makeTransport(MuseProtocol.serveArguments(mode), URL(fileURLWithPath: workspaceRoot))
        let connection = MuseConnection(transport: transport, ids: ids)
        connection.onNotification = { [weak self] method, params in self?.handleNotification(method, params) }
        connection.onRequest = { [weak self] method, params in self?.handleRequest(method, params) }
        connection.onClose = { [weak self, weak connection] status, stderrTail in
            guard let self, let connection, self.connection === connection else { return }
            self.connectionLost(status: status, stderrTail: stderrTail)
        }
        do {
            try connection.start()
        } catch {
            throw AgentError.providerError(String(localized: "Could not start Muse Code: \(error.localizedDescription)"))
        }
        self.connection = connection
        hostMode = mode
        do {
            let result = try await connection.request("initialize", MuseProtocol.initializeParams(), timeout: timing.initialize)
            try MuseProtocol.checkInitializeResult(result)
            connection.notify("initialized")
        } catch {
            if self.connection === connection { dropConnection() }
            throw error
        }
        guard self.connection === connection else { throw MuseRPCError.closed(nil) }
        return connection
    }

    /// Resumes the known session, or starts a new one when there is none or Muse cannot resume it.
    private func openSession(on connection: MuseConnection, mode: MuseProtocol.HostMode, selection: ModelSelection) async throws {
        if let resumeID = sessionID ?? launch.resumeSessionID {
            let result: JSONValue
            do {
                let params: JSONValue = [
                    "sessionId": .string(resumeID), "excludeItems": true,
                    "permissionProfile": .string(MuseProtocol.permissionProfile(mode.accessMode)),
                ]
                result = try await connection.command("session/resume", params, timeout: timing.request)
            } catch MuseRPCError.server(_, _, let message) {
                try await startSession(mode: mode, selection: selection, on: connection)
                replacedSessions += 1
                emit(
                    .notice(
                        String(localized: "The previous Muse Code session could not be resumed, so a new one was started. (\(message))")))
                return
            }
            guard result.at("session.sessionId")?.string == resumeID else {
                throw AgentError.protocolError(String(localized: "Muse Code resumed a different session."))
            }
            // A resumed session keeps the approval mode it had; this host's access decides it now.
            _ = try await connection.command(
                "session/setApprovalMode",
                ["sessionId": .string(resumeID), "mode": .string(MuseProtocol.approvalMode(mode.accessMode))],
                timeout: timing.request)
            try adoptSession(resumeID, model: result.at("session.modelId")?.string, on: connection)
            return
        }
        try await startSession(mode: mode, selection: selection, on: connection)
    }

    private func startSession(mode: MuseProtocol.HostMode, selection: ModelSelection, on connection: MuseConnection) async throws {
        let id = ids.next()
        var params: [String: JSONValue] = [
            "sessionId": .string(id), "workspaceRoot": .string(workspaceRoot), "providerId": .string(MuseProtocol.providerID),
            "approvalMode": .string(MuseProtocol.approvalMode(mode.accessMode)),
            "permissionProfile": .string(MuseProtocol.permissionProfile(mode.accessMode)),
        ]
        if let model = MuseProtocol.modelID(selection) { params["modelId"] = .string(model) }
        let result = try await connection.command("session/start", .object(params), timeout: timing.request)
        guard result.at("session.sessionId")?.string == id else {
            throw AgentError.protocolError(String(localized: "Muse Code started a different session than the one asked for."))
        }
        try adoptSession(id, model: result.at("session.modelId")?.string, on: connection)
    }

    private func adoptSession(_ id: String, model: String?, on connection: MuseConnection) throws {
        guard self.connection === connection, !isShutDown else { throw MuseRPCError.closed(nil) }
        sessionID = id
        sessionLoaded = true
        sessionModel = model ?? sessionModel
        emit(.sessionStarted(id: id))
        if let sessionModel { emit(.modelResolved(sessionModel)) }
        requestExtras(on: connection, sessionID: id)
    }

    /// Reads the plan's usage and the model catalog once per session, so the composer is current before the first
    /// turn; Muse reports usage changes itself afterwards.
    private func requestExtras(on connection: MuseConnection, sessionID: String) {
        guard !extrasRequested else { return }
        extrasRequested = true
        Task { [weak self] in
            if let result = try? await connection.request("usage/read", [:], timeout: .seconds(15)),
                let usage = MuseSubscriptionUsage(result["usage"]), let self
            {
                if self.subscriptionUsage == nil { self.subscriptionUsage = usage }
                self.emit(.rateLimits(usage.windows))
            }
            if let result = try? await connection.request("model/list", ["sessionId": .string(sessionID)], timeout: .seconds(15)),
                let models = MuseProtocol.models(fromList: result), !models.isEmpty
            {
                self?.emit(.modelsDiscovered(models))
            }
        }
    }

    private func applyModel(_ selection: ModelSelection, sessionID: String, on connection: MuseConnection) async throws {
        guard let model = MuseProtocol.modelID(selection), model != sessionModel else { return }
        let params: JSONValue = [
            "sessionId": .string(sessionID), "model": ["modelId": .string(model), "providerId": .string(MuseProtocol.providerID)],
        ]
        _ = try await connection.command("session/setModel", params, timeout: timing.request)
        sessionModel = model
        emit(.modelResolved(model))
    }

    private func dropConnection() {
        let old = connection
        connection = nil
        hostMode = nil
        sessionLoaded = false
        approvals.removeAll()
        questions.removeAll()
        mapper.endBackground()
        old?.close()
    }

    /// Ends the host for good and tells the runner, which resumes the session in a new one next time.
    private func endProcess(error: String?) {
        guard !isShutDown else { return }
        emit(.sessionExited(error: error))
        shutdown()
    }

    private func connectionLost(status: Int32, stderrTail: String) {
        connection = nil
        hostMode = nil
        sessionLoaded = false
        approvals.removeAll()
        questions.removeAll()
        mapper.endBackground()
        let message = MuseProtocol.exitMessage(status: status, stderr: stderrTail)
        // A turn whose `turn/start` has no answer yet fails through `send` instead.
        if let current = turn, current.admitted || current.compact && current.sent {
            finishTurn(current.interruptRequested ? .interrupted : .failed(message))
        }
        emit(.sessionExited(error: message))
        isShutDown = true
    }

    // MARK: Turns

    /// Muse acknowledged the turn. It names the turn that carries the input, which is normally the one Coincide minted.
    private func admit(_ turnID: String) {
        guard let current = turn, !current.admitted else { return }
        turn?.admitted = true
        if turnID != current.nativeID {
            turn?.joined.insert(current.nativeID)
            turn?.nativeID = turnID
        }
        if current.interruptRequested { sendInterrupt() }
    }

    private func startCompaction(_ current: Turn, sessionID: String, on connection: MuseConnection) async throws {
        turn?.sent = true
        let result = try await connection.command(
            "session/compact", ["sessionId": .string(sessionID)], commandID: current.nativeID, timeout: timing.request)
        guard turn?.token == current.token else { return }
        turn?.admitted = true
        switch result["status"]?.string {
        case "accepted":
            // The compaction item ends the turn.
            break
        case "noop":
            let reason = result["reason"]?.string.map { MuseProtocol.compactionReason($0) }
            finishTurn(.failed(reason ?? String(localized: "Muse Code has no conversation to compact yet.")))
        default:
            throw AgentError.protocolError(
                String(localized: "Muse Code answered the compaction with an unexpected status: \(result["status"]?.displayText ?? "")"))
        }
    }

    private func sendInterrupt() {
        guard let connection, let sessionID, let current = turn, !current.interruptSent else { return }
        turn?.interruptSent = true
        // Muse runs a joined turn first, so Stop ends those too (T3).
        let targets = current.joined.sorted() + [current.nativeID]
        let timeout = timing.request
        Task {
            for target in targets {
                // A failed request leaves the turn to the watchdog.
                _ = try? await connection.command(
                    "turn/interrupt", ["sessionId": .string(sessionID), "turnId": .string(target)], timeout: timeout)
            }
        }
    }

    private func interruptTimedOut() {
        guard turn?.interruptRequested == true else { return }
        finishTurn(.interrupted)
        // Muse did not stop in time; end its host so the stuck turn cannot leak into the next one.
        endProcess(error: nil)
    }

    private func finishTurn(_ outcome: TurnOutcome) {
        guard let current = turn else { return }
        turn = nil
        finishedTurns.formUnion(current.turnIDs)
        interruptWatchdog?.cancel()
        interruptWatchdog = nil
        mapper.endTurn()
        // Muse settles a turn's own prompts as it ends. A workflow child's approval can outlive the turn (T3 keeps it
        // open), so it is asked again below, after the turn's open prompts were closed with it.
        var reopened: [String] = []
        for (key, pending) in approvals where pending.turnToken == current.token {
            if pending.approval.subagentID != nil, pending.answered == nil {
                approvals[key]?.turnToken = nil
                if pending.shown { reopened.append(key) }
            } else {
                approvals[key] = nil
            }
        }
        for (key, pending) in questions where pending.turnToken == current.token { questions[key] = nil }
        emit(.turnCompleted(outcome))
        for key in reopened.sorted() {
            guard let pending = approvals[key] else { continue }
            emit(.approvalRequested(pending.approval.request(id: pending.requestID, presentation: mapper.presentation)))
        }
    }

    /// Whether `turnID` (when a notification names one) belongs to the running turn.
    private func owns(_ turnID: String?) -> Bool {
        guard let current = turn else { return false }
        return turnID.map { current.turnIDs.contains($0) } ?? true
    }

    private func turnStarted(_ turnID: String?) {
        guard let turnID, !finishedTurns.contains(turnID) else { return }
        if let current = turn {
            // Muse runs a turn it had queued before (or inside) this one; its items are shown with this turn.
            if !current.turnIDs.contains(turnID), !current.compact { turn?.joined.insert(turnID) }
            return
        }
        // Muse started a turn of its own, for example to report on background work that finished.
        var agentTurn = Turn(nativeID: turnID)
        agentTurn.sent = true
        agentTurn.admitted = true
        turn = agentTurn
        emit(.agentTurnStarted(note: String(localized: "\(provider.displayName) continued after background work finished.")))
    }

    private func turnCompleted(_ params: JSONValue) {
        guard let current = turn, !current.compact, let turnID = params["turnId"]?.string, turnID == current.nativeID else {
            // A joined turn ending does not end this one; its own turn does.
            return
        }
        if let usage = params["usage"], usage.object != nil { emit(.usage(Self.tokenUsage(usage, cost: nil))) }
        if current.interruptRequested { return finishTurn(.interrupted) }
        switch params["terminal"]?.string {
        case "completed":
            finishTurn(.completed)
        case "cancelled":
            finishTurn(.interrupted)
        default:
            finishTurn(.failed(failureMessage(params)))
        }
    }

    /// What a failed turn shows: for a quota stop, when the limit lifts (T3's `usage_limit` failures).
    private func failureMessage(_ params: JSONValue) -> String {
        let detail = params.at("error.message")?.string ?? params["reason"]?.string
        let quota = params.at("error.quota")
        if quota?.object != nil || MuseUsageLimits.isUsageLimitFailure(detail) {
            let reset = MuseUsageLimits.resetDate(
                usage: subscriptionUsage, now: Date(), quotaReset: MuseSubscriptionUsage.date(quota?["resetsAtMs"]),
                message: detail)
            return MuseUsageLimits.failureMessage(detail: detail, resetsAt: reset)
        }
        guard let detail = TerminalText.nonEmpty(detail) else {
            return String(localized: "Muse Code could not finish the turn.")
        }
        return MuseProtocol.explained(detail)
    }

    /// Muse could not deliver part of the session's events (`view/gap`), so the transcript may be missing some (T3
    /// treats it as a broken host). The next turn starts a new host, which resumes the session.
    private func deliveryGap() {
        if turn != nil {
            finishTurn(.failed(String(localized: "Muse Code lost part of this turn’s events. Send your message again to continue.")))
        }
        dropConnection()
    }

    // MARK: Prompts

    /// The text, with a note naming each attached image's path, then the images Muse accepts inline.
    private func inputParts(text: String, imagePaths: [String]) throws -> [JSONValue] {
        var parts: [JSONValue] = []
        let body = ACPPrompt.messageText(text, imagePaths: imagePaths)
        if !body.isEmpty { parts.append(["type": "text", "text": .string(body)]) }
        for path in imagePaths {
            guard let mediaType = ACPPrompt.commonImageTypes[(path as NSString).pathExtension.lowercased()],
                let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                (attributes[.size] as? NSNumber)?.intValue ?? 0 <= ACPPrompt.maxImageBytes,
                let data = FileManager.default.contents(atPath: path), !data.isEmpty, data.count <= ACPPrompt.maxImageBytes
            else { continue }
            parts.append(["type": "image", "base64Data": .string(data.base64EncodedString()), "mediaType": .string(mediaType)])
        }
        guard !parts.isEmpty else {
            throw AgentError.providerError(String(localized: "Muse Code needs text or an image."))
        }
        return parts
    }

    // MARK: Notifications

    private func handleNotification(_ method: String, _ params: JSONValue) {
        // The plan's usage is account-wide and names no session.
        if method == "usage/changed" {
            // An unreadable report is skipped, as in T3.
            guard let usage = MuseSubscriptionUsage(params) else { return }
            subscriptionUsage = usage
            emit(.rateLimits(usage.windows))
            return
        }
        guard let sessionID, params["sessionId"]?.string == sessionID else { return }
        switch method {
        case "view/gap":
            deliveryGap()
        case "session/closed":
            // Muse unloaded the session; the next turn resumes it on a new host.
            if turn == nil, params["reason"]?.string != "hostShutdown" { dropConnection() }
        case "session/contextUsage":
            emit(.usage(TokenUsage(inputTokens: params["usedTokens"]?.int, contextWindow: params["windowTokens"]?.int)))
        case "session/tokenUsage":
            guard owns(params["turnId"]?.string), let usage = params["usage"] else { return }
            emit(.usage(Self.tokenUsage(usage, cost: params.at("cumulative.cost.usd")?.number)))
        case "turn/started":
            turnStarted(params["turnId"]?.string)
        case "turn/completed":
            turnCompleted(params)
        case "turn/retryScheduled":
            guard owns(params["turnId"]?.string), let next = params["nextAttempt"]?.int, let total = params["maxAttempts"]?.int
            else { return }
            let reason = params["reason"]?.string ?? ""
            emit(.notice(String(localized: "Muse Code is retrying this turn (attempt \(next) of \(total)): \(reason)")))
        case "item/started", "item/updated", "item/completed":
            handleItem(params["item"])
        case "item/delta":
            guard let itemID = params["itemId"]?.string, let delta = params["delta"]?.string,
                turn != nil || mapper.isBackground(itemID)
            else { return }
            emit(mapper.delta(itemID: itemID, field: params["field"]?.string ?? "text", delta: delta))
        case "session/todoListChanged":
            guard turn != nil, let markdown = MusePresentation.todoMarkdown(params) else { return }
            emit(.plan(text: markdown))
        case "approval/requested", "approval/updated":
            approvalRequested(params, update: method == "approval/updated")
        case "approval/resolved":
            approvalResolved(params["approvalId"]?.string)
        case "userInput/requested":
            questionRequested(params)
        case "userInput/settled":
            questionSettled(params["userInputId"]?.string)
        default:
            break
        }
    }

    /// Requests Muse sends: approvals and questions arrive both as a request (answered empty, as T3 does) and as a
    /// notification, so either one shows the prompt.
    private func handleRequest(_ method: String, _ params: JSONValue) -> JSONValue? {
        switch method {
        case "approval/request":
            approvalRequested(params, update: false)
            return [:]
        case "userInput/request":
            questionRequested(params)
            return [:]
        default:
            return nil
        }
    }

    private func handleItem(_ value: JSONValue?) {
        guard let item = MuseItem(value) else { return }
        if mapper.isBackground(item.id) { return emit(mapper.apply(item)) }
        guard let current = turn else { return }
        if current.compact {
            // While compacting only the compaction counts, whichever turn Muse files it under (T3).
            guard item.kind == "compaction" else { return }
            emit(mapper.apply(item))
            guard !item.isRunning else { return }
            switch MusePresentation.status(item) {
            case .completed: finishTurn(.completed)
            case _ where item.status == "cancelled": finishTurn(.interrupted)
            default:
                let reason = TerminalText.nonEmpty(item.failureReason) ?? item.reason.map { MuseProtocol.compactionReason($0) }
                finishTurn(.failed(reason ?? String(localized: "Muse Code could not compact the conversation.")))
            }
            return
        }
        guard owns(item.turnID) else { return }
        emit(mapper.apply(item))
    }

    private static func tokenUsage(_ usage: JSONValue, cost: Double?) -> TokenUsage {
        TokenUsage(
            outputTokens: usage["outputTokens"]?.int,
            cachedInputTokens: (usage["cacheReadTokens"] ?? usage["cachedTokens"])?.int, costUSD: cost)
    }

    // MARK: Approvals

    private func approvalRequested(_ params: JSONValue, update: Bool) {
        guard let approval = MuseApproval(params), approval.sessionID == sessionID, !settledApprovals.contains(approval.id)
        else { return }
        let fromChild = approval.subagentID != nil
        // The main agent asks during its turn; a workflow child asks under its own run id, at any time (T3).
        if !fromChild, turn?.interruptRequested == true || !owns(approval.turnID) { return }
        if var existing = approvals[approval.id] {
            let changed = existing.approval != approval
            existing.approval = approval
            defer { approvals[approval.id] = existing }
            // Waiting for Muse to settle what was answered.
            if existing.answered == approval.requirement { return }
            if existing.answered != nil {
                // The next stage of a chained command, after the user answered the last: a prompt of its own.
                existing.stage += 1
                existing.requestID = "\(approval.id)#\(existing.stage)"
                existing.answered = nil
            } else if !changed {
                // The same request again (Muse sends it as a request and as a notification).
                return
            }
            // Unanswered, a newer requirement replaces the prompt's choices in place.
            existing.shown = true
            emit(.approvalRequested(approval.request(id: existing.requestID, presentation: mapper.presentation)))
            return
        }
        // `approval/updated` only refines an approval already shown.
        guard !update else { return }
        var pending = PendingApproval(
            approval: approval, requestID: approval.id, answered: nil, turnToken: turn?.token, shown: false)
        // Muse does not pass full access on to workflow children, so Coincide answers for them, as T3 does.
        if fromChild, hostMode?.accessMode == .fullAccess, let accept = approval.choicesByDecision[.accept] {
            approvals[approval.id] = pending
            decide(approval.id, choice: accept)
            return
        }
        pending.shown = true
        approvals[approval.id] = pending
        emit(.approvalRequested(approval.request(id: pending.requestID, presentation: mapper.presentation)))
    }

    /// Sends the choice for the approval's current requirement. Recorded first: Muse can settle the approval before it
    /// acknowledges the command.
    private func decide(_ key: String, choice: MuseApproval.Choice) {
        guard let pending = approvals[key], let connection, let sessionID else { return }
        let requirement = pending.approval.requirement
        approvals[key]?.answered = requirement
        let params: JSONValue = [
            "sessionId": .string(sessionID), "approvalId": .string(pending.approval.id), "requirementId": requirement,
            "choiceId": .string(choice.id),
        ]
        let timeout = timing.request
        Task { [weak self] in
            do {
                _ = try await connection.command("approval/decide", params, timeout: timeout)
            } catch {
                self?.decisionFailed(key, requirement: requirement, error: error)
            }
        }
    }

    /// Muse did not take the decision and still waits, so the prompt is shown again.
    private func decisionFailed(_ key: String, requirement: JSONValue, error: Error) {
        guard var pending = approvals[key], pending.answered == requirement, !isShutDown else { return }
        pending.answered = nil
        pending.shown = true
        approvals[key] = pending
        emit(.notice(String(localized: "Muse Code did not take that answer: \(error.localizedDescription)")))
        emit(.approvalRequested(pending.approval.request(id: pending.requestID, presentation: mapper.presentation)))
    }

    private func approvalResolved(_ id: String?) {
        guard let id else { return }
        settledApprovals.insert(id)
        guard let pending = approvals.removeValue(forKey: id) else { return }
        // Settled by Muse itself (a rule, a timeout, the turn ending): close the prompt the user did not answer.
        if pending.answered == nil, pending.shown { emit(.approvalResolved(id: pending.requestID)) }
    }

    // MARK: Questions

    private func questionRequested(_ params: JSONValue) {
        guard let input = MuseUserInput(params), input.sessionID == sessionID, turn?.interruptRequested != true,
            owns(input.turnID), questions[input.id] == nil, !settledQuestions.contains(input.id)
        else { return }
        questions[input.id] = PendingQuestion(input: input, turnToken: turn?.token)
        emit(.userInputRequested(input.request))
    }

    private func answerFailed(_ id: String, error: Error) {
        guard let pending = questions[id], pending.answered, !isShutDown else { return }
        questions[id]?.answered = false
        emit(.notice(String(localized: "Muse Code did not take that answer: \(error.localizedDescription)")))
        emit(.userInputRequested(pending.input.request))
    }

    private func questionSettled(_ id: String?) {
        guard let id else { return }
        settledQuestions.insert(id)
        guard let pending = questions.removeValue(forKey: id), !pending.answered else { return }
        emit(.userInputResolved(id: id))
    }

    private func emit(_ events: [AgentEvent]) {
        for event in events { emit(event) }
    }

    private func emit(_ event: AgentEvent) {
        guard !isShutDown else { return }
        onEvent?(event)
    }
}
