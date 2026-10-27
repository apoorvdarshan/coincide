import Foundation

/// How OpenCode 2's tools appear in the transcript: category, title, detail and result.
enum OpenCodeTools {
    nonisolated static func category(for name: String) -> ToolCategory {
        let name = name.lowercased()
        switch name {
        case "shell", "bash": return .command
        case "edit", "write", "patch", "apply_patch", "multiedit": return .fileChange
        case "read": return .read
        case "glob", "grep", "list", "lsp", "codesearch": return .search
        case "webfetch", "websearch": return .web
        case "subagent", "task": return .task
        case "todowrite", "todo": return .todo
        case "execute": return .mcp
        default:
            if name.contains("shell") || name.contains("bash") { return .command }
            if name.hasPrefix("mcp") { return .mcp }
            return .other
        }
    }

    /// The tool call as shown before and while it runs. `input` is empty until OpenCode reports the call.
    /// Paths in the title are shown relative to the working directory when `paths` is given.
    nonisolated static func info(id: String, name: String, input: [String: JSONValue], paths: PathDisplay? = nil) -> ToolCallInfo {
        let category = category(for: name)
        return ToolCallInfo(
            id: id, category: category, title: title(name: name, category: category, input: input, paths: paths),
            detail: detail(name: name, category: category, input: input))
    }

    nonisolated static func title(
        name: String, category: ToolCategory, input: [String: JSONValue], paths: PathDisplay? = nil
    ) -> String {
        func path(_ keys: String...) -> String? {
            keys.lazy.compactMap { string(input, $0) }.first.map { paths?.relative($0) ?? $0 }
        }
        switch category {
        case .command:
            guard let command = string(input, "command", "cmd") else { return String(localized: "Run command") }
            return String(localized: "Run `\(shortened(firstLine(command), limit: 80))`")
        case .fileChange:
            if let path = path("path", "filePath", "file") {
                return name == "write" ? String(localized: "Write \(path)") : String(localized: "Edit \(path)")
            }
            let files = patchFiles(string(input, "patchText", "patch") ?? "").map { paths?.relative($0) ?? $0 }
            if !files.isEmpty { return String(localized: "Edit \(files.joined(separator: ", "))") }
            return name == "write" ? String(localized: "Write file") : String(localized: "Edit file")
        case .read:
            guard let path = path("path", "filePath", "file") else { return String(localized: "Read file") }
            return String(localized: "Read \(path)")
        case .search:
            let pattern = string(input, "pattern", "query")
            let root = path("path", "include")
            switch (name, pattern, root) {
            case ("glob", let pattern?, let root?): return String(localized: "Find `\(pattern)` in \(root)")
            case ("glob", let pattern?, nil): return String(localized: "Find `\(pattern)`")
            case (_, let pattern?, let root?): return String(localized: "Search for `\(pattern)` in \(root)")
            case (_, let pattern?, nil): return String(localized: "Search for `\(pattern)`")
            default: return String(localized: "Search files")
            }
        case .web:
            if let url = string(input, "url") { return String(localized: "Fetch \(url)") }
            if let query = string(input, "query") { return String(localized: "Search the web for “\(query)”") }
            return String(localized: "Web request")
        case .task:
            guard let description = string(input, "description") else { return String(localized: "Subagent") }
            return String(localized: "Subagent: \(description)")
        case .mcp:
            return name == "execute" ? String(localized: "Run tool code") : name
        case .todo:
            return String(localized: "Update todos")
        case .other:
            if name == "skill", let skill = string(input, "id", "name") { return String(localized: "Load skill \(skill)") }
            return name
        }
    }

    nonisolated static func detail(name: String, category: ToolCategory, input: [String: JSONValue]) -> String? {
        guard !input.isEmpty else { return nil }
        switch category {
        case .command:
            return string(input, "command", "cmd")
        case .fileChange:
            if let path = string(input, "path", "filePath", "file"), let old = input["oldString"]?.string,
                let new = input["newString"]?.string
            {
                return unifiedDiff(path: path, old: old, new: new)
            }
            return string(input, "patchText", "patch") ?? input["content"]?.string
        case .read:
            guard let path = string(input, "path", "filePath", "file") else { return nil }
            let offset = input["offset"]?.int
            let limit = input["limit"]?.int
            switch (offset, limit) {
            case (let offset?, let limit?): return String(localized: "\(path), lines \(offset)–\(offset + limit - 1)")
            case (let offset?, nil): return String(localized: "\(path), from line \(offset)")
            default: return path
            }
        case .task:
            return string(input, "prompt") ?? JSONValue.object(input).prettyJSON
        case .search, .web:
            return JSONValue.object(input).prettyJSON
        case .mcp:
            return string(input, "code") ?? JSONValue.object(input).prettyJSON
        case .todo, .other:
            return JSONValue.object(input).prettyJSON
        }
    }

