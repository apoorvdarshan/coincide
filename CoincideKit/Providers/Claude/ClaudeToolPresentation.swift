import Foundation

/// How Claude Code's tool calls appear in the transcript: categories, titles, details (commands,
/// unified diffs, inputs) and outputs.
enum ClaudeTools {
    /// Tools shown as plans or approvals instead of tool items, and tool-loading plumbing.
    static let hiddenTools: Set<String> = [
        "todowrite", "taskcreate", "taskupdate", "tasklist", "taskget", "askuserquestion", "exitplanmode",
        "enterplanmode", "toolsearch",
    ]

    static func normalizedName(_ name: String) -> String {
        name.lowercased().filter { $0 != "_" && $0 != "-" && $0 != " " }
    }

    static func isHidden(_ name: String) -> Bool { hiddenTools.contains(normalizedName(name)) }

    static func isMCP(_ name: String) -> Bool { name.hasPrefix("mcp__") }

    static func category(for name: String) -> ToolCategory {
        if isMCP(name) { return .mcp }
        switch normalizedName(name) {
        case "bash", "powershell", "bashoutput", "monitor", "taskstop", "killshell", "killbash": return .command
        case "edit", "multiedit", "write", "notebookedit": return .fileChange
        case "read", "notebookread", "ls": return .read
        case "grep", "glob", "lsp": return .search
        case "webfetch", "websearch": return .web
        case "task", "agent", "sendmessage": return .task
        case "todowrite", "taskcreate", "taskupdate", "tasklist", "taskget": return .todo
        default: return .other
        }
    }

    /// Title and detail for a tool call. `fileContents` reads the file an edit targets, to number its diff.
    static func info(
        id: String, name: String, input: JSONValue, workingDirectory: String, displayName: String? = nil,
        serverName: String? = nil, fileContents: (String) -> String? = readSmallFile
    ) -> ToolCallInfo {
        let path = input["file_path"]?.string ?? input["notebook_path"]?.string ?? input["path"]?.string
        let shownPath = path.map { displayPath($0, relativeTo: workingDirectory) }
        let title: String
        var detail: String?
        switch normalizedName(name) {
        case "bash", "powershell":
            let command = string(input["command"]) ?? ""
            if command.isEmpty {
                title = String(localized: "Run command")
            } else if input["run_in_background"]?.bool == true {
                title = String(localized: "Run `\(summary(command))` in the background")
            } else {
                title = String(localized: "Run `\(summary(command))`")
            }
            detail = command.isEmpty ? nil : command
        case "monitor":
            let command = string(input["command"])
            title = command.map { String(localized: "Monitor `\(summary($0))`") } ?? String(localized: "Monitor")
            detail = string(input["description"])
        case "edit":
            title = shownPath.map { String(localized: "Edit \($0)") } ?? String(localized: "Edit file")
            if let path, let old = input["old_string"]?.string, let new = input["new_string"]?.string {
                let start = fileContents(path).flatMap { lineNumber(of: old, in: $0) } ?? 1
                detail = diff(path: shownPath ?? path, old: old, new: new, startLine: start)
            }
        case "multiedit":
            title = shownPath.map { String(localized: "Edit \($0)") } ?? String(localized: "Edit file")
            if let path, let edits = input["edits"]?.array {
                let original = fileContents(path)
                let hunks = edits.compactMap { edit -> String? in
                    guard let old = edit["old_string"]?.string, let new = edit["new_string"]?.string else { return nil }
                    let start = original.flatMap { lineNumber(of: old, in: $0) } ?? 1
                    return hunk(old: old, new: new, startLine: start)
                }
                detail = hunks.isEmpty ? nil : header(shownPath ?? path) + hunks.joined(separator: "\n")
            }
        case "write":
            title = shownPath.map { String(localized: "Write \($0)") } ?? String(localized: "Write file")
            if let path, let content = input["content"]?.string { detail = creationDiff(path: shownPath ?? path, content: content) }
        case "notebookedit":
            title = shownPath.map { String(localized: "Edit notebook \($0)") } ?? String(localized: "Edit notebook")
            detail = string(input["new_source"])
        case "read", "notebookread":
            title = readTitle(shownPath, input: input)
        case "ls":
            title = shownPath.map { String(localized: "List \($0)") } ?? String(localized: "List files")
        case "grep":
            let pattern = string(input["pattern"]) ?? ""
            title = shownPath.map { String(localized: "Search for `\(pattern)` in \($0)") } ?? String(localized: "Search for `\(pattern)`")
            detail = inputDetail(input)
        case "glob":
            let pattern = string(input["pattern"]) ?? ""
            title = shownPath.map { String(localized: "Find files matching `\(pattern)` in \($0)") }
                ?? String(localized: "Find files matching `\(pattern)`")
        case "webfetch":
            title = string(input["url"]).map { String(localized: "Fetch \($0)") } ?? String(localized: "Fetch a web page")
            detail = string(input["prompt"])
        case "websearch":
            title = string(input["query"]).map { String(localized: "Search the web for “\($0)”") } ?? String(localized: "Search the web")
        case "task", "agent":
            let type = string(input["subagent_type"])
            let label = type == nil || type == "general-purpose" ? String(localized: "Agent") : type!
            title = string(input["description"]).map { "\(label): \($0)" } ?? label
            detail = string(input["prompt"])
        case "sendmessage":
            title = string(input["summary"]).map { String(localized: "Message agent: \($0)") } ?? String(localized: "Message agent")
            detail = string(input["message"]) ?? string(input["content"])
        case "taskstop", "killshell", "killbash":
            let task = string(input["task_id"]) ?? string(input["shell_id"])
            title = task.map { String(localized: "Stop task \($0)") } ?? String(localized: "Stop task")
        case "skill":
            title = string(input["skill"]).map { String(localized: "Skill: \($0)") } ?? String(localized: "Skill")
            detail = string(input["args"])
        default:
            if isMCP(name) {
                let parts = mcpParts(name)
                title = "\(serverName ?? parts.server): \(displayName ?? parts.tool)"
            } else {
                title = displayName ?? name
            }
            detail = inputDetail(input)
        }
        return ToolCallInfo(id: id, category: category(for: name), title: title, detail: detail)
    }

