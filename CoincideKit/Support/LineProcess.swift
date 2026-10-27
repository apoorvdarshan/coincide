import Foundation

/// Runs a child process and exchanges newline-delimited text with it over stdio.
/// Callbacks are delivered on the main actor in the order lines arrive, and `onExit` comes last.
///
/// Writes go to a serial queue, so a child that is slow to read (or a prompt carrying megabytes of
/// image data) never blocks the caller. The process is registered with `ChildProcesses`, so it is
/// stopped when Coincide quits and swept up after a crash, and `terminate()` also stops everything
/// it started.
public final class LineProcess: @unchecked Sendable {
    public let executable: URL
    public let arguments: [String]
    public let workingDirectory: URL
    public let environment: [String: String]

    public var onLine: (@MainActor (String) -> Void)?
    public var onExit: (@MainActor (_ status: Int32, _ stderrTail: String) -> Void)?
    /// Each chunk of stderr as it arrives, for providers that report progress there.
    public var onStderr: (@MainActor (String) -> Void)?

    /// A line longer than this is dropped rather than buffered without end.
    nonisolated static let maxLineBytes = 256 * 1024 * 1024
    /// How long the exit waits for a helper the process left running to let go of its output.
    nonisolated static let drainTimeout: TimeInterval = 2

    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let writer = DispatchQueue(label: "com.apoorvdarshan.coincide.line-process.stdin")
    private let lock = NSLock()
    private var stdoutBuffer = Data()
    /// How far `stdoutBuffer` has been searched for a newline, so long lines aren't rescanned per chunk.
    private var scannedCount = 0
    /// The current line grew past `maxLineBytes`; the rest of it is skipped.
    private var skippingLine = false
    private var stderrTail = Data()
    /// Bytes of a UTF-8 character split across stderr chunks.
    private var stderrCarry = Data()
    private var exitStatus: Int32?
    private var stdoutOpen = true
    private var stderrOpen = true
    private var finished = false

    public nonisolated init(executable: URL, arguments: [String], workingDirectory: URL, environment: [String: String]) {
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
    }

    public nonisolated var isRunning: Bool { process.isRunning }
    public nonisolated var processIdentifier: Int32 { process.processIdentifier }

