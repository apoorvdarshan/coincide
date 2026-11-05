import Foundation

/// Titles, details and markdown for Codex items, shared by the event mapper and approval prompts.
struct CodexPresentation: Sendable {
    /// Paths under the working directory are shown relative to it.
    let paths: PathDisplay

    /// The working directory as given and as Codex may report it.
    var roots: [String] { paths.roots }

    init(workingDirectory: String) {
        paths = PathDisplay(workingDirectory: workingDirectory)
    }

    func relativePath(_ path: String) -> String { paths.relative(path) }

    // MARK: Commands

    /// Classifies a command by Codex's parsed actions: pure reads and searches get their own category.
    func commandInfo(id: String, command: String, actions: [JSONValue]) -> ToolCallInfo {
        let full = Self.displayCommand(command, actions: actions)
        let display = Self.head(full)
        let types = actions.compactMap { $0["type"]?.string }
        // Codex leaves out of its actions the commands it takes for formatting (`| tee …`, `| xargs …`, `cd … &&`),
        // so a command that chains more than its actions describe is shown as the command it is.
        guard !types.isEmpty, types.count == actions.count, !types.contains("unknown"),
            Self.chainedCommandCount(full) == actions.count
        else {
            return ToolCallInfo(id: id, category: .command, title: Self.runTitle(display), detail: display)
        }
        if types.allSatisfy({ $0 == "read" }) {
            let names = actions.compactMap { $0["name"]?.string ?? $0["path"]?.string.map(relativePath) }
            return ToolCallInfo(id: id, category: .read, title: Self.readTitle(names), detail: display)
        }
        if let search = actions.first(where: { $0["type"]?.string == "search" }) {
            let title = searchTitle(query: search["query"]?.string, path: search["path"]?.string)
            return ToolCallInfo(id: id, category: .search, title: title, detail: display)
        }
        if types.allSatisfy({ $0 == "listFiles" }) {
            let path = actions.lazy.compactMap { $0["path"]?.string }.first { relativePath($0) != "." }
            let title = path.map { String(localized: "List \(relativePath($0))") } ?? String(localized: "List files")
            return ToolCallInfo(id: id, category: .search, title: title, detail: display)
        }
        // Reads mixed with listings: still only looking around.
        return ToolCallInfo(id: id, category: .read, title: Self.runTitle(display), detail: display)
    }

    /// The command as it will run, without the shell wrapper Codex adds, e.g. `npm test` for `/bin/zsh -lc 'npm test'`.
    /// Codex's parsed actions are a summary that drops pipeline stages (`cat notes | tee -a ~/.zshrc` reads as
    /// `cat notes`), so they stand in only when Codex sent no command.
    static func displayCommand(_ command: String, actions: [JSONValue]) -> String {
        let unwrapped = unwrapShell(command)
        guard unwrapped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, actions.count == 1,
            let inner = actions[0]["command"]?.string, !inner.isEmpty
        else { return unwrapped }
        return inner
    }

    /// How many commands a shell script runs, counting the ones `|`, `&&`, `||`, `;`, `&` and new lines chain
    /// outside quotes (`cat a | tee b && ls` runs three); nil when a quote is left open. Errs toward more.
    static func chainedCommandCount(_ script: String) -> Int? {
        var count = 1
        var quote: Character?
        var escaped = false
        var lastOperator: Character?
        for character in script.trimmingCharacters(in: .whitespacesAndNewlines) {
            var chain: Character?
            if escaped {
                escaped = false
            } else if let open = quote {
                if character == open {
                    quote = nil
                } else if open == "\"", character == "\\" {
                    escaped = true
                }
            } else if character == "\\" {
                escaped = true
            } else if character == "'" || character == "\"" {
                quote = character
            } else if "|&;".contains(character) || character.isNewline {
                chain = character
            }
            // `&&` and `||` chain once.
            if let chain, !(chain == lastOperator && (chain == "|" || chain == "&")) { count += 1 }
            lastOperator = chain
        }
        return quote == nil && !escaped ? count : nil
    }

