import Darwin
import Foundation

/// Owns a managed helper independently of windows and completion waiters.
public final class NativeProjectScriptExecutionSession: ProjectScriptExecutionSession, @unchecked Sendable {
    public let plan: ProjectScriptExecutionPlan
    private let helper: URL
    private let environment: [String: String]
    private let lock = NSLock()
    private let ready = ScriptPromise<Void>(), prepared = ScriptPromise<Void>(), started = ScriptPromise<Void>()
    private let commandExit = ScriptPromise<ProjectScriptCommandExit>()
    private let output = ScriptOutputQueue()
    private var process: ScriptHelperProcess?
    private var preparation: Task<Void, any Error>?
    private var closure: Task<Void, Never>?
    private var isPrepared = false, didStart = false, stopping = false, consuming = false
    private var receivedReady = false, receivedPrepared = false, receivedStarted = false, receivedExit = false

    public init(plan: ProjectScriptExecutionPlan, helperURL: URL, environment: [String: String]? = nil) throws {
        try plan.validate()
        guard helperURL.isFileURL, helperURL.query == nil, helperURL.fragment == nil,
              helperURL.host == nil || helperURL.host == "" || helperURL.host == "localhost" else { throw ProjectScriptExecutionError(.helperUnavailable) }
        let helper = helperURL.standardizedFileURL.resolvingSymlinksInPath()
        var node = stat()
        guard lstat(helper.path, &node) == 0, node.st_mode & S_IFMT == S_IFREG, access(helper.path, X_OK) == 0 else { throw ProjectScriptExecutionError(.helperUnavailable) }
        self.plan = plan; self.helper = helper
        self.environment = try Self.sanitizedEnvironment(environment ?? ProcessChannel.environment())
    }
    deinit { process?.stop(); output.finish(discard: true) }

