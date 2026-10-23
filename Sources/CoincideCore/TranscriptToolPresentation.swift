import Foundation

public enum TranscriptToolKind: String, Sendable, CaseIterable {
    case command, read, edit, search, webSearch, fetch, task, todo, plan, mcp, compaction, other
}

/// Only states the transcript actually proves. Codex command text carries no
/// exit status, and an unfinished entity after its run ended is `unknown`.
public enum TranscriptToolStatus: String, Sendable { case running, completed, failed, cancelled, unknown }

public struct TranscriptTodo: Sendable, Equatable {
    public var text: String
    public var status: String
    public init(text: String, status: String) { self.text = text; self.status = status }
    public var isCompleted: Bool { status == "completed" }
    public var isActive: Bool { status == "in_progress" || status == "inProgress" }
}

public struct TranscriptToolCard: Sendable, Equatable {
    public var kind: TranscriptToolKind
    public var name: String
    public var title: String
    public var subject: String?
    public var detail: String?
    public var status: TranscriptToolStatus
    public var input: String?
    public var output: String?
    public var exitCode: Int?
    public var cwd: String?
    public var changes: [TranscriptFileChange] = []
    public var paths: [String] = []
    public var todos: [TranscriptTodo] = []
    public var plan: String?
    public init(kind: TranscriptToolKind, name: String, title: String = "", subject: String? = nil, status: TranscriptToolStatus = .unknown) {
        self.kind = kind; self.name = name; self.title = title; self.subject = subject; self.status = status
    }
    public var isFailure: Bool { status == .failed || (exitCode.map { $0 != 0 } ?? false) }
    public var stat: TranscriptDiffStat? { changes.isEmpty || changes.contains(where: { !$0.countsComplete }) ? nil : .init(changes) }
}

/// Facts the transcript row knows about its run when a card is derived.
public struct TranscriptToolContext: Sendable, Hashable {
    public var provider: ProviderKind?
    /// The owning run is still running or waiting for input.
    public var runActive: Bool
    /// The row is the newest row of the active run.
    public var trailing: Bool
    public var workspacePath: String?
    public init(provider: ProviderKind? = nil, runActive: Bool = false, trailing: Bool = false, workspacePath: String? = nil) {
        self.provider = provider; self.runActive = runActive; self.trailing = trailing; self.workspacePath = workspacePath
    }
}

/// Derives per-tool cards from the transcript rows providers already produce:
/// Codex `$ command` and `File changes` text, Claude `Name\n{input}` calls with
/// `result-<id>` rows, and ACP/OpenCode/Pi/Muse/Antigravity `tool_call` entities.
public enum TranscriptToolPresentation {
    public static func card(for message: ChatMessage, result: ChatMessage? = nil, context: TranscriptToolContext = .init()) -> TranscriptToolCard {
        var card: TranscriptToolCard
        if let entity = message.providerEntity { card = entityCard(entity, context: context) }
        else if message.text.hasPrefix("$ ") { card = codexCommand(message.text, context: context) }
        else if message.text == "File changes" || message.text.hasPrefix("File changes\n") { card = codexFileChange(message.text) }
        else if message.id.hasPrefix("acp-"), message.id.hasSuffix("-plan") {
            card = .init(kind: .todo, name: "plan", title: "Updated plan", status: .completed); card.todos = checklist(message.text)
        } else if message.id.hasPrefix("result-") && result == nil {
            card = .init(kind: .other, name: "result", title: String(localized: "Tool result"), status: .completed); card.output = message.text
        } else if context.provider == .claude || claudeShaped(message.text) { card = claudeCard(message.text, result: result, context: context) }
        else {
            let (head, rest) = split(message.text)
            card = .init(kind: .other, name: head, title: head.isEmpty ? String(localized: "Tool activity") : head, status: context.trailing ? .running : .unknown)
            card.output = rest.isEmpty ? nil : rest
        }
        if card.title.isEmpty { card.title = title(card, workspacePath: context.workspacePath) }
        return card
    }

    // MARK: Codex text forms

    static func codexCommand(_ text: String, context: TranscriptToolContext) -> TranscriptToolCard {
        let (head, rest) = split(text)
        let command = String(head.dropFirst(2))
        var card = TranscriptToolCard(kind: .command, name: "commandExecution", subject: command, status: context.trailing ? .running : .unknown)
        card.output = rest.isEmpty ? nil : rest
        return card
    }

