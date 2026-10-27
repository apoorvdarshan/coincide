import Foundation

/// One ACP tool call as Coincide tracks it, merged across `tool_call` and `tool_call_update`.
/// Flavors fill in what their agent reports outside the standard fields.
public struct ACPToolCallState: Sendable, Hashable {
    public enum Status: Sendable, Hashable {
        case pending
        case inProgress
        case completed
        case failed
    }

    public var id: String
    /// ACP tool kind: `read`, `edit`, `delete`, `move`, `search`, `execute`, `think`, `fetch`, `other`.
    public var kind: String?
    public var title: String?
    public var status: Status
    public var rawInput: JSONValue?
    public var rawOutput: JSONValue?
    public var content: [ACPToolCallContent]
    public var locations: [String]
    public var meta: JSONValue?
    /// The agent's own name for the tool, e.g. `read_file`.
    public var toolName: String?
    public var command: String?
    public var exitCode: Int?
    /// Overrides the category derived from `kind`.
    public var category: ToolCategory?

    public nonisolated init(_ update: ACPToolCallUpdate) {
        id = update.id
        kind = update.kind
        title = update.title
        status = Self.status(update.status) ?? .pending
        rawInput = update.rawInput
        rawOutput = update.rawOutput
        content = update.content ?? []
        locations = update.locations ?? []
        meta = update.meta
        deriveDefaults()
    }

    /// Applies an update; fields the update leaves out keep their value. Agents often resend
    /// an empty `rawInput`, which must not erase the first one.
    public nonisolated mutating func merge(_ update: ACPToolCallUpdate) {
        kind = update.kind ?? kind
        title = update.title ?? title
        status = Self.status(update.status) ?? status
        if let input = update.rawInput {
            if case .object(let next) = input, case .object(let previous) = rawInput {
                rawInput = next.isEmpty ? rawInput : .object(previous.merging(next) { $1 })
            } else if input.object?.isEmpty != true || rawInput == nil {
                rawInput = input
            }
        }
        rawOutput = update.rawOutput ?? rawOutput
        content = update.content ?? content
        if let next = update.locations, !next.isEmpty { locations = next }
        if case .object(let next) = update.meta {
            meta = .object((meta?.object ?? [:]).merging(next) { $1 })
        }
        deriveDefaults()
    }

    public nonisolated var isFinished: Bool { status == .completed || status == .failed }

    private nonisolated mutating func deriveDefaults() {
        toolName = meta?["x.ai/tool"]?["name"]?.string ?? meta?["toolName"]?.string ?? meta?.at("claudeCode.toolName")?.string
        command = Self.commandText(rawInput?["command"]) ?? rawInput?["cmd"]?.string.flatMap(Self.nonEmpty)
        if command == nil, let executable = rawInput?["executable"]?.string.flatMap(Self.nonEmpty) {
            command = ([executable] + (rawInput?["args"]?.array?.compactMap(\.string) ?? [])).joined(separator: " ")
        }
        if command == nil, kind == "execute", let title, let range = title.range(of: #"`([^`]+)`"#, options: .regularExpression) {
            command = String(title[range].dropFirst().dropLast())
        }
        let output = rawOutput
        exitCode = ["exit_code", "exitCode", "code"].compactMap { output?[$0]?.acpInt }.first
        category = nil
    }

    nonisolated static func status(_ raw: String?) -> Status? {
        switch raw {
        case "pending": .pending
        case "in_progress", "inProgress": .inProgress
        case "completed": .completed
        case "failed": .failed
        default: nil
        }
    }

    nonisolated static func commandText(_ value: JSONValue?) -> String? {
        if let text = value?.string { return nonEmpty(text) }
        guard let parts = value?.array?.compactMap(\.string), !parts.isEmpty else { return nil }
        return parts.joined(separator: " ")
    }

    nonisolated static func nonEmpty(_ text: String) -> String? { TerminalText.nonEmpty(text) }
}

// MARK: Presentation

extension ACPToolCallState {
    private nonisolated static let pathKeys = [
        "path", "file_path", "filePath", "target_file", "targetFile", "absolute_path", "notebook_path", "filename",
        "fileName", "relativePath", "target_directory", "targetDirectory", "directory", "dir",
    ]
    private nonisolated static let queryKeys = ["pattern", "query", "regex", "searchTerm", "search_term", "grep", "needle"]
    private nonisolated static let globKeys = ["glob", "glob_pattern", "globPattern", "include", "filePattern", "file_pattern"]
    private nonisolated static let maxOutputCharacters = 64_000

