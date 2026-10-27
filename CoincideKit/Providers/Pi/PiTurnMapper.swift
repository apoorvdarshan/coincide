import Foundation

/// Turns Pi's streamed session events (`message_*`, `tool_execution_*`, compaction, retry and extension
/// errors) into `AgentEvent`s. It does no I/O, so recorded Pi transcripts can be replayed through it.
struct PiTurnMapper {
    /// A tool call as far as Pi has described it.
    struct Tool {
        var name: String
        var args: JSONValue?
        var info: ToolCallInfo?
        /// Output streamed so far. Pi's shell tools resend everything printed in each update.
        var output = ""
        /// The tool trimmed its output (a long log), so updates no longer extend what was shown.
        var outputDiverged = false
        var finished = false
    }

    /// Context window of the active model, for usage reports.
    var contextWindow: Int?
    /// The session's folder; tool titles show paths inside it relative to it.
    var workingDirectory: String?
    /// Why Pi says the turn failed: a model error or an exhausted retry.
    private(set) var failure: String?
    /// Pi's estimate of the context after the last compaction, used until a response reports real usage.
    private(set) var tokensAfterCompaction: Int?
    /// Whether this turn compacted the context.
    private(set) var sawCompaction = false

    private struct Block {
        let id: String
        let isThinking: Bool
        var text = ""
        /// The authoritative text once the block ended.
        var final: String?
    }

    private var prefix = "t0"
    private var messageOrdinal = 0
    private var blocks: [Int: Block] = [:]
    private var tools: [String: Tool] = [:]
    private var toolOrder: [String] = []
    private var compactionCount = 0
    private var openCompaction: String?
    private var lastContextTokens: Int?
    private var lastPromptTokens: Int?
    private var declined: Set<String> = []
    private var lastPlan: String?

    /// Starts a turn whose new items get ids under `itemPrefix`.
    mutating func begin(itemPrefix: String) {
        prefix = itemPrefix
        failure = nil
        sawCompaction = false
        lastPlan = nil
    }

    func tool(_ id: String) -> Tool? { tools[id] }

    /// Records that the user denied a tool call, so its blocked result reads as declined rather than failed.
    mutating func markDeclined(_ toolCallID: String) {
        declined.insert(toolCallID)
    }

    mutating func handle(_ record: JSONValue) -> [AgentEvent] {
        switch record["type"]?.string {
        case "message_start":
            if record["message"]?["role"]?.string == "assistant" {
                messageOrdinal += 1
                blocks.removeAll()
            }
            return []
        case "message_update":
            return messageUpdated(record)
        case "message_end":
            return messageEnded(record["message"])
        case "tool_execution_start":
            guard let id = record["toolCallId"]?.string else { return [] }
            return announceTool(id: id, name: record["toolName"]?.string, args: record["args"])
        case "tool_execution_update":
            return toolProgressed(record)
        case "tool_execution_end":
            return toolEnded(record)
        case "compaction_start":
            return compactionStarted()
        case "compaction_end":
            return compactionEnded(record)
        case "auto_retry_start":
            return [.notice(Self.retryNotice(record))]
        case "auto_retry_end":
            failure =
                record["success"]?.bool == true
                ? nil
                : PiText.nonEmpty(record["finalError"]?.string) ?? String(localized: "Pi gave up retrying a provider error.")
            return []
        case "extension_error":
            return [.notice(Self.extensionErrorNotice(record))]
        default:
            return []
        }
    }

    /// Ends the turn: tools that never reported a result are marked failed and per-turn state is cleared.
    mutating func finish() -> [AgentEvent] {
        var events: [AgentEvent] = []
        for id in toolOrder {
            guard let tool = tools[id], !tool.finished, tool.info != nil else { continue }
            events.append(.toolCompleted(id: id, status: .failed, output: nil))
        }
        if let id = openCompaction { events.append(.toolCompleted(id: id, status: .failed, output: nil)) }
        tools.removeAll()
        toolOrder.removeAll()
        blocks.removeAll()
        declined.removeAll()
        openCompaction = nil
        return events
    }

    // MARK: Messages

    private mutating func messageUpdated(_ record: JSONValue) -> [AgentEvent] {
        var events = usage(record["usage"], final: false)
        guard let update = record["assistantMessageEvent"], let type = update["type"]?.string else { return events }
        let index = update["contentIndex"]?.int ?? 0
        switch type {
        case "text_delta", "thinking_delta":
            guard let delta = update["delta"]?.string, !delta.isEmpty else { break }
            let isThinking = type == "thinking_delta"
            var block = blocks[index] ?? Block(id: blockID(index), isThinking: isThinking)
            block.text += delta
            blocks[index] = block
            events.append(
                isThinking ? .reasoningDelta(itemID: block.id, delta: delta) : .assistantTextDelta(itemID: block.id, delta: delta))
        case "text_end", "thinking_end":
            events += finishBlock(index, isThinking: type == "thinking_end", text: update["content"]?.string)
        case "toolcall_start":
            // Pi 0.84.3+ names the tool here, before its arguments finish streaming.
            if let id = update["id"]?.string { events += announceTool(id: id, name: update["toolName"]?.string, args: nil) }
        case "toolcall_end":
            if let call = update["toolCall"], let id = call["id"]?.string {
                events += announceTool(id: id, name: call["name"]?.string, args: call["arguments"])
            }
        default:
            break
        }
        return events
    }

