import Foundation

public struct AntigravityWireError: LocalizedError, Sendable, Equatable {
    public enum Kind: String, Sendable { case invalidConfiguration, unavailable, invalidRequest, protocolViolation, remoteFailure, signInRequired, overflow, cancelled, timedOut, closed }
    public let kind: Kind
    public let code: Int?
    public init(_ kind: Kind, code: Int? = nil) { self.kind = kind; self.code = code }
    public var errorDescription: String? {
        switch kind {
        case .invalidConfiguration: "The Antigravity configuration is invalid. Check its runtime and selected account method."
        case .unavailable: "The Antigravity server and its executable harness are unavailable."
        case .invalidRequest: "The Antigravity request is invalid. Refresh its options and try again."
        case .protocolViolation: "Antigravity sent an unsupported response. Reopen the conversation to reconcile it."
        case .remoteFailure: "Antigravity could not accept the request. Check its account and selected options."
        case .signInRequired: "Sign in to Antigravity in Settings before continuing."
        case .overflow: "Antigravity exceeded the safe buffer limit. Reopen the conversation to reconcile it."
        case .cancelled: "The Antigravity request was cancelled."
        case .timedOut: "Antigravity did not confirm the request. Reopen the conversation to reconcile it."
        case .closed: "The Antigravity connection closed. Reopen the conversation to reconcile it."
        }
    }
}

/// Runtime-only OAuth handoff. Its sensitive URL/state never enter descriptions or Codable.
public final class AntigravityAuthorizationURL: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let authorizationURL: URL
    public let redirectURI: URL
    public let state: String
    public init(_ string: String) throws {
        guard string.utf8.count <= 16_384, !string.unicodeScalars.contains(where: { $0.value <= 32 || $0.value == 127 }),
              let url = URLComponents(string: string), url.scheme == "https", url.host == "accounts.google.com",
              url.port == nil || url.port == 443, url.user == nil, url.password == nil, url.fragment == nil,
              url.percentEncodedPath == "/o/oauth2/v2/auth", let query = url.queryItems else { throw AntigravityWireError(.protocolViolation) }
        func one(_ name: String) throws -> String {
            let values = query.filter { $0.name == name }
            guard values.count == 1, let value = values[0].value else { throw AntigravityWireError(.protocolViolation) }; return value
        }
        let state = try one("state"), redirect = try one("redirect_uri")
        guard try one("response_type") == "code", !state.isEmpty, state.utf8.count <= 512, !state.contains(where: \.isWhitespace),
              let callback = URLComponents(string: redirect), callback.scheme == "http", callback.host == "127.0.0.1",
              let port = callback.port, (1_024...65_535).contains(port), redirect == "http://127.0.0.1:\(port)/",
              let authorizationURL = url.url, let redirectURI = callback.url else { throw AntigravityWireError(.protocolViolation) }
        self.authorizationURL = authorizationURL; self.redirectURI = redirectURI; self.state = state
    }
    public var description: String { "AntigravityAuthorizationURL(<redacted>)" }
    public var debugDescription: String { description }
}

public typealias AntigravityResponseHandler = @Sendable (Result<JSONValue, AntigravityWireError>) async -> Void
public enum AntigravityWireEvent: Sendable {
    case notification(method: String, params: JSONValue)
    case serverRequest(id: JSONValue, method: String, params: JSONValue)
    case authorizationURL(AntigravityAuthorizationURL)
    /// Await each callback before consuming another event. Direct awaits are not ordering proof.
    case callback(@Sendable () async -> Void)
    case closed(AntigravityWireError?)
}

