import Foundation
import Darwin

public enum ProcessEvent: Sendable { case stdout(Data), stderr(Data), exited(Int32) }

/// Owns exactly one child process. Both pipes are drained concurrently to avoid pipe deadlocks.
public final class ProcessChannel: @unchecked Sendable {
    public let events: AsyncStream<ProcessEvent>
    private let process: Process
    private let input: Pipe
    private let lock = NSLock()
    private let writer = DispatchQueue(label: "Coincide.provider-input", qos: .userInitiated)
    private var closed = false

    public init(executable: URL, arguments: [String], cwd: URL? = nil, environment: [String: String]? = nil) throws {
        let (stream, continuation) = AsyncStream<ProcessEvent>.makeStream()
        events = stream
        process = Process(); input = Pipe()
        let output = Pipe(), errors = Pipe()
        process.executableURL = executable; process.arguments = arguments; process.currentDirectoryURL = cwd
        process.environment = environment ?? Self.environment()
        process.standardInput = input; process.standardOutput = output; process.standardError = errors
        let descriptor = input.fileHandleForWriting.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0,
              fcntl(descriptor, F_SETNOSIGPIPE, 1) == 0 else { throw CoincideError("Could not configure provider input.") }
        let readers = DispatchGroup()
        readers.enter(); readers.enter()
        process.terminationHandler = { child in
            readers.notify(queue: .global(qos: .utility)) {
                continuation.yield(.exited(child.terminationStatus)); continuation.finish()
            }
        }
        try process.run()
        DispatchQueue.global(qos: .userInitiated).async {
            Self.drain(output.fileHandleForReading) { continuation.yield(.stdout($0)) }
            readers.leave()
        }
        DispatchQueue.global(qos: .userInitiated).async {
            Self.drain(errors.fileHandleForReading) { continuation.yield(.stderr($0)) }
            readers.leave()
        }
    }

    public func write(_ data: Data) async throws {
        try await writePayload { data }
    }
    /// Serialize large payloads on the same non-cooperative queue as pipe I/O,
    /// preserving frame order while protocol actors can process cancellation.
    func writePayload(_ makeData: @escaping @Sendable () throws -> Data) async throws {
        let pending = PendingProcessWrite()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            do {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    guard pending.install(continuation) else { return }
                    writer.async {
                        guard pending.begin() else { return }
                        do {
                            let data = try makeData()
                            guard pending.beginWriting() else { return }
                            try self.writeBytes(data); pending.finish(.success(()))
                        }
                        catch { pending.finish(.failure(error)) }
                    }
                }
                try Task.checkCancellation()
            } catch { try Task.checkCancellation(); throw error }
        } onCancel: {
            let (started, continuation) = pending.cancel()
            if started { self.stop() } // A partially written frame cannot be reused safely.
            continuation?.resume(throwing: CancellationError())
        }
    }
    private func writeBytes(_ data: Data) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                // Nonblocking writes hold the state lock only for one short syscall.
                // Closing input can therefore interrupt backpressure immediately.
                lock.lock()
                guard !closed, process.isRunning else { lock.unlock(); throw CoincideError("The provider process is no longer running.") }
                let descriptor = input.fileHandleForWriting.fileDescriptor
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), min(65_536, bytes.count - offset))
                let failure = errno
                lock.unlock()
                if count > 0 { offset += count; continue }
                if count < 0 && failure == EINTR { continue }
                if count < 0 && (failure == EAGAIN || failure == EWOULDBLOCK) {
                    var readiness = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
                    _ = poll(&readiness, 1, 50); continue
                }
                throw CoincideError("Could not write provider input.")
            }
        }
    }
    public func finishInput() {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }; closed = true
        try? input.fileHandleForWriting.close()
    }
    public func stop() {
        finishInput()
        guard process.isRunning else { return }
        process.terminate()
        let child = process
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if child.isRunning { kill(child.processIdentifier, SIGKILL) }
        }
    }
    deinit { stop() }

    private static func drain(_ file: FileHandle, emit: (Data) -> Void) {
        defer { try? file.close() }
        // Foundation's read(upToCount:) may wait to fill the requested buffer on pipes.
        // POSIX read delivers available bytes immediately, which is essential for RPC.
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = Darwin.read(file.fileDescriptor, &buffer, buffer.count)
            if count > 0 { emit(Data(buffer.prefix(count))) }
            else if count == -1 && errno == EINTR { continue }
            else { return }
        }
    }
    public static func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let extras = ["/opt/homebrew/bin", "\(home)/.local/bin", "\(home)/.cargo/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        env["PATH"] = ([env["PATH"] ?? ""] + extras).joined(separator: ":")
        // A child provider owns its own session identity.
        env.removeValue(forKey: "CODEX_THREAD_ID")
        return env
    }
    public static func findExecutable(_ name: String) -> URL? {
        if name.contains("/") {
            let path = NSString(string: name).expandingTildeInPath
            return FileManager.default.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
        }
        for directory in (environment()["PATH"] ?? "").split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }
}

private final class PendingProcessWrite: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, any Error>?
    private var started = false
    private var finished = false
    func install(_ continuation: CheckedContinuation<Void, any Error>) -> Bool {
        lock.lock()
        guard !finished else { lock.unlock(); continuation.resume(throwing: CancellationError()); return false }
        self.continuation = continuation; lock.unlock(); return true
    }
    func begin() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return !finished
    }
    func beginWriting() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return false }; started = true; return true
    }
    func finish(_ result: Result<Void, any Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true; let saved = continuation; continuation = nil; lock.unlock(); saved?.resume(with: result)
    }
    func cancel() -> (Bool, CheckedContinuation<Void, any Error>?) {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return (false, nil) }
        finished = true; let saved = continuation; continuation = nil; return (started, saved)
    }
}

public struct CommandResult: Sendable {
    public var output: Data
    public var error: Data
    public var status: Int32
    public var text: String { String(decoding: output, as: UTF8.self) }
}

public enum CommandRunner {
    public static func run(_ executable: String, _ arguments: [String], cwd: URL? = nil,
                           input: Data? = nil, limit: Int = 16 * 1_024 * 1_024,
                           timeout: Duration = .seconds(30), environment: [String: String]? = nil) async throws -> CommandResult {
        try Task.checkCancellation()
        guard let url = ProcessChannel.findExecutable(executable) else { throw CoincideError("\(executable) is not installed or executable.") }
        let channel = try ProcessChannel(executable: url, arguments: arguments, cwd: cwd, environment: environment)
        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: CommandResult.self) { group in
                group.addTask {
                    var out = Data(), err = Data()
                    for await event in channel.events {
                        try Task.checkCancellation()
                        switch event {
                        case .stdout(let data): out.append(data)
                        case .stderr(let data): err.append(data)
                        case .exited(let status): return CommandResult(output: out, error: err, status: status)
                        }
                        if out.count + err.count > limit { channel.stop(); throw CoincideError("Command output exceeded the limit.") }
                    }
                    try Task.checkCancellation()
                    throw CoincideError("Command ended without an exit status.")
                }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    channel.stop(); throw CoincideError("Command timed out.")
                }
                do {
                    if let input { try await channel.write(input) }
                    channel.finishInput()
                    let result = try await group.next()!
                    group.cancelAll(); return result
                } catch { channel.stop(); group.cancelAll(); try Task.checkCancellation(); throw error }
            }
        } onCancel: { channel.stop() }
    }
}
