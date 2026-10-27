import Foundation

/// Turns Claude Code's stream-json frames into `AgentEvent`s.
///
/// It only keeps parsing state, so recorded frames can be fed to it directly; `ClaudeSession` owns
/// the process, the control channel and turn boundaries.
struct ClaudeEventMapper {
    /// An API failure Claude reported as an assistant message.
    struct AssistantError: Sendable, Hashable {
        var kind: String
        var text: String
    }

    let workingDirectory: String
    /// Context window of the selected model, until a result reports the real one.
    var contextWindow: Int?
    /// Reads the file an edit targets so its diff gets real line numbers.
    var fileContents: (String) -> String? = ClaudeTools.readSmallFile

    private(set) var sessionID: String?
    private(set) var model: String?
    private(set) var capabilities: Set<String> = []
    /// Set when the current turn hit an API error; such messages are not shown as replies.
    private(set) var assistantError: AssistantError?
    /// Claude entered or left plan mode itself during the current turn.
    private(set) var changedPlanMode = false

    private struct ToolCall {
        var name: String
        var input: JSONValue
        /// Nil for hidden tools (plans, questions, tool loading).
        var info: ToolCallInfo?
        var hasFullInput = false
        var completed = false
        var refinedFromStream = false
    }

    private enum OpenBlock {
        case text(String)
        case thinking(String)
        case tool(id: String, partialInput: String)
    }

    private struct MessageUsage {
        var input = 0
        var cacheCreation = 0
        var cacheRead = 0
        var output = 0

        /// Absent or null fields keep their earlier value, as in the Messages API stream.
        mutating func merge(_ json: JSONValue) {
            if let value = json["input_tokens"]?.int { input = value }
            if let value = json["cache_creation_input_tokens"]?.int { cacheCreation = value }
            if let value = json["cache_read_input_tokens"]?.int { cacheRead = value }
            if let value = json["output_tokens"]?.int { output = value }
        }
    }

    private struct LastThinking {
        var messageID: String
        var itemID: String
        var text: String
        var followsThinking: Bool
    }

    private var tools: [String: ToolCall] = [:]
    private var streamTextCounts: [String: Int] = [:]
    private var streamThinkingCounts: [String: Int] = [:]
    private var snapshotTextCounts: [String: Int] = [:]
    private var snapshotThinkingCounts: [String: Int] = [:]
    private var openBlocks: [Int: OpenBlock] = [:]
    private var messageID: String?
    private var messageUsage: MessageUsage?
    private var lastThinking: LastThinking?
    private var taskList = ClaudeTaskList()
    private var retryNoticed = false
    private var costOffset = 0.0
    private var processCost: Double?

    init(workingDirectory: String, contextWindow: Int? = nil) {
        self.workingDirectory = workingDirectory
        self.contextWindow = contextWindow
    }

    /// Clears per-turn state before a prompt is sent.
    mutating func beginTurn() {
        assistantError = nil
        changedPlanMode = false
        retryNoticed = false
    }

    /// A new process started for the same session: stream state resets and cost keeps counting up.
    mutating func processRestarted() {
        costOffset += processCost ?? 0
        processCost = nil
        openBlocks = [:]
        messageUsage = nil
    }

    func toolName(for id: String) -> String? { tools[id]?.name }

    func isVisibleTool(_ id: String) -> Bool { tools[id]?.info != nil }

    /// Starts (or refreshes) a tool call that a permission request mentions before its message arrived.
    mutating func ensureTool(id: String, name: String, input: JSONValue) -> [AgentEvent] {
        startTool(id: id, name: name, input: input, final: true)
    }

    mutating func map(_ frame: JSONValue) -> [AgentEvent] {
        switch frame["type"]?.string {
        case "stream_event"?: return streamEvent(frame)
        case "assistant"?: return assistant(frame)
        case "user"?: return user(frame)
        case "system"?: return system(frame)
        case "result"?: return result(frame)
        case "conversation_reset"?:
            sessionID = frame["new_conversation_id"]?.string ?? sessionID
            return []
        default: return []
        }
    }

    // MARK: Streaming

