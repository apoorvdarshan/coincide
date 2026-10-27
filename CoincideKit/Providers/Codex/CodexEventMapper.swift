import Foundation

/// Turns `codex app-server` item notifications for one thread into `AgentEvent`s.
///
/// It holds no process, so recorded protocol traffic can be replayed through it. Turn lifecycle
/// (`turn/started`, `turn/completed`, errors) is handled by `CodexSession`.
struct CodexEventMapper {
    /// The Codex thread being driven. Items of other threads (subagents) are not shown.
    var threadID: String?
    let presentation: CodexPresentation
    private(set) var turnID: String?
    private(set) var previousTurnID: String?
    private var adoptsNextTurn = false
    /// What each tool item last showed, to tell starts from updates.
    private var tools: [String: ToolCallInfo] = [:]
    /// File changes by item, for any thread, so approval prompts can show the diff.
    private var fileChanges: [String: [JSONValue]] = [:]
    private var proposedPlan: String?
    private var todoList: String?

    init(workingDirectory: String) {
        presentation = CodexPresentation(workingDirectory: workingDirectory)
    }

    /// Prepares for a turn whose id is not known yet; the first item notification of a new turn adopts it.
    mutating func beginTurn() {
        endTurn()
        adoptsNextTurn = true
        tools.removeAll()
        fileChanges.removeAll()
        proposedPlan = nil
        todoList = nil
    }

    mutating func adoptTurn(_ id: String) {
        guard turnID == nil, id != previousTurnID else { return }
        turnID = id
        adoptsNextTurn = false
    }

    mutating func endTurn() {
        if let turnID { previousTurnID = turnID }
        turnID = nil
        adoptsNextTurn = false
    }

    func fileChanges(for itemID: String) -> [JSONValue]? {
        fileChanges[itemID]
    }

    // MARK: Notifications

    mutating func handle(method: String, params: JSONValue) -> [AgentEvent] {
        recordFileChanges(method: method, params: params)
        let isOurThread = threadID != nil && params["threadId"]?.string == threadID
        switch method {
        case "thread/tokenUsage/updated":
            guard isOurThread, let usage = usage(params["tokenUsage"]) else { return [] }
            return [.usage(usage)]
        case "model/rerouted":
            guard isOurThread, let model = params["toModel"]?.string else { return [] }
            let from = params["fromModel"]?.string ?? ""
            return [.modelResolved(model), .notice(String(localized: "Codex switched from \(from) to \(model)."))]
        case "warning":
            guard isOurThread, let message = params["message"]?.string, !message.isEmpty else { return [] }
            return [.notice(message)]
        default:
            break
        }
        guard isOurThread else { return [] }
        switch turnMatch(params["turnId"]?.string) {
        case .current:
            return itemEvents(method: method, params: params)
        case .previous:
            // Background work of a finished turn: let its tools finish, but add nothing new.
            return itemEvents(method: method, params: params).filter { event in
                switch event {
                case .toolOutput, .toolCompleted: true
                default: false
                }
            }
        case .other:
            return []
        }
    }

    private enum TurnMatch {
        case current
        case previous
        case other
    }

    private mutating func turnMatch(_ id: String?) -> TurnMatch {
        guard let id else { return .other }
        if id == turnID { return .current }
        if id == previousTurnID { return .previous }
        if adoptsNextTurn {
            adoptTurn(id)
            return .current
        }
        return .other
    }

    private mutating func recordFileChanges(method: String, params: JSONValue) {
        switch method {
        case "item/started", "item/completed":
            guard let item = params["item"], item["type"]?.string == "fileChange", let id = item["id"]?.string,
                let changes = item["changes"]?.array
            else { return }
            fileChanges[id] = changes
        case "item/fileChange/patchUpdated":
            guard let id = params["itemId"]?.string, let changes = params["changes"]?.array else { return }
            fileChanges[id] = changes
        default:
            return
        }
    }

