import Foundation
import UniformTypeIdentifiers

/// Drives `cursor-agent acp`, the Cursor CLI's Agent Client Protocol server, for one thread.
///
/// The model, reasoning effort and plan mode change through the protocol before a turn. Access
/// mode is a launch flag (`--force` runs everything without asking), so changing it restarts the
/// process and reloads the same chat; so does picking a model the server does not list.
@MainActor
public final class CursorSession: AgentSession {
    public let provider: ProviderKind = .cursor
    public private(set) var sessionID: String?
    public var onEvent: ((AgentEvent) -> Void)?

    private struct Turn {
        var number: Int
        var promptSent = false
        var interruptRequested = false
    }

    private struct PendingApproval {
        var rpcID: JSONValue
        var toolCallID: String?
        var options: [ApprovalOption]
    }

    /// How long an interrupted turn may take to confirm before the session ends it itself.
    var interruptGrace: Duration = .seconds(5)

    private let launch: AgentLaunch
    private let makeTransport: @MainActor (_ arguments: [String]) -> CursorTransport
    private var connection: CursorConnection?
    private var connectionCount = 0
    private var mapper: CursorEventMapper
    private var supportsImages = true
    private var runsEverything = false
    private var currentMode: String?
    private var currentModel: String?
    private var advertisedModels: [String] = []
    private var configOptions: [CursorConfigOption] = []
    /// The selected model id last applied, by config option or by `--model`.
    private var appliedModel: String?
    private var turn: Turn?
    private var turnCount = 0
    private var pendingApprovals: [String: PendingApproval] = [:]
    private var isShutDown = false

    public convenience init(launch: AgentLaunch) {
        self.init(launch: launch) { arguments in
            CursorProcessTransport(
                executable: launch.executable, arguments: arguments, workingDirectory: launch.workingDirectory,
                environment: launch.environment)
        }
    }

    init(launch: AgentLaunch, makeTransport: @escaping @MainActor (_ arguments: [String]) -> CursorTransport) {
        self.launch = launch
        self.makeTransport = makeTransport
        mapper = CursorEventMapper(workingDirectory: launch.workingDirectory)
    }

    nonisolated static var initializeParams: JSONValue {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        return [
            "protocolVersion": 1,
            "clientCapabilities": [
                "fs": ["readTextFile": false, "writeTextFile": false],
                "terminal": false,
                // Model parameters such as reasoning effort then come as their own config options.
                "_meta": ["parameterizedModelPicker": true],
            ],
            "clientInfo": ["name": "Coincide", "version": .string(version)],
        ]
    }

    // MARK: AgentSession

    public func start() async throws {
        do {
            try await open(resuming: launch.resumeSessionID, runEverything: launch.accessMode == .fullAccess, model: nil)
        } catch {
            throw Self.agentError(error)
        }
    }

    public func send(_ input: AgentTurnInput) async throws {
        guard !isShutDown else { throw AgentError.notRunning }
        if let stale = turn {
            // Coincide already gave up on the previous turn, for example after an unconfirmed interrupt.
            if stale.promptSent, let sessionID { connection?.notify("session/cancel", ["sessionId": .string(sessionID)]) }
            resolvePendingApprovals(notify: false)
            turn = nil
        }
        turnCount += 1
        let number = turnCount
        turn = Turn(number: number)
        mapper.beginTurn()

        do {
            try await prepare(for: input)
        } catch {
            if turn?.number == number { turn = nil }
            throw Self.agentError(error)
        }
        guard let current = turn, current.number == number else { return }
        if current.interruptRequested {
            finishTurn(.interrupted)
            return
        }
        guard let connection, !connection.isClosed, let sessionID else {
            turn = nil
            throw AgentError.notRunning
        }
        let prompt: JSONValue
        do {
            prompt = try promptBlocks(for: input)
        } catch {
            turn = nil
            throw error
        }
        turn?.promptSent = true
        connection.send("session/prompt", ["sessionId": .string(sessionID), "prompt": prompt]) { [weak self] result in
            self?.promptFinished(number, result)
        }
    }

    public func respond(to approvalID: String, optionID: String) {
        guard let pending = pendingApprovals.removeValue(forKey: approvalID) else { return }
        let kind = pending.options.first { $0.id == optionID }?.kind
        if kind == .deny || kind == .cancel, let toolCallID = pending.toolCallID {
            mapper.noteDeclined(toolCallID: toolCallID)
        }
        let outcome: JSONValue =
            kind == .cancel ? Self.cancelledOutcome : ["outcome": ["outcome": "selected", "optionId": .string(optionID)]]
        connection?.respond(to: pending.rpcID, result: outcome)
    }