/// Native flat ACP2 over an owned Antigravity runtime; no generic ACP dialect fallback.
public actor AntigravityConnection {
    public static let maximumFrameBytes = 16 * 1_024 * 1_024
    public static let authorizationStdoutPrefix = "Open the following link to authenticate the ACP server: "
    public nonisolated let events: AsyncStream<AntigravityWireEvent>
    private let output: AsyncStream<AntigravityWireEvent>.Continuation
    private let runtime: AntigravityRuntime
    private let requestTimeout: Duration
    private let allowAuthorizationURLs: Bool
    private var authorization: AntigravityAuthorizationURL?
    private var reader: Task<Void, Never>?
    private var closeTask: Task<Void, Never>?
    private var writeTail: Task<Void, Never>?
    private var pending: [Int: Pending] = [:]
    private var requests = Set<JSONValue>()
    private var retired = Set<Int>()
    private var barriers: [UUID: CheckedContinuation<Void, any Error>] = [:]
    private var nextID = 0
    private var initialized = false
    private var initializeStarted = false
    private var closing = false
    private var ended = false
    private var stdout = AntigravityLineFramer(maximum: AntigravityConnection.maximumFrameBytes)
    private var stderr = AntigravityStderrFramer()
    private struct Pending {
        let continuation: CheckedContinuation<JSONValue, any Error>
        let callback: AntigravityResponseHandler?
        let ticket: AntigravityWriteTicket
        var timer: Task<Void, Never>?
    }
    public init(runtime: AntigravityRuntime, requestTimeout: Duration = .seconds(30), eventBufferLimit: Int = 128, allowAuthorizationURLs: Bool = false) throws {
        guard requestTimeout > .zero, (4...512).contains(eventBufferLimit) else { throw AntigravityWireError(.invalidRequest) }
        self.runtime = runtime; self.requestTimeout = requestTimeout; self.allowAuthorizationURLs = allowAuthorizationURLs
        (events, output) = AsyncStream.makeStream(bufferingPolicy: .bufferingOldest(eventBufferLimit))
        output.onTermination = { [weak self] reason in if case .cancelled = reason { Task { await self?.close() } } }
    }
    public func initialize(clientCapabilities: JSONValue = .object([:]), timeout: Duration = .seconds(30)) async throws -> JSONValue {
        guard !initializeStarted, !closing, !ended, clientCapabilities.object != nil, timeout > .zero else { throw AntigravityWireError(.invalidRequest) }
        initializeStarted = true
        do {
            let result = try await perform("initialize", params: .object([
                "protocolVersion": .number(2), "clientInfo": .object(["name": .string("coincide"), "title": .string("Coincide"), "version": .string("0.1.0")]),
                "clientCapabilities": clientCapabilities
            ]), timeout: timeout, onResponse: nil)
            guard [JSONValue.number(1), .number(2)].contains(result["protocolVersion"]), result["agentCapabilities"].object != nil,
                  result["agentInfo"].object != nil, result["authMethods"].array != nil, !closing, !ended else { throw AntigravityWireError(.protocolViolation) }
            initialized = true; return result
        } catch { let safe = Self.safe(error); terminate(safe); throw safe }
    }
    /// Local rejection and pre-registration cancellation also receive exactly one
    /// ordered callback. Fatal wire loss uses a single ordered `.closed` event.
    public func request(_ method: String, params: JSONValue = .object([:]), timeout: Duration? = nil, onResponse: AntigravityResponseHandler? = nil) async throws -> JSONValue {
        guard !closing, !ended else { throw AntigravityWireError(.closed) }
        guard initialized, method != "initialize" else { throw localFailure(.init(.invalidRequest), callback: onResponse) }
        return try await perform(method, params: params, timeout: timeout ?? requestTimeout, onResponse: onResponse)
    }
    /// Waits for preceding wire events. Call from outside the event consumer;
    /// a consumer cannot wait for a callback that it must itself execute.
    public func flushEvents() async throws {
        guard !closing, !ended else { throw AntigravityWireError(.closed) }
        let id = UUID()
        try await withTaskCancellationHandler {
            do { try Task.checkCancellation() } catch { throw AntigravityWireError(.cancelled) }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                barriers[id] = continuation
                emit(.callback { [weak self] in await self?.settleBarrier(id) })
            }
        } onCancel: { Task { await self.settleBarrier(id, error: .init(.cancelled)) } }
    }
    private func settleBarrier(_ id: UUID, error: AntigravityWireError? = nil) {
        guard let waiter = barriers.removeValue(forKey: id) else { return }
        if let error { waiter.resume(throwing: error) } else { waiter.resume() }
    }
    public func notify(_ method: String, params: JSONValue = .object([:])) async throws {
        guard !Task.isCancelled else { throw AntigravityWireError(.cancelled) }
        guard initialized, !closing, !ended else { throw AntigravityWireError(.closed) }
        guard Self.validMethod(method), params.object != nil else { throw AntigravityWireError(.invalidRequest) }
        try await write(Self.encoded(.object(["jsonrpc": .string("2.0"), "method": .string(method), "params": params])))
    }
    public func respond(id: JSONValue, result: JSONValue) async throws {
        guard requests.contains(id), !closing, !ended else { throw AntigravityWireError(.invalidRequest) }
        let data = try Self.encoded(.object(["jsonrpc": .string("2.0"), "id": id, "result": result]))
        requests.remove(id); try await write(data)
    }
    public func reject(id: JSONValue, code: Int = -32601) async throws {
        guard (-32_768...32_767).contains(code) else { throw AntigravityWireError(.invalidRequest) }
        try await respondError(id: id, code: code)
    }
    private func respondError(id: JSONValue, code: Int) async throws {
        guard requests.remove(id) != nil, !closing, !ended else { throw AntigravityWireError(.invalidRequest) }
        try await write(Self.encoded(.object(["jsonrpc": .string("2.0"), "id": id, "error": .object(["code": .number(Double(code)), "message": .string("Coincide could not complete this request.")]) ])))
    }
    private func startReader() {
        guard reader == nil else { return }; let source = runtime.events
        reader = Task { [weak self] in
            for await event in source { guard let self else { return }; await self.consume(event) }
            await self?.sourceEnded()
        }
    }
    private func perform(_ method: String, params: JSONValue, timeout: Duration, onResponse: AntigravityResponseHandler?) async throws -> JSONValue {
        guard !closing, !ended else { throw AntigravityWireError(.closed) }
        let data: Data, id: Int
        do {
            guard pending.count < 128, (nextID < 9_007_199_254_740_991), (timeout > .zero), Self.validMethod(method), params.object != nil else { throw AntigravityWireError(.invalidRequest) }
            id = nextID + 1
            data = try Self.encoded(.object(["jsonrpc": .string("2.0"), "id": .number(Double(id)), "method": .string(method), "params": params]))
        } catch { throw localFailure(Self.safe(error), callback: onResponse) }
        nextID = id; startReader(); let ticket = AntigravityWriteTicket()
        return try await withTaskCancellationHandler {
            do { try Task.checkCancellation() } catch { throw localFailure(.init(.cancelled), callback: onResponse) }
            return try await withCheckedThrowingContinuation { continuation in
                pending[id] = .init(continuation: continuation, callback: onResponse, ticket: ticket)
                let previous = writeTail, runtime = runtime
                writeTail = Task { [weak self] in
                    await previous?.value
                    guard await self?.mayWrite(id) == true else { return }
                    do { try await runtime.write(data, ticket: ticket) }
                    catch let error as AntigravityWireError where error.kind == .cancelled { await self?.retire(id, error: error) }
                    catch { await self?.terminate(.init(.closed)) }
                }
                pending[id]?.timer = Task { [weak self] in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    await self?.retire(id, error: .init(.timedOut))
                }
            }
        } onCancel: { ticket.cancel(); Task { await self.retire(id, error: .init(.cancelled)) } }
    }
    private func mayWrite(_ id: Int) -> Bool { pending[id] != nil && !ended }
    private func localFailure(_ error: AntigravityWireError, callback: AntigravityResponseHandler?) -> AntigravityWireError {
        if let callback { emit(.callback { await callback(.failure(error)) }) }; return error
    }
    private func retire(_ id: Int, error: AntigravityWireError) {
        guard let waiter = pending.removeValue(forKey: id) else { return }
        waiter.ticket.cancel()
        waiter.timer?.cancel()
        guard retired.count < 4_096 else { waiter.continuation.resume(throwing: error); terminate(.init(.overflow)); return }
        retired.insert(id)
        if let callback = waiter.callback { emit(.callback { await callback(.failure(error)) }) }
        waiter.continuation.resume(throwing: error)
    }
    private func write(_ data: Data) async throws {
        guard !Task.isCancelled else { throw AntigravityWireError(.cancelled) }
        guard !closing, !ended else { throw AntigravityWireError(.closed) }
        let previous = writeTail, runtime = runtime, ticket = AntigravityWriteTicket()
        let task = Task { await previous?.value; try await runtime.write(data, ticket: ticket) }
        writeTail = Task { _ = try? await task.value }
        try await withTaskCancellationHandler {
            do {
                try await task.value
                guard !Task.isCancelled else { throw AntigravityWireError(.cancelled) }
            } catch let error as AntigravityWireError where error.kind == .cancelled { throw error }
            catch { terminate(.init(.closed)); throw AntigravityWireError(.closed) }
        } onCancel: { ticket.cancel() }
    }
    private func consume(_ event: AntigravityProcessEvent) {
        guard !ended else { return }
        do {
            guard !runtime.outputOverflowed else { throw AntigravityWireError(.overflow) }
            switch event {
            case .stdout(let data):
                for line in try stdout.append(data) {
                    guard let string = String(data: line, encoding: .utf8) else { throw AntigravityWireError(.protocolViolation) }
                    if string.hasPrefix(Self.authorizationStdoutPrefix) { try handleAuthorization(String(string.dropFirst(Self.authorizationStdoutPrefix.count))) }
                    else {
                        let value: JSONValue
                        do { value = try JSONDecoder().decode(JSONValue.self, from: line) } catch { throw AntigravityWireError(.protocolViolation) }
                        try accept(value)
                    }
                    if ended { break }
                }
            case .stderr(let data):
                for line in stderr.append(data) where line.hasPrefix(runtime.browserMarker) {
                    let raw = Data(line.dropFirst(runtime.browserMarker.count).utf8), string: String
                    do { string = try JSONDecoder().decode(String.self, from: raw) } catch { continue }
                    // Arbitrary stderr is never persisted or treated as JSON-RPC.
                    // Only this owner's browser marker can carry an auth handoff.
                    try handleAuthorization(string)
                }
            case .exited: try stdout.finish(); end(closing ? nil : .init(.closed))
            }
        } catch { terminate(Self.safe(error)) }
    }
    private func handleAuthorization(_ string: String) throws {
        let value = try AntigravityAuthorizationURL(string)
        guard allowAuthorizationURLs else { throw AntigravityWireError(.signInRequired) }
        if let old = authorization {
            guard old.authorizationURL == value.authorizationURL, old.state == value.state, old.redirectURI == value.redirectURI else { throw AntigravityWireError(.protocolViolation) }; return
        }
        authorization = value; emit(.authorizationURL(value))
    }
    private func accept(_ value: JSONValue) throws {
        guard let frame = value.object, value["jsonrpc"] == .string("2.0") else { throw AntigravityWireError(.protocolViolation) }
        if let method = value["method"].string {
            guard Self.validMethod(method), frame["result"] == nil, frame["error"] == nil else { throw AntigravityWireError(.protocolViolation) }
            let params = frame["params"] ?? .object([:]); guard params.object != nil else { throw AntigravityWireError(.protocolViolation) }
            if let id = frame["id"] {
                guard Self.validID(id), requests.count < 64, requests.insert(id).inserted else { throw AntigravityWireError(.protocolViolation) }
                emit(.serverRequest(id: id, method: method, params: params))
            } else { emit(.notification(method: method, params: params)) }; return
        }
        guard frame["method"] == nil, case .number(let number) = value["id"], let id = Int(exactly: number),
              (frame["result"] != nil) != (frame["error"] != nil) else { throw AntigravityWireError(.protocolViolation) }
        if retired.remove(id) != nil { return }
        guard let waiter = pending.removeValue(forKey: id) else { throw AntigravityWireError(.protocolViolation) }
        waiter.timer?.cancel()
        let result: Result<JSONValue, AntigravityWireError>
        if let value = frame["result"] { result = .success(value) }
        else if let error = frame["error"], error.object != nil, error["message"].string != nil,
                case .number(let code) = error["code"], let code = Int(exactly: code) { result = .failure(.init(.remoteFailure, code: code)) }
        else { waiter.continuation.resume(throwing: AntigravityWireError(.protocolViolation)); throw AntigravityWireError(.protocolViolation) }
        if let callback = waiter.callback { emit(.callback { await callback(result) }) }
        waiter.continuation.resume(with: result.mapError { $0 as any Error })
    }
    private func emit(_ value: AntigravityWireEvent) {
        guard !ended else { return }
        switch output.yield(value) {
        case .enqueued(let remaining) where remaining <= 1: terminate(.init(.overflow))
        case .dropped: terminate(.init(.overflow))
        case .terminated: terminate(.init(.closed))
        default: break
        }
    }
    private func sourceEnded() {
        guard !ended else { return }
        do { try stdout.finish(); terminate(runtime.outputOverflowed ? .init(.overflow) : .init(.closed)) }
        catch { terminate(Self.safe(error)) }
    }
    private func terminate(_ error: AntigravityWireError) {
        end(error); let runtime = runtime; runtime.stop(); Task { await runtime.close() }
    }
    private func end(_ error: AntigravityWireError?) {
        guard !ended else { return }; ended = true
        let waits = pending; pending.removeAll(); requests.removeAll()
        for waiter in waits.values { waiter.ticket.cancel(); waiter.timer?.cancel(); waiter.continuation.resume(throwing: error ?? AntigravityWireError(.closed)) }
        let barriers = barriers; self.barriers.removeAll()
        for waiter in barriers.values { waiter.resume(throwing: error ?? AntigravityWireError(.closed)) }
        output.yield(.closed(error)); output.finish()
    }
    public func close() async {
        if let closeTask { await closeTask.value; return }
        closing = true; startReader()
        let runtime = runtime, source = reader, tail = writeTail
        let task = Task { await runtime.close(); await tail?.value; await source?.value }
        closeTask = task; await task.value; end(nil)
    }
    private static func safe(_ error: any Error) -> AntigravityWireError {
        if let value = error as? AntigravityWireError { return value }
        return .init(error is CancellationError ? .cancelled : .protocolViolation)
    }
    private static func validMethod(_ method: String) -> Bool { !method.isEmpty && method.utf8.count <= 256 && !method.unicodeScalars.contains { $0.value < 32 || $0.value == 127 } }
    private static func validID(_ value: JSONValue) -> Bool {
        switch value {
        case .string(let value): return value.utf8.count <= 4_096 && !value.contains("\0")
        case .number(let value): return value.isFinite && value.rounded() == value && abs(value) <= 9_007_199_254_740_991
        default: return false
        }
    }
    private static func encoded(_ value: JSONValue) throws -> Data {
        var budget = maximumFrameBytes, nodes = 100_000
        func visit(_ value: JSONValue, depth: Int) throws {
            nodes -= 1; budget -= 8
            guard budget >= 0, nodes >= 0, depth <= 64 else { throw AntigravityWireError(.overflow) }
            switch value {
            case .string(let string): budget -= string.utf8.count
            case .number(let number): guard number.isFinite else { throw AntigravityWireError(.invalidRequest) }
            case .object(let fields): for (key, value) in fields { budget -= key.utf8.count; try visit(value, depth: depth + 1) }
            case .array(let fields): for value in fields { try visit(value, depth: depth + 1) }
            default: break
            }
            guard budget >= 0 else { throw AntigravityWireError(.overflow) }
        }
        try visit(value, depth: 0)
        var data: Data
        do { data = try JSONEncoder().encode(value) } catch { throw AntigravityWireError(.invalidRequest) }
        guard data.count <= maximumFrameBytes else { throw AntigravityWireError(.overflow) }; data.append(10); return data
    }
}