    /// An argv as one command line, without a `sh -c` wrapper: `["/bin/zsh", "-lc", "make"]` → `make`.
    static func unwrapShell(argv: [String]) -> String {
        if argv.count == 3, ["-lc", "-c"].contains(argv[1]),
            argv[0].range(of: #"(?:^|/)(?:ba|z|da|k)?sh$"#, options: .regularExpression) != nil
        {
            return argv[2]
        }
        return argv.joined(separator: " ")
    }

    static func unwrapShell(_ command: String) -> String {
        guard let wrapper = command.range(of: #"^(?:\S*/)?(?:ba|z|da|k)?sh\s+-l?c\s+"#, options: .regularExpression)
        else { return command }
        return shellWord(String(command[wrapper.upperBound...])) ?? command
    }

    /// Unquotes exactly one POSIX shell word, or returns nil when the text is not a single word.
    static func shellWord(_ text: String) -> String? {
        let characters = Array(text.trimmingCharacters(in: .whitespacesAndNewlines))
        var word = ""
        var index = 0
        while index < characters.count {
            let character = characters[index]
            switch character {
            case "'":
                guard let close = characters[(index + 1)...].firstIndex(of: "'") else { return nil }
                word += String(characters[(index + 1)..<close])
                index = close + 1
            case "\"":
                index += 1
                var closed = false
                while index < characters.count {
                    let inner = characters[index]
                    if inner == "\"" {
                        closed = true
                        index += 1
                        break
                    }
                    if inner == "\\", index + 1 < characters.count, "\"\\$`\n".contains(characters[index + 1]) {
                        if characters[index + 1] != "\n" { word.append(characters[index + 1]) }
                        index += 2
                        continue
                    }
                    word.append(inner)
                    index += 1
                }
                guard closed else { return nil }
            case "\\":
                guard index + 1 < characters.count else { return nil }
                word.append(characters[index + 1])
                index += 2
            case _ where character.isWhitespace:
                return nil
            default:
                word.append(character)
                index += 1
            }
        }
        return word.isEmpty ? nil : word
    }

    static func runTitle(_ command: String) -> String {
        String(localized: "Run `\(shortened(command))`")
    }

    static func readTitle(_ names: [String]) -> String {
        switch names.count {
        case 0: String(localized: "Read files")
        case 1...3: String(localized: "Read \(names.joined(separator: ", "))")
        default: String(localized: "Read \(names.count) files")
        }
    }

    func searchTitle(query: String?, path: String?) -> String {
        guard let query, !query.isEmpty else { return String(localized: "Search files") }
        guard let path, !path.isEmpty, relativePath(path) != "." else {
            return String(localized: "Search for “\(query)”")
        }
        return String(localized: "Search for “\(query)” in \(relativePath(path))")
    }

    /// The first line, at most `limit` characters, with an ellipsis when anything was cut.
    static func shortened(_ text: String, limit: Int = 80) -> String {
        let lines = text.split(whereSeparator: \.isNewline)
        var line = (lines.first.map(String.init) ?? text).trimmingCharacters(in: .whitespaces)
        var cut = lines.count > 1
        if line.count > limit {
            line = String(line.prefix(limit - 1))
            cut = true
        }
        return cut ? line + "…" : line
    }

    /// Codex's aggregated output (its end, when very long), with the exit code when the command failed.
    static func commandOutput(_ output: String?, exitCode: Int?) -> String? {
        guard let output = output.map({ tail($0) }) else { return nil }
        guard let exitCode, exitCode != 0 else { return output }
        let separator = output.isEmpty || output.hasSuffix("\n") ? "" : "\n"
        return output + separator + String(localized: "Exit code \(exitCode)")
    }

    // MARK: Long text

    /// The text without surrounding whitespace, or nil when nothing is left.
    static func nonEmpty(_ text: String) -> String? { TerminalText.nonEmpty(text) }

    /// Outputs keep their end, like a terminal; the transcript keeps at most this much of one item.
    static let outputLimit = 150_000
    /// Inputs (commands, diffs, arguments) keep their start.
    static let detailLimit = 200_000

    /// The last `limit` characters, starting at a line break when one is near, after a note that text was cut.
    static func tail(_ text: String, limit: Int = outputLimit) -> String {
        guard text.utf8.count > limit, text.count > limit else { return text }
        var kept = text.suffix(limit)
        if let newline = kept.prefix(2_000).firstIndex(of: "\n") { kept = kept[kept.index(after: newline)...] }
        return String(localized: "[Earlier output not shown]") + "\n" + kept
    }

    /// The first `limit` characters, with a note when text was cut.
    static func head(_ text: String, limit: Int = detailLimit) -> String {
        guard text.utf8.count > limit, text.count > limit else { return text }
        return String(text.prefix(limit)) + "\n" + String(localized: "[Rest not shown]")
    }

    // MARK: File changes

    func fileChangeInfo(id: String, changes: [JSONValue]) -> ToolCallInfo {
        ToolCallInfo(id: id, category: .fileChange, title: fileChangeTitle(changes), detail: unifiedDiff(changes))
    }

    func fileChangeTitle(_ changes: [JSONValue]) -> String {
        guard changes.count == 1, let change = changes.first, let path = change["path"]?.string else {
            return changes.isEmpty ? String(localized: "Edit files") : String(localized: "Edit \(changes.count) files")
        }
        let name = relativePath(path)
        switch change.at("kind.type")?.string {
        case "add": return String(localized: "Create \(name)")
        case "delete": return String(localized: "Delete \(name)")
        default:
            if let destination = change.at("kind.move_path")?.string {
                return String(localized: "Move \(name) to \(relativePath(destination))")
            }
            return String(localized: "Edit \(name)")
        }
    }

    /// A unified diff for `FileUpdateChange`s: Codex sends hunks for updates and whole contents for added
    /// and deleted files.
    func unifiedDiff(_ changes: [JSONValue]) -> String? {
        let diffs = changes.compactMap { change -> String? in
            guard let path = change["path"]?.string else { return nil }
            return fileDiff(
                path: path, kind: change.at("kind.type")?.string, movePath: change.at("kind.move_path")?.string,
                body: change["diff"]?.string ?? "")
        }
        return diffs.isEmpty ? nil : Self.head(diffs.joined())
    }

    /// The same for the legacy `applyPatchApproval` shape, `{path: {type, content | unified_diff, move_path}}`.
    func unifiedDiff(legacyChanges: [String: JSONValue]) -> String? {
        let diffs = legacyChanges.keys.sorted().compactMap { path -> String? in
            guard let change = legacyChanges[path] else { return nil }
            return fileDiff(
                path: path, kind: change["type"]?.string, movePath: change["move_path"]?.string,
                body: change["unified_diff"]?.string ?? change["content"]?.string ?? "")
        }
        return diffs.isEmpty ? nil : Self.head(diffs.joined())
    }

    func fileDiff(path: String, kind: String?, movePath: String?, body: String) -> String {
        let old = relativePath(path)
        switch kind {
        case "add":
            return "--- /dev/null\n+++ b/\(old)\n" + Self.wholeFileHunk(body, sign: "+")
        case "delete":
            return "--- a/\(old)\n+++ /dev/null\n" + Self.wholeFileHunk(body, sign: "-")
        default:
            let hunks = body.isEmpty || body.hasSuffix("\n") ? body : body + "\n"
            if body.hasPrefix("--- ") || body.hasPrefix("diff ") { return hunks }
            return "--- a/\(old)\n+++ b/\(relativePath(movePath ?? path))\n" + hunks
        }
    }

    static func wholeFileHunk(_ content: String, sign: Character) -> String {
        guard !content.isEmpty else { return "" }
        var lines = content.components(separatedBy: "\n")
        let endsWithNewline = lines.last == ""
        if endsWithNewline { lines.removeLast() }
        let range = sign == "+" ? "-0,0 +1,\(lines.count)" : "-1,\(lines.count) +0,0"
        var hunk = "@@ \(range) @@\n" + lines.map { "\(sign)\($0)\n" }.joined()
        if !endsWithNewline { hunk += "\\ No newline at end of file\n" }
        return hunk
    }

    // MARK: Other tools

    static func mcpInfo(_ item: JSONValue, id: String) -> ToolCallInfo {
        let server = item["server"]?.string ?? "mcp"
        let tool = item["tool"]?.string ?? "tool"
        let title =
            if let app = item.at("appContext.appName")?.string, let action = item.at("appContext.actionName")?.string {
                "\(app): \(action)"
            } else {
                "\(server): \(tool)"
            }
        return ToolCallInfo(id: id, category: .mcp, title: title, detail: argumentsText(item["arguments"]))
    }

    static func dynamicToolInfo(_ item: JSONValue, id: String) -> ToolCallInfo {
        let tool = item["tool"]?.string ?? "tool"
        let title = item["namespace"]?.string.map { "\($0): \(tool)" } ?? tool
        return ToolCallInfo(id: id, category: .other, title: title, detail: argumentsText(item["arguments"]))
    }

    static func argumentsText(_ value: JSONValue?) -> String? {
        guard let value, !value.isNull else { return nil }
        if let object = value.object, object.isEmpty { return nil }
        return head(value.string ?? value.prettyJSON)
    }

    /// Text blocks of an MCP result, else its structured content.
    static func mcpResultText(_ result: JSONValue?) -> String? {
        guard let result, !result.isNull else { return nil }
        let blocks = (result["content"]?.array ?? []).compactMap { block -> String? in
            switch block["type"]?.string {
            case "text": block["text"]?.string
            case "image": String(localized: "[image]")
            case "resource_link": block["uri"]?.string
            case "resource": block.at("resource.text")?.string ?? block.at("resource.uri")?.string
            default: block.compactJSON
            }
        }
        if !blocks.isEmpty { return tail(blocks.joined(separator: "\n")) }
        if let structured = result["structuredContent"], !structured.isNull { return tail(structured.prettyJSON) }
        return nil
    }

    static func dynamicToolOutput(_ items: JSONValue?) -> String? {
        let texts = (items?.array ?? []).compactMap { item -> String? in
            switch item["type"]?.string {
            case "inputText": item["text"]?.string
            case "inputImage": String(localized: "[image]")
            case "inputAudio": String(localized: "[audio]")
            default: nil
            }
        }
        return texts.isEmpty ? nil : tail(texts.joined(separator: "\n"))
    }

    static func webSearchInfo(_ item: JSONValue, id: String) -> ToolCallInfo {
        let action = item["action"]
        let queries = action?["queries"]?.array?.compactMap(\.string).filter { !$0.isEmpty } ?? []
        let title: String
        switch action?["type"]?.string {
        case "open_page", "openPage":
            title = action?["url"]?.string.map { String(localized: "Open \($0)") } ?? String(localized: "Open a web page")
        case "find_in_page", "findInPage":
            let page = action?["url"]?.string ?? String(localized: "the page")
            title = action?["pattern"]?.string.map { String(localized: "Find “\($0)” on \(page)") }
                ?? String(localized: "Search \(page)")
        default:
            let query = [action?["query"]?.string, queries.first, item["query"]?.string].lazy.compactMap { $0 }
                .first { !$0.isEmpty }
            title = query.map { String(localized: "Search the web for “\($0)”") } ?? String(localized: "Search the web")
        }
        let detail = queries.count > 1 ? queries.joined(separator: "\n") : nil
        return ToolCallInfo(id: id, category: .web, title: title, detail: detail)
    }

    /// One line per result: its title and URL when present.
    static func webSearchResults(_ results: JSONValue?) -> String? {
        let lines = (results?.array ?? []).compactMap { result -> String? in
            let title = result["title"]?.string
            let url = result["url"]?.string
            switch (title, url) {
            case let (title?, url?): return "\(title) — \(url)"
            case let (title?, nil): return title
            case let (nil, url?): return url
            case (nil, nil): return nil
            }
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    static func collabInfo(_ item: JSONValue, id: String) -> ToolCallInfo {
        let title =
            switch item["tool"]?.string {
            case "spawnAgent": String(localized: "Start a subagent")
            case "sendInput", "sendMessage", "followupTask": String(localized: "Message a subagent")
            case "resumeAgent": String(localized: "Resume a subagent")
            case "wait": String(localized: "Wait for subagents")
            case "closeAgent": String(localized: "Close a subagent")
            case "interruptAgent": String(localized: "Interrupt a subagent")
            case "listAgents": String(localized: "List subagents")
            default: String(localized: "Subagent")
            }
        let prompt = item["prompt"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        return ToolCallInfo(id: id, category: .task, title: title, detail: prompt)
    }

    /// The subagents' latest messages, or how they ended when they have none.
    static func collabOutput(_ item: JSONValue) -> String? {
        let states = item["agentsStates"]?.object ?? [:]
        let lines = states.keys.sorted().compactMap { key -> String? in
            guard let state = states[key] else { return nil }
            if let message = state["message"]?.string.flatMap(nonEmpty) { return message }
            return switch state["status"]?.string {
            case "errored": String(localized: "The subagent failed.")
            case "interrupted": String(localized: "The subagent was interrupted.")
            case "shutdown": String(localized: "The subagent was closed.")
            case "notFound": String(localized: "The subagent was not found.")
            // Still starting or running: nothing to report yet.
            default: nil
            }
        }
        return lines.isEmpty ? nil : tail(lines.joined(separator: "\n\n"))
    }

    // MARK: Plans and messages

    /// Async questions are message items, not outstanding server requests. Reuse the native question controls
    /// but send the answer as the user's next message (or steer it into the active turn).
    static func asyncQuestions(id: String, questions: [JSONValue]) -> UserInputRequest {
        let questions = questions.enumerated().compactMap { index, question -> UserQuestion? in
            guard let prompt = question["title"]?.string.flatMap(nonEmpty) else { return nil }
            var seen = Set<String>()
            let options = (question["options"]?.array ?? []).compactMap { value -> UserQuestion.Option? in
                guard let label = value.string.flatMap(nonEmpty), seen.insert(label).inserted else { return nil }
                return .init(label: label)
            }
            return UserQuestion(id: "\(id)/\(index)", prompt: prompt, options: options)
        }
        return UserInputRequest(id: "codex-async/\(id)", questions: questions, responseMode: .userMessage)
    }

    /// Some versions include the suggested answers in both `text` and `questions`. The buttons own those
    /// options; remove only matching list entries, preserving surrounding prose and fenced code verbatim.
    static func asyncQuestionText(_ text: String, request: UserInputRequest) -> String {
        let labels = Set(request.questions.flatMap(\.options).map(\.label))
        var fence: String?
        return text.components(separatedBy: "\n").filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let marker = ["```", "~~~"].first(where: { trimmed.hasPrefix($0) }) {
                if fence == marker { fence = nil } else if fence == nil { fence = marker }
                return true
            }
            guard fence == nil else { return true }
            let entry = trimmed.replacingOccurrences(of: #"^(?:[-*+•]|\d+[.)])\s+"#, with: "", options: .regularExpression)
            return entry == trimmed || !labels.contains(entry)
        }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A notice for an MCP server that could not start, or nil while it is starting or ready.
    static func mcpStartupNotice(_ params: JSONValue) -> String? {
        guard params["status"]?.string == "failed", let name = params["name"]?.string else { return nil }
        if params["failureReason"]?.string == "reauthenticationRequired" {
            return String(
                localized: "The MCP server “\(name)” needs you to sign in again: run `codex mcp login \(name)`.")
        }
        guard let error = params["error"]?.string.flatMap(nonEmpty) else {
            return String(localized: "The MCP server “\(name)” could not start.")
        }
        return String(localized: "The MCP server “\(name)” could not start: \(error)")
    }

    /// A hook that failed or blocked Codex, with what it reported; nil for hooks that ran normally.
    static func hookNotice(_ run: JSONValue?) -> String? {
        guard let run, let status = run["status"]?.string, status == "failed" || status == "blocked" else { return nil }
        let event = run["eventName"]?.string ?? "hook"
        let summary =
            status == "blocked"
            ? String(localized: "A \(event) hook stopped Codex.") : String(localized: "A \(event) hook failed.")
        let entries = (run["entries"]?.array ?? []).filter { $0["kind"]?.string != "context" }.map { $0["text"]?.string }
        let details = ([run["statusMessage"]?.string] + entries).compactMap { $0.flatMap(nonEmpty) }
        return ([summary] + details).joined(separator: "\n")
    }

    /// `configWarning`: its summary and details.
    static func configWarning(_ params: JSONValue) -> String? {
        guard let summary = params["summary"]?.string.flatMap(nonEmpty) else { return nil }
        let details = params["details"]?.string.flatMap(nonEmpty)
        let path = params["path"]?.string.flatMap(nonEmpty)
        return [summary, details, path].compactMap { $0 }.joined(separator: "\n")
    }

    /// `turn/plan/updated` as a markdown checklist.
    static func todoMarkdown(explanation: String?, steps: [JSONValue]) -> String {
        var lines: [String] = []
        if let explanation = explanation?.trimmingCharacters(in: .whitespacesAndNewlines), !explanation.isEmpty {
            lines += [explanation, ""]
        }
        for (index, step) in steps.enumerated() {
            let text = step["step"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
            let label = text.flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "Step \(index + 1)")
            switch step["status"]?.string {
            case "completed": lines.append("- [x] \(label)")
            case "inProgress": lines.append("- [ ] \(label) _(\(String(localized: "in progress")))_")
            default: lines.append("- [ ] \(label)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// A `TurnError`'s details, falling back to its summary (T3 Code prefers the details).
    static func errorMessage(_ error: JSONValue?) -> String? {
        for key in ["additionalDetails", "message"] {
            let text = error?[key]?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let text, !text.isEmpty { return text }
        }
        return nil
    }

    static func exitMessage(status: Int32, stderr: String) -> String {
        let summary = String(localized: "Codex exited unexpectedly (status \(Int(status))).")
        guard let tail = TerminalText.tail(stderr, lines: 3, maxLength: 800) else { return summary }
        return summary + "\n" + tail
    }
}
