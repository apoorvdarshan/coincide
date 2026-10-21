import Foundation

public struct NDJSONDecoder: Sendable {
    private var buffer = Data()
    public let maximumFrameSize: Int
    public init(maximumFrameSize: Int = 16 * 1_024 * 1_024) { self.maximumFrameSize = maximumFrameSize }
    public mutating func append(_ bytes: Data) throws -> [JSONValue] {
        buffer.append(bytes)
        var values: [JSONValue] = []
        while let newline = buffer.firstIndex(of: 10) {
            let line = buffer[..<newline]
            guard line.count <= maximumFrameSize else { throw CoincideError("Provider frame exceeded the size limit.") }
            if !line.allSatisfy({ $0 == 13 || $0 == 32 || $0 == 9 }) {
                values.append(try JSONDecoder().decode(JSONValue.self, from: line))
            }
            buffer.removeSubrange(...newline)
        }
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
}

public actor JSONRPCConnection {
    public nonisolated let events: AsyncStream<RPCEvent>
    private let continuation: AsyncStream<RPCEvent>.Continuation
    private let channel: ProcessChannel
    private var reader: Task<Void, Never>?
    private var pending: [JSONValue: CheckedContinuation<JSONValue, any Error>] = [:]
    private var timeouts: [JSONValue: Task<Void, Never>] = [:]
    private var nextID = 0
    private var decoder = NDJSONDecoder()
    private var ended = false

    public init(executable: URL, arguments: [String], cwd: URL? = nil) throws {
        let (events, continuation) = AsyncStream<RPCEvent>.makeStream()
        self.events = events; self.continuation = continuation
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
    public func request(_ method: String, params: JSONValue = .object([:]), timeout: Duration = .seconds(30)) async throws -> JSONValue {
        guard !ended else { throw CoincideError("The provider connection is closed.") }
        start(); nextID += 1
        let id = JSONValue.number(Double(nextID))
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { response in
                pending[id] = response
                do {
                    try send(.object(["id": id, "method": .string(method), "params": params]))
                    timeouts[id] = Task { [weak self] in
                        do { try await Task.sleep(for: timeout) } catch { return }
                        await self?.fail(id, error: CoincideError("\(method) timed out."))
                    }
                } catch { fail(id, error: error) }
            }
        } onCancel: { Task { await self.fail(id, error: CancellationError()) } }
    }
    public func notify(_ method: String, params: JSONValue? = nil) throws {
        var frame: [String: JSONValue] = ["method": .string(method)]
        if let params { frame["params"] = params }
        try send(.object(frame))
    }
    public func respond(id: JSONValue, result: JSONValue) throws { try send(.object(["id": id, "result": result])) }
    public func reject(id: JSONValue, message: String) throws {
        try send(.object(["id": id, "error": .object(["code": .number(-32601), "message": .string(message)])]))
    }
    public func close() {
        disconnect("Connection closed."); channel.stop(); reader?.cancel(); reader = nil
    }
    private func send(_ value: JSONValue) throws {
        guard !ended else { throw CoincideError("The provider connection is closed.") }
        var data = try JSONEncoder().encode(value); data.append(10); try channel.write(data)
    }
    private func consume(_ event: ProcessEvent) {
        do {
            switch event {
            case .stdout(let data): for frame in try decoder.append(data) { accept(frame) }
            case .stderr: break // Provider stderr may contain private configuration. Do not persist it.
            case .exited(let code):
                for frame in try decoder.finish() { accept(frame) }
                disconnect("Provider exited (\(code)).")
            }
        } catch { disconnect("Invalid provider protocol: \(error.localizedDescription)"); channel.stop() }
    }
    private func accept(_ frame: JSONValue) {
        if let method = frame["method"].string {
            if frame.object?["id"] != nil {
                continuation.yield(.request(id: frame["id"], method: method, params: frame["params"]))
            } else { continuation.yield(.notification(method: method, params: frame["params"])) }
        } else if frame.object?["id"] != nil {
            let id = frame["id"]
            if frame.object?["error"] != nil { fail(id, error: CoincideError(frame["error"]["message"].string ?? "Provider request failed.")) }
            else if let waiter = pending.removeValue(forKey: id) {
                timeouts.removeValue(forKey: id)?.cancel(); waiter.resume(returning: frame["result"])
            }
        }
    }
    private func fail(_ id: JSONValue, error: any Error) {
        timeouts.removeValue(forKey: id)?.cancel(); pending.removeValue(forKey: id)?.resume(throwing: error)
    }
    private func disconnect(_ message: String) {
        guard !ended else { return }; ended = true
        for id in Array(pending.keys) { fail(id, error: CoincideError(message)) }
        continuation.yield(.disconnected(message)); continuation.finish()
    }
    deinit { channel.stop(); reader?.cancel(); for timeout in timeouts.values { timeout.cancel() } }
}
