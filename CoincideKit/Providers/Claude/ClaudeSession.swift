import Foundation

/// A live Claude Code process for one thread, speaking the SDK's stream-json control protocol:
/// `initialize`, user messages stamped with a uuid, `can_use_tool` permission prompts, `interrupt`,
/// `set_model`, `apply_flag_settings` and `set_permission_mode`.
@MainActor
final class ClaudeSession: AgentSession {
    typealias TransportFactory = @MainActor (ClaudeLaunchConfig) -> ClaudeTransport

    let provider: ProviderKind = .claude
    private(set) var sessionID: String?
    var onEvent: ((AgentEvent) -> Void)?
    /// How long Claude may take to confirm an interrupt before its process is stopped.
    var interruptGracePeriod: Duration = .seconds(4)

    /// What the model reads about where it runs, like T3's runtime instructions.
    static let runtimeInstructions =
        "<runtime_info>In case you're asked: you are running in Coincide, a macOS app that drives Claude Code and other coding agents from one window. No need to mention this otherwise.</runtime_info>"

    private struct Turn {
        /// The uuid stamped on the user message; `command_lifecycle` frames refer to it.
        let id: String
        /// The message was written to Claude.
        var accepted = false
        /// Claude started running it (it may first finish a turn it started on its own).
        var started = false
        var interruptRequested = false
    }

    /// What a turn asks for, in CLI terms.
    private struct TurnSettings {
        var model: String?
        var effort: ClaudeModelCatalog.EffortPlan
        var permissionMode: String
    }

    /// What the running process was told.
    private struct LiveSettings {
        var model: String?
        var effort: ClaudeModelCatalog.EffortPlan
        var requestedMode: String

        func effortMatches(_ other: ClaudeModelCatalog.EffortPlan) -> Bool {
            effort.cliEffort == other.cliEffort && effort.ultracode == other.ultracode
        }
    }

    /// A `can_use_tool` request waiting for the user, keyed by its request id.
    private enum PendingPrompt {
        case tool(JSONValue)
        case plan(JSONValue)
        case question(JSONValue)
    }

    /// Output gathered while a process starts, to explain why it did not.
    private struct Handshake {
        var resultErrors: [String] = []
        var exit: (status: Int32, stderr: String)?
    }

    private let launch: AgentLaunch
    private let makeTransport: TransportFactory
    private var knownModels: [JSONValue]
    private var transport: ClaudeTransport?
    private var mapper: ClaudeEventMapper
    private var live: LiveSettings?
    private var access: AccessMode
    private var interaction: InteractionMode
    /// Claude has a saved conversation under `sessionID` that a new process must resume.
    private var conversationExists = false
    private var turn: Turn?
    private var lifecycleSeen = false
    private var handshake: Handshake?
    private var pendingControls: [String: CheckedContinuation<JSONValue, Error>] = [:]
    private var controlTimeouts: [String: Task<Void, Never>] = [:]
    private var prompts: [String: PendingPrompt] = [:]
    private var tails: [String: ClaudeTaskOutputTail] = [:]
    private var noticedFullAccessFallback = false
    private var isShutDown = false

    init(launch: AgentLaunch, knownModels: [JSONValue] = [], makeTransport: TransportFactory? = nil) {
        self.launch = launch
        self.knownModels = knownModels
        self.makeTransport =
            makeTransport ?? { config in
                ClaudeProcessTransport(
                    executable: launch.executable, arguments: config.arguments, workingDirectory: launch.workingDirectory,
                    environment: ClaudeLaunchConfig.environment(launch.environment))
            }
        access = launch.accessMode
        interaction = launch.interactionMode
        let resolved = ClaudeInitializeInfo.resolvedModel(for: launch.selection.modelID, in: knownModels)
        mapper = ClaudeEventMapper(
            workingDirectory: launch.workingDirectory.path,
            contextWindow: ClaudeModelCatalog.contextWindow(modelID: launch.selection.modelID, resolvedModel: resolved))
    }

    // MARK: AgentSession

    func start() async throws {
        let settings = turnSettings(launch.selection, access: launch.accessMode, interaction: launch.interactionMode)
        let identity: ClaudeLaunchConfig.Identity = launch.resumeSessionID.map { .resume($0) } ?? .fresh(Self.newID())
        try await launchProcess(identity: identity, settings: settings)
    }

