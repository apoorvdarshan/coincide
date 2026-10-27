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
        /// How soon to ask again when Pi is still busy after settling, in case it goes idle without saying so.
        var busyRecheck: Duration = .seconds(2)
    }

    typealias TransportFactory = @MainActor (_ arguments: [String], _ environment: [String: String]) -> PiTransport

    /// The permission policy is fixed for a process's lifetime; changing it restarts Pi on the same session.
    private struct Policy: Equatable {
        var accessMode: AccessMode
        var interactionMode: InteractionMode

        /// Coincide's extension enforces approvals and plan mode, so those cannot run without it.
        var needsExtension: Bool { accessMode == .approval || interactionMode == .plan }
    }

    private struct Turn {
        let number: Int
        /// Pi has the prompt (or `/compact`). Until then the turn is being prepared, and `send` reports failures.
        var sent = false
        /// A prompt starting with `/` may be an extension command that never starts a run.
        var mayBeCommand = false
        var sawAgentStart = false
        var settled = false
        /// Bumped whenever Pi becomes busy again, so an older idle probe cannot end the turn.
        var probeGeneration = 0
        var interruptRequested = false
        var aborted = false
        var failure: String?
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

    /// "Always allow" answers by Pi session file, so restarting Pi (a new policy, the idle timeout) keeps them.
    private static var approvalsBySession: [String: Set<String>] = [:]

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
    /// Work an extension started between turns, shown as a turn Pi started itself. True once it is being stopped.
    private var wake: Bool?
    /// How many times Pi started a new conversation instead of continuing one.
    private var newConversations = 0
    private var dialogs: [String: OpenDialog] = [:]
    private var alwaysAllowed: Set<String>
    /// Captured from the first process before it loads a saved session, so "Default" means Pi's default.
    private var baseline: Baseline?
    /// The model (`provider/id`) and thinking level the running process uses.
    private var currentModel: String?
    private var currentThinking: String?
    /// How to invoke the extension's handoff command; nil when Pi did not load the extension.
    private var handoffCommand: String?
    /// The process ended during a turn; the exit is reported right after that turn completes.
    private var exitAfterTurn: String?
    /// Why the last process ended, for a turn that was still being prepared.
    private var lastExit: String?
    /// One `send` at a time: a turn the thread runner gave up on may still be starting Pi.
    private var sending = false
    private var sendWaiters: [CheckedContinuation<Void, Never>] = []
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
        alwaysAllowed = launch.resumeSessionID.flatMap { Self.approvalsBySession[$0] } ?? []
        // Pi works in the folder's real path (`/private/tmp`, not `/tmp`), which is what the model sees.
        mapper.workingDirectory = PiSessionFile.canonical(launch.workingDirectory.path)
    }

    // MARK: AgentSession

    public func start() async throws {
        guard rpc == nil, opening == nil, !isClosed else { return }
        try await open(resuming: launch.resumeSessionID)
    }

    public func send(_ input: AgentTurnInput) async throws {
        await acquireSend()
        defer { releaseSend() }
        guard !isClosed else { throw AgentError.notRunning }
        // Work an extension started is now part of this turn: Pi queues the prompt behind it.
        wake = nil
        // A turn the thread runner already gave up on may still be running in Pi; restarting Pi stops it.
        let abandoned = turn != nil
        if let previous = turn?.number { discardTurn(previous) }
        turnCount += 1
        let number = turnCount
        turn = Turn(number: number)
        exitAfterTurn = nil
        do {
            try await begin(number, input: input, restart: abandoned)
        } catch {
            // The user stopped the turn while Pi was starting, and it already ended; there is nothing left to fail.
            guard turn?.number == number else { return }
            discardTurn(number)
            throw error
        }
    }

    public let supportsSteering = true

    /// Sends the message with `streamingBehavior: steer`, as T3 Code does: Pi hands it to the running agent after its
    /// current tool calls, or runs it right after. The turn ends once Pi is idle again, so it covers the steer too.
    /// `/compact` is not steered; it waits for the turn.
    public func steer(_ input: AgentTurnInput) async throws {
        guard !isClosed, var turn, turn.sent, !turn.interruptRequested, let rpc, rpc.isOpen,
            !input.imagePaths.isEmpty || PiCompactCommand.parse(input.message) == nil
        else {
            throw AgentError.providerError(String(localized: "Pi can't take a message for this turn now."))
        }
        let images = try PiImages.payload(input.imagePaths)
        // An idle check already on its way must not end the turn before Pi has the message.
        turn.probeGeneration += 1
        self.turn = turn
        let number = turn.number
        var record: [String: JSONValue] = ["type": "prompt", "message": .string(input.message), "streamingBehavior": "steer"]
        if !images.isEmpty { record["images"] = .array(images) }
        // Answered once queued or started; waiting could block on an extension's dialog.
        rpc.request(.object(record), timeout: nil) { [weak self] result in
            guard let self, self.turn?.number == number else { return }
            if case .failure(let error) = result, (error as? PiRPCError)?.isClosed != true {
                self.emit(.notice(String(localized: "Pi could not take your message: \(error.localizedDescription)")))
            }
            self.probeIdle(number)
        }
    }

    public func respond(to approvalID: String, optionID: String) {
        respond(to: approvalID, optionID: optionID, text: nil)
    }

    public func respond(to approvalID: String, optionID: String, text: String?) {
        guard let open = dialogs[approvalID], open.dialog.approval != nil else { return }
        dialogs[approvalID] = nil
        open.expiry?.cancel()
        client?.send(open.dialog.response(optionID: optionID, text: text))
        if optionID == PiDialog.allowAlwaysID, let key = open.dialog.rememberKey { remember(key) }
        if open.dialog.declines(optionID), let toolCallID = open.dialog.toolCallID { mapper.markDeclined(toolCallID) }
    }

    public func answer(userInput requestID: String, answers: [String: [String]]) {
        guard let open = dialogs[requestID], open.dialog.question != nil else { return }
        dialogs[requestID] = nil
        open.expiry?.cancel()
        client?.send(open.dialog.response(answers: answers))
    }

    public func interrupt() {
        guard var turn, !turn.interruptRequested else {
            // Work an extension started: ask Pi to stop it; `agent_settled` then ends it as interrupted.
            if turn == nil, wake == false, let rpc, rpc.isOpen {
                wake = true
                rpc.request(["type": "abort"], timeout: timing.abort) { _ in }
            }
            return
        }
        turn.interruptRequested = true
        self.turn = turn
        let number = turn.number
        // Pi does not have the prompt yet (or the process is gone): `send` stops short, and the turn ends now.
        guard turn.sent, let rpc, rpc.isOpen else {
            Task { self.finishTurn(number) }
            return
        }
        // Once Pi settled it is only finishing up, such as an extension's compaction: stop that and end the turn now.
        if turn.settled { Task { self.finishTurn(number) } }
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
                self.finishTurn(number)
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

    // MARK: Turns

    /// Readies Pi for the turn and hands it the prompt. Returns early when the user stopped the turn first.
    private func begin(_ number: Int, input: AgentTurnInput, restart: Bool) async throws {
        let wanted = Policy(accessMode: input.accessMode, interactionMode: input.interactionMode)
        let conversations = newConversations
        if restart || rpc?.isOpen != true || wanted != policy {
            policy = wanted
            try await reopen()
        }
        guard try proceed(number) else { return }
        // A restart that could not continue the session started a new one, which needs the whole recap.
        let isNewConversation = newConversations != conversations
        let prompt = PiPrompt(recap: input.recap(forNewSession: isNewConversation), message: input.message)
        // A slash command only runs at the start of a prompt, so a recap in front of one travels on its own.
        let handoff = prompt.needsSeparateRecap ? handoffCommand : nil
        let text = handoff == nil ? input.prompt(forNewSession: isNewConversation) : prompt.message
        let compact = input.imagePaths.isEmpty ? PiCompactCommand.parse(text) : nil
        let images = try PiImages.payload(input.imagePaths)
        mapper.begin(itemPrefix: "t\(number)")
        try await applySelection(input.selection)
        guard try proceed(number) else { return }
        if let handoff, let recap = prompt.recap {
            _ = try await connection().request(
                ["type": "prompt", "message": .string("/\(handoff) \(recap)")], timeout: timing.request)
            guard try proceed(number) else { return }
        }
        let rpc = try connection()
        turn?.sent = true
        turn?.mayBeCommand = compact == nil && text.hasPrefix("/")
        if let compact {
            var record: [String: JSONValue] = ["type": "compact"]
            if let instructions = compact.instructions { record["customInstructions"] = .string(instructions) }
            rpc.request(.object(record), timeout: nil) { [weak self] in self?.compactAnswered(number, $0) }
        } else {
            // `steer` makes Pi queue the prompt if it is still busy instead of rejecting it.
            var record: [String: JSONValue] = ["type": "prompt", "message": .string(text), "streamingBehavior": "steer"]
            if !images.isEmpty { record["images"] = .array(images) }
            // Pi answers once slash commands and extension input handlers are done, which can wait on a dialog.
            rpc.request(.object(record), timeout: nil) { [weak self] in self?.promptAnswered(number, $0) }
        }
    }

    /// Whether to go on preparing the turn: false once the user stopped it, which ends it. Throws when Pi went away.
    private func proceed(_ number: Int) throws -> Bool {
        if isClosed { throw AgentError.notRunning }
        guard let turn, turn.number == number else { return false }
        if turn.interruptRequested {
            finishTurn(number)
            return false
        }
        _ = try connection()
        return true
    }

    /// The running process, or an error saying why it ended.
    private func connection() throws -> PiRPCClient {
        if let rpc, rpc.isOpen { return rpc }
        if let lastExit { throw AgentError.providerError(lastExit) }
        throw AgentError.notRunning
    }

    private func promptAnswered(_ number: Int, _ result: Result<JSONValue, Error>) {
        guard var turn, turn.number == number else { return }
        switch result {
        case .success(let data):
            // "handled": an extension command consumed the prompt and no run starts. Pi before 0.99 says nothing.
            let disposition = data["disposition"]?.string
            if disposition == "handled" || (disposition == nil && turn.mayBeCommand && !turn.sawAgentStart) {
                probeIdle(number)
            }
        case .failure(let error as PiRPCError) where error.isClosed:
            break
        case .failure(let error):
            turn.failure = error.localizedDescription
            self.turn = turn
            finishTurn(number)
        }
    }

    private func compactAnswered(_ number: Int, _ result: Result<JSONValue, Error>) {
        guard var turn, turn.number == number else { return }
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
        guard let turn, turn.number == number, let rpc, rpc.isOpen else { return }
        if let generation, generation != turn.probeGeneration { return }
        let generation = turn.probeGeneration
        rpc.request(["type": "get_state"], timeout: timing.quick) { [weak self] result in
            guard let self, let turn = self.turn, turn.number == number, turn.probeGeneration == generation else { return }
            switch result {
            case .success(let state):
                let busy =
                    state["isStreaming"]?.bool == true || state["isCompacting"]?.bool == true
                    || (state["pendingMessageCount"]?.int ?? 0) > 0
                if !busy {
                    self.finishTurn(number)
                } else if turn.settled || !turn.sawAgentStart {
                    // Pi says so with `agent_settled` or `compaction_end` when that work is done; ask again in case not.
                    self.probeLater(number, generation: generation, after: self.timing.busyRecheck)
                }
            case .failure(let error as PiRPCError) where error.isClosed:
                break
            case .failure:
                if attempt < 3 {
                    self.probeLater(number, generation: generation, after: self.timing.probeRetry, attempt: attempt + 1)
                } else {
                    self.turn?.failure = String(localized: "Pi stopped responding.")
                    self.discardProcess()
                    self.finishTurn(number)
                }
            }
        }
    }

    private func probeLater(_ number: Int, generation: Int, after delay: Duration, attempt: Int = 1) {
        Task { [weak self] in
            try? await Task.sleep(for: delay)
            self?.probeIdle(number, generation: generation, attempt: attempt)
        }
    }

    private func finishTurn(_ number: Int) {
        guard let turn, turn.number == number else { return }
        self.turn = nil
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
        let exit = exitAfterTurn
        exitAfterTurn = nil
        emit(.turnCompleted(outcome))
        if let exit {
            emit(.sessionExited(error: exit))
        } else {
            reportUsage()
        }
    }

    /// Forgets a turn without reporting it: the thread runner gave up on it, or `send` is failing it.
    private func discardTurn(_ number: Int) {
        guard turn?.number == number else { return }
        turn = nil
        _ = mapper.finish()
        withdrawDialogs(announce: false) { $0.turn == number }
    }

    /// The context in use and the session's cost, from `get_session_stats`, once a turn ended.
    private func reportUsage() {
        guard let rpc, rpc.isOpen else { return }
        let estimate = mapper.tokensAfterCompaction
        let window = mapper.contextWindow
        rpc.request(["type": "get_session_stats"], timeout: timing.quick) { [weak self] result in
            guard let self, case .success(let stats) = result else { return }
            let context = stats["contextUsage"]
            // Right after a compaction Pi has no token count until the next response; its estimate stands in.
            let tokens = context?["tokens"]?.int ?? (context?["tokens"]?.isNull == true ? estimate : nil)
            let usage = TokenUsage(
                inputTokens: tokens, contextWindow: context?["contextWindow"]?.int ?? window, costUSD: stats["cost"]?.number)
            if usage != TokenUsage() { self.emit(.usage(usage)) }
        }
    }

    private func acquireSend() async {
        while sending { await withCheckedContinuation { sendWaiters.append($0) } }
        sending = true
    }

    private func releaseSend() {
        sending = false
        if !sendWaiters.isEmpty { sendWaiters.removeFirst().resume() }
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
                try await handshake(extensionPath: extensionPath, resume: .fresh, lostSession: true)
            }
        } catch let error as PiRPCError {
            throw AgentError.providerError(error.localizedDescription)
        }
    }

    /// Starts a process, loads the session and checks that Coincide's extension is in place.
    /// `lostSession` says an earlier session could not be continued, so the fresh one gets a notice.
    private func handshake(extensionPath: String, resume: PiLaunch.Resume, lostSession: Bool = false) async throws {
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
            // A resumed or forked session already holds the conversation; a new one has seen nothing of it.
            var continued = resume != .fresh
            if case .switchTo(let path) = resume {
                do {
                    let result = try await client.request(
                        ["type": "switch_session", "sessionPath": .string(path)], timeout: timing.lifecycle)
                    continued = result["cancelled"]?.bool != true
                } catch PiRPCError.rejected {
                    continued = false
                }
            }
            let state = try await client.request(["type": "get_state"], timeout: timing.request)
            guard let id = state["sessionFile"]?.string ?? state["sessionId"]?.string else {
                throw AgentError.protocolError(String(localized: "Pi did not report a session."))
            }
            let commands: JSONValue?
            do {
                commands = try await client.request(["type": "get_commands"], timeout: timing.request)
            } catch let error as PiRPCError where error.isClosed {
                throw error
            } catch {
                commands = nil
            }
            let handoff = PiExtension.handoffCommandName(in: commands)
            if handoff == nil, policy.needsExtension {
                throw AgentError.providerError(
                    String(
                        localized:
                            "Pi did not load Coincide’s extension, so it cannot ask before running tools or stay in plan mode. Run `pi --extension \"\(extensionPath)\"` in a terminal to see why."))
            }
            guard !isClosed else { throw AgentError.notRunning }
            handoffCommand = handoff
            // A resumed session brings back the model and level it last used.
            currentModel = PiModels.slug(of: state["model"])
            currentThinking = state["thinkingLevel"]?.string
            mapper.contextWindow = PiModels.contextWindow(of: state["model"])
            sessionID = id
            rpc = client
            lastExit = nil
            alwaysAllowed.formUnion(Self.approvalsBySession[id] ?? [])
            if !alwaysAllowed.isEmpty { Self.approvalsBySession[id] = alwaysAllowed }
            if !continued { newConversations += 1 }
            emit(continued ? .sessionContinued(id: id) : .sessionStarted(id: id))
            if let model = currentModel { emit(.modelResolved(model)) }
            if lostSession || (resume != .fresh && !continued) {
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
        lastExit = reason
        wake = nil
        withdrawDialogs(announce: true) { $0.turn == nil }
        guard var turn else {
            emit(.sessionExited(error: reason))
            return
        }
        // A turn still being prepared fails through `send`, which is waiting on this process.
        guard turn.sent else { return }
        if !turn.interruptRequested { turn.failure = reason }
        self.turn = turn
        exitAfterTurn = reason
        finishTurn(turn.number)
    }

    // MARK: Model and thinking level

    /// Points Pi at the turn's model and thinking level; "Default" returns to Pi's own default.
    private func applySelection(_ selection: ModelSelection) async throws {
        let isDefault = selection.modelID == PiModels.defaultModelID || selection.modelID.isEmpty
        if let model = isDefault ? baseline?.model : selection.modelID, model != currentModel {
            guard let target = PiModels.parseSlug(model) else {
                throw AgentError.providerError(
                    String(localized: "Pi model ids look like provider/model, for example anthropic/claude-sonnet-4-5."))
            }
            let data: JSONValue
            do {
                data = try await connection().request(
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
        _ = try await connection().request(["type": "set_thinking_level", "level": .string(level)], timeout: timing.request)
        currentThinking = level
    }

    // MARK: Events

    /// The turn Pi is working on; a turn still being prepared does not own Pi's events yet.
    private var activeTurn: Turn? { turn?.sent == true ? turn : nil }

    private func handle(_ record: JSONValue) {
        guard let type = record["type"]?.string else { return }
        switch type {
        case "agent_start":
            if var turn = activeTurn {
                turn.sawAgentStart = true
                turn.settled = false
                turn.aborted = false
                turn.probeGeneration += 1
                self.turn = turn
            } else if turn == nil {
                // An extension started work between turns; it is shown as a turn of its own, under its own item ids.
                wakeCount += 1
                mapper.begin(itemPrefix: "w\(wakeCount)")
                // While a send prepares its turn, the work becomes part of that turn instead.
                if wake == nil, !sending {
                    wake = false
                    emit(.agentTurnStarted(note: String(localized: "A Pi extension started a turn.")))
                }
            }
        case "agent_settled":
            guard var turn = activeTurn else {
                // Work that started before the turn's prompt keeps the turn's ids; it ends with the turn.
                if turn == nil {
                    emit(mapper.finish())
                    if let stopping = wake {
                        wake = nil
                        emit(.turnCompleted(stopping || record["aborted"]?.bool == true ? .interrupted : .completed))
                    }
                }
                return
            }
            if turn.interruptRequested {
                finishTurn(turn.number)
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
            if var turn = activeTurn {
                turn.probeGeneration += 1
                self.turn = turn
            }
            emit(mapper.handle(record))
        case "compaction_end":
            emit(mapper.handle(record))
            // A compaction after `agent_settled`, or a `/compact` turn, is the last work of the turn.
            if let turn = activeTurn, turn.settled || !turn.sawAgentStart { probeIdle(turn.number) }
        case "tool_execution_end":
            // A tool that ended while its approval was pending no longer needs it (Pi gave up waiting).
            if let toolCallID = record["toolCallId"]?.string {
                withdrawDialogs(announce: true) { $0.dialog.toolCallID == toolCallID }
            }
            emit(mapper.handle(record))
        case "response":
            // Responses without an id: Pi could not parse a line Coincide wrote.
            guard record["command"]?.string == "parse", record["success"]?.bool == false, var turn = activeTurn else { return }
            turn.failure = PiRPCClient.errorText(record["error"])
            self.turn = turn
            finishTurn(turn.number)
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
            client?.send(dialog.response(optionID: PiDialog.allowID, text: nil))
            return
        }
        let id = dialog.id
        var open = OpenDialog(dialog: dialog, turn: turn?.number)
        if let timeout = dialog.timeout {
            open.expiry = Task { [weak self] in
                try? await Task.sleep(for: timeout)
                // Pi answered the dialog itself with its default, so it no longer needs the user.
                guard !Task.isCancelled, let self, let open = self.dialogs.removeValue(forKey: id) else { return }
                self.announceResolved(open.dialog)
            }
        }
        dialogs[id] = open
        switch dialog.presentation {
        case .approval(let request): emit(.approvalRequested(request))
        case .question(let request): emit(.userInputRequested(request))
        }
    }

    /// Withdraws dialogs nobody will answer any more and tells Pi; `announce` reports them as resolved by the agent.
    private func withdrawDialogs(announce: Bool, where shouldWithdraw: (OpenDialog) -> Bool) {
        for (id, open) in dialogs where shouldWithdraw(open) {
            dialogs[id] = nil
            open.expiry?.cancel()
            client?.send(open.dialog.cancellation)
            if announce { announceResolved(open.dialog) }
        }
    }

    private func announceResolved(_ dialog: PiDialog) {
        switch dialog.presentation {
        case .approval: emit(.approvalResolved(id: dialog.id))
        case .question: emit(.userInputResolved(id: dialog.id))
        }
    }

    private func remember(_ key: String) {
        alwaysAllowed.insert(key)
        if let sessionID { Self.approvalsBySession[sessionID, default: []].insert(key) }
    }

    private func emit(_ event: AgentEvent) {
        guard !isClosed else { return }
        onEvent?(event)
    }

    private func emit(_ events: [AgentEvent]) {
        for event in events { emit(event) }
    }
}
