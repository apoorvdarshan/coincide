import Foundation

/// These are provider-owned sessions. They are never adopted as Coincide chats.
public struct ProviderSessionsScope: Hashable, Sendable {
    public let provider: ProviderKind
    public let executable: String
    public let configurationDirectory: String?
    public let workspacePath: String?

    public init(provider: ProviderKind, executable: String, configurationDirectory: String? = nil, workspacePath: String? = nil) {
        self.provider = provider
        self.executable = executable
        self.configurationDirectory = configurationDirectory
        self.workspacePath = workspacePath
    }

    func validate() throws {
        guard !executable.isEmpty, executable.utf8.count <= 4_096,
              !executable.contains("\0"), [configurationDirectory, workspacePath].compactMap({ $0 }).allSatisfy({
                  $0.hasPrefix("/") && !$0.contains("\0") && $0.utf8.count <= 4_096
              }) else { throw CoincideError("Choose a valid local Codex or Claude configuration.") }
    }

    func environment() -> [String: String] {
        var environment = ProcessChannel.environment()
        if let configurationDirectory {
            environment[provider == .codex ? "CODEX_HOME" : "CLAUDE_CONFIG_DIR"] = configurationDirectory
        }
        return environment
    }

    public var codexControlSocketPath: String {
        let environment = environment()
        let home = configurationDirectory ?? environment["CODEX_HOME"]
            ?? URL(fileURLWithPath: environment["HOME"] ?? NSHomeDirectory()).appendingPathComponent(".codex").path
        return URL(fileURLWithPath: home).appendingPathComponent("app-server-control/app-server-control.sock").path
    }
}

public enum ProviderSessionState: String, Sendable, Codable, CaseIterable {
    case running, waiting, idle, completed, stopped, failed, unknown

    public var label: String {
        switch self {
        case .running: "Running"
        case .waiting: "Waiting for input"
        case .idle: "Idle"
        case .completed: "Completed"
        case .stopped: "Stopped"
        case .failed: "Failed"
        case .unknown: "Status unavailable"
        }
    }
    public var isActive: Bool { self == .running || self == .waiting }
}

public struct ProviderSessionSummary: Identifiable, Sendable, Equatable {
    public let provider: ProviderKind
    public let nativeID: String
    public let commandID: String?
    public let title: String
    public let directory: String
    public let kind: String
    public let state: ProviderSessionState
    public let updatedAt: Date?
    public let isLoaded: Bool
    public var id: String { provider.rawValue + ":" + kind + ":" + nativeID }
    public var canStop: Bool {
        provider == .codex ? state.isActive : kind == "background" && commandID != nil && state.isActive
    }
    public var canReadOutput: Bool { provider == .codex || (kind == "background" && commandID != nil) }
}

public struct ProviderSessionsSnapshot: Sendable {
    public let sessions: [ProviderSessionSummary]
    public let hasMore: Bool
    public let checkedAt: Date
}

public struct ProviderSessionDetails: Identifiable, Sendable {
    public let session: ProviderSessionSummary
    public let output: String
    public let resumeCommand: String
    public let note: String
    public var id: String { session.id }
}

