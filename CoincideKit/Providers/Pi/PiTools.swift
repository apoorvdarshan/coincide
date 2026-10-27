import Foundation

/// How Pi's tools appear in the transcript: category, title, detail and output.
enum PiTools {
    static func category(for name: String) -> ToolCategory {
        switch name {
        case "bash", "powershell": return .command
        case "edit", "write": return .fileChange
        case "read", "ls": return .read
        case "grep", "find", "tool_search": return .search
        case "subagent": return .task
        default: break
        }
        if isTodo(name) { return .todo }
        if mcpParts(name) != nil || mcpResourceTools.contains(name) { return .mcp }
        if webSearch(name) || webFetch(name) { return .web }
        return .other
    }

    static func isTodo(_ name: String) -> Bool {
        ["todo", "todos", "todo_write", "todowrite"].contains(name.lowercased())
    }

    /// `base` is the session's working folder; paths inside it are shown relative to it.
    static func info(id: String, name: String, args: JSONValue?, relativeTo base: String? = nil) -> ToolCallInfo {
        ToolCallInfo(
            id: id, category: category(for: name), title: title(name: name, args: args, base: base),
            detail: detail(name: name, args: args))
    }

    /// The detail once the tool has finished, when the result improves on it: Pi computes a unified patch for edits.
    static func finishedInfo(
        id: String, name: String, args: JSONValue?, result: JSONValue?, relativeTo base: String? = nil
    ) -> ToolCallInfo? {
        guard name == "edit", let patch = PiText.nonEmpty(result?["details"]?["patch"]?.string) else { return nil }
        return ToolCallInfo(id: id, category: .fileChange, title: title(name: name, args: args, base: base), detail: patch)
    }

    /// `path` relative to `base` when it lies inside it.
    static func displayPath(_ path: String, relativeTo base: String?) -> String {
        guard let base = PiText.nonEmpty(base), path.hasPrefix("/") else { return path }
        let folder = base.hasSuffix("/") ? base : base + "/"
        guard path.hasPrefix(folder), path.count > folder.count else { return path }
        return String(path.dropFirst(folder.count))
    }

    /// Text of a finished tool's result.
    static func outputText(name: String, result: JSONValue?) -> String {
        if name == "subagent" {
            let summary = subagentOutput(result?["details"])
            if !summary.isEmpty { return summary }
        }
        let text = PiText.content(result?["content"])
        if !text.isEmpty { return text }
        guard let structured = result?["structuredContent"], !structured.isNull else { return "" }
        return PiText.truncated(structured.displayText, limit: 20_000)
    }

    /// Text of a running tool's latest partial result. Pi's shell tools resend everything printed so far.
    static func progressText(name: String, partialResult: JSONValue?) -> String {
        name == "subagent" ? subagentOutput(partialResult?["details"]) : PiText.content(partialResult?["content"])
    }

    /// A todo tool's list (Pi's `todo` example extension and look-alikes) as a Markdown checklist.
    static func todoMarkdown(_ result: JSONValue?) -> String? {
        guard let todos = result?["details"]?["todos"]?.array else { return nil }
        let items = todos.compactMap { todo -> String? in
            guard let text = PiText.nonEmpty(todo["text"]?.string ?? todo["content"]?.string ?? todo["title"]?.string)
            else { return nil }
            let status = todo["status"]?.string
            let done = todo["done"]?.bool ?? todo["completed"]?.bool ?? (status == "completed" || status == "done")
            return "- [\(done ? "x" : " ")] " + (status == "in_progress" ? "**\(text)**" : text)
        }
        return items.isEmpty ? String(localized: "No todos.") : items.joined(separator: "\n")
    }

    /// What "Always allow" remembers: the exact command for shells, the file for edits, the input otherwise.
    static func approvalKey(name: String, args: JSONValue?) -> String {
        let subject: String
        switch name {
        case "bash", "powershell": subject = args?["command"]?.string ?? ""
        case "edit", "write": subject = path(args) ?? ""
        default: subject = args?.compactJSON ?? ""
        }
        return "\(name)\u{0}\(subject)"
    }

    // MARK: Titles and details

