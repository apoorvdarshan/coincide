import Foundation
import Synchronization

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

    /// Set once the developer tools were found, after which `/usr/bin/git` is no longer checked.
    private nonisolated static let developerToolsFound = Mutex(false)

    /// The git to run, or nil when no usable git is installed. `/usr/bin/git` is a shim that brings
    /// up the "install the command line developer tools" dialog when they are missing, so it only
    /// counts once they are installed. A missing answer is not remembered, so installing the tools
    /// takes effect without a restart.
    nonisolated static func gitExecutable() async -> URL? {
        guard let git = await ShellEnvironment.shared.which("git") else { return nil }
        guard git.standardizedFileURL.path == "/usr/bin/git", !developerToolsFound.withLock({ $0 }) else { return git }
        let tools = await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/xcode-select"), ["-p"], timeout: 5)
        guard tools.succeeded else { return nil }
        developerToolsFound.withLock { $0 = true }
        return git
    }

    /// What a git call reports when no usable git is installed. `isNotRepository` matches it, so
    /// status reads treat the folder as having no repository.
    nonisolated static let gitMissingMessage = String(
        localized: "Git is not installed. Install Apple's command line developer tools to use Git in Coincide.")

    private nonisolated static var gitMissingResult: ProcessRunner.Result {
        ProcessRunner.Result(status: 127, stdout: "", stderr: gitMissingMessage)
    }

    nonisolated static func ghExecutable() async -> URL? {
        await ShellEnvironment.shared.which("gh")
    }

    nonisolated static func git(
        _ arguments: [String], in cwd: URL, environment overrides: [String: String] = [:], input: String? = nil,
        timeout: TimeInterval = 30
    ) async -> ProcessRunner.Result {
        guard let executable = await gitExecutable() else { return gitMissingResult }
        let env = await environment(overrides)
        return await ProcessRunner.run(executable, arguments, cwd: cwd, environment: env, timeout: timeout, input: input)
    }

    /// Runs git keeping at most `maxOutputBytes` of its standard output. Once more arrives, git is
    /// stopped and the run counts as succeeded with `truncated` set, so a huge patch is never read
    /// into memory in full.
    nonisolated static func git(
        _ arguments: [String], in cwd: URL, environment overrides: [String: String] = [:], timeout: TimeInterval = 30,
        maxOutputBytes: Int
    ) async -> (result: ProcessRunner.Result, truncated: Bool) {
        guard let executable = await gitExecutable() else { return (result: gitMissingResult, truncated: false) }
        let env = await environment(overrides)
        return await CappedRun.run(
            executable, arguments, cwd: cwd, environment: env, timeout: timeout, maxOutputBytes: maxOutputBytes)
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

    /// Runs another host tool (`glab`, `az`, `tea`) with git's environment plus `overrides`, or returns
    /// nil when it is not installed.
    nonisolated static func tool(
        _ name: String, _ arguments: [String], in cwd: URL, environment overrides: [String: String] = [:],
        input: String? = nil, timeout: TimeInterval = 60
    ) async -> ProcessRunner.Result? {
        guard let executable = await ShellEnvironment.shared.which(name) else { return nil }
        let env = await environment(overrides)
        return await ProcessRunner.run(executable, arguments, cwd: cwd, environment: env, timeout: timeout, input: input)
    }

    /// `git` on stderr when the folder is not inside a work tree, or no git is installed.
    nonisolated static func isNotRepository(_ stderr: String) -> Bool {
        let lower = stderr.lowercased()
        return lower.contains("not a git repository") || lower.contains("must be run in a work tree")
            || stderr == gitMissingMessage
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

/// One `GitCLI.git(…, maxOutputBytes:)` call: like `ProcessRunner.run`, but standard output stops
/// growing at the cap and git is stopped (with anything it started) once the cap is exceeded.
/// Resumes the caller once git has exited and both pipes are drained.
private final class CappedRun: @unchecked Sendable {
    /// Standard error is only read for diagnostics; its tail is enough.
    private nonisolated static let maxErrorBytes = 64 * 1024

    private let lock = NSLock()
    private let limit: Int
    private var continuation: CheckedContinuation<(result: ProcessRunner.Result, truncated: Bool), Never>?
    private var stdout = Data()
    private var stderr = Data()
    private var status: Int32?
    private var stdoutOpen = true
    private var stderrOpen = true
    private var truncated = false
    private var didTimeOut = false

    private nonisolated init(
        limit: Int, continuation: CheckedContinuation<(result: ProcessRunner.Result, truncated: Bool), Never>
    ) {
        self.limit = max(0, limit)
        self.continuation = continuation
    }

    nonisolated static func run(
        _ executable: URL, _ arguments: [String], cwd: URL, environment: [String: String], timeout: TimeInterval,
        maxOutputBytes: Int
    ) async -> (result: ProcessRunner.Result, truncated: Bool) {
        await withCheckedContinuation { continuation in
            let run = CappedRun(limit: maxOutputBytes, continuation: continuation)
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.currentDirectoryURL = cwd
            process.environment = environment
            process.standardInput = FileHandle.nullDevice
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            for (pipe, isStdout) in [(stdout, true), (stderr, false)] {
                pipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if data.isEmpty {
                        handle.readabilityHandler = nil
                        run.closed(stdout: isStdout)
                    } else if run.append(data, stdout: isStdout), process.isRunning {
                        // Past the cap: stop git instead of reading the rest. Reading goes on (and drops
                        // what arrives) until the pipe closes.
                        ProcessTree.terminateTree(process.processIdentifier, grace: 3)
                    }
                }
            }
            process.terminationHandler = { process in
                run.exited(process.terminationStatus)
                // A helper git left running can hold the pipes open; don't wait on it for long.
                DispatchQueue.global().asyncAfter(deadline: .now() + LineProcess.drainTimeout) {
                    stdout.fileHandleForReading.readabilityHandler = nil
                    stderr.fileHandleForReading.readabilityHandler = nil
                    run.closed(stdout: true)
                    run.closed(stdout: false)
                }
            }
            do {
                try process.run()
            } catch {
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                run.fail(error.localizedDescription)
                return
            }
            let pid = process.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard process.isRunning else { return }
                run.timedOut()
                ProcessTree.terminateTree(pid, grace: 3)
            }
        }
    }

    /// Keeps `data`, up to the cap for standard output. Returns true once, when output first goes past the cap.
    nonisolated func append(_ data: Data, stdout isStdout: Bool) -> Bool {
        lock.withLock {
            guard isStdout else {
                stderr.append(data)
                if stderr.count > Self.maxErrorBytes { stderr = Data(stderr.suffix(Self.maxErrorBytes)) }
                return false
            }
            guard !truncated else { return false }
            guard stdout.count + data.count > limit else {
                stdout.append(data)
                return false
            }
            stdout.append(data.prefix(limit - stdout.count))
            truncated = true
            return true
        }
    }

    nonisolated func closed(stdout isStdout: Bool) {
        lock.lock()
        if isStdout { stdoutOpen = false } else { stderrOpen = false }
        finishIfDone()
    }

    nonisolated func exited(_ code: Int32) {
        lock.lock()
        status = code
        finishIfDone()
    }

    nonisolated func timedOut() {
        lock.withLock { didTimeOut = true }
    }

    nonisolated func fail(_ message: String) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(
            returning: (result: ProcessRunner.Result(status: -1, stdout: "", stderr: message), truncated: false))
    }

    /// Called with the lock held; releases it. Output is released here, so a timeout that is still
    /// pending does not keep it alive.
    private nonisolated func finishIfDone() {
        guard let status, !stdoutOpen, !stderrOpen, let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        var errorText = String(decoding: stderr, as: UTF8.self)
        if didTimeOut { errorText += "\nThe command timed out." }
        // Stopping git at the cap is not a failure: everything up to the cap was read.
        let result = ProcessRunner.Result(
            status: truncated && !didTimeOut ? 0 : status, stdout: String(decoding: stdout, as: UTF8.self),
            stderr: errorText)
        let truncated = truncated
        stdout = Data()
        stderr = Data()
        lock.unlock()
        continuation.resume(returning: (result: result, truncated: truncated))
    }
}
