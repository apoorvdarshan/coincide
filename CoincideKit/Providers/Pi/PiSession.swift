import Foundation

/// A Pi session driven through `pi --mode rpc`: JSON commands on stdin, responses and session events on stdout.
///
/// The session id is Pi's session file, which `switch_session` loads to resume. A turn is one `prompt`;
/// it ends when Pi reports `agent_settled` and `get_state` confirms nothing else is queued or compacting.
@MainActor
public final class PiSession: AgentSession {
    public let provider: ProviderKind = .pi
    public private(set) var sessionID: String?
    public var onEvent: ((AgentEvent) -> Void)?

    /// How long to wait for Pi. Tests shorten these.
    struct Timing {
        var request: Duration = .seconds(15)
        /// `switch_session` runs extension hooks and loads the whole session file.
        var lifecycle: Duration = .seconds(60)
        /// Idle probes and usage reads, which must not hold up the end of a turn.
        var quick: Duration = .seconds(2)
        /// The thread runner gives up on an interrupt after six seconds, so an abort has to settle sooner.
        var abort: Duration = .seconds(4)
        var exitGrace: Duration = .seconds(2)
        var probeRetry: Duration = .milliseconds(100)
    }

    typealias TransportFactory = @MainActor (_ arguments: [String], _ environment: [String: String]) -> PiTransport

    /// The permission policy is fixed for a process's lifetime; changing it restarts Pi on the same session.
    private struct Policy: Equatable {
        var accessMode: AccessMode
        var interactionMode: InteractionMode
    }

    private struct Turn {
        let number: Int
        /// A prompt starting with `/` may be an extension command that never starts a run.
        let mayBeCommand: Bool
        var sawAgentStart = false
        var settled = false
        /// Bumped whenever Pi becomes busy again, so an older idle probe cannot end the turn.
        var probeGeneration = 0
        var interruptRequested = false
        var aborted = false
        var failure: String?
        var finishing = false
    }

    private struct OpenDialog {
        let dialog: PiDialog
        /// The turn that raised it; nil for dialogs Pi raised between turns, such as at startup.
        let turn: Int?
        var expiry: Task<Void, Never>?
    }

    /// What Pi uses without being told: its configured default model (as `provider/id`) and thinking level.
    private struct Baseline {
        var model: String?
        var thinking: String?
    }

    private let launch: AgentLaunch
    private let extensionDirectory: URL
    private let timing: Timing
    private let makeTransport: TransportFactory
    private var policy: Policy
    private var rpc: PiRPCClient?
    /// The process being started, before it is bound to a session.
    private var opening: PiRPCClient?
    private var mapper = PiTurnMapper()
    private var turn: Turn?
    private var turnCount = 0
    private var wakeCount = 0
    private var dialogs: [String: OpenDialog] = [:]
    private var alwaysAllowed: Set<String> = []
    /// Captured from the first process before it loads a saved session, so "Default" means Pi's default.
    private var baseline: Baseline?
    /// The model (`provider/id`) and thinking level the running process uses.
    private var currentModel: String?
    private var currentThinking: String?
    /// The process ended during a turn; the exit is reported right after that turn completes.
    private var exitAfterTurn: String?
    private var isClosed = false

    public convenience init(launch: AgentLaunch) {
        self.init(launch: launch, extensionDirectory: PiExtension.defaultDirectory, timing: Timing()) { arguments, environment in
            PiProcessTransport(
                executable: launch.executable, arguments: arguments, workingDirectory: launch.workingDirectory,
                environment: environment)
        }
    }

    init(launch: AgentLaunch, extensionDirectory: URL, timing: Timing, makeTransport: @escaping TransportFactory) {
        self.launch = launch
        self.extensionDirectory = extensionDirectory
        self.timing = timing
        self.makeTransport = makeTransport
        policy = Policy(accessMode: launch.accessMode, interactionMode: launch.interactionMode)
    }

    // MARK: AgentSession

    public func start() async throws {
        guard rpc == nil, opening == nil, !isClosed else { return }
        try await open(resuming: launch.resumeSessionID)
    }

