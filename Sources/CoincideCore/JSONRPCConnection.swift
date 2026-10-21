import Foundation
import OSLog

public struct NDJSONDecoder: Sendable {
    private var buffer = Data()
    private var searchOffset = 0
    public let maximumFrameSize: Int
    public init(maximumFrameSize: Int = 16 * 1_024 * 1_024) { self.maximumFrameSize = maximumFrameSize }
    public mutating func append(_ bytes: Data) throws -> [JSONValue] {
        buffer.append(bytes)
        var values: [JSONValue] = []
        while let newline = buffer[searchOffset...].firstIndex(of: 10) {
            let line = buffer[..<newline]
            guard line.count <= maximumFrameSize else { throw CoincideError("Provider frame exceeded the size limit.") }
            if !line.allSatisfy({ $0 == 13 || $0 == 32 || $0 == 9 }) {
                values.append(try JSONDecoder().decode(JSONValue.self, from: line))
            }
            buffer.removeSubrange(...newline)
            searchOffset = 0
        }
        searchOffset = buffer.endIndex
        guard buffer.count <= maximumFrameSize else { throw CoincideError("Provider frame exceeded the size limit.") }
        return values
    }
    public mutating func finish() throws -> [JSONValue] {
        guard !buffer.isEmpty else { return [] }
        return try append(Data([10]))
    }
}

public enum RPCEvent: Sendable {
    case notification(method: String, params: JSONValue)
    case request(id: JSONValue, method: String, params: JSONValue)
    case disconnected(String)
    case barrier(@Sendable () -> Void)
}

public enum StdioDialect: Sendable { case jsonRPC, jsonRPC2, claudeControl }