private struct AntigravityLineFramer {
    let maximum: Int
    private var pending = Data()
    init(maximum: Int) { self.maximum = maximum }
    mutating func append(_ bytes: Data) throws -> [Data] {
        var lines: [Data] = [], offset = bytes.startIndex
        while offset < bytes.endIndex {
            let newline = bytes[offset...].firstIndex(of: 10), end = newline ?? bytes.endIndex
            let count = pending.count + bytes.distance(from: offset, to: end), last = end > offset ? bytes[bytes.index(before: end)] : pending.last
            guard count <= maximum || count == maximum + 1 && last == 13 else { throw AntigravityWireError(.overflow) }
            pending.append(contentsOf: bytes[offset..<end]); guard let newline else { break }
            if pending.last == 13 { pending.removeLast() }
            if !pending.allSatisfy({ $0 == 32 || $0 == 9 || $0 == 13 }) { lines.append(pending) }
            pending = Data(); offset = bytes.index(after: newline)
        }; return lines
    }
    func finish() throws { guard pending.isEmpty else { throw AntigravityWireError(.protocolViolation) } }
}
private struct AntigravityStderrFramer {
    private var pending = Data()
    private var discarding = false
    mutating func append(_ bytes: Data) -> [String] {
        var result: [String] = []
        for byte in bytes {
            if byte == 10 {
                if !discarding {
                    if pending.last == 13 { pending.removeLast() }
                    if let string = String(data: pending, encoding: .utf8) { result.append(string) }
                }
                pending.removeAll(keepingCapacity: true); discarding = false
            } else if !discarding {
                if pending.count >= 16_640 { pending.removeAll(keepingCapacity: true); discarding = true }
                else { pending.append(byte) }
            }
        }; return result
    }
}
