import Foundation

/// A live Claude Code process for one thread, speaking the SDK's stream-json control protocol:
/// `initialize`, user messages stamped with a uuid (and, to steer a running turn, priority `now`),
/// `can_use_tool` permission prompts, MCP elicitations, `interrupt`, `set_model`, `apply_flag_settings`
/// and `set_permission_mode`.
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
        /// The uuid stamped on the user message; `command_lifecycle` frames and results refer to it.
        let id: String
        /// Messages the user added while the turn ran (steering it), in order.
        var steerIDs: [String] = []
        /// Messages of the turn Claude is done with: a result answered them, or their lifecycle ended.
        var settled: Set<String> = []
        /// The message was written to Claude.
        var accepted = false
        /// Claude started running it (it may first finish a turn it started on its own).
        var started = false
        var interruptRequested = false

        var messageIDs: [String] { [id] + steerIDs }
        /// Steers Claude has not answered yet: a result before them ends only a part of the turn.
        var pendingSteers: [String] { steerIDs.filter { !settled.contains($0) } }
    }

    /// What a turn asks for, in CLI terms.
    private struct TurnSettings {
        var model: String?
        var effort: ClaudeModelCatalog.EffortPlan
        var permissionMode: String
        var allowsBypass: Bool
    }

    /// What the running process was told.
    private struct LiveSettings {
        var model: String?
        var effort: ClaudeModelCatalog.EffortPlan
        var requestedMode: String
        var allowsBypass: Bool

        func effortMatches(_ other: ClaudeModelCatalog.EffortPlan) -> Bool {
            effort.cliEffort == other.cliEffort && effort.ultracode == other.ultracode
        }
    }

    /// A request waiting for the user, keyed by its control request id.
    private enum PendingPrompt {
        case tool(JSONValue)
        case plan(JSONValue)
        case question(JSONValue)
        case elicitation(JSONValue)
    }

    /// Output gathered while a process starts, to explain why it did not.
    private struct Handshake {
        var resultErrors: [String] = []
        var exit: (status: Int32, stderr: String)?
    }

    private let launch: AgentLaunch
    private let makeTransport: TransportFactory
    private var knownModels: [JSONValue]
    /// Commands and skills Claude Code offers here, so `$name` in a message can run one.
    private var commandNames: Set<String> = []
    private var transport: ClaudeTransport?
    private var mapper: ClaudeEventMapper
    private var live: LiveSettings?
    private var access: AccessMode
    private var interaction: InteractionMode
    /// Claude has a saved conversation under `sessionID` that a new process must resume.
    private var conversationExists = false
    private var turn: Turn?
    /// A turn Claude started by itself between our turns, for example to answer finished background work.
    /// True once it is being stopped.
    private var agentTurn: Bool?
    /// A turn ended before its result arrived (stopped, or its lifecycle completed first); frames until that
    /// result still belong to it rather than to a turn Claude starts by itself.
    private var endedTurnResultPending = false
    private var lifecycleSeen = false
    private var handshake: Handshake?
    private var pendingControls: [String: CheckedContinuation<JSONValue, Error>] = [:]
    private var controlTimeouts: [String: Task<Void, Never>] = [:]
    private var prompts: [String: PendingPrompt] = [:]
    private var tails: [String: ClaudeTaskOutputTail] = [:]
    private var noticedFullAccessFallback = false
    private var isShutDown = false

    init(
        launch: AgentLaunch, knownModels: [JSONValue] = [], overageIncludedName: String? = nil,
        makeTransport: TransportFactory? = nil
    ) {
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
        mapper.overageIncludedName = overageIncludedName
    }

    // MARK: AgentSession

    func start() async throws {
        guard !isShutDown else { throw AgentError.notRunning }
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
        // A turn Claude started itself is no longer reported on its own; its result does not end this one.
        agentTurn = nil
        access = input.accessMode
        interaction = input.interactionMode
        let conversationBefore = sessionID
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
            // A relaunch that could not resume the conversation started a new one, which needs the whole recap.
            let isNewConversation = sessionID != conversationBefore
            let texts = Self.promptTexts(
                message: input.message, recap: input.recap(forNewSession: isNewConversation),
                ultrathink: settings.effort.ultrathink, skills: commandNames)
            let (images, skipped) = ClaudeAttachments.imageBlocks(for: input.imagePaths)
            let documents = ClaudeAttachments.documentBlocks(for: input.filePaths)
            guard turn?.id == turnID else { return }
            if turn?.interruptRequested == true {
                finishTurn(.interrupted)
                return
            }
            guard let transport else { throw AgentError.notRunning }
            for path in skipped {
                emit(.notice(String(localized: "Couldn't attach \((path as NSString).lastPathComponent).")))
            }
            mapper.beginTurn()
            transport.write(Self.userMessage(texts: texts, images: images, documents: documents, uuid: turnID).compactJSON)
            turn?.accepted = true
            if !conversationExists, let title = TerminalText.nonEmpty(input.threadTitle) { name(title) }
            conversationExists = true
        } catch {
            if turn?.id == turnID { turn = nil }
            throw error
        }
    }

    let supportsSteering = true

    /// Writes the message into the running turn with priority `now`, as the Agent SDK steers: Claude moves running
    /// commands to the background or stops streaming, takes the message in and answers it in the same turn. Running
    /// subagents would be cancelled, so they are moved to the background first (for at most five seconds), as T3 Code
    /// does.
    func steer(_ input: AgentTurnInput) async throws {
        let refusal = AgentError.providerError(String(localized: "Claude Code can't take a message for this turn now."))
        guard !isShutDown, transport != nil, let current = turn, current.accepted, !current.interruptRequested else {
            throw refusal
        }
        // Requested together, so the steer waits at most one request's timeout.
        let moves = mapper.foregroundAgentCalls.map { id in
            Task { [weak self] in
                _ = try? await self?.control(["subtype": "background_tasks", "tool_use_id": .string(id)], timeout: 5)
            }
        }
        for move in moves { await move.value }
        // The turn may have ended meanwhile; a message now would start a turn nobody asked for.
        guard !isShutDown, let transport, turn?.id == current.id, turn?.interruptRequested == false else { throw refusal }
        let texts = Self.promptTexts(
            message: input.message, recap: nil, ultrathink: live?.effort.ultrathink ?? false, skills: commandNames)
        let (images, skipped) = ClaudeAttachments.imageBlocks(for: input.imagePaths)
        for path in skipped {
            emit(.notice(String(localized: "Couldn't attach \((path as NSString).lastPathComponent).")))
        }
        let documents = ClaudeAttachments.documentBlocks(for: input.filePaths)
        let id = Self.newID()
        turn?.steerIDs.append(id)
        transport.write(
            Self.userMessage(texts: texts, images: images, documents: documents, uuid: id, priority: "now").compactJSON)
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
        case .question?, .elicitation?, nil:
            break
        }
    }

    func answer(userInput requestID: String, answers: [String: [String]]) {
        switch prompts[requestID] {
        case .question(let request)?:
            prompts[requestID] = nil
            reply(to: requestID, with: ClaudePermissions.answersResponse(request, answers: answers))
        case .elicitation(let request)?:
            prompts[requestID] = nil
            reply(to: requestID, with: ClaudePermissions.elicitationResponse(request, answers: answers))
        case .tool?, .plan?, nil:
            break
        }
    }

    func interrupt() {
        guard let current = turn, !current.interruptRequested else {
            // A turn Claude started by itself: stop it; its result then ends it as interrupted.
            if turn == nil, agentTurn == false {
                agentTurn = true
                Task { [weak self] in _ = try? await self?.control(["subtype": "interrupt"], timeout: 10) }
            }
            return
        }
        turn?.interruptRequested = true
        // A turn still being prepared stops in `send` before its message goes out.
        guard current.accepted else { return }
        let turnID = current.id
        let grace = interruptGracePeriod
        Task { [weak self] in
            // `cancel_queued` also drops the message when Claude had not started it yet (it may be finishing a
            // turn it began itself), and stops that turn too.
            let response = try? await self?.control(["subtype": "interrupt", "cancel_queued": true], timeout: 10)
            let cancelled = Set((response?["cancelled"]?.array ?? []).compactMap(\.string))
            if let self, let current = self.turn, current.id == turnID, !cancelled.isDisjoint(with: current.messageIDs) {
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
            permissionMode: ClaudeLaunchConfig.permissionMode(access: access, interaction: interaction),
            allowsBypass: ClaudeLaunchConfig.allowsBypass(access: access))
    }

    /// Starts a process. When the saved conversation is gone it starts a fresh one; when a fresh id turns out to be
    /// taken (its conversation was saved after all) it resumes that one.
    private func launchProcess(identity: ClaudeLaunchConfig.Identity, settings: TurnSettings) async throws {
        func config(_ identity: ClaudeLaunchConfig.Identity) -> ClaudeLaunchConfig {
            ClaudeLaunchConfig(
                identity: identity, model: settings.model, effort: settings.effort, permissionMode: settings.permissionMode,
                allowsBypass: settings.allowsBypass)
        }
        do {
            try await spawn(config(identity))
        } catch let failure as StartFailure where failure.missingConversation {
            guard case .resume = identity else { throw failure }
            conversationExists = false
            try await spawn(config(.fresh(Self.newID())))
            // The new conversation gets the next turn's recap of the whole thread (the runner builds it once `start`
            // reported the new id, `send` once a relaunch did), not the history itself.
            emit(
                .notice(
                    String(
                        localized:
                            "Claude Code could not find this thread's saved conversation, so it started a new one with a recap of the earlier messages.")))
        } catch let failure as StartFailure where failure.sessionInUse {
            guard case .fresh(let id) = identity else { throw failure }
            try await spawn(config(.resume(id)))
        }
    }

    private func spawn(_ config: ClaudeLaunchConfig) async throws {
        guard !isShutDown else { throw AgentError.notRunning }
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
                ["subtype": "initialize", "appendSystemPrompt": .string(Self.runtimeInstructions)], timeout: 180)
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
        // Shut down (or replaced) while the handshake was finishing.
        guard !isShutDown, self.transport === transport else { throw AgentError.notRunning }

        let info = ClaudeInitializeInfo(response: response)
        if !info.models.isEmpty {
            knownModels = info.models
            emit(.modelsDiscovered(ClaudeModelCatalog.models(fromInitialize: info.models)))
        }
        commandNames = Set(info.commands.map(\.name))
        if !info.commands.isEmpty { emit(.commandsDiscovered(info.commands)) }
        live = LiveSettings(
            model: config.model, effort: config.effort, requestedMode: config.permissionMode, allowsBypass: config.allowsBypass)
        mapper.notePermissionMode(info.permissionMode)
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
        let stopped = mapper.backgroundTasks.values.sorted()
        await stopTransport()
        if !stopped.isEmpty {
            emit(
                .notice(
                    String(
                        localized:
                            "Claude Code restarted to apply the new settings, which stopped its background work: \(stopped.joined(separator: ", "))."
                    )))
        }
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
        withdrawPrompts()
        failPendingControls(AgentError.notRunning)
        processRestarted()
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
        mapper.notePermissionMode(auto?["mode"]?.string)
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
        // Full access needs a process started for it, and leaving full access drops that process.
        var needsRelaunch = settings.allowsBypass != live.allowsBypass
        if !needsRelaunch, settings.model != live.model {
            // `default` switches back to Claude Code's own default model.
            let model = settings.model ?? ClaudeModelCatalog.defaultModelID
            if (try? await control(["subtype": "set_model", "model": .string(model)])) != nil {
                live.model = settings.model
            } else {
                needsRelaunch = true
            }
        }
        // Clearing an effort must reload the user's own setting, which takes a new process (as in T3).
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
            // The process exited while a setting was being applied: the session has ended (the runner dropped it on
            // `sessionExited`), so it must not start another process and send the message there.
            guard transport != nil else { throw AgentError.notRunning }
            try await relaunch(settings)
            return
        }

        // Claude may have entered or left plan mode itself; otherwise keep modes it chose with the user,
        // such as accepting edits after "Always allow".
        let mode = settings.permissionMode
        let planModeDiffers = mapper.permissionMode.map { ($0 == "plan") != (mode == "plan") } ?? false
        guard mode != live.requestedMode || mapper.changedPlanMode || planModeDiffers else { return }
        let response: JSONValue
        do {
            response = try await control(["subtype": "set_permission_mode", "mode": .string(mode)])
        } catch {
            // The process exited meanwhile and the session ended with it; don't start another one.
            guard transport != nil else { throw error }
            // Claude refused the switch; start in the mode instead.
            try await relaunch(settings)
            return
        }
        self.live?.requestedMode = mode
        mapper.notePermissionMode(response["mode"]?.string ?? mode)
        if mode == "bypassPermissions", let applied = response["mode"]?.string, applied != mode {
            await fallBackFromFullAccess()
        }
    }

    /// Names a new conversation after the thread, as OpenCode's sessions are, so Claude Code's own session list
    /// (`claude --resume`) shows the thread's title. Claude Code takes it as a name the user chose; should it refuse,
    /// the conversation keeps the title Claude Code gives it.
    private func name(_ title: String) {
        Task { [weak self] in
            _ = try? await self?.control(["subtype": "rename_session", "title": .string(title), "source": "host"], timeout: 10)
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
                let owned = ownsResult(frame)
                if owned { turn?.settled.formUnion(Self.answeredMessages(frame)) }
                emit(mapper.map(frame))
                if owned {
                    if !endsSegment(frame) { finishTurn(withResult: frame) }
                } else if turn == nil {
                    finishAgentTurn(withResult: frame)
                }
            }
        default:
            // A background subagent keeps writing frames (tagged with its Agent call) after the turn that launched it
            // ended; only the main conversation starts a turn of Claude's own.
            if turn == nil, agentTurn == nil, !endedTurnResultPending, frame["parent_tool_use_id"]?.string == nil,
                frame["type"]?.string == "stream_event" || frame["type"]?.string == "assistant"
            {
                // Claude answers on its own, for example after background work finished.
                agentTurn = false
                mapper.turnStarted()
                emit(.agentTurnStarted(note: String(localized: "Claude Code continued on its own.")))
            }
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
        guard let uuid = frame["command_uuid"]?.string, let current = turn, current.messageIDs.contains(uuid) else { return }
        lifecycleSeen = true
        switch frame["state"]?.string {
        case "started"?:
            // A steer that starts begins a new part of the turn, with a reply of its own.
            guard uuid != current.id || !current.started else { return }
            turn?.started = true
            mapper.turnStarted()
        case let state? where state == "completed" || state == "cancelled":
            turn?.settled.insert(uuid)
            // Claude may still answer a steer after the message before it ended: the turn goes on until all have.
            guard let updated = turn, updated.messageIDs.allSatisfy(updated.settled.contains) else { return }
            if state == "cancelled" {
                finishTurn(.interrupted)
                return
            }
            // The result normally ends the turn first.
            guard current.accepted else { return }
            if updated.started || updated.interruptRequested {
                finishTurn(updated.interruptRequested ? .interrupted : .completed)
            } else {
                finishTurn(.failed(String(localized: "Claude Code accepted the message but never started working on it.")))
            }
        default:
            break
        }
    }

    /// The messages a result answered.
    private static func answeredMessages(_ result: JSONValue) -> [String] {
        (result["user_message_uuids"]?.array ?? []).compactMap(\.string) + [result["user_message_uuid"]?.string].compactMap { $0 }
    }

    /// Whether a result of the turn ends only the part before a steer: Claude stopped streaming or tools to take the
    /// steer in (T3 Code's active-steering abort), or finished the earlier messages while a steer still waited. The
    /// turn ends with the result that answers its last steer. Without an echo of the answered messages (older
    /// versions), only an aborted result after a steer tells.
    private func endsSegment(_ result: JSONValue) -> Bool {
        guard let current = turn, !current.steerIDs.isEmpty, !current.interruptRequested else { return false }
        let terminal = result["terminal_reason"]?.string
        let aborted = terminal == "aborted_streaming" || terminal == "aborted_tools"
        if Self.answeredMessages(result).isEmpty { return aborted }
        guard !current.pendingSteers.isEmpty else { return false }
        return aborted
            || ClaudeEventMapper.outcome(of: result, interruptRequested: false, assistantError: mapper.assistantError) == .completed
    }

    /// Whether a result ends the current turn rather than one Claude started by itself (to follow up on finished
    /// background work, for example) while the message waited.
    private func ownsResult(_ result: JSONValue) -> Bool {
        guard let current = turn, current.accepted else { return false }
        // Results name the messages their turn consumed; ours may also have been folded into Claude's own turn.
        let echoed = Self.answeredMessages(result)
        if !echoed.isEmpty { return !Set(echoed).isDisjoint(with: current.messageIDs) }
        if let origin = result.at("origin.kind")?.string, origin != "human" { return false }
        // Without an echo, lifecycle frames tell whether our message has started.
        let lifecycle = lifecycleSeen || mapper.capabilities.contains("msg_lifecycle_v1")
        return !lifecycle || current.started
    }

    private func finishTurn(withResult result: JSONValue) {
        guard let current = turn else { return }
        let outcome = ClaudeEventMapper.outcome(
            of: result, interruptRequested: current.interruptRequested, assistantError: mapper.assistantError)
        if outcome == .completed { showUnreportedOutput(of: result, fallbackID: current.id) }
        finishTurn(outcome)
        endedTurnResultPending = false
    }

    /// A result between our turns: the late one of a turn that already ended, or the end of a turn Claude
    /// started by itself.
    private func finishAgentTurn(withResult result: JSONValue) {
        if endedTurnResultPending {
            endedTurnResultPending = false
            return
        }
        guard let stopping = agentTurn else { return }
        agentTurn = nil
        prompts.removeAll()
        cancelTails()
        let outcome = ClaudeEventMapper.outcome(of: result, interruptRequested: stopping, assistantError: mapper.assistantError)
        if outcome == .completed { showUnreportedOutput(of: result, fallbackID: Self.newID()) }
        emit(.turnCompleted(outcome))
    }

    /// What a completed turn showed nowhere else: an API error Claude reported as its reply, or output only the
    /// result carries (a slash command's, for example). A compaction item already shows `/compact`'s outcome.
    private func showUnreportedOutput(of result: JSONValue, fallbackID: String) {
        if let error = mapper.assistantError, !error.text.isEmpty {
            emit(.notice(error.text))
        } else if !mapper.emittedReply, !mapper.compactedThisTurn, let reply = ClaudeEventMapper.replyText(of: result) {
            emit(.assistantText(itemID: (result["uuid"]?.string ?? fallbackID) + ":result", text: reply))
        }
    }

    private func finishTurn(_ outcome: TurnOutcome) {
        guard let current = turn else { return }
        turn = nil
        // Claude still sends a result for a message it received.
        endedTurnResultPending = current.accepted
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
        withdrawPrompts()
        failPendingControls(AgentError.notRunning)
        processRestarted()
        stuck.closeInput()
        stuck.terminate()
        emit(.sessionExited(error: nil))
    }

    private func transportExited(_ exited: ClaudeTransport, status: Int32, stderrTail: String) {
        guard exited === transport else { return }
        transport = nil
        cancelTails()
        if handshake != nil {
            prompts.removeAll()
            handshake?.exit = (status, stderrTail)
            failPendingControls(AgentError.notRunning)
            return
        }
        let message = Self.exitMessage(status: status, stderrTail: stderrTail)
        failPendingControls(AgentError.providerError(message ?? String(localized: "Claude Code exited.")))
        guard !isShutDown else { return }
        if let current = turn, current.accepted {
            finishTurn(
                current.interruptRequested
                    ? .interrupted : .failed(message ?? String(localized: "Claude Code exited before finishing the turn.")))
        }
        // A turn Claude started by itself ends with the session.
        processRestarted()
        withdrawPrompts()
        emit(.sessionExited(error: message))
    }

    /// A new process (or none) runs the conversation: stream state and turns of the old one are gone.
    private func processRestarted() {
        // The old process's background work ended with it.
        if !mapper.backgroundTasks.isEmpty { emit(.backgroundWork([])) }
        mapper.processRestarted()
        agentTurn = nil
        endedTurnResultPending = false
    }

    // MARK: Permission prompts

    private func handleControlRequest(_ frame: JSONValue) {
        guard let requestID = frame["request_id"]?.string, let request = frame["request"] else { return }
        switch request["subtype"]?.string {
        case "can_use_tool"?:
            handlePermission(requestID: requestID, request: request)
        case "elicitation"?:
            // An MCP server asking for input: asked as questions when Coincide can show its form, else declined
            // as the SDK does without a handler.
            guard let questions = ClaudePermissions.elicitation(requestID: requestID, request: request) else {
                reply(to: requestID, with: ["action": "decline"])
                return
            }
            prompts[requestID] = .elicitation(request)
            emit(.userInputRequested(questions))
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
        // A subagent's tool calls are not transcript items of their own; the approval describes the call.
        if let toolUseID = request["tool_use_id"]?.string, request["agent_id"]?.string == nil {
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
            // Under full access only asks Claude refuses to bypass get here (ask rules, safety checks, plan mode).
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
        case .question?, .elicitation?: emit(.userInputResolved(id: requestID))
        case .tool?, .plan?: emit(.approvalResolved(id: requestID))
        case nil: break
        }
    }

    /// The process that asked is gone, so nothing can answer its requests any more.
    private func withdrawPrompts() {
        for requestID in Array(prompts.keys) { withdrawPrompt(requestID: requestID) }
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

    /// A user message as the SDK sends it, stamped with a uuid that lifecycle frames and results echo, and marked
    /// as typed by a person. Images and documents go first: Claude runs a slash command or skill only when it starts
    /// the last text block. Priority `now` steers a running turn.
    static func userMessage(
        texts: [String], images: [JSONValue] = [], documents: [JSONValue] = [], uuid: String, priority: String? = nil
    ) -> JSONValue {
        let texts = texts.filter { !$0.isEmpty }
        let attachments = images + documents
        let content: JSONValue =
            attachments.isEmpty && texts.count <= 1
            ? .string(texts.first ?? "") : .array(attachments + texts.map { ["type": "text", "text": .string($0)] })
        var message: [String: JSONValue] = [
            "type": "user", "message": ["role": "user", "content": content], "parent_tool_use_id": nil, "uuid": .string(uuid),
            "origin": ["kind": "human"],
        ]
        if let priority { message["priority"] = .string(priority) }
        return .object(message)
    }

    /// The text blocks of a user message. A slash command or skill (`/name …`) only runs when it starts the last
    /// text block, so after a recap it travels in a block of its own. Ultrathink is a request to the model, so it
    /// is not added to a command.
    static func promptTexts(message: String, recap: String?, ultrathink: Bool, skills: Set<String> = []) -> [String] {
        if let dispatch = skillDispatch(message, known: skills) {
            return [recap, dispatch.leading].compactMap { $0?.isEmpty == false ? $0 : nil } + [dispatch.command]
        }
        if let recap, !recap.isEmpty, message.range(of: #"^/[^\s/]+(\s|$)"#, options: .regularExpression) != nil {
            return [recap, message]
        }
        let prompt = Handoff.compose(message: message, recap: recap)
        return [ultrathink ? ClaudeModelCatalog.applyUltrathink(to: prompt) : prompt]
    }

    /// A message that names skills as `$name` (the composer's skill picker) runs the last one, as T3 Code does:
    /// Claude expands a skill only when `/name` starts the last text block, and takes everything after the name as its
    /// arguments. With text before it, the whole message goes first, with each skill written `/name`.
    static func skillDispatch(_ message: String, known: Set<String>) -> (leading: String?, command: String)? {
        guard !known.isEmpty, message.contains("$") else { return nil }
        let text = message as NSString
        let mentions = skillMention.matches(in: message, range: NSRange(location: 0, length: text.length)).filter {
            known.contains(text.substring(with: $0.range(at: 2)))
        }
        guard let last = mentions.last else { return nil }
        var converted = message
        for mention in mentions.reversed() {
            let range = mention.range(at: 2)
            converted = (converted as NSString).replacingCharacters(
                in: NSRange(location: range.location - 1, length: range.length + 1), with: "/" + text.substring(with: range))
        }
        let nameRange = last.range(at: 2)
        let before = text.substring(to: nameRange.location - 1).trimmingCharacters(in: .whitespacesAndNewlines)
        let after = text.substring(from: NSMaxRange(nameRange))
        let command = ("/" + text.substring(with: nameRange) + after).trimmingCharacters(in: .whitespacesAndNewlines)
        let leading = converted.trimmingCharacters(in: .whitespacesAndNewlines)
        return (before.isEmpty ? nil : leading, command)
    }

    /// `$name` after a space or at the start, with at least one letter so prices such as `$20` are left alone.
    private static let skillMention = try! NSRegularExpression(
        pattern: #"(^|\s)\$(?=[A-Za-z0-9:_-]*[A-Za-z])([A-Za-z0-9][A-Za-z0-9:_-]*)(?=\s|$)"#)

    /// Why Claude Code ended on its own, with the last lines it printed to stderr. Nil for a clean exit: status 0
    /// with nothing on stderr.
    nonisolated static func exitMessage(status: Int32, stderrTail: String) -> String? {
        let tail = TerminalText.tail(stderrTail, lines: 6, maxLength: 800)
        guard status != 0 || tail != nil else { return nil }
        let summary = String(localized: "\(ProviderKind.claude.displayName) exited unexpectedly (status \(status)).")
        return tail.map { summary + "\n" + $0 } ?? summary
    }

    private static func newID() -> String { UUID().uuidString.lowercased() }

    /// Why a process did not finish its handshake.
    private struct StartFailure: LocalizedError {
        var message: String
        /// `--resume` named a conversation Claude no longer has.
        var missingConversation: Bool
        /// `--session-id` named a conversation Claude already saved.
        var sessionInUse: Bool

        init(error: Error, handshake: Handshake) {
            // Claude's own errors for the failed start; its diagnostics explain nothing to the user.
            let errors = handshake.resultErrors.compactMap { TerminalText.nonEmpty($0) }.filter { !$0.hasPrefix("[ede_diagnostic]") }
            let stderr = handshake.exit.map { TerminalText.stripANSI($0.stderr) } ?? ""
            missingConversation = (errors + [stderr]).contains { $0.contains("No conversation found") }
            sessionInUse = (errors + [stderr]).contains { $0.contains("is already in use") }
            if let exit = handshake.exit {
                let reason =
                    errors.first.map { String($0.suffix(800)) } ?? TerminalText.tail(exit.stderr, lines: 6, maxLength: 800)
                    ?? String(localized: "status \(Int(exit.status))")
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

extension ClaudeSession: BackgroundWorkReporting {
    /// Background commands or agents Claude started keep running between turns; the idle sweep must not stop them.
    var hasBackgroundWork: Bool { !isShutDown && transport != nil && !mapper.backgroundTasks.isEmpty }
}