public actor JSONRPCConnection {
    private let logger = Logger(subsystem: "com.apoorvdarshan.coincide", category: "ProviderTransport")
    public nonisolated let events: AsyncStream<RPCEvent>
    private let continuation: AsyncStream<RPCEvent>.Continuation
    private let channel: ProcessChannel
    private let dialect: StdioDialect
    private var reader: Task<Void, Never>?
    private var pending: [JSONValue: CheckedContinuation<JSONValue, any Error>] = [:]
    private var timeouts: [JSONValue: Task<Void, Never>] = [:]
    private var writes: [JSONValue: Task<Void, Never>] = [:]
    private var barriers: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var nextID = 0
    private var decoder: NDJSONDecoder
    private var ended = false

    public init(executable: URL, arguments: [String], cwd: URL? = nil, dialect: StdioDialect = .jsonRPC, maximumFrameSize: Int = 16 * 1_024 * 1_024) throws {
        let (events, continuation) = AsyncStream<RPCEvent>.makeStream()
        self.events = events; self.continuation = continuation
        self.dialect = dialect
        decoder = NDJSONDecoder(maximumFrameSize: maximumFrameSize)
        channel = try ProcessChannel(executable: executable, arguments: arguments, cwd: cwd)
    }
    public func start() {
        guard reader == nil else { return }
        let events = channel.events
        reader = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                await self.consume(event)
            }
        }
    }
    public func request(_ method: String, params: JSONValue = .object([:]), timeout: Duration = .seconds(30), onSent: (@Sendable () -> Void)? = nil) async throws -> JSONValue {
        guard !ended else { throw CoincideError("The provider connection is closed.") }
        start(); nextID += 1
        logger.debug("Provider request started: \(method, privacy: .public)")
        let id: JSONValue = dialect == .claudeControl ? .string("coincide-\(nextID)") : .number(Double(nextID))
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { response in
                pending[id] = response
                let frame: JSONValue
                if dialect == .claudeControl {
                    var request = params.object ?? [:]; request["subtype"] = .string(method)
                    frame = .object(["type": .string("control_request"), "request_id": id, "request": .object(request)])
                } else { frame = .object(["id": id, "method": .string(method), "params": params]) }
                writes[id] = Task { [weak self] in
                    guard let self else { return }
                    do { try await self.send(frame); onSent?(); await self.writeFinished(id) }
                    catch { await self.fail(id, error: error) }
                }
                timeouts[id] = Task { [weak self] in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    await self?.fail(id, error: CoincideError("\(method) timed out."))
                }
            }
        } onCancel: { Task { await self.fail(id, error: CancellationError()) } }
    }
    public func notify(_ method: String, params: JSONValue? = nil) async throws {
        var frame: [String: JSONValue] = ["method": .string(method)]
        if let params { frame["params"] = params }
        try await send(.object(frame))
    }
    public func sendFrame(_ frame: JSONValue) async throws { try await send(frame) }
    public func respond(id: JSONValue, result: JSONValue) async throws {
        if dialect == .claudeControl {
            try await send(.object(["type": .string("control_response"), "response": .object([
                "subtype": .string("success"), "request_id": id, "response": result])]))
        } else { try await send(.object(["id": id, "result": result])) }
    }
    public func reject(id: JSONValue, message: String) async throws {
        if dialect == .claudeControl {
            try await send(.object(["type": .string("control_response"), "response": .object([
                "subtype": .string("error"), "request_id": id, "error": .string(message)])]))
        } else { try await send(.object(["id": id, "error": .object(["code": .number(-32601), "message": .string(message)])])) }
    }
    public func close() {
        disconnect("Connection closed."); channel.stop(); reader?.cancel(); reader = nil
    }
    /// Completes after the event consumer has processed all notifications already decoded.
    public func flushEvents() async {
        guard !ended else { return }
        let id = UUID()
        await withTaskCancellationHandler {
            guard !Task.isCancelled else { return }
            await withCheckedContinuation { continuation in
                barriers[id] = continuation
                self.continuation.yield(.barrier { [weak self] in Task { await self?.finishBarrier(id) } })
            }
        } onCancel: { Task { await self.finishBarrier(id) } }
    }
    private func finishBarrier(_ id: UUID) { barriers.removeValue(forKey: id)?.resume() }
    private func send(_ value: JSONValue) async throws {
        guard !ended else { throw CoincideError("The provider connection is closed.") }
        var value = value
        if dialect == .jsonRPC2, var object = value.object {
            object["jsonrpc"] = .string("2.0"); value = .object(object)
        }
        let payload = value
        try await channel.writePayload {
            var data = try JSONEncoder().encode(payload); data.append(10); return data
        }
    }
    private func writeFinished(_ id: JSONValue) { writes.removeValue(forKey: id) }
    private func consume(_ event: ProcessEvent) {
        do {
            switch event {
            case .stdout(let data):
                for frame in try decoder.append(data) { accept(frame) }
            case .stderr: break // Provider stderr may contain private configuration. Do not persist it.
            case .exited(let code):
                for frame in try decoder.finish() { accept(frame) }
                disconnect("Provider exited (\(code)).")
            }
        } catch { disconnect("Invalid provider protocol: \(error.localizedDescription)"); channel.stop() }
    }
    private func accept(_ frame: JSONValue) {
        if dialect == .jsonRPC2, frame["jsonrpc"].string != "2.0" {
            disconnect("The agent sent an invalid JSON-RPC 2.0 envelope."); channel.stop(); return
        }
        if dialect == .claudeControl {
            switch frame["type"].string {
            case "control_response":
                let response = frame["response"], id = response["request_id"]
                if response["subtype"].string == "error" { fail(id, error: CoincideError(response["error"].string ?? "Claude control request failed.")) }
                else { resolve(id, result: response["response"]) }
            case "control_request":
                continuation.yield(.request(id: frame["request_id"], method: frame["request"]["subtype"].string ?? "unknown", params: frame["request"]))
            default:
                continuation.yield(.notification(method: frame["type"].string ?? "unknown", params: frame))
            }
            return
        }
        if let method = frame["method"].string {
            if frame.object?["id"] != nil {
                continuation.yield(.request(id: frame["id"], method: method, params: frame["params"]))
            } else { continuation.yield(.notification(method: method, params: frame["params"])) }
        } else if frame.object?["id"] != nil {
            let id = frame["id"]
            if frame.object?["error"] != nil { fail(id, error: CoincideError(frame["error"]["message"].string ?? "Provider request failed.")) }
            else { resolve(id, result: frame["result"]) }
        }
    }
    private func resolve(_ id: JSONValue, result: JSONValue) {
        logger.debug("Provider request completed")
        timeouts.removeValue(forKey: id)?.cancel(); pending.removeValue(forKey: id)?.resume(returning: result)
        writes.removeValue(forKey: id) // A valid response must not cancel a completed write.
    }
    private func fail(_ id: JSONValue, error: any Error) {
        logger.debug("Provider request failed")
        timeouts.removeValue(forKey: id)?.cancel(); pending.removeValue(forKey: id)?.resume(throwing: error)
        writes.removeValue(forKey: id)?.cancel()
    }
    private func disconnect(_ message: String) {
        guard !ended else { return }; ended = true
        for id in Array(pending.keys) { fail(id, error: CoincideError(message)) }
        for id in Array(barriers.keys) { finishBarrier(id) }
        continuation.yield(.disconnected(message)); continuation.finish()
    }
    deinit { channel.stop(); reader?.cancel(); for timeout in timeouts.values { timeout.cancel() }; for write in writes.values { write.cancel() } }
}
