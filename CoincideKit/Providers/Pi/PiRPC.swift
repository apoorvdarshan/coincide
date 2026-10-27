import Foundation

/// A newline-delimited JSON channel to a Pi process. Callbacks arrive on the main actor.
@MainActor
protocol PiTransport: AnyObject {
    var onLine: ((String) -> Void)? { get set }
    var onExit: ((_ status: Int32, _ stderrTail: String) -> Void)? { get set }
    var isRunning: Bool { get }
    func start() throws
    func write(_ line: String)
    /// Closes stdin, which asks Pi to shut down cleanly.
    func closeInput()
    func terminate()
}

/// Runs `pi` as a child process.
@MainActor
final class PiProcessTransport: PiTransport {
    var onLine: ((String) -> Void)?
    var onExit: ((Int32, String) -> Void)?

    /// Prompts can carry megabytes of image data; `LineProcess` writes off the main thread, in order.
    private let process: LineProcess

    init(executable: URL, arguments: [String], workingDirectory: URL, environment: [String: String]) {
        process = LineProcess(
            executable: executable, arguments: arguments, workingDirectory: workingDirectory, environment: environment)
    }

    var isRunning: Bool { process.isRunning }

    func start() throws {
        process.onLine = { [weak self] line in self?.onLine?(line) }
        process.onExit = { [weak self] status, tail in self?.onExit?(status, tail) }
        try process.start()
    }

    func write(_ line: String) {
        process.write(line)
    }

    func closeInput() {
        process.closeInput()
    }

    func terminate() {
        process.terminate()
    }
}

enum PiRPCError: LocalizedError {
    /// Pi answered the command with `success: false`.
    case rejected(command: String, message: String)
    case timedOut(command: String)
    /// The process ended; the reason includes the exit status and the end of stderr.
    case closed(String)

    var isClosed: Bool {
        if case .closed = self { return true }
        return false
    }

    var errorDescription: String? {
        switch self {
        case .rejected(_, let message): message
        case .timedOut(let command): String(localized: "Pi did not answer “\(command)” in time.")
        case .closed(let reason): reason
        }
    }
}

/// Request/response correlation over a `PiTransport`.
/// Commands carry an id that Pi repeats in its response; every other record is an event.
@MainActor
final class PiRPCClient {
    var onEvent: ((JSONValue) -> Void)?
    /// Called once when the process ends, with a readable reason.
    var onExit: ((String) -> Void)?

    private(set) var exitReason: String?
    private let transport: PiTransport
    private var nextID = 0
    private var waiters: [String: (Result<JSONValue, Error>) -> Void] = [:]
    private var exitWaiters: [CheckedContinuation<Void, Never>] = []

    init(transport: PiTransport) {
        self.transport = transport
        transport.onLine = { [weak self] line in self?.receive(line) }
        transport.onExit = { [weak self] status, stderr in self?.ended(status: status, stderr: stderr) }
    }

    var isOpen: Bool { exitReason == nil }

    func start() throws {
        try transport.start()
    }

    /// Writes a record that expects no response, such as `extension_ui_response`.
    func send(_ record: JSONValue) {
        guard isOpen else { return }
        transport.write(record.compactJSON)
    }

    /// Sends a command and calls `completion` with its `data` (or `.null`) once Pi answers.
    /// A nil timeout waits until Pi answers or exits.
    func request(
        _ record: JSONValue, timeout: Duration?, completion: @escaping (Result<JSONValue, Error>) -> Void
    ) {
        let command = record["type"]?.string ?? "request"
        if let exitReason {
            completion(.failure(PiRPCError.closed(exitReason)))
            return
        }
        nextID += 1
        let id = "coincide-\(nextID)"
        waiters[id] = completion
        var object = record.object ?? [:]
        object["id"] = .string(id)
        transport.write(JSONValue.object(object).compactJSON)
        guard let timeout else { return }
        Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard let self, let waiter = self.waiters.removeValue(forKey: id) else { return }
            waiter(.failure(PiRPCError.timedOut(command: command)))
        }
    }

    func request(_ record: JSONValue, timeout: Duration?) async throws -> JSONValue {
        try await withCheckedThrowingContinuation { continuation in
            request(record, timeout: timeout) { continuation.resume(with: $0) }
        }
    }

    /// Closes stdin and waits up to `grace` for Pi to exit, then kills it.
    func stop(grace: Duration) async {
        guard isOpen else { return }
        transport.closeInput()
        let timer = Task { [weak self] in
            try? await Task.sleep(for: grace)
            self?.releaseExitWaiters()
        }
        await withCheckedContinuation { exitWaiters.append($0) }
        timer.cancel()
        if isOpen { transport.terminate() }
    }

    /// Closes stdin without waiting, and kills Pi if it is still running after `grace`.
    func shutDown(grace: Duration) {
        guard isOpen else { return }
        transport.closeInput()
        let transport = transport
        Task {
            try? await Task.sleep(for: grace)
            if transport.isRunning { transport.terminate() }
        }
    }

    func kill() {
        transport.terminate()
    }

    private func receive(_ line: String) {
        guard let record = JSONValue.parse(line), record.object != nil else { return }
        if record["type"]?.string == "response", let id = record["id"]?.string,
            let waiter = waiters.removeValue(forKey: id)
        {
            if record["success"]?.bool == true {
                waiter(.success(record["data"] ?? .null))
            } else {
                let command = record["command"]?.string ?? "request"
                waiter(.failure(PiRPCError.rejected(command: command, message: Self.errorText(record["error"]))))
            }
            return
        }
        onEvent?(record)
    }

    private func ended(status: Int32, stderr: String) {
        guard exitReason == nil else { return }
        let reason = Self.exitDescription(status: status, stderr: stderr)
        exitReason = reason
        let pending = waiters
        waiters.removeAll()
        for waiter in pending.values { waiter(.failure(PiRPCError.closed(reason))) }
        releaseExitWaiters()
        onExit?(reason)
    }

    private func releaseExitWaiters() {
        let waiting = exitWaiters
        exitWaiters.removeAll()
        for waiter in waiting { waiter.resume() }
    }

    /// Pi reports most errors as a string; some extensions send objects.
    nonisolated static func errorText(_ value: JSONValue?) -> String {
        let text = (value?.string ?? value?.displayText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return String(localized: "Pi reported an error.") }
        return text.count > 500 ? String(text.prefix(500)) + "…" : text
    }

    nonisolated static func exitDescription(status: Int32, stderr: String) -> String {
        let summary = status == 0 ? String(localized: "Pi exited.") : String(localized: "Pi exited with code \(status).")
        let detail = TerminalText.stripANSI(stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !detail.isEmpty else { return summary }
        return summary + "\n" + (detail.count > 800 ? "…" + String(detail.suffix(800)) : detail)
    }
}