    public func interrupt() {
        guard let current = turn, !current.interruptRequested else { return }
        turn?.interruptRequested = true
        // Before the prompt is out, `send` ends the turn once its preparation finishes.
        guard current.promptSent else { return }
        if let sessionID { connection?.notify("session/cancel", ["sessionId": .string(sessionID)]) }
        resolvePendingApprovals(notify: false)
        let number = current.number
        let grace = interruptGrace
        Task { [weak self] in
            try? await Task.sleep(for: grace)
            guard let self, self.turn?.number == number else { return }
            self.finishTurn(.interrupted)
        }
    }

    public func shutdown() {
        guard !isShutDown else { return }
        isShutDown = true
        if turn?.promptSent == true, let sessionID {
            connection?.notify("session/cancel", ["sessionId": .string(sessionID)])
        }
        resolvePendingApprovals(notify: false)
        turn = nil
        connection?.close()
        connection = nil
    }

    // MARK: Process and chat

    /// Starts a process and opens the chat: loads `resumeID` when given, otherwise (or when Cursor
    /// cannot load it) creates a new one.
    private func open(resuming resumeID: String?, runEverything: Bool, model: String?) async throws {
        var arguments: [String] = []
        if runEverything { arguments.append("--force") }
        if let model { arguments += ["--model", model] }
        arguments.append("acp")

        connectionCount += 1
        let generation = connectionCount
        let connection = CursorConnection(transport: makeTransport(arguments))
        connection.onNotification = { [weak self] method, params in
            guard let self, self.connectionCount == generation else { return }
            self.handleNotification(method, params)
        }
        connection.onRequest = { [weak self] id, method, params in
            guard let self, self.connectionCount == generation else { return }
            self.handleRequest(id, method, params)
        }
        connection.onClose = { [weak self] message in
            guard let self, self.connectionCount == generation else { return }
            self.connectionClosed(message)
        }
        self.connection = connection
        runsEverything = runEverything
        do {
            try connection.start()
        } catch {
            self.connection = nil
            throw AgentError.providerError(String(localized: "Couldn't start Cursor: \(error.localizedDescription)"))
        }

        let initialized = try await connection.request("initialize", Self.initializeParams, timeout: .seconds(30))
        supportsImages = initialized["agentCapabilities"]?["promptCapabilities"]?["image"]?.bool ?? true

        let cwd = JSONValue.string(launch.workingDirectory.path)
        if let resumeID {
            do {
                // Cursor replays the chat as session updates before answering. No prompt is out
                // yet, so `handleNotification` drops them.
                let result = try await connection.request(
                    "session/load", ["sessionId": .string(resumeID), "cwd": cwd, "mcpServers": []],
                    timeout: .seconds(120))
                adopt(sessionID: resumeID, result: result)
                return
            } catch let error as CursorRPCError where !error.isAuthRequired {
                emit(.notice(String(localized: "Cursor couldn't reopen the earlier chat (\(error.detail)), so a new one was started.")))
            }
        }
        let result = try await connection.request(
            "session/new", ["cwd": cwd, "mcpServers": []], timeout: .seconds(120))
        guard let id = result["sessionId"]?.string, !id.isEmpty else {
            throw AgentError.protocolError("session/new returned no sessionId")
        }
        adopt(sessionID: id, result: result)
    }

    private func adopt(sessionID id: String, result: JSONValue) {
        sessionID = id
        currentMode = result["modes"]?["currentModeId"]?.string
        currentModel = result["models"]?["currentModelId"]?.string
        advertisedModels = (result["models"]?["availableModels"]?.array ?? []).compactMap { $0["modelId"]?.string }
        apply(configOptions: result["configOptions"])
        emit(.sessionStarted(id: id))
        if let currentModel { emit(.modelResolved(currentModel)) }
    }

    private func restart(runEverything: Bool, model: String?) async throws {
        connection?.close()
        connection = nil
        resolvePendingApprovals(notify: false)
        try await open(resuming: sessionID, runEverything: runEverything, model: model)
        if let model { appliedModel = model }
    }

    private func connectionClosed(_ message: String) {
        connection = nil
        guard !isShutDown else { return }
        pendingApprovals.removeAll()
        if turn?.promptSent == true { finishTurn(.failed(message)) }
        emit(.sessionExited(error: message))
    }

    // MARK: Turn setup

