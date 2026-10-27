import Foundation

/// Turns OpenCode 2 server events into Coincide agent events for one session and the subagent sessions
/// it starts. It holds no I/O; `OpenCodeSession` performs the effects.
struct OpenCodeEventMapper {
    enum Effect: Hashable, Sendable {
        case event(AgentEvent)
        /// Stream a running shell command's output.
        case watchShell(toolID: String, shellID: String)
        case unwatchShell(toolID: String)
        /// A form Coincide cannot show; cancel it with a note so the agent asks in plain text.
        case declineForm(sessionID: String, formID: String)
        /// Withdraw the turn's prompt, which was interrupted before it ran.
        case cancelPrompt(messageID: String)
        case sessionDeleted
    }

    struct PendingRequest: Hashable, Sendable {
        enum Kind: Hashable, Sendable {
            case permission(action: String, resources: [String], save: [String])
            /// Questions, answered through `answer(userInput:answers:)`.
            case form([OpenCodeQuestions.Field])
        }

        var id: String
        /// The session that asked: the thread's session or one of its subagents.
        var sessionID: String
        var toolCallID: String?
        var kind: Kind
    }

    struct Turn: Hashable, Sendable {
        /// The id Coincide gave the prompt; OpenCode reports it when the prompt reaches the agent.
        var promptID: String
        var delivered = false
        /// An execution started after the prompt was sent.
        var started = false
        var interruptRequested = false
    }

    private struct Tool {
        var name: String
        var info: ToolCallInfo
    }

    let sessionID: String
    private(set) var children: Set<String> = []
    private(set) var turn: Turn?
    private(set) var pending: [String: PendingRequest] = [:]
    /// Whether an execution of the session is running, from its start and end events.
    private(set) var executionRunning = false
    /// An execution OpenCode started without a prompt from Coincide (another client, or a wake-up),
    /// reported as a turn the agent started itself. True once the user asked to stop it.
    private(set) var agentExecution: Bool?
    /// A prompt is being prepared: an execution starting now belongs to it, not to the agent.
    var preparingPrompt = false {
        didSet { if preparingPrompt { agentExecution = nil } }
    }
    /// Context window of the session's current model, reported with usage.
    var contextWindow: Int?

    private var tools: [String: Tool] = [:]
    /// Tool calls shown another way: todo lists as the plan, questions as user input requests.
    private var hiddenTools: [String: String] = [:]
    private var declinedTools: Set<String> = []
    private var streamedBlocks: Set<String> = []
    private var model: String?
    private var retryMessages: Set<String> = []
    private var compactionID: String?
    private var compactions = 0

    nonisolated init(sessionID: String) {
        self.sessionID = sessionID
    }

    // MARK: Turns

    mutating func beginTurn(promptID: String) {
        turn = Turn(promptID: promptID)
        // An execution OpenCode started itself now continues as this turn; its end no longer reports separately.
        agentExecution = nil
        retryMessages = []
        guard !executionRunning else { return }
        // Nothing from an earlier execution can still arrive; drop what an interrupted one left behind.
        tools = [:]
        hiddenTools = [:]
        declinedTools = []
        streamedBlocks = []
    }

    mutating func requestInterrupt() {
        turn?.interruptRequested = true
        if turn == nil, agentExecution == false { agentExecution = true }
    }

    /// Ends a turn OpenCode started itself whose end was missed (the event stream dropped meanwhile).
    mutating func endAgentExecution() -> AgentEvent? {
        guard let stopping = agentExecution else { return nil }
        agentExecution = nil
        executionRunning = false
        return .turnCompleted(stopping ? .interrupted : .completed)
    }

    /// Ends the turn without waiting for OpenCode, e.g. after an interrupt it could not confirm.
    /// Returns nil when no turn is running, so a turn ends at most once.
    mutating func endTurn(_ outcome: TurnOutcome) -> AgentEvent? {
        guard turn != nil else { return nil }
        turn = nil
        compactionID = nil
        return .turnCompleted(outcome)
    }

    /// Forgets a turn whose prompt was never accepted.
    mutating func abandonTurn() {
        turn = nil
    }

    /// Takes a pending request the user answered. A denied tool call later reports as declined.
    mutating func resolve(_ id: String, declined: Bool) -> PendingRequest? {
        guard let request = pending.removeValue(forKey: id) else { return nil }
        if declined, let tool = request.toolCallID { declinedTools.insert(tool) }
        return request
    }

    // MARK: Events

