import Foundation

/// Maps what `cursor-agent acp` sends during a turn (`session/update` notifications, permission
/// requests and the `cursor/*` extension requests) to `AgentEvent`s.
///
/// Cursor streams text and reasoning as chunks without message ids, so the mapper groups them
/// into segments: switching between text and reasoning, a tool call, an approval or the end of
/// the turn closes the open segment and reports its full text.
struct CursorEventMapper {
    enum TodoStatus: Sendable {
        case pending
        case inProgress
        case completed
        case cancelled
    }

    struct Todo: Equatable, Sendable {
        var id: String
        var content: String
        var status: TodoStatus
    }

    /// A question from `cursor/ask_question`, kept to turn the user's answers back into Cursor's option ids.
    struct Question: Equatable, Sendable {
        struct Option: Equatable, Sendable {
            var id: String
            /// Unique within the question, since answers come back as labels.
            var label: String
        }

        var id: String
        var prompt: String
        var options: [Option]
        var allowsMultiple: Bool
    }

    private struct Segment {
        var id: String
        var text = ""
    }

    private struct Tool {
        var kind = "other"
        var title = ""
        var input: [String: JSONValue] = [:]
        var diff: String?
        var isNewFile = false
        var progress: String?
        var info: ToolCallInfo?
        var isFinished = false
    }

    /// The extra option Cursor adds when it falls back to asking a question through `session/request_permission`.
    nonisolated static let skipQuestionOptionID = "__ask_question_skip__"
    /// Longest tool output, diff or input kept in the transcript; Cursor reports whole files and command logs.
    nonisolated static let maxTextLength = 100_000

    private let directoryPrefixes: [String]
    private var turn = 0
    private var segmentCount = 0
    private var assistant: Segment?
    private var reasoning: Segment?
    private var lastAssistantText = ""
    /// A chunk that reads like Cursor's own error report, held back until more output shows it was not the end.
    private var heldReport: String?
    private var tools: [String: Tool] = [:]
    /// Todo, plan and question tool calls, shown as the plan or the question instead of as tool items.
    private var hiddenTools: Set<String> = []
    private var declinedTools: Set<String> = []
    /// Cursor's todo list lives as long as the chat, and updates may only carry the changed items.
    private var todos: [Todo] = []
    private var hasProposedPlan = false
    private var lastPlan: String?

    nonisolated init(workingDirectory: URL) {
        let path = workingDirectory.standardizedFileURL.path
        var paths = [path, workingDirectory.resolvingSymlinksInPath().path]
        // macOS reaches /tmp, /var and /etc through /private, and Cursor may report either form.
        for root in ["/tmp/", "/var/", "/etc/"] where path.hasPrefix(root) { paths.append("/private" + path) }
        if path.hasPrefix("/private/") { paths.append(String(path.dropFirst("/private".count))) }
        var seen = Set<String>()
        directoryPrefixes = paths.map { $0.hasSuffix("/") ? $0 : $0 + "/" }.filter { seen.insert($0).inserted }
    }

    nonisolated mutating func beginTurn() {
        turn += 1
        segmentCount = 0
        assistant = nil
        reasoning = nil
        lastAssistantText = ""
        heldReport = nil
        tools = [:]
        hiddenTools = []
        declinedTools = []
        hasProposedPlan = false
        lastPlan = nil
    }

    /// Reports the full text of whatever is still streaming, including a held error report that did
    /// not become the turn's failure.
    nonisolated mutating func endTurn() -> [AgentEvent] {
        releaseReport() + closeSegments()
    }

    /// The error Cursor reported instead of finishing the turn, if any. Cursor still ends such a turn
    /// normally: it appends the error as a last chunk of its own ("\n\nError: …"), which is then taken
    /// from the transcript to become the turn's failure. A whole message that is only a connection
    /// diagnostic counts too, as in T3 Code's `CursorTransportFailure`.
    nonisolated mutating func takeFailure() -> String? {
        if let report = heldReport {
            heldReport = nil
            return Self.errorReport(in: report)
        }
        return Self.transportFailure(in: assistant?.text ?? lastAssistantText)
    }