    private static func title(name: String, args: JSONValue?, base: String?) -> String {
        let text = { (key: String) in PiText.nonEmpty(args?[key]?.string) }
        let place = { (key: String) in text(key).map { displayPath($0, relativeTo: base) } }
        let file = path(args).map { displayPath($0, relativeTo: base) }
        switch name {
        case "bash", "powershell":
            guard let command = text("command") else { return String(localized: "Run a command") }
            return String(localized: "Run `\(PiText.summary(command))`")
        case "read":
            guard let file else { return String(localized: "Read a file") }
            return String(localized: "Read \(file)")
        case "edit":
            guard let file else { return String(localized: "Edit a file") }
            return String(localized: "Edit \(file)")
        case "write":
            guard let file else { return String(localized: "Write a file") }
            return String(localized: "Write \(file)")
        case "grep":
            guard let pattern = text("pattern").map({ PiText.summary($0, limit: 60) }) else {
                return String(localized: "Search files")
            }
            return place("path").map { String(localized: "Search for `\(pattern)` in \($0)") }
                ?? String(localized: "Search for `\(pattern)`")
        case "find":
            guard let pattern = text("pattern").map({ PiText.summary($0, limit: 60) }) else {
                return String(localized: "Find files")
            }
            return place("path").map { String(localized: "Find `\(pattern)` in \($0)") }
                ?? String(localized: "Find `\(pattern)`")
        case "ls":
            return String(localized: "List \(place("path") ?? ".")")
        case "tool_search":
            return text("query").map { String(localized: "Search tools for `\(PiText.summary($0, limit: 60))`") }
                ?? String(localized: "Search tools")
        case "codemode":
            return String(localized: "Run a code mode script")
        case "subagent":
            return subagentTitle(args)
        case "list_mcp_resources":
            return String(localized: "List MCP resources")
        case "list_mcp_resource_templates":
            return String(localized: "List MCP resource templates")
        case "read_mcp_resource":
            return text("uri").map { String(localized: "Read MCP resource \($0)") } ?? String(localized: "Read an MCP resource")
        default:
            break
        }
        if isTodo(name) { return todoTitle(args) }
        if let mcp = mcpParts(name) { return "\(mcp.server): \(mcp.tool)" }
        if webSearch(name), let query = text("query") ?? text("q") {
            return String(localized: "Search the web for `\(PiText.summary(query, limit: 60))`")
        }
        if webFetch(name), let url = text("url") { return String(localized: "Fetch \(url)") }
        return name
    }

    private static func detail(name: String, args: JSONValue?) -> String? {
        switch name {
        case "bash", "powershell":
            return PiText.nonEmpty(args?["command"]?.string)
        case "edit":
            return path(args).flatMap { editDiff(path: $0, args: args) }
        case "write":
            return args?["content"]?.string.map { PiText.truncated($0, limit: 100_000) }
        case "read":
            return lineRange(args)
        case "codemode":
            return PiText.nonEmpty(args?["code"]?.string) ?? arguments(args)
        case "subagent":
            return subagentDetail(args)
        default:
            return arguments(args)
        }
    }

    private static func path(_ args: JSONValue?) -> String? {
        PiText.nonEmpty(args?["path"]?.string ?? args?["file_path"]?.string)
    }

    private static func lineRange(_ args: JSONValue?) -> String? {
        let offset = args?["offset"]?.int
        let limit = args?["limit"]?.int
        switch (offset, limit) {
        case let (offset?, limit?): return String(localized: "Lines \(offset)–\(offset + limit - 1)")
        case let (offset?, nil): return String(localized: "From line \(offset)")
        case let (nil, limit?): return String(localized: "Lines 1–\(limit)")
        case (nil, nil): return nil
        }
    }

    /// The input as pretty JSON, or nil when there is none.
    private static func arguments(_ args: JSONValue?) -> String? {
        guard let args else { return nil }
        if let object = args.object, object.isEmpty { return nil }
        if let array = args.array, array.isEmpty { return nil }
        return PiText.truncated(args.prettyJSON, limit: 20_000)
    }

    /// A diff of the requested replacements, shown until Pi reports the real patch. Pi's `edit` takes
    /// `edits: [{oldText, newText}]`; older versions took a single `oldText`/`newText` pair. Some models send
    /// `edits` as a JSON string or as one object, which Pi accepts too.
    static func editDiff(path: String, args: JSONValue?) -> String? {
        var edits = args?["edits"]
        if let encoded = edits?.string { edits = JSONValue.parse(encoded) }
        if edits?.object != nil { edits = .array([edits ?? .null]) }
        var replacements: [(old: String, new: String)] = (edits?.array ?? []).compactMap { edit in
            guard let old = edit["oldText"]?.string, let new = edit["newText"]?.string else { return nil }
            return (old, new)
        }
        if let old = args?["oldText"]?.string, let new = args?["newText"]?.string {
            replacements.append((old, new))
        }
        guard !replacements.isEmpty else { return nil }
        var lines = ["--- \(path)", "+++ \(path)"]
        for replacement in replacements {
            lines.append("@@")
            lines += diffLines(replacement.old).map { "-" + $0 }
            lines += diffLines(replacement.new).map { "+" + $0 }
        }
        return lines.joined(separator: "\n")
    }