    /// The exact diff Claude Code reports after an edit, which replaces the one built from the input.
    static func resultDetail(name: String, input: JSONValue, structured: JSONValue?, workingDirectory: String) -> String? {
        guard category(for: name) == .fileChange, normalizedName(name) != "notebookedit", let structured else { return nil }
        guard let path = structured["filePath"]?.string ?? input["file_path"]?.string else { return nil }
        let shown = displayPath(path, relativeTo: workingDirectory)
        if let hunks = structured["structuredPatch"]?.array, !hunks.isEmpty { return diff(path: shown, hunks: hunks) }
        if structured["type"]?.string == "create", let content = structured["content"]?.string {
            return creationDiff(path: shown, content: content)
        }
        return nil
    }

    /// Output text for a finished call: command streams, an agent's report, search results, or the
    /// tool result's text.
    static func output(name: String, content: JSONValue?, structured: JSONValue?, isError: Bool) -> String {
        let text = self.text(of: content)
        switch normalizedName(name) {
        case "bash", "powershell":
            guard !isError, let structured, structured["stdout"] != nil || structured["stderr"] != nil else { return text }
            let out = structured["stdout"]?.string ?? ""
            let err = structured["stderr"]?.string ?? ""
            let combined = out.isEmpty || err.isEmpty || out.hasSuffix("\n") ? out + err : out + "\n" + err
            return combined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? text : combined
        case "task", "agent":
            let report = self.text(of: structured?["content"])
            return report.isEmpty ? text : report
        case "websearch":
            let links = (structured?["results"]?.array ?? []).flatMap { result in
                (result["content"]?.array ?? []).compactMap { link -> String? in
                    guard let url = link["url"]?.string else { return nil }
                    return "- [\(link["title"]?.string ?? url)](\(url))"
                }
            }
            return links.isEmpty ? text : links.joined(separator: "\n")
        case "webfetch":
            return String((structured?["result"]?.string ?? text).prefix(8_000))
        default:
            return text
        }
    }

    /// Text of a tool result's content: a string, or text blocks with images noted.
    static func text(of content: JSONValue?) -> String {
        switch content {
        case .string(let text)?:
            return text
        case .array(let blocks)?:
            return blocks.compactMap { block -> String? in
                switch block["type"]?.string {
                case "text"?: return block["text"]?.string
                case "image"?: return String(localized: "[image]")
                case "tool_reference"?: return block["tool_name"]?.string.map { String(localized: "Loaded \($0)") }
                default: return block.string
                }
            }.joined(separator: "\n")
        default:
            return ""
        }
    }

    // MARK: Paths and text