    private func prepare(for input: AgentTurnInput) async throws {
        let model = input.selection.modelID
        let runEverything = input.accessMode == .fullAccess
        // Models the server does not list (custom ids, legacy variant slugs) only work as a launch flag.
        let needsModelFlag =
            model != CursorModels.defaultModelID && model != appliedModel && model != currentModel
            && !advertisedModels.contains(model)
        if connection == nil || runEverything != runsEverything || needsModelFlag {
            try await restart(runEverything: runEverything, model: needsModelFlag ? model : nil)
        }
        try await applyModel(model)
        try await applyEffort(input.selection.effort)
        try await applyMode(input.interactionMode == .plan ? "plan" : "agent")
    }

    private func applyModel(_ model: String) async throws {
        guard model != appliedModel else { return }
        guard model != currentModel, advertisedModels.contains(model) else {
            // The default entry keeps the CLI's model; anything else was applied by `--model`.
            appliedModel = model
            return
        }
        do {
            try await setConfigOption("model", value: model)
        } catch let error as CursorRPCError {
            throw AgentError.providerError(
                String(localized: "Cursor can't run the model \(model): \(error.detail). Choose one of the models from your Cursor account."))
        }
        appliedModel = model
        if let currentModel { emit(.modelResolved(currentModel)) }
    }

    private func applyEffort(_ effort: String?) async throws {
        guard let effort, let option = configOptions.first(where: \.isThoughtLevel), option.currentValue != effort,
            option.values.contains(effort)
        else { return }
        try await setConfigOption(option.id, value: effort)
    }

    private func applyMode(_ mode: String) async throws {
        guard currentMode != mode, let connection, let sessionID else { return }
        _ = try await connection.request(
            "session/set_mode", ["sessionId": .string(sessionID), "modeId": .string(mode)], timeout: .seconds(30))
        currentMode = mode
    }

    private func setConfigOption(_ id: String, value: String) async throws {
        guard let connection, let sessionID else { throw AgentError.notRunning }
        let result = try await connection.request(
            "session/set_config_option",
            ["sessionId": .string(sessionID), "configId": .string(id), "value": .string(value)], timeout: .seconds(30))
        apply(configOptions: result["configOptions"])
    }

    private func apply(configOptions json: JSONValue?) {
        guard json?.array != nil else { return }
        configOptions = CursorConfigOption.list(json)
        if let mode = configOptions.first(where: { $0.category == "mode" || $0.id == "mode" })?.currentValue {
            currentMode = mode
        }
        if let model = configOptions.first(where: { $0.category == "model" || $0.id == "model" }) {
            currentModel = model.currentValue ?? currentModel
            if !model.values.isEmpty { advertisedModels = model.values }
        }
    }

    private func promptBlocks(for input: AgentTurnInput) throws -> JSONValue {
        var text = input.text
        var images: [JSONValue] = []
        for path in input.imagePaths {
            let url = URL(fileURLWithPath: path)
            guard supportsImages else {
                text += "\n\n" + String(localized: "[Attached image: \(path)]")
                continue
            }
            guard let data = try? Data(contentsOf: url) else {
                throw AgentError.providerError(String(localized: "Couldn't read the attached image \(url.lastPathComponent)."))
            }
            let mimeType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "image/png"
            images.append(["type": "image", "mimeType": .string(mimeType), "data": .string(data.base64EncodedString())])
        }
        let textBlock: [JSONValue] = text.isEmpty ? [] : [["type": "text", "text": .string(text)]]
        return .array(textBlock + images)
    }

    // MARK: Incoming traffic

    private func handleNotification(_ method: String, _ params: JSONValue) {
        switch method {
        case "session/update":
            if let id = params["sessionId"]?.string, let sessionID, id != sessionID { return }
            let update = params["update"] ?? .null
            switch update["sessionUpdate"]?.string {
            case "current_mode_update": currentMode = update["currentModeId"]?.string ?? currentMode
            case "config_option_update": apply(configOptions: update["configOptions"])
            default: break
            }
            guard turn?.promptSent == true else { return }
            emit(mapper.handle(update: update))
        case "$/cancel_request":
            withdrawApproval(rpcID: params["requestId"])
        default:
            break
        }
    }

