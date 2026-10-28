import Foundation

/// A live Agent Client Protocol session bound to one Coincide thread, generic over the agent
/// (see `ACPAgentFlavor` for what an agent can customize).
///
/// It spawns the agent, runs the handshake, resumes the thread's native session when it can,
/// applies the turn's model, effort, access and interaction mode before each prompt, and maps
/// the agent's updates, approvals, questions, elicitations and extensions to `AgentEvent`s.
/// Every turn ends with exactly one `.turnCompleted`.
@MainActor
public final class ACPSession: AgentSession {
    public let provider: ProviderKind
    public private(set) var sessionID: String?
    public var onEvent: ((AgentEvent) -> Void)?

    /// How long a `.cancel` interrupt waits for the agent to confirm before the turn ends anyway
    /// and the process is replaced. Defaults to the flavor's.
    public var cancelTimeout: TimeInterval
    /// Quiet time after the last replayed update that ends a `session/load` the agent never answers.
    public var replayIdleGap: TimeInterval = 2

    private struct Turn {
        let promptID: String
        var interrupting = false
        var cancelTimer: Task<Void, Never>?
        /// The user approved a command in this turn, so client terminals may run.
        var approvedCommand = false
    }

    /// A request from the agent that waits for the user.
    private enum Pending {
        case approval(ACPConnection.IncomingRequest, toolCallID: String, options: [ACPPermissionOption], kind: String)
        case question(ACPConnection.IncomingRequest, ACPQuestionSet, isElicitation: Bool)

        var request: ACPConnection.IncomingRequest {
            switch self {
            case .approval(let request, _, _, _), .question(let request, _, _): request
            }
        }
    }

    /// The configuration plan mode replaced, restored when the thread builds again.
    private struct BuildConfiguration {
        var modeID: String?
        var options: [String: String]
    }

    /// Tracks a `session/load` so replayed history is dropped and a load the agent never
    /// answers still ends once the replay goes quiet.
    @MainActor
    private final class LoadGate {
        let sessionID: String
        var lastActivity: Date?
        var candidateOptions: [ACPConfigOption]?
        private var continuation: CheckedContinuation<ACPSessionSetup, Error>?

        init(sessionID: String) {
            self.sessionID = sessionID
        }

        var isFinished: Bool { continuation == nil }

        func wait(_ continuation: CheckedContinuation<ACPSessionSetup, Error>) {
            self.continuation = continuation
        }

        func finish(_ result: Result<ACPSessionSetup, Error>) {
            guard let continuation else { return }
            self.continuation = nil
            continuation.resume(with: result)
        }
    }

    private nonisolated static let sessionTimeout: TimeInterval = 60
    private nonisolated static let loadTimeout: TimeInterval = 90
    private nonisolated static let configTimeout: TimeInterval = 30
    private nonisolated static let closeTimeout: TimeInterval = 2
    private nonisolated static let maxStartupUpdates = 32

    private let launch: AgentLaunch
    private let flavor: ACPAgentFlavor
    private let makeTransport: ACPTransportFactory

    private var transport: ACPTransport?
    private var client: ACPClient?
    private var terminals: ACPTerminals?
    private var initialized: ACPInitializeResult?
    private var setup = ACPSessionSetup()
    private var mapper: ACPEventMapper
    private var launchedAccessMode: AccessMode
    private var accessMode: AccessMode
    private var savedBuild: BuildConfiguration?
    /// The reasoning effort last chosen or reported outside the config options (Grok).
    private var legacyEffort: String?
    /// The interaction mode each native session was last told about.
    private var instructedModes: [String: InteractionMode] = [:]
    private var publishedModels: [ModelOption] = []
    private var contextTokens: Int?
    private var turnUsage = TokenUsage()
    private var loadGate: LoadGate?
    /// Configuration updates that arrived before the agent answered `session/new` or `session/load`.
    private var startupUpdates: [ACPSessionNotification] = []
    private var launching = false
    private var needsRestart = false
    private var isShutDown = false
    /// How many times a new native session was created instead of an earlier one continued.
    private var newConversations = 0
    /// A prompt the agent runs by itself between Coincide's turns (Grok's background wakes), shown as a turn
    /// the agent started. True once it is being stopped.
    private var backgroundTurn: Bool?
    /// Each `send` gets a generation. A newer one supersedes an older one that is still
    /// preparing (the runner gave up on that turn), and the older one then stops silently.
    private var sendGeneration = 0
    /// The generation of the `send` that is setting up its turn, if any.
    private var preparingGeneration: Int?
    /// A `send` the user stopped before its prompt reached the agent.
    private var interruptedGeneration: Int?
    private var commandsApprovedForSession = false
    private var turn: Turn?
    private var pending: [String: Pending] = [:]
    private var requestCount = 0
    private var stderrTail = ""
    private var stderrLine = ""
    private var shownNotices: Set<String> = []
    private var temporaryDirectory: URL?
    /// What `prepareLaunch` handed out for the running process, released once it has ended.
    private var launchLease: ACPLaunchLease?
    /// When this session last read the plan's usage windows (see `reportUsageLimits`).
    private var usageLimitsRead: Date?

    public init(launch: AgentLaunch, flavor: ACPAgentFlavor, transport: ACPTransportFactory? = nil) {
        self.launch = launch
        self.flavor = flavor
        provider = launch.provider
        makeTransport = transport ?? { executable, arguments, directory, environment in
            ACPProcessTransport(executable: executable, arguments: arguments, workingDirectory: directory, environment: environment)
        }
        mapper = ACPEventMapper(workingDirectory: launch.workingDirectory)
        launchedAccessMode = launch.accessMode
        accessMode = launch.accessMode
        cancelTimeout = flavor.cancelTimeout
    }

    // MARK: AgentSession

    public func start() async throws {
        try await open(resuming: launch.resumeSessionID, accessMode: launch.accessMode)
    }