    private mutating func messageEnded(_ message: JSONValue?) -> [AgentEvent] {
        switch message?["role"]?.string {
        case "assistant":
            var events = usage(message?["usage"], final: true)
            // `message_end` is authoritative for every block of the response.
            for (index, block) in (message?["content"]?.array ?? []).enumerated() {
                switch block["type"]?.string {
                case "text": events += finishBlock(index, isThinking: false, text: block["text"]?.string ?? "")
                case "thinking": events += finishBlock(index, isThinking: true, text: block["thinking"]?.string ?? "")
                default: break
                }
            }
            blocks.removeAll()
            if message?["stopReason"]?.string == "error", failure == nil {
                failure = PiText.nonEmpty(message?["errorMessage"]?.string) ?? String(localized: "Pi reported a model error.")
            }
            return events
        case "custom":
            // Extensions add messages to the conversation; those meant to be seen have `display: true`.
            guard message?["display"]?.bool == true, let text = PiText.nonEmpty(PiText.content(message?["content"])) else {
                return []
            }
            return [.notice(text)]
        default:
            return []
        }
    }

    /// Settles a block on its authoritative text, emitting it unless exactly that text was already sent.
    private mutating func finishBlock(_ index: Int, isThinking: Bool, text: String?) -> [AgentEvent] {
        var block = blocks[index] ?? Block(id: blockID(index), isThinking: isThinking)
        let final = text ?? block.text
        guard block.final != final else { return [] }
        block.final = final
        blocks[index] = block
        guard !final.isEmpty else { return [] }
        return [isThinking ? .reasoningText(itemID: block.id, text: final) : .assistantText(itemID: block.id, text: final)]
    }

    private func blockID(_ index: Int) -> String { "\(prefix).m\(messageOrdinal).c\(index)" }

    /// Pi attaches the response's cumulative usage to its updates (0.84.2+); `totalTokens` is the context in use.
    /// While a response streams only a new prompt size is reported, so output growth does not flood the UI.
    private mutating func usage(_ usage: JSONValue?, final: Bool) -> [AgentEvent] {
        guard let total = usage?["totalTokens"]?.int, total > 0, total != lastContextTokens else { return [] }
        let prompt = ["input", "cacheRead", "cacheWrite"].reduce(0) { $0 + (usage?[$1]?.int ?? 0) }
        guard final || prompt != lastPromptTokens else { return [] }
        lastPromptTokens = prompt
        lastContextTokens = total
        return [
            .usage(
                TokenUsage(
                    inputTokens: total, outputTokens: usage?["output"]?.int, cachedInputTokens: usage?["cacheRead"]?.int,
                    contextWindow: contextWindow))
        ]
    }

    // MARK: Tools

    private mutating func announceTool(id: String, name: String?, args: JSONValue?) -> [AgentEvent] {
        if tools[id] == nil { toolOrder.append(id) }
        var tool = tools[id] ?? Tool(name: name ?? "tool")
        if let name { tool.name = name }
        if let args, !args.isNull { tool.args = args }
        // The plan tool of Coincide's extension carries the plan; it is not shown as a tool call.
        if tool.name == PiExtension.planToolName {
            tools[id] = tool
            return planEvents(tool.args)
        }
        let info = PiTools.info(id: id, name: tool.name, args: tool.args, relativeTo: workingDirectory)
        let previous = tool.info
        tool.info = info
        tools[id] = tool
        guard info != previous else { return [] }
        return [previous == nil ? .toolStarted(info) : .toolUpdated(info)]
    }

    private mutating func planEvents(_ args: JSONValue?) -> [AgentEvent] {
        guard let plan = PiText.nonEmpty(args?["plan"]?.string), plan != lastPlan else { return [] }
        lastPlan = plan
        return [.plan(text: plan)]
    }

    private mutating func toolProgressed(_ record: JSONValue) -> [AgentEvent] {
        guard let id = record["toolCallId"]?.string else { return [] }
        var events = announceTool(id: id, name: record["toolName"]?.string, args: record["args"])
        guard var tool = tools[id], tool.name != PiExtension.planToolName, !tool.outputDiverged else { return events }
        let text = PiTools.progressText(name: tool.name, partialResult: record["partialResult"])
        guard !text.isEmpty else { return events }
        if text.utf8.starts(with: tool.output.utf8) {
            let delta = String(decoding: text.utf8.dropFirst(tool.output.utf8.count), as: UTF8.self)
            tool.output = text
            if !delta.isEmpty { events.append(.toolOutput(id: id, delta: delta)) }
        } else {
            tool.outputDiverged = true
        }
        tools[id] = tool
        return events
    }