    private mutating func streamEvent(_ frame: JSONValue) -> [AgentEvent] {
        guard frame["parent_tool_use_id"]?.string == nil, let event = frame["event"] else { return [] }
        switch event["type"]?.string {
        case "message_start"?:
            let message = event["message"]
            messageID = message?["id"]?.string ?? frame["api_message_id"]?.string
            openBlocks = [:]
            var events: [AgentEvent] = []
            if let model = message?["model"]?.string { events += resolveModel(model) }
            if let usage = message?["usage"] {
                var current = MessageUsage()
                current.merge(usage)
                messageUsage = current
                events.append(.usage(contextUsage(current)))
            }
            return events
        case "message_delta"?:
            guard let usage = event["usage"], var current = messageUsage else { return [] }
            current.merge(usage)
            messageUsage = current
            return [.usage(contextUsage(current))]
        case "content_block_start"?:
            guard let index = event["index"]?.int, let block = event["content_block"], let messageID else { return [] }
            switch block["type"]?.string {
            case "text"?:
                let id = "\(messageID):text:\(Self.next(&streamTextCounts, messageID))"
                openBlocks[index] = .text(id)
                return nonEmpty(block["text"]?.string).map { [.assistantTextDelta(itemID: id, delta: $0)] } ?? []
            case "thinking"?:
                let id = "\(messageID):thinking:\(Self.next(&streamThinkingCounts, messageID))"
                openBlocks[index] = .thinking(id)
                return nonEmpty(block["thinking"]?.string).map { [.reasoningDelta(itemID: id, delta: $0)] } ?? []
            case "tool_use"?, "server_tool_use"?, "mcp_tool_use"?:
                guard let id = block["id"]?.string, let name = block["name"]?.string else { return [] }
                openBlocks[index] = .tool(id: id, partialInput: "")
                return startTool(id: id, name: name, input: block["input"] ?? [:], final: false)
            default:
                return []
            }
        case "content_block_delta"?:
            guard let index = event["index"]?.int, let delta = event["delta"], let block = openBlocks[index] else { return [] }
            switch (block, delta["type"]?.string) {
            case (.text(let id), "text_delta"?):
                return nonEmpty(delta["text"]?.string).map { [.assistantTextDelta(itemID: id, delta: $0)] } ?? []
            case (.thinking(let id), "thinking_delta"?):
                return nonEmpty(delta["thinking"]?.string).map { [.reasoningDelta(itemID: id, delta: $0)] } ?? []
            case (.tool(let id, let partial), "input_json_delta"?):
                let input = partial + (delta["partial_json"]?.string ?? "")
                openBlocks[index] = .tool(id: id, partialInput: input)
                return refineFromPartialInput(id: id, partial: input)
            default:
                return []
            }
        case "content_block_stop"?:
            if let index = event["index"]?.int { openBlocks[index] = nil }
            return []
        default:
            return []
        }
    }

    /// Shows a tool's path or command while its input is still streaming in.
    private mutating func refineFromPartialInput(id: String, partial: String) -> [AgentEvent] {
        guard let call = tools[id], call.info != nil, !call.refinedFromStream, partial.count < 4_096 else { return [] }
        var fields: [String: JSONValue] = [:]
        for key in ["file_path", "notebook_path", "path", "command", "pattern", "url", "query", "description", "skill"] {
            if let value = ClaudeTools.partialStringField(key, in: partial) { fields[key] = .string(value) }
        }
        guard !fields.isEmpty else { return [] }
        tools[id]?.refinedFromStream = true
        return startTool(id: id, name: call.name, input: .object(fields), final: false, refine: true)
    }

    // MARK: Messages

