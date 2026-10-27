import Foundation

/// A failed git, gh or worktree operation. `message` is a short sentence for the user;
/// `detail` carries git's own explanation when it gave one.
public struct GitError: LocalizedError, Sendable, Equatable {
    public var message: String
    public var detail: String?

    public nonisolated init(_ message: String, detail: String? = nil) {
        self.message = message
        self.detail = detail
    }

    public nonisolated var errorDescription: String? { message }
    public nonisolated var failureReason: String? { detail }

    /// Shown when another process holds the index lock.
    public nonisolated static let indexLockedDetail = String(
        localized: "Git's index is locked. Wait for other Git operations to finish, then try again.")

    /// Builds an error from a failed command, keeping git's diagnostic lines.
    nonisolated static func failed(_ action: String, _ result: ProcessRunner.Result) -> GitError {
        if result.stderr.range(of: #"unable to create '[^']*index\.lock': File exists"#, options: .regularExpression) != nil {
            return GitError(action, detail: indexLockedDetail)
        }
        let lines = (result.stderr.isEmpty ? result.stdout : result.stderr)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("hint:") }
        let detail = lines.suffix(12).joined(separator: "\n")
        return GitError(action, detail: detail.isEmpty ? String(localized: "Exit status \(result.status).") : detail)
    }
}

/// Runs git and gh with the user's login-shell environment, so hooks, credential helpers and
/// Homebrew installs behave as they do in Terminal.
enum GitCLI {
    /// Variables that would point git at another repository or index than the one we pass.
    private nonisolated static let repositoryOverrides = [
        "GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR", "GIT_OBJECT_DIRECTORY",
        "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_PREFIX", "GIT_NAMESPACE",
    ]

    nonisolated static func environment(_ overrides: [String: String] = [:]) async -> [String: String] {
        var env = await ShellEnvironment.shared.environment()
        for key in repositoryOverrides { env.removeValue(forKey: key) }
        // Fail instead of waiting for a username on a stdin nobody reads.
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GH_PROMPT_DISABLED"] = "1"
        env["GH_NO_UPDATE_NOTIFIER"] = "1"
        env["NO_COLOR"] = "1"
        for (key, value) in overrides { env[key] = value }
        return env
    }

    nonisolated static func gitExecutable() async -> URL {
        await ShellEnvironment.shared.which("git") ?? URL(fileURLWithPath: "/usr/bin/git")
    }

    nonisolated static func ghExecutable() async -> URL? {
        await ShellEnvironment.shared.which("gh")
    }

    nonisolated static func git(
        _ arguments: [String], in cwd: URL, environment overrides: [String: String] = [:], input: String? = nil,
        timeout: TimeInterval = 30
    ) async -> ProcessRunner.Result {
        let executable = await gitExecutable()
        let env = await environment(overrides)
        return await ProcessRunner.run(executable, arguments, cwd: cwd, environment: env, timeout: timeout, input: input)
    }

    /// Runs git and throws a `GitError` describing `action` when it fails.
    @discardableResult
    nonisolated static func checked(
        _ action: String, _ arguments: [String], in cwd: URL, environment overrides: [String: String] = [:],
        input: String? = nil, timeout: TimeInterval = 30
    ) async throws -> String {
        let result = await git(arguments, in: cwd, environment: overrides, input: input, timeout: timeout)
        guard result.succeeded else { throw GitError.failed(action, result) }
        return result.stdout
    }

    nonisolated static func gh(
        _ arguments: [String], in cwd: URL, input: String? = nil, timeout: TimeInterval = 60
    ) async -> ProcessRunner.Result? {
        guard let executable = await ghExecutable() else { return nil }
        let env = await environment()
        return await ProcessRunner.run(executable, arguments, cwd: cwd, environment: env, timeout: timeout, input: input)
    }

    /// `git` on stderr when the folder is not inside a work tree.
    nonisolated static func isNotRepository(_ stderr: String) -> Bool {
        let lower = stderr.lowercased()
        return lower.contains("not a git repository") || lower.contains("must be run in a work tree")
    }

    /// `git` on stderr when HEAD has no commit yet.
    nonisolated static func isUnbornHead(_ stderr: String) -> Bool {
        let lower = stderr.lowercased()
        return lower.contains("unknown revision") || lower.contains("ambiguous argument 'head'")
            || lower.contains("bad revision 'head'") || lower.contains("does not have any commits yet")
            || lower.contains("not a valid object name")
    }

    /// The well-known id of the empty tree, used to diff an unborn HEAD.
    nonisolated static let emptyTree = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
}
