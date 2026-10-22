import Foundation

/// An ephemeral connection to this exact child. It is never a durable provider
/// configuration, and it contains no credentials in its URL.
public struct OpenCodeOwnedServerEndpoint: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let origin: URL
    public let credential: OpenCodeHTTPCredential
    public let processIdentifier: Int32

    public init(origin: URL, credential: OpenCodeHTTPCredential, processIdentifier: Int32) throws {
        self.origin = try Self.validatedOrigin(origin)
        guard processIdentifier > 0 else { throw OpenCodeOwnedServerError.invalidReadiness }
        self.credential = credential; self.processIdentifier = processIdentifier
    }

    public var description: String { "OpenCodeOwnedServerEndpoint(<runtime-only>, credential: <redacted>)" }
    public var debugDescription: String { description }

    fileprivate static func validatedOrigin(_ url: URL) throws -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "http", components.host == "127.0.0.1",
              let port = components.port, (1...65_535).contains(port),
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.percentEncodedPath.isEmpty || components.percentEncodedPath == "/" else {
            throw OpenCodeOwnedServerError.invalidReadiness
        }
        components.scheme = "http"; components.path = ""
        guard let origin = components.url else { throw OpenCodeOwnedServerError.invalidReadiness }
        return origin
    }
}

/// Fixed errors never include child output, invocation environment or credentials.
public enum OpenCodeOwnedServerError: Error, Sendable, Equatable, LocalizedError {
    case invalidInvocation, launchFailed, invalidReadiness, startupTimedOut, outputLimit, exited, closed

    public var errorDescription: String? {
        switch self {
        case .invalidInvocation: "The OpenCode server invocation is invalid."
        case .launchFailed: "The OpenCode server could not be started."
        case .invalidReadiness: "The OpenCode server returned an invalid local endpoint."
        case .startupTimedOut: "The OpenCode server did not become ready in time."
        case .outputLimit: "The OpenCode server exceeded its output limit."
        case .exited: "The OpenCode server exited."
        case .closed: "The owned OpenCode server is closed."
        }
    }
}