    public func prepare() async throws {
        try Task.checkCancellation()
        let task = try lock.withLock { () throws -> Task<Void, any Error> in
            guard !stopping else { throw ProjectScriptExecutionError(.closed) }
            if let preparation { return preparation }
            let task = Task.detached { [self] in
                do {
                    let child = try ScriptHelperProcess(helper: helper, id: plan.id, environment: environment, output: output) { [weak self] message in self?.receive(message) }
                    let stop = lock.withLock { process = child; return stopping }
                    if stop { child.stop(); throw CancellationError() }
                    try await handshake(ready)
                    var message = ScriptWire.Message("prepare", id: plan.id); message.plan = plan
                    try await child.write(message)
                    try await handshake(prepared)
                } catch {
                    requestStop()
                    if let child = lock.withLock({ process }) { await child.finished() }
                    throw error
                }
            }
            preparation = task; return task
        }
        try await withTaskCancellationHandler {
            do { try await task.value; try Task.checkCancellation() }
            catch { try Task.checkCancellation(); throw error }
        } onCancel: { self.requestStop() }
    }
    /// A one-shot synchronous handoff. The helper still validates its pinned files before spawn.
    public func start() throws {
        try lock.withLock {
            guard !stopping, isPrepared, let process else { throw ProjectScriptExecutionError(.closed) }
            guard !didStart else { throw ProjectScriptExecutionError(.alreadyStarted) }
            didStart = true
            try process.writeStart(ScriptWire.Message("start", id: plan.id))
        }
    }
    public func waitUntilStarted() async throws { try await started.value() }
    public func waitForCommandExit() async throws -> ProjectScriptCommandExit { try await commandExit.value() }
    public func consumeOutput(_ receive: @escaping @Sendable (ProjectScriptOutputChunk) async -> Void) async throws {
        try lock.withLock {
            guard !consuming else { throw ProjectScriptExecutionError(.outputAlreadyConsumed) }
            consuming = true
        }
        try await withTaskCancellationHandler {
            while let chunk = await output.next() { try Task.checkCancellation(); await receive(chunk) }
            try Task.checkCancellation()
        } onCancel: { self.output.finish(discard: true) }
    }
    public func sendInput(_ data: Data) async throws {
        guard data.count <= 1_048_576 else { throw ProjectScriptExecutionError(.protocolViolation) }
        let child = try activeProcess()
        for index in stride(from: 0, to: data.count, by: ScriptWire.maximumInput) {
            try Task.checkCancellation()
            var message = ScriptWire.Message("input", id: plan.id)
            message.input = Data(data.dropFirst(index).prefix(ScriptWire.maximumInput))
            try await child.write(message)
        }
    }
    public func resize(columns: Int, rows: Int) async throws {
        guard (1...1_000).contains(columns), (1...1_000).contains(rows) else { throw ProjectScriptExecutionError(.protocolViolation) }
        let child = try activeProcess()
        var message = ScriptWire.Message("resize", id: plan.id); message.columns = columns; message.rows = rows
        try await child.write(message)
    }
    public func close() async {
        let task = lock.withLock { () -> Task<Void, Never> in
            if let closure { return closure }
            let task = Task.detached { [self] in
                requestStop()
                if let pending = lock.withLock({ preparation }) { _ = await pending.result }
                if let child = lock.withLock({ process }) { child.stop(); await child.finished() }
                output.finish(discard: true)
            }
            closure = task; return task
        }
        await task.value
    }
    private func activeProcess() throws -> ScriptHelperProcess {
        try lock.withLock {
            guard !stopping, receivedStarted, let process else { throw ProjectScriptExecutionError(.closed) }; return process
        }
    }
    private func handshake(_ promise: ScriptPromise<Void>) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await promise.value() }
            group.addTask { try await Task.sleep(for: .seconds(10)); throw ProjectScriptExecutionError(.launchFailed) }
            defer { group.cancelAll() }; try await group.next()!
        }
    }
    private func requestStop() {
        let child = lock.withLock { stopping = true; return process }
        let error = ProjectScriptExecutionError(.closed)
        ready.finish(.failure(error)); prepared.finish(.failure(error)); started.finish(.failure(error)); commandExit.finish(.failure(error))
        output.finish(discard: true); child?.stop()
    }
    private func receive(_ message: ScriptWire.Message) {
        guard message.runID == plan.id, (try? message.validate()) != nil else { fail(.protocolViolation); return }
        switch message.kind {
        case "ready":
            let valid = lock.withLock { () -> Bool in
                guard !receivedReady, !receivedPrepared else { return false }; receivedReady = true; return true
            }
            guard valid else { fail(.protocolViolation); return }; ready.finish(.success(()))
        case "prepared":
            let valid = lock.withLock { () -> Bool in
                guard receivedReady, !receivedPrepared else { return false }; receivedPrepared = true; isPrepared = true; return true
            }
            guard valid else { fail(.protocolViolation); return }; prepared.finish(.success(()))
        case "started":
            let valid = lock.withLock { () -> Bool in
                guard isPrepared, didStart, !receivedStarted else { return false }; receivedStarted = true; return true
            }
            guard valid else { fail(.protocolViolation); return }; started.finish(.success(()))
        case "exited", "signaled":
            guard let code = message.code, (message.kind == "exited" ? (0...255).contains(code) : (1...127).contains(code)),
                  lock.withLock({ () -> Bool in guard receivedStarted, !receivedExit else { return false }; receivedExit = true; return true }) else {
                fail(.protocolViolation); return
            }
            commandExit.finish(.success(message.kind == "exited" ? .exited(code) : .signaled(code)))
        case "error": fail(message.failure == "configurationChanged" ? .configurationChanged : message.failure == "protocolViolation" ? .protocolViolation : .launchFailed)
        case "helperClosed": fail(.closed)
        default: fail(.protocolViolation)
        }
    }
    private func fail(_ failure: ProjectScriptExecutionError.Failure) {
        let error = ProjectScriptExecutionError(failure)
        ready.finish(.failure(error)); prepared.finish(.failure(error)); started.finish(.failure(error)); commandExit.finish(.failure(error))
        requestStop()
    }
    static func sanitizedEnvironment(_ original: [String: String]) throws -> [String: String] {
        var env = original
        for key in ["GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_PREFIX", "GIT_CEILING_DIRECTORIES", "GIT_DISCOVERY_ACROSS_FILESYSTEM", "GIT_IMPLICIT_WORK_TREE", "GIT_SUPER_PREFIX", "GIT_NAMESPACE", "GIT_CONFIG_PARAMETERS", "GIT_CONFIG_COUNT", "GIT_CURL_VERBOSE", "CODEX_THREAD_ID", "T3CODE_PROJECT_ROOT", "T3CODE_WORKTREE_PATH"] + env.keys.filter({ $0.hasPrefix("GIT_CONFIG_KEY_") || $0.hasPrefix("GIT_CONFIG_VALUE_") || $0.hasPrefix("GIT_TRACE") }) { env.removeValue(forKey: key) }
        guard env.allSatisfy({ !$0.key.isEmpty && !$0.key.contains("=") && !$0.key.contains("\0") && !$0.value.contains("\0") }) else { throw ProjectScriptExecutionError(.invalidPlan) }
        return env
    }
    var helperProcessID: pid_t? { lock.withLock { process?.pid } }
    func simulateControlEOF() { lock.withLock { process }?.closeControl() }
}