    private mutating func toolEnded(_ record: JSONValue) -> [AgentEvent] {
        guard let id = record["toolCallId"]?.string else { return [] }
        var events = announceTool(id: id, name: record["toolName"]?.string, args: record["args"])
        guard var tool = tools[id], !tool.finished else { return events }
        tool.finished = true
        tools[id] = tool
        guard tool.name != PiExtension.planToolName else { return events }
        let result = record["result"]
        let output = PiTools.outputText(name: tool.name, result: result)
        if let finished = PiTools.finishedInfo(
            id: id, name: tool.name, args: tool.args, result: result, relativeTo: workingDirectory),
            finished != tool.info
        {
            tools[id]?.info = finished
            events.append(.toolUpdated(finished))
        }
        if PiTools.isTodo(tool.name), let plan = PiTools.todoMarkdown(result), plan != lastPlan {
            lastPlan = plan
            events.append(.plan(text: plan))
        }
        let status: ItemStatus
        if record["isError"]?.bool == true {
            let refused = declined.contains(id) || output.hasPrefix(PiExtension.planModeBlockPrefix)
            status = refused ? .declined : .failed
        } else {
            status = .completed
        }
        events.append(.toolCompleted(id: id, status: status, output: output.isEmpty ? nil : output))
        return events
    }

    // MARK: Compaction, retries, extensions

    private mutating func compactionStarted() -> [AgentEvent] {
        var events: [AgentEvent] = []
        if let open = openCompaction { events.append(.toolCompleted(id: open, status: .failed, output: nil)) }
        compactionCount += 1
        sawCompaction = true
        let id = "\(prefix).compaction\(compactionCount)"
        openCompaction = id
        events.append(.toolStarted(ToolCallInfo(id: id, category: .other, title: String(localized: "Compacting context"))))
        return events
    }

    private mutating func compactionEnded(_ record: JSONValue) -> [AgentEvent] {
        var events = openCompaction == nil ? compactionStarted() : []
        guard let id = openCompaction else { return events }
        openCompaction = nil
        if let result = record["result"], result.object != nil {
            // Overflow recovery retries the prompt after compacting, which supersedes the overflow error.
            if record["willRetry"]?.bool == true { failure = nil }
            tokensAfterCompaction = result["estimatedTokensAfter"]?.int
            let title: String
            if let before = result["tokensBefore"]?.int, let after = result["estimatedTokensAfter"]?.int {
                title = String(localized: "Compacted context from \(before.formatted()) to about \(after.formatted()) tokens")
            } else {
                title = String(localized: "Compacted context")
            }
            events.append(.toolUpdated(ToolCallInfo(id: id, category: .other, title: title)))
            events.append(.toolCompleted(id: id, status: .completed, output: PiText.nonEmpty(result["summary"]?.string)))
        } else if record["aborted"]?.bool == true {
            events.append(.toolCompleted(id: id, status: .failed, output: String(localized: "Compaction was stopped.")))
        } else {
            let message = PiText.nonEmpty(record["errorMessage"]?.string) ?? String(localized: "Pi could not compact the context.")
            events.append(.toolCompleted(id: id, status: .failed, output: message))
        }
        return events
    }

    private static func retryNotice(_ record: JSONValue) -> String {
        let attempt = max(1, record["attempt"]?.int ?? 1)
        let maximum = max(attempt, record["maxAttempts"]?.int ?? attempt)
        guard let reason = PiText.nonEmpty(record["errorMessage"]?.string) else {
            return String(localized: "Retrying after a provider error (attempt \(attempt) of \(maximum)).")
        }
        return String(localized: "Retrying after a provider error (attempt \(attempt) of \(maximum)): \(reason)")
    }

    private static func extensionErrorNotice(_ record: JSONValue) -> String {
        let name = extensionName(record["extensionPath"]?.string)
        let summary =
            PiText.nonEmpty(record["event"]?.string).map { String(localized: "\(name) failed during \($0).") }
            ?? String(localized: "\(name) failed.")
        guard let detail = PiText.nonEmpty(record["error"]?.string) else { return summary }
        return summary + "\n\n" + PiText.truncated(detail, limit: 2_000)
    }

    /// `~/.pi/agent/extensions/todo.ts` is "todo"; a folder extension (`subagent/index.ts`) is named after its folder.
    private static func extensionName(_ path: String?) -> String {
        guard let path = PiText.nonEmpty(path) else { return String(localized: "A Pi extension") }
        let url = URL(fileURLWithPath: path)
        let base = url.deletingPathExtension().lastPathComponent
        let name = base == "index" ? url.deletingLastPathComponent().lastPathComponent : base
        return name.isEmpty ? String(localized: "A Pi extension") : name
    }
}
