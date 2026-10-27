import Darwin
import Foundation

struct OpenCodeServerError: LocalizedError, Sendable {
    var message: String
    /// OpenCode's shared database was briefly locked by another process; worth retrying.
    var databaseLocked = false

    nonisolated var errorDescription: String? { message }
}

/// One `opencode serve` process and its event stream. An OpenCode 2 server serves every directory,
/// so, like T3 Code, Coincide shares one across threads (see `OpenCodeServerPool`).
@MainActor
final class OpenCodeServer {
    enum Notification {
        case event(JSONValue)
        /// The event stream dropped and was restored; events in between were lost.
        case reconnected
        /// The server is gone: the process exited or its event stream could not be restored.
        case terminated(String)
    }

    nonisolated static let startupTimeout: TimeInterval = 30
    private nonisolated static let reconnectAttempts = 5

    let api: OpenCodeAPI
    let version: String
    let pid: Int32
    private let process: LineProcess
    private var stream: OpenCodeEventStream?
    private var streamWaiter: OpenCodeOnce<Void>?
    private var subscribers: [UUID: (Notification) -> Void] = [:]
    private var isReconnecting = false
    private var isStopping = false
    private(set) var isTerminated = false
    /// Called once when the server ends, whether stopped or not.
    var onTerminated: (() -> Void)?

    private init(api: OpenCodeAPI, version: String, process: LineProcess) {
        self.api = api
        self.version = version
        self.process = process
        pid = process.processIdentifier
        process.onLine = nil
        process.onExit = { [weak self] status, stderrTail in
            self?.processExited(status: status, stderrTail: stderrTail)
        }
    }

    // MARK: Launch

    /// Starts `opencode serve` on a free local port with a fresh password and waits until its event
    /// stream is connected. Retries briefly when OpenCode's database is locked.
    static func launch(executable: URL, environment: [String: String]) async throws -> OpenCodeServer {
        var attempt = 0
        while true {
            do {
                return try await launchOnce(executable: executable, environment: environment)
            } catch let error as OpenCodeServerError where error.databaseLocked && attempt < 3 {
                attempt += 1
                try await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private static func launchOnce(executable: URL, environment: [String: String]) async throws -> OpenCodeServer {
        let password = randomPassword()
        var environment = environment
        // OPENCODE_PASSWORD takes precedence; drop the inherited 1.x variable.
        environment.removeValue(forKey: "OPENCODE_SERVER_PASSWORD")
        environment["OPENCODE_PASSWORD"] = password
        let process = LineProcess(
            executable: executable, arguments: ["serve", "--hostname=127.0.0.1", "--port=0"],
            workingDirectory: FileManager.default.homeDirectoryForCurrentUser, environment: environment)
        let url = try await waitUntilListening(process)
        // `LineProcess` registers the server with `ChildProcesses`, so it never outlives Coincide.
        let pid = process.processIdentifier
        let api = OpenCodeAPI(baseURL: url, password: password, urlSession: OpenCodeAPI.makeURLSession())
        do {
            let version = try await api.serverVersion()
            let server = OpenCodeServer(api: api, version: version, process: process)
            try await server.connectStream(timeout: 10)
            return server
        } catch {
            // The handler holds the process until it has exited, then lets go.
            process.onExit = { _, _ in process.onExit = nil }
            OpenCodeServerProcesses.stop(pid)
            api.urlSession.invalidateAndCancel()
            throw error
        }
    }

    private static func waitUntilListening(_ process: LineProcess) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let once = OpenCodeOnce(continuation)
            process.onLine = { line in
                if let url = listeningURL(in: line) {
                    once.resume(.success(url))
                } else if once.log.count < 8_000 {
                    once.log += line + "\n"
                }
            }
            // Holds the process until it exits; a started server replaces this handler.
            process.onExit = { status, stderrTail in
                process.onExit = nil
                once.resume(.failure(startupFailure(status: status, stdout: once.log, stderr: stderrTail)))
            }
            do {
                try process.start()
            } catch {
                process.onExit = nil
                let message = String(localized: "Could not start OpenCode: \(error.localizedDescription)")
                once.resume(.failure(OpenCodeServerError(message: message)))
                return
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(startupTimeout))
                guard once.isPending else { return }
                OpenCodeServerProcesses.stop(process.processIdentifier)
                let message = String(localized: "Timed out waiting for the OpenCode server to start.")
                once.resume(.failure(OpenCodeServerError(message: message)))
            }
        }
    }

