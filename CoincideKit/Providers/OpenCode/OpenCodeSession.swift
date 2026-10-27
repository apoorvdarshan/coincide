import Foundation

/// A thread's OpenCode session, driven over the HTTP API of a pooled `opencode serve` process.
///
/// Before each turn the session switches OpenCode's agent (build or plan), permission rules and model
/// to match the turn, then sends the prompt; progress arrives on the server's event stream.
@MainActor
final class OpenCodeSession: AgentSession {
    let provider: ProviderKind = .opencode
    private(set) var sessionID: String?
    var onEvent: ((AgentEvent) -> Void)?

    nonisolated static let stillStoppingMessage = String(
        localized: "OpenCode is still stopping the previous turn. Send the message again in a moment.")
    nonisolated static let sessionGoneMessage = String(
        localized: "The OpenCode session no longer exists. Send the message again to continue in a new session.")
    private nonisolated static let unsupportedQuestionNote =
        "Coincide can't show this question. Ask it in plain text in your reply instead."
    private nonisolated static let dismissedQuestionNote =
        "The user dismissed the question without answering. Continue without the answer, or ask in plain text if you need it."
    private nonisolated static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp"]

    private let launch: AgentLaunch
    private var lease: OpenCodeServerLease?
    private var subscription: UUID?
    private var mapper: OpenCodeEventMapper?
    private var api: OpenCodeAPI? { lease?.server.api }
    private var directory: String { launch.workingDirectory.path }

    // What the native session is set to, so a turn only sends changes.
    private var agent = "build"
    private var model: OpenCodeModelRef?
    private var rules: [OpenCodeRule]?
    private var accessMode: AccessMode
    private var needsTitle = false

    /// Actions the user allowed for the rest of the session.
    private var grants: [OpenCodeRule] = []
    /// Path rules of OpenCode's agents by agent id, loaded once approval or plan mode needs them.
    private var agentPaths: [String: [OpenCodeRule]]?
    private var contextWindows: [String: Int] = [:]
    private var shellWatchers: [String: Task<Void, Never>] = [:]
    private var isSending = false
    private var interruptBeforePrompt = false
    /// A turn ended locally while OpenCode was still stopping its execution.
    private var isStopping = false
    private var isClosed = false

    init(launch: AgentLaunch) {
        self.launch = launch
        accessMode = launch.accessMode
    }

    // MARK: AgentSession

    func start() async throws {
        let lease = try await OpenCodeServerPool.shared.borrow(
            executable: launch.executable, environment: launch.environment)
        guard !isClosed else {
            lease.release()
            throw AgentError.notRunning
        }
        self.lease = lease
        subscription = lease.server.subscribe { [weak self] notification in self?.received(notification) }
        let api = lease.server.api
        let directory = directory
        // Context windows for usage; the project's configuration can change them.
        async let models = try? api.models(directory: directory, timeout: 5)
        await loadAgentPathsIfNeeded(accessMode: launch.accessMode, mode: launch.interactionMode, api: api)

        let id: String
        if let resumeID = launch.resumeSessionID, await resume(resumeID, api: api) {
            id = resumeID
        } else {
            let agent = OpenCodePermissions.agent(for: launch.interactionMode)
            let requested = OpenCodeModelRef(selection: launch.selection)
            let initialRules = self.rules(accessMode: launch.accessMode, mode: launch.interactionMode)
            let session = try await api.createSession(
                directory: directory, model: requested, agent: agent, permissions: initialRules)
            id = session["id"]?.string ?? ""
            self.agent = agent
            rules = initialRules
            model = OpenCodeModelRef(json: session["model"]) ?? requested
            needsTitle = true
        }
        contextWindows = OpenCodeCatalog.contextWindows(from: await models ?? [])
        guard !isClosed else { throw AgentError.notRunning }
        sessionID = id
        var mapper = OpenCodeEventMapper(sessionID: id)
        mapper.contextWindow = model.flatMap { contextWindows[$0.slug] }
        mapper.paths = PathDisplay(workingDirectory: directory)
        self.mapper = mapper
        emit(.sessionStarted(id: id))
        if let resumeID = launch.resumeSessionID, resumeID != id {
            emit(.notice(String(localized: "Couldn't resume the earlier OpenCode session, so a new one was started.")))
        }
    }