    public func send(_ input: AgentTurnInput) async throws {
        guard !isShutDown else { throw AgentError.notRunning }
        sendGeneration += 1
        let generation = sendGeneration
        // Work the agent started by itself is no longer reported as a turn of its own.
        backgroundTurn = nil
        // An earlier send may still be setting up a turn the runner gave up on; it stops at its
        // next step. Never throw for a superseded send: the runner would fail the newer turn.
        while preparingGeneration != nil {
            try? await Task.sleep(for: .milliseconds(20))
            guard generation == sendGeneration else { return }
        }
        guard !isShutDown else { throw AgentError.notRunning }
        preparingGeneration = generation
        defer { if preparingGeneration == generation { preparingGeneration = nil } }
        if let stale = turn {
            // The runner gave up on a turn the agent never confirmed; start from a fresh process.
            stale.cancelTimer?.cancel()
            turn = nil
            cancelPending()
            needsRestart = true
        }
        let conversations = newConversations
        if transport == nil || needsRestart || (flavor.accessModeNeedsRestart && input.accessMode != launchedAccessMode) {
            let resumeID = sessionID ?? launch.resumeSessionID
            stopProcess()
            needsRestart = false
            try await open(resuming: resumeID, accessMode: input.accessMode)
            guard generation == sendGeneration else { return }
        }
        guard let client, let sessionID else { throw AgentError.notRunning }
        try await applySelection(input.selection, client: client, sessionID: sessionID)
        guard generation == sendGeneration else { return }
        accessMode = input.accessMode
        try await applyInteractionMode(input.interactionMode, client: client, sessionID: sessionID)
        guard generation == sendGeneration else { return }
        try await applyAccessMode(input.accessMode, client: client, sessionID: sessionID)
        guard generation == sendGeneration else { return }
        guard interruptedGeneration != generation else {
            // The user stopped the turn while it was being set up; nothing reached the agent yet.
            emit(.turnCompleted(.interrupted))
            return
        }
        guard self.client === client, !isShutDown else { throw AgentError.notRunning }

        // A restart that could not resume the session created a new one, which needs the whole recap.
        let recap = input.recap(forNewSession: newConversations != conversations)
        let texts = ACPPrompt.texts(
            message: ACPPrompt.messageText(input.message, imagePaths: input.imagePaths), recap: recap,
            mode: input.interactionMode, previousMode: instructedModes[sessionID])
        if texts.instructed { instructedModes[sessionID] = input.interactionMode }
        let inline = flavor.supportsImagePrompts || initialized?.promptImage == true
        let images = inline ? input.imagePaths.compactMap { ACPPrompt.imageBlock($0, types: flavor.imageTypes) } : []

        let promptID = UUID().uuidString.lowercased()
        turn = Turn(promptID: promptID)
        mapper.beginTurn()
        contextTokens = nil
        turnUsage = TokenUsage()
        let blocks = texts.blocks.map { ACPContentBlock.text($0) } + images
        client.prompt(sessionID: sessionID, blocks: blocks, meta: flavor.promptMeta(promptID: promptID)) {
            [weak self] result in
            self?.promptFinished(promptID, result)
        }
    }

    public func respond(to approvalID: String, optionID: String) {
        guard let entry = pending[approvalID] else { return }
        if case .question(_, let set, _) = entry {
            // Answering a question as an approval picks that option for its first question.
            let answers = optionID == ACPApprovals.cancelOptionID ? [:] : set.questions.first.map { [$0.id: [optionID]] } ?? [:]
            answer(userInput: approvalID, answers: answers)
            return
        }
        guard case .approval(let request, let toolCallID, let options, let kind) = entry, let client else { return }
        pending[approvalID] = nil
        let option = options.first { $0.id == optionID }
        client.respondToPermission(request, optionID: option?.id)
        guard let option, option.isAllow else {
            emit(mapper.markDeclined(toolCallID))
            return
        }
        if kind == "execute" {
            turn?.approvedCommand = true
            if option.kind == .allowAlways { commandsApprovedForSession = true }
        }
    }

    public func answer(userInput requestID: String, answers: [String: [String]]) {
        guard case .question(let request, let set, let isElicitation)? = pending.removeValue(forKey: requestID) else { return }
        reply(to: request, set, answers: answers.isEmpty ? nil : answers, isElicitation: isElicitation)
    }

    public func interrupt() {
        guard var current = turn, !current.interrupting else {
            // The runner's turn belongs to the newest send, which may still be setting up.
            if turn == nil && preparingGeneration != nil {
                interruptedGeneration = sendGeneration
            } else if turn == nil, backgroundTurn == false {
                stopBackgroundTurn()
            }
            return
        }
        current.interrupting = true
        turn = current
        cancelPending()
        guard let client, let sessionID else {
            finishTurn(.interrupted)
            return
        }
        switch flavor.interruptStyle {
        case .terminate:
            finishTurn(.interrupted)
            stopProcess()
            needsRestart = true
        case .cancel:
            client.cancel(sessionID: sessionID, meta: flavor.cancelMeta)
            let promptID = current.promptID
            turn?.cancelTimer = Task { [weak self, timeout = cancelTimeout] in
                try? await Task.sleep(for: .seconds(timeout))
                guard !Task.isCancelled, let self, self.turn?.promptID == promptID else { return }
                // The agent did not confirm; end the turn and replace the process.
                self.finishTurn(.interrupted)
                self.stopProcess()
                self.needsRestart = true
            }
        }
    }

    public func shutdown() {
        guard !isShutDown else { return }
        isShutDown = true
        turn?.cancelTimer?.cancel()
        turn = nil
        backgroundTurn = nil
        cancelPending()
        guard let transport, let client, let sessionID, initialized?.closeSession == true, !launching,
            !client.connection.isClosed
        else {
            stopProcess()
            return
        }
        // Let the agent close the session (its hooks and history), then stop the process.
        // The completion keeps the client and transport alive until then.
        detach(transport, client: client)
        transport.onLine = { [weak connection = client.connection] in connection?.receive($0) }
        client.closeSession(id: sessionID, timeout: Self.closeTimeout) { [client, transport] in
            transport.terminate()
            client.connection.close(with: AgentError.notRunning)
        }
        self.transport = nil
        self.client = nil
        terminals?.disposeAll()
        terminals = nil
        removeTemporaryDirectory(after: Self.closeTimeout + 4)
    }