    public nonisolated var resolvedCategory: ToolCategory {
        if let category { return category }
        if isMCP { return .mcp }
        switch kind {
        case "execute": return .command
        case "edit", "delete", "move": return .fileChange
        case "read": return .read
        case "search": return .search
        case "fetch": return .web
        default: break
        }
        let name = (toolName ?? "").lowercased().replacingOccurrences(of: "-", with: "_")
        switch name {
        case "bash", "shell", "terminal", "run_terminal_cmd", "run_terminal_command", "exec", "run_command": return .command
        case "edit", "write", "write_file", "search_replace", "str_replace", "multi_edit", "apply_patch", "delete_file":
            return .fileChange
        case "read", "read_file", "view", "list_dir", "ls": return .read
        case "grep", "glob", "find", "rg", "search", "codebase_search", "file_search": return .search
        case "web_search", "web_fetch", "fetch", "x_search": return .web
        case "todo_write", "todowrite", "todo", "update_todos": return .todo
        case "task", "spawn_subagent", "agent", "subagent", "start_subagent": return .task
        default: break
        }
        if (title ?? "").localizedCaseInsensitiveContains("subagent") { return .task }
        return .other
    }

    private nonisolated var isMCP: Bool {
        if meta?["is_mcp_tool_call"]?.bool == true { return true }
        if mcpIdentity != nil { return true }
        return rawInput?["server"]?.string != nil && rawInput?["tool"]?.string != nil && kind != "execute"
    }

    /// Server and tool for names like `mcp__github__create_issue`.
    nonisolated var mcpIdentity: (server: String, tool: String)? {
        for candidate in [toolName, title].compactMap(\.self) {
            let parts = candidate.components(separatedBy: "__")
            if parts.count >= 3, parts[0].lowercased() == "mcp", !parts[1].isEmpty {
                return (parts[1], parts[2...].joined(separator: "__"))
            }
        }
        if let server = rawInput?["server"]?.string, let tool = rawInput?["tool"]?.string { return (server, tool) }
        return nil
    }

    /// File paths the call touches, most relevant first.
    nonisolated var paths: [String] {
        var seen = Set<String>()
        var result: [String] = []
        func add(_ path: String?) {
            guard let path = path.flatMap(Self.nonEmpty), seen.insert(path).inserted else { return }
            result.append(path)
        }
        locations.forEach(add)
        for entry in content {
            switch entry {
            case .diff(let path, _, _): add(path)
            case .patch(let patch): patch.changes.forEach { add($0.path) }
            default: break
            }
        }
        for key in Self.pathKeys { add(rawInput?[key]?.string) }
        if let paths = rawInput?["paths"]?.array { paths.forEach { add($0.string) } }
        return result
    }

    public nonisolated func info(relativeTo directory: URL) -> ToolCallInfo {
        let category = resolvedCategory
        return ToolCallInfo(
            id: id, category: category, title: displayTitle(category, directory), detail: detail(category, directory))
    }

    private nonisolated func displayTitle(_ category: ToolCategory, _ directory: URL) -> String {
        let agentTitle = title.flatMap(Self.nonEmpty).flatMap { Self.isGenericTitle($0) ? nil : $0 }
        let paths = self.paths.map { Self.displayPath($0, relativeTo: directory) }
        let more = paths.count > 1 ? " +\(paths.count - 1)" : ""
        switch category {
        case .command:
            if let command { return String(localized: "Run `\(Self.truncate(command, 80))`") }
            return agentTitle ?? String(localized: "Run command")
        case .fileChange:
            guard let first = paths.first else { return agentTitle ?? String(localized: "Edit files") }
            switch patchOperation ?? kind {
            case "delete": return String(localized: "Delete \(first)\(more)")
            case "move", "rename": return String(localized: "Move \(first)\(more)")
            case "add", "copy": return String(localized: "Create \(first)\(more)")
            default:
                let created = content.contains { if case .diff(_, .none, _) = $0 { return true } else { return false } }
                return created ? String(localized: "Create \(first)\(more)") : String(localized: "Edit \(first)\(more)")
            }
        case .read:
            guard let first = paths.first else { return agentTitle ?? String(localized: "Read file") }
            let listing = toolName == "list_dir" || toolName == "ls" || meta?["x.ai/tool"]?["kind"]?.string == "list"
            return listing ? String(localized: "List \(first)") : String(localized: "Read \(first)\(more)")
        case .search:
            let query = firstString(Self.queryKeys)
            let glob = firstString(Self.globKeys)
            let target = paths.first
            switch (query, glob, target) {
            case (let query?, _, let target?): return String(localized: "Search “\(query)” in \(target)")
            case (let query?, _, nil): return String(localized: "Search “\(query)”")
            case (nil, let glob?, let target?): return String(localized: "Find “\(glob)” in \(target)")
            case (nil, let glob?, nil): return String(localized: "Find “\(glob)”")
            default: return agentTitle ?? String(localized: "Search")
            }
        case .web:
            if let url = firstString(["url", "uri"]) { return String(localized: "Fetch \(url)") }
            if let query = firstString(["query", "search_term", "q"]) { return String(localized: "Search the web for “\(query)”") }
            return agentTitle ?? String(localized: "Web request")
        case .mcp:
            if let identity = mcpIdentity { return "\(identity.server): \(identity.tool)" }
            return agentTitle ?? String(localized: "MCP tool")
        case .task:
            if let description = firstString(["description", "title"]) { return String(localized: "Task: \(description)") }
            return agentTitle ?? String(localized: "Task")
        case .todo:
            return agentTitle ?? String(localized: "Update the todo list")
        case .other:
            return agentTitle ?? toolName ?? String(localized: "Tool call")
        }
    }

