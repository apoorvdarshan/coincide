import CryptoKit
import Foundation

public typealias MuseMSPResponseHandler = @Sendable (Result<JSONValue, MuseMSPError>) async -> Void

public enum MuseMSPEvent: Sendable {
    case notification(method: String, params: JSONValue)
    case serverRequest(id: Int, method: String, params: JSONValue)
    /// Consumers await callbacks before taking the next event. Responses themselves
    /// never wait on the consumer, so an unopened stream cannot deadlock close.
    case callback(@Sendable () async -> Void)
    case closed(MuseMSPError?)
}

/// Native MSP v1 stdio. Owns the exact child PID, not its descendants.
public actor MuseMSPConnection {
    public nonisolated let events: AsyncStream<MuseMSPEvent>
    private let output: AsyncStream<MuseMSPEvent>.Continuation
    private let channel: ProcessChannel
    private let requestTimeout: Duration
    private let shutdownTimeout: Duration
    private var reader: Task<Void, Never>?
    private var closeTask: Task<Void, Never>?
    private var writeTail: Task<Void, Never>?
    private var pending: [Int: Pending] = [:]
    private var presentations = Set<Int>()
    private var retired = Set<Int>()
    private var commands: [String: CommandMemory] = [:]
    private var nextID = 0
    private var initializeStarted = false
    private var initialized = false
    private var closing = false
    private var ended = false
    private var framer = MuseMSPFramer()
    private struct Pending {
        let continuation: CheckedContinuation<JSONValue, any Error>
        let callback: MuseMSPResponseHandler?
        let commandID: String?
        var timeout: Task<Void, Never>?
    }
    private struct CommandMemory { let signature: Data; var acknowledgement: Data? }

    public init(executable: URL, arguments: [String], cwd: URL, environment: [String: String]? = nil,
                requestTimeout: Duration = .seconds(30), shutdownTimeout: Duration = .seconds(10), eventBufferLimit: Int = 128) throws {
        guard requestTimeout > .zero, shutdownTimeout > .zero, (4...512).contains(eventBufferLimit) else { throw MuseMSPError(.invalidInput) }
        var environment = environment ?? ProcessChannel.environment()
        for key in environment.keys.filter({ $0.uppercased() == "META_API_KEY" }) { environment.removeValue(forKey: key) }
        environment["MUSE_NO_AUTO_UPDATE"] = "1"
        do { channel = try ProcessChannel(executable: executable, arguments: arguments, cwd: cwd, environment: environment, eventBufferLimit: 64) }
        catch { throw MuseMSPError(.closed) }
        self.requestTimeout = requestTimeout; self.shutdownTimeout = shutdownTimeout
        (events, output) = AsyncStream.makeStream(bufferingPolicy: .bufferingOldest(eventBufferLimit))
        output.onTermination = { [weak self] reason in
            if case .cancelled = reason { Task { await self?.close() } }
        }
    }

    public func mintCommandID() -> String { MuseUUIDv7.make().uuidString.lowercased() }

    public func initialize(userInputDialogs: Bool = true) async throws -> MuseInitializeResult {
        guard !initializeStarted, !closing, !ended else { throw MuseMSPError(.invalidInput) }
        initializeStarted = true
        do {
            let value = try await request("initialize", params: .object([
                "clientInfo": .object(["name": .string("coincide"), "title": .string("Coincide"), "version": .string("1")]),
                "capabilities": .object(["requestedCapabilities": .array([.string("sessionMcp")]), "userInputDialogs": .bool(userInputDialogs)])
            ]), timeout: .seconds(20), onResponse: nil)
            let result = try MuseProtocol.initialize(value)
            try Task.checkCancellation()
            try await write(.object(["jsonrpc": .string("2.0"), "method": .string("initialized")]))
            try Task.checkCancellation()
            guard !closing, !ended else { throw MuseMSPError(.closed) }
            initialized = true
            return result
        } catch {
            terminate(error as? MuseMSPError ?? .init(.closed))
            throw error as? MuseMSPError ?? MuseMSPError(.closed)
        }
    }

    /// Recoverable failures, including local rejection before registration, are
    /// delivered once in event order. Fatal transport loss uses only `.closed`.
    public func query(_ method: String, params: JSONValue = .object([:]), onResponse: MuseMSPResponseHandler? = nil) async throws -> JSONValue {
        guard !closing, !ended else { throw MuseMSPError(.closed) }
        guard initialized, method != "initialize", method != "initialized" else { throw localFailure(.init(.invalidInput), onResponse: onResponse) }
        return try await request(method, params: params, onResponse: onResponse)
    }

    public func command(_ method: String, params: JSONValue = .object([:]), commandID: String, onResponse: MuseMSPResponseHandler? = nil) async throws -> JSONValue {
        guard !closing, !ended else { throw MuseMSPError(.closed) }
        let fields: [String: JSONValue]
        do {
            guard initialized, method != "initialize", method != "initialized", var values = params.object else { throw MuseMSPError(.invalidInput) }
            _ = try MuseProtocol.identity(.string(commandID), command: true)
            guard values["commandId"] == nil || values["commandId"] == .string(commandID) else { throw MuseMSPError(.invalidInput) }
            values["commandId"] = .string(commandID)
            let signed: JSONValue = .object(["method": .string(method), "params": .object(values)])
            let signature = try fingerprint(signed)
            if let memory = commands[commandID] {
                guard memory.signature == signature else { throw MuseMSPError(.invalidInput) }
            } else {
                guard commands.count < 4_096 else { throw MuseMSPError(.overflow) }
                commands[commandID] = .init(signature: signature)
            }
            fields = values
        } catch {
            throw localFailure(error as? MuseMSPError ?? .init(.invalidInput), onResponse: onResponse)
        }
        // No mutation retries: an uncertain intake belongs to the same commandID.
        // Keep this await outside the preflight catch: registered failures already
        // own their callback, or a single fatal `.closed` event.
        return try await request(method, params: .object(fields), commandID: commandID, onResponse: onResponse)
    }

    public func acknowledgePresentation(id: Int) async throws {
        guard presentations.remove(id) != nil else { throw MuseMSPError(.invalidInput) }
        try await write(.object(["jsonrpc": .string("2.0"), "id": .number(Double(id)), "result": .object([:])]))
    }

    private func startReader() {
        guard reader == nil else { return }
        let source = channel.events
        reader = Task { [weak self] in
            for await event in source { guard let self else { return }; await self.consume(event) }
            await self?.sourceEnded()
        }
    }
    private func request(_ method: String, params: JSONValue, commandID: String? = nil, timeout: Duration? = nil, onResponse: MuseMSPResponseHandler?) async throws -> JSONValue {
        guard !closing, !ended else { throw MuseMSPError(.closed) }
        guard pending.count < 128, nextID < 9_007_199_254_740_991,
              !method.isEmpty, method.utf8.count <= 256, !method.unicodeScalars.contains(where: { $0.value < 32 }), params.object != nil else { throw localFailure(.init(.invalidInput), onResponse: onResponse) }
        startReader(); nextID += 1; let id = nextID, timeoutDuration = timeout ?? requestTimeout
        return try await withTaskCancellationHandler {
            do { try Task.checkCancellation() }
            catch { throw localFailure(.init(.cancelled), onResponse: onResponse) }
            return try await withCheckedThrowingContinuation { continuation in
                pending[id] = .init(continuation: continuation, callback: onResponse, commandID: commandID)
                let frame: JSONValue = .object(["jsonrpc": .string("2.0"), "id": .number(Double(id)), "method": .string(method), "params": params])
                let previous = writeTail, channel = channel
                let task = Task { [weak self] in
                    await previous?.value
                    guard await self?.mayWrite(id) == true else { return }
                    do { try await Self.write(frame, channel: channel) }
                    catch { await self?.writeFailed() }
                }
                writeTail = task
                pending[id]?.timeout = Task { [weak self] in
                    do { try await Task.sleep(for: timeoutDuration) } catch { return }
                    await self?.retire(id, error: .init(.timedOut))
                }
            }
        } onCancel: { Task { await self.retire(id, error: .init(.cancelled)) } }
    }
    private func localFailure(_ error: MuseMSPError, onResponse: MuseMSPResponseHandler?) -> MuseMSPError {
        if let callback = onResponse { emit(.callback { await callback(.failure(error)) }) }
        return error
    }
    private func mayWrite(_ id: Int) -> Bool { pending[id] != nil && !ended }
    private func retire(_ id: Int, error: MuseMSPError) {
        guard let waiter = pending.removeValue(forKey: id) else { return }
        waiter.timeout?.cancel()
        guard retired.count < 4_096 else { waiter.continuation.resume(throwing: error); terminate(.init(.overflow)); return }
        retired.insert(id)
        if let callback = waiter.callback { emit(.callback { await callback(.failure(error)) }) }
        waiter.continuation.resume(throwing: error)
        // A caller may have stronger, already-observed terminal proof. Timeout or
        // cancellation alone does not kill a healthy successor's shared process.
    }
    private func write(_ frame: JSONValue) async throws {
        guard !closing, !ended else { throw MuseMSPError(.closed) }
        let previous = writeTail, channel = channel
        let task = Task { await previous?.value; try await Self.write(frame, channel: channel) }
        writeTail = Task { _ = try? await task.value }
        do { try await task.value } catch { terminate(.init(.closed)); throw MuseMSPError(.closed) }
    }
    private static func write(_ frame: JSONValue, channel: ProcessChannel) async throws {
        try checkBudget(frame)
        try await channel.writePayload {
            var data = try JSONEncoder().encode(frame)
            guard data.count <= MuseProtocol.maximumFrameBytes else { throw MuseMSPError(.overflow) }
            data.append(10); return data
        }
    }
    private func fingerprint(_ value: JSONValue) throws -> Data {
        try Self.checkBudget(value)
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(value)
        guard data.count <= MuseProtocol.maximumFrameBytes else { throw MuseMSPError(.overflow) }
        return Data(SHA256.hash(data: data))
    }
    private static func checkBudget(_ value: JSONValue) throws {
        var remaining = MuseProtocol.maximumFrameBytes, nodes = 100_000
        func visit(_ item: JSONValue, depth: Int) throws {
            nodes -= 1; remaining -= 8
            guard nodes >= 0, remaining >= 0, depth <= 64 else { throw MuseMSPError(.overflow) }
            switch item {
            case .string(let text): remaining -= text.utf8.count
            case .object(let fields): for (key, value) in fields { remaining -= key.utf8.count; try visit(value, depth: depth + 1) }
            case .array(let values): for value in values { try visit(value, depth: depth + 1) }
            case .number(let number): guard number.isFinite else { throw MuseMSPError(.invalidInput) }
            default: break
            }
            guard remaining >= 0 else { throw MuseMSPError(.overflow) }
        }
        try visit(value, depth: 0)
    }

    private func consume(_ event: ProcessEvent) {
        guard !ended else { return }
        do {
            switch event {
            case .stdout(let bytes): for frame in try framer.append(bytes) { try accept(frame); if ended { break } }
            case .stderr: break
            case .exited:
                try framer.finish()
                end(closing ? nil : .init(.closed))
            }
        } catch { terminate(channel.outputOverflowed ? .init(.overflow) : error as? MuseMSPError ?? .init(.protocolViolation)) }
    }
    private func accept(_ frame: JSONValue) throws {
        guard let object = frame.object, frame["jsonrpc"] == .string("2.0") else { throw MuseMSPError(.protocolViolation) }
        if let method = frame["method"].string {
            guard object["result"] == nil, object["error"] == nil, !method.isEmpty, method.utf8.count <= 256 else { throw MuseMSPError(.protocolViolation) }
            let params = object["params"] ?? .object([:])
            guard params.object != nil else { throw MuseMSPError(.protocolViolation) }
            if let value = object["id"] {
                let id = try MuseProtocol.integer(value, minimum: 1, maximum: 9_007_199_254_740_991)
                guard presentations.count < 64, presentations.insert(id).inserted else { throw MuseMSPError(.protocolViolation) }
                emit(.serverRequest(id: id, method: method, params: params))
            } else { emit(.notification(method: method, params: params)) }
            return
        }
        guard object["method"] == nil else { throw MuseMSPError(.protocolViolation) }
        let id = try MuseProtocol.integer(frame["id"], minimum: 1, maximum: 9_007_199_254_740_991)
        guard (object["result"] != nil) != (object["error"] != nil) else { throw MuseMSPError(.protocolViolation) }
        if retired.remove(id) != nil { return }
        guard let waiter = pending.removeValue(forKey: id) else { throw MuseMSPError(.protocolViolation) }
        waiter.timeout?.cancel()
        let result: Result<JSONValue, MuseMSPError>
        do {
            if let raw = object["result"], raw.object != nil {
                if let commandID = waiter.commandID {
                    if let echo = raw.object?["commandId"], echo != .string(commandID) { throw MuseMSPError(.protocolViolation) }
                    let acknowledgement = try fingerprint(raw)
                    if let held = commands[commandID]?.acknowledgement, held != acknowledgement { throw MuseMSPError(.protocolViolation) }
                    commands[commandID]?.acknowledgement = acknowledgement
                }
                result = .success(raw)
            } else if let error = object["error"], error.object != nil, error["message"].string != nil {
                result = .failure(.init(.remoteFailure, code: try MuseProtocol.integer(error["code"], minimum: -Int.max), nativeKind: error["data"]["kind"].string))
            } else { throw MuseMSPError(.protocolViolation) }
        } catch {
            waiter.continuation.resume(throwing: MuseMSPError(.protocolViolation))
            throw MuseMSPError(.protocolViolation)
        }
        if let callback = waiter.callback { emit(.callback { await callback(result) }) }
        waiter.continuation.resume(with: result.mapError { $0 as any Error })
    }
    private func emit(_ event: MuseMSPEvent) {
        guard !ended else { return }
        switch output.yield(event) {
        case .enqueued(let remaining) where remaining <= 1:
            // Reserve the final slot for an explicit overflow terminal. No
            // accepted notification is dropped to make room for that terminal.
            end(.init(.overflow)); channel.stop()
        case .dropped: end(.init(.overflow)); channel.stop()
        case .terminated: end(.init(.closed)); channel.stop()
        default: break
        }
    }
    private func writeFailed() { terminate(.init(.closed)) }
    private func sourceEnded() {
        guard !ended else { return }
        if channel.outputOverflowed { terminate(.init(.overflow)); return }
        do { try framer.finish(); end(channel.outputOverflowed ? .init(.overflow) : closing ? nil : .init(.closed)) }
        catch { terminate(.init(.protocolViolation)) }
    }
    private func terminate(_ error: MuseMSPError) { end(error); channel.stop() }
    private func end(_ error: MuseMSPError?) {
        guard !ended else { return }; ended = true
        let waits = pending; pending.removeAll(); presentations.removeAll()
        for waiter in waits.values {
            waiter.timeout?.cancel()
            // Fatal close is its own ordered event. Pending callers are all
            // resolved directly; enqueuing one callback per waiter here could
            // overwrite that terminal in a full bounded event queue.
            waiter.continuation.resume(throwing: error ?? MuseMSPError(.closed))
        }
        _ = output.yield(.closed(error)); output.finish()
    }
    public func close() async {
        if let closeTask { await closeTask.value; return }
        startReader(); closing = true
        let tail = writeTail, source = reader, channel = channel, budget = shutdownTimeout
        let task = Task {
            let deadline = Task {
                do { try await Task.sleep(for: budget) } catch { return }
                await channel.stopAndDrain()
            }
            await tail?.value
            channel.finishInput()
            await source?.value
            deadline.cancel(); await deadline.value
            await channel.stopAndDrain()
        }
        closeTask = task
        await task.value
        end(nil)
    }
}