    public func send(_ input: AgentTurnInput) async throws {
        guard !isClosed else { throw AgentError.notRunning }
        exitAfterTurn = nil
        // A turn the thread runner already gave up on may still be running in Pi; a new process cannot leak it.
        let abandoned = turn != nil
        if abandoned {
            turn = nil
            _ = mapper.finish()
            withdrawDialogs(announce: false) { _ in true }
        }
        let wanted = Policy(accessMode: input.accessMode, interactionMode: input.interactionMode)
        if abandoned || rpc?.isOpen != true || wanted != policy {
            policy = wanted
            try await reopen()
        }
        let compact = input.imagePaths.isEmpty ? PiCompactCommand.parse(input.text) : nil
        let images = try PiImages.payload(input.imagePaths)

        turnCount += 1
        let number = turnCount
        turn = Turn(number: number, mayBeCommand: compact == nil && input.text.hasPrefix("/"))
        mapper.begin(itemPrefix: "t\(number)")
        do {
            try await applySelection(input.selection)
        } catch {
            if turn?.number == number { turn = nil }
            throw error
        }
        // Interrupted while the model was being switched: nothing was sent, and the abort path ends the turn.
        guard let current = turn, current.number == number, !current.interruptRequested, let rpc else { return }
        if let compact {
            var record: [String: JSONValue] = ["type": "compact"]
            if let instructions = compact.instructions { record["customInstructions"] = .string(instructions) }
            rpc.request(.object(record), timeout: nil) { [weak self] in self?.compactAnswered(number, $0) }
        } else {
            // `steer` makes Pi queue the prompt if it is still busy instead of rejecting it.
            var record: [String: JSONValue] = ["type": "prompt", "message": .string(input.text), "streamingBehavior": "steer"]
            if !images.isEmpty { record["images"] = .array(images) }
            // Pi answers once slash commands and extension input handlers are done, which can wait on a dialog.
            rpc.request(.object(record), timeout: nil) { [weak self] in self?.promptAnswered(number, $0) }
        }
    }

    public func respond(to approvalID: String, optionID: String) {
        guard let open = dialogs.removeValue(forKey: approvalID) else { return }
        open.expiry?.cancel()
        client?.send(open.dialog.response(for: optionID))
        if optionID == PiDialog.allowAlwaysID, let key = open.dialog.rememberKey { alwaysAllowed.insert(key) }
        if open.dialog.declines(optionID), let toolCallID = open.dialog.request.toolCallID { mapper.markDeclined(toolCallID) }
    }

    public func interrupt() {
        guard var turn, !turn.finishing, !turn.interruptRequested else { return }
        turn.interruptRequested = true
        self.turn = turn
        let number = turn.number
        guard let rpc else {
            Task { await finishTurn(number) }
            return
        }
        // Once Pi settled it is only finishing up, such as an extension's compaction: stop that and end the turn now.
        if turn.settled { Task { await finishTurn(number) } }
        rpc.request(["type": "abort"], timeout: timing.abort) { [weak self] result in
            guard let self, self.turn?.number == number else { return }
            switch result {
            case .success:
                // Pi reports `agent_settled` before answering; this covers prompts that never started a run.
                self.probeIdle(number)
            case .failure(let error as PiRPCError) where error.isClosed:
                break
            case .failure:
                // Pi did not stop in time. End the process so the turn ends now; the next turn restarts Pi.
                self.discardProcess()
                Task { await self.finishTurn(number) }
            }
        }
    }

    public func shutdown() {
        guard !isClosed else { return }
        withdrawDialogs(announce: false) { _ in true }
        isClosed = true
        turn = nil
        let client = client
        rpc = nil
        opening = nil
        client?.shutDown(grace: timing.exitGrace)
    }

    // MARK: Process

    private var client: PiRPCClient? { rpc ?? opening }

    /// Starts Pi on the thread's session: the saved one when it can be resumed, otherwise a new one.
    private func open(resuming sessionPath: String?) async throws {
        let extensionPath: String
        do {
            extensionPath = try PiExtension.materialize(in: extensionDirectory).path
        } catch {
            throw AgentError.providerError(
                String(localized: "Coincide could not prepare its Pi extension: \(error.localizedDescription)"))
        }
        let resume = PiLaunch.resume(sessionPath, workingDirectory: launch.workingDirectory)
        do {
            do {
                try await handshake(extensionPath: extensionPath, resume: resume)
            } catch let error as PiRPCError where error.isClosed && resume.forkPath != nil {
                // Pi exits when it cannot fork the session file; continue in a new session instead.
                try await handshake(extensionPath: extensionPath, resume: .fresh)
            }
        } catch let error as PiRPCError {
            throw AgentError.providerError(error.localizedDescription)
        }
    }

