import Foundation

/// Turns the `session/update` stream of one ACP session into Coincide events.
///
/// ACP sends message and thought text as chunks without item ids, so the mapper groups them
/// into segments: a segment ends when the agent switches between text, reasoning and tools, and
/// its full text is then reported once more as authoritative. Tool calls are merged across
/// updates; output that grows is streamed as deltas and the final output replaces it.
@MainActor
struct ACPEventMapper {
    private struct Segment {
        var id: String
        var text: String
        var messageID: String?
    }

    private struct Tool {
        var state: ACPToolCallState
        var info: ToolCallInfo
        var streamed = ""
        var completion: (status: ItemStatus, output: String?)?
    }

    let workingDirectory: URL
    private var tools: [String: Tool] = [:]
    private var assistant: Segment?
    private var reasoning: Segment?
    private var turn = 0
    private var segmentCount = 0
    private var declined: Set<String> = []
    private var lastPlan: String?
    /// The latest plan document the agent wrote (Grok keeps it in `…/.grok/sessions/…/plan.md`).
    private(set) var planFileMarkdown: String?

    init(workingDirectory: URL) {
        self.workingDirectory = workingDirectory
    }

    mutating func beginTurn() {
        turn += 1
        segmentCount = 0
        assistant = nil
        reasoning = nil
        declined.removeAll()
        lastPlan = nil
        planFileMarkdown = nil
    }

