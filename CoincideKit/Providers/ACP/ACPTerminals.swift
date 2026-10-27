import Foundation

/// Runs commands for agents that use the client's terminals (`terminal/create`, `output`,
/// `wait_for_exit`, `kill`, `release`). Output is kept up to the agent's byte limit, dropping
/// the oldest bytes first as the spec requires.
@MainActor
public final class ACPTerminals {
    public nonisolated static let maxLiveTerminals = 16
    public nonisolated static let maxUnreleasedTerminals = 64
    public nonisolated static let maxRetainedReleased = 32
    public nonisolated static let defaultOutputByteLimit = 4 * 1024 * 1024
    public nonisolated static let maxOutputByteLimit = 8 * 1024 * 1024

    private final class Terminal {
        let sessionID: String
        let process: Process
        let output: OutputBuffer
        var exitStatus: JSONValue?
        var waiters: [CheckedContinuation<JSONValue, Never>] = []
        var released = false

        init(sessionID: String, process: Process, output: OutputBuffer) {
            self.sessionID = sessionID
            self.process = process
            self.output = output
        }
    }

    private let workingDirectory: URL
    private let environment: [String: String]
    private var terminals: [String: Terminal] = [:]
    private var order: [String] = []
    private var nextNumber = 1

    public init(workingDirectory: URL, environment: [String: String]) {
        self.workingDirectory = workingDirectory
        self.environment = environment
    }

    public func create(_ params: JSONValue) throws -> JSONValue {
        guard let sessionID = params["sessionId"]?.string, let command = params["command"]?.string, !command.isEmpty else {
            throw ACPError.invalidParams("terminal/create needs a sessionId and a command.")
        }
        let open = terminals.values.filter { !$0.released }
        guard open.count < Self.maxUnreleasedTerminals, open.filter({ $0.exitStatus == nil }).count < Self.maxLiveTerminals
        else {
            throw ACPError.internalError("Too many terminals are open.")
        }
        let arguments = params["args"]?.array?.compactMap(\.string) ?? []
        var environment = environment
        for variable in params["env"]?.array ?? [] {
            if let name = variable["name"]?.string, let value = variable["value"]?.string { environment[name] = value }
        }
        let limit = min(params["outputByteLimit"]?.int ?? Self.defaultOutputByteLimit, Self.maxOutputByteLimit)
        let output = OutputBuffer(limit: max(0, limit))

        let process = Process()
        // `env` resolves the command on the agent-provided PATH.
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [command] + arguments
        process.environment = environment
        process.currentDirectoryURL = params["cwd"]?.string.map { URL(fileURLWithPath: $0) } ?? workingDirectory
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                output.append(data)
            }
        }

        let id = "coincide-term-\(nextNumber)"
        nextNumber += 1
        let terminal = Terminal(sessionID: sessionID, process: process, output: output)
        process.terminationHandler = { [weak self] process in
            let status: JSONValue =
                process.terminationReason == .uncaughtSignal
                ? ["exitCode": .null, "signal": .string(Self.signalName(process.terminationStatus))]
                : ["exitCode": .number(Double(process.terminationStatus)), "signal": .null]
            // Give the reader a moment to drain the pipe before reporting the exit.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                MainActor.assumeIsolated { self?.finish(id, status: status) }
            }
        }
        do {
            try process.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            throw ACPError.internalError("Could not start terminal command '\(command)'.")
        }
        terminals[id] = terminal
        order.append(id)
        return ["terminalId": .string(id)]
    }

    public func output(_ params: JSONValue) throws -> JSONValue {
        let terminal = try lookup(params, "terminal/output")
        var result: [String: JSONValue] = [
            "output": .string(terminal.output.text), "truncated": .bool(terminal.output.truncated),
        ]
        if let exitStatus = terminal.exitStatus { result["exitStatus"] = exitStatus }
        return .object(result)
    }

    public func waitForExit(_ params: JSONValue) async throws -> JSONValue {
        let terminal = try lookup(params, "terminal/wait_for_exit")
        if let exitStatus = terminal.exitStatus { return exitStatus }
        return await withCheckedContinuation { terminal.waiters.append($0) }
    }

    public func kill(_ params: JSONValue) throws -> JSONValue {
        let terminal = try lookup(params, "terminal/kill")
        stop(terminal)
        return [:]
    }

    public func release(_ params: JSONValue) throws -> JSONValue {
        let terminal = try lookup(params, "terminal/release")
        terminal.released = true
        stop(terminal)
        pruneReleased()
        return [:]
    }

    /// Output of a terminal an agent embedded in a tool call, kept after release.
    public func snapshot(_ terminalID: String) -> String? {
        terminals[terminalID]?.output.text
    }

    public func disposeAll() {
        for terminal in terminals.values {
            terminal.released = true
            stop(terminal)
        }
    }

    private func lookup(_ params: JSONValue, _ method: String) throws -> Terminal {
        guard let id = params["terminalId"]?.string, let terminal = terminals[id], !terminal.released,
            terminal.sessionID == params["sessionId"]?.string
        else {
            throw ACPError.invalidParams("\(method) received an unknown terminal id.")
        }
        return terminal
    }

    private func stop(_ terminal: Terminal) {
        let process = terminal.process
        guard process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            if process.isRunning { Darwin.kill(pid, SIGKILL) }
        }
    }

    private func finish(_ id: String, status: JSONValue) {
        guard let terminal = terminals[id], terminal.exitStatus == nil else { return }
        terminal.exitStatus = status
        let waiters = terminal.waiters
        terminal.waiters.removeAll()
        for waiter in waiters { waiter.resume(returning: status) }
    }

    private func pruneReleased() {
        let released = order.filter { terminals[$0]?.released == true }
        for id in released.dropLast(Self.maxRetainedReleased) {
            terminals[id] = nil
            order.removeAll { $0 == id }
        }
    }

    private nonisolated static func signalName(_ signal: Int32) -> String {
        switch signal {
        case SIGTERM: "SIGTERM"
        case SIGKILL: "SIGKILL"
        case SIGINT: "SIGINT"
        case SIGHUP: "SIGHUP"
        case SIGQUIT: "SIGQUIT"
        case SIGSEGV: "SIGSEGV"
        case SIGABRT: "SIGABRT"
        case SIGPIPE: "SIGPIPE"
        default: "SIG\(signal)"
        }
    }
}

/// Terminal output that keeps the newest `limit` bytes.
final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var data = Data()
    private var didTruncate = false

    nonisolated init(limit: Int) {
        self.limit = limit
    }

    nonisolated func append(_ chunk: Data) {
        lock.withLock {
            data.append(chunk)
            if data.count > limit {
                data.removeFirst(data.count - limit)
                didTruncate = true
            }
        }
    }

    nonisolated var truncated: Bool { lock.withLock { didTruncate } }

    /// The retained output, starting at a character boundary when the front was dropped.
    nonisolated var text: String {
        lock.withLock {
            var bytes = data[...]
            if didTruncate {
                while let first = bytes.first, first & 0b1100_0000 == 0b1000_0000 { bytes = bytes.dropFirst() }
            }
            return String(decoding: bytes, as: UTF8.self)
        }
    }
}
