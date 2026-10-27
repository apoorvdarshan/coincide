import Foundation

/// GUI apps launched from Finder get a minimal PATH. Agent CLIs live wherever the user's
/// shell puts them (Homebrew, npm, bun, ~/.local/bin), so Coincide asks the login shell once.
///
/// Concurrent callers share one resolution. When the login shell cannot be read (it timed out, or
/// its startup files fail), a fallback environment is used and the shell is asked again a minute later.
public final class ShellEnvironment: @unchecked Sendable {
    public static let shared = ShellEnvironment()

    private struct Resolved {
        var environment: [String: String]
        var fromShell: Bool
        var at: Date
    }

    /// How long the fallback environment is kept before the login shell is tried again.
    nonisolated static let retryAfterFailure: TimeInterval = 60

    private let lock = NSLock()
    private var cached: Resolved?
    private var resolving: Task<Resolved, Never>?
    private let resolve: @Sendable () async -> [String: String]?

    /// `resolve` returns the login shell's variables, or nil when the shell could not be read.
    nonisolated init(resolve: @escaping @Sendable () async -> [String: String]? = { await ShellEnvironment.loginShellEnvironment() }) {
        self.resolve = resolve
    }

    public nonisolated func environment() async -> [String: String] {
        let task: Task<Resolved, Never> = lock.withLock {
            if let cached, cached.fromShell || Date().timeIntervalSince(cached.at) < Self.retryAfterFailure {
                return Task { cached }
            }
            if let resolving { return resolving }
            let resolve = resolve
            let task = Task.detached { () -> Resolved in
                let shell = await resolve()
                return Resolved(environment: Self.merged(shell: shell), fromShell: shell != nil, at: Date())
            }
            resolving = task
            return task
        }
        let resolved = await task.value
        lock.withLock {
            if resolving == task {
                resolving = nil
                cached = resolved
            }
        }
        return resolved.environment
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

    /// Forgets the resolved environment, so the next call asks the login shell again.
    public nonisolated func invalidate() {
        lock.withLock { cached = nil }
    }

    private static let ignoredKeys: Set<String> = ["PWD", "OLDPWD", "SHLVL", "_", "TERM_PROGRAM", "TERM_SESSION_ID"]

    private static let parentAgentKeys = [
        "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SESSION_ID", "CLAUDE_CODE_CHILD_SESSION",
        "CLAUDE_CODE_BRIDGE_SESSION_ID", "CLAUDE_CODE_MESSAGING_SOCKET", "CLAUDE_CODE_MESSAGING_TOKEN",
        "CLAUDE_CODE_SESSION_ATTENDED", "CLAUDE_CODE_EXECPATH", "CLAUDE_PID", "CLAUDE_EFFORT",
    ]

    /// Coincide's own environment with the login shell's on top, a PATH that also covers the usual
    /// install folders, and nothing that would make an agent think it runs inside another one.
    nonisolated static func merged(shell: [String: String]?) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        for (key, value) in shell ?? [:] where !ignoredKeys.contains(key) {
            env[key] = value
        }
        env["PATH"] = mergedPath(env["PATH"] ?? "")
        env["TERM"] = env["TERM"] ?? "xterm-256color"
        // Never let a child agent think it is nested inside another Claude Code session
        // (Coincide may itself be started from one).
        for key in parentAgentKeys { env.removeValue(forKey: key) }
        env.removeValue(forKey: "COINCIDE_RESOLVING_ENVIRONMENT")
        return env
    }

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

    // MARK: Login shell

    private nonisolated static let startMarker = "__COINCIDE_ENV_START__"
    private nonisolated static let endMarker = "__COINCIDE_ENV_END__"

    /// The user's login shell from the user database.
    private nonisolated static func userShell() -> String? {
        guard let pw = getpwuid(getuid()), let shell = pw.pointee.pw_shell else { return nil }
        let path = String(cString: shell)
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    /// How to run `command` in `shell` as a login shell that also reads its interactive startup files,
    /// where PATH is usually set. Nil for shells Coincide does not know how to drive.
    nonisolated static func arguments(forShell shell: String, command: String) -> [String]? {
        switch (shell as NSString).lastPathComponent {
        case "zsh", "bash", "sh", "ksh", "ksh93", "mksh", "dash", "yash", "xonsh": ["-l", "-i", "-c", command]
        case "fish", "nu": ["-l", "-c", command]
        // csh reads its startup files for every shell and accepts -l only on its own.
        case "tcsh", "csh", "elvish": ["-c", command]
        case "pwsh", "pwsh-preview": ["-Login", "-NoLogo", "-NonInteractive", "-Command", command]
        default: nil
        }
    }

    /// The variables the user's login shell sets, or nil when no shell could be read. A shell Coincide
    /// cannot drive, or one whose startup fails, falls back to zsh.
    nonisolated static func loginShellEnvironment() async -> [String: String]? {
        // External commands by path, so aliases and shell functions cannot change the output.
        let command = "/usr/bin/printf '\(startMarker)'; /usr/bin/env -0; /usr/bin/printf '\(endMarker)'"
        var shells: [String] = []
        if let shell = userShell(), arguments(forShell: shell, command: command) != nil { shells.append(shell) }
        if !shells.contains("/bin/zsh") { shells.append("/bin/zsh") }
        var baseEnv = ProcessInfo.processInfo.environment
        baseEnv["COINCIDE_RESOLVING_ENVIRONMENT"] = "1"
        for shell in shells {
            guard let arguments = arguments(forShell: shell, command: command) else { continue }
            let result = await ProcessRunner.run(URL(fileURLWithPath: shell), arguments, environment: baseEnv, timeout: 8)
            if let env = parse(result.stdout) { return env }
        }
        return nil
    }

    /// Reads `env -0` output between the markers: NUL-separated `NAME=value` entries, whose values may
    /// span lines.
    nonisolated static func parse(_ output: String) -> [String: String]? {
        guard let startRange = output.range(of: startMarker),
            let endRange = output.range(of: endMarker, range: startRange.upperBound..<output.endIndex)
        else { return nil }
        var env: [String: String] = [:]
        for entry in output[startRange.upperBound..<endRange.lowerBound].split(separator: "\0") {
            guard let eq = entry.firstIndex(of: "=") else { continue }
            let key = String(entry[entry.startIndex..<eq])
            guard key.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil else { continue }
            env[key] = String(entry[entry.index(after: eq)...])
        }
        return env.isEmpty ? nil : env
    }
}
