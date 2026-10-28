import Foundation

/// One transcript item of a Muse session at one revision (MSP's `Item`), with the fields Coincide shows.
/// `item/delta` appends to `text`, `visibleOutput` or a reasoning summary part without a new revision.
struct MuseItem: Equatable {
    struct Child: Equatable {
        var id: String
        var attempt: Int
        var status: String
        var label: String?
        var terminal: String?
        var failureKind: String?
        var failureReason: String?
    }

    var id: String
    var kind: String
    var revision: Int
    var status: String
    var turnID: String?
    var text: String?
    var summary: [String]?
    var tool: String?
    var args: String?
    var visibleOutput: String?
    var failureReason: String?
    var fallbackText: String?
    var commandText: String?
    var exitCode: Int?
    var objective: String?
    var role: String?
    var controlStatus: String?
    var result: String?
    var outcome: String?
    var reason: String?
    var entryID: String?
    var finalSummary: String?
    var children: [Child]?

    /// Reads an item; nil without the id, kind, revision and status every item has (T3's `MuseItem` schema).
    init?(_ value: JSONValue?) {
        guard let value, let id = value["itemId"]?.string, !id.isEmpty, let kind = value["kind"]?.string, !kind.isEmpty,
            let revision = value["revision"]?.exactInt, revision > 0, let status = value["status"]?.string, !status.isEmpty
        else { return nil }
        self.id = id
        self.kind = kind
        self.revision = revision
        self.status = status
        turnID = value["turnId"]?.string
        text = value["text"]?.string
        summary = value["summary"]?.array?.map { $0.string ?? "" }
        tool = value["tool"]?.string
        args = value["args"]?.string
        visibleOutput = value["visibleOutput"]?.string
        failureReason = value["failureReason"]?.string
        fallbackText = value["fallbackText"]?.string
        commandText = value["commandText"]?.string
        exitCode = value["exitCode"]?.exactInt
        objective = value["objective"]?.string
        role = value["role"]?.string
        controlStatus = value["controlStatus"]?.string
        result = value.at("result.text")?.string ?? value.at("result.summary")?.string
        outcome = value["outcome"]?.string
        reason = value["reason"]?.string
        entryID = value["entryId"]?.string
        finalSummary = value["finalSummary"]?.string
        children = value["children"]?.array?.compactMap { child -> Child? in
            guard let id = child["childId"]?.string, !id.isEmpty, let status = child["status"]?.string else { return nil }
            return Child(
                id: id, attempt: child["attempt"]?.int ?? 1, status: status, label: child["label"]?.string,
                terminal: child["terminal"]?.string, failureKind: child["failureKind"]?.string,
                failureReason: child["failureReason"]?.string)
        }
    }

    var isRunning: Bool { status == "inProgress" }
}

/// Titles, details and outputs for Muse items, approvals and questions, following T3 Code's Muse
/// `itemPresentation.ts` and `protocol.ts`, in the words Coincide uses for other agents' tools.
struct MusePresentation {
    let paths: PathDisplay

    init(workingDirectory: String) {
        paths = PathDisplay(workingDirectory: workingDirectory)
    }

    /// Tool calls Muse shows another way: the todo list (`session/todoListChanged`), questions
    /// (`userInput/requested`) and workflows (their own `workflow` item). Shown only when they fail.
    static let toolsShownElsewhere: Set<String> = ["write_todos", "request_user_input", "workflow"]

    /// Items that are not work: the user's own message, and the reminder child Muse runs on every model step.
    static let hiddenKinds: Set<String> = ["userMessage", "reminderChild"]

    // MARK: Status

    /// T3's `museItemStatus`: anything that ended other than `completed` failed, and so did a compaction that did not
    /// compact. A subagent whose result is ready has done its work, though Muse keeps it open.
    static func status(_ item: MuseItem) -> ItemStatus {
        if item.kind == "subagent", item.isRunning, item.controlStatus == "resultReady" { return .completed }
        if item.isRunning { return .running }
        if item.status == "completed", !(item.kind == "compaction" && (item.outcome.map { $0 != "compacted" } ?? false)) {
            return .completed
        }
        return .failed
    }

    // MARK: Tools

    struct Tool: Equatable {
        var info: ToolCallInfo
        var status: ItemStatus
        var output: String?
    }