public enum ProviderSessionsService {
    public static func list(scope: ProviderSessionsScope) async throws -> ProviderSessionsSnapshot {
        try scope.validate()
        if scope.provider == .claude {
            let result = try await claude(scope: scope, arguments: ["agents", "--json", "--all"])
            let rows = try parseClaude(result.output)
            let reportedCount = try JSONDecoder().decode(JSONValue.self, from: result.output).array?.count ?? 0
            return .init(sessions: filtered(rows, scope: scope), hasMore: reportedCount > 2_000, checkedAt: Date())
        }
        return try await ProviderSessionsCodexConnection.perform(socketPath: scope.codexControlSocketPath) { connection in
            var sessions: [ProviderSessionSummary] = [], cursor: String?, seen: Set<String> = []
            for _ in 0..<4 {
                var params: [String: JSONValue] = [
                    "limit": .number(50), "useStateDbOnly": .bool(true),
                    "sortKey": .string("updated_at"), "sortDirection": .string("desc"),
                    "sourceKinds": .array(["cli", "vscode", "exec", "appServer", "subAgent", "subAgentReview", "subAgentCompact", "subAgentThreadSpawn", "subAgentOther", "unknown"].map(JSONValue.string))
                ]
                if let cursor { params["cursor"] = .string(cursor) }
                if let workspacePath = scope.workspacePath { params["cwd"] = .string(workspacePath) }
                let response = try connection.request("thread/list", params: .object(params))
                guard let rows = response["data"].array, rows.count <= 50 else { throw CoincideError("Codex returned an unsupported session list.") }
                for row in rows {
                    if let session = parseCodex(row), seen.insert(session.id).inserted { sessions.append(session) }
                }
                let next = response["nextCursor"].string
                guard let next, next != cursor, !next.isEmpty else { cursor = nil; break }
                cursor = next
            }
            return .init(sessions: filtered(sessions, scope: scope), hasMore: cursor != nil, checkedAt: Date())
        }
    }

    /// Called only after the user asks to inspect this provider-owned session.
    public static func details(scope: ProviderSessionsScope, session: ProviderSessionSummary) async throws -> ProviderSessionDetails {
        try validateSelection(scope: scope, session: session)
        if scope.provider == .claude {
            let snapshot = try await list(scope: scope)
            guard let current = snapshot.sessions.first(where: { $0.id == session.id }),
                  current.commandID == session.commandID else {
                throw CoincideError("That Claude session is no longer in this configuration. Refresh the list.")
            }
            let output: String
            if let commandID = current.commandID, current.kind == "background" {
                output = readableOutput(try await claude(scope: scope, arguments: ["logs", commandID]).text)
            } else { output = "Claude does not expose terminal output for interactive sessions through its agents command." }
            return .init(session: current, output: output, resumeCommand: resumeCommand(scope: scope, session: current),
                         note: "Recent terminal output belongs to Claude. Continuing with this command uses the original Claude conversation.")
        }
        return try await ProviderSessionsCodexConnection.perform(socketPath: scope.codexControlSocketPath) { connection in
            let current = try currentCodex(connection, scope: scope, session: session)
            let response = try connection.request("thread/turns/list", params: .object([
                "threadId": .string(session.nativeID), "limit": .number(10),
                "sortDirection": .string("desc"), "itemsView": .string("summary")
            ]))
            guard let turns = response["data"].array, turns.count <= 10 else { throw CoincideError("This Codex version does not expose recent turn details.") }
            let output = turns.reversed().map { turn -> String in
                let status = turn["status"].string ?? "unknown"
                let messages = (turn["items"].array ?? []).compactMap { item -> String? in
                    switch item["type"].string {
                    case "agentMessage": return item["text"].string.map { "Assistant: " + $0 }
                    case "userMessage":
                        let text = (item["content"].array ?? []).filter { $0["type"].string == "text" }.compactMap { $0["text"].string }.joined(separator: "\n")
                        return text.isEmpty ? nil : "You: " + text
                    default: return nil
                    }
                }.joined(separator: "\n\n")
                return "Turn · \(status)" + (messages.isEmpty ? "" : "\n\n" + messages)
            }.joined(separator: "\n\n────────\n\n")
            return .init(session: current, output: readableOutput(output.isEmpty ? "No recent turn summaries are available." : output),
                         resumeCommand: resumeCommand(scope: scope, session: current),
                         note: "Up to 10 recent turn summaries from the existing Codex daemon. Internal reasoning and tool output are not included.")
        }
    }

