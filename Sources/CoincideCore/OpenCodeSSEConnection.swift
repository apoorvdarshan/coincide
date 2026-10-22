import Foundation

public enum OpenCodeSSEConnectionError: Error, Sendable, Equatable, LocalizedError {
    case invalidDirectory, invalidWatchdog, disconnected, heartbeatTimedOut, eventBufferOverflow
    case rawHTTPFailure(OpenCodeHTTPError)

    public var errorDescription: String? {
        switch self {
        case .invalidDirectory: "The OpenCode event directory is invalid."
        case .invalidWatchdog: "The OpenCode event watchdog is invalid."
        case .disconnected, .rawHTTPFailure: "The OpenCode event stream disconnected. Reconcile native sessions before continuing."
        case .heartbeatTimedOut: "The OpenCode event stream stopped receiving bytes. Reconcile native sessions before continuing."
        case .eventBufferOverflow: "The OpenCode event consumer exceeded its bounded buffer. Reconcile native sessions before continuing."
        }
    }

    /// Only fixed categories may enter diagnostic evidence. Associated HTTP
    /// status values, arbitrary errors and transport payloads are never rendered.
    public var diagnosticCategory: String {
        switch self {
        case .invalidDirectory: "sse-invalid-directory"
        case .invalidWatchdog: "sse-invalid-watchdog"
        case .disconnected: "sse-disconnected"
        case .heartbeatTimedOut: "sse-heartbeat-timed-out"
        case .eventBufferOverflow: "sse-event-buffer-overflow"
        case .rawHTTPFailure(let error):
            switch error {
            case .invalidOrigin: "raw-http-invalid-origin"
            case .invalidPath: "raw-http-invalid-path"
            case .invalidQuery: "raw-http-invalid-query"
            case .invalidMethod: "raw-http-invalid-method"
            case .invalidLimit: "raw-http-invalid-limit"
            case .requestBodyTooLarge: "raw-http-request-body-too-large"
            case .responseBodyTooLarge: "raw-http-response-body-too-large"
            case .invalidResponse: "raw-http-invalid-response"
            case .redirectDenied: "raw-http-redirect-denied"
            case .eventResponseRejected: "raw-http-event-response-rejected"
            case .eventBufferOverflow: "raw-http-event-buffer-overflow"
            case .transportFailure: "raw-http-transport-failure"
            case .clientClosed: "raw-http-client-closed"
            }
        }
    }

    static func sanitizingStreamFailure(_ error: any Error) -> Self {
        if let safe = error as? OpenCodeHTTPError { return .rawHTTPFailure(safe) }
        return .disconnected
    }
}

