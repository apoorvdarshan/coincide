import Foundation

/// Runs a child process and exchanges newline-delimited text with it over stdio.
/// Callbacks are delivered on the main actor in the order lines arrive.
public final class LineProcess: @unchecked Sendable {
    public let executable: URL
    public let arguments: [String]
    public let workingDirectory: URL
    public let environment: [String: String]

    public var onLine: (@MainActor (String) -> Void)?
    public var onExit: (@MainActor (_ status: Int32, _ stderrTail: String) -> Void)?
    /// Each chunk of stderr as it arrives, for providers that report progress there.
    public var onStderr: (@MainActor (String) -> Void)?

    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let lock = NSLock()
    private var stdoutBuffer = Data()
    private var stderrTail = Data()
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
            self?.handleTermination(status: process.terminationStatus)
        }
        try process.run()
    }

    /// Writes one line (a newline is appended).
    public nonisolated func write(_ line: String) {
        guard process.isRunning, let data = (line + "\n").data(using: .utf8) else { return }
        do {
            try stdinPipe.fileHandleForWriting.write(contentsOf: data)
        } catch {
            // The child closed stdin; termination is reported through onExit.
        }
    }

    /// Encodes a JSON value on one line and writes it.
    public nonisolated func write(json: JSONValue) {
        write(json.compactJSON)
    }

    public nonisolated func closeInput() {
        try? stdinPipe.fileHandleForWriting.close()
    }

    /// Sends SIGINT.
    public nonisolated func interrupt() {
        if process.isRunning { process.interrupt() }
    }

    /// Sends SIGTERM, then SIGKILL if the process is still alive after three seconds.
    public nonisolated func terminate() {
        guard process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.process.isRunning else { return }
            kill(pid, SIGKILL)
        }
    }

    private nonisolated func consumeStdout(_ data: Data) {
        if data.isEmpty {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            return
        }
        var lines: [String] = []
        lock.lock()
        stdoutBuffer.append(data)
        while let newline = stdoutBuffer.firstIndex(of: 0x0A) {
            let lineData = stdoutBuffer[stdoutBuffer.startIndex..<newline]
            var line = String(decoding: lineData, as: UTF8.self)
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...newline)
            if line.hasSuffix("\r") { line.removeLast() }
            if !line.isEmpty { lines.append(line) }
        }
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
            return
        }
        lock.lock()
        stderrTail.append(data)
        if stderrTail.count > 16_384 { stderrTail = stderrTail.suffix(16_384) }
        lock.unlock()
        let text = String(decoding: data, as: UTF8.self)
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.onStderr?(text) }
        }
    }

    private nonisolated func handleTermination(status: Int32) {
        // Let the readers drain what is left in the pipes before reporting the exit.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            if self.finished {
                self.lock.unlock()
                return
            }
            self.finished = true
            var trailing: String?
            if !self.stdoutBuffer.isEmpty {
                trailing = String(decoding: self.stdoutBuffer, as: UTF8.self)
                self.stdoutBuffer.removeAll()
            }
            let tail = String(decoding: self.stderrTail, as: UTF8.self)
            self.lock.unlock()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let trailing, !trailing.isEmpty { self.onLine?(trailing) }
                    self.onExit?(status, tail)
                }
            }
        }
    }
}

/// Runs a command to completion and returns its output. Used for probes like `--version` and git.
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
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = executable
                process.arguments = arguments
                if let cwd { process.currentDirectoryURL = cwd }
                if let environment { process.environment = environment }
                let out = Pipe()
                let err = Pipe()
                let inPipe = Pipe()
                process.standardOutput = out
                process.standardError = err
                process.standardInput = inPipe
                let outBox = DataBox()
                let errBox = DataBox()
                out.fileHandleForReading.readabilityHandler = { outBox.append($0.availableData) }
                err.fileHandleForReading.readabilityHandler = { errBox.append($0.availableData) }
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: Result(status: -1, stdout: "", stderr: error.localizedDescription))
                    return
                }
                if let input, let data = input.data(using: .utf8) {
                    try? inPipe.fileHandleForWriting.write(contentsOf: data)
                }
                try? inPipe.fileHandleForWriting.close()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async {
                    process.waitUntilExit()
                    group.leave()
                }
                if group.wait(timeout: .now() + timeout) == .timedOut {
                    process.terminate()
                    process.waitUntilExit()
                }
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                outBox.append((try? out.fileHandleForReading.readToEnd()) ?? Data())
                errBox.append((try? err.fileHandleForReading.readToEnd()) ?? Data())
                continuation.resume(
                    returning: Result(
                        status: process.terminationStatus,
                        stdout: String(decoding: outBox.data, as: UTF8.self),
                        stderr: String(decoding: errBox.data, as: UTF8.self)))
            }
        }
    }
}

final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    nonisolated init() {}

    nonisolated func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        storage.append(data)
        lock.unlock()
    }

    nonisolated var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