    func send(_ input: AgentTurnInput) async throws {
        guard !isClosed, let api, let sessionID, mapper != nil else { throw AgentError.notRunning }
        guard mapper?.turn == nil, !isSending else {
            throw AgentError.providerError(String(localized: "OpenCode is already working on a turn in this thread."))
        }
        isSending = true
        interruptBeforePrompt = false
        mapper?.preparingPrompt = true
        defer {
            isSending = false
            mapper?.preparingPrompt = false
        }

        do {
            if isStopping { try await waitForStop(api: api, sessionID: sessionID) }
            try await apply(input, api: api, sessionID: sessionID)
        } catch let error as OpenCodeAPIError where error.isSessionNotFound {
            sessionLost(Self.sessionGoneMessage)
            throw AgentError.providerError(Self.sessionGoneMessage)
        }
        guard !isClosed else { throw AgentError.notRunning }

        let promptID = Self.newPromptID()
        mapper?.beginTurn(promptID: promptID)
        if interruptBeforePrompt {
            endTurnLocally(.interrupted)
            return
        }
        let content = Self.promptContent(text: input.text, imagePaths: input.imagePaths)
        do {
            try await api.prompt(sessionID, messageID: promptID, text: content.text, files: content.files)
        } catch {
            guard mapper?.turn?.promptID == promptID else { return }
            mapper?.abandonTurn()
            if let error = error as? OpenCodeAPIError, error.isSessionNotFound {
                sessionLost(Self.sessionGoneMessage)
                throw AgentError.providerError(Self.sessionGoneMessage)
            }
            throw error
        }
        if mapper?.turn?.promptID != promptID || mapper?.turn?.interruptRequested == true {
            // Stop was pressed while the prompt was on its way and may have missed it.
            Task {
                _ = try? await api.interrupt(sessionID, timeout: 3)
                try? await api.cancelInbox(sessionID, inboxID: promptID, timeout: 2)
            }
        }
    }

    func respond(to approvalID: String, optionID: String) {
        guard !isClosed, let api, case .permission(let action, let resources, let save)? = mapper?.pending[approvalID]?.kind
        else { return }
        let declined = optionID == OpenCodePermissions.denyOptionID || optionID == OpenCodePermissions.stopOptionID
        guard let request = mapper?.resolve(approvalID, declined: declined) else { return }
        Task {
            await deliver {
                try await self.answerPermission(
                    request, action: action, resources: resources, save: save, optionID: optionID, api: api)
            }
        }
    }

    func answer(userInput requestID: String, answers: [String: [String]]) {
        guard !isClosed, let api, case .form(let fields)? = mapper?.pending[requestID]?.kind,
            let request = mapper?.resolve(requestID, declined: false)
        else { return }
        let answer = OpenCodeQuestions.answer(answers, fields: fields)
        Task {
            await deliver {
                guard !answer.isEmpty else {
                    try await self.retrying {
                        try await api.cancelForm(
                            sessionID: request.sessionID, formID: request.id, message: Self.dismissedQuestionNote)
                    }
                    return
                }
                do {
                    try await self.retrying {
                        try await api.replyForm(sessionID: request.sessionID, formID: request.id, answer: answer)
                    }
                } catch let error as OpenCodeAPIError where error.status == 400 {
                    // OpenCode refused the answer (for example a required question was left empty).
                    let note = "The user's answer could not be used (\(error.message)). Ask again in plain text."
                    try await self.retrying {
                        try await api.cancelForm(sessionID: request.sessionID, formID: request.id, message: note)
                    }
                }
            }
        }
    }

    func interrupt() {
        guard !isClosed, let api, let sessionID else { return }
        guard let promptID = mapper?.turn?.promptID else {
            // Stop arrived while the turn's settings were being applied; end it before prompting.
            if isSending { interruptBeforePrompt = true }
            // Work OpenCode started itself ends with its execution, as interrupted.
            if !isSending, mapper?.agentExecution == false {
                mapper?.requestInterrupt()
                Task { _ = try? await api.interrupt(sessionID, timeout: 3) }
            }
            return
        }
        mapper?.requestInterrupt()
        // ThreadRunner gives up after six seconds, so this ends the turn itself within that time.
        Task {
            let interrupted = try? await api.interrupt(sessionID, timeout: 3)
            guard mapper?.turn?.promptID == promptID else { return }
            if interrupted != true, mapper?.turn?.delivered == false {
                // Nothing ran yet: withdraw the queued prompt so it does not start later.
                try? await api.cancelInbox(sessionID, inboxID: promptID, timeout: 2)
            }
            try? await Task.sleep(for: .milliseconds(interrupted == true ? 2_500 : 500))
            guard mapper?.turn?.promptID == promptID else { return }
            endTurnLocally(.interrupted)
        }
    }