    // MARK: Process and handshake

    private func open(resuming resumeID: String?, accessMode: AccessMode) async throws {
        guard !isShutDown else { throw AgentError.notRunning }
        launching = true
        defer { launching = false }
        do {
            let lease = try await flavor.prepareLaunch(executable: launch.executable, environment: launch.environment)
            guard !isShutDown else {
                lease?.release()
                throw AgentError.notRunning
            }
            try await handshake(resuming: resumeID, client: spawn(accessMode: accessMode, lease: lease))
        } catch {
            // A half-open process must not serve the next turn.
            stopProcess()
            needsRestart = true
            throw error
        }
    }

    private func handshake(resuming resumeID: String?, client: ACPClient) async throws {
        startupUpdates.removeAll()
        initialized = try await client.initialize(
            capabilities: flavor.clientCapabilities, clientInfo: Self.clientInfo, meta: flavor.initializeMeta,
            timeout: flavor.initializeTimeout)
        if flavor.authenticatesEagerly, let method = flavor.authMethodID(environment: launch.environment) {
            // The configured method decides the credential source, even when the agent does not list it.
            try await client.authenticate(methodID: method, timeout: flavor.authenticateTimeout)
        }
        if let resumeID {
            do {
                try await reopen(resumeID, client: client)
                return
            } catch {
                guard !client.connection.isClosed, !isShutDown,
                    (error as? ACPError)?.code != ACPError.authRequired
                else { throw error }
                emit(.notice(String(localized: "Couldn't resume the earlier \(provider.displayName) session, so a new one was started.")))
            }
        }
        let created = try await authenticated(client) {
            try await client.newSession(cwd: self.launch.workingDirectory, timeout: Self.sessionTimeout)
        }
        newConversations += 1
        adopt(created, id: created.sessionID ?? "", continued: false)
    }

    private func reopen(_ id: String, client: ACPClient) async throws {
        let canResume = initialized?.resumeSession == true
        let canLoad = initialized?.loadSession == true
        let reopened: ACPSessionSetup
        if canResume && (flavor.prefersResume || !canLoad) {
            reopened = try await authenticated(client) {
                try await client.resumeSession(id: id, cwd: self.launch.workingDirectory, timeout: Self.sessionTimeout)
            }
        } else if canLoad {
            reopened = try await authenticated(client) { try await self.load(id, client: client) }
        } else {
            throw AgentError.providerError(String(localized: "\(provider.displayName) cannot resume sessions."))
        }
        // An agent may answer with a new id that still holds the whole conversation.
        if let newID = reopened.sessionID.flatMap(ACPToolCallState.nonEmpty), newID != id {
            adopt(reopened, id: newID, continued: true)
        } else {
            adopt(reopened, id: id, continued: false)
        }
    }

    /// `session/load` drops the history the agent replays (the transcript already has it). The
    /// agent should answer once it has replayed everything; when it never does, the load ends
    /// after `replayIdleGap` without replayed updates.
    private func load(_ id: String, client: ACPClient) async throws -> ACPSessionSetup {
        let gate = LoadGate(sessionID: id)
        loadGate = gate
        defer { if loadGate === gate { loadGate = nil } }
        var setup = try await withCheckedThrowingContinuation { continuation in
            gate.wait(continuation)
            client.loadSession(id: id, cwd: launch.workingDirectory, timeout: Self.loadTimeout) { [weak self] result in
                // Runs as the response is read, so updates after it are no longer replay.
                if self?.loadGate === gate { self?.loadGate = nil }
                if gate.isFinished, case .success(let late) = result {
                    // The load already ended on a quiet replay; keep what the answer reports.
                    self?.mergeLateLoad(late, id: id)
                }
                gate.finish(result)
            }
            Task { [weak self] in
                while !gate.isFinished {
                    try? await Task.sleep(for: .milliseconds(100))
                    guard let self, !gate.isFinished else { return }
                    if let last = gate.lastActivity, Date().timeIntervalSince(last) >= self.replayIdleGap {
                        if self.loadGate === gate { self.loadGate = nil }
                        gate.finish(.success(ACPSessionSetup()))
                    }
                }
            }
        }
        if setup.configOptions.isEmpty, let candidate = gate.candidateOptions { setup.configOptions = candidate }
        return setup
    }

    private func mergeLateLoad(_ late: ACPSessionSetup, id: String) {
        guard sessionID == id else { return }
        if let modes = late.modes { setup.modes = modes }
        if let models = late.models { setup.models = models }
        if !late.configOptions.isEmpty { setup.configOptions = late.configOptions }
        publishModels()
    }

    /// Runs `body`, signing in and retrying once when the agent answers `auth_required`.
    private func authenticated<T>(_ client: ACPClient, _ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let error as ACPError
            where error.code == ACPError.authRequired && flavor.authenticatesWhenRequired && !flavor.authenticatesEagerly
        {
            guard let method = signInMethod() else { throw error }
            try await client.authenticate(methodID: method, timeout: flavor.authenticateTimeout)
            return try await body()
        }
    }

    /// The flavor's method when the agent lists it (or lists none), otherwise the first method
    /// the agent completes by itself. Methods that need a terminal or typed credentials cannot
    /// run here, so the original error stands.
    private func signInMethod() -> String? {
        let configured = flavor.authMethodID(environment: launch.environment)
        guard let agent = initialized, !agent.authMethods.isEmpty else { return configured }
        guard let method = agent.authMethod(preferring: configured), method.isAgentDriven else { return nil }
        return method.id
    }

    private func adopt(_ opened: ACPSessionSetup, id: String, continued: Bool) {
        if id != sessionID {
            savedBuild = nil
            legacyEffort = nil
        }
        sessionID = id
        setup = opened
        setup.sessionID = id
        // Configuration the agent reported before it answered.
        let early = startupUpdates.filter { $0.sessionID == id }
        startupUpdates.removeAll()
        early.forEach { applyConfiguration($0.update) }
        emit(continued ? .sessionContinued(id: id) : .sessionStarted(id: id))
        if let model = setup.currentModelID ?? initialized?.modelState?.currentModelID { emit(.modelResolved(model)) }
        publishModels()
        reportUsageLimits()
    }

