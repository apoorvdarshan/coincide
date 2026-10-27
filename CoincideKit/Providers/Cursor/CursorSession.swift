import Foundation
import UniformTypeIdentifiers

/// Drives `cursor-agent acp`, the Cursor CLI's Agent Client Protocol server, for one thread.
///
/// The model, reasoning effort and plan mode change through the protocol before a turn. Access
/// mode is a launch flag (`--force` runs everything without asking), so changing it restarts the
/// process and reloads the same chat; so does picking a model the server does not list, which only
/// works as `--model`. Cursor saves every model change as the user's CLI default, so the session
/// puts the user's own model settings back after each one (see `CursorModelSettings`).
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

    private struct PendingQuestion {
        var rpcID: JSONValue
        var questions: [CursorEventMapper.Question]
    }

    /// How long an interrupted turn may take to confirm before the session ends it itself.
    var interruptGrace: Duration = .seconds(5)

    private let launch: AgentLaunch
    private let makeTransport: @MainActor (_ arguments: [String]) -> CursorTransport
    private let modelSettings: CursorModelSettings
    private var connection: CursorConnection?
    private var connectionCount = 0
    private var mapper: CursorEventMapper
    private var supportsImages = true
    private var runsEverything = false
    /// The `--model` the running process was started with.
    private var launchModel: String?
    private var currentMode: String?
    private var currentModel: String?
    private var advertisedModels: [String] = []
    private var configOptions: [CursorConfigOption] = []
    /// Whether Cursor has stored the chat, which it does with the first prompt. Until then there is
    /// nothing to reopen, and a restart simply starts a new chat.
    private var chatIsStored = false
    /// How many times a reopened chat could not be loaded, so a new one was started in its place.
    private var replacedChats = 0
    private var turn: Turn?
    private var turnCount = 0
    private var pendingApprovals: [String: PendingApproval] = [:]
    private var pendingQuestions: [String: PendingQuestion] = [:]
    private var isShutDown = false

    public convenience init(launch: AgentLaunch) {
        self.init(launch: launch, modelSettings: .shared(environment: launch.environment)) { arguments in
            CursorProcessTransport(
                executable: launch.executable, arguments: arguments, workingDirectory: launch.workingDirectory,
                environment: launch.environment)
        }
    }

    init(
        launch: AgentLaunch, modelSettings: CursorModelSettings,
        makeTransport: @escaping @MainActor (_ arguments: [String]) -> CursorTransport
    ) {
        self.launch = launch
        self.modelSettings = modelSettings
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
        // Read attachments first, so a missing image fails the turn before any process work.
        _ = try promptBlocks(for: input, text: input.text)
        let replaced = replacedChats
        if let stale = turn {
            // Coincide already gave up on the previous turn, for example after an unconfirmed interrupt.
            if stale.promptSent, let sessionID { connection?.notify("session/cancel", ["sessionId": .string(sessionID)]) }
            cancelPendingRequests()
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
        guard let current = turn, current.number == number else { throw AgentError.notRunning }
        if current.interruptRequested {
            finishTurn(.interrupted)
            return
        }
        guard let connection, !connection.isClosed, let sessionID else {
            turn = nil
            throw AgentError.notRunning
        }
        // A restart that could not reopen the chat started a new one, which needs the whole recap.
        let prompt: JSONValue
        do {
            prompt = try promptBlocks(for: input, text: input.prompt(forNewSession: replacedChats != replaced))
        } catch {
            turn = nil
            throw error
        }
        turn?.promptSent = true
        chatIsStored = true
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

    public func answer(userInput requestID: String, answers: [String: [String]]) {
        guard let pending = pendingQuestions.removeValue(forKey: requestID) else { return }
        connection?.respond(to: pending.rpcID, result: CursorEventMapper.questionReply(pending.questions, answers: answers))
    }

    public func interrupt() {
        guard let current = turn, !current.interruptRequested else { return }
        turn?.interruptRequested = true
        // Before the prompt is out, `send` ends the turn once its preparation finishes.
        guard current.promptSent else { return }
        if let sessionID { connection?.notify("session/cancel", ["sessionId": .string(sessionID)]) }
        cancelPendingRequests()
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
        cancelPendingRequests()
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
        launchModel = model

        // Starting with `--model` and reopening a chat both make Cursor save a model as the user's default.
        modelSettings.begin()
        defer { modelSettings.end(touching: [model, currentModel].compactMap { $0 }) }
        do {
            try await openChat(on: connection, resuming: resumeID)
        } catch {
            // A half-started process cannot run turns; the next turn starts a new one.
            if self.connection === connection { self.connection = nil }
            connection.close()
            throw error
        }
    }

    private func openChat(on connection: CursorConnection, resuming resumeID: String?) async throws {
        do {
            try connection.start()
        } catch {
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
                chatIsStored = true
                return
            } catch let error as CursorRPCError where !error.isAuthRequired {
                replacedChats += 1
                emit(.notice(String(localized: "Cursor couldn't reopen the earlier chat (\(error.detail)), so a new one was started.")))
            }
        }
        let result = try await connection.request(
            "session/new", ["cwd": cwd, "mcpServers": []], timeout: .seconds(120))
        guard let id = result["sessionId"]?.string, !id.isEmpty else {
            throw AgentError.protocolError("session/new returned no sessionId")
        }
        chatIsStored = false
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
        pendingApprovals.removeAll()
        pendingQuestions.removeAll()
        try await open(resuming: chatIsStored ? sessionID : nil, runEverything: runEverything, model: model)
    }

    private func connectionClosed(_ message: String) {
        connection = nil
        guard !isShutDown else { return }
        pendingApprovals.removeAll()
        pendingQuestions.removeAll()
        if turn?.promptSent == true { finishTurn(.failed(message)) }
        emit(.sessionExited(error: message))
    }

    // MARK: Turn setup

    private func prepare(for input: AgentTurnInput) async throws {
        let model = input.selection.modelID
        let runEverything = input.accessMode == .fullAccess
        let flagModel = launchFlag(for: model)
        if connection == nil || runEverything != runsEverything || (flagModel != nil && flagModel != launchModel) {
            try await restart(runEverything: runEverything, model: flagModel)
        }
        try await applyModel(model)
        try await applyEffort(input.selection.effort)
        try await applyMode(input.interactionMode == .plan ? "plan" : "agent")
    }

    /// Models Cursor's ACP server does not list (custom ids, legacy variant slugs such as
    /// `grok-4.7-high`) only work as `--model`.
    private func launchFlag(for model: String) -> String? {
        if isDefaultEntry(model) || advertisedModels.contains(model) || model == currentModel { return nil }
        return model
    }

    /// Coincide's "Default" entry, unless Cursor lists a model with that id itself.
    private func isDefaultEntry(_ model: String) -> Bool {
        model == CursorModels.defaultModelID && !advertisedModels.contains(model)
    }

    private func applyModel(_ model: String) async throws {
        // "Default" is the model of the user's own Cursor settings, also in a reopened chat that last
        // ran another one; a model Cursor does not list was given as `--model`.
        let target = isDefaultEntry(model) ? modelSettings.userModelID() : model
        guard let target, target != currentModel, advertisedModels.contains(target) else { return }
        do {
            try await setConfigOption("model", value: target)
        } catch let error as CursorRPCError {
            throw AgentError.providerError(
                String(localized: "Cursor can't run the model \(target): \(error.detail). Choose one of the models from your Cursor account."))
        }
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
        // Cursor saves the model and its parameters as the user's default.
        modelSettings.begin()
        defer { modelSettings.end(touching: [currentModel, id == "model" ? value : nil].compactMap { $0 }) }
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

    private func promptBlocks(for input: AgentTurnInput, text: String) throws -> JSONValue {
        var text = text
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
            withdrawRequest(rpcID: params["requestId"])
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
        case "cursor/ask_question":
            askQuestion(id, params)
        case "cursor/update_todos":
            connection.respond(to: id, result: [:])
            if inTurn { emit(mapper.handleTodos(params)) }
        case "cursor/create_plan":
            guard inTurn else {
                connection.respond(to: id, result: ["outcome": ["outcome": "cancelled"]])
                return
            }
            emit(mapper.handleCreatePlan(params))
            // Accepting without a URI lets Cursor save the plan file itself, as in its own apps.
            connection.respond(to: id, result: ["outcome": ["outcome": "accepted"]])
        case "cursor/generate_image":
            connection.respond(to: id, result: [:])
            if inTurn { emit(mapper.handleGeneratedImage(params)) }
        case "cursor/task":
            connection.respond(to: id, result: [:])
        default:
            connection.respond(to: id, errorCode: CursorRPCError.methodNotFound, message: "Method not found: \(method)")
        }
    }

    /// Whether the agent may still ask for something: a prompt is out and not being interrupted.
    private var acceptsRequests: Bool { turn?.promptSent == true && turn?.interruptRequested == false }

    private func requestPermission(_ rpcID: JSONValue, _ params: JSONValue) {
        guard acceptsRequests else {
            connection?.respond(to: rpcID, result: Self.cancelledOutcome)
            return
        }
        let key = "\(connectionCount):\(rpcID.displayText)"
        let (events, request) = mapper.approval(id: key, params: params)
        pendingApprovals[key] = PendingApproval(rpcID: rpcID, toolCallID: request.toolCallID, options: request.options)
        emit(events)
        emit(.approvalRequested(request))
    }

    private func askQuestion(_ rpcID: JSONValue, _ params: JSONValue) {
        guard acceptsRequests else {
            connection?.respond(to: rpcID, result: CursorEventMapper.cancelledQuestionReply)
            return
        }
        let key = "\(connectionCount):\(rpcID.displayText)"
        let (events, request, questions) = mapper.questions(id: key, params: params)
        emit(events)
        guard !questions.isEmpty else {
            connection?.respond(to: rpcID, result: CursorEventMapper.questionReply([], answers: [:]))
            return
        }
        pendingQuestions[key] = PendingQuestion(rpcID: rpcID, questions: questions)
        emit(.userInputRequested(request))
    }

    /// `$/cancel_request`: the agent no longer needs an answer.
    private func withdrawRequest(rpcID: JSONValue?) {
        guard let rpcID else { return }
        if let entry = pendingApprovals.first(where: { $0.value.rpcID == rpcID }) {
            pendingApprovals[entry.key] = nil
            connection?.respond(to: rpcID, errorCode: CursorRPCError.requestCancelled, message: "Request cancelled")
            emit(.approvalResolved(id: entry.key))
        } else if let entry = pendingQuestions.first(where: { $0.value.rpcID == rpcID }) {
            pendingQuestions[entry.key] = nil
            connection?.respond(to: rpcID, errorCode: CursorRPCError.requestCancelled, message: "Request cancelled")
            emit(.userInputResolved(id: entry.key))
        }
    }

    /// Answers whatever the agent still waits for as cancelled. Coincide marks those items declined
    /// when the turn ends.
    private func cancelPendingRequests() {
        let approvals = pendingApprovals.sorted { $0.key < $1.key }
        let questions = pendingQuestions.sorted { $0.key < $1.key }
        pendingApprovals.removeAll()
        pendingQuestions.removeAll()
        for (_, approval) in approvals {
            connection?.respond(to: approval.rpcID, result: Self.cancelledOutcome)
        }
        for (_, question) in questions {
            connection?.respond(to: question.rpcID, result: CursorEventMapper.cancelledQuestionReply)
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
            } else if let failure = mapper.takeFailure() {
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
        cancelPendingRequests()
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