    func send(_ input: AgentTurnInput) async throws {
        guard !isShutDown else { throw AgentError.notRunning }
        guard turn == nil else {
            throw AgentError.providerError(String(localized: "Claude Code is still working on the previous message."))
        }
        let turnID = Self.newID()
        turn = Turn(id: turnID)
        access = input.accessMode
        interaction = input.interactionMode
        do {
            let settings = turnSettings(input.selection, access: input.accessMode, interaction: input.interactionMode)
            if transport == nil {
                // An earlier relaunch failed or the process was stopped; start again on the same conversation.
                try await launchProcess(identity: restartIdentity, settings: settings)
            } else {
                try await apply(settings)
            }
            let resolved = ClaudeInitializeInfo.resolvedModel(for: input.selection.modelID, in: knownModels)
            if let window = ClaudeModelCatalog.contextWindow(modelID: input.selection.modelID, resolvedModel: resolved) {
                mapper.contextWindow = window
            }
            let text = settings.effort.ultrathink ? ClaudeModelCatalog.applyUltrathink(to: input.text) : input.text
            let (images, skipped) = ClaudeAttachments.imageBlocks(for: input.imagePaths)
            guard turn?.id == turnID else { return }
            if turn?.interruptRequested == true {
                finishTurn(.interrupted)
                return
            }
            guard let transport else { throw AgentError.notRunning }
            for path in skipped {
                emit(.notice(String(localized: "Couldn't attach \((path as NSString).lastPathComponent).")))
            }
            let content: JSONValue = images.isEmpty ? .string(text) : .array([["type": "text", "text": .string(text)]] + images)
            mapper.beginTurn()
            transport.write(Self.userMessage(content: content, uuid: turnID).compactJSON)
            turn?.accepted = true
            conversationExists = true
        } catch {
            if turn?.id == turnID { turn = nil }
            throw error
        }
    }

    func respond(to approvalID: String, optionID: String) {
        respond(to: approvalID, optionID: optionID, text: nil)
    }

    func respond(to approvalID: String, optionID: String, text: String?) {
        switch prompts[approvalID] {
        case .tool(let request)?:
            prompts[approvalID] = nil
            reply(to: approvalID, with: ClaudePermissions.response(optionID: optionID, request: request, feedback: text))
        case .plan(let request)?:
            prompts[approvalID] = nil
            reply(to: approvalID, with: ClaudePermissions.planResponse(optionID: optionID, request: request, feedback: text))
        case .question?, nil:
            break
        }
    }

    func answer(userInput requestID: String, answers: [String: [String]]) {
        guard case .question(let request)? = prompts[requestID] else { return }
        prompts[requestID] = nil
        reply(to: requestID, with: ClaudePermissions.answersResponse(request, answers: answers))
    }

    func interrupt() {
        guard let current = turn, !current.interruptRequested else { return }
        turn?.interruptRequested = true
        // A turn still being prepared stops in `send` before its message goes out.
        guard current.accepted else { return }
        let turnID = current.id
        let grace = interruptGracePeriod
        Task { [weak self] in
            // `cancel_queued` also drops the message when Claude had not started it yet.
            let response = try? await self?.control(["subtype": "interrupt", "cancel_queued": true], timeout: 10)
            if let self, self.turn?.id == turnID,
                response?["cancelled"]?.array?.contains(.string(turnID)) == true
            {
                self.finishTurn(.interrupted)
            }
        }
        Task { [weak self] in
            try? await Task.sleep(for: grace)
            self?.interruptTimedOut(turnID)
        }
    }

    func shutdown() {
        guard !isShutDown else { return }
        isShutDown = true
        turn = nil
        prompts.removeAll()
        cancelTails()
        failPendingControls(AgentError.notRunning)
        transport?.closeInput()
        transport?.terminate()
        transport = nil
    }

    // MARK: Launching

    private func turnSettings(_ selection: ModelSelection, access: AccessMode, interaction: InteractionMode) -> TurnSettings {
        let resolved = ClaudeInitializeInfo.resolvedModel(for: selection.modelID, in: knownModels)
        return TurnSettings(
            model: ClaudeModelCatalog.launchModel(for: selection.modelID),
            effort: ClaudeModelCatalog.effortPlan(modelID: selection.modelID, resolvedModel: resolved, effort: selection.effort),
            permissionMode: ClaudeLaunchConfig.permissionMode(access: access, interaction: interaction))
    }