/// Byte-bounded LF framing. UTF8 is decoded only after a complete line, and EOF
/// never manufactures a missing newline. Separate from ACP's permissive decoder.
struct MuseMSPFramer {
    private var buffer = Data()
    mutating func append(_ bytes: Data) throws -> [JSONValue] {
        var frames: [JSONValue] = [], offset = bytes.startIndex
        while offset < bytes.endIndex {
            let newline = bytes[offset...].firstIndex(of: 10)
            let end = newline ?? bytes.endIndex
            let total = buffer.count + bytes.distance(from: offset, to: end)
            let last = end > offset ? bytes[bytes.index(before: end)] : buffer.last
            guard total <= MuseProtocol.maximumFrameBytes || (total == MuseProtocol.maximumFrameBytes + 1 && last == 13) else { throw MuseMSPError(.overflow) }
            buffer.append(contentsOf: bytes[offset..<end])
            guard let newline else { break }
            if buffer.last == 13 { buffer.removeLast() }
            guard buffer.count <= MuseProtocol.maximumFrameBytes else { throw MuseMSPError(.overflow) }
            if !buffer.allSatisfy({ $0 == 32 || $0 == 9 || $0 == 13 }) {
                guard String(data: buffer, encoding: .utf8) != nil else { throw MuseMSPError(.protocolViolation) }
                do { frames.append(try JSONDecoder().decode(JSONValue.self, from: buffer)) }
                catch { throw MuseMSPError(.protocolViolation) }
            }
            buffer.removeAll(keepingCapacity: true); offset = bytes.index(after: newline)
        }
        return frames
    }
    func finish() throws { guard buffer.isEmpty else { throw MuseMSPError(.protocolViolation) } }
}

public enum MuseUUIDv7 {
    private static let clock = MuseUUIDClock()
    public static func make() -> UUID { clock.make() }
}
private final class MuseUUIDClock: @unchecked Sendable {
    private let lock = NSLock()
    private var lastMilliseconds: UInt64 = 0
    private var sequence: UInt16 = 0
    func make() -> UUID {
        lock.lock(); defer { lock.unlock() }
        let now = UInt64(max(0, Date().timeIntervalSince1970 * 1_000))
        if now > lastMilliseconds { lastMilliseconds = now; sequence = 0 }
        else if sequence == 0x0fff { lastMilliseconds += 1; sequence = 0 }
        else { sequence += 1 }
        var bytes = withUnsafeBytes(of: UUID().uuid) { Array($0) }
        for index in 0..<6 { bytes[index] = UInt8((lastMilliseconds >> ((5 - index) * 8)) & 0xff) }
        bytes[6] = 0x70 | UInt8(sequence >> 8); bytes[7] = UInt8(sequence & 0xff); bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