/// Owns one local CLI child, never an existing service. HTTP identity/version
/// checks are performed by the caller before exposing any catalog or capability.
/// Close proves exact child exit, not termination of every provider descendant.
public actor OpenCodeOwnedServer {
    private enum Phase { case idle, starting, ready, failed, closed }
    private let executable: URL
    private let generation: OpenCodeGeneration
    private let cwd: URL
    private let environment: [String: String]
    private let startupTimeout: Duration
    private let eofGrace: Duration
    private var phase: Phase = .idle
    private var endpoint: OpenCodeOwnedServerEndpoint?
    private var failure: OpenCodeOwnedServerError?
    private var channel: ProcessChannel?
    private var launchID: UUID?
    private var reader: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var cleanup: Task<Void, Never>?
    private var exitSignal: OpenCodeServerExitSignal?
    private var observedExit = false
    private var parser = OpenCodeReadinessParser()
    private var outputBytes = 0
    private var waiters: [UUID: CheckedContinuation<OpenCodeOwnedServerEndpoint, any Error>] = [:]
    private var startCalls: Set<UUID> = []
    private var successfullyStarted = false
    var pendingStartCount: Int { waiters.count }

    public init(executable: URL, generation: OpenCodeGeneration, cwd: URL,
                environment: [String: String] = ProcessChannel.environment()) {
        self.executable = executable; self.generation = generation; self.cwd = cwd
        self.environment = environment; startupTimeout = .seconds(10); eofGrace = .seconds(1)
    }

    /// Internal deadline injection keeps failure tests deterministic without
    /// changing the public startup/ownership contract.
    init(executable: URL, generation: OpenCodeGeneration, cwd: URL, environment: [String: String],
         startupTimeout: Duration, eofGrace: Duration = .seconds(1)) {
        self.executable = executable; self.generation = generation; self.cwd = cwd
        self.environment = environment; self.startupTimeout = startupTimeout; self.eofGrace = eofGrace
    }

    deinit { channel?.stop(); reader?.cancel(); deadline?.cancel() }

    public func start() async throws -> OpenCodeOwnedServerEndpoint {
        try Task.checkCancellation()
        let id = UUID()
        startCalls.insert(id)
        defer { startCalls.remove(id) }
        do {
            let result = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    register(id, continuation: continuation)
                }
            } onCancel: { Task { await self.cancelWaiter(id) } }
            try Task.checkCancellation()
            successfullyStarted = true
            return result
        } catch {
            if Task.isCancelled {
                cancelWaiter(id)
                startCalls.remove(id)
                // Readiness may have resumed the continuation immediately before
                // cancellation. Do not leave an unclaimed first launch alive.
                if phase == .ready && !successfullyStarted && startCalls.isEmpty {
                    phase = .closed; endpoint = nil
                    beginCleanup(gracefully: generation == .v2)
                }
            }
            // A detached surviving waiter must not wait for the shared launch.
            // The last waiter, startup failures and explicit close drain ownership.
            if let cleanup { await cleanup.value }
            try Task.checkCancellation()
            throw error
        }
    }

    public func close() async {
        phase = .closed; endpoint = nil; deadline?.cancel(); deadline = nil
        resumeWaiters(throwing: OpenCodeOwnedServerError.closed)
        beginCleanup(gracefully: generation == .v2 && failure == nil)
        if let cleanup { await cleanup.value }
    }

    private func register(_ id: UUID, continuation: CheckedContinuation<OpenCodeOwnedServerEndpoint, any Error>) {
        if phase == .closed { continuation.resume(throwing: OpenCodeOwnedServerError.closed); return }
        if let failure { continuation.resume(throwing: failure); return }
        if let endpoint {
            if channel?.outputOverflowed == true {
                fail(.outputLimit); continuation.resume(throwing: OpenCodeOwnedServerError.outputLimit)
            } else { continuation.resume(returning: endpoint) }
            return
        }
        waiters[id] = continuation
        guard phase == .idle else { return }
        do { try launch() }
        catch let error as OpenCodeOwnedServerError { fail(error) }
        catch { fail(.launchFailed) }
    }

    private func launch() throws {
        guard Self.localFile(executable), Self.localFile(cwd),
              FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw OpenCodeOwnedServerError.invalidInvocation
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw OpenCodeOwnedServerError.invalidInvocation
        }
        var random = SystemRandomNumberGenerator()
        let password = Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &random) }).base64EncodedString()
        let credential = try OpenCodeHTTPCredential(password: password)
        var env = environment
        for key in ["OPENCODE_PASSWORD", "OPENCODE_SERVER_PASSWORD", "OPENCODE_SERVER_URL", "OPENCODE_URL", "OPENCODE_PTY_HANDOFF"] {
            env.removeValue(forKey: key)
        }
        env["OPENCODE_SERVER_USERNAME"] = "opencode"
        env[generation == .v2 ? "OPENCODE_PASSWORD" : "OPENCODE_SERVER_PASSWORD"] = password
        env["NO_COLOR"] = "1"; env["FORCE_COLOR"] = "0"
        let args = ["serve"] + (generation == .v2 ? ["--stdio"] : []) + ["--hostname", "127.0.0.1", "--port", "0"]
        phase = .starting
        let channel: ProcessChannel
        do {
            channel = try ProcessChannel(executable: executable, arguments: args, cwd: cwd,
                                         environment: env, eventBufferLimit: 32)
        } catch { throw OpenCodeOwnedServerError.launchFailed }
        self.channel = channel
        let token = UUID(); launchID = token
        reader = Task.detached(priority: .utility) { [weak self, channel] in
            for await event in channel.events {
                guard !Task.isCancelled else { break }
                await self?.consume(event, token: token, credential: credential)
            }
            await self?.streamEnded(token: token)
        }
        let timeout = startupTimeout
        deadline = Task { [weak self] in
            do { try await Task.sleep(for: timeout); await self?.startupExpired(token: token) }
            catch { /* A ready or closed owner cancels its startup deadline. */ }
        }
    }

    private static func localFile(_ url: URL) -> Bool {
        url.isFileURL && (url.host == nil || url.host == "" || url.host == "localhost") &&
            url.query == nil && url.fragment == nil && url.path.hasPrefix("/")
    }

    private func consume(_ event: ProcessEvent, token: UUID, credential: OpenCodeHTTPCredential) {
        guard launchID == token else { return }
        if case .exited = event {
            observedExit = true; exitSignal?.finish(true)
            if phase != .closed && phase != .failed { fail(.exited) }
            return
        }
        guard phase == .starting || phase == .ready else { return }
        guard channel?.outputOverflowed != true else { fail(.outputLimit); return }
        // A live server can emit logs for hours. Once readiness is immutable,
        // discard bytes directly; only pending transport buffering remains capped.
        guard phase == .starting else { return }
        let data: Data
        switch event { case .stdout(let bytes), .stderr(let bytes): data = bytes; case .exited: return }
        guard data.count <= 1_048_576 - outputBytes else { fail(.outputLimit); return }
        outputBytes += data.count
        guard case .stdout = event else { return } // Drain stderr without retaining or publishing it.
        do {
            for origin in try parser.consume(data, generation: generation) {
                if let endpoint {
                    guard endpoint.origin == origin else { throw OpenCodeOwnedServerError.invalidReadiness }
                    continue
                }
                guard let channel else { throw OpenCodeOwnedServerError.closed }
                let result = try OpenCodeOwnedServerEndpoint(origin: origin, credential: credential,
                                                            processIdentifier: channel.processIdentifier)
                endpoint = result; phase = .ready; deadline?.cancel(); deadline = nil
                parser = OpenCodeReadinessParser()
                let pending = waiters.values; waiters.removeAll()
                for waiter in pending { waiter.resume(returning: result) }
            }
        } catch let error as OpenCodeOwnedServerError { fail(error) }
        catch { fail(.invalidReadiness) }
    }

    private func streamEnded(token: UUID) {
        guard launchID == token else { return }
        exitSignal?.finish(observedExit)
        guard phase == .starting || phase == .ready else { return }
        fail(channel?.outputOverflowed == true ? .outputLimit : .exited)
    }

    private func startupExpired(token: UUID) {
        if launchID == token && phase == .starting { fail(.startupTimedOut) }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        waiter.resume(throwing: CancellationError())
        if waiters.isEmpty && phase == .starting {
            phase = .closed; deadline?.cancel(); deadline = nil
            beginCleanup(gracefully: generation == .v2)
        }
    }

    private func fail(_ error: OpenCodeOwnedServerError) {
        guard phase != .closed, phase != .failed else { return }
        failure = error; phase = .failed; endpoint = nil; deadline?.cancel(); deadline = nil
        resumeWaiters(throwing: error)
        beginCleanup(gracefully: false)
    }

    private func resumeWaiters(throwing error: any Error) {
        let pending = waiters.values; waiters.removeAll()
        for waiter in pending { waiter.resume(throwing: error) }
    }

    private func beginCleanup(gracefully: Bool) {
        guard cleanup == nil, let channel else { return }
        let signal = OpenCodeServerExitSignal(); exitSignal = signal
        if observedExit { signal.finish(true) }
        let reader = reader, grace = eofGrace, token = launchID
        cleanup = Task.detached { [weak self, channel] in
            channel.finishInput()
            if gracefully {
                let timeout = Task { try? await Task.sleep(for: grace); signal.finish(false) }
                _ = await signal.wait(); timeout.cancel()
            }
            _ = await channel.stopAndDrain()
            // Owned pipe readers are joined even if an unowned descendant kept
            // a writer. No descendant is signalled or claimed by this owner.
            reader?.cancel()
            if let reader { await reader.value }
            await self?.cleanupFinished(token: token)
        }
    }

    private func cleanupFinished(token: UUID?) {
        guard launchID == token else { return }
        channel = nil; reader = nil; exitSignal = nil
    }
}