    /// The URL in OpenCode's "server listening on http://127.0.0.1:PORT" line.
    nonisolated static func listeningURL(in line: String) -> URL? {
        guard let match = line.firstMatch(of: /(?i)server listening on\s+(https?:\/\/\S+)/) else { return nil }
        return URL(string: String(match.1))
    }

    nonisolated static func startupFailure(status: Int32, stdout: String, stderr: String) -> OpenCodeServerError {
        let details = [stdout, stderr].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        var message = String(localized: "The OpenCode server exited before it started (code \(status)).")
        if let tail = details.last { message += "\n" + String(tail.suffix(2_000)) }
        let locked = stderr.range(of: "SQLITE_BUSY|database is locked", options: [.regularExpression, .caseInsensitive]) != nil
        return OpenCodeServerError(message: message, databaseLocked: locked)
    }

    /// 32 random bytes, base64url-encoded. OpenCode 2 always requires a password.
    nonisolated static func randomPassword() -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: Events

    /// Delivers every server event, in order, until the subscription is cancelled or the server ends.
    func subscribe(_ handler: @escaping (Notification) -> Void) -> UUID {
        let id = UUID()
        subscribers[id] = handler
        return id
    }

    func unsubscribe(_ id: UUID) {
        subscribers[id] = nil
    }

    /// Opens the event stream and waits for OpenCode's `server.connected` greeting. Events are
    /// volatile, so the stream must be connected before any work is sent.
    private func connectStream(timeout: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = OpenCodeOnce(continuation)
            streamWaiter = once
            let stream = OpenCodeEventStream(
                api: api,
                onEvent: { [weak self] event in self?.received(event) },
                onClose: { [weak self] reason in self?.streamClosed(reason) })
            self.stream = stream
            stream.start()
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                guard once.isPending else { return }
                self?.stream?.cancel()
                self?.stream = nil
                let message = String(localized: "Timed out connecting to the OpenCode event stream.")
                once.resume(.failure(OpenCodeServerError(message: message)))
            }
        }
    }

    private func received(_ event: JSONValue) {
        if event["type"]?.string == "server.connected" {
            streamWaiter?.resume(.success(()))
            streamWaiter = nil
            return
        }
        for handler in Array(subscribers.values) { handler(.event(event)) }
    }

    private func streamClosed(_ reason: String) {
        stream = nil
        if let waiter = streamWaiter {
            streamWaiter = nil
            waiter.resume(.failure(OpenCodeServerError(message: reason)))
            return
        }
        guard !isStopping, !isTerminated else { return }
        reconnect()
    }

    private func reconnect() {
        guard !isReconnecting else { return }
        isReconnecting = true
        Task { @MainActor [weak self] in
            for attempt in 1...Self.reconnectAttempts {
                try? await Task.sleep(for: .milliseconds(attempt == 1 ? 500 : 2_000))
                guard let self, !self.isStopping, !self.isTerminated else { return }
                // A dead process reports through its exit handler.
                guard self.process.isRunning else { return }
                do {
                    try await self.connectStream(timeout: 10)
                    self.isReconnecting = false
                    for handler in Array(self.subscribers.values) { handler(.reconnected) }
                    return
                } catch {
                    continue
                }
            }
            guard let self else { return }
            self.isReconnecting = false
            self.terminate(String(localized: "Lost the connection to the OpenCode server."))
        }
    }

    // MARK: Lifecycle

    /// Stops the process. Subscribers are not notified; they released the server first.
    func stop() {
        guard !isTerminated else { return }
        isStopping = true
        isTerminated = true
        subscribers = [:]
        stream?.cancel()
        stream = nil
        stopProcess()
        api.urlSession.finishTasksAndInvalidate()
        onTerminated?()
        onTerminated = nil
    }

    /// Stops the process, keeping this server (and so the process handle) alive until it has exited, so
    /// the exit is reaped.
    private func stopProcess() {
        guard process.isRunning else { return }
        process.onExit = { [self] status, stderrTail in
            process.onExit = nil
            processExited(status: status, stderrTail: stderrTail)
        }
        OpenCodeServerProcesses.stop(pid)
    }

    private func processExited(status: Int32, stderrTail: String) {
        guard !isStopping else { return }
        var message = String(localized: "OpenCode exited unexpectedly (code \(status)).")
        let tail = TerminalText.stripANSI(stderrTail).trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { message += "\n" + String(tail.suffix(1_500)) }
        terminate(message)
    }

    private func terminate(_ reason: String) {
        guard !isTerminated else { return }
        isTerminated = true
        stream?.cancel()
        stream = nil
        stopProcess()
        api.urlSession.invalidateAndCancel()
        let handlers = Array(subscribers.values)
        subscribers = [:]
        for handler in handlers { handler(.terminated(reason)) }
        onTerminated?()
        onTerminated = nil
    }
}