    private func handshake(extensionPath: String, resume: PiLaunch.Resume) async throws {
        let transport = makeTransport(
            PiLaunch.arguments(extensionPath: extensionPath, forkingFrom: resume.forkPath),
            PiLaunch.environment(launch.environment, accessMode: policy.accessMode, interactionMode: policy.interactionMode))
        let client = PiRPCClient(transport: transport)
        client.onEvent = { [weak self, weak client] record in
            guard let self, let client, client === self.rpc || client === self.opening else { return }
            self.handle(record)
        }
        client.onExit = { [weak self, weak client] reason in
            guard let self, let client else { return }
            self.processEnded(client, reason: reason)
        }
        opening = client
        defer { if opening === client { opening = nil } }
        do {
            try client.start()
        } catch {
            throw AgentError.providerError(String(localized: "Coincide could not start Pi: \(error.localizedDescription)"))
        }
        do {
            if baseline == nil {
                let initial = try await client.request(["type": "get_state"], timeout: timing.request)
                baseline = Baseline(model: PiModels.slug(of: initial["model"]), thinking: initial["thinkingLevel"]?.string)
            }
            var resumed = true
            if case .switchTo(let path) = resume {
                do {
                    let result = try await client.request(
                        ["type": "switch_session", "sessionPath": .string(path)], timeout: timing.lifecycle)
                    resumed = result["cancelled"]?.bool != true
                } catch PiRPCError.rejected {
                    resumed = false
                }
            }
            let state = try await client.request(["type": "get_state"], timeout: timing.request)
            guard let id = state["sessionFile"]?.string ?? state["sessionId"]?.string else {
                throw AgentError.protocolError(String(localized: "Pi did not report a session."))
            }
            guard !isClosed else { throw AgentError.notRunning }
            // A resumed session brings back the model and level it last used.
            currentModel = PiModels.slug(of: state["model"])
            currentThinking = state["thinkingLevel"]?.string
            mapper.contextWindow = PiModels.contextWindow(of: state["model"])
            sessionID = id
            rpc = client
            emit(.sessionStarted(id: id))
            if let model = PiModels.slug(of: state["model"]) { emit(.modelResolved(model)) }
            if resume.forkPath != nil {
                emit(.notice(String(localized: "This thread’s folder changed, so Pi continues the conversation in a new session here.")))
            } else if !resumed {
                emit(.notice(String(localized: "Pi could not resume its earlier session for this thread and started a new one.")))
            }
        } catch {
            withdrawDialogs(announce: true) { $0.turn == nil }
            client.kill()
            throw error
        }
    }

    /// Restarts Pi on the current session, for a new permission policy or after the process went away.
    private func reopen() async throws {
        withdrawDialogs(announce: true) { $0.turn == nil }
        if let client = rpc {
            rpc = nil
            await client.stop(grace: timing.exitGrace)
        }
        try await open(resuming: sessionID ?? launch.resumeSessionID)
    }

    /// Kills the process without reporting its exit; the next turn starts a new one.
    private func discardProcess() {
        guard let client = rpc else { return }
        rpc = nil
        client.kill()
    }

    private func processEnded(_ client: PiRPCClient, reason: String) {
        guard client === rpc, !isClosed else { return }
        rpc = nil
        withdrawDialogs(announce: true) { $0.turn == nil }
        guard var turn else {
            emit(.sessionExited(error: reason))
            return
        }
        if !turn.interruptRequested { turn.failure = reason }
        self.turn = turn
        exitAfterTurn = reason
        guard !turn.finishing else { return }
        let number = turn.number
        Task { await finishTurn(number) }
    }

    // MARK: Model and thinking level