    // MARK: Session updates

    nonisolated mutating func handle(update: JSONValue) -> [AgentEvent] {
        switch update["sessionUpdate"]?.string {
        case "agent_message_chunk":
            guard let text = Self.text(of: update["content"]), !text.isEmpty else { return [] }
            let released = releaseReport()
            if Self.errorReport(in: text) != nil {
                heldReport = text
                return released
            }
            return released + closeReasoning() + [appendAssistant(text)]
        case "agent_thought_chunk":
            guard let text = Self.text(of: update["content"]), !text.isEmpty else { return [] }
            return releaseReport() + closeAssistant() + [appendReasoning(text)]
        case "tool_call", "tool_call_update":
            return releaseReport() + closeSegments() + handleTool(update)
        case "plan":
            // A proposed plan from plan mode is richer than the step list Cursor also sends.
            guard !hasProposedPlan else { return [] }
            return releaseReport() + plan(Self.checklist((update["entries"]?.array ?? []).compactMap(Self.todo)))
        case "usage_update":
            return Self.usage(update).map { [.usage($0)] } ?? []
        default:
            return []
        }
    }

    // MARK: Extension requests

    /// `cursor/update_todos`: the todo list, whole or (with `merge`) only the changed items.
    nonisolated mutating func handleTodos(_ params: JSONValue) -> [AgentEvent] {
        guard let list = params["todos"]?.array else { return [] }
        return releaseReport() + applyTodos(list, merge: params["merge"]?.bool ?? false)
    }

    /// `cursor/create_plan`: the plan the agent proposes in plan mode.
    nonisolated mutating func handleCreatePlan(_ params: JSONValue) -> [AgentEvent] {
        hasProposedPlan = true
        return releaseReport() + closeSegments() + plan(Self.proposedPlan(params))
    }

    /// `cursor/generate_image`, sent once an image tool finished: the image file becomes its output.
    nonisolated mutating func handleGeneratedImage(_ params: JSONValue) -> [AgentEvent] {
        guard let id = params["toolCallId"]?.string, let path = params["filePath"]?.string, !path.isEmpty,
            tools[id]?.info != nil, !hiddenTools.contains(id)
        else { return [] }
        return [.toolCompleted(id: id, status: .completed, output: relativePath(path))]
    }

    // MARK: Questions

