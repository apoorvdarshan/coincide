import Foundation

/// The process side of a Claude session: newline-delimited JSON over stdio. Tests use a fake.
@MainActor
protocol ClaudeTransport: AnyObject {
    var onLine: ((String) -> Void)? { get set }
    var onExit: ((_ status: Int32, _ stderrTail: String) -> Void)? { get set }
    func start() throws
    func write(_ line: String)
    func closeInput()
    func terminate()
}

@MainActor
final class ClaudeProcessTransport: ClaudeTransport {
    var onLine: ((String) -> Void)?
    var onExit: ((Int32, String) -> Void)?
    private let process: LineProcess

    init(executable: URL, arguments: [String], workingDirectory: URL, environment: [String: String]) {
        process = LineProcess(
            executable: executable, arguments: arguments, workingDirectory: workingDirectory, environment: environment)
        process.onLine = { [weak self] line in self?.onLine?(line) }
        process.onExit = { [weak self] status, stderrTail in self?.onExit?(status, stderrTail) }
    }

    func start() throws { try process.start() }
    func write(_ line: String) { process.write(line) }
    func closeInput() { process.closeInput() }
    func terminate() { process.terminate() }
}

/// The command line for one Claude Code process, as the Claude Agent SDK builds it.
struct ClaudeLaunchConfig: Sendable, Hashable {
    enum Identity: Sendable, Hashable {
        /// A new conversation under an id Coincide picks, so it is known before the first turn.
        case fresh(String)
        case resume(String)
    }

    var identity: Identity
    /// `--model`; nil lets Claude Code use its default.
    var model: String?
    var effort: ClaudeModelCatalog.EffortPlan
    var permissionMode: String
    /// Whether the process may switch into full access (bypassPermissions) later. Only processes started
    /// while the user picked full access get it, so a session in approval mode can never skip prompts.
    var allowsBypass: Bool
    /// Fast mode, which Claude Code only runs for an SDK client that opts in with the `fastMode` flag setting.
    var fastMode = false

    var sessionID: String {
        switch identity {
        case .fresh(let id), .resume(let id): id
        }
    }

    var arguments: [String] {
        var settings: [String: JSONValue] = ["showThinkingSummaries": true]
        if effort.ultracode { settings["ultracode"] = true }
        if fastMode { settings["fastMode"] = true }
        var arguments = [
            "--output-format", "stream-json", "--verbose", "--input-format", "stream-json", "--include-partial-messages",
            // Permission prompts come back over stdio as `can_use_tool` control requests.
            "--permission-prompt-tool", "stdio", "--setting-sources=user,project,local", "--permission-mode", permissionMode,
            "--thinking", "adaptive", "--thinking-display", "summarized", "--settings", JSONValue.object(settings).compactJSON,
        ]
        // Lets a plan turn under full access go back to bypassing prompts without a restart.
        if allowsBypass { arguments.append("--allow-dangerously-skip-permissions") }
        if let model { arguments += ["--model", model] }
        if let effort = effort.cliEffort { arguments += ["--effort", effort] }
        switch identity {
        case .fresh(let id): arguments.append("--session-id=\(id)")
        case .resume(let id): arguments.append("--resume=\(id)")
        }
        return arguments
    }

    /// Plan turns plan; otherwise full access bypasses prompts and approval mode asks.
    static func permissionMode(access: AccessMode, interaction: InteractionMode) -> String {
        if interaction == .plan { return "plan" }
        return access == .fullAccess ? "bypassPermissions" : "default"
    }

    /// Claude Code takes `bypassPermissions` mid-session only from a process started with
    /// `--allow-dangerously-skip-permissions`, which only full access gets.
    static func allowsBypass(access: AccessMode) -> Bool { access == .fullAccess }

    /// Variables a running Claude Code session sets for the commands it starts. When Coincide itself was
    /// started from such a session, the processes it starts must not look like that session's children.
    static let parentSessionVariables: Set<String> = [
        "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SESSION_ID", "CLAUDE_CODE_CHILD_SESSION",
        "CLAUDE_CODE_BRIDGE_SESSION_ID", "CLAUDE_CODE_MESSAGING_SOCKET", "CLAUDE_CODE_MESSAGING_TOKEN",
        "CLAUDE_CODE_SESSION_ATTENDED", "CLAUDE_CODE_EXECPATH", "CLAUDE_PID", "CLAUDE_EFFORT",
    ]

    static func environment(_ base: [String: String]) -> [String: String] {
        base.filter { !parentSessionVariables.contains($0.key) }
    }
}
