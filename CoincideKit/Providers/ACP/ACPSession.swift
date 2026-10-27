import Foundation

/// Moves ACP lines between Coincide and an agent. The default runs the agent CLI as a child
/// process; tests use an in-memory one.
@MainActor
public protocol ACPTransport: AnyObject {
    var onLine: ((String) -> Void)? { get set }
    var onStderr: ((String) -> Void)? { get set }
    var onExit: ((_ status: Int32, _ stderrTail: String) -> Void)? { get set }
    func start() throws
    func write(_ line: String)
    func terminate()
}

public typealias ACPTransportFactory = @MainActor (
    _ executable: URL, _ arguments: [String], _ workingDirectory: URL, _ environment: [String: String]
) -> ACPTransport

/// Runs the agent with `LineProcess`.
@MainActor
final class ACPProcessTransport: ACPTransport {
    var onLine: ((String) -> Void)?
    var onStderr: ((String) -> Void)?
    var onExit: ((_ status: Int32, _ stderrTail: String) -> Void)?
    private let process: LineProcess

    init(executable: URL, arguments: [String], workingDirectory: URL, environment: [String: String]) {
        process = LineProcess(executable: executable, arguments: arguments, workingDirectory: workingDirectory, environment: environment)
        process.onLine = { [weak self] line in self?.onLine?(line) }
        process.onStderr = { [weak self] text in self?.onStderr?(text) }
        process.onExit = { [weak self] status, tail in self?.onExit?(status, tail) }
    }

    func start() throws { try process.start() }
    func write(_ line: String) { process.write(line) }

    func terminate() {
        // Stay alive until the process is gone, so the SIGKILL fallback still runs after the
        // session lets go of this transport.
        process.onExit = { [self] _, _ in process.onExit = nil }
        process.terminate()
    }
}

/// A live ACP agent session bound to one Coincide thread.
///
/// It spawns the agent, runs the handshake, resumes the thread's native session when it can,
/// applies the turn's model, effort, access and plan mode before each prompt, and maps the
/// agent's updates, approvals and extensions to `AgentEvent`s. Every turn ends with exactly one
/// `.turnCompleted`.
@MainActor
public final class ACPSession: AgentSession {
    public let provider: ProviderKind
    public private(set) var sessionID: String?
    public var onEvent: ((AgentEvent) -> Void)?

    /// How long `interrupt()` waits for the agent to confirm before the turn ends anyway.
    public var cancelTimeout: TimeInterval = 4

    private struct Turn {
        let promptID: String
        var interrupting = false
        var cancelTimer: Task<Void, Never>?
    }

    private enum PendingApproval {
        case permission(ACPConnection.IncomingRequest, toolCallID: String, options: [ACPPermissionOption], isQuestion: Bool)
        case questions(QuestionFlow)
    }

    /// Grok's `ask_user_question` asks each question as its own approval, in order.
    private struct QuestionFlow {
        let request: ACPConnection.IncomingRequest
        let toolCallID: String?
        let questions: [XAI.Question]
        var index = 0
        var answers: [String: String] = [:]
    }

