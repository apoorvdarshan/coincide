import Darwin
import Foundation

/// Bounded, local-only Git with owned process-group cancellation and complete exit/pipe draining.
struct GitWorktreeCommand: Sendable {
    let environment: [String: String]?
    let executable: URL?
    func run(_ arguments: [String], cwdFD: Int32, timeout: Duration = .seconds(30), maximumOutput: Int = 1_048_576,
             gitDirectory: String? = nil, commonDirectory: String? = nil, workTree: String? = nil,
             allowedProtocols: String = "", checkpointIndexPath: String? = nil, allowTruncatedOutput: Bool = false,
             trustedInputFD: Int32? = nil, checkpointObjectDirectory: String? = nil) async throws -> GitWorktreeCommandResult {
        try Task.checkCancellation()
        guard let git = executable ?? ProcessChannel.findExecutable("git") else { throw GitWorktreeError(.commandFailed, "Git is not installed.") }
        var env = environment ?? ProcessChannel.environment()
        for key in ["GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_PREFIX", "GIT_CEILING_DIRECTORIES", "GIT_DISCOVERY_ACROSS_FILESYSTEM", "GIT_IMPLICIT_WORK_TREE", "GIT_SUPER_PREFIX", "GIT_NAMESPACE", "GIT_CONFIG_PARAMETERS", "GIT_CONFIG_COUNT", "GIT_CURL_VERBOSE"] + env.keys.filter({ $0.hasPrefix("GIT_CONFIG_KEY_") || $0.hasPrefix("GIT_CONFIG_VALUE_") || $0.hasPrefix("GIT_TRACE") }) { env.removeValue(forKey: key) }
        env["GIT_TERMINAL_PROMPT"] = "0"; env["GCM_INTERACTIVE"] = "Never"; env["GIT_ASKPASS"] = "/usr/bin/false"
        env["SSH_ASKPASS"] = "/usr/bin/false"; env["SSH_ASKPASS_REQUIRE"] = "never"
        env["GIT_ALLOW_PROTOCOL"] = allowedProtocols; env["GIT_PROTOCOL_FROM_USER"] = "0"; env["LC_ALL"] = "C"; env["GIT_MERGE_AUTOEDIT"] = "no"
        if let commonDirectory { env["GIT_COMMON_DIR"] = commonDirectory }
        if let checkpointIndexPath {
            env["GIT_INDEX_FILE"] = checkpointIndexPath
            env["GIT_AUTHOR_NAME"] = "Coincide"; env["GIT_COMMITTER_NAME"] = "Coincide"
            env["GIT_AUTHOR_EMAIL"] = "coincide@localhost"; env["GIT_COMMITTER_EMAIL"] = "coincide@localhost"
            env.removeValue(forKey: "GIT_AUTHOR_DATE"); env.removeValue(forKey: "GIT_COMMITTER_DATE")
        }
        if let checkpointObjectDirectory {
            env["GIT_OBJECT_DIRECTORY"] = checkpointObjectDirectory
            env["GIT_CONFIG_NOSYSTEM"] = "1"; env["GIT_CONFIG_SYSTEM"] = "/dev/null"; env["GIT_CONFIG_GLOBAL"] = "/dev/null"
            env["GIT_ATTR_NOSYSTEM"] = "1"; env.removeValue(forKey: "GIT_CONFIG"); env.removeValue(forKey: "GIT_ATTR_SOURCE")
        }
        let binding = (gitDirectory.map { ["--git-dir=" + $0] } ?? []) + (workTree.map { ["--work-tree=" + $0] } ?? [])
        let process = try GitWorktreeProcess(executable: git,
            arguments: ["--no-pager", "--no-optional-locks", "--literal-pathspecs", "-c", "core.fsmonitor=false", "-c", "color.ui=false", "-c", "submodule.recurse=false"] + binding + arguments,
            cwdFD: cwdFD, environment: env, maxBytes: maximumOutput, trustedInputFD: trustedInputFD)
        let reader = Task.detached { await process.result() }
        return try await withTaskCancellationHandler {
            do {
                let result = try await withThrowingTaskGroup(of: GitWorktreeCommandResult.self) { group in
                    group.addTask { await reader.value }
                    group.addTask {
                        try await Task.sleep(for: timeout); process.stop()
                        throw GitWorktreeError(.timedOut, "Preparing this local worktree timed out. Existing branches and files were preserved; inspect the attempt before retrying.")
                    }
                    defer { group.cancelAll() }
                    return try await group.next()!
                }
                try Task.checkCancellation()
                guard !result.overflow || (allowTruncatedOutput && result.stdoutOverflow && !result.stderrOverflow) else { throw GitWorktreeError(.outputLimit, "Worktree Git output exceeded the size limit. Existing branches and files were preserved.") }
                return result
            } catch { process.stop(); _ = await reader.value; try Task.checkCancellation(); throw error }
        } onCancel: { process.stop() }
    }
    var inheritedProtocolAllowlist: String? { (environment ?? ProcessChannel.environment())["GIT_ALLOW_PROTOCOL"] }
}