private struct OpenCodeReadinessParser {
    private var pending = Data()

    mutating func consume(_ data: Data, generation: OpenCodeGeneration) throws -> [URL] {
        pending.append(data)
        var origins: [URL] = []
        while let newline = pending.firstIndex(of: 10) {
            let bytes = pending[..<newline]
            guard bytes.count <= 65_536, let line = String(data: bytes, encoding: .utf8) else {
                throw OpenCodeOwnedServerError.invalidReadiness
            }
            pending.removeSubrange(...newline)
            let value: String?
            switch generation {
            case .v2:
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix("{") {
                    guard let data = trimmed.data(using: .utf8),
                          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        throw OpenCodeOwnedServerError.invalidReadiness
                    }
                    if let raw = object["url"] {
                        guard let string = raw as? String else { throw OpenCodeOwnedServerError.invalidReadiness }
                        value = string
                    } else { value = nil }
                } else { value = nil }
            case .v1:
                if let marker = line.range(of: "server listening on ", options: .caseInsensitive) {
                    value = String(line[marker.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                } else { value = nil }
            }
            if let value {
                guard value.utf8.count <= 2_048, let url = URL(string: value) else { throw OpenCodeOwnedServerError.invalidReadiness }
                origins.append(try OpenCodeOwnedServerEndpoint.validatedOrigin(url))
                // Readiness is a single immutable frame. Later stdout is logs,
                // including JSON, rather than a second endpoint announcement.
                pending.removeAll(keepingCapacity: false)
                return origins
            }
        }
        guard pending.count <= 65_536 else { throw OpenCodeOwnedServerError.invalidReadiness }
        return origins
    }
}

private final class OpenCodeServerExitSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Bool?
    private var waiters: [CheckedContinuation<Bool, Never>] = []

    func finish(_ value: Bool) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = value; let pending = waiters; waiters.removeAll(); lock.unlock()
        for waiter in pending { waiter.resume(returning: value) }
    }
    func wait() async -> Bool {
        await withCheckedContinuation { waiter in
            lock.lock()
            if let result { lock.unlock(); waiter.resume(returning: result) }
            else { waiters.append(waiter); lock.unlock() }
        }
    }
}