    /// No kill signals, daemon shutdown, resume, or turn/start are used here.
    /// A fresh read and the exact active turn ID prevent interrupting a later turn.
    public static func stop(scope: ProviderSessionsScope, session: ProviderSessionSummary) async throws {
        try validateSelection(scope: scope, session: session)
        guard session.canStop else { throw CoincideError("This session has no supported stop action.") }
        if scope.provider == .claude {
            let snapshot = try await list(scope: scope)
            guard let current = snapshot.sessions.first(where: { $0.id == session.id }), current.canStop,
                  let commandID = current.commandID, commandID == session.commandID else {
                throw CoincideError("The Claude session changed or already stopped. Refresh the list.")
            }
            _ = try await claude(scope: scope, arguments: ["stop", commandID])
        } else {
            try await ProviderSessionsCodexConnection.perform(socketPath: scope.codexControlSocketPath) { connection in
                let current = try currentCodex(connection, scope: scope, session: session)
                guard current.canStop else { throw CoincideError("The Codex session no longer has an active turn.") }
                let response = try connection.request("thread/turns/list", params: .object([
                    "threadId": .string(session.nativeID), "limit": .number(1),
                    "sortDirection": .string("desc"), "itemsView": .string("notLoaded")
                ]))
                let turnID = try activeTurnID(response)
                _ = try connection.request("turn/interrupt", params: .object([
                    "threadId": .string(session.nativeID), "turnId": .string(turnID)
                ]))
            }
        }
    }

    static func activeTurnID(_ response: JSONValue) throws -> String {
        guard let turns = response["data"].array, turns.count == 1,
              turns[0]["status"].string == "inProgress", let id = turns[0]["id"].string, validID(id) else {
            throw CoincideError("The Codex turn finished or cannot be identified. Refresh the list before stopping it.")
        }
        return id
    }

    static func parseClaude(_ data: Data) throws -> [ProviderSessionSummary] {
        guard data.count <= 4 * 1_024 * 1_024, let rows = try JSONDecoder().decode(JSONValue.self, from: data).array else {
            throw CoincideError("Claude returned an unsupported session list. Update Claude Code to a version with agents --json.")
        }
        var seen: Set<String> = []
        return rows.prefix(2_000).compactMap { row in
            guard let kind = row["kind"].string, ["background", "interactive"].contains(kind),
                  let nativeID = row["sessionId"].string, validID(nativeID),
                  let directory = directory(row["cwd"]) else { return nil }
            let commandID = row["id"].string.flatMap { validID($0) ? $0 : nil }
            let raw = row["state"].string ?? row["status"].string ?? ""
            let state: ProviderSessionState = switch raw {
            case "running", "working", "starting", "busy": .running
            case "blocked", "waiting", "waiting_for_input": .waiting
            case "idle": .idle
            case "done", "completed": .completed
            case "stopped": .stopped
            case "failed", "error": .failed
            default: .unknown
            }
            let summary = ProviderSessionSummary(provider: .claude, nativeID: nativeID, commandID: commandID,
                title: title(row["name"].string, fallback: "Claude session"), directory: directory,
                kind: kind, state: state, updatedAt: date(row["startedAt"]), isLoaded: state.isActive || kind == "interactive")
            return seen.insert(summary.id).inserted ? summary : nil
        }
    }

    static func parseCodex(_ row: JSONValue) -> ProviderSessionSummary? {
        guard let id = row["id"].string, validID(id), let directory = directory(row["cwd"]) else { return nil }
        let status = row["status"]["type"].string
        let state: ProviderSessionState = switch status {
        case "active": (row["status"]["activeFlags"].array ?? []).isEmpty ? .running : .waiting
        case "idle": .idle
        case "systemError": .failed
        default: .unknown
        }
        return .init(provider: .codex, nativeID: id, commandID: nil,
                     title: title(row["name"].string ?? row["agentNickname"].string ?? row["preview"].string, fallback: "Codex session"),
                     directory: directory, kind: row["parentThreadId"].string == nil ? "session" : "subagent",
                     state: state, updatedAt: date(row["updatedAt"]), isLoaded: status != "notLoaded" && status != nil)
    }