    private mutating func itemEvents(method: String, params: JSONValue) -> [AgentEvent] {
        let itemID = params["itemId"]?.string
        let delta = params["delta"]?.string ?? ""
        switch method {
        case "item/started":
            guard let item = params["item"] else { return [] }
            return itemStarted(item)
        case "item/completed":
            guard let item = params["item"] else { return [] }
            return itemCompleted(item)
        case "item/agentMessage/delta":
            guard let itemID, !delta.isEmpty else { return [] }
            return [.assistantTextDelta(itemID: itemID, delta: delta)]
        case "item/reasoning/summaryTextDelta":
            guard let itemID, !delta.isEmpty else { return [] }
            let part = Self.reasoningPartID(itemID, "summary", params["summaryIndex"]?.int ?? 0)
            return [.reasoningDelta(itemID: part, delta: delta)]
        case "item/reasoning/textDelta":
            guard let itemID, !delta.isEmpty else { return [] }
            let part = Self.reasoningPartID(itemID, "content", params["contentIndex"]?.int ?? 0)
            return [.reasoningDelta(itemID: part, delta: delta)]
        case "item/commandExecution/outputDelta":
            guard let itemID, !delta.isEmpty else { return [] }
            return [.toolOutput(id: itemID, delta: delta)]
        case "item/fileChange/patchUpdated":
            guard let itemID, let changes = params["changes"]?.array else { return [] }
            return show(presentation.fileChangeInfo(id: itemID, changes: changes)).map { [$0] } ?? []
        case "item/mcpToolCall/progress":
            guard let itemID, let message = params["message"]?.string, !message.isEmpty else { return [] }
            return [.toolOutput(id: itemID, delta: message + "\n")]
        case "item/plan/delta":
            guard !delta.isEmpty else { return [] }
            proposedPlan = (proposedPlan ?? "") + delta
            return planEvents
        case "turn/plan/updated":
            todoList = CodexPresentation.todoMarkdown(
                explanation: params["explanation"]?.string, steps: params["plan"]?.array ?? [])
            return planEvents
        default:
            return []
        }
    }

    // MARK: Items

    private mutating func itemStarted(_ item: JSONValue) -> [AgentEvent] {
        guard let id = item["id"]?.string else { return [] }
        if item["type"]?.string == "plan" {
            proposedPlan = item["text"]?.string
            return proposedPlan?.isEmpty == false ? planEvents : []
        }
        guard let info = toolInfo(item, id: id) else { return [] }
        return show(info).map { [$0] } ?? []
    }

    private mutating func itemCompleted(_ item: JSONValue) -> [AgentEvent] {
        guard let id = item["id"]?.string else { return [] }
        switch item["type"]?.string {
        case "agentMessage":
            guard let text = item["text"]?.string, !text.isEmpty else { return [] }
            return [.assistantText(itemID: id, text: text)]
        case "reasoning":
            var events: [AgentEvent] = []
            for stream in ["summary", "content"] {
                for (index, part) in (item[stream]?.array ?? []).enumerated() {
                    guard let text = part.string, !text.isEmpty else { continue }
                    events.append(.reasoningText(itemID: Self.reasoningPartID(id, stream, index), text: text))
                }
            }
            return events
        case "plan":
            proposedPlan = item["text"]?.string ?? proposedPlan
            return planEvents
        case "contextCompaction":
            return [.notice(String(localized: "Context compacted"))]
        default:
            guard let info = toolInfo(item, id: id) else { return [] }
            let (status, output) = Self.completion(item)
            return [show(info), AgentEvent.toolCompleted(id: id, status: status, output: output)].compactMap { $0 }
        }
    }