    mutating func handle(_ event: JSONValue) -> [Effect] {
        guard let type = event["type"]?.string, let data = event["data"] else { return [] }
        let eventSession = data["sessionID"]?.string
        switch type {
        case "session.created":
            if let child = eventSession, let parent = data["parentID"]?.string, owns(parent) { children.insert(child) }
            return []
        case "permission.asked":
            guard let asker = eventSession, owns(asker) else { return [] }
            return permissionAsked(data, asker: asker)
        case "permission.replied":
            return resolvedRemotely(data["requestID"]?.string)
        case "form.created":
            guard let form = data["form"], let asker = form["sessionID"]?.string, owns(asker) else { return [] }
            return formCreated(form, asker: asker)
        case "form.replied", "form.cancelled":
            return resolvedRemotely(data["id"]?.string)
        default:
            break
        }
        guard eventSession == sessionID else { return [] }

        switch type {
        case "session.inbox.delivered":
            if let promptID = turn?.promptID, data["inboxID"]?.string == promptID { turn?.delivered = true }
            return []
        case "session.execution.started":
            executionRunning = true
            turn?.started = true
            guard turn == nil, agentExecution == nil, !preparingPrompt else { return [] }
            agentExecution = false
            return [.event(.agentTurnStarted(note: String(localized: "OpenCode started working on its own.")))]
        case "session.execution.succeeded":
            return executionEnded(turn?.interruptRequested == true ? .interrupted : .completed)
        case "session.execution.interrupted":
            return executionEnded(.interrupted)
        case "session.execution.failed":
            return executionEnded(.failed(Self.errorMessage(data["error"])))
        case "session.deleted":
            return [.sessionDeleted]

        case "session.step.started":
            guard let model = OpenCodeModelRef(json: data["model"])?.slug, model != self.model else { return [] }
            self.model = model
            return [.event(.modelResolved(model))]
        case "session.text.delta", "session.reasoning.delta":
            guard let id = Self.blockID(data, reasoning: type == "session.reasoning.delta"),
                let delta = data["delta"]?.string, !delta.isEmpty
            else { return [] }
            streamedBlocks.insert(id)
            let event: AgentEvent =
                type == "session.text.delta"
                ? .assistantTextDelta(itemID: id, delta: delta) : .reasoningDelta(itemID: id, delta: delta)
            return [.event(event)]
        case "session.text.ended", "session.reasoning.ended":
            let reasoning = type == "session.reasoning.ended"
            guard let id = Self.blockID(data, reasoning: reasoning) else { return [] }
            let text = data["text"]?.string ?? ""
            guard streamedBlocks.remove(id) != nil || !text.isEmpty else { return [] }
            return [.event(reasoning ? .reasoningText(itemID: id, text: text) : .assistantText(itemID: id, text: text))]

        case "session.tool.input.started":
            guard let id = data["id"]?.string, let name = data["name"]?.string else { return [] }
            if name == "todowrite" || name == "question" {
                hiddenTools[id] = name
                return []
            }
            let info = OpenCodeTools.info(id: id, name: name, input: [:])
            tools[id] = Tool(name: name, info: info)
            return [.event(.toolStarted(info))]
        case "session.tool.called":
            guard let id = data["id"]?.string else { return [] }
            let input = data["input"]?.object ?? [:]
            if let hidden = hiddenTools[id] {
                guard hidden == "todowrite", let plan = OpenCodeTools.todoMarkdown(input) else { return [] }
                return [.event(.plan(text: plan))]
            }
            let name = tools[id]?.name ?? data["name"]?.string ?? "tool"
            let info = OpenCodeTools.info(id: id, name: name, input: input)
            tools[id] = Tool(name: name, info: info)
            return [.event(.toolUpdated(info))]
        case "session.tool.progress":
            guard let id = data["id"]?.string, let tool = tools[id], let metadata = data["metadata"] else { return [] }
            if tool.info.category == .command, let shellID = metadata["shellID"]?.string {
                return [.watchShell(toolID: id, shellID: shellID)]
            }
            if tool.info.category == .task, let child = metadata["sessionID"]?.string { children.insert(child) }
            return []
        case "session.tool.success":
            return toolSucceeded(data)
        case "session.tool.failed":
            return toolFailed(data)

        case "session.step.ended", "session.step.failed":
            guard let tokens = data["tokens"] else { return [] }
            let cacheRead = tokens.at("cache.read")?.int ?? 0
            let cacheWrite = tokens.at("cache.write")?.int ?? 0
            let usage = TokenUsage(
                inputTokens: (tokens["input"]?.int ?? 0) + cacheRead + cacheWrite, outputTokens: tokens["output"]?.int,
                cachedInputTokens: cacheRead, contextWindow: contextWindow)
            return [.event(.usage(usage))]
        case "session.usage.updated":
            guard let cost = data["cost"]?.number, cost > 0 else { return [] }
            return [.event(.usage(TokenUsage(costUSD: cost)))]
        case "session.retry.scheduled":
            let message = Self.errorMessage(data["error"])
            guard retryMessages.insert(message).inserted else { return [] }
            return [.event(.notice(String(localized: "OpenCode is retrying the request: \(message)")))]

        case "session.compaction.started":
            compactions += 1
            let id = "\(sessionID):compaction:\(compactions)"
            compactionID = id
            return [.event(.toolStarted(ToolCallInfo(id: id, category: .other, title: String(localized: "Compacting context"))))]
        case "session.compaction.ended":
            guard let id = compactionID else { return [] }
            compactionID = nil
            return [
                .event(.toolUpdated(ToolCallInfo(id: id, category: .other, title: String(localized: "Compacted context")))),
                .event(.toolCompleted(id: id, status: .completed, output: data["text"]?.string)),
            ]
        case "session.compaction.failed":
            guard let id = compactionID else { return [] }
            compactionID = nil
            return [.event(.toolCompleted(id: id, status: .failed, output: Self.errorMessage(data["error"])))]
        default:
            return []
        }
    }

