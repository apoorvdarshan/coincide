import Darwin
import Foundation

struct WorkspaceFileGit: Sendable {
    let environment: [String: String]?
    let executable: URL?
    func ignored(_ paths: [String], root: WorkspaceFileRoot, includeTracked: Bool, deadline: ContinuousClock.Instant? = nil) async throws -> Set<String> {
        guard !paths.isEmpty else { return [] }
        let deadline = deadline ?? ContinuousClock.now + .seconds(10)
        var ignored: Set<String> = []
        for start in stride(from: 0, to: paths.count, by: 1_000) {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw WorkspaceFileError(.timedOut, "Reading workspace ignore rules timed out.") }
            let chunk = Array(paths[start..<min(paths.count, start + 1_000)])
            let input = Data((chunk.joined(separator: "\0") + "\0").utf8)
            let result = try await run(["check-ignore"] + (includeTracked ? ["--no-index"] : []) + ["-z", "--stdin"], input: input, root: root, maxBytes: 16 * 1_024 * 1_024, timeout: min(.seconds(10), ContinuousClock.now.duration(to: deadline)))
            guard let result, result.status == 0 || result.status == 1 else { continue }
            guard result.output.isEmpty || result.output.last == 0, let text = String(data: result.output, encoding: .utf8) else {
                throw WorkspaceFileError(.operationFailed, "Git returned unsupported workspace filenames.")
            }
            ignored.formUnion(text.split(separator: "\0").map(String.init))
        }
        return ignored
    }
    func inventory(root: WorkspaceFileRoot) async throws -> WorkspaceIgnoredFilePage {
        let result = try await run(["ls-files", "--others", "--ignored", "--exclude-standard", "--directory", "--no-empty-directory", "-z"], input: Data(), root: root, maxBytes: 4 * 1_024 * 1_024)
        guard let result, result.status == 0 else { return .init(files: [], truncated: false) }
        guard result.output.isEmpty || result.output.last == 0, let text = String(data: result.output, encoding: .utf8) else {
            throw WorkspaceFileError(.operationFailed, "Git returned unsupported workspace filenames.")
        }
        let paths = text.split(separator: "\0").map(String.init).filter { !$0.hasSuffix("/") }.sorted()
        var files: [WorkspaceIgnoredFile] = []
        for path in paths.prefix(200) {
            try Task.checkCancellation()
            if let size = try? root.regularSize(path) { files.append(.init(path: path, byteLength: size)) }
        }
        return .init(files: files, truncated: paths.count > 200)
    }
    private func run(_ arguments: [String], input: Data, root: WorkspaceFileRoot, maxBytes: Int, timeout: Duration = .seconds(10)) async throws -> WorkspaceFileGitResult? {
        try Task.checkCancellation(); try root.validate()
        guard let git = executable ?? ProcessChannel.findExecutable("git") else { return nil }
        var env = environment ?? ProcessChannel.environment()
        for key in ["GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_PREFIX", "GIT_CEILING_DIRECTORIES", "GIT_DISCOVERY_ACROSS_FILESYSTEM", "GIT_IMPLICIT_WORK_TREE", "GIT_SUPER_PREFIX", "GIT_NAMESPACE", "GIT_CONFIG_PARAMETERS", "GIT_CONFIG_COUNT", "GIT_CURL_VERBOSE"] + env.keys.filter({ $0.hasPrefix("GIT_CONFIG_KEY_") || $0.hasPrefix("GIT_CONFIG_VALUE_") || $0.hasPrefix("GIT_TRACE") }) { env.removeValue(forKey: key) }
        env["GIT_TERMINAL_PROMPT"] = "0"; env["GCM_INTERACTIVE"] = "Never"; env["GIT_ASKPASS"] = "/usr/bin/false"
        env["GIT_ALLOW_PROTOCOL"] = ""; env["GIT_PROTOCOL_FROM_USER"] = "0"; env["LC_ALL"] = "C"
        let process = try WorkspaceFileGitProcess(executable: git,
            arguments: ["--no-pager", "--no-optional-locks", "-c", "core.fsmonitor=false", "-c", "color.ui=false"] + arguments,
            cwdFD: root.fd, environment: env, input: input, maxBytes: maxBytes)
        let reader = Task.detached { await process.result() }
        return try await withTaskCancellationHandler {
            do {
                let result = try await withThrowingTaskGroup(of: WorkspaceFileGitResult.self) { group in
                    group.addTask { await reader.value }
                    group.addTask {
                        try await Task.sleep(for: timeout); process.stop()
                        throw WorkspaceFileError(.timedOut, "Reading workspace ignore rules timed out.")
                    }
                    defer { group.cancelAll() }
                    return try await group.next()!
                }
                try Task.checkCancellation(); try root.validate()
                guard !result.overflow else { throw WorkspaceFileError(.operationFailed, "Workspace ignore data exceeded the size limit.") }
                return result
            } catch { process.stop(); _ = await reader.value; try Task.checkCancellation(); throw error }
        } onCancel: { process.stop() }
    }
}

private struct WorkspaceFileGitResult: Sendable { let status: Int32; let output: Data; let overflow: Bool }