    /// How a tool-like item shows: its category and title, the input as detail, and its output. `childLabels` holds
    /// workflow agents' first labels (see `workflowChildren`).
    func tool(_ item: MuseItem, childLabels: [String: String] = [:]) -> Tool {
        let status = Self.status(item)
        // A failure leads with Muse's reason, as T3 puts it before the output.
        let failure = status == .failed ? (TerminalText.nonEmpty(item.failureReason) ?? Self.reportedStatus(item)) : nil
        let text = Self.outputText(item)
        func output(_ body: String?) -> String? {
            let parts = [failure, TerminalText.nonEmpty(body)].compactMap { $0 }
            return parts.isEmpty ? nil : CodexPresentation.tail(parts.joined(separator: "\n"))
        }
        switch item.kind {
        case "subagent":
            let objective = TerminalText.nonEmpty(item.objective)
            let title = (objective ?? TerminalText.nonEmpty(item.role)).map { String(localized: "Subagent: \(CodexPresentation.shortened($0))") }
                ?? String(localized: "Subagent")
            let info = ToolCallInfo(id: item.id, category: .task, title: title, detail: objective)
            return Tool(info: info, status: status, output: output(item.result))
        case "workflow":
            let name = TerminalText.nonEmpty(item.entryID) ?? TerminalText.nonEmpty(item.fallbackText)
            let title = name.map { String(localized: "Workflow: \($0)") } ?? String(localized: "Workflow")
            let info = ToolCallInfo(
                id: item.id, category: .task, title: title, detail: Self.workflowChildren(item, labels: childLabels))
            return Tool(info: info, status: status, output: output(item.finalSummary))
        case "compaction":
            let info = CodexEventMapper.compactionInfo(item.id)
            return Tool(info: info, status: status, output: status == .failed ? output(item.reason) : nil)
        case "userShell":
            return command(item, status: status, failure: failure)
        case "toolCall":
            return toolCall(item, status: status, output: output(text), failure: failure)
        default:
            // Kinds this version does not know: their name and Muse's one-line summary, as MSP asks clients to render them.
            let title = TerminalText.nonEmpty(item.fallbackText) ?? item.kind
            let category: ToolCategory = item.kind == "webSearch" ? .web : .other
            let info = ToolCallInfo(id: item.id, category: category, title: CodexPresentation.shortened(title))
            return Tool(info: info, status: status, output: output(text))
        }
    }