    /// Starts a process; when the saved conversation is gone, starts a fresh one instead.
    private func launchProcess(identity: ClaudeLaunchConfig.Identity, settings: TurnSettings) async throws {
        func config(_ identity: ClaudeLaunchConfig.Identity) -> ClaudeLaunchConfig {
            ClaudeLaunchConfig(
                identity: identity, model: settings.model, effort: settings.effort, permissionMode: settings.permissionMode)
        }
        do {
            try await spawn(config(identity))
        } catch let failure as StartFailure where failure.missingConversation {
            guard case .resume = identity else { throw failure }
            conversationExists = false
            try await spawn(config(.fresh(Self.newID())))
        }
    }

    private func spawn(_ config: ClaudeLaunchConfig) async throws {
        let transport = makeTransport(config)
        self.transport = transport
        handshake = Handshake()
        transport.onLine = { [weak self, weak transport] line in
            guard let self, let transport, transport === self.transport else { return }
            self.receive(line)
        }
        transport.onExit = { [weak self, weak transport] status, stderrTail in
            guard let self, let transport else { return }
            self.transportExited(transport, status: status, stderrTail: stderrTail)
        }
        do {
            try transport.start()
        } catch {
            self.transport = nil
            handshake = nil
            throw AgentError.providerError(String(localized: "Claude Code could not be started: \(error.localizedDescription)"))
        }

        let response: JSONValue
        do {
            response = try await control(
                ["subtype": "initialize", "appendSystemPrompt": .string(Self.runtimeInstructions)], timeout: 90)
        } catch {
            let handshake = self.handshake ?? Handshake()
            self.handshake = nil
            if self.transport === transport {
                self.transport = nil
                transport.closeInput()
                transport.terminate()
            }
            throw StartFailure(error: error, handshake: handshake)
        }
        handshake = nil

        let info = ClaudeInitializeInfo(response: response)
        if !info.models.isEmpty {
            knownModels = info.models
            emit(.modelsDiscovered(ClaudeModelCatalog.models(fromInitialize: info.models)))
        }
        live = LiveSettings(model: config.model, effort: config.effort, requestedMode: config.permissionMode)
        if case .resume = config.identity { conversationExists = true }
        if sessionID != config.sessionID {
            sessionID = config.sessionID
            emit(.sessionStarted(id: config.sessionID))
        }
        if config.permissionMode == "bypassPermissions", let mode = info.permissionMode, mode != "bypassPermissions" {
            await fallBackFromFullAccess()
        }
    }

    /// Restarts the process on the same conversation, for changes the protocol cannot apply live.
    private func relaunch(_ settings: TurnSettings) async throws {
        await stopTransport()
        try await launchProcess(identity: restartIdentity, settings: settings)
    }

    /// How a new process picks up this session's conversation.
    private var restartIdentity: ClaudeLaunchConfig.Identity {
        guard let sessionID else { return .fresh(Self.newID()) }
        return conversationExists ? .resume(sessionID) : .fresh(sessionID)
    }