    /// `cursor/ask_question`: `{toolCallId, title, questions: [{id, prompt, options: [{id, label}], allowMultiple}]}`.
    nonisolated mutating func questions(
        id: String, params: JSONValue
    ) -> (events: [AgentEvent], request: UserInputRequest, questions: [Question]) {
        let events = releaseReport() + closeSegments()
        let title = params["title"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let questions = (params["questions"]?.array ?? []).compactMap { Self.question($0, title: title) }
        let request = UserInputRequest(
            id: id, title: title.isEmpty ? nil : title,
            questions: questions.map { question in
                UserQuestion(
                    id: question.id, prompt: question.prompt,
                    options: question.options.map { UserQuestion.Option(label: $0.label) },
                    allowsMultipleSelection: question.allowsMultiple,
                    // Cursor's answer carries option ids only; typed text has to travel as the skip reason.
                    allowsFreeText: question.options.isEmpty)
            })
        return (events, request, questions)
    }

    nonisolated static func question(_ json: JSONValue, title: String = "") -> Question? {
        guard let id = json["id"]?.string, !id.isEmpty else { return nil }
        var seenIDs = Set<String>()
        var seenLabels = Set<String>()
        let options = (json["options"]?.array ?? []).compactMap { option -> Question.Option? in
            guard let optionID = option["id"]?.string, !optionID.isEmpty, seenIDs.insert(optionID).inserted else {
                return nil
            }
            var label = (option["label"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if label.isEmpty { label = optionID }
            if !seenLabels.insert(label).inserted {
                label = "\(label) (\(optionID))"
                seenLabels.insert(label)
            }
            return Question.Option(id: optionID, label: label)
        }
        var prompt = (json["prompt"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if prompt.isEmpty { prompt = title }
        guard !prompt.isEmpty || !options.isEmpty else { return nil }
        return Question(id: id, prompt: prompt, options: options, allowsMultiple: json["allowMultiple"]?.bool ?? false)
    }

    /// The `cursor/ask_question` result for the user's answers (question id to chosen labels or typed
    /// text). No answers at all means the user dismissed the questions.
    nonisolated static func questionReply(_ questions: [Question], answers: [String: [String]]) -> JSONValue {
        var selections: [JSONValue] = []
        var inWords: [String] = []
        var typedText = false
        for question in questions {
            let values = (answers[question.id] ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard !values.isEmpty else { continue }
            var ids: [String] = []
            for value in values {
                if let option = question.options.first(where: { $0.label == value })
                    ?? question.options.first(where: { $0.id == value })
                {
                    if !ids.contains(option.id) { ids.append(option.id) }
                } else {
                    typedText = true
                }
            }
            if !question.allowsMultiple { ids = Array(ids.prefix(1)) }
            if !ids.isEmpty {
                selections.append(["questionId": .string(question.id), "selectedOptionIds": .array(ids.map { .string($0) })])
            }
            inWords.append("\(question.prompt): \(values.joined(separator: ", "))")
        }
        if typedText {
            // Cursor's answer has no field for typed text, so it reaches the model as the reason the questions were skipped.
            let reason = "The user replied in their own words:\n" + inWords.joined(separator: "\n")
            return ["outcome": ["outcome": "skipped", "reason": .string(reason)]]
        }
        guard !selections.isEmpty else { return ["outcome": ["outcome": "skipped"]] }
        return ["outcome": ["outcome": "answered", "answers": .array(selections)]]
    }

    nonisolated static let cancelledQuestionReply: JSONValue = ["outcome": ["outcome": "cancelled"]]

    // MARK: Approvals

    /// Maps `session/request_permission`. Cursor also asks questions this way (one option per
    /// answer plus Skip) when `cursor/ask_question` fails.
    nonisolated mutating func approval(id: String, params: JSONValue) -> (events: [AgentEvent], request: ApprovalRequest) {
        let events = releaseReport() + closeSegments()
        let call = params["toolCall"] ?? .null
        var options = (params["options"]?.array ?? []).compactMap(Self.approvalOption)
        if !options.contains(where: { $0.kind == .deny || $0.kind == .cancel }) { options.append(Self.cancelOption) }
        let isQuestion = options.contains { $0.id == Self.skipQuestionOptionID }
        let toolCallID = call["toolCallId"]?.string
        let callTitle = call["title"]?.string ?? ""
        let notes = (call["content"]?.array ?? []).compactMap { block -> String? in
            switch block["type"]?.string {
            case "content":
                return Self.text(of: block["content"])
            case "diff":
                let (old, new) = Self.diffSides(old: block["oldText"]?.string, new: block["newText"]?.string ?? "")
                return Self.clipped(CursorDiff.unified(old: old, new: new, path: relativePath(block["path"]?.string ?? "")))
            default:
                return nil
            }
        }

        if !isQuestion, let toolCallID, let info = tools[toolCallID]?.info {
            let parts = (info.category == .command ? [info.detail] : []) + notes
            let request = ApprovalRequest(
                id: id, category: info.category, title: info.title, detail: Self.joined(parts.compactMap { $0 }),
                options: options, toolCallID: toolCallID)
            return (events, request)
        }
        let kind = call["kind"]?.string ?? "other"
        let category = isQuestion ? .other : Self.category(kind: kind, title: callTitle, input: [:])
        let title =
            isQuestion
            ? (callTitle.isEmpty ? String(localized: "Question") : callTitle)
            : permissionTitle(callTitle, category: category)
        let request = ApprovalRequest(
            id: id, category: category, title: title, detail: Self.joined(notes.filter { $0 != callTitle }),
            options: options, toolCallID: isQuestion ? nil : toolCallID)
        return (events, request)
    }

    /// Remembers that the user declined a tool call, so its completion reads as declined.
    nonisolated mutating func noteDeclined(toolCallID: String) {
        declinedTools.insert(toolCallID)
    }

    /// Cursor titles permissions for calls it has not shown as tools with absolute paths in backticks
    /// (`Edit \`/path\``, `Write /path` for a new file) and bare commands (`` `npm test` ``).
    private nonisolated func permissionTitle(_ title: String, category: ToolCategory) -> String {
        if title.isEmpty { return String(localized: "Permission request") }
        if category == .command, title.hasPrefix("`") { return String(localized: "Run \(title)") }
        guard let space = title.firstIndex(of: " ") else { return title }
        let verb = String(title[..<space])
        var path = String(title[title.index(after: space)...]).trimmingCharacters(in: .whitespaces)
        if path.count > 2, path.hasPrefix("`"), path.hasSuffix("`") { path = String(path.dropFirst().dropLast()) }
        guard path.hasPrefix("/") else { return title }
        let relative = relativePath(path)
        switch verb {
        case "Edit": return String(localized: "Edit \(relative)")
        case "Write": return String(localized: "Create \(relative)")
        case "Delete": return String(localized: "Delete \(relative)")
        case "Read": return String(localized: "Read \(relative)")
        default: return title
        }
    }

    // MARK: Text

    private nonisolated mutating func nextSegmentID() -> String {
        segmentCount += 1
        return "cursor-\(turn)-\(segmentCount)"
    }

    private nonisolated mutating func appendAssistant(_ text: String) -> AgentEvent {
        var segment = assistant ?? Segment(id: nextSegmentID())
        segment.text += text
        assistant = segment
        return .assistantTextDelta(itemID: segment.id, delta: text)
    }

    private nonisolated mutating func appendReasoning(_ text: String) -> AgentEvent {
        var segment = reasoning ?? Segment(id: nextSegmentID())
        segment.text += text
        reasoning = segment
        return .reasoningDelta(itemID: segment.id, delta: text)
    }

    private nonisolated mutating func closeAssistant() -> [AgentEvent] {
        guard let segment = assistant else { return [] }
        assistant = nil
        lastAssistantText = segment.text
        return [.assistantText(itemID: segment.id, text: segment.text)]
    }

    private nonisolated mutating func closeReasoning() -> [AgentEvent] {
        guard let segment = reasoning else { return [] }
        reasoning = nil
        return [.reasoningText(itemID: segment.id, text: segment.text)]
    }

    private nonisolated mutating func closeSegments() -> [AgentEvent] {
        closeReasoning() + closeAssistant()
    }

    /// More output followed a held error report, so it was the agent's own text after all.
    private nonisolated mutating func releaseReport() -> [AgentEvent] {
        guard let report = heldReport else { return [] }
        heldReport = nil
        return closeReasoning() + [appendAssistant(report)]
    }

    // MARK: Tools

    private nonisolated mutating func handleTool(_ update: JSONValue) -> [AgentEvent] {
        guard let id = update["toolCallId"]?.string else { return [] }
        var tool = tools[id] ?? Tool()
        if let kind = update["kind"]?.string { tool.kind = kind }
        if let title = update["title"]?.string, !title.isEmpty { tool.title = title }
        if let input = update["rawInput"]?.object { tool.input = input }
        for block in update["content"]?.array ?? [] {
            switch block["type"]?.string {
            case "diff":
                let (old, new) = Self.diffSides(old: block["oldText"]?.string, new: block["newText"]?.string ?? "")
                let isDeletion = tool.kind == "delete" && new.isEmpty
                let path = relativePath(block["path"]?.string ?? tool.input["path"]?.string ?? "")
                tool.diff = Self.clipped(CursorDiff.unified(old: old, new: isDeletion ? nil : new, path: path))
                tool.isNewFile = old == nil && !isDeletion
            case "content":
                if let text = Self.text(of: block["content"]) { tool.progress = text }
            default:
                break
            }
        }
        let status = update["status"]?.string
        let finished = status == "completed" || status == "failed"
        tools[id] = tool

        switch tool.input["_toolName"]?.string {
        case "updateTodos":
            hiddenTools.insert(id)
            // `cursor/update_todos` follows with the exact merge rule; this covers CLIs without it.
            guard finished, let list = tool.input["todos"]?.array else { return [] }
            return applyTodos(list, merge: true)
        case "createPlan":
            hiddenTools.insert(id)
            hasProposedPlan = true
            return plan(tool.input["plan"]?.string ?? "")
        case "askQuestion":
            // Shown as the question itself, which arrives as `cursor/ask_question`.
            hiddenTools.insert(id)
            return []
        default:
            guard !hiddenTools.contains(id), !tool.isFinished else { return [] }
        }

        let info = toolInfo(id: id, tool: tool)
        var events: [AgentEvent] = []
        if tool.info == nil {
            events.append(.toolStarted(info))
        } else if tool.info != info {
            events.append(.toolUpdated(info))
        }
        tools[id]?.info = info
        if finished {
            tools[id]?.isFinished = true
            let result = completion(id: id, tool: tool, category: info.category, status: status, output: update["rawOutput"])
            events.append(.toolCompleted(id: id, status: result.status, output: result.output))
        }
        return events
    }

    private nonisolated func toolInfo(id: String, tool: Tool) -> ToolCallInfo {
        let category = Self.category(kind: tool.kind, title: tool.title, input: tool.input)
        return ToolCallInfo(
            id: id, category: category, title: title(of: tool, category: category),
            detail: detail(of: tool, category: category).map { Self.clipped($0) })
    }

    private nonisolated func title(of tool: Tool, category: ToolCategory) -> String {
        let path = tool.input["path"]?.string.flatMap { $0.isEmpty ? nil : relativePath($0) }
        switch category {
        case .command:
            if let command = tool.input["command"]?.string, !command.isEmpty {
                return String(localized: "Run `\(Self.commandSummary(command))`")
            }
        case .fileChange:
            if let path {
                if tool.kind == "delete" { return String(localized: "Delete \(path)") }
                return tool.isNewFile ? String(localized: "Create \(path)") : String(localized: "Edit \(path)")
            }
        case .read:
            // Cursor's own read titles are already relative and include the line range.
            if let path, tool.title.isEmpty || tool.title == "Read File" { return String(localized: "Read \(path)") }
        default:
            break
        }
        return tool.title.isEmpty ? String(localized: "Tool call") : tool.title
    }

    private nonisolated func detail(of tool: Tool, category: ToolCategory) -> String? {
        let input = tool.input
        switch category {
        case .command: return input["command"]?.string ?? Self.json(input)
        case .fileChange: return tool.diff ?? input["path"]?.string
        case .read: return input["path"]?.string ?? Self.json(input)
        case .web: return input["url"]?.string ?? input["searchTerm"]?.string ?? Self.json(input)
        case .task: return input["prompt"]?.string ?? Self.json(input)
        case .mcp: return Self.json(input["args"]?.object ?? input)
        default: return Self.json(input)
        }
    }

    private nonisolated func completion(
        id: String, tool: Tool, category: ToolCategory, status: String?, output rawOutput: JSONValue?
    ) -> (status: ItemStatus, output: String?) {
        let output = rawOutput?.object ?? [:]
        if let error = output["error"]?.string, !error.isEmpty { return (.failed, Self.clipped(error)) }
        if output["rejected"]?.bool == true || output["permissionDenied"]?.bool == true || declinedTools.contains(id) {
            return (.declined, output["reason"]?.string)
        }
        if status == "failed" { return (.failed, tool.progress) }
        switch category {
        case .command:
            // Cursor reports a shell's result only when the command ran; a rejected, timed-out or
            // unstartable command ends without one.
            if tool.input["command"] != nil, output["exitCode"] == nil, output["stdout"] == nil, output["stderr"] == nil {
                return (.failed, nil)
            }
            var text = output["stdout"]?.string ?? ""
            if let stderr = output["stderr"]?.string, !stderr.isEmpty {
                text += (text.isEmpty || text.hasSuffix("\n") ? "" : "\n") + stderr
            }
            // The end of a long log usually says what happened.
            text = Self.clipped(tail: text)
            guard let code = output["exitCode"]?.int, code != 0 else { return (.completed, text) }
            text += (text.isEmpty || text.hasSuffix("\n") ? "" : "\n") + String(localized: "Exit code \(code)")
            return (.failed, text)
        case .read:
            return (.completed, output["content"]?.string.map { Self.clipped($0) })
        case .search, .web:
            return (.completed, Self.resultSummary(output))
        default:
            if let path = output["filePath"]?.string, !path.isEmpty { return (.completed, relativePath(path)) }
            return (.completed, tool.progress)
        }
    }

    nonisolated static func category(kind: String, title: String, input: [String: JSONValue]) -> ToolCategory {
        switch input["_toolName"]?.string {
        case "task": return .task
        case "updateTodos": return .todo
        default: break
        }
        if input["providerIdentifier"] != nil || input["server"] != nil { return .mcp }
        switch kind {
        case "execute": return .command
        case "edit", "delete", "move": return .fileChange
        case "read": return .read
        case "search": return input["searchTerm"] != nil || title.lowercased().hasPrefix("web search") ? .web : .search
        case "fetch": return .web
        default: return title.hasPrefix("Task:") ? .task : .other
        }
    }

    // MARK: Plans

    private nonisolated mutating func applyTodos(_ list: [JSONValue], merge: Bool) -> [AgentEvent] {
        let incoming = list.compactMap(Self.todo)
        if merge {
            for todo in incoming {
                if let index = todos.firstIndex(where: { $0.id == todo.id }) {
                    todos[index] = todo
                } else {
                    todos.append(todo)
                }
            }
        } else {
            todos = incoming
        }
        return plan(Self.checklist(todos))
    }

    private nonisolated mutating func plan(_ markdown: String) -> [AgentEvent] {
        let text = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text != lastPlan else { return [] }
        lastPlan = text
        return [.plan(text: text)]
    }

    nonisolated static func todo(_ json: JSONValue) -> Todo? {
        guard let content = json["content"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !content.isEmpty
        else { return nil }
        return Todo(id: json["id"]?.string ?? content, content: content, status: todoStatus(json["status"]?.string))
    }

    /// Accepts the plain (`in_progress`, `inProgress`) and tool-input (`TODO_STATUS_IN_PROGRESS`) spellings.
    nonisolated static func todoStatus(_ value: String?) -> TodoStatus {
        let normalized = (value ?? "").lowercased().replacingOccurrences(of: "todo_status_", with: "")
            .replacingOccurrences(of: "_", with: "")
        switch normalized {
        case "inprogress": return .inProgress
        case "completed", "done": return .completed
        case "cancelled", "canceled": return .cancelled
        default: return .pending
        }
    }

    nonisolated static func checklist(_ todos: [Todo]) -> String {
        todos.map { todo in
            switch todo.status {
            case .completed: "- [x] \(todo.content)"
            case .inProgress: "- [ ] \(todo.content) " + String(localized: "(in progress)")
            case .cancelled: "- [ ] ~~\(todo.content)~~"
            case .pending: "- [ ] \(todo.content)"
            }
        }.joined(separator: "\n")
    }

    /// The plan's own markdown, or one assembled from its name, overview and steps.
    nonisolated static func proposedPlan(_ params: JSONValue) -> String {
        if let plan = params["plan"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !plan.isEmpty {
            return plan
        }
        var parts: [String] = []
        if let name = params["name"]?.string, !name.isEmpty { parts.append("# \(name)") }
        if let overview = params["overview"]?.string, !overview.isEmpty { parts.append(overview) }
        let steps = checklist((params["todos"]?.array ?? []).compactMap(todo))
        if !steps.isEmpty { parts.append(steps) }
        return parts.joined(separator: "\n\n")
    }

    // MARK: Helpers

    private nonisolated func relativePath(_ path: String) -> String {
        for prefix in directoryPrefixes where path.hasPrefix(prefix) && path.count > prefix.count {
            return String(path.dropFirst(prefix.count))
        }
        return path
    }

    nonisolated static func text(of content: JSONValue?) -> String? {
        guard let content, content["type"]?.string ?? "text" == "text" else { return nil }
        return content["text"]?.string
    }

    /// When Cursor lacks a file's full contents it rebuilds before/after text from a unified diff
    /// and keeps the header lines, minus their first character (`-- /dev/null`, `++ b/path`).
    nonisolated static func diffSides(old: String?, new: String) -> (old: String?, new: String) {
        guard let old else { return (nil, new) }
        var oldLines = old.components(separatedBy: "\n")
        var newLines = new.components(separatedBy: "\n")
        guard let oldHeader = oldLines.first, oldHeader == "-- /dev/null" || oldHeader.hasPrefix("-- a/"),
            let newHeader = newLines.first, newHeader == "++ /dev/null" || newHeader.hasPrefix("++ b/")
        else { return (old, new) }
        oldLines.removeFirst()
        newLines.removeFirst()
        let before = oldLines.joined(separator: "\n")
        return (oldHeader == "-- /dev/null" && before.isEmpty ? nil : before, newLines.joined(separator: "\n"))
    }

    /// An option of a kind Coincide does not know could allow or reject, so it is left out rather than
    /// shown as an allow (as the ACP providers do).
    nonisolated static func approvalOption(_ json: JSONValue) -> ApprovalOption? {
        guard let id = json["optionId"]?.string else { return nil }
        let kind: ApprovalOption.Kind
        switch json["kind"]?.string {
        case "allow_once": kind = .allowOnce
        case "allow_always": kind = .allowAlways
        case "reject_once", "reject_always": kind = .deny
        default: return nil
        }
        return ApprovalOption(id: id, label: json["name"]?.string ?? id, kind: kind)
    }

    /// Answers the request as cancelled, offered when the agent gave no way to say no.
    nonisolated static let cancelOption = ApprovalOption(
        id: "coincide-cancel", label: String(localized: "Cancel"), kind: .cancel)

    nonisolated static func usage(_ update: JSONValue) -> TokenUsage? {
        let used = update["used"]?.int
        let size = update["size"]?.int
        guard used != nil || size != nil else { return nil }
        let cost = update["cost"]
        let dollars = cost?["currency"]?.string?.uppercased() == "USD" ? cost?["amount"]?.number : nil
        return TokenUsage(inputTokens: used, contextWindow: size, costUSD: dollars)
    }

    /// The `usage` field newer ACP agents add to the `session/prompt` result. Its input count adds up
    /// every request of the turn, so it says nothing about the context in use (`usage_update` does) and
    /// is left out, as the ACP providers do.
    nonisolated static func promptUsage(_ json: JSONValue?) -> TokenUsage? {
        guard let json, json.object != nil else { return nil }
        let usage = TokenUsage(outputTokens: json["outputTokens"]?.int, cachedInputTokens: json["cachedReadTokens"]?.int)
        return usage == TokenUsage() ? nil : usage
    }

    nonisolated static func resultSummary(_ output: [String: JSONValue]) -> String? {
        let summary: String
        if let count = output["totalMatches"]?.int {
            summary = count == 1 ? String(localized: "1 match") : String(localized: "\(count) matches")
        } else if let count = output["totalFiles"]?.int {
            summary = count == 1 ? String(localized: "1 file") : String(localized: "\(count) files")
        } else if let count = (output["resultCount"] ?? output["referenceCount"])?.int {
            summary = count == 1 ? String(localized: "1 result") : String(localized: "\(count) results")
        } else {
            return nil
        }
        return output["truncated"]?.bool == true ? String(localized: "\(summary) (truncated)") : summary
    }

    nonisolated static func commandSummary(_ command: String) -> String {
        let lines = command.split(whereSeparator: \.isNewline)
        var summary = (lines.first.map(String.init) ?? command).split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        if summary.count > 80 {
            summary = String(summary.prefix(79)) + "…"
        } else if lines.count > 1 {
            summary += " …"
        }
        return summary
    }

    /// Pretty JSON of a tool input without Cursor's private `_` keys, or nil when nothing is left.
    nonisolated static func json(_ input: [String: JSONValue]) -> String? {
        let visible = input.filter { !$0.key.hasPrefix("_") && !$0.value.isNull }
        return visible.isEmpty ? nil : JSONValue.object(visible).prettyJSON
    }

    /// The start of `text`, when it is longer than `limit` characters.
    nonisolated static func clipped(_ text: String, limit: Int = maxTextLength) -> String {
        guard text.utf8.count > limit else { return text }
        let kept = text.prefix(limit)
        guard kept.endIndex < text.endIndex else { return text }
        let omitted = text[kept.endIndex...].count
        return String(kept) + "\n" + String(localized: "… \(omitted) more characters not shown")
    }

    /// The end of `text`, when it is longer than `limit` characters.
    nonisolated static func clipped(tail text: String, limit: Int = maxTextLength) -> String {
        guard text.utf8.count > limit else { return text }
        let kept = text.suffix(limit)
        guard kept.startIndex > text.startIndex else { return text }
        let omitted = text[..<kept.startIndex].count
        return String(localized: "… \(omitted) earlier characters not shown") + "\n" + String(kept)
    }

    private nonisolated static func joined(_ parts: [String]) -> String? {
        let text = parts.filter { !$0.isEmpty }.joined(separator: "\n\n")
        return text.isEmpty ? nil : text
    }

    /// Cursor reports a failed turn as a last message chunk of its own, after a blank line:
    /// `Error: ConnectError: [unavailable] …`, `Error: RetriableError: …`, `Error: [unauthenticated] …`,
    /// or an account prompt such as "Upgrade your plan to continue". Returns the report without the blank line.
    nonisolated static func errorReport(in chunk: String) -> String? {
        guard chunk.hasPrefix("\n\n") else { return nil }
        let body = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let firstLine = body.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init)
        else { return nil }
        if accountPrompts.contains(firstLine) { return body }
        return firstLine.range(of: #"^Error: (?:[A-Za-z]*Error: |\[[a-z_]+\] )"#, options: .regularExpression) != nil
            ? body : nil
    }

    private nonisolated static let accountPrompts: Set<String> = [
        "Please sign in to continue", "Upgrade your plan to continue", "Add a payment method to continue",
        "Check your settings to continue", "Something went wrong communicating with the server. Please try again.",
    ]

    nonisolated static func transportFailure(in text: String) -> String? {
        var failure: String?
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            guard rawLine.count <= 4_096 else { return nil }
            let line = String(rawLine).replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
            if isTransportDiagnostic(line) {
                failure = line
            } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                continue
            } else if failure != nil, line.range(of: "^\\s+at\\s", options: .regularExpression) != nil {
                continue
            } else {
                return nil
            }
        }
        return failure
    }

    private nonisolated static func isTransportDiagnostic(_ line: String) -> Bool {
        let fixed = [
            "Something went wrong communicating with the server. Please try again.",
            // What Cursor's ACP server prints when its backend refuses the request.
            "Please sign in to continue", "Upgrade your plan to continue", "Add a payment method to continue",
        ]
        if fixed.contains(line) || line.hasPrefix("Error: [unauthenticated] Backend rejected authentication.") {
            return true
        }
        let retriable = "Error: RetriableError: "
        if line.hasPrefix(retriable) {
            let rest = line.dropFirst(retriable.count)
            return !rest.isEmpty && !rest.hasPrefix("[internal]")
        }
        return ["unavailable", "aborted", "deadline_exceeded"].contains { line.hasPrefix("Error: ConnectError: [\($0)]") }
    }
}