    /// Points Pi at the turn's model and thinking level; "Default" returns to Pi's own default.
    private func applySelection(_ selection: ModelSelection) async throws {
        guard let rpc else { throw AgentError.notRunning }
        let isDefault = selection.modelID == PiModels.defaultModelID || selection.modelID.isEmpty
        if let model = isDefault ? baseline?.model : selection.modelID, model != currentModel {
            guard let target = PiModels.parseSlug(model) else {
                throw AgentError.providerError(
                    String(localized: "Pi model ids look like provider/model, for example anthropic/claude-sonnet-4-5."))
            }
            let data: JSONValue
            do {
                data = try await rpc.request(
                    ["type": "set_model", "provider": .string(target.provider), "modelId": .string(target.modelID)],
                    timeout: timing.request)
            } catch PiRPCError.rejected(_, let message) {
                throw AgentError.providerError(String(localized: "Pi could not switch to \(model): \(message)"))
            }
            currentModel = model
            // Pi picks a thinking level for the new model, so the requested one is applied again below.
            currentThinking = nil
            mapper.contextWindow = PiModels.contextWindow(of: data) ?? mapper.contextWindow
            emit(.modelResolved(model))
        }
        guard let level = selection.effort ?? (isDefault ? baseline?.thinking : nil), level != currentThinking,
            PiModels.thinkingLevels.contains(level)
        else { return }
        // Pi clamps a level the model does not support rather than failing.
        _ = try await rpc.request(["type": "set_thinking_level", "level": .string(level)], timeout: timing.request)
        currentThinking = level
    }

    // MARK: Events

    private func handle(_ record: JSONValue) {
        guard let type = record["type"]?.string else { return }
        switch type {
        case "agent_start":
            if var turn {
                turn.sawAgentStart = true
                turn.settled = false
                turn.aborted = false
                turn.probeGeneration += 1
                self.turn = turn
            } else {
                // An extension started work between turns; it is shown, under its own item ids.
                wakeCount += 1
                mapper.begin(itemPrefix: "w\(wakeCount)")
            }
        case "agent_settled":
            guard var turn else {
                emit(mapper.finish())
                return
            }
            if turn.interruptRequested {
                Task { await finishTurn(turn.number) }
                return
            }
            turn.aborted = record["aborted"]?.bool == true
            turn.settled = true
            turn.probeGeneration += 1
            self.turn = turn
            probeIdle(turn.number)
        case "extension_ui_request":
            handleDialog(record)
        case "thinking_level_changed":
            currentThinking = record["level"]?.string
        case "compaction_start":
            if var turn {
                turn.probeGeneration += 1
                self.turn = turn
            }
            emit(mapper.handle(record))
        case "compaction_end":
            emit(mapper.handle(record))
            // A compaction after `agent_settled`, or a `/compact` turn, is the last work of the turn.
            if let turn, turn.settled || !turn.sawAgentStart { probeIdle(turn.number) }
        case "tool_execution_end":
            // A tool that ended while its approval was pending no longer needs it (Pi gave up waiting).
            if let toolCallID = record["toolCallId"]?.string {
                withdrawDialogs(announce: true) { $0.dialog.request.toolCallID == toolCallID }
            }
            emit(mapper.handle(record))
        case "response":
            // Responses without an id: Pi could not parse a line Coincide wrote.
            guard record["command"]?.string == "parse", record["success"]?.bool == false, var turn, !turn.finishing else { return }
            turn.failure = PiRPCClient.errorText(record["error"])
            self.turn = turn
            Task { await finishTurn(turn.number) }
        default:
            emit(mapper.handle(record))
        }
    }

    private func handleDialog(_ record: JSONValue) {
        if record["method"]?.string == "notify" {
            if turn != nil, let message = PiText.nonEmpty(record["message"]?.string) { emit(.notice(message)) }
            return
        }
        guard let dialog = PiDialog(record, tool: { mapper.tool($0) }) else { return }
        if let key = dialog.rememberKey, alwaysAllowed.contains(key) {
            client?.send(dialog.response(for: "allow"))
            return
        }
        let id = dialog.request.id
        var open = OpenDialog(dialog: dialog, turn: turn?.number)
        if let timeout = dialog.timeout {
            open.expiry = Task { [weak self] in
                try? await Task.sleep(for: timeout)
                // Pi answered the dialog itself with its default, so it no longer needs the user.
                guard !Task.isCancelled, let self, self.dialogs.removeValue(forKey: id) != nil else { return }
                self.emit(.approvalResolved(id: id))
            }
        }
        dialogs[id] = open
        emit(.approvalRequested(dialog.request))
    }

    /// Withdraws dialogs nobody will answer any more and tells Pi; `announce` reports them as resolved by the agent.
    private func withdrawDialogs(announce: Bool, where shouldWithdraw: (OpenDialog) -> Bool) {
        for (id, open) in dialogs where shouldWithdraw(open) {
            dialogs[id] = nil
            open.expiry?.cancel()
            client?.send(open.dialog.response(for: "cancel"))
            if announce { emit(.approvalResolved(id: id)) }
        }
    }