    mutating func map(_ update: ACPSessionUpdate, flavor: ACPAgentFlavor, terminals: ACPTerminals?) -> [AgentEvent] {
        switch update {
        case .agentMessageChunk(let block, let messageID):
            guard let text = block.displayText, !text.isEmpty else { return [] }
            var events = closeReasoning()
            if let open = assistant, let messageID, let previous = open.messageID, previous != messageID {
                events += closeAssistant()
            }
            if assistant == nil {
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return events }
                assistant = Segment(id: nextSegmentID("assistant"), text: "", messageID: messageID)
            }
            assistant?.text += text
            events.append(.assistantTextDelta(itemID: assistant!.id, delta: text))
            return events
        case .agentThoughtChunk(let block, let messageID):
            guard case .text(let text) = block, !text.isEmpty else { return [] }
            var events = closeAssistant()
            if let open = reasoning, let messageID, let previous = open.messageID, previous != messageID {
                events += closeReasoning()
            }
            if reasoning == nil {
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return events }
                reasoning = Segment(id: nextSegmentID("reasoning"), text: "", messageID: messageID)
            }
            reasoning?.text += text
            events.append(.reasoningDelta(itemID: reasoning!.id, delta: text))
            return events
        case .toolCall(let call), .toolCallUpdate(let call):
            return toolEvents(call, flavor: flavor, terminals: terminals)
        case .plan(let entries):
            guard !entries.isEmpty else { return [] }
            let plan = Self.planMarkdown(entries)
            lastPlan = plan
            return [.plan(text: plan)]
        default:
            return []
        }
    }

    /// Merges a tool call update and reports what changed.
    mutating func toolEvents(_ call: ACPToolCallUpdate, flavor: ACPAgentFlavor, terminals: ACPTerminals?) -> [AgentEvent] {
        var events: [AgentEvent] = []
        var state: ACPToolCallState
        let previous = tools[call.id]
        if let previous {
            state = previous.state
            state.merge(call)
        } else {
            events += closeSegments()
            state = ACPToolCallState(call)
        }
        flavor.normalize(&state)
        rememberPlanFile(state)

        let info = state.info(relativeTo: workingDirectory)
        var tool = previous ?? Tool(state: state, info: info)
        if previous == nil {
            events.append(.toolStarted(info))
        } else if info != previous?.info {
            events.append(.toolUpdated(info))
        }
        tool.state = state
        tool.info = info
        if info.category == .todo, let todos = Self.todoEntries(state.rawInput), !todos.isEmpty {
            let plan = Self.planMarkdown(todos)
            if plan != lastPlan {
                lastPlan = plan
                events.append(.plan(text: plan))
            }
        }

        let output = state.outputText { terminals?.snapshot($0) }
        if state.isFinished {
            let status: ItemStatus = declined.contains(call.id) ? .declined : state.status == .failed ? .failed : .completed
            let final = Self.finalOutput(output, state: state)
            if tool.completion?.status != status || tool.completion?.output != final {
                tool.completion = (status, final)
                events.append(.toolCompleted(id: call.id, status: status, output: final))
            }
        } else if let output, output.count > tool.streamed.count, output.hasPrefix(tool.streamed) {
            events.append(.toolOutput(id: call.id, delta: String(output.dropFirst(tool.streamed.count))))
            tool.streamed = output
        }
        tools[call.id] = tool
        return events
    }

    /// The presentation of a known tool call.
    func info(for id: String) -> ToolCallInfo? { tools[id]?.info }

    func kind(of id: String) -> String? { tools[id]?.state.kind }

    /// The user declined the tool's approval; report it now in case the agent never does.
    mutating func markDeclined(_ id: String) -> [AgentEvent] {
        declined.insert(id)
        guard var tool = tools[id], tool.completion == nil else { return [] }
        tool.completion = (.declined, nil)
        tools[id] = tool
        return [.toolCompleted(id: id, status: .declined, output: nil)]
    }

    /// Ends open text segments with their full text.
    mutating func closeSegments() -> [AgentEvent] {
        closeReasoning() + closeAssistant()
    }

    private mutating func closeAssistant() -> [AgentEvent] {
        guard let segment = assistant else { return [] }
        assistant = nil
        return [.assistantText(itemID: segment.id, text: segment.text)]
    }

    private mutating func closeReasoning() -> [AgentEvent] {
        guard let segment = reasoning else { return [] }
        reasoning = nil
        return [.reasoningText(itemID: segment.id, text: segment.text)]
    }

    private mutating func nextSegmentID(_ kind: String) -> String {
        segmentCount += 1
        return "\(kind)-\(turn)-\(segmentCount)"
    }

    private mutating func rememberPlanFile(_ state: ACPToolCallState) {
        for entry in state.content {
            if case .diff(let path, _, let text) = entry, path.hasSuffix("/plan.md"), path.contains("/.grok/sessions/") {
                planFileMarkdown = text
            }
        }
    }

    private static func finalOutput(_ output: String?, state: ACPToolCallState) -> String? {
        guard state.resolvedCategory == .command, let code = state.exitCode, code != 0 else { return output }
        let note = String(localized: "Exit code \(code)")
        guard var text = output else { return note }
        while text.hasSuffix("\n") { text.removeLast() }
        return "\(text)\n\n\(note)"
    }

    /// Items of a todo tool's input, as `{"todos":[{"content":…,"status":…}]}`.
    static func todoEntries(_ input: JSONValue?) -> [ACPPlanEntry]? {
        guard let items = input?["todos"]?.array ?? input?["items"]?.array else { return nil }
        return items.compactMap { item in
            guard let text = (item["content"] ?? item["title"] ?? item["text"] ?? item["description"])?.string else { return nil }
            let status = item["status"]?.string?.lowercased().replacingOccurrences(of: "-", with: "_") ?? "pending"
            return ACPPlanEntry(content: text, status: status == "done" ? "completed" : status)
        }
    }

    /// A markdown checklist; the step in progress is bold.
    static func planMarkdown(_ entries: [ACPPlanEntry]) -> String {
        entries.map { entry in
            let text = entry.content.trimmingCharacters(in: .whitespacesAndNewlines)
            switch entry.status {
            case "completed": return "- [x] \(text)"
            case "in_progress", "inProgress": return "- [ ] **\(text)**"
            default: return "- [ ] \(text)"
            }
        }.joined(separator: "\n")
    }
}