    public nonisolated func start() throws {
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        process.environment = environment
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            self?.consumeStdout(data)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            self?.consumeStderr(data)
        }
        process.terminationHandler = { [weak self] process in
            ChildProcesses.shared.forget(process.processIdentifier)
            self?.handleTermination(status: process.terminationStatus)
        }
        // A write racing the child's exit should fail with EPIPE (handled in write) instead of killing Coincide.
        _ = fcntl(stdinPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            throw error
        }
        ChildProcesses.shared.track(process.processIdentifier)
    }

    /// Writes one line (a newline is appended), after any earlier writes.
    public nonisolated func write(_ line: String) {
        guard let data = (line + "\n").data(using: .utf8) else { return }
        let process = process
        let handle = stdinPipe.fileHandleForWriting
        writer.async {
            guard process.isRunning else { return }
            do {
                try handle.write(contentsOf: data)
            } catch {
                // The child closed stdin; termination is reported through onExit.
            }
        }
    }

    /// Encodes a JSON value on one line and writes it.
    public nonisolated func write(json: JSONValue) {
        write(json.compactJSON)
    }

    /// Closes stdin once every earlier write is done.
    public nonisolated func closeInput() {
        let handle = stdinPipe.fileHandleForWriting
        writer.async { try? handle.close() }
    }

    /// Sends SIGINT.
    public nonisolated func interrupt() {
        if process.isRunning { process.interrupt() }
    }

    /// Sends SIGTERM to the process and everything it started, then SIGKILL to whatever is still alive
    /// after three seconds. The fallback does not depend on this object staying around.
    public nonisolated func terminate() {
        guard process.isRunning else { return }
        ProcessTree.terminateTree(process.processIdentifier, grace: 3)
    }

    // MARK: Output

    private nonisolated func consumeStdout(_ data: Data) {
        if data.isEmpty {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            lock.lock()
            stdoutOpen = false
            finishIfDone()
            return
        }
        var lines: [String] = []
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        stdoutBuffer.append(data)
        var lineStart = stdoutBuffer.startIndex
        var searchFrom = stdoutBuffer.startIndex + scannedCount
        while let newline = stdoutBuffer[searchFrom...].firstIndex(of: 0x0A) {
            if skippingLine {
                skippingLine = false
            } else {
                var line = String(decoding: stdoutBuffer[lineStart..<newline], as: UTF8.self)
                if line.hasSuffix("\r") { line.removeLast() }
                if !line.isEmpty { lines.append(line) }
            }
            lineStart = newline + 1
            searchFrom = lineStart
        }
        stdoutBuffer.removeSubrange(stdoutBuffer.startIndex..<lineStart)
        if stdoutBuffer.count > Self.maxLineBytes {
            stdoutBuffer.removeAll()
            skippingLine = true
        }
        scannedCount = stdoutBuffer.count
        lock.unlock()
        guard !lines.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let onLine = self?.onLine else { return }
                for line in lines { onLine(line) }
            }
        }
    }

    private nonisolated func consumeStderr(_ data: Data) {
        if data.isEmpty {
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            lock.lock()
            stderrOpen = false
            finishIfDone()
            return
        }
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        Self.appendToTail(&stderrTail, data)
        let (text, carry) = Self.decodeUTF8(stderrCarry + data)
        stderrCarry = carry
        lock.unlock()
        guard !text.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.onStderr?(text) }
        }
    }

    private nonisolated func handleTermination(status: Int32) {
        lock.lock()
        exitStatus = status
        finishIfDone()
        // A helper the process started can keep its output open; don't wait on it for long.
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.drainTimeout) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.stdoutOpen = false
            self.stderrOpen = false
            self.finishIfDone()
        }
    }

    /// Called with the lock held; releases it. Reports the exit once the process has ended and its
    /// output is drained, after every line read before.
    private nonisolated func finishIfDone() {
        guard let status = exitStatus, !stdoutOpen, !stderrOpen, !finished else {
            lock.unlock()
            return
        }
        finished = true
        var trailing: String?
        if !stdoutBuffer.isEmpty, !skippingLine {
            trailing = String(decoding: stdoutBuffer, as: UTF8.self)
        }
        stdoutBuffer.removeAll()
        let tail = String(decoding: stderrTail, as: UTF8.self)
        lock.unlock()
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if let trailing, !trailing.isEmpty { self.onLine?(trailing) }
                self.onExit?(status, tail)
            }
        }
    }

    /// How much of the end of stderr is kept for `onExit`.
    nonisolated static let stderrTailLimit = 16_384

    /// Appends to the stderr tail and keeps its last `stderrTailLimit` bytes in storage of their own. A slice
    /// would keep the old buffer, which then grows in place, so everything the process ever wrote to stderr
    /// would stay in memory.
    nonisolated static func appendToTail(_ tail: inout Data, _ data: Data) {
        tail.append(data)
        if tail.count > stderrTailLimit { tail = Data(tail.suffix(stderrTailLimit)) }
    }

    /// Decodes the complete UTF-8 characters of `data` and returns the bytes of a character cut off at the end.
    nonisolated static func decodeUTF8(_ data: Data) -> (text: String, carry: Data) {
        let bytes = [UInt8](data)
        var cut = bytes.count
        // Look back over at most three continuation bytes for the start of a multi-byte character.
        var index = bytes.count - 1
        while index >= 0, index >= bytes.count - 4 {
            let byte = bytes[index]
            if byte & 0b1100_0000 == 0b1000_0000 {
                index -= 1
                continue
            }
            let length = byte >= 0xF0 ? 4 : byte >= 0xE0 ? 3 : byte >= 0xC0 ? 2 : 1
            if bytes.count - index < length { cut = index }
            break
        }
        return (String(decoding: bytes[..<cut], as: UTF8.self), Data(bytes[cut...]))
    }
}