    /// A path relative to the working directory when inside it, otherwise with `~` for the home folder.
    static func displayPath(_ path: String, relativeTo workingDirectory: String) -> String {
        let root = workingDirectory.hasSuffix("/") ? String(workingDirectory.dropLast()) : workingDirectory
        if !root.isEmpty, path.hasPrefix(root + "/") { return String(path.dropFirst(root.count + 1)) }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    /// First line of a command, shortened for a title.
    static func summary(_ command: String, limit: Int = 80) -> String {
        let lines = command.trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: \.isNewline)
        let first = lines.first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        if first.count > limit { return String(first.prefix(limit - 1)) + "…" }
        return lines.count > 1 ? first + " …" : first
    }

    private static func readTitle(_ path: String?, input: JSONValue) -> String {
        guard let path else { return String(localized: "Read file") }
        if let offset = input["offset"]?.int, let limit = input["limit"]?.int, limit > 0 {
            return String(localized: "Read \(path) (lines \(offset)–\(offset + limit - 1))")
        }
        return String(localized: "Read \(path)")
    }

    private static func string(_ value: JSONValue?) -> String? {
        guard let text = value?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    private static func inputDetail(_ input: JSONValue) -> String? {
        if case .object(let object) = input, object.isEmpty { return nil }
        if input.isNull { return nil }
        return input.prettyJSON
    }

    /// `mcp__server__tool` → ("server", "tool"), with claude.ai and plugin prefixes dropped.
    static func mcpParts(_ name: String) -> (server: String, tool: String) {
        let body = name.dropFirst("mcp__".count)
        guard let separator = body.range(of: "__") else { return (String(body), String(body)) }
        var server = String(body[..<separator.lowerBound])
        let tool = String(body[separator.upperBound...])
        if server.hasPrefix("claude_ai_") { server.removeFirst("claude_ai_".count) }
        if server.hasPrefix("plugin_"), let last = server.split(separator: "_").last { server = String(last) }
        return (server, tool)
    }

    static func readSmallFile(_ path: String) -> String? {
        let url = URL(fileURLWithPath: path)
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 2_000_000 else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    // MARK: Diffs

    /// 1-based line where `text` first occurs in `contents`.
    static func lineNumber(of text: String, in contents: String) -> Int? {
        guard !text.isEmpty, let range = contents.range(of: text) else { return nil }
        return contents[..<range.lowerBound].reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
    }

    static func diff(path: String, old: String, new: String, startLine: Int) -> String {
        header(path) + hunk(old: old, new: new, startLine: startLine)
    }

    static func creationDiff(path: String, content: String) -> String {
        let lines = splitLines(content)
        return "--- /dev/null\n+++ \(path)\n@@ -0,0 +1,\(lines.count) @@\n" + lines.map { "+" + $0 }.joined(separator: "\n")
    }

    /// Renders Claude Code's `structuredPatch` hunks.
    static func diff(path: String, hunks: [JSONValue]) -> String? {
        let rendered = hunks.compactMap { hunk -> String? in
            guard let oldStart = hunk["oldStart"]?.int, let newStart = hunk["newStart"]?.int,
                let lines = hunk["lines"]?.array?.compactMap(\.string)
            else { return nil }
            let oldLines = hunk["oldLines"]?.int ?? lines.filter { !$0.hasPrefix("+") }.count
            let newLines = hunk["newLines"]?.int ?? lines.filter { !$0.hasPrefix("-") }.count
            return "@@ -\(oldStart),\(oldLines) +\(newStart),\(newLines) @@\n" + lines.joined(separator: "\n")
        }
        return rendered.isEmpty ? nil : header(path) + rendered.joined(separator: "\n")
    }

    private static func header(_ path: String) -> String { "--- \(path)\n+++ \(path)\n" }

    /// One hunk replacing `old` with `new`, keeping their shared first and last lines as context.
    private static func hunk(old: String, new: String, startLine: Int) -> String {
        let oldLines = splitLines(old)
        let newLines = splitLines(new)
        var prefix = 0
        while prefix < min(oldLines.count, newLines.count), oldLines[prefix] == newLines[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(oldLines.count, newLines.count) - prefix,
            oldLines[oldLines.count - 1 - suffix] == newLines[newLines.count - 1 - suffix]
        {
            suffix += 1
        }
        var body = oldLines[..<prefix].map { " " + $0 }
        body += oldLines[prefix..<(oldLines.count - suffix)].map { "-" + $0 }
        body += newLines[prefix..<(newLines.count - suffix)].map { "+" + $0 }
        body += oldLines[(oldLines.count - suffix)...].map { " " + $0 }
        return "@@ -\(startLine),\(oldLines.count) +\(startLine),\(newLines.count) @@\n" + body.joined(separator: "\n")
    }

    private static func splitLines(_ text: String) -> [String] {
        var lines = text.components(separatedBy: "\n")
        if lines.count > 1, lines.last == "" { lines.removeLast() }
        return lines
    }

    // MARK: Streaming input

    /// Reads a complete string value for `key` out of JSON that is still streaming in, so a title
    /// can show a path or command before the whole input has arrived.
    static func partialStringField(_ key: String, in json: String) -> String? {
        guard let keyRange = json.range(of: "\"\(key)\"") else { return nil }
        var index = keyRange.upperBound
        func skipSpaces() {
            while index < json.endIndex, json[index].isWhitespace { index = json.index(after: index) }
        }
        skipSpaces()
        guard index < json.endIndex, json[index] == ":" else { return nil }
        index = json.index(after: index)
        skipSpaces()
        guard index < json.endIndex, json[index] == "\"" else { return nil }
        var escaped = false
        var cursor = json.index(after: index)
        while cursor < json.endIndex {
            let character = json[cursor]
            if escaped {
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                return JSONValue.parse(String(json[index...cursor]))?.string
            }
            cursor = json.index(after: cursor)
        }
        return nil
    }

    // MARK: Plans

    /// A TodoWrite list as a markdown checklist; the item in progress is bold.
    static func todoPlan(_ input: JSONValue) -> String? {
        let items = (input["todos"]?.array ?? []).compactMap { todo -> (String, String)? in
            guard let text = todo["content"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                return nil
            }
            return (text, todo["status"]?.string ?? "pending")
        }
        return items.isEmpty ? nil : checklist(items)
    }

    static func checklist(_ items: [(text: String, status: String)]) -> String {
        items.map { item in
            switch item.status {
            case "completed": "- [x] \(item.text)"
            case "in_progress": "- [ ] **\(item.text)**"
            default: "- [ ] \(item.text)"
            }
        }.joined(separator: "\n")
    }
}

/// The task list kept by Claude Code's TaskCreate / TaskUpdate / TaskList tools, as T3 tracks it.
struct ClaudeTaskList: Sendable, Equatable {
    struct Item: Sendable, Equatable {
        var id: String
        var subject: String
        var status: String
    }

    private(set) var tasks: [Item] = []

    var plan: String? { tasks.isEmpty ? nil : ClaudeTools.checklist(tasks.map { ($0.subject, $0.status) }) }

    /// Applies a finished task tool call. Returns true when the list changed.
    mutating func apply(tool: String, input: JSONValue, structured: JSONValue?, resultText: String) -> Bool {
        let before = tasks
        switch tool {
        case "TaskList":
            guard let listed = structured?["tasks"]?.array else { return false }
            tasks = listed.compactMap { item in
                guard let id = Self.field(item["id"]), let subject = item["subject"]?.string,
                    let status = Self.status(item["status"]?.string)
                else { return nil }
                return Item(id: id, subject: subject, status: status)
            }
        case "TaskCreate":
            let created = structured?["task"]
            let fromText = Self.createdTask(fromText: resultText)
            guard let id = Self.field(created?["id"]) ?? fromText?.id,
                let subject = created?["subject"]?.string ?? fromText?.subject ?? input["subject"]?.string
            else { return false }
            tasks.removeAll { $0.id == id }
            tasks.append(Item(id: id, subject: subject, status: "pending"))
        case "TaskUpdate":
            guard structured?["success"]?.bool != false,
                let id = Self.field(input["taskId"]) ?? Self.field(structured?["taskId"]),
                let index = tasks.firstIndex(where: { $0.id == id })
            else { return false }
            if input["status"]?.string == "deleted" {
                tasks.remove(at: index)
            } else {
                if let subject = input["subject"]?.string, !subject.isEmpty { tasks[index].subject = subject }
                if let status = Self.status(input["status"]?.string) { tasks[index].status = status }
            }
        default:
            return false
        }
        return tasks != before
    }

    private static func field(_ value: JSONValue?) -> String? {
        guard let value, !value.isNull else { return nil }
        let text = value.displayText
        return text.isEmpty ? nil : text
    }

    private static func status(_ raw: String?) -> String? {
        switch raw {
        case "pending"?, "in_progress"?, "completed"?: raw
        default: nil
        }
    }

    /// Subagent results carry only the text "Task #3 created successfully: <subject>".
    private static func createdTask(fromText text: String) -> (id: String, subject: String)? {
        guard let match = text.firstMatch(of: /^Task #(\S+) created successfully: (.+)$/.dotMatchesNewlines()) else { return nil }
        return (String(match.1), String(match.2).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
