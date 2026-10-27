import Foundation

/// A JSON-RPC 2.0 message read from `cursor-agent acp`.
enum CursorRPCMessage: Equatable, Sendable {
    case request(id: JSONValue, method: String, params: JSONValue)
    case notification(method: String, params: JSONValue)
    case response(id: JSONValue, result: Result<JSONValue, CursorRPCError>)

    nonisolated static func parse(_ line: String) -> CursorRPCMessage? {
        guard let value = JSONValue.parse(line), let object = value.object else { return nil }
        let params = object["params"] ?? .null
        if let method = object["method"]?.string {
            if let id = object["id"], !id.isNull { return .request(id: id, method: method, params: params) }
            return .notification(method: method, params: params)
        }
        guard let id = object["id"] else { return nil }
        if let error = object["error"], !error.isNull {
            return .response(id: id, result: .failure(CursorRPCError(error)))
        }
        return .response(id: id, result: .success(object["result"] ?? .null))
    }

    nonisolated static func requestLine(id: Int, method: String, params: JSONValue) -> String {
        JSONValue.object(["jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method), "params": params])
            .compactJSON
    }

    nonisolated static func notificationLine(method: String, params: JSONValue) -> String {
        JSONValue.object(["jsonrpc": "2.0", "method": .string(method), "params": params]).compactJSON
    }

    nonisolated static func resultLine(id: JSONValue, _ result: JSONValue) -> String {
        JSONValue.object(["jsonrpc": "2.0", "id": id, "result": result]).compactJSON
    }

    nonisolated static func errorLine(id: JSONValue, code: Int, message: String) -> String {
        JSONValue.object([
            "jsonrpc": "2.0", "id": id, "error": ["code": .number(Double(code)), "message": .string(message)],
        ]).compactJSON
    }
}

struct CursorRPCError: LocalizedError, Equatable, Sendable {
    nonisolated static let authRequired = -32000
    nonisolated static let methodNotFound = -32601
    nonisolated static let invalidParams = -32602
    nonisolated static let requestCancelled = -32800

    var code: Int
    var message: String
    var data: JSONValue?

    nonisolated init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    nonisolated init(_ value: JSONValue) {
        code = value["code"]?.int ?? 0
        message = value["message"]?.string ?? ""
        data = value["data"]
    }

    /// Cursor puts the useful reason in `data.message`; `message` is often just "Invalid params".
    nonisolated var detail: String {
        if let text = data?["message"]?.string, !text.isEmpty { return text }
        if let text = data?.string, !text.isEmpty { return text }
        return message.isEmpty ? String(localized: "Cursor reported error \(code).") : message
    }

    nonisolated var isAuthRequired: Bool {
        code == Self.authRequired || detail.localizedCaseInsensitiveContains("authentication required")
    }

    nonisolated var errorDescription: String? { detail }
}

/// The byte stream to a `cursor-agent acp` process. Tests substitute a scripted one.
@MainActor
protocol CursorTransport: AnyObject {
    var onLine: ((String) -> Void)? { get set }
    /// Called once when the process ends, with its exit status and the tail of stderr.
    var onExit: ((Int32, String) -> Void)? { get set }
    func start() throws
    func send(_ line: String)
    func terminate()
}

@MainActor
final class CursorProcessTransport: CursorTransport {
    var onLine: ((String) -> Void)?
    var onExit: ((Int32, String) -> Void)?
    private let process: LineProcess

    init(executable: URL, arguments: [String], workingDirectory: URL, environment: [String: String]) {
        process = LineProcess(
            executable: executable, arguments: arguments, workingDirectory: workingDirectory, environment: environment)
    }

    func start() throws {
        process.onLine = { [weak self] line in self?.onLine?(line) }
        process.onExit = { [weak self] status, stderr in self?.onExit?(status, stderr) }
        try process.start()
    }

    func send(_ line: String) {
        process.write(line)
    }

    func terminate() {
        process.closeInput()
        process.terminate()
    }
}

/// JSON-RPC over a `CursorTransport`: correlates responses with requests and routes the agent's
/// own requests and notifications.
@MainActor
final class CursorConnection {
    typealias Completion = (Result<JSONValue, any Error>) -> Void

    var onNotification: ((_ method: String, _ params: JSONValue) -> Void)?
    var onRequest: ((_ id: JSONValue, _ method: String, _ params: JSONValue) -> Void)?
    /// Called when the process ends without `close()` having been called.
    var onClose: ((_ message: String) -> Void)?

    private(set) var isClosed = false
    private let transport: CursorTransport
    private var nextID = 1
    private var callbacks: [Int: Completion] = [:]
    private var timeouts: [Int: Task<Void, Never>] = [:]

    init(transport: CursorTransport) {
        self.transport = transport
        transport.onLine = { [weak self] line in self?.receive(line) }
        transport.onExit = { [weak self] status, stderr in self?.processEnded(status: status, stderr: stderr) }
    }

    func start() throws {
        try transport.start()
    }

    /// Sends a request; `completion` runs once with the result, an error, or a closed-connection failure.
    @discardableResult
    func send(_ method: String, _ params: JSONValue, completion: @escaping Completion) -> Int {
        let id = nextID
        nextID += 1
        guard !isClosed else {
            completion(.failure(AgentError.notRunning))
            return id
        }
        callbacks[id] = completion
        transport.send(CursorRPCMessage.requestLine(id: id, method: method, params: params))
        return id
    }

    func request(_ method: String, _ params: JSONValue, timeout: Duration? = nil) async throws -> JSONValue {
        try await withCheckedThrowingContinuation { continuation in
            let id = send(method, params) { continuation.resume(with: $0) }
            guard let timeout, callbacks[id] != nil else { return }
            timeouts[id] = Task { [weak self] in
                do {
                    try await Task.sleep(for: timeout)
                } catch {
                    return
                }
                self?.fail(id, with: AgentError.timeout(method))
            }
        }
    }

    func notify(_ method: String, _ params: JSONValue) {
        guard !isClosed else { return }
        transport.send(CursorRPCMessage.notificationLine(method: method, params: params))
    }

    func respond(to id: JSONValue, result: JSONValue) {
        guard !isClosed else { return }
        transport.send(CursorRPCMessage.resultLine(id: id, result))
    }

    func respond(to id: JSONValue, errorCode: Int, message: String) {
        guard !isClosed else { return }
        transport.send(CursorRPCMessage.errorLine(id: id, code: errorCode, message: message))
    }

    /// Stops the process. Pending requests fail with `AgentError.notRunning`; `onClose` is not called.
    func close() {
        guard !isClosed else { return }
        isClosed = true
        transport.onLine = nil
        transport.onExit = nil
        failAll(with: AgentError.notRunning)
        transport.terminate()
    }

    private func fail(_ id: Int, with error: any Error) {
        complete(id, with: .failure(error))
    }

    private func complete(_ id: Int, with result: Result<JSONValue, any Error>) {
        timeouts.removeValue(forKey: id)?.cancel()
        callbacks.removeValue(forKey: id)?(result)
    }

    private func failAll(with error: any Error) {
        for id in callbacks.keys.sorted() { fail(id, with: error) }
    }

    private func receive(_ line: String) {
        // The CLI may print stray diagnostics; only JSON-RPC lines matter.
        guard !isClosed, let message = CursorRPCMessage.parse(line) else { return }
        switch message {
        case .response(let id, let result):
            guard let key = id.int else { return }
            complete(key, with: result.mapError { $0 })
        case .request(let id, let method, let params):
            onRequest?(id, method, params)
        case .notification(let method, let params):
            onNotification?(method, params)
        }
    }

    private func processEnded(status: Int32, stderr: String) {
        guard !isClosed else { return }
        isClosed = true
        let message = Self.exitMessage(status: status, stderr: stderr)
        failAll(with: AgentError.providerError(message))
        onClose?(message)
    }

    /// The last lines Cursor printed to stderr, or a generic note with the exit status.
    nonisolated static func exitMessage(status: Int32, stderr: String) -> String {
        let lines = stripANSI(stderr).split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let tail = lines.suffix(4).joined(separator: "\n")
        guard !tail.isEmpty else { return String(localized: "Cursor exited unexpectedly (status \(status)).") }
        return tail.count > 600 ? String(tail.suffix(600)) : tail
    }

    nonisolated static func stripANSI(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
    }
}