    // MARK: Ending turns

    private func promptAnswered(_ number: Int, _ result: Result<JSONValue, Error>) {
        guard var turn, turn.number == number, !turn.finishing else { return }
        switch result {
        case .success(let data):
            // "handled": an extension command consumed the prompt and no run starts. Older Pi says nothing.
            let disposition = data["disposition"]?.string
            if disposition == "handled" || (disposition == nil && turn.mayBeCommand && !turn.sawAgentStart) {
                probeIdle(number)
            }
        case .failure(let error as PiRPCError) where error.isClosed:
            break
        case .failure(let error):
            turn.failure = error.localizedDescription
            self.turn = turn
            Task { await finishTurn(number) }
        }
    }

    private func compactAnswered(_ number: Int, _ result: Result<JSONValue, Error>) {
        guard var turn, turn.number == number, !turn.finishing else { return }
        if case .failure(let error) = result {
            if (error as? PiRPCError)?.isClosed == true { return }
            // A compaction that ran shows its own failure; one Pi refused outright fails the turn.
            if !mapper.sawCompaction, !turn.interruptRequested {
                turn.failure = error.localizedDescription
                self.turn = turn
            }
        }
        probeIdle(number)
    }

    /// Ends the turn once `get_state` shows Pi idle: not streaming, not compacting, nothing queued.
    private func probeIdle(_ number: Int, generation: Int? = nil, attempt: Int = 1) {
        guard let turn, turn.number == number, !turn.finishing, let rpc else { return }
        if let generation, generation != turn.probeGeneration { return }
        let generation = turn.probeGeneration
        rpc.request(["type": "get_state"], timeout: timing.quick) { [weak self] result in
            guard let self, let turn = self.turn, turn.number == number, turn.probeGeneration == generation, !turn.finishing
            else { return }
            switch result {
            case .success(let state):
                let busy =
                    state["isStreaming"]?.bool == true || state["isCompacting"]?.bool == true
                    || (state["pendingMessageCount"]?.int ?? 0) > 0
                // When busy, Pi reports `agent_settled` again once that work is done.
                if !busy { Task { await self.finishTurn(number) } }
            case .failure(let error as PiRPCError) where error.isClosed:
                break
            case .failure:
                if attempt < 3 {
                    Task {
                        try? await Task.sleep(for: self.timing.probeRetry)
                        self.probeIdle(number, generation: generation, attempt: attempt + 1)
                    }
                } else {
                    var turn = turn
                    turn.failure = String(localized: "Pi stopped responding.")
                    self.turn = turn
                    self.discardProcess()
                    Task { await self.finishTurn(number) }
                }
            }
        }
    }

    private func finishTurn(_ number: Int) async {
        guard var turn, turn.number == number, !turn.finishing else { return }
        turn.finishing = true
        self.turn = turn
        let outcome: TurnOutcome =
            if turn.interruptRequested || turn.aborted {
                .interrupted
            } else if let failure = turn.failure ?? mapper.failure {
                .failed(failure)
            } else {
                .completed
            }
        emit(mapper.finish())
        withdrawDialogs(announce: false) { $0.turn == number }
        if let usage = await readUsage() { emit(.usage(usage)) }
        let exit = exitAfterTurn
        exitAfterTurn = nil
        guard self.turn?.number == number else { return }
        self.turn = nil
        emit(.turnCompleted(outcome))
        if let exit { emit(.sessionExited(error: exit)) }
    }

    /// The context in use and the session's cost, from `get_session_stats`.
    private func readUsage() async -> TokenUsage? {
        guard let rpc, rpc.isOpen,
            let stats = try? await rpc.request(["type": "get_session_stats"], timeout: timing.quick)
        else { return nil }
        let context = stats["contextUsage"]
        // Right after a compaction Pi reports no token count until the next response.
        let usage = TokenUsage(
            inputTokens: context?["tokens"]?.int ?? mapper.tokensAfterCompaction,
            contextWindow: context?["contextWindow"]?.int ?? mapper.contextWindow, costUSD: stats["cost"]?.number)
        return usage == TokenUsage() ? nil : usage
    }

    private func emit(_ event: AgentEvent) {
        guard !isClosed else { return }
        onEvent?(event)
    }

    private func emit(_ events: [AgentEvent]) {
        for event in events { emit(event) }
    }
}