    func shutdown() {
        guard !isClosed else { return }
        if let api, let sessionID, mapper?.turn != nil || mapper?.executionRunning == true {
            // The pooled server outlives this session, so stop its work before letting go.
            Task { _ = try? await api.interrupt(sessionID, timeout: 2) }
        }
        close()
        onEvent = nil
    }

    // MARK: Turns

    /// Switches agent, permission rules and model when the turn asks for different ones.
    private func apply(_ input: AgentTurnInput, api: OpenCodeAPI, sessionID: String) async throws {
        accessMode = input.accessMode
        await loadAgentPathsIfNeeded(accessMode: input.accessMode, mode: input.interactionMode, api: api)
        let agent = OpenCodePermissions.agent(for: input.interactionMode)
        if agent != self.agent {
            try await api.switchAgent(sessionID, agent: agent)
            self.agent = agent
        }
        let desired = self.rules(accessMode: input.accessMode, mode: input.interactionMode)
        if desired != rules {
            try await api.updateSession(sessionID, permissions: desired)
            rules = desired
        }
        if let model = OpenCodeModelRef(selection: input.selection), !model.isSameModel(as: self.model) {
            try await api.switchModel(sessionID, model: model)
            self.model = model
        }
        if contextWindows.isEmpty {
            // A cold server may not have listed its models when the session started.
            let models = (try? await api.models(directory: directory, timeout: 5)) ?? []
            contextWindows = OpenCodeCatalog.contextWindows(from: models)
        }
        mapper?.contextWindow = model.flatMap { contextWindows[$0.slug] }
        if needsTitle {
            // A titled session is not renamed by OpenCode's own model, which saves a request.
            needsTitle = false
            if let title = Self.title(threadTitle: input.threadTitle, message: input.message) {
                try? await api.updateSession(sessionID, title: title)
            }
        }
    }

    private func rules(accessMode: AccessMode, mode: InteractionMode) -> [OpenCodeRule] {
        OpenCodePermissions.rules(
            accessMode: accessMode, plan: mode == .plan, grants: grants,
            agentPaths: agentPaths?[OpenCodePermissions.agent(for: mode)] ?? [])
    }

    /// Gives an execution the user stopped a moment to end, so the next prompt does not join it.
    private func waitForStop(api: OpenCodeAPI, sessionID: String) async throws {
        for _ in 0..<12 where isStopping {
            try await Task.sleep(for: .milliseconds(250))
        }
        guard isStopping else { return }
        _ = try? await api.interrupt(sessionID, timeout: 3)
        if let active = try? await api.activeSessions(), !active.contains(sessionID) { isStopping = false }
        if isStopping { throw AgentError.providerError(Self.stillStoppingMessage) }
    }

    private func endTurnLocally(_ outcome: TurnOutcome) {
        isStopping = mapper?.executionRunning == true
        stopShellWatchers()
        if let event = mapper?.endTurn(outcome) { emit(event) }
    }

    /// Sends the user's answer. OpenCode waits on an unanswered request forever, so if the answer cannot
    /// be delivered the turn is stopped rather than left hanging.
    private func deliver(_ reply: () async throws -> Void) async {
        do {
            try await reply()
        } catch {
            emit(.notice(String(localized: "Coincide could not send your answer to OpenCode: \(error.localizedDescription)")))
            interrupt()
        }
    }

    private func answerPermission(
        _ request: OpenCodeEventMapper.PendingRequest, action: String, resources: [String], save: [String],
        optionID: String, api: OpenCodeAPI
    ) async throws {
        switch optionID {
        case OpenCodePermissions.allowForSessionOptionID:
            for pattern in save {
                let grant = OpenCodeRule(action, "allow", resource: pattern)
                if !grants.contains(grant) { grants.append(grant) }
            }
            if let sessionID, accessMode == .approval {
                let mode: InteractionMode = agent == "plan" ? .plan : .build
                let updated = self.rules(accessMode: accessMode, mode: mode)
                if updated != rules {
                    try? await api.updateSession(sessionID, permissions: updated)
                    rules = updated
                }
                if request.sessionID != sessionID {
                    try? await api.updateSession(request.sessionID, permissions: updated)
                }
            }
            try await retrying {
                try await api.replyPermission(sessionID: request.sessionID, requestID: request.id, decision: "once")
            }
        case OpenCodePermissions.denyOptionID:
            // Without a note the model only sees a failed call and tends to retry it.
            try? await api.steer(request.sessionID, text: OpenCodePermissions.declinedNote(action: action, resources: resources))
            try await retrying {
                try await api.replyPermission(
                    sessionID: request.sessionID, requestID: request.id, decision: "reject",
                    message: OpenCodePermissions.declinedMessage)
            }
        case OpenCodePermissions.stopOptionID:
            // A rejection without a message stops the whole turn.
            try await retrying {
                try await api.replyPermission(sessionID: request.sessionID, requestID: request.id, decision: "reject")
            }
        default:
            try await retrying {
                try await api.replyPermission(sessionID: request.sessionID, requestID: request.id, decision: "once")
            }
        }
    }

