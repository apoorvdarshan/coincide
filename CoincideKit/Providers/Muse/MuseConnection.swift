import Foundation

/// Newline-delimited JSON channel to a `muse serve` process. Tests swap in a fake.
@MainActor
protocol MuseTransport: AnyObject {
    var onLine: ((String) -> Void)? { get set }
    /// The process ended on its own, with its exit status and the tail of stderr.
    var onExit: ((Int32, String) -> Void)? { get set }
    func start() throws
    func send(_ line: String)
    /// Stops the process. `onExit` may still fire afterwards.
    func close()
}

/// Runs `muse serve` over stdio, as T3 Code's Muse SDK host does.
@MainActor
final class MuseProcessTransport: MuseTransport {
    var onLine: ((String) -> Void)?
    var onExit: ((Int32, String) -> Void)?

    private let process: LineProcess

    init(executable: URL, arguments: [String], workingDirectory: URL, environment: [String: String]) {
        process = LineProcess(
            executable: executable, arguments: arguments, workingDirectory: workingDirectory, environment: environment)
    }

    func start() throws {
        process.onLine = { [weak self] line in self?.onLine?(line) }
        // Holds the transport until the process is gone, so a closed session still reaps its child.
        process.onExit = { [self] status, stderrTail in
            onExit?(status, stderrTail)
            process.onLine = nil
            process.onExit = nil
        }
        do {
            try process.start()
        } catch {
            process.onLine = nil
            process.onExit = nil
            throw error
        }
    }

    func send(_ line: String) {
        process.write(line)
    }

    func close() {
        // `muse serve` shuts down at the end of its input; T3's SDK gives it 10 s before ending it.
        process.closeInput()
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [process] in process.terminate() }
    }
}

enum MuseRPCError: LocalizedError, Equatable {
    /// Muse answered with an MSP error: its JSON-RPC code, `data.kind` and message.
    case server(code: Int, kind: String, message: String)
    /// The connection ended before the answer arrived.
    case closed(String?)
    case timedOut(method: String)

    var errorDescription: String? {
        switch self {
        case .server(_, _, let message): message
        case .closed(let reason): reason ?? String(localized: "Muse Code stopped.")
        case .timedOut(let method): AgentError.timeout(String(localized: "Muse Code to answer \(method)")).errorDescription
        }
    }

    /// Muse refused the command before admitting anything, so sending it again is safe (the SDK's retry rule).
    var nothingAdmitted: Bool {
        guard case .server(let code, let kind, _) = self else { return false }
        return (code == -32001 && kind == "overloaded") || (code == -32031 && kind == "backpressured")
    }
}

/// The MSP connection T3 Code's Muse SDK (`@muse-code/sdk`) keeps: JSON-RPC 2.0 requests, commands (requests that
/// carry a `commandId`, Muse's idempotency handle), notifications, and requests Muse sends back.
@MainActor
final class MuseConnection {
    var onNotification: ((_ method: String, _ params: JSONValue) -> Void)?
    /// A request Muse sent. The result is the answer; nil answers that the method is not handled.
    var onRequest: ((_ method: String, _ params: JSONValue) -> JSONValue?)?
    /// The process exited without `close()` being called.
    var onClose: ((_ status: Int32, _ stderrTail: String) -> Void)?

    let ids: MuseIDs
    private let transport: MuseTransport
    private let retryDelay: @MainActor (_ attempt: Int) async -> Void
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var timeouts: [Int: Task<Void, Never>] = [:]
    private(set) var isClosed = false

    init(transport: MuseTransport, ids: MuseIDs, retryDelay: @escaping @MainActor (Int) async -> Void = MuseConnection.backoff) {
        self.transport = transport
        self.ids = ids
        self.retryDelay = retryDelay
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
        guard !isClosed else { throw MuseRPCError.closed(nil) }
        let id = nextID
        nextID += 1
        let message: JSONValue = ["jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method), "params": params]
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            timeouts[id] = Task { [weak self] in
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled else { return }
                self?.finish(id, with: .failure(MuseRPCError.timedOut(method: method)))
            }
            transport.send(message.compactJSON)
        }
    }

    /// Sends a command: a request whose params carry `commandId`, minted here unless given. Up to `attempts` times
    /// it is sent again (with the same id) while Muse answers that it admitted nothing, as the SDK does; T3 Code
    /// allows that only for `turn/start`.
    func command(
        _ method: String, _ params: JSONValue, commandID: String? = nil, attempts: Int = 1,
        timeout: Duration = .seconds(30)
    ) async throws -> JSONValue {
        let commandID = commandID ?? ids.next()
        var fields = params.object ?? [:]
        fields["commandId"] = .string(commandID)
        var attempt = 1
        while true {
            do {
                let ack = try await request(method, .object(fields), timeout: timeout)
                // `session/start` and `session/resume` leave the echo out; where it is present it must match.
                if let echo = ack["commandId"]?.string, echo != commandID {
                    throw AgentError.protocolError(String(localized: "Muse Code answered \(method) for another command."))
                }
                return ack
            } catch let error as MuseRPCError where error.nothingAdmitted && attempt < max(1, attempts) {
                await retryDelay(attempt)
                attempt += 1
            }
        }
    }