    /// The result of a finished call. Shell commands that exit non-zero count as failed.
    nonisolated static func completion(
        name: String, content: JSONValue?, metadata: JSONValue?
    ) -> (status: ItemStatus, output: String) {
        var output = text(of: content)
        switch category(for: name) {
        case .command:
            if let exit = metadata?["exit"]?.int, exit != 0 {
                output += (output.isEmpty || output.hasSuffix("\n") ? "" : "\n") + String(localized: "Exit code \(exit)")
                return (.failed, output)
            }
        case .task:
            output = subagentResult(output)
        default:
            break
        }
        return (.completed, output)
    }

    /// The real unified diff of an edit, from tool or permission metadata (`files[].patch`).
    nonisolated static func diff(fromMetadata metadata: JSONValue?) -> String? {
        let patches = (metadata?["files"]?.array ?? []).compactMap { $0["patch"]?.string }.filter { !$0.isEmpty }
        return patches.isEmpty ? nil : patches.joined(separator: "\n")
    }

    /// A `todowrite` call's list as a markdown checklist.
    nonisolated static func todoMarkdown(_ input: [String: JSONValue]) -> String? {
        guard let todos = input["todos"]?.array else { return nil }
        let lines = todos.compactMap { todo -> String? in
            guard let content = todo["content"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !content.isEmpty
            else { return nil }
            switch todo["status"]?.string {
            case "completed": return "- [x] \(content)"
            case "in_progress": return "- [ ] **\(content)**"
            case "cancelled": return "- [x] ~~\(content)~~"
            default: return "- [ ] \(content)"
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Text parts of a tool result, joined.
    nonisolated static func text(of content: JSONValue?) -> String {
        (content?.array ?? []).compactMap { part in
            part["type"]?.string == "text" ? part["text"]?.string : nil
        }.joined(separator: "\n")
    }

    /// Strips the `<subagent …>` wrapper OpenCode puts around a subagent's answer.
    nonisolated static func subagentResult(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let match = trimmed.wholeMatch(of: /<subagent\b[^>]*>\n?([\s\S]*?)\n?<\/subagent>/) else { return text }
        return String(match.1)
    }

    /// Title for a permission request, preferring the tool call it belongs to.
    nonisolated static func permissionTitle(action: String, resources: [String], tool: ToolCallInfo?) -> String {
        if let tool, action == "shell" || action == "edit" || tool.category == .web { return tool.title }
        let target = resources.joined(separator: ", ")
        switch action {
        case "shell":
            return target.isEmpty
                ? String(localized: "Run a command") : String(localized: "Run `\(shortened(target, limit: 80))`")
        case "edit": return target.isEmpty ? String(localized: "Edit files") : String(localized: "Edit \(target)")
        case "read": return target.isEmpty ? String(localized: "Read files") : String(localized: "Read \(target)")
        case "external_directory":
            return target.isEmpty
                ? String(localized: "Access files outside the project")
                : String(localized: "Access \(target) outside the project")
        case "webfetch", "websearch":
            return target.isEmpty ? String(localized: "Use the web") : String(localized: "Fetch \(target)")
        default:
            return target.isEmpty ? String(localized: "Allow \(action)") : String(localized: "Allow \(action): \(target)")
        }
    }

    nonisolated static func permissionCategory(action: String, tool: ToolCallInfo?) -> ToolCategory {
        if let tool { return tool.category }
        switch action {
        case "shell": return .command
        case "edit": return .fileChange
        case "read", "external_directory": return .read
        case "glob", "grep", "lsp": return .search
        case "webfetch", "websearch": return .web
        default: return category(for: action)
        }
    }

    // MARK: Helpers

    nonisolated static func string(_ input: [String: JSONValue], _ keys: String...) -> String? {
        for key in keys {
            if let value = input[key]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value
            }
        }
        return nil
    }

    /// A unified diff for an edit that replaces `old` with `new`. Line numbers are unknown, so the hunk
    /// starts at line 1; the real patch replaces it once the edit is applied.
    nonisolated static func unifiedDiff(path: String, old: String, new: String) -> String {
        let oldLines = old.isEmpty ? [] : old.components(separatedBy: "\n")
        let newLines = new.isEmpty ? [] : new.components(separatedBy: "\n")
        var lines = ["--- a/\(path)", "+++ b/\(path)", "@@ -1,\(oldLines.count) +1,\(newLines.count) @@"]
        lines += oldLines.map { "-" + $0 }
        lines += newLines.map { "+" + $0 }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Files named in an apply_patch body.
    nonisolated static func patchFiles(_ patch: String) -> [String] {
        patch.split(whereSeparator: \.isNewline).compactMap { line in
            for marker in ["*** Update File: ", "*** Add File: ", "*** Delete File: "] where line.hasPrefix(marker) {
                return line.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
            }
            return nil
        }
    }

    nonisolated static func firstLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
    }

    nonisolated static func shortened(_ text: String, limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit - 1)) + "…" : text
    }
}