    /// Ends the current process and waits briefly for it to exit, so a new one can resume its conversation.
    private func stopTransport() async {
        guard let old = transport else { return }
        transport = nil
        cancelTails()
        failPendingControls(AgentError.notRunning)
        mapper.processRestarted()
        await withCheckedContinuation { continuation in
            let waiter = ExitWaiter(continuation)
            old.onExit = { _, _ in waiter.finish() }
            old.closeInput()
            old.terminate()
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(4))
                waiter.finish()
            }
        }
    }

    /// Claude Code refused full access (settings or policy). Like T3, fall back to auto mode, then to asking.
    private func fallBackFromFullAccess() async {
        let auto = try? await control(["subtype": "set_permission_mode", "mode": "auto"])
        guard !noticedFullAccessFallback else { return }
        noticedFullAccessFallback = true
        emit(
            .notice(
                auto?["mode"]?.string == "auto"
                    ? String(localized: "Claude Code's settings don't allow full access, so it decides approvals itself (auto mode).")
                    : String(localized: "Claude Code's settings don't allow full access, so it will ask before using tools.")))
    }

    // MARK: Per-turn changes

    /// Applies the turn's model, effort and permission mode, live when the protocol allows it.
    private func apply(_ settings: TurnSettings) async throws {
        guard var live else { throw AgentError.notRunning }
        var needsRelaunch = false
        if settings.model != live.model {
            if let model = settings.model ?? ClaudeInitializeInfo.resolvedModel(for: ClaudeModelCatalog.defaultModelID, in: knownModels),
                (try? await control(["subtype": "set_model", "model": .string(model)])) != nil
            {
                live.model = settings.model
            } else {
                needsRelaunch = true
            }
        }
        // Claude only clears an effort by reloading its settings, which takes a new process.
        if !needsRelaunch, !live.effortMatches(settings.effort) {
            if settings.effort.cliEffort == nil, live.effort.cliEffort != nil {
                needsRelaunch = true
            } else {
                var flags: [String: JSONValue] = ["ultracode": settings.effort.ultracode ? true : .null]
                if let effort = settings.effort.cliEffort { flags["effortLevel"] = .string(effort) }
                if (try? await control(["subtype": "apply_flag_settings", "settings": .object(flags)])) != nil {
                    live.effort = settings.effort
                } else {
                    needsRelaunch = true
                }
            }
        }
        self.live = live
        if needsRelaunch {
            try await relaunch(settings)
            return
        }

        // Claude may have entered or left plan mode itself; otherwise keep modes it chose with the user,
        // such as accepting edits after "Always allow".
        let mode = settings.permissionMode
        guard mode != live.requestedMode || mapper.changedPlanMode else { return }
        let response: JSONValue
        do {
            response = try await control(["subtype": "set_permission_mode", "mode": .string(mode)])
        } catch {
            // Claude refused the switch (for example into full access without consent); start in the mode instead.
            try await relaunch(settings)
            return
        }
        self.live?.requestedMode = mode
        if mode == "bypassPermissions", let applied = response["mode"]?.string, applied != mode {
            await fallBackFromFullAccess()
        }
    }

    // MARK: Frames

    private func receive(_ line: String) {
        guard !isShutDown, let frame = JSONValue.parse(line) else { return }
        switch frame["type"]?.string {
        case "control_response"?:
            resolveControl(frame["response"] ?? .null)
        case "control_request"?:
            handleControlRequest(frame)
        case "control_cancel_request"?:
            if let requestID = frame["request_id"]?.string { withdrawPrompt(requestID: requestID) }
        case "keep_alive"?:
            break
        case "command_lifecycle"?:
            handleLifecycle(frame)
        case "result"?:
            // A result while starting up only explains why the start failed.
            if handshake != nil {
                handshake?.resultErrors += (frame["errors"]?.array ?? []).compactMap(\.string)
            } else {
                emit(mapper.map(frame))
                finishTurnIfOwned(by: frame)
            }
        default:
            if frame["type"]?.string == "system", frame["subtype"]?.string == "task_started" { startTail(frame) }
            if frame["type"]?.string == "user" {
                // The tool's own output replaces anything tailed so far.
                for block in frame.at("message.content")?.array ?? [] {
                    if let id = block["tool_use_id"]?.string { tails.removeValue(forKey: id)?.cancel() }
                }
            }
            let reportedID = mapper.sessionID
            emit(mapper.map(frame))
            // Claude moved the conversation to a new id: a copy of a session in use elsewhere, or a reset the
            // user asked for with /clear. Neither should be recapped.
            if let id = mapper.sessionID, id != reportedID, id != sessionID {
                sessionID = id
                conversationExists = true
                emit(.sessionContinued(id: id))
            }
        }
    }

    private func handleLifecycle(_ frame: JSONValue) {
        guard let uuid = frame["command_uuid"]?.string, let current = turn, uuid == current.id else { return }
        lifecycleSeen = true
        switch frame["state"]?.string {
        case "started"?:
            turn?.started = true
        case "completed"?:
            // The result normally ends the turn first.
            if current.accepted { finishTurn(current.interruptRequested ? .interrupted : .completed) }
        case "cancelled"?:
            finishTurn(.interrupted)
        default:
            break
        }
    }

    private func finishTurnIfOwned(by result: JSONValue) {
        guard let current = turn, current.accepted else { return }
        // With lifecycle frames, a result before our message started belongs to a turn Claude began itself.
        let lifecycle = lifecycleSeen || mapper.capabilities.contains("msg_lifecycle_v1")
        if lifecycle && !current.started { return }
        let outcome = ClaudeEventMapper.outcome(
            of: result, interruptRequested: current.interruptRequested, assistantError: mapper.assistantError)
        if outcome == .completed, let error = mapper.assistantError, !error.text.isEmpty { emit(.notice(error.text)) }
        finishTurn(outcome)
    }

    private func finishTurn(_ outcome: TurnOutcome) {
        guard turn != nil else { return }
        turn = nil
        // Claude withdraws prompts of a finished turn; the runner closes their items.
        prompts.removeAll()
        cancelTails()
        emit(.turnCompleted(outcome))
    }

    private func interruptTimedOut(_ turnID: String) {
        guard turn?.id == turnID else { return }
        finishTurn(.interrupted)
        // Claude did not stop. End the process; the next turn resumes the saved conversation.
        guard let stuck = transport else { return }
        transport = nil
        failPendingControls(AgentError.notRunning)
        mapper.processRestarted()
        stuck.closeInput()
        stuck.terminate()
        emit(.sessionExited(error: nil))
    }

    private func transportExited(_ exited: ClaudeTransport, status: Int32, stderrTail: String) {
        guard exited === transport else { return }
        transport = nil
        cancelTails()
        prompts.removeAll()
        if handshake != nil {
            handshake?.exit = (status, stderrTail)
            failPendingControls(AgentError.notRunning)
            return
        }
        let message = Self.exitMessage(status: status, stderrTail: stderrTail)
        failPendingControls(AgentError.providerError(message ?? String(localized: "Claude Code exited.")))
        guard !isShutDown else { return }
        mapper.processRestarted()
        if let current = turn, current.accepted {
            finishTurn(
                current.interruptRequested
                    ? .interrupted : .failed(message ?? String(localized: "Claude Code exited before finishing the turn.")))
        }
        emit(.sessionExited(error: message))
    }

    // MARK: Permission prompts

    private func handleControlRequest(_ frame: JSONValue) {
        guard let requestID = frame["request_id"]?.string, let request = frame["request"] else { return }
        switch request["subtype"]?.string {
        case "can_use_tool"?:
            handlePermission(requestID: requestID, request: request)
        case "elicitation"?:
            // MCP servers asking for input; the SDK declines when the host has no form for it.
            reply(to: requestID, with: ["action": "decline"])
        case "request_user_dialog"?:
            // Not declared in `initialize`, so Claude settles these itself.
            break
        case let subtype:
            replyError(to: requestID, message: "Unsupported control request: \(subtype ?? "unknown")")
        }
    }

    private func handlePermission(requestID: String, request: JSONValue) {
        let toolName = request["tool_name"]?.string ?? ""
        let input = request["input"] ?? [:]
        if let toolUseID = request["tool_use_id"]?.string {
            emit(mapper.ensureTool(id: toolUseID, name: toolName, input: input))
        }
        switch toolName {
        case "ExitPlanMode":
            if interaction == .plan {
                // T3's plan capture: the plan is shown, and Claude waits for the user's next message.
                reply(to: requestID, with: ClaudePermissions.deny(request, message: ClaudePermissions.planCapturedMessage, interrupt: false))
            } else if access == .fullAccess {
                reply(to: requestID, with: ClaudePermissions.allow(request, forSession: false))
            } else {
                prompts[requestID] = .plan(request)
                emit(.approvalRequested(ClaudePermissions.planApproval(requestID: requestID, request: request)))
            }
        case "AskUserQuestion":
            guard let questions = ClaudePermissions.userInput(requestID: requestID, input: input) else {
                reply(to: requestID, with: ClaudePermissions.deny(request, message: "There were no questions to answer.", interrupt: false))
                return
            }
            prompts[requestID] = .question(request)
            emit(.userInputRequested(questions))
        default:
            // Under full access only asks Claude refuses to bypass get here (ask rules, safety checks).
            prompts[requestID] = .tool(request)
            emit(
                .approvalRequested(
                    ClaudePermissions.approval(
                        requestID: requestID, request: request, workingDirectory: launch.workingDirectory.path,
                        fileContents: mapper.fileContents)))
        }
    }

    /// Claude withdrew a request, for example because the turn was interrupted.
    private func withdrawPrompt(requestID: String) {
        switch prompts.removeValue(forKey: requestID) {
        case .question?: emit(.userInputResolved(id: requestID))
        case .tool?, .plan?: emit(.approvalResolved(id: requestID))
        case nil: break
        }
    }

    // MARK: Control channel

    @discardableResult
    private func control(_ request: JSONValue, timeout: TimeInterval = 30) async throws -> JSONValue {
        guard let transport else { throw AgentError.notRunning }
        let id = Self.newID()
        let frame: JSONValue = ["request_id": .string(id), "type": "control_request", "request": request]
        return try await withCheckedThrowingContinuation { continuation in
            pendingControls[id] = continuation
            controlTimeouts[id] = Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                guard !Task.isCancelled else { return }
                self?.completeControl(id, with: .failure(AgentError.timeout(String(localized: "Claude Code"))))
            }
            transport.write(frame.compactJSON)
        }
    }

    private func resolveControl(_ response: JSONValue) {
        guard let id = response["request_id"]?.string else { return }
        if response["subtype"]?.string == "error" {
            let message = response["error"]?.string ?? String(localized: "Claude Code rejected the request.")
            completeControl(id, with: .failure(AgentError.providerError(message)))
        } else {
            completeControl(id, with: .success(response["response"] ?? .null))
        }
    }

    private func completeControl(_ id: String, with result: Result<JSONValue, Error>) {
        controlTimeouts.removeValue(forKey: id)?.cancel()
        pendingControls.removeValue(forKey: id)?.resume(with: result)
    }

    private func failPendingControls(_ error: Error) {
        for id in Array(pendingControls.keys) { completeControl(id, with: .failure(error)) }
    }

    private func reply(to requestID: String, with response: JSONValue) {
        let frame: JSONValue = [
            "type": "control_response", "response": ["subtype": "success", "request_id": .string(requestID), "response": response],
        ]
        transport?.write(frame.compactJSON)
    }

    private func replyError(to requestID: String, message: String) {
        let frame: JSONValue = [
            "type": "control_response",
            "response": ["subtype": "error", "request_id": .string(requestID), "error": .string(message)],
        ]
        transport?.write(frame.compactJSON)
    }

    // MARK: Command output

    private func startTail(_ frame: JSONValue) {
        guard frame["task_type"]?.string == "local_bash", frame["is_backgrounded"]?.bool != true,
            let toolUseID = frame["tool_use_id"]?.string, let taskID = frame["task_id"]?.string,
            mapper.isVisibleTool(toolUseID), ClaudeTools.category(for: mapper.toolName(for: toolUseID) ?? "") == .command,
            tails[toolUseID] == nil, let session = frame["session_id"]?.string ?? sessionID
        else { return }
        let tail = ClaudeTaskOutputTail(
            root: ClaudeTaskOutputTail.root(environment: launch.environment), sessionID: session, taskID: taskID
        ) { [weak self] chunk in
            self?.emit(.toolOutput(id: toolUseID, delta: chunk))
        }
        tails[toolUseID] = tail
        tail.start()
    }

    private func cancelTails() {
        for tail in tails.values { tail.cancel() }
        tails.removeAll()
    }

    // MARK: Helpers

    private func emit(_ events: [AgentEvent]) {
        for event in events { emit(event) }
    }

    private func emit(_ event: AgentEvent) {
        guard !isShutDown else { return }
        onEvent?(event)
    }

    static func userMessage(content: JSONValue, uuid: String) -> JSONValue {
        ["type": "user", "message": ["role": "user", "content": content], "parent_tool_use_id": nil, "uuid": .string(uuid)]
    }

    static func exitMessage(status: Int32, stderrTail: String) -> String? {
        let lines = stderrTail.split(whereSeparator: \.isNewline).suffix(6).joined(separator: "\n")
        let detail = ClaudeEventMapper.cleaned(lines)
        guard status != 0 || detail != nil else { return nil }
        let summary = String(localized: "Claude Code exited with status \(Int(status)).")
        return detail.map { summary + "\n" + String($0.suffix(800)) } ?? summary
    }

    private static func newID() -> String { UUID().uuidString.lowercased() }

    /// Why a process did not finish its handshake.
    private struct StartFailure: LocalizedError {
        var message: String
        /// `--resume` named a conversation Claude no longer has.
        var missingConversation: Bool

        init(error: Error, handshake: Handshake) {
            let stderr = handshake.exit.map { ClaudeEventMapper.cleaned($0.stderr) ?? "" } ?? ""
            let details = (handshake.resultErrors + [stderr]).filter { !$0.isEmpty && !$0.hasPrefix("[ede_diagnostic]") }
            missingConversation = details.contains { $0.contains("No conversation found") }
            if let exit = handshake.exit {
                let reason = details.first.map { String($0.suffix(800)) } ?? String(localized: "status \(Int(exit.status))")
                message = String(localized: "Claude Code exited while starting: \(reason)")
            } else {
                message = error.localizedDescription
            }
        }

        var errorDescription: String? { message }
    }

    @MainActor
    private final class ExitWaiter {
        private var continuation: CheckedContinuation<Void, Never>?

        init(_ continuation: CheckedContinuation<Void, Never>) {
            self.continuation = continuation
        }

        func finish() {
            continuation?.resume()
            continuation = nil
        }
    }
}