/// Resumes a continuation once, from whichever callback fires first.
@MainActor
final class OpenCodeOnce<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, Error>?
    /// Output collected while waiting, for the error message.
    var log = ""

    init(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    var isPending: Bool { continuation != nil }

    func resume(_ result: Result<Value, Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }
}

// MARK: - Pool

/// Shares one server per executable and environment among sessions and model discovery. A server
/// nobody uses is stopped after `idleTimeout`, like T3 Code's 30-second idle stop, so a provider
/// refresh followed by a turn starts it once.
@MainActor
final class OpenCodeServerPool {
    static let shared = OpenCodeServerPool()

    var idleTimeout: TimeInterval = 30

    private struct Key: Hashable {
        var executable: String
        var environment: [String: String]
    }

    private var servers: [Key: OpenCodeServer] = [:]
    private var launches: [Key: Task<OpenCodeServer, Error>] = [:]
    private var borrowers: [ObjectIdentifier: Int] = [:]
    private var idleStops: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var sweptOrphans = false

    func borrow(executable: URL, environment: [String: String]) async throws -> OpenCodeServerLease {
        if !sweptOrphans {
            sweptOrphans = true
            OpenCodeServerLedger.sweep()
        }
        let key = Key(executable: executable.standardizedFileURL.path, environment: environment)
        while true {
            if let server = servers[key], !server.isTerminated { return lease(server) }
            if let launch = launches[key] {
                let server = try await launch.value
                if !server.isTerminated { return lease(server) }
                continue
            }
            let launch = Task { () throws -> OpenCodeServer in
                defer { self.launches[key] = nil }
                let server = try await OpenCodeServer.launch(executable: executable, environment: environment)
                self.register(server, for: key)
                return server
            }
            launches[key] = launch
            let server = try await launch.value
            if !server.isTerminated { return lease(server) }
        }
    }

    private func register(_ server: OpenCodeServer, for key: Key) {
        servers[key] = server
        server.onTerminated = { [weak self, weak server] in
            guard let self, let server else { return }
            self.forget(server)
        }
    }

    /// Stops every server now (used when quitting and by tests).
    func shutdownAll() {
        for task in idleStops.values { task.cancel() }
        idleStops = [:]
        let running = Array(servers.values)
        servers = [:]
        borrowers = [:]
        for server in running { server.stop() }
    }