    private static func diffLines(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    // MARK: Subagents (Pi's `subagent` example extension)

    private static func subagentTitle(_ args: JSONValue?) -> String {
        if let count = args?["tasks"]?.array?.count, count > 0 {
            return String(localized: "Run \(count) subagents in parallel")
        }
        if let count = args?["chain"]?.array?.count, count > 0 {
            return String(localized: "Run a chain of \(count) subagents")
        }
        guard let agent = PiText.nonEmpty(args?["agent"]?.string) else { return String(localized: "Run a subagent") }
        guard let task = PiText.nonEmpty(args?["task"]?.string) else { return String(localized: "Ask \(agent)") }
        return String(localized: "Ask \(agent): \(PiText.summary(task, limit: 60))")
    }

    private static func subagentDetail(_ args: JSONValue?) -> String? {
        let steps = args?["tasks"]?.array ?? args?["chain"]?.array ?? []
        guard !steps.isEmpty else { return PiText.nonEmpty(args?["task"]?.string) }
        return steps.compactMap { step -> String? in
            guard let task = PiText.nonEmpty(step["task"]?.string) else { return nil }
            return "\(step["agent"]?.string ?? "subagent"): \(task)"
        }.joined(separator: "\n")
    }

    /// The latest assistant text of each subagent, or its error when it failed.
    static func subagentOutput(_ details: JSONValue?) -> String {
        let results = details?["results"]?.array ?? []
        let texts = results.compactMap { result -> String? in
            let text = subagentText(result)
            guard !text.isEmpty else { return nil }
            return results.count == 1 ? text : "\(result["agent"]?.string ?? "subagent"):\n\(text)"
        }
        return texts.joined(separator: "\n\n")
    }

    private static func subagentText(_ result: JSONValue) -> String {
        let stopReason = result["stopReason"]?.string
        let failed = (result["exitCode"]?.int ?? 0) != 0 || stopReason == "error" || stopReason == "aborted"
        if failed, let failure = PiText.nonEmpty(result["errorMessage"]?.string) ?? PiText.nonEmpty(result["stderr"]?.string) {
            return failure
        }
        for message in (result["messages"]?.array ?? []).reversed() where message["role"]?.string == "assistant" {
            let text = PiText.content(message["content"])
            if !text.isEmpty { return text }
        }
        return ""
    }

    // MARK: Other tool families

    private static func todoTitle(_ args: JSONValue?) -> String {
        switch args?["action"]?.string {
        case "add": PiText.nonEmpty(args?["text"]?.string).map { String(localized: "Add todo: \($0)") } ?? String(localized: "Add a todo")
        case "toggle": args?["id"]?.int.map { String(localized: "Toggle todo #\($0)") } ?? String(localized: "Toggle a todo")
        case "list": String(localized: "List todos")
        case "clear": String(localized: "Clear todos")
        default: String(localized: "Update todos")
        }
    }

    /// Pi names MCP tools `mcp__<server>__<tool>`.
    static func mcpParts(_ name: String) -> (server: String, tool: String)? {
        guard name.hasPrefix("mcp__") else { return nil }
        let rest = name.dropFirst("mcp__".count)
        guard let separator = rest.range(of: "__") else { return nil }
        let server = rest[..<separator.lowerBound]
        let tool = rest[separator.upperBound...]
        guard !server.isEmpty, !tool.isEmpty else { return nil }
        return (String(server), String(tool))
    }

    private static let mcpResourceTools: Set<String> = ["list_mcp_resources", "list_mcp_resource_templates", "read_mcp_resource"]

    private static func webSearch(_ name: String) -> Bool {
        let name = name.lowercased()
        return ["web_search", "websearch", "search_web", "brave_search", "tavily"].contains { name.contains($0) }
    }

    private static func webFetch(_ name: String) -> Bool {
        let name = name.lowercased()
        return name == "fetch" || ["web_fetch", "webfetch", "fetch_url", "url_fetch"].contains { name.contains($0) }
    }
}

/// Text helpers for Pi's payloads.
enum PiText {
    /// The text with surrounding whitespace removed, or nil when nothing is left.
    static func nonEmpty(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// The first line, shortened to `limit` characters, with an ellipsis when anything was left out.
    static func summary(_ text: String, limit: Int = 80) -> String {
        let lines = text.trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: \.isNewline)
        let first = lines.first.map(String.init) ?? ""
        guard first.count > limit || lines.count > 1 else { return first }
        return String(first.prefix(limit - 1)) + "…"
    }

    static func truncated(_ text: String, limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit)) + "\n…" : text
    }

    /// Joins the text blocks of Pi message or tool content, which is either a string or an array of blocks.
    static func content(_ value: JSONValue?) -> String {
        if let text = value?.string { return text }
        return (value?.array ?? []).compactMap { block in
            block["type"]?.string == "text" ? block["text"]?.string : nil
        }.joined(separator: "\n")
    }
}