    static func resumeCommand(scope: ProviderSessionsScope, session: ProviderSessionSummary) -> String {
        var words: [String] = []
        if let directory = scope.configurationDirectory {
            words += ["env", (scope.provider == .codex ? "CODEX_HOME=" : "CLAUDE_CONFIG_DIR=") + directory]
        }
        words += [scope.executable]
        if session.provider == .claude, session.kind == "background", let id = session.commandID { words += ["attach", id] }
        else { words += [session.provider == .codex ? "resume" : "--resume", session.nativeID] }
        let command = words.map { "'" + $0.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }.joined(separator: " ")
        guard session.directory.hasPrefix("/"), !session.directory.contains("\0") else { return command }
        return "cd -- '" + session.directory.replacingOccurrences(of: "'", with: "'\"'\"'") + "' && " + command
    }

    private static func currentCodex(_ connection: ProviderSessionsCodexConnection, scope: ProviderSessionsScope, session: ProviderSessionSummary) throws -> ProviderSessionSummary {
        let response = try connection.request("thread/read", params: .object(["threadId": .string(session.nativeID), "includeTurns": .bool(false)]))
        guard let current = parseCodex(response["thread"]), current.nativeID == session.nativeID,
              scope.workspacePath == nil || current.directory == scope.workspacePath else {
            throw CoincideError("That Codex session is no longer in this configuration. Refresh the list.")
        }
        return current
    }

    private static func claude(scope: ProviderSessionsScope, arguments: [String]) async throws -> CommandResult {
        do {
            let result = try await CommandRunner.run(scope.executable, arguments,
                cwd: scope.workspacePath.map { URL(fileURLWithPath: $0) }, limit: 4 * 1_024 * 1_024,
                timeout: .seconds(15), environment: scope.environment())
            guard result.status == 0 else { throw CoincideError("Claude could not complete this session action. Check that the configured CLI supports agents, logs and stop.") }
            return result
        } catch is CancellationError { throw CancellationError() }
        catch { throw CoincideError("Claude could not complete this session action. Check the configured CLI and refresh the list.") }
    }

    private static func validateSelection(scope: ProviderSessionsScope, session: ProviderSessionSummary) throws {
        try scope.validate()
        guard scope.provider == session.provider, validID(session.nativeID), session.commandID.map(validID) ?? true,
              scope.workspacePath == nil || session.directory == scope.workspacePath else {
            throw CoincideError("Choose a session from the current provider configuration.")
        }
    }
    private static func filtered(_ rows: [ProviderSessionSummary], scope: ProviderSessionsScope) -> [ProviderSessionSummary] {
        rows.filter { scope.workspacePath == nil || $0.directory == scope.workspacePath }.sorted {
            if $0.state.isActive != $1.state.isActive { return $0.state.isActive }
            return ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast)
        }
    }
    private static func validID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value.first != "-" && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }
    private static func title(_ value: String?, fallback: String) -> String {
        let bounded = TranscriptOutputTail.head(value ?? "", maxLines: 1, maxBytes: 1_024).text
        let text = String(bounded.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
        return text.isEmpty ? fallback : String(text.prefix(160))
    }
    private static func directory(_ value: JSONValue) -> String? {
        if value == .null { return "" }
        guard let path = value.string, path.isEmpty || path.hasPrefix("/"),
              path.utf8.count <= 4_096, !path.contains("\0") else { return nil }
        return path
    }
    private static func date(_ value: JSONValue) -> Date? {
        guard case .number(let stamp) = value, stamp.isFinite, stamp > 0 else { return nil }
        let seconds = stamp > 10_000_000_000 ? stamp / 1_000 : stamp
        guard seconds <= 253_402_300_799 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
    static func readableOutput(_ value: String) -> String {
        let bounded = TranscriptOutputTail.tail(value, maxLines: .max, maxBytes: 64 * 1_024).text
        let noANSI = bounded.replacingOccurrences(of: "\\x1B(?:\\[[0-?]*[ -/]*[@-~]|\\][^\\x07\\x1B]*(?:\\x07|\\x1B\\\\))", with: "", options: .regularExpression)
        return String(noANSI.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) || $0 == "\n" || $0 == "\t" })
    }
}