    fileprivate func release(_ server: OpenCodeServer) {
        let id = ObjectIdentifier(server)
        let count = max(0, (borrowers[id] ?? 1) - 1)
        borrowers[id] = count
        guard count == 0, !server.isTerminated else { return }
        idleStops[id]?.cancel()
        let timeout = idleTimeout
        guard timeout > 0 else {
            stop(server)
            return
        }
        idleStops[id] = Task { @MainActor [weak self, weak server] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled, let self, let server, self.borrowers[ObjectIdentifier(server)] == 0 else { return }
            self.stop(server)
        }
    }

    private func lease(_ server: OpenCodeServer) -> OpenCodeServerLease {
        let id = ObjectIdentifier(server)
        borrowers[id, default: 0] += 1
        idleStops[id]?.cancel()
        idleStops[id] = nil
        return OpenCodeServerLease(server: server, pool: self)
    }

    private func stop(_ server: OpenCodeServer) {
        forget(server)
        server.stop()
    }

    private func forget(_ server: OpenCodeServer) {
        let id = ObjectIdentifier(server)
        borrowers[id] = nil
        idleStops.removeValue(forKey: id)?.cancel()
        for (key, value) in servers where value === server { servers[key] = nil }
    }
}

/// A session's or probe's claim on a pooled server. Release it when done.
@MainActor
final class OpenCodeServerLease {
    let server: OpenCodeServer
    private weak var pool: OpenCodeServerPool?
    private var isReleased = false

    fileprivate init(server: OpenCodeServer, pool: OpenCodeServerPool) {
        self.server = server
        self.pool = pool
    }

    func release() {
        guard !isReleased else { return }
        isReleased = true
        pool?.release(server)
    }

    isolated deinit {
        release()
    }
}

// MARK: - Process tracking

/// Stopping a server. Servers are `LineProcess`es, so `ChildProcesses` stops them when Coincide quits
/// and sweeps up ones a crashed Coincide left behind.
enum OpenCodeServerProcesses {
    /// Sends SIGTERM, which lets OpenCode stop the MCP servers it started (they run in their own
    /// process groups). If it is still running after `grace`, kills it and stops its children.
    nonisolated static func stop(_ pid: Int32, grace: TimeInterval = 10) {
        guard let server = ProcessTree.identity(of: pid) else { return }
        kill(pid, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + grace) {
            guard ProcessTree.isAlive(server) else { return }
            let children = ProcessTree.descendants(of: pid)
            kill(pid, SIGKILL)
            ProcessTree.terminate(children)
        }
    }
}

/// Servers an earlier Coincide recorded before `ChildProcesses` kept the ledger for every child.
enum OpenCodeServerLedger {
    private nonisolated static var directory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("coincide-opencode-servers", isDirectory: true)
    }

    /// Stops servers whose owner is no longer running, and removes the old ledger.
    nonisolated static func sweep() {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        guard !files.isEmpty else { return }
        for file in files where file.pathExtension == "json" {
            // A pid that does not fit pid_t makes the entry unreadable rather than trapping.
            guard let data = try? Data(contentsOf: file), let entry = JSONValue.parse(data),
                let pid = entry["pid"]?.int.flatMap({ pid_t(exactly: $0) }), let start = entry["start"]?.number,
                let owner = entry["owner"]?.int.flatMap({ pid_t(exactly: $0) }), let ownerStart = entry["ownerStart"]?.number
            else {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            if isRunning(owner, startedAt: ownerStart) { continue }
            if isRunning(pid, startedAt: start) { kill(pid, SIGTERM) }
            try? FileManager.default.removeItem(at: file)
        }
    }

    private nonisolated static func isRunning(_ pid: Int32, startedAt start: Double) -> Bool {
        guard let actual = ProcessTree.identity(of: pid) else { return false }
        return abs(Double(actual.startTime) / 1_000_000 - start) < 0.001
    }
}