    /// Runs a reply, once more after a transport or server error. A request that is already settled
    /// (answered elsewhere, or its turn ended) needs no reply.
    private func retrying(_ operation: () async throws -> Void) async throws {
        do {
            try await operation()
        } catch let error as OpenCodeAPIError where error.isSettled {
        } catch let error as OpenCodeAPIError where (error.status ?? 500) >= 500 {
            try await operation()
        }
    }

    // MARK: Events

    private func received(_ notification: OpenCodeServer.Notification) {
        guard !isClosed else { return }
        switch notification {
        case .event(let event):
            guard mapper != nil else { return }
            let effects = mapper?.handle(event) ?? []
            if mapper?.executionRunning == false { isStopping = false }
            perform(effects)
        case .reconnected:
            Task { await reconcile() }
        case .terminated(let reason):
            sessionLost(reason)
        }
    }

    private func perform(_ effects: [OpenCodeEventMapper.Effect]) {
        for effect in effects {
            guard !isClosed else { return }
            switch effect {
            case .event(let event):
                if case .approvalRequested(let request) = event, accessMode == .fullAccess,
                    case .permission? = mapper?.pending[request.id]?.kind
                {
                    // Full access means no prompts; allow anything an agent's own rules still ask about.
                    respond(to: request.id, optionID: OpenCodePermissions.allowOptionID)
                    continue
                }
                if case .turnCompleted = event { stopShellWatchers() }
                emit(event)
            case .watchShell(let toolID, let shellID):
                watchShell(toolID: toolID, shellID: shellID)
            case .unwatchShell(let toolID):
                shellWatchers.removeValue(forKey: toolID)?.cancel()
            case .declineForm(let asker, let formID):
                guard let api else { continue }
                Task { try? await api.cancelForm(sessionID: asker, formID: formID, message: Self.unsupportedQuestionNote) }
            case .cancelPrompt(let messageID):
                guard let api, let sessionID else { continue }
                Task { try? await api.cancelInbox(sessionID, inboxID: messageID) }
            case .sessionDeleted:
                sessionLost(Self.sessionGoneMessage)
            }
        }
    }

    /// After the event stream was restored, settles a turn that ended while events were missed.
    private func reconcile() async {
        guard let api, let sessionID, mapper?.turn != nil || mapper?.agentExecution != nil else { return }
        guard let active = try? await api.activeSessions(), !active.contains(sessionID) else { return }
        guard !isClosed else { return }
        if mapper?.turn == nil {
            // A turn OpenCode started itself ended while the event stream was down.
            if let end = mapper?.endAgentExecution() { emit(end) }
            return
        }
        let messages = (try? await api.messages(sessionID, newestFirst: true, limit: 50)) ?? []
        guard !isClosed, mapper?.turn != nil else { return }
        perform(mapper?.backfill(newestFirst: messages) ?? [])
    }

