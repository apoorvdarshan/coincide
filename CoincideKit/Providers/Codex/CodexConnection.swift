import Foundation

/// Newline-delimited JSON channel to a `codex app-server` process. Tests swap in a fake.
@MainActor
protocol CodexTransport: AnyObject {
    var onLine: ((String) -> Void)? { get set }
    /// The process ended on its own, with its exit status and the tail of stderr.
    var onExit: ((Int32, String) -> Void)? { get set }
    func start() throws
    func send(_ line: String)
    /// Stops the process. `onExit` may still fire afterwards.
    func close()
}

/// Runs `codex app-server` over stdio.
@MainActor
final class CodexProcessTransport: CodexTransport {
    var onLine: ((String) -> Void)?
    var onExit: ((Int32, String) -> Void)?

    private let process: LineProcess

    init(executable: URL, workingDirectory: URL, environment: [String: String]) {
        process = LineProcess(
            executable: executable, arguments: ["app-server"], workingDirectory: workingDirectory,
            environment: environment)
    }

    func start() throws {
        try process.start()
        process.onLine = { [weak self] line in self?.onLine?(line) }
        // Holds the transport until the process is gone, so a closed session still reaps its child.
        process.onExit = { [self] status, stderrTail in
            onExit?(status, stderrTail)
            process.onLine = nil
            process.onExit = nil
        }
    }

    func send(_ line: String) {
        process.write(line)
    }

    func close() {
        // The app server exits at the end of its input; give it a moment to finish writing the session log.
        process.closeInput()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [process] in process.terminate() }
    }
}

enum CodexRPCError: LocalizedError, Equatable {
    /// The app server answered with a JSON-RPC error.
    case server(code: Int, message: String)
    /// The connection ended before the answer arrived.
    case closed(String?)
    case timedOut(method: String)

    var errorDescription: String? {
        switch self {
        case .server(_, let message): message
        case .closed(let reason): reason ?? String(localized: "The Codex app server stopped.")
        case .timedOut(let method): AgentError.timeout(String(localized: "Codex to answer \(method)")).errorDescription
        }
    }
}

/// JSON-RPC peer for the app server: requests with ids, notifications, and requests the server sends back.
/// Messages omit the `jsonrpc` field, as the app server does.
@MainActor
final class CodexConnection {
    var onNotification: ((_ method: String, _ params: JSONValue) -> Void)?
    var onRequest: ((_ id: JSONValue, _ method: String, _ params: JSONValue) -> Void)?
    /// The process exited without `close()` being called.
    var onClose: ((_ status: Int32, _ stderrTail: String) -> Void)?

    private let transport: CodexTransport
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var timeouts: [Int: Task<Void, Never>] = [:]
    private(set) var isClosed = false

    init(transport: CodexTransport) {
        self.transport = transport
        transport.onLine = { [weak self] line in self?.receive(line) }
        transport.onExit = { [weak self] status, stderrTail in
            self?.transportExited(status: status, stderrTail: stderrTail)
        }
    }

    func start() throws {
        try transport.start()
    }

    /// Sends a request and waits for its result.
    func request(_ method: String, _ params: JSONValue = [:], timeout: Duration = .seconds(30)) async throws -> JSONValue {
        guard !isClosed else { throw CodexRPCError.closed(nil) }
        let id = nextID
        nextID += 1
        let message: JSONValue = ["id": .number(Double(id)), "method": .string(method), "params": params]
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            timeouts[id] = Task { [weak self] in
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled else { return }
                self?.finish(id, with: .failure(CodexRPCError.timedOut(method: method)))
            }
            transport.send(message.compactJSON)
        }
    }

    func notify(_ method: String, _ params: JSONValue? = nil) {
        guard !isClosed else { return }
        var message: [String: JSONValue] = ["method": .string(method)]
        if let params { message["params"] = params }
        transport.send(JSONValue.object(message).compactJSON)
    }

    /// Answers a request the server sent.
    func respond(to id: JSONValue, result: JSONValue) {
        guard !isClosed else { return }
        transport.send(JSONValue.object(["id": id, "result": result]).compactJSON)
    }

    func respondError(to id: JSONValue, code: Int, message: String) {
        guard !isClosed else { return }
        let error: JSONValue = ["code": .number(Double(code)), "message": .string(message)]
        transport.send(JSONValue.object(["id": id, "error": error]).compactJSON)
    }

    /// Stops the process and fails waiting requests. `onClose` is not called.
    func close() {
        guard !isClosed else { return }
        isClosed = true
        failAll(CodexRPCError.closed(nil))
        transport.close()
    }

    private func receive(_ line: String) {
        // A closed connection's process may still flush output; none of it belongs to the session any more.
        guard !isClosed, let message = JSONValue.parse(line), let object = message.object else { return }
        if let method = object["method"]?.string {
            let params = object["params"] ?? .null
            if let id = object["id"], !id.isNull {
                onRequest?(id, method, params)
            } else {
                onNotification?(method, params)
            }
            return
        }
        guard let id = object["id"]?.int else { return }
        if let error = object["error"], !error.isNull {
            let code = error["code"]?.int ?? 0
            let text = error["message"]?.string ?? String(localized: "Codex returned an error.")
            finish(id, with: .failure(CodexRPCError.server(code: code, message: text)))
        } else {
            finish(id, with: .success(object["result"] ?? .null))
        }
    }

    private func finish(_ id: Int, with result: Result<JSONValue, Error>) {
        timeouts.removeValue(forKey: id)?.cancel()
        pending.removeValue(forKey: id)?.resume(with: result)
    }

    private func failAll(_ error: CodexRPCError) {
        for id in Array(pending.keys) { finish(id, with: .failure(error)) }
    }

    private func transportExited(status: Int32, stderrTail: String) {
        guard !isClosed else { return }
        isClosed = true
        failAll(CodexRPCError.closed(CodexPresentation.exitMessage(status: status, stderr: stderrTail)))
        onClose?(status, stderrTail)
    }
}