final class ScriptHelperProcess: @unchecked Sendable {
    let pid: pid_t
    private let lock = NSLock(), writer = DispatchQueue(label: "com.apoorvdarshan.coincide.script-control")
    private var control: Int32
    private var stopped = false, signalAllowed = true, readerShutdown = false
    private var pendingWriteBytes = 0, pendingWrites = 0
    private let complete = ScriptPromise<Void>()
    private let output: ScriptOutputQueue
    private let onStatus: @Sendable (ScriptWire.Message) -> Void

    init(helper: URL, id: UUID, environment: [String: String], output: ScriptOutputQueue,
         onStatus: @escaping @Sendable (ScriptWire.Message) -> Void) throws {
        self.output = output; self.onStatus = onStatus
        let launched = try ProcessChannel.withChildLaunch { () throws -> (pid_t, Int32, Int32, Int32) in
            var descriptors: [Int32] = []
            defer { for fd in descriptors where fd >= 0 { Darwin.close(fd) } }
            for _ in 0..<3 {
                var ends: [Int32] = [-1, -1]
                guard pipe(&ends) == 0 else { throw ProjectScriptExecutionError(.launchFailed) }
                let first = descriptors.count; descriptors.append(contentsOf: ends)
                for index in first..<descriptors.count { descriptors[index] = try ScriptWire.elevated(descriptors[index]) }
            }
            for fd in descriptors { try ScriptWire.setNonblocking(fd) }
            guard fcntl(descriptors[1], F_SETNOSIGPIPE, 1) == 0 else { throw ProjectScriptExecutionError(.launchFailed) }
            var actions: posix_spawn_file_actions_t?, attributes: posix_spawnattr_t?
            let actionCode = posix_spawn_file_actions_init(&actions), attributeCode = posix_spawnattr_init(&attributes)
            guard actionCode == 0, attributeCode == 0 else {
                if actionCode == 0 { posix_spawn_file_actions_destroy(&actions) }
                if attributeCode == 0 { posix_spawnattr_destroy(&attributes) }
                throw ProjectScriptExecutionError(.launchFailed)
            }
            defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
            var mask = sigset_t(), defaults = sigset_t(); sigemptyset(&mask); sigemptyset(&defaults)
            for value in [SIGPIPE, SIGINT, SIGQUIT, SIGTERM, SIGHUP, SIGTSTP, SIGTTIN, SIGTTOU] { sigaddset(&defaults, value) }
            let codes = [posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0),
                posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0),
                posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0),
                posix_spawn_file_actions_adddup2(&actions, descriptors[0], ScriptWire.controlFD),
                posix_spawn_file_actions_adddup2(&actions, descriptors[3], ScriptWire.statusFD),
                posix_spawn_file_actions_adddup2(&actions, descriptors[5], ScriptWire.outputFD),
                posix_spawnattr_setsigmask(&attributes, &mask), posix_spawnattr_setsigdefault(&attributes, &defaults),
                posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))]
            guard codes.allSatisfy({ $0 == 0 }) else { throw ProjectScriptExecutionError(.launchFailed) }
            let helperPath: String = helper.path(percentEncoded: false)
            let argumentStrings: [String] = [helperPath, "--run-id", id.uuidString]
            let environmentStrings: [String] = environment.sorted(by: { $0.key < $1.key }).map { $0.key + "=" + $0.value }
            let argv: [UnsafeMutablePointer<CChar>?] = argumentStrings.map { value in value.withCString { strdup($0) } } + [nil]
            let env: [UnsafeMutablePointer<CChar>?] = environmentStrings.map { value in value.withCString { strdup($0) } } + [nil]
            defer { for pointer in argv + env { free(pointer) } }
            var child: pid_t = 0
            let code = argv.withUnsafeBufferPointer { args in env.withUnsafeBufferPointer { values in
                posix_spawn(&child, helperPath, &actions, &attributes, UnsafeMutablePointer(mutating: args.baseAddress!), UnsafeMutablePointer(mutating: values.baseAddress!))
            } }
            guard code == 0 else { throw ProjectScriptExecutionError(.launchFailed) }
            let result = (child, descriptors[1], descriptors[2], descriptors[4])
            for index in [1, 2, 4] { descriptors[index] = -1 }; return result
        }
        pid = launched.0; control = launched.1
        let status = launched.2, raw = launched.3
        let drained = DispatchGroup(); drained.enter(); drained.enter()
        DispatchQueue.global(qos: .utility).async { [self] in readStatus(status, id: id); drained.leave() }
        DispatchQueue.global(qos: .utility).async { [self] in readOutput(raw); drained.leave() }
        DispatchQueue.global(qos: .utility).async { [self] in
            var info = siginfo_t(), observed: Int32
            repeat { observed = waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) } while observed < 0 && errno == EINTR
            lock.withLock {
                if observed == 0 { _ = kill(-pid, SIGKILL) }
                else { signalAllowed = false; readerShutdown = true }
            }
            // Keep the leader unreaped while checking the killed group's remaining live members.
            if observed == 0 {
                while true {
                    if let members = try? ScriptWire.groupMembers(pid, excluding: pid), members.isEmpty { break }
                    usleep(20_000)
                }
            }
            output.finish(discard: true)
            drained.wait()
            lock.withLock {
                signalAllowed = false; readerShutdown = true
                if control >= 0 { Darwin.close(control); control = -1 }
                if observed == 0 { var value: Int32 = 0; while waitpid(pid, &value, 0) < 0 && errno == EINTR {} }
            }
            onStatus(ScriptWire.Message("helperClosed", id: id)); complete.finish(.success(()))
        }
    }
    func finished() async {
        _ = try? await complete.value()
        await withCheckedContinuation { continuation in writer.async { continuation.resume() } }
    }
    var pendingControlWrites: (count: Int, bytes: Int) { lock.withLock { (pendingWrites, pendingWriteBytes) } }
    func closeControl() { lock.withLock { if control >= 0 { Darwin.close(control); control = -1 } } }
    func stop() {
        let schedule = lock.withLock { () -> Bool in
            guard !stopped else { return false }; stopped = true
            if control >= 0 { Darwin.close(control); control = -1 }; return true
        }
        output.finish(discard: true)
        if schedule {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { [self] in
                lock.withLock { if signalAllowed { _ = kill(-pid, SIGKILL) } }
            }
        }
    }
    func writeStart(_ message: ScriptWire.Message) throws {
        let bytes = try ScriptWire.frame(message)
        guard bytes.count <= 512 else { throw ProjectScriptExecutionError(.protocolViolation) }
        try lock.withLock {
            guard control >= 0, !stopped else { throw ProjectScriptExecutionError(.closed) }
            let written = bytes.withUnsafeBytes { Darwin.write(control, $0.baseAddress!, $0.count) }
            guard written == bytes.count else { throw ProjectScriptExecutionError(.launchFailed) }
        }
    }
    func write(_ message: ScriptWire.Message) async throws {
        let reservation = message.plan != nil ? ScriptWire.maximumFrame : (message.input?.count ?? 0) * 2 + 512
        try admitWrite(reservation)
        let bytes: Data
        do { bytes = try ScriptWire.frame(message) }
        catch { releaseWrite(reservation); throw error }
        try await writeAdmitted(bytes, reservation: reservation)
    }
    // Used by the protocol regression to put Stop and Start in the same pipe read.
    func writeBatch(_ messages: [ScriptWire.Message]) async throws {
        guard (1...16).contains(messages.count), messages.allSatisfy({ $0.plan == nil && $0.input == nil }) else { throw ProjectScriptExecutionError(.protocolViolation) }
        let reservation = messages.count * ScriptWire.maximumStatus
        try admitWrite(reservation)
        var bytes = Data()
        do { for message in messages { bytes.append(try ScriptWire.frame(message, maximum: ScriptWire.maximumStatus)) } }
        catch { releaseWrite(reservation); throw error }
        try await writeAdmitted(bytes, reservation: reservation)
    }
    private func admitWrite(_ amount: Int) throws {
        try lock.withLock {
            guard !stopped, control >= 0 else { throw ProjectScriptExecutionError(.closed) }
            guard pendingWrites < 16, pendingWriteBytes + amount <= ScriptWire.maximumFrame else { throw ProjectScriptExecutionError(.inputBusy) }
            pendingWrites += 1; pendingWriteBytes += amount
        }
    }
    private func releaseWrite(_ amount: Int) { lock.withLock { pendingWrites -= 1; pendingWriteBytes -= amount } }
    private func writeAdmitted(_ bytes: Data, reservation: Int) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                writer.async { [self] in
                    let result: Result<Void, any Error>
                    do {
                        var index = 0
                        while index < bytes.count {
                            let count = try lock.withLock { () throws -> Int in
                                guard control >= 0, !stopped else { throw ProjectScriptExecutionError(.closed) }
                                return bytes.withUnsafeBytes { Darwin.write(control, $0.baseAddress!.advanced(by: index), min(16_384, $0.count - index)) }
                            }
                            if count > 0 { index += count }
                            else if count < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) { usleep(5_000) }
                            else { throw ProjectScriptExecutionError(.closed) }
                        }
                        result = .success(())
                    } catch { result = .failure(error) }
                    releaseWrite(reservation)
                    continuation.resume(with: result)
                }
            }
            try Task.checkCancellation()
        } onCancel: { self.stop() }
    }
    private func readStatus(_ fd: Int32, id: UUID) {
        defer { Darwin.close(fd) }
        var decoder = ScriptWire.Decoder(maximum: ScriptWire.maximumStatus)
        drain(fd) { bytes in
            do { for message in try decoder.append(bytes) { onStatus(message) } }
            catch { var message = ScriptWire.Message("error", id: id); message.failure = "protocolViolation"; onStatus(message); stop() }
        }
    }
    private func readOutput(_ fd: Int32) { defer { Darwin.close(fd) }; drain(fd) { output.push($0) } }
    private func drain(_ fd: Int32, receive: (Data) -> Void) {
        var bytes = [UInt8](repeating: 0, count: 16_384)
        while !lock.withLock({ readerShutdown }) {
            var readiness = pollfd(fd: fd, events: Int16(POLLIN | POLLHUP), revents: 0)
            let ready = poll(&readiness, 1, 50)
            if ready == 0 || (ready < 0 && errno == EINTR) { continue }
            guard ready > 0 else { return }
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count > 0 { receive(Data(bytes.prefix(count))) }
            else if count < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) { continue }
            else { return }
        }
    }
}