    /// How often a session reads the plan's usage windows again: T3 Code checks providers this often.
    nonisolated static let usageLimitsInterval: TimeInterval = 5 * 60

    /// Reads the plan's usage windows (`ACPAgentFlavor.usageLimits`) when the session starts and after its turns, at
    /// most every `usageLimitsInterval`, so the composer's meter stays current as Codex's does: ACP agents do not
    /// report their limits themselves. Only windows read are reported; a failed read changes nothing.
    private func reportUsageLimits() {
        if let usageLimitsRead, Date().timeIntervalSince(usageLimitsRead) < Self.usageLimitsInterval { return }
        usageLimitsRead = Date()
        Task { [weak self, flavor, environment = launch.environment] in
            guard let windows = await flavor.usageLimits(environment: environment)?.limits?.windows, !windows.isEmpty else {
                return
            }
            self?.emit(.rateLimits(windows))
        }
    }

    private func spawn(accessMode: AccessMode, lease: ACPLaunchLease?) throws -> ACPClient {
        launchLease = lease
        var environment = flavor.environment(launch.environment, executable: launch.executable)
        if flavor.usesPrivateTemporaryDirectory, let directory = makeTemporaryDirectory() {
            environment["TMPDIR"] = directory.path + "/"
            temporaryDirectory = directory
        }
        let transport = makeTransport(launch.executable, flavor.arguments(for: accessMode), launch.workingDirectory, environment)
        let connection = ACPConnection(write: { [weak transport] line in transport?.write(line) })
        let client = ACPClient(connection: connection)
        let capabilities = flavor.clientCapabilities
        if capabilities.readTextFile || capabilities.writeTextFile {
            client.fileSystem = ACPFileSystem(roots: [launch.workingDirectory])
        }
        if capabilities.terminal {
            let terminals = ACPTerminals(workingDirectory: launch.workingDirectory, environment: environment)
            client.terminals = terminals
            client.authorizeTerminal = { [weak self] _ in self?.terminalRefusal() }
            self.terminals = terminals
        }
        client.onSessionUpdate = { [weak self] in self?.handle($0) }
        client.onPermissionRequest = { [weak self, weak client] request, incoming in
            guard let self else {
                client?.respondToPermission(incoming, optionID: nil)
                return
            }
            self.handlePermission(request, incoming)
        }
        client.onElicitation = { [weak self, weak client] request, incoming in
            guard let self else {
                client?.respondToElicitation(incoming, action: "cancel")
                return
            }
            self.handleElicitation(request, incoming)
        }
        client.onElicitationComplete = { [weak self] in self?.elicitationCompleted($0) }
        client.onExtensionRequest = { [weak self] in self?.handleExtensionRequest($0) ?? false }
        client.onExtensionNotification = { [weak self] in self?.handleExtensionNotification($0, $1) }
        connection.onUnparsedLine = { [weak self] in self?.outputLine($0) }
        transport.onLine = { [weak connection] in connection?.receive($0) }
        transport.onStderr = { [weak self] in self?.recordStderr($0) }
        transport.onExit = { [weak self, weak transport] status, tail in
            guard let self, let transport else { return }
            self.processExited(transport, status: status, stderrTail: tail)
        }
        stderrTail = ""
        stderrLine = ""
        do {
            try transport.start()
        } catch {
            removeTemporaryDirectory(after: 0)
            throw AgentError.providerError(
                String(localized: "Could not start \(provider.displayName): \(error.localizedDescription)"))
        }
        self.transport = transport
        self.client = client
        launchedAccessMode = accessMode
        mapper = ACPEventMapper(workingDirectory: launch.workingDirectory)
        return client
    }

    private func detach(_ transport: ACPTransport, client: ACPClient) {
        transport.onExit = nil
        transport.onLine = nil
        transport.onStderr = nil
        client.onSessionUpdate = nil
        client.onPermissionRequest = nil
        client.onElicitation = nil
        client.onElicitationComplete = nil
        client.onExtensionRequest = nil
        client.onExtensionNotification = nil
        client.connection.onUnparsedLine = nil
    }

    /// Ends the process on purpose: no `.sessionExited` follows.
    private func stopProcess() {
        guard let transport else { return }
        if let client { detach(transport, client: client) }
        transport.terminate()
        client?.connection.close(with: AgentError.notRunning)
        terminals?.disposeAll()
        self.transport = nil
        client = nil
        terminals = nil
        pending.removeAll()
        loadGate = nil
        // Give the process time to exit before its temporary folder goes away.
        removeTemporaryDirectory(after: 4)
    }

    private func processExited(_ exited: ACPTransport, status: Int32, stderrTail tail: String) {
        guard exited === transport else { return }
        let message = exitMessage(status: status, stderr: tail.isEmpty ? stderrTail : tail)
        let closing = client
        transport = nil
        client = nil
        terminals?.disposeAll()
        terminals = nil
        pending.removeAll()
        removeTemporaryDirectory(after: 0)
        // Fails the pending prompt (ending the turn) or the handshake that is waiting.
        closing?.connection.close(with: AgentError.providerError(message))
        if turn != nil { finishTurn(.failed(message)) }
        // A turn the agent started by itself ends with the session (the runner fails it on the exit).
        backgroundTurn = nil
        if !launching && !isShutDown { emit(.sessionExited(error: message)) }
    }

    private func recordStderr(_ text: String) {
        stderrTail = String((stderrTail + text).suffix(4_096))
        // Agents print sign-in links and similar notices on stderr too.
        let lines = (stderrLine + text).split(separator: "\n", omittingEmptySubsequences: false)
        stderrLine = String((lines.last ?? "").suffix(32_768))
        lines.dropLast().forEach { outputLine(String($0)) }
    }

    private func outputLine(_ line: String) {
        let line = line.hasSuffix("\r") ? String(line.dropLast()) : line
        if let failure = flavor.failure(forOutputLine: line) {
            failFromOutput(failure)
            return
        }
        guard let notice = flavor.notice(forOutputLine: line), shownNotices.insert(notice).inserted else { return }
        emit(.notice(notice))
    }