    private func toolInfo(_ item: JSONValue, id: String) -> ToolCallInfo? {
        switch item["type"]?.string {
        case "commandExecution":
            return presentation.commandInfo(
                id: id, command: item["command"]?.string ?? "", actions: item["commandActions"]?.array ?? [])
        case "fileChange":
            return presentation.fileChangeInfo(id: id, changes: item["changes"]?.array ?? [])
        case "mcpToolCall":
            return CodexPresentation.mcpInfo(item, id: id)
        case "dynamicToolCall":
            return CodexPresentation.dynamicToolInfo(item, id: id)
        case "webSearch":
            return CodexPresentation.webSearchInfo(item, id: id)
        case "collabAgentToolCall":
            return CodexPresentation.collabInfo(item, id: id)
        case "imageView":
            let path = item["path"]?.string ?? ""
            let name = (path as NSString).lastPathComponent
            return ToolCallInfo(id: id, category: .read, title: String(localized: "View \(name)"), detail: path)
        case "imageGeneration":
            return ToolCallInfo(
                id: id, category: .other, title: String(localized: "Generate an image"),
                detail: item["revisedPrompt"]?.string)
        case "sleep":
            let seconds = Int(((item["durationMs"]?.number ?? 0) / 1000).rounded())
            return ToolCallInfo(id: id, category: .other, title: String(localized: "Wait \(seconds) s"))
        default:
            return nil
        }
    }

    /// Final status and output of a completed tool item.
    private static func completion(_ item: JSONValue) -> (ItemStatus, String?) {
        let status = item["status"]?.string
        switch item["type"]?.string {
        case "commandExecution":
            let exitCode = item["exitCode"]?.int
            let failed = status == "failed" || (exitCode ?? 0) != 0
            let itemStatus: ItemStatus = status == "declined" ? .declined : failed ? .failed : .completed
            return (itemStatus, CodexPresentation.commandOutput(item["aggregatedOutput"]?.string, exitCode: exitCode))
        case "fileChange":
            return (status == "declined" ? .declined : status == "failed" ? .failed : .completed, nil)
        case "mcpToolCall":
            if let message = item.at("error.message")?.string { return (.failed, message) }
            return (status == "failed" ? .failed : .completed, CodexPresentation.mcpResultText(item["result"]))
        case "dynamicToolCall":
            let failed = status == "failed" || item["success"]?.bool == false
            return (failed ? .failed : .completed, CodexPresentation.dynamicToolOutput(item["contentItems"]))
        case "webSearch":
            return (.completed, CodexPresentation.webSearchResults(item["results"]))
        case "collabAgentToolCall":
            let failed = status == "failed" || status == "interrupted"
            return (failed ? .failed : .completed, CodexPresentation.collabOutput(item))
        case "imageGeneration":
            if let failure = item["failure"], !failure.isNull {
                return (.failed, failure["message"]?.string ?? failure.displayText)
            }
            return (.completed, item["savedPath"]?.string)
        default:
            return (.completed, nil)
        }
    }

    /// Emits a tool the first time it is seen and again only when its title or detail changed.
    private mutating func show(_ info: ToolCallInfo) -> AgentEvent? {
        guard let shown = tools[info.id] else {
            tools[info.id] = info
            return .toolStarted(info)
        }
        guard shown != info else { return nil }
        tools[info.id] = info
        return .toolUpdated(info)
    }

    // MARK: Usage and plans

    /// Context fill is the newest request's total, as in T3 Code; `total` counts every request of the thread.
    private func usage(_ tokenUsage: JSONValue?) -> TokenUsage? {
        guard let last = tokenUsage?["last"] else { return nil }
        return TokenUsage(
            inputTokens: last["totalTokens"]?.int, outputTokens: last["outputTokens"]?.int,
            cachedInputTokens: last["cachedInputTokens"]?.int, contextWindow: tokenUsage?["modelContextWindow"]?.int)
    }

    /// The proposed plan (Plan mode) and the todo list (`update_plan`) of the turn, whichever exist.
    private var planEvents: [AgentEvent] {
        let text = [proposedPlan, todoList]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        return text.isEmpty ? [] : [.plan(text: text)]
    }

    /// Each summary or content part of a reasoning item is its own transcript entry, as in T3 Code.
    static func reasoningPartID(_ itemID: String, _ stream: String, _ index: Int) -> String {
        "\(itemID)#\(stream)\(index)"
    }
}