/// Runs a command to completion and returns its output. Used for probes like `--version`, and for git.
///
/// Input is written off the caller's thread (checkpoint and diff steps pipe thousands of paths), a
/// helper that keeps the output open after the command exits is not waited on for long, and a command
/// that outlives the timeout is stopped together with what it started (SIGTERM, then SIGKILL).
public enum ProcessRunner {
    public struct Result: Sendable {
        public var status: Int32
        public var stdout: String
        public var stderr: String

        public nonisolated var succeeded: Bool { status == 0 }
    }

    public nonisolated static func run(
        _ executable: URL, _ arguments: [String], cwd: URL? = nil, environment: [String: String]? = nil,
        timeout: TimeInterval = 20, input: String? = nil
    ) async -> Result {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            if let cwd { process.currentDirectoryURL = cwd }
            if let environment { process.environment = environment }
            let stdout = Pipe()
            let stderr = Pipe()
            let stdin = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            process.standardInput = stdin
            let run = CommandRun(continuation: continuation)
            for (pipe, isStdout) in [(stdout, true), (stderr, false)] {
                pipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if data.isEmpty {
                        handle.readabilityHandler = nil
                        run.closed(stdout: isStdout)
                    } else {
                        run.append(data, stdout: isStdout)
                    }
                }
            }
            process.terminationHandler = { process in
                run.exited(process.terminationStatus)
                // A helper the command left running can hold the pipes open; don't wait on it for long.
                DispatchQueue.global().asyncAfter(deadline: .now() + LineProcess.drainTimeout) {
                    stdout.fileHandleForReading.readabilityHandler = nil
                    stderr.fileHandleForReading.readabilityHandler = nil
                    run.closed(stdout: true)
                    run.closed(stdout: false)
                }
            }
            // Writing to a command that already exited should fail with EPIPE, not kill Coincide.
            _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
            do {
                try process.run()
            } catch {
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                run.fail(error.localizedDescription)
                return
            }
            // Write on another thread: a child that doesn't read its input must not block us.
            DispatchQueue.global().async {
                if let input, let data = input.data(using: .utf8) {
                    try? stdin.fileHandleForWriting.write(contentsOf: data)
                }
                try? stdin.fileHandleForWriting.close()
            }
            let pid = process.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard process.isRunning else { return }
                run.timedOut()
                ProcessTree.terminateTree(pid, grace: 3)
            }
        }
    }
}

/// The output of one `ProcessRunner.run` call; resumes the caller once the process has exited
/// and both pipes are drained.
private final class CommandRun: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ProcessRunner.Result, Never>?
    private var stdout = Data()
    private var stderr = Data()
    private var status: Int32?
    private var stdoutOpen = true
    private var stderrOpen = true
    private var didTimeOut = false

    nonisolated init(continuation: CheckedContinuation<ProcessRunner.Result, Never>) {
        self.continuation = continuation
    }

    nonisolated func append(_ data: Data, stdout isStdout: Bool) {
        lock.withLock {
            if isStdout { stdout.append(data) } else { stderr.append(data) }
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
        continuation?.resume(returning: ProcessRunner.Result(status: -1, stdout: "", stderr: message))
    }

    /// Called with the lock held; releases it.
    private nonisolated func finishIfDone() {
        guard let status, !stdoutOpen, !stderrOpen, let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        var errorText = String(decoding: stderr, as: UTF8.self)
        if didTimeOut { errorText += "\nThe command timed out." }
        let result = ProcessRunner.Result(
            status: status, stdout: String(decoding: stdout, as: UTF8.self), stderr: errorText)
        // The timeout closure keeps this object alive; don't keep the output with it.
        stdout = Data()
        stderr = Data()
        lock.unlock()
        continuation.resume(returning: result)
    }
}
