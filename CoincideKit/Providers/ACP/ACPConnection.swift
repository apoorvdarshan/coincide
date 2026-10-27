import Foundation

extension JSONValue {
    /// The value as an `Int` when it is a whole number in range (`exactInt`). Agents are untrusted:
    /// `int` would round 1.5 down to 1.
    nonisolated var acpInt: Int? { exactInt }
}

/// A JSON-RPC error object, as an agent returns it or as Coincide sends one back.
public struct ACPError: LocalizedError, Sendable, Hashable {
    public var code: Int
    public var message: String
    public var data: JSONValue?

    public nonisolated init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    public nonisolated static let parseError = -32700
    public nonisolated static let invalidRequest = -32600
    public nonisolated static let methodNotFound = -32601
    public nonisolated static let invalidParams = -32602
    public nonisolated static let internalError = -32603
    /// The agent needs `authenticate` before it can open a session.
    public nonisolated static let authRequired = -32000
    public nonisolated static let resourceNotFound = -32002
    /// Some agents end a prompt stopped by `session/cancel` with this LSP-style code.
    public nonisolated static let requestCancelled = -32800

    public nonisolated static func methodNotFound(_ method: String) -> ACPError {
        ACPError(code: methodNotFound, message: "Method not found: \(method)")
    }

    public nonisolated static func invalidParams(_ message: String) -> ACPError {
        ACPError(code: invalidParams, message: message)
    }

    public nonisolated static func internalError(_ message: String) -> ACPError {
        ACPError(code: internalError, message: message)
    }

    /// The message plus any human-readable detail the agent put in `data`.
    public nonisolated var errorDescription: String? {
        let detail = data?["details"]?.string ?? data?["message"]?.string ?? data?.string
        guard let detail, !detail.isEmpty, detail != message else { return message }
        return message.isEmpty ? detail : "\(message): \(detail)"
    }

    nonisolated init?(json: JSONValue) {
        guard let code = json["code"]?.acpInt else { return nil }
        self.init(code: code, message: json["message"]?.string ?? "", data: json["data"])
    }

    nonisolated var json: JSONValue {
        var object: [String: JSONValue] = ["code": .number(Double(code)), "message": .string(message)]
        if let data { object["data"] = data }
        return .object(object)
    }
}

/// A JSON-RPC 2.0 peer that exchanges one message per line, the way the Agent Client Protocol
/// runs over stdio. It knows nothing about ACP methods; `ACPClient` builds on it.
@MainActor
public final class ACPConnection {
    /// A request the agent sent to the client. Answer each one exactly once.
    public struct IncomingRequest: Sendable, Hashable {
        public let id: JSONValue
        public let method: String
        public let params: JSONValue
    }

    public typealias Completion = (Result<JSONValue, Error>) -> Void

    public var onRequest: ((IncomingRequest) -> Void)?
    public var onNotification: ((_ method: String, _ params: JSONValue) -> Void)?
    /// Lines that are not JSON-RPC messages, such as sign-in links some agents print on stdout.
    public var onUnparsedLine: ((String) -> Void)?

    private struct Pending {
        var method: String
        var completion: Completion
        var timer: Task<Void, Never>?
    }

    private let write: (String) -> Void
    private var nextID = 1
    private var pending: [Int: Pending] = [:]
    private var closedError: Error?

    public init(write: @escaping (String) -> Void) {
        self.write = write
    }

    public var isClosed: Bool { closedError != nil }
    public var hasPendingRequests: Bool { !pending.isEmpty }

    /// Sends a request; `completion` runs on the main actor as soon as the response line is read,
    /// so it observes notifications and responses in wire order.
    @discardableResult
    public func send(
        _ method: String, params: JSONValue, timeout: TimeInterval? = nil, completion: @escaping Completion
    ) -> Int {
        let id = nextID
        nextID += 1
        if let closedError {
            completion(.failure(closedError))
            return id
        }
        var entry = Pending(method: method, completion: completion)
        if let timeout {
            entry.timer = Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                guard !Task.isCancelled else { return }
                self?.expire(id)
            }
        }
        pending[id] = entry
        write(JSONValue.object(["jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method), "params": params]).compactJSON)
        return id
    }

    public func request(_ method: String, params: JSONValue, timeout: TimeInterval? = nil) async throws -> JSONValue {
        try await withCheckedThrowingContinuation { continuation in
            send(method, params: params, timeout: timeout) { continuation.resume(with: $0) }
        }
    }

    public func notify(_ method: String, params: JSONValue) {
        guard closedError == nil else { return }
        write(JSONValue.object(["jsonrpc": "2.0", "method": .string(method), "params": params]).compactJSON)
    }

    public func respond(to request: IncomingRequest, result: JSONValue) {
        guard closedError == nil else { return }
        let line = JSONValue.object(["jsonrpc": "2.0", "id": request.id, "result": result]).compactJSON
        // A result JSON cannot encode (a non-finite number) must still answer the request.
        guard !line.isEmpty else { return respond(to: request, error: .internalError("The client could not encode its answer.")) }
        write(line)
    }

    public func respond(to request: IncomingRequest, error: ACPError) {
        guard closedError == nil else { return }
        write(JSONValue.object(["jsonrpc": "2.0", "id": request.id, "error": error.json]).compactJSON)
    }

    /// Feeds one line read from the agent.
    public func receive(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("{"), let message = JSONValue.parse(trimmed), message.object != nil else {
            if !trimmed.isEmpty { onUnparsedLine?(line) }
            return
        }
        if let method = message["method"]?.string {
            let params = message["params"] ?? .null
            if let id = message["id"], !id.isNull {
                onRequest?(IncomingRequest(id: id, method: method, params: params))
            } else {
                onNotification?(method, params)
            }
            return
        }
        guard let id = message["id"]?.acpInt, let entry = pending.removeValue(forKey: id) else { return }
        entry.timer?.cancel()
        if let error = message["error"], !error.isNull {
            // A malformed error object is still a failure, never a successful empty result.
            let message = error["message"]?.string ?? error.string ?? "The agent returned an invalid error."
            entry.completion(.failure(ACPError(json: error) ?? .internalError(message)))
        } else {
            entry.completion(.success(message["result"] ?? .null))
        }
    }

    /// Fails every pending request and refuses new ones, for example when the agent process exits.
    public func close(with error: Error) {
        guard closedError == nil else { return }
        closedError = error
        let entries = pending.values
        pending.removeAll()
        for entry in entries {
            entry.timer?.cancel()
            entry.completion(.failure(error))
        }
    }

    private func expire(_ id: Int) {
        guard let entry = pending.removeValue(forKey: id) else { return }
        entry.completion(.failure(AgentError.timeout(entry.method)))
    }
}