/// Captures output directly into a bounded accumulator; no unbounded raw-byte event queue.
private final class WorkspaceFileGitProcess: @unchecked Sendable {
    private let pid: pid_t, maxBytes: Int
    private let lock = NSLock()
    private var stopped = false, signalAllowed = true, readerShutdown = false, overflow = false
    private var output = Data(), errorBytes = 0
    private var finished: WorkspaceFileGitResult?
    private var waiters: [CheckedContinuation<WorkspaceFileGitResult, Never>] = []
    init(executable: URL, arguments: [String], cwdFD: Int32, environment: [String: String], input: Data, maxBytes: Int) throws {
        self.maxBytes = maxBytes
        var outputPipe = [Int32](repeating: -1, count: 2), errors = [Int32](repeating: -1, count: 2)
        guard pipe(&outputPipe) == 0, pipe(&errors) == 0 else {
            for fd in outputPipe + errors where fd >= 0 { close(fd) }; throw WorkspaceFileError(.operationFailed, "Could not create workspace Git pipes.")
        }
        var descriptors = outputPipe + errors
        var inputFD: Int32 = -1
        defer { for fd in descriptors where fd >= 0 { close(fd) }; if inputFD >= 0 { close(inputFD) } }
        for index in descriptors.indices {
            if descriptors[index] <= STDERR_FILENO {
                let elevated = fcntl(descriptors[index], F_DUPFD_CLOEXEC, 3)
                guard elevated >= 0 else { throw WorkspaceFileError(.operationFailed, "Could not configure workspace Git pipes.") }
                close(descriptors[index]); descriptors[index] = elevated
            }
            _ = fcntl(descriptors[index], F_SETFD, FD_CLOEXEC)
        }
        outputPipe = Array(descriptors[0..<2]); errors = Array(descriptors[2..<4])
        var template = Array((FileManager.default.temporaryDirectory.path + "/coincide-file-input-XXXXXX").utf8CString)
        inputFD = mkstemp(&template)
        guard inputFD >= 0 else { throw WorkspaceFileError(.operationFailed, "Could not prepare workspace Git input.") }
        template.withUnsafeBufferPointer { _ = unlink($0.baseAddress!) }
        if inputFD <= STDERR_FILENO {
            let copy = fcntl(inputFD, F_DUPFD_CLOEXEC, 3); close(inputFD); inputFD = copy
            guard copy >= 0 else { throw WorkspaceFileError(.operationFailed, "Could not configure workspace Git input.") }
        }
        _ = fcntl(inputFD, F_SETFD, FD_CLOEXEC)
        try input.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try Task.checkCancellation()
                let count = Darwin.write(inputFD, bytes.baseAddress!.advanced(by: offset), min(65_536, bytes.count - offset))
                guard count > 0 else { if errno == EINTR { continue }; throw WorkspaceFileError(.operationFailed, "Could not prepare workspace Git input.") }; offset += count
            }
        }
        guard lseek(inputFD, 0, SEEK_SET) == 0 else { throw WorkspaceFileError(.operationFailed, "Could not rewind workspace Git input.") }
        var actions: posix_spawn_file_actions_t?, attributes: posix_spawnattr_t?
        let a = posix_spawn_file_actions_init(&actions), b = posix_spawnattr_init(&attributes)
        guard a == 0, b == 0 else {
            if a == 0 { posix_spawn_file_actions_destroy(&actions) }; if b == 0 { posix_spawnattr_destroy(&attributes) }
            throw WorkspaceFileError(.operationFailed, "Could not configure workspace Git.")
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
        guard setup.allSatisfy({ $0 == 0 }) else { throw WorkspaceFileError(.operationFailed, "Could not isolate workspace Git.") }
        let argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
        let env = environment.sorted(by: { $0.key < $1.key }).map { strdup($0.key + "=" + $0.value) } + [nil]
        defer { for pointer in argv + env { free(pointer) } }
        var child: pid_t = 0
        let code = argv.withUnsafeBufferPointer { args in env.withUnsafeBufferPointer { values in
            posix_spawn(&child, executable.path, &actions, &attributes, UnsafeMutablePointer(mutating: args.baseAddress!), UnsafeMutablePointer(mutating: values.baseAddress!))
        } }
        guard code == 0 else { throw WorkspaceFileError(.operationFailed, "Workspace Git could not be launched.") }
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
            let value = WorkspaceFileGitResult(status: status, output: output, overflow: overflow)
            finished = value; let pending = waiters; waiters = []; lock.unlock()
            for waiter in pending { waiter.resume(returning: value) }
        }
    }
    func result() async -> WorkspaceFileGitResult {
        await withCheckedContinuation { waiter in
            let result = lock.withLock { () -> WorkspaceFileGitResult? in
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
                        if output.count + count > maxBytes { overflow = true; return true }
                        output.append(contentsOf: bytes.prefix(count))
                    } else { errorBytes += count; if errorBytes > 65_536 { overflow = true; return true } }
                    return false
                }
                if exceeded { stop() }
            } else if count < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) { continue }
            else { return }
        }
    }
}