    /// Ends the process for something it printed: the handshake or prompt waiting on it fails with
    /// `message`, and the next turn starts a new process.
    private func failFromOutput(_ message: String) {
        guard let client, !client.connection.isClosed else { return }
        client.connection.close(with: AgentError.providerError(message))
        if turn != nil { finishTurn(.failed(message)) }
        stopProcess()
        needsRestart = true
    }

    private func exitMessage(status: Int32, stderr: String) -> String {
        var message = String(localized: "\(provider.displayName) exited unexpectedly (status \(status)).")
        if let tail = TerminalText.tail(stderr, lines: 6, maxLength: 800) { message += "\n" + tail }
        return message
    }

    private func makeTemporaryDirectory() -> URL? {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Coincide-\(provider.rawValue)", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory
        } catch {
            return nil
        }
    }

    /// Removes the process's temporary folder and ends its launch lease, `delay` seconds from now.
    private func removeTemporaryDirectory(after delay: TimeInterval) {
        if let lease = launchLease {
            launchLease = nil
            if delay <= 0 {
                lease.release()
            } else {
                Task {
                    try? await Task.sleep(for: .seconds(delay))
                    lease.release()
                }
            }
        }
        guard let directory = temporaryDirectory else { return }
        temporaryDirectory = nil
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    // MARK: Turn configuration

    /// Applies the model and effort: through `session/set_model` with the effort in `_meta` for
    /// agents that select models that way (Grok), otherwise through config options, falling back
    /// to `session/set_model` for agents that only list legacy models.
    private func applySelection(_ selection: ModelSelection, client: ACPClient, sessionID: String) async throws {
        let model = selection.modelID.trimmingCharacters(in: .whitespaces)
        let requested = model.isEmpty || model == flavor.defaultModelID || model == "default" ? nil : model
        let effort = selection.effort.flatMap { ACPModels.isEffortToken($0) ? $0 : nil }
        let legacyState = setup.models ?? initialized?.modelState

        if flavor.selectsModelsWithSetModel, let state = legacyState {
            let currentEffort = legacyEffort ?? setup.reasoningOption?.currentValue ?? state.currentEffort
            let modelChanged = requested != nil && requested != state.currentModelID
            let effortChanged = effort != nil && effort != currentEffort
            guard modelChanged || effortChanged else { return }
            try await setLegacyModel(requested ?? state.currentModelID, effort: effort, state: state, client: client, sessionID: sessionID)
            return
        }

        if let option = setup.modelOption {
            if let requested, option.currentValue != requested {
                if flavor.requiresListedModel, !option.offers(requested) {
                    throw AgentError.providerError(unavailableModelMessage(requested))
                }
                try await setConfigOption(option.id, requested, client: client, sessionID: sessionID, rejecting: requested)
                emit(.modelResolved(requested))
            }
        } else if let requested, let state = legacyState, state.currentModelID != requested {
            if flavor.requiresListedModel, !state.availableModels.contains(where: { $0.modelID == requested }) {
                throw AgentError.providerError(unavailableModelMessage(requested))
            }
            try await setLegacyModel(requested, effort: nil, state: state, client: client, sessionID: sessionID)
        }
        if let effort, let option = setup.reasoningOption, option.currentValue != effort, option.offers(effort) {
            try await setConfigOption(option.id, effort, client: client, sessionID: sessionID)
        }
    }

    private func setLegacyModel(
        _ model: String, effort: String?, state: ACPModelState, client: ACPClient, sessionID: String
    ) async throws {
        if flavor.requiresListedModel, !state.availableModels.contains(where: { $0.modelID == model }) {
            throw AgentError.providerError(unavailableModelMessage(model))
        }
        do {
            try await client.setModel(
                sessionID: sessionID, modelID: model, meta: effort.map { ["reasoningEffort": .string($0)] },
                timeout: Self.configTimeout)
        } catch let error as ACPError where error.code == ACPError.invalidParams {
            throw AgentError.providerError(rejectedModelMessage(model))
        }
        var updated = state
        updated.currentModelID = model
        setup.models = updated
        if let option = setup.modelOption { setup.setCurrentValue(model, ofOption: option.id) }
        if let effort {
            legacyEffort = effort
            if let option = setup.reasoningOption, option.offers(effort) { setup.setCurrentValue(effort, ofOption: option.id) }
        }
        emit(.modelResolved(model))
        publishModels()
    }

    /// Runs after the interaction mode, so leaving plan mode can never bring back an access
    /// mode the thread no longer has.
    private func applyAccessMode(_ mode: AccessMode, client: ACPClient, sessionID: String) async throws {
        accessMode = mode
        guard let target = flavor.sessionMode(for: mode), let modes = setup.effectiveModes, modes.currentModeID != target,
            modes.availableModes.contains(where: { $0.id == target })
        else { return }
        if savedBuild != nil, Self.isPlanMode(modes.currentModeID) {
            // Plan mode holds the session mode; build mode restores this one.
            savedBuild?.modeID = target
            return
        }
        try await setSessionMode(target, client: client, sessionID: sessionID)
    }

    /// Plan mode switches to the agent's own plan (or architect) mode and mode-like options when
    /// it has them, remembering what to restore; the prompt also carries the mode's instructions.
    private func applyInteractionMode(_ mode: InteractionMode, client: ACPClient, sessionID: String) async throws {
        switch mode {
        case .plan:
            let modes = setup.effectiveModes
            let planMode = modes?.availableModes.first { Self.isPlanMode($0.id) }
            let planOptions = setup.modeLikeOptions.compactMap { option -> (id: String, value: String)? in
                guard let value = option.choices.first(where: { Self.isPlanMode($0.value) })?.value, option.currentValue != value
                else { return nil }
                return (option.id, value)
            }
            let switchesMode = planMode != nil && modes?.currentModeID != planMode?.id
            if savedBuild == nil, switchesMode || !planOptions.isEmpty {
                savedBuild = BuildConfiguration(
                    modeID: modes?.currentModeID,
                    options: Dictionary(uniqueKeysWithValues: setup.modeLikeOptions.compactMap { option in
                        option.currentValue.map { (option.id, $0) }
                    }))
            }
            if let planMode, switchesMode { try await setSessionMode(planMode.id, client: client, sessionID: sessionID) }
            for option in planOptions where setup.configOptions.first(where: { $0.id == option.id })?.currentValue != option.value {
                try await setConfigOption(option.id, option.value, client: client, sessionID: sessionID)
            }
        case .build:
            guard let saved = savedBuild else { return }
            savedBuild = nil
            // The thread's current access mode wins over the mode plan mode replaced.
            let modeID = flavor.sessionMode(for: accessMode) ?? saved.modeID
            if let modeID, let modes = setup.effectiveModes, modes.currentModeID != modeID,
                modes.availableModes.contains(where: { $0.id == modeID })
            {
                try await setSessionMode(modeID, client: client, sessionID: sessionID)
            }
            for (id, value) in saved.options.sorted(by: { $0.key < $1.key }) where id != setup.modeOption?.id {
                guard let option = setup.configOptions.first(where: { $0.id == id }), option.currentValue != value,
                    option.offers(value)
                else { continue }
                try await setConfigOption(id, value, client: client, sessionID: sessionID)
            }
        }
    }

    private nonisolated static func isPlanMode(_ id: String) -> Bool {
        ["plan", "architect"].contains(id.lowercased())
    }

    private func setSessionMode(_ id: String, client: ACPClient, sessionID: String) async throws {
        if let option = setup.modeOption {
            try await setConfigOption(option.id, id, client: client, sessionID: sessionID)
        } else {
            try await client.setMode(sessionID: sessionID, modeID: id, timeout: Self.configTimeout)
            setup.modes?.currentModeID = id
        }
    }

    private func setConfigOption(
        _ id: String, _ value: String, client: ACPClient, sessionID: String, rejecting model: String? = nil
    ) async throws {
        let options: [ACPConfigOption]?
        do {
            options = try await client.setConfigOption(sessionID: sessionID, configID: id, value: value, timeout: Self.configTimeout)
        } catch let error as ACPError where error.code == ACPError.invalidParams && model != nil {
            throw AgentError.providerError(rejectedModelMessage(model ?? value))
        }
        if let options, !options.isEmpty {
            setup.configOptions = options
        } else {
            setup.setCurrentValue(value, ofOption: id)
        }
        if id == setup.modeOption?.id { setup.modes?.currentModeID = value }
        publishModels()
    }

    private func rejectedModelMessage(_ model: String) -> String {
        String(localized: "\(provider.displayName) did not accept the model “\(model)”. Choose another model, then try again.")
    }

    private func unavailableModelMessage(_ model: String) -> String {
        String(localized: "\(provider.displayName) does not offer the model “\(model)” for this account. Choose another model.")
    }

    // MARK: Agent messages

    private func handle(_ notification: ACPSessionNotification) {
        if let gate = loadGate, notification.sessionID == gate.sessionID {
            if Self.isReplayActivity(notification.update) { gate.lastActivity = Date() }
            if case .configOptions(let options) = notification.update { gate.candidateOptions = options }
            return
        }
        if launching {
            // The session id is not known yet; keep its configuration for `adopt`.
            switch notification.update {
            case .configOptions, .currentMode:
                startupUpdates.append(notification)
                if startupUpdates.count > Self.maxStartupUpdates { startupUpdates.removeFirst() }
            case .notice(let title, let description):
                showNotice(title, description)
            default:
                break
            }
            return
        }
        guard let sessionID, notification.sessionID == sessionID, !notification.isReplay else { return }
        if let tokens = notification.meta?["totalTokens"]?.acpInt { contextTokens = tokens }
        switch notification.update {
        case .configOptions, .currentMode:
            applyConfiguration(notification.update)
        case .usage(let used, let size, let costUSD):
            emit(.usage(TokenUsage(inputTokens: used, contextWindow: size > 0 ? size : nil, costUSD: costUSD)))
        case .idle(_, _, let usage):
            if let usage = usage?["totalTokens"]?.acpInt { contextTokens = usage }
        case .notice(let title, let description):
            showNotice(title, description)
        case .availableCommands(let commands):
            emit(
                .commandsDiscovered(
                    commands.map { ProviderCommand(name: $0.name, description: $0.description.isEmpty ? nil : $0.description) }))
        case .userMessageChunk, .sessionInfo, .other:
            break
        default:
            if flavor.isBackgroundUpdate(meta: notification.meta) {
                // Background work stays out of a turn of ours; between turns it is a turn of the agent's own.
                guard turn == nil, preparingGeneration == nil else { return }
                if backgroundTurn == nil {
                    backgroundTurn = false
                    mapper.beginTurn()
                    emit(.agentTurnStarted(note: String(localized: "\(provider.displayName) continued after background work finished.")))
                }
            } else if turn == nil {
                return
            }
            emit(mapper.map(notification.update, flavor: flavor, terminals: terminals))
        }
    }

    /// Stops a turn the agent started by itself, the way the flavor stops any turn.
    private func stopBackgroundTurn() {
        backgroundTurn = true
        guard let client, let sessionID, flavor.interruptStyle == .cancel else {
            finishBackgroundTurn(.interrupted)
            stopProcess()
            needsRestart = true
            return
        }
        client.cancel(sessionID: sessionID, meta: flavor.cancelMeta)
        Task { [weak self, timeout = cancelTimeout] in
            try? await Task.sleep(for: .seconds(timeout))
            guard let self, self.turn == nil, self.backgroundTurn == true else { return }
            // The agent did not confirm; end the turn and replace the process.
            self.finishBackgroundTurn(.interrupted)
            self.stopProcess()
            self.needsRestart = true
        }
    }

    /// Ends the turn the agent started by itself.
    private func finishBackgroundTurn(_ outcome: TurnOutcome) {
        guard backgroundTurn != nil else { return }
        backgroundTurn = nil
        emit(mapper.closeSegments())
        emit(.turnCompleted(outcome))
    }

    private func showNotice(_ title: String, _ description: String?) {
        guard let title = ACPToolCallState.nonEmpty(title) else { return }
        emit(.notice(description.flatMap(ACPToolCallState.nonEmpty).map { "\(title)\n\($0)" } ?? title))
    }

    /// Updates that show the agent is still replaying a loaded session.
    private nonisolated static func isReplayActivity(_ update: ACPSessionUpdate) -> Bool {
        switch update {
        case .agentMessageChunk(let block, _), .agentThoughtChunk(let block, _):
            return block.displayText?.isEmpty == false
        case .userMessageChunk, .idle, .notice, .other:
            return false
        default:
            return true
        }
    }

    private func applyConfiguration(_ update: ACPSessionUpdate) {
        switch update {
        case .configOptions(let options):
            let previousModel = setup.currentModelID
            setup.configOptions = options
            if let mode = setup.modeOption?.currentValue { setup.modes?.currentModeID = mode }
            if let model = setup.currentModelID, model != previousModel { emit(.modelResolved(model)) }
            publishModels()
        case .currentMode(let id):
            guard !id.isEmpty else { return }
            setup.modes?.currentModeID = id
            if let option = setup.modeOption { setup.setCurrentValue(id, ofOption: option.id) }
        default:
            break
        }
    }

    private func handlePermission(_ request: ACPPermissionRequest, _ incoming: ACPConnection.IncomingRequest) {
        guard let client else { return }
        guard let current = turn, !current.interrupting, request.sessionID == sessionID else {
            client.respondToPermission(incoming, optionID: nil)
            return
        }
        if let questions = flavor.question(for: request) {
            ask(questions, request: incoming, isElicitation: false)
            return
        }
        emit(mapper.toolEvents(request.toolCall, flavor: flavor, terminals: terminals))
        let kind = request.toolCall.kind ?? mapper.kind(of: request.toolCall.id) ?? "other"
        if let optionID = automaticAnswer(request, kind: kind) {
            client.respondToPermission(incoming, optionID: optionID)
            if kind == "execute" { turn?.approvedCommand = true }
            return
        }
        let info = mapper.info(for: request.toolCall.id) ?? ACPToolCallState(request.toolCall).info(relativeTo: launch.workingDirectory)
        let detail = [request.description, info.detail, flavor.approvalNote(for: request)]
            .compactMap { $0.flatMap(ACPToolCallState.nonEmpty) }.joined(separator: "\n\n")
        let id = nextRequestID("acp-approval")
        pending[id] = .approval(incoming, toolCallID: request.toolCall.id, options: request.options, kind: kind)
        emit(
            .approvalRequested(
                ApprovalRequest(
                    id: id, category: info.category, title: request.title.flatMap(ACPToolCallState.nonEmpty) ?? info.title,
                    detail: detail.isEmpty ? nil : detail, options: flavor.approvalOptions(for: request),
                    toolCallID: request.toolCall.id)))
    }

    /// Full access allows everything; otherwise reads, searches and thinking need no approval.
    /// Allow-once is preferred because allow-always can outlive the session.
    private func automaticAnswer(_ request: ACPPermissionRequest, kind: String) -> String? {
        guard accessMode == .fullAccess || ["read", "search", "think"].contains(kind) else { return nil }
        return (request.option(.allowOnce) ?? request.option(.allowAlways))?.id
    }

    /// Client terminals run with Coincide's privileges: in approval mode only after the user
    /// approved a command in this turn (or for the session).
    private func terminalRefusal() -> ACPError? {
        guard accessMode != .fullAccess, !commandsApprovedForSession, turn?.approvedCommand != true else { return nil }
        return .internalError("The user has not approved running commands in this turn.")
    }

    private func handleElicitation(_ request: ACPElicitationRequest, _ incoming: ACPConnection.IncomingRequest) {
        guard let client else { return }
        // Session elicitations belong to a running turn; request-scoped ones can also come
        // while the agent signs in during the handshake.
        let inTurn = turn.map { !$0.interrupting && (request.sessionID == nil || request.sessionID == sessionID) } ?? false
        guard inTurn || (launching && request.sessionID == nil) else {
            client.respondToElicitation(incoming, action: "cancel")
            return
        }
        guard let questions = ACPElicitationForm.questionSet(request) else {
            client.respondToElicitation(incoming, action: "decline")
            return
        }
        ask(questions, request: incoming, isElicitation: true)
    }

    private func elicitationCompleted(_ elicitationID: String) {
        guard let entry = pending.first(where: { _, pending in
            guard case .question(let request, _, true) = pending else { return false }
            return request.params["elicitationId"]?.string == elicitationID
        }) else { return }
        pending[entry.key] = nil
        client?.respondToElicitation(entry.value.request, action: "cancel")
        emit(.userInputResolved(id: entry.key))
    }

    private func ask(_ questions: ACPQuestionSet, request: ACPConnection.IncomingRequest, isElicitation: Bool) {
        let id = nextRequestID("acp-question")
        pending[id] = .question(request, questions, isElicitation: isElicitation)
        emit(.userInputRequested(UserInputRequest(id: id, title: questions.title, questions: questions.questions)))
    }

    private func reply(
        to request: ACPConnection.IncomingRequest, _ questions: ACPQuestionSet, answers: [String: [String]]?,
        isElicitation: Bool
    ) {
        guard let client else { return }
        let reply = questions.respond(answers)
        if isElicitation {
            client.respondToElicitation(request, action: reply["action"]?.string ?? "cancel", content: reply["content"])
        } else {
            client.connection.respond(to: request, result: reply)
        }
    }

    private func handleExtensionRequest(_ request: ACPConnection.IncomingRequest) -> Bool {
        guard let client, let action = flavor.extensionRequest(method: request.method, params: request.params) else {
            return false
        }
        switch action {
        case .respond(let result):
            client.connection.respond(to: request, result: result)
        case .capturePlan(let markdown, let placeholder, let response):
            if turn != nil, let plan = markdown ?? mapper.planDocument.flatMap(ACPToolCallState.nonEmpty) ?? placeholder {
                emit(.plan(text: plan))
            }
            client.connection.respond(to: request, result: response)
        case .ask(let questions):
            guard let current = turn, !current.interrupting, !questions.questions.isEmpty else {
                client.connection.respond(to: request, result: questions.respond(nil))
                return true
            }
            ask(questions, request: request, isElicitation: false)
        }
        return true
    }

    private func handleExtensionNotification(_ method: String, _ params: JSONValue) {
        if method == "$/cancel_request" {
            withdraw(params["requestId"])
            return
        }
        if let id = params["sessionId"]?.string, let sessionID, id != sessionID { return }
        for event in flavor.extensionEvents(method: method, params: params) {
            switch event {
            case .promptCompleted(let promptID, let stopReason, let failure, let usage):
                guard let current = turn, promptID == nil || promptID == current.promptID else { continue }
                if let usage { turnUsage = usage.merged(with: turnUsage) }
                if let failure {
                    finishTurn(current.interrupting ? .interrupted : .failed(failure))
                } else {
                    complete(stopReason: stopReason ?? "end_turn", interrupting: current.interrupting)
                }
            case .backgroundPromptCompleted(_, let stopReason, let failure):
                guard turn == nil, let stopping = backgroundTurn else { continue }
                if stopping || stopReason == "cancelled" {
                    finishBackgroundTurn(.interrupted)
                } else {
                    finishBackgroundTurn(failure.map { .failed($0) } ?? .completed)
                }
            case .modelState(let state):
                setup.models = state
                publishModels()
            case .modelChanged(let id, let effort):
                if let effort { legacyEffort = effort }
                var state = setup.models ?? initialized?.modelState
                guard state?.currentModelID != id else { continue }
                state?.currentModelID = id
                setup.models = state
                if let option = setup.modelOption, option.offers(id) { setup.setCurrentValue(id, ofOption: option.id) }
                emit(.modelResolved(id))
                publishModels()
            }
        }
    }

    /// The agent withdrew one of its requests (`$/cancel_request`); it still gets an answer.
    private func withdraw(_ requestID: JSONValue?) {
        guard let requestID, let entry = pending.first(where: { $0.value.request.id == requestID }) else { return }
        pending[entry.key] = nil
        client?.connection.respond(to: entry.value.request, error: ACPError(code: ACPError.requestCancelled, message: "Request cancelled"))
        switch entry.value {
        case .approval: emit(.approvalResolved(id: entry.key))
        case .question: emit(.userInputResolved(id: entry.key))
        }
    }

    private func promptFinished(_ promptID: String, _ result: Result<ACPPromptResult, Error>) {
        guard let current = turn, current.promptID == promptID else { return }
        switch result {
        case .success(let response):
            if let usage = Self.promptUsage(response.usage) { turnUsage = usage.merged(with: turnUsage) }
            complete(stopReason: response.stopReason, interrupting: current.interrupting)
        case .failure(let error):
            let cancelled = (error as? ACPError)?.code == ACPError.requestCancelled
            finishTurn(current.interrupting || cancelled ? .interrupted : .failed(flavor.message(for: error)))
        }
    }

    private func complete(stopReason: String, interrupting: Bool) {
        switch stopReason {
        case "cancelled":
            finishTurn(.interrupted)
            return
        case "refusal":
            emit(.notice(String(localized: "\(provider.displayName) refused to continue this request.")))
        case "max_tokens":
            emit(.notice(String(localized: "\(provider.displayName) stopped after reaching its output limit.")))
        case "max_turn_requests":
            emit(.notice(String(localized: "\(provider.displayName) stopped after reaching its request limit for this turn.")))
        default:
            break
        }
        finishTurn(interrupting ? .interrupted : .completed)
    }

    private func finishTurn(_ outcome: TurnOutcome) {
        guard let current = turn else { return }
        turn = nil
        current.cancelTimer?.cancel()
        // Anything still waiting was withdrawn by the agent when it ended the turn.
        let withdrawn = pending.sorted { $0.key < $1.key }
        cancelPending()
        if outcome == .completed {
            for (id, entry) in withdrawn {
                switch entry {
                case .approval: emit(.approvalResolved(id: id))
                case .question: emit(.userInputResolved(id: id))
                }
            }
        }
        emit(mapper.closeSegments())
        var usage = turnUsage
        if usage.inputTokens == nil { usage.inputTokens = contextTokens }
        if usage.contextWindow == nil { usage.contextWindow = modelContextWindow }
        if usage != TokenUsage() { emit(.usage(usage)) }
        emit(.turnCompleted(outcome))
        reportUsageLimits()
    }

    /// Answers every waiting request with its cancelled form.
    private func cancelPending() {
        let waiting = pending.values
        pending.removeAll()
        guard let client else { return }
        for entry in waiting {
            switch entry {
            case .approval(let request, _, _, _):
                client.respondToPermission(request, optionID: nil)
            case .question(let request, let questions, let isElicitation):
                reply(to: request, questions, answers: nil, isElicitation: isElicitation)
            }
        }
    }

    private func nextRequestID(_ prefix: String) -> String {
        requestCount += 1
        return "\(prefix)-\(requestCount)"
    }

    private func publishModels() {
        let models = flavor.models(initialize: initialized, setup: setup)
        guard !models.isEmpty, models != publishedModels else { return }
        publishedModels = models
        emit(.modelsDiscovered(models))
    }

    private var modelContextWindow: Int? {
        guard let current = setup.currentModelID ?? initialized?.modelState?.currentModelID else { return nil }
        return publishedModels.first { $0.modelID == current }?.contextWindow
    }

    /// ACP's prompt `usage` counts the whole turn, so only output and cache figures carry over.
    nonisolated static func promptUsage(_ value: JSONValue?) -> TokenUsage? {
        guard let value, value.object != nil else { return nil }
        let usage = TokenUsage(outputTokens: value["outputTokens"]?.acpInt, cachedInputTokens: value["cachedReadTokens"]?.acpInt)
        return usage == TokenUsage() ? nil : usage
    }

    private func emit(_ event: AgentEvent) {
        guard !isShutDown else { return }
        onEvent?(event)
    }

    private func emit(_ events: [AgentEvent]) {
        events.forEach(emit)
    }

    nonisolated static var clientInfo: JSONValue {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        return ["name": "coincide", "title": "Coincide", "version": .string(version)]
    }
}