    private mutating func assistant(_ frame: JSONValue) -> [AgentEvent] {
        guard let message = frame["message"], let content = message["content"]?.array else { return [] }
        if let parent = frame["parent_tool_use_id"]?.string { return subagentActivity(parent: parent, content: content) }
        let messageID = message["id"]?.string ?? frame["uuid"]?.string ?? UUID().uuidString
        let model = message["model"]?.string
        var events: [AgentEvent] = []
        if let model, model != "<synthetic>" { events += resolveModel(model) }
        if let error = frame["error"]?.string, error != "max_output_tokens" {
            assistantError = AssistantError(kind: error, text: ClaudeTools.text(of: message["content"]).trimmingCharacters(in: .whitespacesAndNewlines))
            return events
        }
        let presentations = toolPresentations(frame)
        for block in content {
            let type = block["type"]?.string
            if type != "thinking" {
                // Claude 5.1+ writes a pre-tool update as a second thinking block; T3 shows it as text too.
                if type == "tool_use", let update = lastThinking, update.messageID == messageID, update.followsThinking,
                    Self.writesUpdatesAsThinking(model ?? self.model ?? "")
                {
                    events.append(.assistantText(itemID: update.itemID + ":update", text: update.text))
                }
                lastThinking = nil
            }
            switch type {
            case "text"?:
                let id = "\(messageID):text:\(Self.next(&snapshotTextCounts, messageID))"
                events.append(.assistantText(itemID: id, text: block["text"]?.string ?? ""))
            case "thinking"?:
                let id = "\(messageID):thinking:\(Self.next(&snapshotThinkingCounts, messageID))"
                let text = block["thinking"]?.string ?? ""
                if !text.isEmpty { events.append(.reasoningText(itemID: id, text: text)) }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                let previous = lastThinking
                lastThinking =
                    trimmed.isEmpty
                    ? nil
                    : LastThinking(
                        messageID: messageID, itemID: id, text: trimmed,
                        followsThinking: previous?.messageID == messageID)
            case "tool_use"?, "server_tool_use"?, "mcp_tool_use"?:
                guard let id = block["id"]?.string, let name = block["name"]?.string else { continue }
                let presentation = presentations[id]
                events += startTool(
                    id: id, name: name, input: block["input"] ?? [:], final: true, displayName: presentation?.tool,
                    serverName: presentation?.server)
            default:
                // Server tools (web search, code execution) return their results inside the message.
                if let toolUseID = block["tool_use_id"]?.string {
                    let isError = block["is_error"]?.bool == true || (block.at("content.type")?.string?.hasSuffix("_error") ?? false)
                    events += completeTool(
                        id: toolUseID, content: block["content"], structured: nil, isError: isError, notExecuted: false)
                }
            }
        }
        return events
    }

    private mutating func user(_ frame: JSONValue) -> [AgentEvent] {
        guard frame["parent_tool_use_id"]?.string == nil, let blocks = frame.at("message.content")?.array else { return [] }
        let results = blocks.filter { $0["tool_use_id"]?.string != nil }
        guard !results.isEmpty else { return [] }
        let structured = results.count == 1 ? frame["tool_use_result"] : nil
        let meta = frame["tool_result_meta"]?.array ?? []
        var events: [AgentEvent] = []
        for result in results {
            guard let id = result["tool_use_id"]?.string else { continue }
            let notExecuted = meta.first { $0["id"]?.string == id }?["non_execution_kind"]?.string != nil
            events += completeTool(
                id: id, content: result["content"], structured: structured, isError: result["is_error"]?.bool == true,
                notExecuted: notExecuted)
        }
        return events
    }

    /// A subagent's own tool calls become progress lines on the agent's tool item.
    private mutating func subagentActivity(parent: String, content: [JSONValue]) -> [AgentEvent] {
        guard let call = tools[parent], call.info != nil, !call.completed else { return [] }
        let lines = content.compactMap { block -> String? in
            guard block["type"]?.string == "tool_use", let name = block["name"]?.string, !ClaudeTools.isHidden(name) else {
                return nil
            }
            let info = ClaudeTools.info(
                id: block["id"]?.string ?? "", name: name, input: block["input"] ?? [:], workingDirectory: workingDirectory,
                fileContents: { _ in nil })
            return "→ " + info.title
        }
        return lines.isEmpty ? [] : [.toolOutput(id: parent, delta: lines.joined(separator: "\n") + "\n")]
    }

    private func toolPresentations(_ frame: JSONValue) -> [String: (server: String?, tool: String?)] {
        var presentations: [String: (server: String?, tool: String?)] = [:]
        for entry in frame["tool_use_meta"]?.array ?? [] {
            guard let id = entry["id"]?.string else { continue }
            presentations[id] = (nonEmpty(entry["server_display_name"]?.string), nonEmpty(entry["display_name"]?.string))
        }
        return presentations
    }

    // MARK: Tools

    private mutating func startTool(
        id: String, name: String, input: JSONValue, final: Bool, refine: Bool = false, displayName: String? = nil,
        serverName: String? = nil
    ) -> [AgentEvent] {
        var call = tools[id] ?? ToolCall(name: name, input: input)
        // A streamed partial input never overrides the full one.
        if refine, call.hasFullInput { return [] }
        if final || tools[id] == nil { call.input = input }
        if final { call.hasFullInput = true }
        defer { tools[id] = call }
        if ClaudeTools.isHidden(name) {
            guard final else { return [] }
            switch ClaudeTools.normalizedName(name) {
            case "todowrite":
                return ClaudeTools.todoPlan(input).map { [.plan(text: $0)] } ?? []
            case "exitplanmode":
                changedPlanMode = true
                return Self.proposedPlan(input).map { [.plan(text: $0)] } ?? []
            case "enterplanmode":
                changedPlanMode = true
                return []
            default:
                return []
            }
        }
        let info = ClaudeTools.info(
            id: id, name: name, input: input, workingDirectory: workingDirectory, displayName: displayName,
            serverName: serverName, fileContents: fileContents)
        let previous = call.info
        call.info = info
        if previous == nil { return [.toolStarted(info)] }
        return previous == info ? [] : [.toolUpdated(info)]
    }