    /// Polls a running command's output, since OpenCode reports it only when the command finishes.
    private func watchShell(toolID: String, shellID: String) {
        guard shellWatchers[toolID] == nil, let api else { return }
        let directory = directory
        shellWatchers[toolID] = Task { [weak self] in
            var cursor = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(700))
                guard !Task.isCancelled else { return }
                guard let chunk = try? await api.shellOutput(shellID, directory: directory, cursor: cursor) else { return }
                guard !Task.isCancelled else { return }
                cursor = chunk.cursor
                if !chunk.output.isEmpty { self?.emit(.toolOutput(id: toolID, delta: chunk.output)) }
            }
        }
    }

    private func stopShellWatchers() {
        for task in shellWatchers.values { task.cancel() }
        shellWatchers = [:]
    }

    private func emit(_ event: AgentEvent) {
        guard !isClosed else { return }
        onEvent?(event)
    }

    /// The session or its server is gone; ends a running turn, reports the exit once and lets go.
    private func sessionLost(_ reason: String) {
        guard !isClosed else { return }
        let handler = onEvent
        let end = mapper?.endTurn(.failed(reason))
        close()
        onEvent = nil
        if let end { handler?(end) }
        handler?(.sessionExited(error: reason))
    }

    private func close() {
        isClosed = true
        stopShellWatchers()
        if let subscription { lease?.server.unsubscribe(subscription) }
        subscription = nil
        lease?.release()
        lease = nil
    }

    // MARK: Setup

    /// Loads the agents' path rules (such as the plan agent's plan folder) when the session's rules
    /// need them. Full access in build mode does not.
    private func loadAgentPathsIfNeeded(accessMode: AccessMode, mode: InteractionMode, api: OpenCodeAPI) async {
        guard agentPaths == nil, accessMode == .approval || mode == .plan else { return }
        let agents = await Self.agents(api: api, directory: directory)
        if !agents.isEmpty { agentPaths = OpenCodePermissions.agentPaths(fromAgents: agents) }
    }

    /// A fresh server lists no agents for its first moments.
    private nonisolated static func agents(api: OpenCodeAPI, directory: String) async -> [JSONValue] {
        for attempt in 0..<12 {
            if attempt > 0 { try? await Task.sleep(for: .milliseconds(250)) }
            if let agents = try? await api.agents(directory: directory), !agents.isEmpty { return agents }
        }
        return []
    }

    /// Picks up an existing session in this directory. False when it cannot be resumed.
    private func resume(_ id: String, api: OpenCodeAPI) async -> Bool {
        guard let session = try? await api.session(id) else { return false }
        if let current = session.at("location.directory")?.string, !Self.sameDirectory(current, directory) {
            do {
                try await api.moveSession(id, directory: directory)
            } catch {
                return false
            }
        }
        agent = session["agent"]?.string ?? "build"
        model = OpenCodeModelRef(json: session["model"])
        rules = session["permissions"]?.array?.compactMap(OpenCodeRule.init(json:))
        // Requests left from an earlier run can no longer be answered here; stop them so OpenCode does
        // not wait on them.
        for request in (try? await api.pendingPermissions(id)) ?? [] {
            guard let requestID = request["id"]?.string else { continue }
            try? await api.replyPermission(sessionID: id, requestID: requestID, decision: "reject")
        }
        for form in (try? await api.pendingForms(id)) ?? [] {
            guard let formID = form["id"]?.string else { continue }
            try? await api.cancelForm(sessionID: id, formID: formID, message: nil)
        }
        return true
    }

    // MARK: Helpers

    nonisolated static func newPromptID() -> String {
        "msg_coincide_" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
    }

    /// The prompt text, with a note per attached image, and the images OpenCode can pass to the model.
    nonisolated static func promptContent(text: String, imagePaths: [String]) -> (text: String, files: [JSONValue]) {
        var parts = text.isEmpty ? [] : [text]
        var files: [JSONValue] = []
        for path in imagePaths {
            let url = URL(fileURLWithPath: path)
            let name = url.lastPathComponent
            guard FileManager.default.fileExists(atPath: path) else {
                parts.append("[Attached image \"\(name)\" is unavailable: \(path) was not found.]")
                continue
            }
            parts.append("[Attached image \"\(name)\" is saved at: \(path)]")
            if imageExtensions.contains(url.pathExtension.lowercased()) {
                files.append(["uri": .string(url.absoluteString), "name": .string(name)])
            }
        }
        return (parts.joined(separator: "\n\n"), files)
    }

    /// A title for a new session: the thread's, or one made from the user's message (never the handoff recap).
    static func title(threadTitle: String?, message: String) -> String? {
        if let threadTitle = threadTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !threadTitle.isEmpty {
            return threadTitle
        }
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : ThreadRunner.title(from: trimmed)
    }

    nonisolated static func sameDirectory(_ lhs: String, _ rhs: String) -> Bool {
        canonicalPath(lhs) == canonicalPath(rhs)
    }

    /// The path with symlinks resolved (for example /tmp to /private/tmp) when it exists.
    private nonisolated static func canonicalPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return URL(fileURLWithPath: path).standardizedFileURL.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