    // MARK: Recovery

    /// Settles the turn from history after events were missed (the stream dropped and the session is
    /// no longer running). `messages` are the session's latest messages, newest first.
    mutating func backfill(newestFirst messages: [JSONValue]) -> [Effect] {
        guard let turn else { return [] }
        var recent: [JSONValue] = []
        var found = false
        for message in messages {
            if message["id"]?.string == turn.promptID {
                found = true
                break
            }
            recent.append(message)
        }
        executionRunning = false
        guard found else { return endTurn(.interrupted).map { [.event($0)] } ?? [] }

        var effects: [Effect] = []
        var outcome: TurnOutcome = .interrupted
        for message in recent.reversed() {
            switch message["type"]?.string {
            case "assistant":
                effects += assistantHistory(message)
            case "idle":
                switch message["outcome"]?.string {
                case "succeeded": outcome = turn.interruptRequested ? .interrupted : .completed
                case "failed": outcome = .failed(Self.errorMessage(message["error"]))
                default: outcome = .interrupted
                }
            default:
                break
            }
        }
        if let end = endTurn(outcome) { effects.append(.event(end)) }
        return effects
    }

    private mutating func assistantHistory(_ message: JSONValue) -> [Effect] {
        guard let messageID = message["id"]?.string else { return [] }
        var effects: [Effect] = []
        var textOrdinal = 0
        var reasoningOrdinal = 0
        for part in message["content"]?.array ?? [] {
            switch part["type"]?.string {
            case "text":
                let id = "\(messageID):text:\(textOrdinal)"
                textOrdinal += 1
                if let text = part["text"]?.string, !text.isEmpty {
                    effects.append(.event(.assistantText(itemID: id, text: text)))
                }
            case "reasoning":
                let id = "\(messageID):reasoning:\(reasoningOrdinal)"
                reasoningOrdinal += 1
                if let text = part["text"]?.string, !text.isEmpty {
                    effects.append(.event(.reasoningText(itemID: id, text: text)))
                }
            case "tool":
                guard let id = part["id"]?.string, let name = part["name"]?.string, name != "question" else { continue }
                let state = part["state"]
                let input = state?["input"]?.object ?? [:]
                if name == "todowrite" {
                    if let plan = OpenCodeTools.todoMarkdown(input) { effects.append(.event(.plan(text: plan))) }
                    continue
                }
                effects.append(.event(.toolStarted(OpenCodeTools.info(id: id, name: name, input: input))))
                switch state?["status"]?.string {
                case "completed":
                    let result = OpenCodeTools.completion(name: name, content: state?["content"], metadata: state?["metadata"])
                    effects.append(.event(.toolCompleted(id: id, status: result.status, output: result.output)))
                case "error":
                    effects.append(.event(.toolCompleted(id: id, status: .failed, output: Self.errorMessage(state?["error"]))))
                default:
                    break
                }
                tools[id] = nil
            default:
                break
            }
        }
        return effects
    }

    // MARK: Helpers

    private func owns(_ id: String) -> Bool { id == sessionID || children.contains(id) }

    private mutating func executionEnded(_ outcome: TurnOutcome) -> [Effect] {
        executionRunning = false
        guard let turn else {
            guard let stopping = agentExecution else { return [] }
            agentExecution = nil
            return [.event(.turnCompleted(stopping && outcome == .completed ? .interrupted : outcome))]
        }
        // An end before the prompt reached the agent belongs to an earlier execution, unless the user
        // stopped the turn while its prompt was still queued.
        let stoppedWhileQueued = outcome == .interrupted && turn.interruptRequested
        guard turn.delivered || turn.started || stoppedWhileQueued else { return [] }
        var effects: [Effect] = []
        if !turn.delivered && turn.interruptRequested { effects.append(.cancelPrompt(messageID: turn.promptID)) }
        if let end = endTurn(outcome) { effects.append(.event(end)) }
        return effects
    }

