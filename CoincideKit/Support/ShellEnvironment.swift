import Foundation

/// GUI apps launched from Finder get a minimal PATH. Agent CLIs live wherever the user's
/// shell puts them (Homebrew, npm, bun, ~/.local/bin), so Coincide asks the login shell once.
public final class ShellEnvironment: @unchecked Sendable {
    public static let shared = ShellEnvironment()

    private let lock = NSLock()
    private var cached: [String: String]?

    nonisolated init() {}

    public nonisolated func environment() async -> [String: String] {
        if let cached = lock.withLock({ cached }) { return cached }
        var env = ProcessInfo.processInfo.environment
        if let shellEnv = await Self.loginShellEnvironment() {
            for (key, value) in shellEnv where !Self.ignoredKeys.contains(key) {
                env[key] = value
            }
        }
        env["PATH"] = Self.mergedPath(env["PATH"] ?? "")
        env["TERM"] = env["TERM"] ?? "xterm-256color"
        // Never let a child agent think it is nested inside another Claude Code session
        // (Coincide may itself be started from one).
        for key in Self.parentAgentKeys { env.removeValue(forKey: key) }
        env.removeValue(forKey: "COINCIDE_RESOLVING_ENVIRONMENT")
        let result = env
        lock.withLock { cached = result }
        return result
    }

    /// Finds an executable on the resolved PATH.
    public nonisolated func which(_ name: String) async -> URL? {
        if name.hasPrefix("/") || name.hasPrefix("~") {
            let path = (name as NSString).expandingTildeInPath
            return FileManager.default.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
        }
        let path = await environment()["PATH"] ?? ""
        for dir in path.split(separator: ":") {
            let candidate = (String(dir) as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        return nil
    }

    public nonisolated func invalidate() {
        lock.withLock { cached = nil }
    }

    private static let ignoredKeys: Set<String> = ["PWD", "OLDPWD", "SHLVL", "_", "TERM_PROGRAM", "TERM_SESSION_ID"]

    private static let parentAgentKeys = [
        "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SESSION_ID", "CLAUDE_CODE_CHILD_SESSION",
        "CLAUDE_CODE_BRIDGE_SESSION_ID", "CLAUDE_CODE_MESSAGING_SOCKET", "CLAUDE_CODE_MESSAGING_TOKEN",
        "CLAUDE_CODE_SESSION_ATTENDED", "CLAUDE_CODE_EXECPATH", "CLAUDE_PID", "CLAUDE_EFFORT",
    ]

    private nonisolated static func mergedPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let extras = [
            "/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.bun/bin",
            "\(home)/.npm-global/bin", "\(home)/.cargo/bin", "\(home)/.grok/bin", "\(home)/.opencode/bin",
            "\(home)/.cursor/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        ]
        var seen = Set<String>()
        var parts: [String] = []
        for entry in path.split(separator: ":").map(String.init) + extras where !entry.isEmpty && !seen.contains(entry) {
            seen.insert(entry)
            parts.append(entry)
        }
        return parts.joined(separator: ":")
    }

    private nonisolated static func userShell() -> String {
        if let pw = getpwuid(getuid()), let shell = pw.pointee.pw_shell {
            let path = String(cString: shell)
            if ["zsh", "bash", "fish", "sh"].contains((path as NSString).lastPathComponent),
                FileManager.default.isExecutableFile(atPath: path)
            {
                return path
            }
        }
        return "/bin/zsh"
    }

    private nonisolated static func loginShellEnvironment() async -> [String: String]? {
        let shell = userShell()
        let start = "__COINCIDE_ENV_START__"
        let end = "__COINCIDE_ENV_END__"
        let command = "printf '\(start)'; /usr/bin/env; printf '\(end)'"
        let isFish = shell.hasSuffix("fish")
        let args = isFish ? ["-l", "-c", command] : ["-l", "-i", "-c", command]
        var baseEnv = ProcessInfo.processInfo.environment
        baseEnv["COINCIDE_RESOLVING_ENVIRONMENT"] = "1"
        let result = await ProcessRunner.run(URL(fileURLWithPath: shell), args, environment: baseEnv, timeout: 8)
        guard let startRange = result.stdout.range(of: start),
            let endRange = result.stdout.range(of: end, range: startRange.upperBound..<result.stdout.endIndex)
        else { return nil }
        let body = result.stdout[startRange.upperBound..<endRange.lowerBound]
        var env: [String: String] = [:]
        for line in body.split(separator: "\n") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[line.startIndex..<eq])
            guard key.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil else { continue }
            env[key] = String(line[line.index(after: eq)...])
        }
        return env.isEmpty ? nil : env
    }
}