    private func toolCall(_ item: MuseItem, status: ItemStatus, output: String?, failure: String?) -> Tool {
        let args = item.args.flatMap { JSONValue.parse($0) }?.object
        func argument(_ keys: String...) -> String? {
            keys.lazy.compactMap { TerminalText.nonEmpty(args?[$0]?.string) }.first
        }
        let name = item.tool ?? item.kind
        let detail = args.map { JSONValue.object($0).prettyJSON } ?? TerminalText.nonEmpty(item.args)
        func make(_ category: ToolCategory, _ title: String, detail: String? = detail, output: String? = output) -> Tool {
            Tool(info: ToolCallInfo(id: item.id, category: category, title: title, detail: detail), status: status, output: output)
        }
        if name.range(of: "shell|bash|exec_command", options: [.regularExpression, .caseInsensitive]) != nil {
            return command(item, status: status, failure: failure)
        }
        if name.range(of: "write|edit|patch", options: [.regularExpression, .caseInsensitive]) != nil,
            let path = argument("file_path", "path", "filePath")
        {
            let file = paths.relative(path)
            let old = args?["old_string"]?.string ?? args?["old_str"]?.string ?? args?["oldStr"]?.string ?? args?["oldText"]?.string
            let new = args?["new_string"]?.string ?? args?["new_str"]?.string ?? args?["newStr"]?.string
                ?? args?["newText"]?.string ?? args?["content"]?.string
            let patch = args?["diff"]?.string ?? args?["patch"]?.string ?? args?["diffStr"]?.string
            let diff: String? =
                if let patch, !patch.isEmpty {
                    patch.hasPrefix("--- ") || patch.hasPrefix("diff ")
                        ? patch : "--- a/\(file)\n+++ b/\(file)\n" + (patch.hasSuffix("\n") ? patch : patch + "\n")
                } else if let new {
                    UnifiedDiff.make(path: file, old: old, new: new)
                } else {
                    nil
                }
            let title =
                old == nil && patch == nil && args?["content"] != nil
                ? String(localized: "Write \(file)") : String(localized: "Edit \(file)")
            return make(.fileChange, title, detail: diff.map { CodexPresentation.head($0) } ?? detail)
        }
        if name.range(of: "web|browse|fetch", options: [.regularExpression, .caseInsensitive]) != nil {
            let query = argument("query", "pattern")
            let url = argument("url")
            let title: String =
                if name == "web_search" || (url == nil && query != nil) {
                    query.map { String(localized: "Search the web for “\($0)”") } ?? String(localized: "Search the web")
                } else {
                    url.map { String(localized: "Fetch \($0)") } ?? String(localized: "Fetch a web page")
                }
            let results = name == "web_search" && failure == nil ? Self.webResults(item.visibleOutput) : nil
            return make(.web, title, output: results ?? output)
        }
        if name.hasPrefix("subagent_") {
            return make(.task, Self.subagentToolTitle(name))
        }
        if name.range(of: "^(read|view|cat)", options: [.regularExpression, .caseInsensitive]) != nil,
            let path = argument("file_path", "path", "filePath")
        {
            return make(.read, CodexPresentation.readTitle([paths.relative(path)]))
        }
        if name.range(of: "grep|glob|search|find", options: [.regularExpression, .caseInsensitive]) != nil {
            return make(.search, searchTitle(query: argument("pattern", "query", "regex"), path: argument("path", "directory")))
        }
        if name.range(of: "^(ls|list)", options: [.regularExpression, .caseInsensitive]) != nil {
            let title = argument("path", "directory").map { String(localized: "List \(paths.relative($0))") }
                ?? String(localized: "List files")
            return make(.search, title)
        }
        let category: ToolCategory = name.contains("__") || name.lowercased().hasPrefix("mcp") ? .mcp : .other
        return make(category, name)
    }

    /// "Search for “TODO” in Sources", as Coincide titles other agents' searches.
    private func searchTitle(query: String?, path: String?) -> String {
        guard let query else { return String(localized: "Search files") }
        guard let path, paths.relative(path) != "." else { return String(localized: "Search for “\(query)”") }
        return String(localized: "Search for “\(query)” in \(paths.relative(path))")
    }

    /// A shell command: Muse's `bash` tool reports a JSON envelope whose `output` and `exit_code` are what ran.
    private func command(_ item: MuseItem, status: ItemStatus, failure: String?) -> Tool {
        let args = item.args.flatMap { JSONValue.parse($0) }
        let command = TerminalText.nonEmpty(item.commandText) ?? args?["command"]?.string ?? args?["cmd"]?.string
            ?? item.args ?? ""
        let display = CodexPresentation.head(command)
        let envelope = item.visibleOutput.flatMap { JSONValue.parse($0) }
        let printed = envelope?["output"]?.string ?? (envelope?.object == nil ? item.visibleOutput : nil)
        let exitCode = item.exitCode ?? envelope?["exit_code"]?.exactInt
        var status = status
        if status == .completed, let exitCode, exitCode != 0 { status = .failed }
        let body = TerminalText.nonEmpty(CodexPresentation.commandOutput(printed ?? "", exitCode: exitCode))
        let output = [failure, body].compactMap { $0 }.joined(separator: "\n")
        let info = ToolCallInfo(id: item.id, category: .command, title: CodexPresentation.runTitle(display), detail: display)
        return Tool(info: info, status: status, output: output.isEmpty ? nil : output)
    }

    /// The item's own text, in T3's order of preference.
    static func outputText(_ item: MuseItem) -> String? {
        [item.visibleOutput, item.result, item.text, item.summary?.joined(separator: "\n"), item.finalSummary, item.fallbackText]
            .lazy.compactMap { TerminalText.nonEmpty($0) }.first
    }

    /// "Muse reported rejected." for an item that ended some other way than completing, with no reason of its own.
    static func reportedStatus(_ item: MuseItem) -> String {
        String(localized: "Muse reported \(item.status).")
    }