    private nonisolated func detail(_ category: ToolCategory, _ directory: URL) -> String? {
        switch category {
        case .command:
            return command ?? inputJSON
        case .fileChange:
            let diffs = content.compactMap { entry -> String? in
                switch entry {
                case .diff(let path, let old, let new):
                    let diff = UnifiedDiff.make(path: Self.displayPath(path, relativeTo: directory), old: old, new: new)
                    return diff.isEmpty ? nil : diff
                case .patch(let patch):
                    return patch.text.flatMap(Self.nonEmpty)
                default:
                    return nil
                }
            }
            if !diffs.isEmpty { return diffs.joined(separator: "\n") }
            return paths.isEmpty ? inputJSON : paths.joined(separator: "\n")
        case .read:
            return paths.isEmpty ? inputJSON : paths.joined(separator: "\n")
        case .search, .web, .mcp, .task, .todo, .other:
            return inputJSON
        }
    }

    /// The tool's output as text: content blocks first, then the agent's raw output.
    /// `terminalOutput` resolves terminals embedded in the content.
    public nonisolated func outputText(terminalOutput: (String) -> String? = { _ in nil }) -> String? {
        let parts = content.compactMap { entry -> String? in
            switch entry {
            case .content(let block): return block.displayText
            case .terminal(let id): return terminalOutput(id)
            case .diff, .patch, .unknown: return nil
            }
        }
        var text = parts.joined(separator: "\n")
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let raw = rawOutput.flatMap(Self.rawOutputText) {
            text = raw
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text.count > Self.maxOutputCharacters ? "…" + String(text.suffix(Self.maxOutputCharacters)) : text
    }

    nonisolated static func rawOutputText(_ value: JSONValue) -> String? {
        if let text = value.string { return text }
        guard value.object != nil else { return nil }
        for key in ["output", "text", "output_for_prompt", "combinedOutput", "combined_output", "formatted_output", "result", "content"] {
            if let text = value[key].flatMap(byteText) { return text }
        }
        let streams = ["stdout", "stderr"].compactMap { value[$0].flatMap(byteText) }
        if !streams.isEmpty { return streams.joined(separator: "\n") }
        // Grok wraps file reads and listings: {"type":"ReadFile","FileContent":{"content":…}}.
        for key in ["Content", "FileContent", "Result", "result"] {
            if let nested = value[key], let text = nested["content"].flatMap(byteText) ?? nested["output"].flatMap(byteText) {
                return text
            }
        }
        return nil
    }

    /// Text from a string, or from an array of UTF-8 bytes as Grok sends stdout.
    nonisolated static func byteText(_ value: JSONValue) -> String? {
        if let text = value.string { return text.isEmpty ? nil : text }
        guard let array = value.array, !array.isEmpty else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(array.count)
        for element in array {
            guard let number = element.acpInt, (0...255).contains(number) else { return nil }
            bytes.append(UInt8(number))
        }
        let text = String(decoding: bytes, as: UTF8.self)
        return text.isEmpty ? nil : text
    }

    /// The operation of a v2 patch that changes a single file.
    private nonisolated var patchOperation: String? {
        let changes = content.flatMap { entry -> [ACPFilePatch.Change] in
            if case .patch(let patch) = entry { return patch.changes }
            return []
        }
        return changes.count == 1 ? changes[0].operation : nil
    }

    private nonisolated var inputJSON: String? {
        guard let rawInput, rawInput.object?.isEmpty != true, !rawInput.isNull else { return nil }
        return rawInput.string ?? rawInput.prettyJSON
    }

    private nonisolated func firstString(_ keys: [String]) -> String? {
        keys.lazy.compactMap { self.rawInput?[$0]?.string.flatMap(Self.nonEmpty) }.first
    }

    nonisolated static func isGenericTitle(_ title: String) -> Bool {
        ["tool", "tool call", "terminal", "other"].contains(title.lowercased())
    }

    /// A path relative to the working directory when inside it, with the home folder as `~`.
    nonisolated static func displayPath(_ path: String, relativeTo directory: URL) -> String {
        let root = directory.standardizedFileURL.path
        if path == root { return "." }
        if path.hasPrefix(root + "/") { return String(path.dropFirst(root.count + 1)) }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    nonisolated static func truncate(_ text: String, _ limit: Int) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        return line.count > limit ? String(line.prefix(limit - 1)) + "…" : line
    }
}