    func notify(_ method: String, _ params: JSONValue? = nil) {
        guard !isClosed else { return }
        var message: [String: JSONValue] = ["jsonrpc": "2.0", "method": .string(method)]
        if let params { message["params"] = params }
        transport.send(JSONValue.object(message).compactJSON)
    }

    /// Stops the process and fails waiting requests. `onClose` is not called.
    func close() {
        guard !isClosed else { return }
        isClosed = true
        failAll(MuseRPCError.closed(nil))
        transport.close()
    }

    /// The SDK's backoff between retries: a random wait up to 50 ms, doubling per attempt, at most 2 s.
    nonisolated static func backoff(_ attempt: Int) async {
        let ceiling = min(2_000, 50 * (1 << min(max(0, attempt - 1), 6)))
        try? await Task.sleep(for: .milliseconds(Int.random(in: 0...ceiling)))
    }

    private func receive(_ line: String) {
        // A closed connection's process may still flush output; none of it belongs to the session any more.
        guard !isClosed, let message = JSONValue.parse(line), let object = message.object else { return }
        if let method = object["method"]?.string {
            let params = object["params"] ?? .null
            if let id = object["id"], !id.isNull {
                answer(id: id, method: method, params: params)
            } else {
                onNotification?(method, params)
            }
            return
        }
        guard let id = object["id"]?.exactInt else { return }
        if let error = object["error"], !error.isNull {
            let code = error["code"]?.int ?? 0
            let kind = error.at("data.kind")?.string ?? "unknown"
            let text = error["message"]?.string ?? String(localized: "Muse Code returned an error.")
            finish(id, with: .failure(MuseRPCError.server(code: code, kind: kind, message: text)))
        } else {
            finish(id, with: .success(object["result"] ?? .null))
        }
    }

    private func answer(id: JSONValue, method: String, params: JSONValue) {
        if let result = onRequest?(method, params) {
            transport.send(JSONValue.object(["jsonrpc": "2.0", "id": id, "result": result]).compactJSON)
            return
        }
        let error: JSONValue = [
            "code": -32601, "message": .string("method not found: \(method)"),
            "data": ["kind": "methodNotFound", "retryable": false],
        ]
        transport.send(JSONValue.object(["jsonrpc": "2.0", "id": id, "error": error]).compactJSON)
    }

    private func finish(_ id: Int, with result: Result<JSONValue, Error>) {
        timeouts.removeValue(forKey: id)?.cancel()
        pending.removeValue(forKey: id)?.resume(with: result)
    }

    private func failAll(_ error: MuseRPCError) {
        for id in Array(pending.keys) { finish(id, with: .failure(error)) }
    }

    private func transportExited(status: Int32, stderrTail: String) {
        guard !isClosed else { return }
        isClosed = true
        failAll(MuseRPCError.closed(MuseProtocol.exitMessage(status: status, stderr: stderrTail)))
        onClose?(status, stderrTail)
    }
}

/// Mints the UUIDv7 ids Muse expects for commands, sessions and turns, as the SDK's `createUuidV7Mint` does:
/// the millisecond clock in front, a counter that keeps ids made in the same millisecond in order, and random bits.
@MainActor
final class MuseIDs {
    private let generate: () -> String

    init(generate: @escaping () -> String) {
        self.generate = generate
    }

    func next() -> String { generate() }

    /// Ids from the clock and the system's random source.
    static func uuidV7() -> MuseIDs {
        var lastMilliseconds: UInt64 = 0
        var sequence: UInt16 = 0
        return MuseIDs {
            var now = UInt64(max(0, Date().timeIntervalSince1970 * 1000))
            if now <= lastMilliseconds {
                now = lastMilliseconds
                sequence += 1
                if sequence > 0x0fff {
                    now += 1
                    sequence = 0
                }
            } else {
                sequence = 0
            }
            lastMilliseconds = now
            var random = [UInt8](repeating: 0, count: 16)
            for index in random.indices { random[index] = UInt8.random(in: 0...255) }
            return uuidV7(milliseconds: now, sequence: sequence, random: random)
        }
    }

    /// One id: 48 bits of milliseconds, version 7, a 12-bit sequence, the RFC 4122 variant and random bits.
    nonisolated static func uuidV7(milliseconds: UInt64, sequence: UInt16, random: [UInt8]) -> String {
        var bytes = random.count >= 16 ? Array(random.prefix(16)) : random + [UInt8](repeating: 0, count: 16 - random.count)
        var timestamp = milliseconds
        for index in stride(from: 5, through: 0, by: -1) {
            bytes[index] = UInt8(timestamp & 0xff)
            timestamp >>= 8
        }
        bytes[6] = 0x70 | UInt8((sequence >> 8) & 0x0f)
        bytes[7] = UInt8(sequence & 0xff)
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let parts = [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map { range in
            String(hex[hex.index(hex.startIndex, offsetBy: range.lowerBound)..<hex.index(hex.startIndex, offsetBy: range.upperBound)])
        }
        return parts.joined(separator: "-")
    }
}