    /// `web_search` results, one per line with title and link; nil when the output is not Muse's result list.
    static func webResults(_ output: String?) -> String? {
        guard let results = output.flatMap({ JSONValue.parse($0) })?["results"]?.array else { return nil }
        let lines = results.compactMap { result -> String? in
            let title = TerminalText.nonEmpty(result["title"]?.string)
            let url = TerminalText.nonEmpty(result["url"]?.string)
            let snippet = TerminalText.nonEmpty(result["snippet"]?.string)
            switch (title, url) {
            case let (title?, url?): return "\(title) — \(url)"
            case let (title?, nil): return title
            case let (nil, url?): return url
            case (nil, nil): return snippet
            }
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    static func subagentToolTitle(_ tool: String) -> String {
        switch tool {
        case "subagent_spawn": String(localized: "Start a subagent")
        case "subagent_wait": String(localized: "Wait for subagents")
        case "subagent_send_message", "subagent_followup_task": String(localized: "Message a subagent")
        case "subagent_resume", "subagent_reopen": String(localized: "Resume a subagent")
        case "subagent_interrupt": String(localized: "Interrupt a subagent")
        case "subagent_close", "subagent_stop": String(localized: "Close a subagent")
        case "subagent_list": String(localized: "List subagents")
        default: String(localized: "Subagent")
        }
    }

    /// A workflow's agents, one line each: ✓ done, ✗ failed (with why), • still running or waiting. Muse re-sends the
    /// whole list on every change; an agent keeps the first label it was given, which later revisions may drop.
    static func workflowChildren(_ item: MuseItem, labels: [String: String] = [:]) -> String? {
        guard let children = item.children, !children.isEmpty else { return nil }
        let lines = children.enumerated().map { index, child -> String in
            let label = labels["\(child.id)#\(child.attempt)"] ?? TerminalText.nonEmpty(child.label)
                ?? String(localized: "Agent \(index + 1)")
            switch childStatus(child, workflowRunning: item.isRunning) {
            case .completed: return "✓ \(label)"
            case .failed:
                let why = TerminalText.nonEmpty(child.failureReason) ?? TerminalText.nonEmpty(child.failureKind)
                return why.map { "✗ \(label): \($0)" } ?? "✗ \(label)"
            default: return "• \(label)"
            }
        }
        return lines.joined(separator: "\n")
    }

    /// T3's workflow child status: a `failureKind` fails an attempt even when its terminal reads `completed`, and
    /// children of a settled workflow settle with it.
    static func childStatus(_ child: MuseItem.Child, workflowRunning: Bool) -> ItemStatus {
        switch child.terminal {
        case "completed": return child.failureKind == nil ? .completed : .failed
        case .some: return .failed
        case nil: return workflowRunning ? (child.status == "scheduled" ? .waiting : .running) : .completed
        }
    }

    // MARK: Plans

    /// `session/todoListChanged` as a markdown checklist; empty and cancelled steps are left out, as in T3.
    static func todoMarkdown(_ params: JSONValue) -> String? {
        let lines = (params["items"]?.array ?? []).compactMap { entry -> String? in
            guard let text = TerminalText.nonEmpty(entry["text"]?.string), entry["status"]?.string != "cancelled"
            else { return nil }
            switch entry["status"]?.string {
            case "completed": return "- [x] \(text)"
            case "inProgress": return "- [ ] \(text) _(\(String(localized: "in progress")))_"
            default: return "- [ ] \(text)"
            }
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}

// MARK: - Approvals

/// A permission request (`approval/requested`, `approval/updated`): a shell command, file access, a network host or
/// another target, with the choices Muse offers for its current requirement.
struct MuseApproval: Equatable {
    struct Choice: Equatable {
        var id: String
        var label: String
        var decision: String
        var scope: String
    }

    var id: String
    var sessionID: String
    var turnID: String?
    var toolName: String?
    var rawArgs: String?
    /// Set when a workflow child asks; its `turnId` is then the child's run, not a session turn.
    var subagentID: String?
    /// The requirement being decided; shell commands with several stages ask once per stage.
    var requirement: JSONValue
    var choices: [Choice]
    var subjectKind: String
    var access: String?
    var command: String?
    var path: String?
    var host: String?
    var target: String?

    init?(_ params: JSONValue) {
        guard let id = params["approvalId"]?.string, !id.isEmpty, let sessionID = params["sessionId"]?.string,
            let requirement = params["currentRequirementId"], requirement["approvalId"]?.string != nil,
            let choices = params["availableChoices"]?.array, let subject = params["subject"], subject.object != nil
        else { return nil }
        self.id = id
        self.sessionID = sessionID
        turnID = params["turnId"]?.string
        toolName = params["toolName"]?.string
        rawArgs = params["rawArgs"]?.string
        subagentID = params.at("subagentOrigin.subagentId")?.string
        self.requirement = requirement
        self.choices = choices.compactMap { choice in
            guard let id = choice["choiceId"]?.string, !id.isEmpty, let decision = choice["decision"]?.string else { return nil }
            return Choice(
                id: id, label: choice["label"]?.string ?? "", decision: decision, scope: choice["scope"]?.string ?? "once")
        }
        subjectKind = subject["kind"]?.string ?? ""
        access = subject["access"]?.string
        command = subject["command"]?.string
        path = subject["path"]?.string
        host = subject["host"]?.string
        target = subject["target"]?.string
    }

    enum Decision: Hashable {
        case accept
        case acceptForSession
        case acceptAlways
        case decline
        case cancel
    }

    /// T3's `museApprovalDecision`.
    static func decision(_ choice: Choice) -> Decision? {
        switch choice.decision {
        case "approved": .accept
        case "approvedForSession": .acceptForSession
        case "approvedPolicyAmendment": choice.scope == "session" ? .acceptForSession : choice.scope == "localPersistent" ? .acceptAlways : nil
        case "denied", "deniedPolicyAmendment": .decline
        case "abort": .cancel
        default: nil
        }
    }

    /// The choice for each decision, preferring the narrowest scope (T3's `museApprovalChoices`). Shell approvals offer
    /// abort instead of denied, so declining falls back to abort.
    var choicesByDecision: [Decision: Choice] {
        func rank(_ choice: Choice) -> Int {
            (choice.scope == "once" ? 0 : choice.scope == "session" ? 2 : 4) + (choice.decision.hasSuffix("PolicyAmendment") ? 1 : 0)
        }
        var chosen: [Decision: Choice] = [:]
        for choice in choices {
            guard let decision = Self.decision(choice) else { continue }
            if let previous = chosen[decision], rank(previous) <= rank(choice) { continue }
            chosen[decision] = choice
        }
        if chosen[.decline] == nil, let abort = chosen[.cancel] { chosen[.decline] = abort }
        return chosen
    }

    /// The buttons, in the order Muse lists the choices (T3's `museApprovalOptions`); abort shows once even when it
    /// also stands in for declining.
    var options: [ApprovalOption] {
        let chosen = choicesByDecision
        var options: [ApprovalOption] = []
        for choice in choices where !options.contains(where: { $0.id == choice.id }) {
            let decisions = chosen.filter { $0.value == choice }.map { $0.key }
            guard !decisions.isEmpty else { continue }
            let kind: ApprovalOption.Kind =
                decisions.contains(.decline) ? .deny
                : decisions.contains(.cancel) ? .cancel
                : decisions.contains(.accept) ? .allowOnce : .allowAlways
            options.append(ApprovalOption(id: choice.id, label: Self.label(choice, kind: kind), kind: kind))
        }
        return options
    }

    private static func label(_ choice: Choice, kind: ApprovalOption.Kind) -> String {
        if let label = TerminalText.nonEmpty(choice.label) { return label }
        return switch kind {
        case .allowOnce: String(localized: "Allow")
        case .allowAlways: String(localized: "Always allow")
        case .deny, .cancel: String(localized: "Deny")
        }
    }

    /// The prompt: what Muse wants to run, read, write or reach.
    func request(id requestID: String, presentation: MusePresentation) -> ApprovalRequest {
        let category: ToolCategory
        var title: String
        var detail: String?
        if subjectKind == "shell", let command = TerminalText.nonEmpty(command) {
            category = .command
            title = CodexPresentation.runTitle(command)
            detail = CodexPresentation.head(command)
        } else if subjectKind == "fileAccess", let path = TerminalText.nonEmpty(path) {
            let file = presentation.paths.relative(path)
            category = access == "read" ? .read : .fileChange
            title = access == "read" ? CodexPresentation.readTitle([file]) : String(localized: "Edit \(file)")
            detail = path
        } else {
            category = host != nil ? .web : .other
            let subject = [command, path, host, target, toolName].lazy.compactMap { TerminalText.nonEmpty($0) }.first
            title = subject.map { CodexPresentation.shortened($0) } ?? String(localized: "\(ProviderKind.muse.displayName) asks for permission")
            detail = subject
        }
        if detail == nil || category == .other, let rawArgs = TerminalText.nonEmpty(rawArgs) {
            detail = JSONValue.parse(rawArgs)?.prettyJSON ?? rawArgs
        }
        if subagentID != nil { title = String(localized: "Subagent: \(title)") }
        return ApprovalRequest(
            id: requestID, category: category, title: title, detail: detail, options: options, toolCallID: nil)
    }
}

// MARK: - Questions

/// Questions Muse's `request_user_input` asks (`userInput/requested`), and the answer `userInput/answer` takes.
struct MuseUserInput: Equatable {
    struct Question: Equatable {
        var id: String
        var header: String
        var prompt: String
        var options: [(label: String, detail: String?)]
        var multiple: Bool
        var maxSelections: Int?

        static func == (lhs: Question, rhs: Question) -> Bool {
            lhs.id == rhs.id && lhs.header == rhs.header && lhs.prompt == rhs.prompt && lhs.multiple == rhs.multiple
                && lhs.maxSelections == rhs.maxSelections && lhs.options.map(\.label) == rhs.options.map(\.label)
                && lhs.options.map(\.detail) == rhs.options.map(\.detail)
        }
    }

    var id: String
    var sessionID: String
    var turnID: String?
    var questions: [Question]

    /// Muse takes at most this much typed text per answer (and per note).
    static let freeTextLimit = 500

    init?(_ params: JSONValue) {
        guard let id = params["userInputId"]?.string, !id.isEmpty, let sessionID = params["sessionId"]?.string,
            let questions = params["questions"]?.array
        else { return nil }
        self.id = id
        self.sessionID = sessionID
        turnID = params["turnId"]?.string
        self.questions = questions.compactMap { question in
            guard let id = question["id"]?.string, !id.isEmpty else { return nil }
            return Question(
                id: id, header: question["header"]?.string ?? "", prompt: question["question"]?.string ?? "",
                options: (question["options"]?.array ?? []).compactMap { option in
                    option["label"]?.string.map { ($0, TerminalText.nonEmpty(option["description"]?.string)) }
                },
                multiple: question.at("selection.mode")?.string == "multiple",
                maxSelections: question.at("selection.maxSelections")?.int)
        }
    }

    var request: UserInputRequest {
        UserInputRequest(
            id: id,
            questions: questions.map { question in
                UserQuestion(
                    id: question.id, header: TerminalText.nonEmpty(question.header), prompt: question.prompt,
                    options: question.options.map { UserQuestion.Option(label: $0.label, detail: $0.detail) },
                    allowsMultipleSelection: question.multiple, allowsFreeText: true)
            })
    }

    /// `userInput/answer`'s answers: chosen option labels, typed text as `freeText`, or as a `note` next to chosen
    /// labels (T3's mapping). Nil when a question has no answer, which Muse would refuse.
    func answers(_ replies: [String: [String]]) -> JSONValue? {
        var answers: [JSONValue] = []
        for question in questions {
            let values = (replies[question.id] ?? []).reduce(into: [String]()) { unique, value in
                if !unique.contains(value) { unique.append(value) }
            }
            var selected = values.filter { value in question.options.contains { $0.label == value } }
            if !question.multiple { selected = Array(selected.prefix(1)) }
            if let limit = question.maxSelections, limit > 0 { selected = Array(selected.prefix(limit)) }
            let typed = values.filter { value in !question.options.contains { $0.label == value } }
                .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            let text = String(typed.prefix(Self.freeTextLimit))
            guard !selected.isEmpty || !text.isEmpty else { return nil }
            var answer: [String: JSONValue] = ["questionId": .string(question.id)]
            if !selected.isEmpty {
                if question.multiple {
                    answer["selectedLabels"] = .array(selected.map { .string($0) })
                } else {
                    answer["selectedLabel"] = .string(selected[0])
                }
            }
            if !text.isEmpty { answer[selected.isEmpty ? "freeText" : "note"] = .string(text) }
            answers.append(.object(answer))
        }
        return .array(answers)
    }
}