    private func handleRequest(_ id: JSONValue, _ method: String, _ params: JSONValue) {
        guard let connection else { return }
        let inTurn = turn?.promptSent == true
        switch method {
        case "session/request_permission":
            requestPermission(id, params)
        case "cursor/update_todos":
            connection.respond(to: id, result: [:])
            if inTurn { emit(mapper.handleTodos(params)) }
        case "cursor/create_plan":
            if inTurn { emit(mapper.handleCreatePlan(params)) }
            // Accepting without a URI lets Cursor save the plan file itself, as in its own apps.
            connection.respond(to: id, result: ["outcome": ["outcome": "accepted"]])
        case "cursor/task", "cursor/generate_image":
            connection.respond(to: id, result: [:])
        default:
            // Includes cursor/ask_question: Cursor then asks through session/request_permission.
            connection.respond(to: id, errorCode: CursorRPCError.methodNotFound, message: "Method not found: \(method)")
        }
    }

    private func requestPermission(_ rpcID: JSONValue, _ params: JSONValue) {
        guard turn?.promptSent == true else {
            connection?.respond(to: rpcID, result: Self.cancelledOutcome)
            return
        }
        let key = "\(connectionCount):\(rpcID.displayText)"
        let (events, request) = mapper.approval(id: key, params: params)
        pendingApprovals[key] = PendingApproval(rpcID: rpcID, toolCallID: request.toolCallID, options: request.options)
        emit(events)
        emit(.approvalRequested(request))
    }

    private func withdrawApproval(rpcID: JSONValue?) {
        guard let rpcID, let entry = pendingApprovals.first(where: { $0.value.rpcID == rpcID }) else { return }
        pendingApprovals[entry.key] = nil
        connection?.respond(to: rpcID, errorCode: CursorRPCError.requestCancelled, message: "Request cancelled")
        emit(.approvalResolved(id: entry.key))
    }

    /// Answers waiting approvals as cancelled; `notify` reports them as withdrawn by the agent.
    private func resolvePendingApprovals(notify: Bool) {
        let pending = pendingApprovals.sorted { $0.key < $1.key }
        pendingApprovals.removeAll()
        for (key, approval) in pending {
            connection?.respond(to: approval.rpcID, result: Self.cancelledOutcome)
            if notify { emit(.approvalResolved(id: key)) }
        }
    }

    // MARK: Turn end

    private func promptFinished(_ number: Int, _ result: Result<JSONValue, any Error>) {
        guard let current = turn, current.number == number else { return }
        switch result {
        case .success(let response):
            if let usage = CursorEventMapper.promptUsage(response["usage"]) { emit(.usage(usage)) }
            let stopReason = response["stopReason"]?.string
            if current.interruptRequested || stopReason == "cancelled" {
                finishTurn(.interrupted)
            } else if let failure = mapper.transportFailure {
                finishTurn(.failed(failure))
            } else {
                if let note = Self.stopNote(stopReason) { emit(.notice(note)) }
                finishTurn(.completed)
            }
        case .failure(let error):
            finishTurn(current.interruptRequested ? .interrupted : .failed(Self.agentError(error).localizedDescription))
        }
    }

    private func finishTurn(_ outcome: TurnOutcome) {
        guard turn != nil else { return }
        turn = nil
        emit(mapper.endTurn())
        resolvePendingApprovals(notify: true)
        if let contextWindow { emit(.usage(TokenUsage(contextWindow: contextWindow))) }
        emit(.turnCompleted(outcome))
    }

    // MARK: Helpers

    private var contextWindow: Int? {
        if let option = configOptions.first(where: \.isContextSize),
            let window = CursorModels.contextWindow(option.currentValue)
        {
            return window
        }
        return currentModel.flatMap(CursorModels.contextWindow(modelID:))
    }

    private func emit(_ event: AgentEvent) {
        guard !isShutDown else { return }
        onEvent?(event)
    }

    private func emit(_ events: [AgentEvent]) {
        for event in events { emit(event) }
    }

    private static let cancelledOutcome: JSONValue = ["outcome": ["outcome": "cancelled"]]

    private static func stopNote(_ stopReason: String?) -> String? {
        switch stopReason {
        case "max_tokens": String(localized: "Cursor stopped because the reply reached its length limit.")
        case "max_turn_requests": String(localized: "Cursor stopped after reaching its limit of model requests for one turn.")
        case "refusal": String(localized: "The model declined to continue.")
        default: nil
        }
    }

    private static func agentError(_ error: any Error) -> any Error {
        guard let error = error as? CursorRPCError else { return error }
        if error.isAuthRequired {
            return AgentError.providerError(
                String(localized: "Cursor isn't signed in. Run `cursor-agent login` in Terminal, then try again."))
        }
        return AgentError.providerError(error.detail)
    }
}