/// Owns one volatile event subscription. EOF, invalid framing, silence and slow
/// consumption require adapter reconciliation; they never complete a provider run.
/// Generation 2 events are GLOBAL: adapters must match exact native session IDs.
public actor OpenCodeSSEConnection {
    public nonisolated let events: AsyncThrowingStream<OpenCodeSSEEvent, Error>
    private let continuation: AsyncThrowingStream<OpenCodeSSEEvent, Error>.Continuation
    private let bytes: OpenCodeHTTPByteStream
    private let silenceTimeout: Duration
    private var lastByteAt = ContinuousClock.now
    private var parser: OpenCodeSSEParser
    private var reader: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var cleanup: Task<Void, Never>?
    private enum State { case running, stopping, closed }
    private var state: State = .running

    public static func open(client: OpenCodeHTTPClient, generation: OpenCodeGeneration,
                            directory: URL) async throws -> OpenCodeSSEConnection {
        try await open(client: client, generation: generation, directory: directory, silenceTimeout: .seconds(45))
    }

    /// Internal deadline injection exercises real stream cancellation without a
    /// 45-second fixture wait. Production always uses the public 45-second limit.
    static func open(client: OpenCodeHTTPClient, generation: OpenCodeGeneration,
                     directory: URL, silenceTimeout: Duration) async throws -> OpenCodeSSEConnection {
        guard silenceTimeout > .zero, silenceTimeout <= .seconds(45) else { throw OpenCodeSSEConnectionError.invalidWatchdog }
        let path = directory.path
        guard directory.isFileURL, directory.host == nil || directory.host == "" || directory.host == "localhost",
              directory.user == nil, directory.password == nil, directory.query == nil, directory.fragment == nil,
              path.hasPrefix("/"), path == directory.standardizedFileURL.path, path.utf8.count <= 16_384,
              !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw OpenCodeSSEConnectionError.invalidDirectory
        }
        try Task.checkCancellation()
        let route = generation == .v1 ? ["event"] : ["api", "event"]
        // V2's global event feed is not location-filtered by this parameter.
        let query = generation == .v1 ? [URLQueryItem(name: "directory", value: path)] : []
        let bytes = try await client.openEvents(path: route, query: query)
        let connection: OpenCodeSSEConnection
        do {
            try Task.checkCancellation()
            connection = try OpenCodeSSEConnection(bytes: bytes, silenceTimeout: silenceTimeout)
        } catch { await bytes.close(); throw error }
        await connection.startReaders()
        do { try Task.checkCancellation(); return connection }
        catch { await connection.close(); throw error }
    }

    private init(bytes: OpenCodeHTTPByteStream, silenceTimeout: Duration) throws {
        self.bytes = bytes; self.silenceTimeout = silenceTimeout
        parser = try OpenCodeSSEParser()
        let pair = AsyncThrowingStream<OpenCodeSSEEvent, Error>.makeStream(bufferingPolicy: .bufferingOldest(16))
        events = pair.stream; continuation = pair.continuation
    }

    deinit {
        reader?.cancel(); watchdog?.cancel()
        continuation.finish()
        let bytes = bytes
        // Cleanup owns only the transport request, never this actor or its client.
        Task.detached { await bytes.close() }
    }

    private func startReaders() {
        continuation.onTermination = { [weak self] _ in
            Task { [weak self] in await self?.consumerStopped() }
        }
        let bytes = bytes
        reader = Task.detached(priority: .utility) { [weak self, bytes] in
            var failure = OpenCodeSSEConnectionError.disconnected
            do {
                for try await chunk in bytes.stream {
                    guard !Task.isCancelled else { break }
                    guard await self?.receive(chunk) == true else { break }
                }
            } catch { failure = .sanitizingStreamFailure(error) }
            await self?.streamEnded(cause: failure)
        }
        watchdog = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                guard let delay = await self?.watchdogDelay() else { return }
                if delay <= .zero {
                    if await self?.failIfSilent() != false { return }
                } else {
                    do { try await Task.sleep(for: delay) }
                    catch { return }
                }
            }
        }
    }

    /// Explicit closure is normal subscription shutdown, with no completion event.
    /// Concurrent callers await the same exact request and worker cleanup.
    public func close() async {
        beginStop(error: nil)
        if let cleanup { await cleanup.value }
        state = .closed
    }

    private func receive(_ chunk: Data) -> Bool {
        guard state == .running else { return false }
        if !chunk.isEmpty { lastByteAt = ContinuousClock.now }
        do {
            for event in try parser.append(chunk) {
                switch continuation.yield(event) {
                case .enqueued: break
                case .dropped: beginStop(error: OpenCodeSSEConnectionError.eventBufferOverflow); return false
                case .terminated: beginStop(error: nil); return false
                @unknown default: beginStop(error: OpenCodeSSEConnectionError.eventBufferOverflow); return false
                }
            }
            return true
        } catch let error as OpenCodeProtocolError {
            beginStop(error: error); return false
        } catch {
            beginStop(error: OpenCodeProtocolError.invalidEvent); return false
        }
    }

    private func watchdogDelay() -> Duration? {
        guard state == .running else { return nil }
        return ContinuousClock.now.duration(to: lastByteAt + silenceTimeout)
    }

    private func failIfSilent() -> Bool {
        guard state == .running else { return true }
        guard ContinuousClock.now >= lastByteAt + silenceTimeout else { return false }
        beginStop(error: OpenCodeSSEConnectionError.heartbeatTimedOut); return true
    }

    private func streamEnded(cause: OpenCodeSSEConnectionError) {
        guard state == .running else { return }
        beginStop(error: cause)
    }

    private func consumerStopped() { beginStop(error: nil) }

    /// This method never awaits its own reader/watchdog. A detached cleanup joins
    /// both only after this actor callback has returned to the initiating worker.
    private func beginStop(error: Error?) {
        guard state == .running else { return }
        state = .stopping; parser.finish()
        if let error { continuation.finish(throwing: error) } else { continuation.finish() }
        let reader = reader, watchdog = watchdog, bytes = bytes
        reader?.cancel(); watchdog?.cancel()
        cleanup = Task.detached { [weak self, reader, watchdog, bytes] in
            await bytes.close()
            if let reader { await reader.value }
            if let watchdog { await watchdog.value }
            await self?.didStop()
        }
    }

    private func didStop() { state = .closed }
}