    private mutating func toolSucceeded(_ data: JSONValue) -> [Effect] {
        guard let id = data["id"]?.string else { return [] }
        if hiddenTools.removeValue(forKey: id) != nil { return [] }
        let tool = tools.removeValue(forKey: id)
        let name = tool?.name ?? "tool"
        var effects: [Effect] = []
        if tool?.info.category == .command { effects.append(.unwatchShell(toolID: id)) }
        if tool?.info.category == .task, let child = data.at("metadata.sessionID")?.string { children.insert(child) }
        if var info = tool?.info, let diff = OpenCodeTools.diff(fromMetadata: data["metadata"]) {
            info.detail = diff
            effects.append(.event(.toolUpdated(info)))
        }
        let result = OpenCodeTools.completion(name: name, content: data["content"], metadata: data["metadata"])
        effects.append(.event(.toolCompleted(id: id, status: result.status, output: result.output)))
        return effects
    }

    private mutating func toolFailed(_ data: JSONValue) -> [Effect] {
        guard let id = data["id"]?.string else { return [] }
        if hiddenTools.removeValue(forKey: id) != nil { return [] }
        let tool = tools.removeValue(forKey: id)
        var effects: [Effect] = []
        if tool?.info.category == .command { effects.append(.unwatchShell(toolID: id)) }
        let declined = declinedTools.remove(id) != nil || data.at("error.type")?.string == "permission.rejected"
        let output = [OpenCodeTools.text(of: data["content"]), Self.errorMessage(data["error"])]
            .filter { !$0.isEmpty }.joined(separator: "\n")
        effects.append(.event(.toolCompleted(id: id, status: declined ? .declined : .failed, output: output)))
        return effects
    }

    private mutating func permissionAsked(_ data: JSONValue, asker: String) -> [Effect] {
        guard let id = data["id"]?.string, pending[id] == nil else { return [] }
        let action = data["action"]?.string ?? "permission"
        let resources = (data["resources"]?.array ?? []).compactMap(\.string)
        let save = (data["save"]?.array ?? []).compactMap(\.string)
        let toolID = data.at("source.id")?.string
        let tool = asker == sessionID ? toolID.flatMap { tools[$0]?.info } : nil
        let detail =
            OpenCodeTools.diff(fromMetadata: data["metadata"])
            ?? (resources.isEmpty ? data["message"]?.string : resources.joined(separator: "\n"))
        pending[id] = PendingRequest(
            id: id, sessionID: asker, toolCallID: toolID,
            kind: .permission(action: action, resources: resources, save: save))
        let request = ApprovalRequest(
            id: id, category: OpenCodeTools.permissionCategory(action: action, tool: tool),
            title: OpenCodeTools.permissionTitle(action: action, resources: resources, tool: tool), detail: detail,
            options: OpenCodePermissions.options(action: action, save: save), toolCallID: tool == nil ? nil : toolID)
        return [.event(.approvalRequested(request))]
    }

    /// OpenCode's questions are asked as user input; a form Coincide cannot show is declined.
    private mutating func formCreated(_ form: JSONValue, asker: String) -> [Effect] {
        guard let id = form["id"]?.string, pending[id] == nil else { return [] }
        guard let parsed = OpenCodeQuestions.parse(form) else { return [.declineForm(sessionID: asker, formID: id)] }
        pending[id] = PendingRequest(
            id: id, sessionID: asker, toolCallID: form.at("metadata.tool.id")?.string, kind: .form(parsed.fields))
        return [.event(.userInputRequested(parsed.request))]
    }

    /// OpenCode settled a request Coincide did not answer (another client did, or the turn ended).
    private mutating func resolvedRemotely(_ id: String?) -> [Effect] {
        guard let id, let request = pending.removeValue(forKey: id) else { return [] }
        if case .form = request.kind { return [.event(.userInputResolved(id: id))] }
        return [.event(.approvalResolved(id: id))]
    }

    private nonisolated static func blockID(_ data: JSONValue, reasoning: Bool) -> String? {
        guard let message = data["assistantMessageID"]?.string, let ordinal = data["ordinal"]?.int else { return nil }
        return "\(message):\(reasoning ? "reasoning" : "text"):\(ordinal)"
    }

    nonisolated static func errorMessage(_ error: JSONValue?) -> String {
        if let message = error?["message"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty {
            return message
        }
        if let type = error?["type"]?.string { return String(localized: "OpenCode reported an error (\(type)).") }
        return String(localized: "OpenCode reported an error.")
    }
}