    private nonisolated static let sessionTimeout: TimeInterval = 60
    private nonisolated static let loadTimeout: TimeInterval = 90
    private nonisolated static let configTimeout: TimeInterval = 30
    private nonisolated static let maxImageBytes = 10 * 1024 * 1024
    private nonisolated static let planInstruction =
        "[Plan mode] Investigate and reply with a step-by-step plan in markdown. Do not edit files or run commands that change anything until the user approves the plan.\n\n"

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
    private var savedBuildModeID: String?
    private var legacyEffort: String?
    private var publishedModels: [ModelOption] = []
    private var contextTokens: Int?
    private var turnUsage = TokenUsage()
    private var replaying = false
    private var launching = false
    private var needsRestart = false
    private var isShutDown = false
    /// Set while `send` prepares a turn; an interrupt then waits for the turn to exist.
    private var isPreparingTurn = false
    private var interruptPending = false
    private var turn: Turn?
    private var approvals: [String: PendingApproval] = [:]
    private var approvalCount = 0
    private var stderrTail = ""
    private var temporaryDirectory: URL?

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
    }

    // MARK: AgentSession

    public func start() async throws {
        try await open(resuming: launch.resumeSessionID, accessMode: launch.accessMode)
    }

    public func send(_ input: AgentTurnInput) async throws {
        guard !isShutDown else { throw AgentError.notRunning }
        isPreparingTurn = true
        interruptPending = false
        defer { isPreparingTurn = false }
        if let stale = turn {
            // The runner gave up on a turn the agent never confirmed; start from a fresh process.
            stale.cancelTimer?.cancel()
            turn = nil
            needsRestart = true
        }
        if transport == nil || needsRestart || (flavor.accessModeNeedsRestart && input.accessMode != launchedAccessMode) {
            let resumeID = sessionID ?? launch.resumeSessionID
            stopProcess()
            needsRestart = false
            try await open(resuming: resumeID, accessMode: input.accessMode)
        }
        guard let client, let sessionID else { throw AgentError.notRunning }
        try await applySelection(input.selection, client: client, sessionID: sessionID)
        try await applyAccessMode(input.accessMode, client: client, sessionID: sessionID)
        let prefix = try await applyInteractionMode(input.interactionMode, client: client, sessionID: sessionID)
        let blocks = promptBlocks(prefix + input.text, imagePaths: input.imagePaths)

        guard !interruptPending else {
            // The user stopped the turn while it was being set up; nothing reached the agent yet.
            emit(.turnCompleted(.interrupted))
            return
        }
        let promptID = UUID().uuidString.lowercased()
        turn = Turn(promptID: promptID)
        mapper.beginTurn()
        contextTokens = nil
        turnUsage = TokenUsage()
        client.prompt(sessionID: sessionID, blocks: blocks, meta: flavor.usesXAIExtensions ? XAI.promptMeta(promptID) : nil) {
            [weak self] result in
            self?.promptFinished(promptID, result)
        }
    }

    public func respond(to approvalID: String, optionID: String) {
        guard let pending = approvals.removeValue(forKey: approvalID), let client else { return }
        switch pending {
        case .permission(let request, let toolCallID, let options, let isQuestion):
            let option = options.first { $0.id == optionID }
            client.respondToPermission(request, optionID: option?.id)
            if option == nil || (!isQuestion && option?.isAllow == false) {
                emit(mapper.markDeclined(toolCallID))
            }
        case .questions(var flow):
            guard optionID != ACPApprovals.cancelOptionID else {
                client.connection.respond(to: flow.request, result: ["outcome": "cancelled"])
                return
            }
            flow.answers[flow.questions[flow.index].text] = optionID
            flow.index += 1
            if flow.index < flow.questions.count {
                ask(flow)
            } else {
                client.connection.respond(to: flow.request, result: XAI.answers(flow.answers))
            }
        }
    }

    public func interrupt() {
        guard var current = turn, !current.interrupting else {
            if turn == nil && isPreparingTurn { interruptPending = true }
            return
        }
        current.interrupting = true
        cancelApprovals()
        guard let client, let sessionID else {
            turn = current
            finishTurn(.interrupted)
            return
        }
        client.cancel(sessionID: sessionID, meta: flavor.cancelMeta)
        let promptID = current.promptID
        current.cancelTimer = Task { [weak self, timeout = cancelTimeout] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled, let self, self.turn?.promptID == promptID else { return }
            // The agent did not confirm; end the turn and replace the process.
            self.finishTurn(.interrupted)
            self.stopProcess()
            self.needsRestart = true
        }
        turn = current
    }

    public func shutdown() {
        guard !isShutDown else { return }
        isShutDown = true
        turn?.cancelTimer?.cancel()
        turn = nil
        cancelApprovals()
        stopProcess()
    }

    // MARK: Process and handshake

    private func open(resuming resumeID: String?, accessMode: AccessMode) async throws {
        guard !isShutDown else { throw AgentError.notRunning }
        launching = true
        defer { launching = false }
        do {
            try await handshake(resuming: resumeID, client: spawn(accessMode: accessMode))
        } catch {
            // A half-open process must not serve the next turn.
            stopProcess()
            needsRestart = true
            throw error
        }
    }

    private func handshake(resuming resumeID: String?, client: ACPClient) async throws {
        initialized = try await client.initialize(
            capabilities: flavor.clientCapabilities, clientInfo: Self.clientInfo, meta: flavor.initializeMeta,
            timeout: flavor.initializeTimeout)
        if flavor.authenticatesEagerly, let method = flavor.authMethodID(environment: launch.environment) {
            try await client.authenticate(methodID: method, timeout: flavor.authenticateTimeout)
        }
        if let resumeID {
            do {
                try await reopen(resumeID, client: client)
                return
            } catch {
                guard !client.connection.isClosed else { throw error }
                emit(.notice(String(localized: "Couldn't resume the earlier \(provider.displayName) session, so a new one was started.")))
            }
        }
        let created = try await authenticated(client) {
            try await client.newSession(cwd: self.launch.workingDirectory, timeout: Self.sessionTimeout)
        }
        adopt(created, id: created.sessionID ?? "")
    }

    private func reopen(_ id: String, client: ACPClient) async throws {
        let agent = initialized
        let canResume = agent?.resumeSession == true
        let canLoad = agent?.loadSession == true
        let reopened: ACPSessionSetup
        if canResume && (flavor.prefersResume || !canLoad) {
            reopened = try await authenticated(client) {
                try await client.resumeSession(id: id, cwd: self.launch.workingDirectory, timeout: Self.sessionTimeout)
            }
        } else if canLoad {
            // The agent replays the history as updates before it answers; the transcript already has it.
            reopened = try await authenticated(client) {
                self.replaying = true
                defer { self.replaying = false }
                return try await client.loadSession(id: id, cwd: self.launch.workingDirectory, timeout: Self.loadTimeout) {
                    [weak self] in
                    self?.replaying = false
                }
            }
        } else {
            throw AgentError.providerError(String(localized: "\(provider.displayName) cannot resume sessions."))
        }
        adopt(reopened, id: id)
    }

    /// Runs `body`, signing in and retrying once when the agent answers `auth_required`.
    private func authenticated<T>(_ client: ACPClient, _ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let error as ACPError where error.code == ACPError.authRequired && !flavor.authenticatesEagerly {
            let advertised = initialized?.authMethods.first { $0.type == nil || $0.type == "agent" }?.id
            guard let method = flavor.authMethodID(environment: launch.environment) ?? advertised else { throw error }
            try await client.authenticate(methodID: method, timeout: flavor.authenticateTimeout)
            return try await body()
        }
    }

    private func adopt(_ opened: ACPSessionSetup, id: String) {
        sessionID = id
        setup = opened
        setup.sessionID = id
        legacyEffort = nil
        savedBuildModeID = nil
        emit(.sessionStarted(id: id))
        if let model = setup.currentModelID { emit(.modelResolved(model)) }
        publishModels()
    }

    private func spawn(accessMode: AccessMode) throws -> ACPClient {
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
        client.onExtensionRequest = { [weak self] in self?.handleExtensionRequest($0) ?? false }
        client.onExtensionNotification = { [weak self] in self?.handleExtensionNotification($0, $1) }
        connection.onUnparsedLine = { [weak self] line in
            guard let self, let notice = self.flavor.notice(forUnparsedLine: line) else { return }
            self.emit(.notice(notice))
        }
        transport.onLine = { [weak connection] in connection?.receive($0) }
        transport.onStderr = { [weak self] in self?.recordStderr($0) }
        transport.onExit = { [weak self, weak transport] status, tail in
            guard let self, let transport else { return }
            self.processExited(transport, status: status, stderrTail: tail)
        }
        stderrTail = ""
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

    /// Ends the process on purpose: no `.sessionExited` follows.
    private func stopProcess() {
        guard let transport else { return }
        transport.onExit = nil
        transport.onLine = nil
        transport.onStderr = nil
        transport.terminate()
        client?.connection.close(with: AgentError.notRunning)
        terminals?.disposeAll()
        self.transport = nil
        client = nil
        terminals = nil
        approvals.removeAll()
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
        approvals.removeAll()
        removeTemporaryDirectory(after: 0)
        // Fails the pending prompt (ending the turn) or the handshake that is waiting.
        closing?.connection.close(with: AgentError.providerError(message))
        if turn != nil { finishTurn(.failed(message)) }
        if !launching && !isShutDown { emit(.sessionExited(error: message)) }
    }

    private func recordStderr(_ text: String) {
        stderrTail = String((stderrTail + text).suffix(4_096))
    }

    private func exitMessage(status: Int32, stderr: String) -> String {
        var message = String(localized: "\(provider.displayName) exited unexpectedly (status \(status)).")
        let lines = stderr.replacingOccurrences(of: #"\u001B\[[0-9;]*[A-Za-z]"#, with: "", options: .regularExpression)
            .split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if !lines.isEmpty { message += "\n" + String(lines.suffix(6).joined(separator: "\n").suffix(800)) }
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

    private func removeTemporaryDirectory(after delay: TimeInterval) {
        guard let directory = temporaryDirectory else { return }
        temporaryDirectory = nil
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    // MARK: Turn configuration

    /// Applies the model and effort through config options when the agent has them, otherwise
    /// through Grok's legacy `session/set_model` with `_meta.reasoningEffort`.
    private func applySelection(_ selection: ModelSelection, client: ACPClient, sessionID: String) async throws {
        let model = selection.modelID.trimmingCharacters(in: .whitespaces)
        let wantsModel = !model.isEmpty && model != flavor.defaultModelID && model != "default"
        let effort = selection.effort.flatMap { ACPModels.isEffortToken($0) ? $0 : nil }

        if let option = setup.modelOption {
            if wantsModel, option.currentValue != model {
                if flavor.requiresListedModel, !option.choices.contains(where: { $0.value == model }) {
                    throw AgentError.providerError(
                        String(localized: "\(provider.displayName) does not offer the model “\(model)” for this account. Choose another model."))
                }
                try await setConfigOption(option.id, model, client: client, sessionID: sessionID, rejecting: model)
                emit(.modelResolved(model))
            }
        } else if let state = setup.models ?? initialized?.modelState {
            let target = wantsModel ? model : state.currentModelID
            let current = legacyEffort ?? state.availableModels.first { $0.modelID == state.currentModelID }?.meta?["reasoningEffort"]?.string
            let effortChanged = effort != nil && effort != current
            if target != state.currentModelID || effortChanged {
                do {
                    try await client.setModel(
                        sessionID: sessionID, modelID: target, meta: effort.map { ["reasoningEffort": .string($0)] },
                        timeout: Self.configTimeout)
                } catch let error as ACPError where error.code == ACPError.invalidParams {
                    throw AgentError.providerError(rejectedModelMessage(target))
                }
                var updated = state
                updated.currentModelID = target
                setup.models = updated
                if effortChanged { legacyEffort = effort }
                emit(.modelResolved(target))
            }
            return
        }

        if let effort, let option = setup.reasoningOption, option.currentValue != effort,
            option.choices.contains(where: { $0.value == effort })
        {
            try await setConfigOption(option.id, effort, client: client, sessionID: sessionID)
        }
    }

    private func applyAccessMode(_ mode: AccessMode, client: ACPClient, sessionID: String) async throws {
        accessMode = mode
        guard let target = flavor.sessionMode(for: mode), let modes = setup.effectiveModes, modes.currentModeID != target,
            modes.availableModes.contains(where: { $0.id == target })
        else { return }
        try await setSessionMode(target, client: client, sessionID: sessionID)
    }

    /// Switches to the agent's plan mode, or returns a prefix that asks for a plan instead.
    private func applyInteractionMode(_ mode: InteractionMode, client: ACPClient, sessionID: String) async throws -> String {
        let modes = setup.effectiveModes
        let planMode = modes?.availableModes.first { ["plan", "architect"].contains($0.id.lowercased()) }
        switch mode {
        case .plan:
            if let planMode, let modes {
                if modes.currentModeID != planMode.id {
                    savedBuildModeID = modes.currentModeID
                    try await setSessionMode(planMode.id, client: client, sessionID: sessionID)
                }
                return ""
            }
            if let command = flavor.planCommand { return "/\(command) " }
            return Self.planInstruction
        case .build:
            if let saved = savedBuildModeID, let planMode, modes?.currentModeID == planMode.id {
                try await setSessionMode(saved, client: client, sessionID: sessionID)
            }
            savedBuildModeID = nil
            return ""
        }
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
            options = try await client.setConfigOption(
                sessionID: sessionID, configID: id, value: value, timeout: Self.configTimeout)
        } catch let error as ACPError where error.code == ACPError.invalidParams && model != nil {
            throw AgentError.providerError(rejectedModelMessage(model ?? value))
        }
        if let options, !options.isEmpty {
            setup.configOptions = options
        } else if let index = setup.configOptions.firstIndex(where: { $0.id == id }),
            case .select(_, let choices) = setup.configOptions[index].value
        {
            setup.configOptions[index].value = .select(current: value, choices: choices)
        }
        publishModels()
    }

    private func rejectedModelMessage(_ model: String) -> String {
        String(localized: "\(provider.displayName) did not accept the model “\(model)”. Choose another model, then try again.")
    }

    private func promptBlocks(_ text: String, imagePaths: [String]) -> [ACPContentBlock] {
        var text = text
        var images: [ACPContentBlock] = []
        let inline = flavor.acceptsImages || initialized?.promptImage == true
        for path in imagePaths {
            if inline, let image = Self.imageBlock(path) {
                images.append(image)
            } else {
                text += "\n\n[Attached image: \(path)]"
            }
        }
        return (text.isEmpty ? [] : [.text(text)]) + images
    }

    nonisolated static func imageBlock(_ path: String) -> ACPContentBlock? {
        let types = ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "webp": "image/webp",
                     "heic": "image/heic", "bmp": "image/bmp", "tif": "image/tiff", "tiff": "image/tiff"]
        guard let mimeType = types[(path as NSString).pathExtension.lowercased()],
            let data = FileManager.default.contents(atPath: path), !data.isEmpty, data.count <= maxImageBytes
        else { return nil }
        return .image(mimeType: mimeType, data: data.base64EncodedString(), uri: nil)
    }

    // MARK: Agent messages

    private func handle(_ notification: ACPSessionNotification) {
        guard sessionID == nil || notification.sessionID == sessionID else { return }
        if let tokens = notification.meta?["totalTokens"]?.int { contextTokens = tokens }
        switch notification.update {
        case .configOptions(let options):
            setup.configOptions = options
            publishModels()
        case .currentMode(let id):
            guard !id.isEmpty else { return }
            setup.modes?.currentModeID = id
            if let index = setup.configOptions.firstIndex(where: { $0.id == setup.modeOption?.id }),
                case .select(_, let choices) = setup.configOptions[index].value
            {
                setup.configOptions[index].value = .select(current: id, choices: choices)
            }
        case .usage(let used, let size, let costUSD):
            emit(.usage(TokenUsage(inputTokens: used, contextWindow: size > 0 ? size : nil, costUSD: costUSD)))
        case .notice(let title, let description):
            guard turn != nil, !title.isEmpty else { return }
            emit(.notice(description.map { "\(title)\n\($0)" } ?? title))
        default:
            guard !replaying, notification.meta?["isReplay"]?.bool != true, turn != nil else { return }
            emit(mapper.map(notification.update, flavor: flavor, terminals: terminals))
        }
    }

    private func handlePermission(_ request: ACPPermissionRequest, _ incoming: ACPConnection.IncomingRequest) {
        guard let client else { return }
        guard turn?.interrupting == false else {
            client.respondToPermission(incoming, optionID: nil)
            return
        }
        let isQuestion = flavor.isQuestion(request)
        if !isQuestion { emit(mapper.toolEvents(request.toolCall, flavor: flavor, terminals: terminals)) }
        if !isQuestion, let optionID = automaticAnswer(request) {
            client.respondToPermission(incoming, optionID: optionID)
            return
        }
        let info = mapper.info(for: request.toolCall.id) ?? ACPToolCallState(request.toolCall).info(relativeTo: launch.workingDirectory)
        let options: [ApprovalOption] =
            isQuestion
            ? request.options.map { ApprovalOption(id: $0.id, label: $0.name, kind: .allowOnce) } + [ACPApprovals.cancelOption]
            : flavor.approvalOptions(for: request)
        let title = isQuestion ? (request.toolCall.title ?? String(localized: "Choose an option.")) : (request.title ?? info.title)
        approvalCount += 1
        let id = "acp-approval-\(approvalCount)"
        approvals[id] = .permission(incoming, toolCallID: request.toolCall.id, options: request.options, isQuestion: isQuestion)
        emit(
            .approvalRequested(
                ApprovalRequest(
                    id: id, category: isQuestion ? .other : info.category, title: title, detail: isQuestion ? nil : info.detail,
                    options: options, toolCallID: request.toolCall.id)))
    }

    /// Full access allows everything; otherwise reads, searches and thinking need no approval.
    private func automaticAnswer(_ request: ACPPermissionRequest) -> String? {
        let kind = mapper.kind(of: request.toolCall.id) ?? request.toolCall.kind ?? "other"
        guard accessMode == .fullAccess || ["read", "search", "think"].contains(kind) else { return nil }
        return (request.option(.allowOnce) ?? request.option(.allowAlways))?.id
    }

    private func handleExtensionRequest(_ request: ACPConnection.IncomingRequest) -> Bool {
        guard flavor.usesXAIExtensions, let client else { return false }
        switch XAI.method(request.method) {
        case "exit_plan_mode":
            if turn != nil { emit(.plan(text: XAI.exitPlanMarkdown(request.params) ?? mapper.planFileMarkdown ?? XAI.emptyPlan)) }
            client.connection.respond(to: request, result: XAI.exitPlanResponse)
            return true
        case "ask_user_question":
            let questions = XAI.questions(request.params)
            guard turn?.interrupting == false, !questions.isEmpty else {
                client.connection.respond(to: request, result: ["outcome": "cancelled"])
                return true
            }
            ask(QuestionFlow(request: request, toolCallID: XAI.toolCallID(request.params), questions: questions))
            return true
        default:
            return false
        }
    }

    private func ask(_ flow: QuestionFlow) {
        let question = flow.questions[flow.index]
        let labels = question.options.isEmpty ? [String(localized: "OK")] : question.options
        approvalCount += 1
        let id = "acp-question-\(approvalCount)"
        approvals[id] = .questions(flow)
        emit(
            .approvalRequested(
                ApprovalRequest(
                    id: id, category: .other, title: question.text,
                    detail: question.details.isEmpty ? nil : question.details.joined(separator: "\n"),
                    options: labels.map { ApprovalOption(id: $0, label: $0, kind: .allowOnce) } + [ACPApprovals.cancelOption],
                    toolCallID: flow.toolCallID)))
    }

    private func handleExtensionNotification(_ method: String, _ params: JSONValue) {
        if method == "$/cancel_request", let requestID = params["requestId"] {
            withdrawApproval(requestID)
            return
        }
        guard flavor.usesXAIExtensions, let completion = XAI.promptCompletion(method: method, params: params),
            completion.promptID == turn?.promptID
        else { return }
        let window = modelContextWindow
        if let usage = XAI.usage(completion.usage, contextTokens: contextTokens, contextWindow: window) {
            turnUsage = usage.merged(with: turnUsage)
        }
        switch completion.stopReason {
        case "cancelled": finishTurn(.interrupted)
        case "rate_limit": finishTurn(.failed(String(localized: "Grok usage limit reached. Try again later.")))
        case "error":
            finishTurn(.failed(completion.agentResult ?? String(localized: "Grok ended the turn with an error.")))
        default: finishTurn(turn?.interrupting == true ? .interrupted : .completed)
        }
    }

    private func withdrawApproval(_ requestID: JSONValue) {
        guard let entry = approvals.first(where: { _, pending in
            if case .permission(let request, _, _, _) = pending { return request.id == requestID }
            return false
        }) else { return }
        approvals[entry.key] = nil
        emit(.approvalResolved(id: entry.key))
    }

    private func promptFinished(_ promptID: String, _ result: Result<ACPPromptResult, Error>) {
        guard let current = turn, current.promptID == promptID else { return }
        switch result {
        case .success(let response):
            if let usage = Self.promptUsage(response.usage) { turnUsage = turnUsage.merged(with: usage) }
            switch response.stopReason {
            case "cancelled":
                finishTurn(.interrupted)
            case "refusal":
                emit(.notice(String(localized: "\(provider.displayName) refused to continue this request.")))
                finishTurn(.completed)
            case "max_tokens":
                emit(.notice(String(localized: "\(provider.displayName) stopped after reaching its output limit.")))
                finishTurn(.completed)
            case "max_turn_requests":
                emit(.notice(String(localized: "\(provider.displayName) stopped after reaching its request limit for this turn.")))
                finishTurn(.completed)
            default:
                finishTurn(current.interrupting ? .interrupted : .completed)
            }
        case .failure(let error):
            let cancelled = (error as? ACPError)?.code == ACPError.requestCancelled
            finishTurn(current.interrupting || cancelled ? .interrupted : .failed(flavor.message(for: error)))
        }
    }

    private func finishTurn(_ outcome: TurnOutcome) {
        guard let current = turn else { return }
        turn = nil
        current.cancelTimer?.cancel()
        // Anything still waiting was withdrawn by the agent when it ended the turn.
        let withdrawn = approvals.keys.sorted()
        cancelApprovals()
        if outcome == .completed { withdrawn.forEach { emit(.approvalResolved(id: $0)) } }
        emit(mapper.closeSegments())
        var usage = turnUsage
        if usage.inputTokens == nil { usage.inputTokens = contextTokens }
        if usage.contextWindow == nil { usage.contextWindow = modelContextWindow }
        if usage != TokenUsage() { emit(.usage(usage)) }
        emit(.turnCompleted(outcome))
        if outcome == .interrupted, flavor.restartsAfterInterrupt {
            stopProcess()
            needsRestart = true
        }
    }

    /// Answers every waiting approval with `cancelled`.
    private func cancelApprovals() {
        let pending = approvals.values
        approvals.removeAll()
        guard let client else { return }
        for entry in pending {
            switch entry {
            case .permission(let request, _, _, _): client.respondToPermission(request, optionID: nil)
            case .questions(let flow): client.connection.respond(to: flow.request, result: ["outcome": "cancelled"])
            }
        }
    }

    private func publishModels() {
        let models = flavor.models(initialize: initialized, setup: setup)
        guard !models.isEmpty, models != publishedModels else { return }
        publishedModels = models
        emit(.modelsDiscovered(models))
    }

    private var modelContextWindow: Int? {
        guard let current = setup.currentModelID else { return nil }
        return publishedModels.first { $0.modelID == current }?.contextWindow
    }

    /// ACP's prompt `usage` counts the whole turn, so only output and cache figures carry over.
    nonisolated static func promptUsage(_ value: JSONValue?) -> TokenUsage? {
        guard let value, value.object != nil else { return nil }
        return TokenUsage(outputTokens: value["outputTokens"]?.int, cachedInputTokens: value["cachedReadTokens"]?.int)
    }

    private func emit(_ event: AgentEvent) {
        guard !isShutDown else { return }
        onEvent?(event)
    }

    private func emit(_ events: [AgentEvent]) {
        events.forEach(emit)
    }

    private nonisolated static var clientInfo: JSONValue {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        return ["name": "coincide", "title": "Coincide", "version": .string(version)]
    }
}