struct GitWorktreeCommandResult: Sendable { let status: Int32; let output: Data; let overflow: Bool; let stdoutOverflow: Bool; let stderrOverflow: Bool; let errorOutput: Data }

/// Captures output directly into a bounded accumulator; no unbounded raw-byte event queue.
final class GitWorktreeProcess: @unchecked Sendable {
    private let pid: pid_t, maxBytes: Int
    private let lock = NSLock()
    private var stopped = false, signalAllowed = true, readerShutdown = false, overflow = false, stdoutOverflow = false, stderrOverflow = false
    private var output = Data(), errorOutput = Data(), errorBytes = 0
    private var finished: GitWorktreeCommandResult?
    private var waiters: [CheckedContinuation<GitWorktreeCommandResult, Never>] = []
    init(executable: URL, arguments: [String], cwdFD: Int32, environment: [String: String], maxBytes: Int, trustedInputFD: Int32? = nil) throws {
        self.maxBytes = maxBytes
        var outputPipe = [Int32](repeating: -1, count: 2), errors = [Int32](repeating: -1, count: 2)
        guard pipe(&outputPipe) == 0, pipe(&errors) == 0 else {
            for fd in outputPipe + errors where fd >= 0 { close(fd) }; throw GitWorktreeError(.commandFailed, "Could not create worktree Git pipes.")
        }
        var descriptors = outputPipe + errors
        var inputFD: Int32 = -1
        defer { for fd in descriptors where fd >= 0 { close(fd) }; if inputFD >= 0 { close(inputFD) } }
        for index in descriptors.indices {
            if descriptors[index] <= STDERR_FILENO {
                let elevated = fcntl(descriptors[index], F_DUPFD_CLOEXEC, 3)
                guard elevated >= 0 else { throw GitWorktreeError(.commandFailed, "Could not configure worktree Git pipes.") }
                close(descriptors[index]); descriptors[index] = elevated
            }
            _ = fcntl(descriptors[index], F_SETFD, FD_CLOEXEC)
        }
        outputPipe = Array(descriptors[0..<2]); errors = Array(descriptors[2..<4])
        if let trustedInputFD {
            inputFD = fcntl(trustedInputFD, F_DUPFD_CLOEXEC, STDERR_FILENO + 1)
            var information = stat()
            guard inputFD >= 0, fstat(inputFD, &information) == 0, information.st_mode & S_IFMT == S_IFREG else {
                throw GitWorktreeError(.commandFailed, "Could not configure bounded Git input.")
            }
        } else { inputFD = Darwin.open("/dev/null", O_RDONLY | O_CLOEXEC) }
        guard inputFD >= 0 else { throw GitWorktreeError(.commandFailed, "Could not configure worktree Git input.") }
        if inputFD <= STDERR_FILENO {
            let copy = fcntl(inputFD, F_DUPFD_CLOEXEC, 3); close(inputFD); inputFD = copy
            guard copy >= 0 else { throw GitWorktreeError(.commandFailed, "Could not configure worktree Git input.") }
        }
        var actions: posix_spawn_file_actions_t?, attributes: posix_spawnattr_t?
        let a = posix_spawn_file_actions_init(&actions), b = posix_spawnattr_init(&attributes)
        guard a == 0, b == 0 else {
            if a == 0 { posix_spawn_file_actions_destroy(&actions) }; if b == 0 { posix_spawnattr_destroy(&attributes) }
            throw GitWorktreeError(.commandFailed, "Could not configure worktree Git.")
        }
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        var setup = [posix_spawn_file_actions_addfchdir_np(&actions, cwdFD),
            posix_spawn_file_actions_adddup2(&actions, inputFD, STDIN_FILENO),
            posix_spawn_file_actions_adddup2(&actions, outputPipe[1], STDOUT_FILENO),
            posix_spawn_file_actions_adddup2(&actions, errors[1], STDERR_FILENO)]
        for fd in descriptors + [inputFD] { setup.append(posix_spawn_file_actions_addclose(&actions, fd)) }
        var mask = sigset_t(), defaults = sigset_t(); sigemptyset(&mask); sigemptyset(&defaults)
        for signal in [SIGPIPE, SIGTERM, SIGINT, SIGHUP] { sigaddset(&defaults, signal) }
        setup += [posix_spawnattr_setsigmask(&attributes, &mask), posix_spawnattr_setsigdefault(&attributes, &defaults),
            posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))]
        guard setup.allSatisfy({ $0 == 0 }) else { throw GitWorktreeError(.commandFailed, "Could not isolate worktree Git.") }
        let argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
        let env = environment.sorted(by: { $0.key < $1.key }).map { strdup($0.key + "=" + $0.value) } + [nil]
        defer { for pointer in argv + env { free(pointer) } }
        var child: pid_t = 0
        let code = argv.withUnsafeBufferPointer { args in env.withUnsafeBufferPointer { values in
            posix_spawn(&child, executable.path, &actions, &attributes, UnsafeMutablePointer(mutating: args.baseAddress!), UnsafeMutablePointer(mutating: values.baseAddress!))
        } }
        guard code == 0 else { throw GitWorktreeError(.commandFailed, "Worktree Git could not be launched.") }
        pid = child
        close(outputPipe[1]); close(errors[1])
        let out = outputPipe[0], err = errors[0]
        descriptors = [] // Reader threads exclusively own and close these descriptors.
        let drained = DispatchGroup(); drained.enter(); drained.enter()
        DispatchQueue.global(qos: .utility).async { [self] in drain(out, stdout: true); drained.leave() }
        DispatchQueue.global(qos: .utility).async { [self] in drain(err, stdout: false); drained.leave() }
        DispatchQueue.global(qos: .utility).async { [self] in
            var information = siginfo_t(), observed: Int32
            repeat { observed = waitid(P_PID, id_t(pid), &information, WEXITED | WNOWAIT) } while observed == -1 && errno == EINTR
            if observed == -1 { lock.withLock { signalAllowed = false; readerShutdown = true } }
            drained.wait()
            lock.lock(); signalAllowed = false
            var raw: Int32 = 0, result: pid_t = -1
            if observed == 0 { repeat { result = waitpid(pid, &raw, 0) } while result == -1 && errno == EINTR }
            let status: Int32 = result == -1 ? 255 : ((raw & 0x7f) == 0 ? (raw >> 8) & 0xff : 128 + (raw & 0x7f))
            let value = GitWorktreeCommandResult(status: status, output: output, overflow: overflow, stdoutOverflow: stdoutOverflow, stderrOverflow: stderrOverflow, errorOutput: errorOutput)
            finished = value; let pending = waiters; waiters = []; lock.unlock()
            for waiter in pending { waiter.resume(returning: value) }
        }
    }
    func result() async -> GitWorktreeCommandResult {
        await withCheckedContinuation { waiter in
            let result = lock.withLock { () -> GitWorktreeCommandResult? in
                if let finished { return finished }; waiters.append(waiter); return nil
            }
            if let result { waiter.resume(returning: result) }
        }
    }
    func stop() {
        let signal = lock.withLock { () -> Bool in
            guard !stopped, signalAllowed, finished == nil else { return false }
            stopped = true; _ = kill(-pid, SIGTERM); return true
        }
        guard signal else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { [self] in
            lock.withLock { if signalAllowed, finished == nil { _ = kill(-pid, SIGKILL) }; readerShutdown = true }
        }
    }
    private func drain(_ fd: Int32, stdout: Bool) {
        defer { close(fd) }; _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var bytes = [UInt8](repeating: 0, count: 65_536)
        while !lock.withLock({ readerShutdown }) {
            var readiness = pollfd(fd: fd, events: Int16(POLLIN | POLLHUP), revents: 0)
            let ready = poll(&readiness, 1, 100)
            if ready == 0 || (ready < 0 && errno == EINTR) { continue }
            guard ready > 0, !lock.withLock({ readerShutdown }) else { return }
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count > 0 {
                let exceeded = lock.withLock { () -> Bool in
                    if stdout {
                        if output.count + count > maxBytes {
                            output.append(contentsOf: bytes.prefix(max(0, maxBytes - output.count)))
                            overflow = true; stdoutOverflow = true; return true
                        }
                        output.append(contentsOf: bytes.prefix(count))
                    } else {
                        errorOutput.append(contentsOf: bytes.prefix(max(0, 65_536 - errorOutput.count)))
                        errorBytes += count
                        if errorBytes > 65_536 { overflow = true; stderrOverflow = true; return true }
                    }
                    return false
                }
                if exceeded { stop() }
            } else if count < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) { continue }
            else { return }
        }
    }
}