    private mutating func completeTool(
        id: String, content: JSONValue?, structured: JSONValue?, isError: Bool, notExecuted: Bool
    ) -> [AgentEvent] {
        guard var call = tools[id], !call.completed else { return [] }
        call.completed = true
        tools[id] = call
        let resultText = ClaudeTools.text(of: content)
        guard var info = call.info else {
            guard !isError, taskList.apply(tool: call.name, input: call.input, structured: structured, resultText: resultText),
                let plan = taskList.plan
            else { return [] }
            return [.plan(text: plan)]
        }
        var events: [AgentEvent] = []
        if !isError,
            let detail = ClaudeTools.resultDetail(
                name: call.name, input: call.input, structured: structured, workingDirectory: workingDirectory),
            detail != info.detail
        {
            info.detail = detail
            tools[id]?.info = info
            events.append(.toolUpdated(info))
        }
        let declined = notExecuted || structured?.string == "User rejected tool use"
        let status: ItemStatus = declined ? .declined : isError ? .failed : .completed
        let output = ClaudeTools.output(name: call.name, content: content, structured: structured, isError: isError)
        events.append(.toolCompleted(id: id, status: status, output: output))
        return events
    }

    static func proposedPlan(_ input: JSONValue) -> String? {
        guard let plan = input["plan"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !plan.isEmpty else { return nil }
        return plan
    }

    // MARK: System and results

    private mutating func system(_ frame: JSONValue) -> [AgentEvent] {
        switch frame["subtype"]?.string {
        case "init"?:
            sessionID = frame["session_id"]?.string ?? sessionID
            capabilities.formUnion(frame["capabilities"]?.array?.compactMap(\.string) ?? [])
            guard let model = frame["model"]?.string else { return [] }
            return resolveModel(model)
        case "compact_boundary"?:
            return [.notice(String(localized: "Context compacted"))]
        case "api_retry"?:
            guard !retryNoticed else { return [] }
            retryNoticed = true
            let error = (frame["error"]?.string ?? "error").replacingOccurrences(of: "_", with: " ")
            return [.notice(String(localized: "Claude API \(error); retrying…"))]
        case "informational"?:
            guard frame["level"]?.string != "info", let content = Self.cleaned(frame["content"]?.string) else { return [] }
            return [.notice(content)]
        case "model_refusal_fallback"?, "model_refusal_no_fallback"?:
            return Self.cleaned(frame["content"]?.string).map { [.notice($0)] } ?? []
        case "local_command_output"?:
            guard let content = Self.cleaned(frame["content"]?.string) else { return [] }
            return [.assistantText(itemID: frame["uuid"]?.string ?? UUID().uuidString, text: content)]
        case "task_notification"?:
            // A background command or agent finished after its tool call already returned.
            guard let id = frame["tool_use_id"]?.string, let call = tools[id], call.completed, call.info != nil,
                let summary = Self.cleaned(frame["summary"]?.string)
            else { return [] }
            return [.toolOutput(id: id, delta: "\n" + summary)]
        default:
            return []
        }
    }

    private mutating func result(_ frame: JSONValue) -> [AgentEvent] {
        var usage = TokenUsage()
        let models = frame["modelUsage"]?.object ?? [:]
        if let window = (model.flatMap { models[$0] } ?? models.values.first)?["contextWindow"]?.int, window > 0 {
            contextWindow = window
            usage.contextWindow = window
        }
        if let cost = frame["total_cost_usd"]?.number {
            processCost = cost
            usage.costUSD = costOffset + cost
        }
        return usage == TokenUsage() ? [] : [.usage(usage)]
    }

    private mutating func resolveModel(_ model: String) -> [AgentEvent] {
        guard model != self.model else { return [] }
        self.model = model
        return [.modelResolved(model)]
    }

    private func contextUsage(_ usage: MessageUsage) -> TokenUsage {
        TokenUsage(
            inputTokens: usage.input + usage.cacheCreation + usage.cacheRead, outputTokens: usage.output,
            cachedInputTokens: usage.cacheRead, contextWindow: contextWindow)
    }

    // MARK: Turn outcome

    /// How a `result` frame ends the turn, following T3's reading of terminal reasons and API errors.
    static func outcome(of result: JSONValue, interruptRequested: Bool, assistantError: AssistantError?) -> TurnOutcome {
        if interruptRequested { return .interrupted }
        let terminal = result["terminal_reason"]?.string
        if terminal == "aborted_tools" || terminal == "aborted_streaming" { return .interrupted }
        let allErrors = (result["errors"]?.array ?? []).compactMap(\.string)
        let listed = allErrors.first { !$0.hasPrefix("[ede_diagnostic]") }
        let resultText = (result["result"]?.string).flatMap { cleaned($0) }
        let signedOut =
            assistantError?.kind == "authentication_failed"
            ? String(localized: "Claude Code is not signed in. Run `claude auth login` in Terminal, then try again.") : nil

        guard result["subtype"]?.string == "success" else {
            let lowered = allErrors.joined(separator: "\n").lowercased()
            if lowered.contains("interrupt") || lowered.contains("cancel") { return .interrupted }
            return .failed(
                listed ?? signedOut ?? terminalMessage(terminal, hint: nil) ?? subtypeMessage(result["subtype"]?.string))
        }
        switch result["api_error_status"]?.int {
        case 529?: return .failed(String(localized: "The Claude API is overloaded (529). Try again shortly."))
        case 429?: return .failed(String(localized: "Claude API rate limit reached. Try again later."))
        default: break
        }
        let apiError = terminal == "api_error" && resultText?.hasPrefix("API Error:") == true ? resultText.map { String($0.prefix(500)) } : nil
        if let message = terminalMessage(terminal, hint: apiError) { return .failed(listed ?? message) }
        if result["is_error"]?.bool == true {
            return .failed(listed ?? signedOut ?? resultText ?? assistantError?.text ?? String(localized: "Claude Code reported an error."))
        }
        return .completed
    }

    private static func terminalMessage(_ reason: String?, hint: String?) -> String? {
        let contextFull = String(
            localized: "Claude stopped: the prompt exceeds the model's context window. Run /compact or start a new thread.")
        switch reason {
        case "api_error"?: return hint ?? String(localized: "Claude gave up after repeated API errors.")
        case "malformed_tool_use_exhausted"?: return String(localized: "Claude gave up after repeated malformed tool calls.")
        case "budget_exhausted"?: return String(localized: "Claude stopped: the turn's token budget was exhausted.")
        case "structured_output_retry_exhausted"?: return String(localized: "Claude could not produce the requested structured output.")
        case "tool_deferred_unavailable"?:
            return String(localized: "Claude could not resume a deferred tool call: the tool is no longer available.")
        case "turn_setup_failed"?: return String(localized: "Claude could not start the turn.")
        case "blocking_limit"?: return hint ?? contextFull
        case "rapid_refill_breaker"?: return String(localized: "Claude stopped: the context refilled too quickly after compaction.")
        case "prompt_too_long"?: return contextFull
        case "image_error"?: return String(localized: "Claude stopped: an image in the conversation could not be processed.")
        case "model_error"?: return String(localized: "Claude stopped: the model returned an error.")
        default: return nil
        }
    }

    private static func subtypeMessage(_ subtype: String?) -> String {
        switch subtype {
        case "error_max_turns"?: String(localized: "Claude stopped after reaching the maximum number of turns.")
        case "error_max_budget_usd"?: String(localized: "Claude stopped after reaching its budget.")
        case "error_max_structured_output_retries"?: String(localized: "Claude could not produce the requested structured output.")
        default: String(localized: "Claude Code reported an error while running the turn.")
        }
    }

    // MARK: Helpers

    private static func next(_ counts: inout [String: Int], _ key: String) -> Int {
        let value = counts[key, default: 0]
        counts[key] = value + 1
        return value
    }

    private func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return text
    }

    /// Strips terminal escape sequences and surrounding whitespace; nil when nothing is left.
    static func cleaned(_ text: String?) -> String? {
        guard let text else { return nil }
        let stripped = text.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stripped.isEmpty ? nil : stripped
    }

    /// Claude 5.1 and newer models write their pre-tool updates as thinking.
    static func writesUpdatesAsThinking(_ model: String) -> Bool {
        guard let match = model.firstMatch(of: /claude-[a-z]+-(\d+)(?:-(\d{1,2}))?(?!\d)/), let major = Int(match.1) else {
            return false
        }
        return major > 5 || (major == 5 && (match.2.flatMap { Int($0) } ?? 0) >= 1)
    }
}