    static func codexFileChange(_ text: String) -> TranscriptToolCard {
        var card = TranscriptToolCard(kind: .edit, name: "fileChange", status: .completed)
        let (_, rest) = split(text)
        if let value = decode(rest) { card.changes = TranscriptPatch.codexChanges(value) }
        if card.changes.isEmpty || card.changes.contains(where: { !$0.countsComplete }) { card.output = rest.isEmpty ? nil : rest }
        card.paths = card.changes.map(\.path)
        return card
    }

    // MARK: Claude tool_use / tool_result

    static func claudeShaped(_ text: String) -> Bool {
        let (head, rest) = split(text)
        guard !head.isEmpty, head.utf8.count <= 256, head.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) else { return false }
        return rest.isEmpty || rest.hasPrefix("{")
    }

    static func claudeCard(_ text: String, result: ChatMessage?, context: TranscriptToolContext) -> TranscriptToolCard {
        let (name, rest) = split(text)
        let input = decode(rest) ?? .null
        var card = TranscriptToolCard(kind: .other, name: name)
        card.input = rest.isEmpty ? nil : rest
        func string(_ keys: String...) -> String? { keys.lazy.compactMap { input[$0].string }.first { !$0.isEmpty } }
        switch name {
        case "Bash", "BashOutput", "KillShell", "KillBash":
            card.kind = name == "Bash" ? .command : .other
            card.subject = name == "Bash" ? string("command") : nil
            card.detail = string("description")
            if name != "Bash" { card.title = name == "BashOutput" ? String(localized: "Read background output") : String(localized: "Stopped background command") }
        case "Read": card.kind = .read; card.subject = string("file_path", "path")
        case "Edit":
            card.kind = .edit; card.subject = string("file_path")
            if let path = card.subject { card.changes = [TranscriptLineDiff.change(path: path, old: input["old_string"].string ?? "", new: input["new_string"].string ?? "")] }
        case "MultiEdit":
            card.kind = .edit; card.subject = string("file_path")
            if let path = card.subject, let edits = input["edits"].array {
                var combined = TranscriptFileChange(path: path)
                for edit in edits.prefix(256) {
                    let change = TranscriptLineDiff.change(path: path, old: edit["old_string"].string ?? "", new: edit["new_string"].string ?? "")
                    guard combined.lineCount + change.lineCount <= TranscriptPatch.maximumLines else {
                        combined.isTruncated = true; combined.countsComplete = false; break
                    }
                    combined.hunks += change.hunks; combined.additions += change.additions; combined.deletions += change.deletions
                    combined.isTruncated = combined.isTruncated || change.isTruncated
                    combined.countsComplete = combined.countsComplete && change.countsComplete
                }
                card.changes = [combined]
            }
        case "Write":
            card.kind = .edit; card.subject = string("file_path")
            if let path = card.subject { card.changes = [TranscriptLineDiff.change(path: path, old: nil, new: input["content"].string ?? "", kind: .modified, numbered: true)] }
            card.title = card.subject.map { String(localized: "Wrote \(relative($0, to: context.workspacePath))") } ?? ""
        case "NotebookEdit":
            card.kind = .edit; card.subject = string("notebook_path")
            if let path = card.subject { card.changes = [TranscriptLineDiff.change(path: path, old: nil, new: input["new_source"].string ?? "", kind: .modified)] }
        case "Grep", "Glob", "LS":
            card.kind = .search; card.subject = name == "LS" ? string("path") : string("pattern")
            card.detail = name == "LS" ? nil : string("path", "glob")
            if name == "LS" { card.title = card.subject.map { String(localized: "Listed \(relative($0, to: context.workspacePath))") } ?? String(localized: "Listed files") }
        case "WebFetch": card.kind = .fetch; card.subject = string("url")
        case "WebSearch": card.kind = .webSearch; card.subject = string("query")
        case "Task", "Agent": card.kind = .task; card.subject = string("description", "prompt"); card.detail = string("subagent_type")
        case "TodoWrite": card.kind = .todo; card.todos = todos(input["todos"])
        case "ExitPlanMode": card.kind = .plan; card.plan = string("plan")
        default:
            if name.hasPrefix("mcp__") {
                card.kind = .mcp
                let parts = name.dropFirst(5).components(separatedBy: "__")
                card.subject = parts.count >= 2 ? parts[0] + " · " + parts.dropFirst().joined(separator: "__") : String(name.dropFirst(5))
            } else { card.kind = inferredKind(name: name, input: input) ?? .other; card.subject = subject(for: card.kind, input: input) }
        }
        card.paths = card.changes.map(\.path) + (card.kind == .read ? card.subject.map { [$0] } ?? [] : [])
        if let result {
            var output = result.text
            if let range = output.range(of: "<tool_use_error>") {
                card.status = .failed
                output = output.replacingCharacters(in: range, with: "").replacingOccurrences(of: "</tool_use_error>", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } else { card.status = .completed }
            card.output = output.isEmpty ? nil : output
        } else if card.kind == .plan || card.kind == .todo {
            card.status = .completed
        } else { card.status = context.runActive ? .running : .unknown }
        return card
    }

    // MARK: Provider entities

    static func entityCard(_ entity: ProviderEntity, context: TranscriptToolContext) -> TranscriptToolCard {
        let fields = entity.fields
        switch entity.key.type {
        case "plan":
            if let entries = fields["entries"].array {
                var card = TranscriptToolCard(kind: .todo, name: "plan", title: String(localized: "Updated plan"), status: .completed)
                card.todos = entries.prefix(512).map { .init(text: $0["content"].string ?? "", status: $0["status"].string ?? "pending") }
                return card
            }
            var card = TranscriptToolCard(kind: .plan, name: "plan", title: String(localized: "Proposed plan"), status: .completed)
            card.plan = fields["content"].string ?? contentText(fields["content"].array ?? [])
            return card
        case "terminal":
            var card = TranscriptToolCard(kind: .command, name: "terminal", subject: fields["command"].string, status: context.runActive ? .running : .unknown)
            let data = Data(base64Encoded: fields["output"]["data"].string ?? "") ?? Data()
            let output = String(decoding: data, as: UTF8.self)
            card.output = output.isEmpty ? nil : output
            if let code = number(fields["exitStatus"]["exitCode"]) ?? number(fields["exitCode"]) { card.exitCode = code; card.status = code == 0 ? .completed : .failed }
            return card
        case "compaction":
            var card = TranscriptToolCard(kind: .compaction, name: "compaction", title: String(localized: "Compacted context"))
            card.status = status(fields["status"].string, context: context)
            let summary = contentText(fields["summary"].array ?? [])
            card.output = summary.isEmpty ? nil : summary
            return card
        default: break
        }
        let title = fields["title"].string ?? String(localized: "Tool")
        let input = fields["rawInput"], meta = fields["_meta"]
        var card = TranscriptToolCard(kind: .other, name: meta["museKind"].string ?? title)
        if context.provider == .codex { card.kind = .mcp }
        else if let kind = acpKind(fields["kind"].string) { card.kind = kind }
        else if fields["command"].string != nil { card.kind = .command }
        else if let kind = inferredKind(name: meta["museKind"].string ?? meta["antigravityToolKind"].string ?? title, input: input) { card.kind = kind }
        card.status = status(fields["status"].string, context: context)
        if input != .null { card.input = input.string ?? input.pretty }
        var outputs: [String] = []
        for item in (fields["content"].array ?? []).prefix(1_024) {
            switch item["type"].string {
            case "content": outputs.append(contentText([item["content"]]))
            case "diff":
                if let path = item["path"].string {
                    card.changes.append(TranscriptLineDiff.change(path: path, old: item["oldText"].string, new: item["newText"].string ?? ""))
                } else if let patch = item["patch"]["text"].string ?? item["patch"].string {
                    if let parsed = TranscriptPatch.parse(patch, fallbackPath: item["patch"]["path"].string) { card.changes += parsed } else { outputs.append(patch) }
                }
            case "terminal": outputs.append(String(localized: "Terminal: \(item["terminalId"].string ?? "")"))
            default: outputs.append(item.pretty)
            }
        }
        let raw = fields["rawOutput"]
        if let text = raw.string { outputs.append(text) }
        else if raw != .null {
            if let text = ["output", "stdout", "formatted_output", "aggregated_output", "combinedOutput", "combined_output", "result"].lazy.compactMap({ raw[$0].string }).first {
                outputs.append(text)
            } else if outputs.isEmpty { outputs.append(raw.pretty) }
            card.exitCode = number(raw["exitCode"]) ?? number(raw["exit_code"])
        }
        if let code = number(fields["exitCode"]) { card.exitCode = code }
        let output = outputs.filter { !$0.isEmpty }.joined(separator: "\n")
        card.output = output.isEmpty ? nil : output
        card.cwd = fields["cwd"].string
        let locations = (fields["locations"].array ?? []).compactMap { $0["path"].string }
        card.paths = Array((card.changes.map(\.path) + locations).prefix(256))
        if card.kind == .command { card.subject = fields["command"].string ?? subject(for: .command, input: input) }
        else if card.kind == .mcp { card.subject = title }
        else { card.subject = subject(for: card.kind, input: input) ?? locations.first }
        card.todos = todos(input["todos"])
        // Agent-written titles ("Run the test suite") beat a generic label;
        // bare tool names ("bash") get the synthesized one.
        let bareName = !title.contains(" ") && title == title.lowercased()
        if card.kind == .other || (card.subject == nil && card.changes.isEmpty && !bareName) { card.title = title }
        return card
    }

    static func status(_ value: String?, context: TranscriptToolContext) -> TranscriptToolStatus {
        switch value {
        case "completed", "success": .completed
        case "failed", "error": .failed
        case "cancelled", "canceled", "interrupted", "declined": .cancelled
        case "pending", "in_progress", "inProgress", "running": context.runActive ? .running : .unknown
        default: context.trailing ? .running : .unknown
        }
    }

    static func acpKind(_ value: String?) -> TranscriptToolKind? {
        switch value {
        case "execute": .command
        case "read": .read
        case "edit", "delete", "move": .edit
        case "search": .search
        case "fetch": .fetch
        default: nil
        }
    }

    /// Tool names shared by most agents, then the input shape.
    static func inferredKind(name: String, input: JSONValue) -> TranscriptToolKind? {
        let normalized = name.lowercased().split(whereSeparator: { $0 == " " || $0 == ":" }).first.map(String.init) ?? ""
        switch normalized {
        case "bash", "shell", "exec", "execute", "command", "run_command", "run_terminal_cmd", "local_shell", "terminal", "commandexecution": return .command
        case "read", "read_file", "readfile", "view", "cat", "open": return .read
        case "edit", "multiedit", "write", "write_file", "edit_file", "apply_patch", "patch", "str_replace", "str_replace_editor", "create", "filechange", "notebookedit": return .edit
        case "grep", "glob", "find", "ls", "list", "list_dir", "search", "codebase_search", "file_search", "rg": return .search
        case "websearch", "web_search": return .webSearch
        case "webfetch", "web_fetch", "fetch": return .fetch
        case "task", "agent", "subagent", "spawn_agent": return .task
        case "todowrite", "todo_write", "todoread", "update_plan", "todo": return .todo
        case "mcp", "mcptoolcall": return .mcp
        default: break
        }
        if normalized.contains("shell") || normalized.contains("command") { return .command }
        if normalized.contains("websearch") { return .webSearch }
        if normalized.contains("subagent") { return .task }
        guard input.object != nil else { return nil }
        if input["command"] != .null || input["cmd"] != .null { return .command }
        if input["todos"].array != nil { return .todo }
        if input["oldString"] != .null || input["old_string"] != .null || input["newString"] != .null || input["patch"] != .null { return .edit }
        if input["url"].string != nil { return .fetch }
        if input["pattern"].string != nil { return .search }
        if input["query"].string != nil { return .webSearch }
        if input["content"].string != nil, path(input) != nil { return .edit }
        if path(input) != nil { return .read }
        return nil
    }

    static func subject(for kind: TranscriptToolKind, input: JSONValue) -> String? {
        switch kind {
        case .command:
            if let command = input["command"].string ?? input["cmd"].string { return command }
            if let parts = (input["command"].array ?? input["cmd"].array)?.compactMap(\.string), !parts.isEmpty { return parts.joined(separator: " ") }
            return nil
        case .read, .edit: return path(input)
        case .search: return input["pattern"].string ?? input["query"].string ?? path(input)
        case .webSearch: return input["query"].string
        case .fetch: return input["url"].string
        case .task: return input["description"].string ?? input["prompt"].string
        default: return nil
        }
    }

    static func path(_ input: JSONValue) -> String? {
        ["file_path", "filePath", "path", "notebook_path", "file", "filename", "target_file"].lazy.compactMap { input[$0].string }.first { !$0.isEmpty }
    }

    // MARK: Titles and group summaries

    public static func title(_ card: TranscriptToolCard, workspacePath: String?) -> String {
        let subject = card.subject.map { relative($0, to: workspacePath) }
        switch card.kind {
        case .command: return card.subject.map(singleLine) ?? String(localized: "Ran command")
        case .read: return subject.map { String(localized: "Read \($0)") } ?? String(localized: "Read file")
        case .edit:
            if let first = card.changes.first {
                let path = relative(first.path, to: workspacePath)
                if card.changes.count > 1 { return String(localized: "Edited \(path) +\(card.changes.count - 1) more") }
                switch first.kind {
                case .added: return String(localized: "Created \(path)")
                case .deleted: return String(localized: "Deleted \(path)")
                case .renamed: return String(localized: "Renamed \(relative(first.previousPath ?? path, to: workspacePath)) to \(path)")
                case .modified: return String(localized: "Edited \(path)")
                }
            }
            return subject.map { String(localized: "Edited \($0)") } ?? String(localized: "Edited files")
        case .search: return subject.map { String(localized: "Searched for \(singleLine($0))") } ?? String(localized: "Searched code")
        case .webSearch: return subject.map { String(localized: "Searched the web for \(singleLine($0))") } ?? String(localized: "Searched the web")
        case .fetch: return subject.map { String(localized: "Fetched \($0)") } ?? String(localized: "Fetched a page")
        case .task: return subject.map { String(localized: "Agent task · \(singleLine($0))") } ?? String(localized: "Agent task")
        case .todo:
            let done = card.todos.filter(\.isCompleted).count
            return card.todos.isEmpty ? String(localized: "Updated todos") : String(localized: "Updated todos · \(done) of \(card.todos.count) done")
        case .plan: return String(localized: "Proposed plan")
        case .mcp: return card.subject.map { String(localized: "Called \($0)") } ?? String(localized: "Called a tool")
        case .compaction: return String(localized: "Compacted context")
        case .other: return card.name.isEmpty ? String(localized: "Tool activity") : card.name
        }
    }

    private enum Action: Hashable { case command, edit, read, codeSearch, web, fetch, task, todo, other }
    private static func action(_ kind: TranscriptToolKind) -> Action {
        switch kind {
        case .command: .command
        case .edit: .edit
        case .read: .read
        case .search: .codeSearch
        case .webSearch: .web
        case .fetch: .fetch
        case .task: .task
        case .todo: .todo
        case .plan, .mcp, .compaction, .other: .other
        }
    }
    private static func priority(_ action: Action) -> Int {
        switch action {
        case .command, .edit, .task: 0
        case .other, .todo: 2
        default: 1
        }
    }
    private static func label(_ action: Action, count: Int) -> String {
        switch action {
        case .read: count == 1 ? String(localized: "Read 1 file") : String(localized: "Read \(count) files")
        case .edit: count == 1 ? String(localized: "Changed 1 file") : String(localized: "Changed \(count) files")
        case .command: count == 1 ? String(localized: "Ran 1 command") : String(localized: "Ran \(count) commands")
        case .codeSearch: count == 1 ? String(localized: "Searched code 1 time") : String(localized: "Searched code \(count) times")
        case .web: count == 1 ? String(localized: "Searched the web 1 time") : String(localized: "Searched the web \(count) times")
        case .fetch: count == 1 ? String(localized: "Fetched 1 page") : String(localized: "Fetched \(count) pages")
        case .task: count == 1 ? String(localized: "Delegated 1 task") : String(localized: "Delegated \(count) tasks")
        case .todo: count == 1 ? String(localized: "Updated todos") : String(localized: "Updated todos \(count) times")
        case .other: count == 1 ? String(localized: "Used 1 tool") : String(localized: "Used \(count) tools")
        }
    }

    /// T3's work-log sentence: the two highest-priority action groups in order,
    /// then "performed N other actions". Reasoning-only groups read "Thought".
    public static func summary(cards: [TranscriptToolCard], reasoningCount: Int = 0) -> (text: String, failed: Bool) {
        if cards.isEmpty { return (reasoningCount <= 1 ? String(localized: "Thought") : String(localized: "Thought (×\(reasoningCount))"), false) }
        var order: [Action] = [], groups: [Action: [TranscriptToolCard]] = [:]
        for card in cards {
            let key = action(card.kind)
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(card)
        }
        let summaries = order.indices.map { index -> (index: Int, key: Action, count: Int, label: String) in
            let key = order[index], entries = groups[key]!
            var count = entries.count
            if key == .edit {
                let paths = Set(entries.flatMap { $0.changes.map(\.path) + ($0.changes.isEmpty ? $0.subject.map { [$0] } ?? [] : []) })
                count = paths.count + entries.filter { $0.changes.isEmpty && $0.subject == nil }.count
            }
            return (index, key, entries.count, label(key, count: count))
        }
        let selected = summaries.sorted { (priority($0.key), $0.index) < (priority($1.key), $1.index) }.prefix(2).sorted { $0.index < $1.index }
        var labels = selected.map(\.label)
        let remaining = cards.count - selected.reduce(0) { $0 + $1.count }
        if remaining > 0 { labels.append(remaining == 1 ? String(localized: "Performed 1 other action") : String(localized: "Performed \(remaining) other actions")) }
        let sentence = labels.enumerated().map { $0.offset == 0 ? $0.element : $0.element.prefix(1).lowercased() + $0.element.dropFirst() }
        let text = sentence.count < 3 ? sentence.joined(separator: String(localized: " and ")) : sentence.dropLast().joined(separator: ", ") + String(localized: ", and ") + sentence.last!
        return (text, cards.last?.isFailure == true)
    }

    // MARK: Helpers

    public static func relative(_ path: String, to workspace: String?) -> String {
        guard let workspace, !workspace.isEmpty else { return path }
        let root = workspace.hasSuffix("/") ? String(workspace.dropLast()) : workspace
        if path.hasPrefix(root + "/") { return String(path.dropFirst(root.count + 1)) }
        return path
    }
    static func singleLine(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        return line.count > 240 ? String(line.prefix(240)) + "…" : line
    }
    static func split(_ text: String) -> (String, String) {
        guard let newline = text.firstIndex(where: \.isNewline) else { return (text, "") }
        return (String(text[..<newline]), String(text[text.index(after: newline)...]))
    }
    static func decode(_ text: String) -> JSONValue? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") || trimmed.hasPrefix("["), trimmed.utf8.count <= 8 * 1_048_576 else { return nil }
        guard boundedJSON(trimmed) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: Data(trimmed.utf8))
    }
    /// Bound recursive decoding before constructing JSONValue. Delimiters inside
    /// strings and escaped quotes remain literal; Foundation validates grammar.
    private static func boundedJSON(_ text: String) -> Bool {
        var depth = 0, nodes = 0, quoted = false, escaped = false
        for byte in text.utf8 {
            if quoted {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { quoted = false }
                continue
            }
            if byte == 34 { quoted = true; nodes += 1 }
            else if byte == 123 || byte == 91 { depth += 1; nodes += 1 }
            else if byte == 125 || byte == 93 { depth -= 1 }
            else if byte == 44 { nodes += 1 }
            guard depth >= 0, depth <= 64, nodes <= 100_000 else { return false }
        }
        return !quoted && depth == 0
    }
    static func number(_ value: JSONValue) -> Int? {
        if case .number(let raw) = value, raw.isFinite, let exact = Int(exactly: raw) { return exact }
        return nil
    }
    static func todos(_ value: JSONValue) -> [TranscriptTodo] {
        (value.array ?? []).prefix(512).compactMap { item in
            guard let text = item["content"].string ?? item["text"].string ?? item["title"].string else { return nil }
            return .init(text: text, status: item["status"].string ?? "pending")
        }
    }
    static func checklist(_ text: String) -> [TranscriptTodo] {
        text.split(whereSeparator: \.isNewline).prefix(512).compactMap { line in
            let value = line.trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("- [x] ") || value.hasPrefix("- [X] ") { return .init(text: String(value.dropFirst(6)), status: "completed") }
            if value.hasPrefix("- [ ] ") { return .init(text: String(value.dropFirst(6)), status: "pending") }
            return nil
        }
    }
    static func contentText(_ content: [JSONValue]) -> String {
        content.map { block in
            if let text = block["text"].string, block["type"].string == "text" { return text }
            if let text = block["resource"]["text"].string, block["type"].string == "resource" { return text }
            if block["type"].string == "resource_link" { return block["name"].string ?? block["uri"].string ?? "Resource" }
            return block.string ?? ""
        }.joined()
    }
}
