import Darwin
import Foundation

public protocol CodexOAuthCallbackListener: Sendable {
    var redirectURI: URL { get }
    func receive(accept: @escaping @Sendable (String) async -> Bool) async throws -> String
    func close() async
}

/// Owns only an ephemeral IPv4 loopback HTTP listener. The acceptance closure
/// validates the exact live OAuth flow; it must cooperate with cancellation.
public actor CodexOAuthLoopback: CodexOAuthCallbackListener {
    public nonisolated let redirectURI: URL
    private let owner: CodexOAuthLoopbackOwner
    private let timeout: Duration
    private var waiter: CheckedContinuation<String, any Error>?
    private var reader: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var started = false
    private var closed = false
    private var settled = false
    private init(owner: CodexOAuthLoopbackOwner, timeout: Duration) {
        self.owner = owner; self.timeout = timeout; redirectURI = owner.redirectURI
    }
    public static func start(timeout: Duration = .seconds(300)) async throws -> CodexOAuthLoopback {
        guard timeout > .zero, timeout <= .seconds(300) else { throw CodexOAuthError(.invalidConfiguration) }
        if Task.isCancelled { throw CodexOAuthError(.cancelled) }
        let owner = try CodexOAuthLoopbackOwner()
        let result = CodexOAuthLoopback(owner: owner, timeout: timeout)
        await result.activateDeadline()
        if Task.isCancelled { await result.close(); throw CodexOAuthError(.cancelled) }
        return result
    }
    public func receive(accept: @escaping @Sendable (String) async -> Bool) async throws -> String {
        guard !started, !closed else { throw CodexOAuthError(.invalidCallback) }
        started = true
        return try await withTaskCancellationHandler {
            do {
                let value = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, any Error>) in
                    waiter = continuation
                    let events = owner.requests
                    reader = Task { [weak self] in
                        for await request in events {
                            guard !Task.isCancelled else { break }
                            let accepted = await accept(request.url)
                            guard !Task.isCancelled else { break }
                            if await self?.decide(request, accepted: accepted) == true { break }
                        }
                        await self?.sourceEnded()
                    }
                }
                await close()
                return value
            } catch {
                await close()
                throw error
            }
        } onCancel: { Task { await self.cancel() } }
    }
    private func activateDeadline() {
        timer = Task { [weak self, timeout] in
            do { try await Task.sleep(for: timeout) }
            catch { return }
            await self?.expire()
        }
    }
    private func decide(_ request: CodexOAuthLoopbackOwner.Request, accepted: Bool) async -> Bool {
        guard !closed, !settled else { return true }
        if !accepted { await owner.respond(request.id, accepted: false); return false }
        // Admission is committed on the socket owner's serial queue. A timed-out
        // or closed socket cannot consume a valid callback on behalf of a new flow.
        guard await owner.complete(request.id) else { return false }
        guard !closed, !settled else { return true }
        settled = true; timer?.cancel()
        let pending = waiter; waiter = nil; pending?.resume(returning: request.url)
        return true
    }
    private func sourceEnded() {
        guard !closed, !settled else { return }
        settled = true; timer?.cancel()
        let pending = waiter; waiter = nil; pending?.resume(throwing: CodexOAuthError(.transportFailed))
    }
    private func expire() async { await finish(.expired) }
    private func cancel() async { await finish(.cancelled) }
    private func finish(_ kind: CodexOAuthError.Kind) async {
        guard !settled else { return }
        settled = true
        let pending = waiter; waiter = nil
        await close()
        pending?.resume(throwing: CodexOAuthError(kind))
    }
    public func close() async {
        if !closed {
            closed = true; settled = true; timer?.cancel(); reader?.cancel()
            let pending = waiter; waiter = nil; pending?.resume(throwing: CodexOAuthError(.cancelled))
        }
        await owner.close()
        await reader?.value
        reader = nil; timer = nil
    }
    deinit { owner.stop() }
}

/// All descriptor/source state is confined to queue. Cancel handlers close each
/// descriptor and form the join proof; no synchronous socket read can block it.
private final class CodexOAuthLoopbackOwner: @unchecked Sendable {
    struct Request: Sendable { let id: UUID; let url: String }
    let redirectURI: URL
    let requests: AsyncStream<Request>
    private let sink: AsyncStream<Request>.Continuation
    private let queue = DispatchQueue(label: "com.apoorvdarshan.coincide.codex-oauth-loopback")
    private var listener: DispatchSourceRead?
    private var connections: [UUID: Connection] = [:]
    private var attempted = 0
    private var closing = false
    private var descriptors = 0
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []
    private let socket: Int32
    private let port: UInt16
    private final class Connection {
        let id = UUID(), fd: Int32
        let read: DispatchSourceRead
        let timer: DispatchSourceTimer
        var write: DispatchSourceWrite?
        var input = Data(), output = Data(), offset = 0
        var awaitingDecision = false
        init(fd: Int32, queue: DispatchQueue) {
            self.fd = fd; read = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            timer = DispatchSource.makeTimerSource(queue: queue)
        }
    }
    init() throws {
        let pair = AsyncStream<Request>.makeStream(bufferingPolicy: .bufferingOldest(8))
        requests = pair.stream; sink = pair.continuation
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw CodexOAuthError(.transportFailed) }
        var valid = false
        defer { if !valid { Darwin.close(fd) } }
        guard Self.configure(fd) else { throw CodexOAuthError(.transportFailed) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        guard inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1 else { throw CodexOAuthError(.transportFailed) }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, Darwin.listen(fd, 8) == 0 else { throw CodexOAuthError(.transportFailed) }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let observed = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) }
        }
        let port = UInt16(bigEndian: address.sin_port)
        guard observed == 0, port > 0 else { throw CodexOAuthError(.transportFailed) }
        socket = fd; self.port = port
        redirectURI = URL(string: "http://127.0.0.1:\(port)/auth/callback")!
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        listener = source; descriptors = 1
        source.setEventHandler { [weak self] in self?.acceptConnections() }
        source.setCancelHandler { [weak self] in Darwin.close(fd); self?.descriptorClosed() }
        source.resume(); valid = true
    }
    private static func configure(_ fd: Int32) -> Bool {
        let flags = fcntl(fd, F_GETFL), descriptorFlags = fcntl(fd, F_GETFD)
        var noPipe: Int32 = 1
        return flags >= 0 && descriptorFlags >= 0 && fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 &&
            fcntl(fd, F_SETFD, descriptorFlags | FD_CLOEXEC) == 0 &&
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noPipe, socklen_t(MemoryLayout<Int32>.size)) == 0
    }
    private func acceptConnections() {
        guard !closing else { return }
        while true {
            var address = sockaddr_in(), length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let fd = withUnsafeMutablePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.accept(socket, $0, &length) }
            }
            if fd < 0 {
                if errno == EINTR { continue }
                if errno != EAGAIN && errno != EWOULDBLOCK { stopOnQueue() }
                return
            }
            attempted += 1
            guard attempted <= 64, connections.count < 8, address.sin_addr.s_addr == inet_addr("127.0.0.1"), Self.configure(fd) else {
                Darwin.close(fd)
                if attempted > 64 { stopOnQueue(); return }
                continue
            }
            let connection = Connection(fd: fd, queue: queue), id = connection.id
            // Connection dictionary keys, not native descriptor numbers, guard
            // queued callbacks against descriptor reuse after cancellation.
            connections[id] = connection; descriptors += 2
            connection.read.setEventHandler { [weak self] in self?.read(id) }
            connection.read.setCancelHandler { [weak self] in Darwin.close(fd); self?.descriptorClosed() }
            connection.timer.schedule(deadline: .now() + .seconds(5))
            connection.timer.setEventHandler { [weak self] in self?.retire(id) }
            connection.timer.setCancelHandler { [weak self] in self?.descriptorClosed() }
            connection.read.resume(); connection.timer.resume()
        }
    }
    private func read(_ id: UUID) {
        guard let connection = connections[id] else { return }
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = Darwin.recv(connection.fd, &buffer, buffer.count, 0)
            if count == 0 { retire(id); return }
            if count < 0 {
                if errno == EINTR { continue }
                if errno != EAGAIN && errno != EWOULDBLOCK { retire(id) }
                return
            }
            guard !connection.awaitingDecision, connection.output.isEmpty, connection.input.count + count <= 16_384 else {
                reply(id, status: 400); return
            }
            connection.input.append(contentsOf: buffer.prefix(count))
            if let end = connection.input.range(of: Data([13, 10, 13, 10])) {
                guard end.upperBound == connection.input.endIndex,
                      let target = parse(connection.input) else { reply(id, status: 400); return }
                connection.awaitingDecision = true; connection.input = Data()
                switch sink.yield(.init(id: id, url: redirectURI.absoluteString + target)) {
                case .enqueued: break
                case .dropped, .terminated: retire(id)
                @unknown default: retire(id)
                }
                return
            }
        }
    }
    private func parse(_ data: Data) -> String? {
        guard let value = String(data: data, encoding: .utf8) else { return nil }
        let lines = value.components(separatedBy: "\r\n")
        guard let first = lines.first else { return nil }
        let request = first.split(separator: " ", omittingEmptySubsequences: false)
        guard request.count == 3, request[0] == "GET", request[2] == "HTTP/1.1" || request[2] == "HTTP/1.0" else { return nil }
        let target = String(request[1])
        guard target.hasPrefix("/auth/callback?"), target.utf8.allSatisfy({ $0 >= 33 && $0 <= 126 }),
              !target.contains("#"), let parts = URLComponents(string: target), parts.scheme == nil, parts.host == nil,
              parts.percentEncodedPath == "/auth/callback", parts.fragment == nil, parts.query != nil else { return nil }
        let headers = lines.dropFirst().dropLast(2)
        guard headers.count <= 32 else { return nil }
        var names: Set<String> = [], host: String?
        for header in headers {
            guard let colon = header.firstIndex(of: ":") else { return nil }
            let rawName = String(header[..<colon]), name = rawName.lowercased()
            guard !rawName.isEmpty, rawName.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }),
                  names.insert(name).inserted else { return nil }
            let content = header[header.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !content.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { return nil }
            if name == "host" { host = content }
            if name == "transfer-encoding" || (name == "content-length" && content != "0") { return nil }
        }
        guard host == "127.0.0.1:\(port)" else { return nil }
        return String(target.dropFirst("/auth/callback".count))
    }
    func respond(_ id: UUID, accepted: Bool) async {
        await withCheckedContinuation { continuation in queue.async { self.reply(id, status: accepted ? 200 : 400); continuation.resume() } }
    }
    /// A successful decision closes admission immediately, drains its generic
    /// response, then joins every owned descriptor before returning to the flow.
    func complete(_ id: UUID) async -> Bool {
        let accepted = await withCheckedContinuation { continuation in
            queue.async {
                guard !self.closing, self.connections[id]?.awaitingDecision == true else { continuation.resume(returning: false); return }
                self.closing = true; self.listener?.cancel(); self.listener = nil; self.sink.finish()
                for other in Array(self.connections.keys) where other != id { self.retire(other) }
                self.reply(id, status: 200); continuation.resume(returning: true)
            }
        }
        if accepted { await joined() }; return accepted
    }
    private func reply(_ id: UUID, status: Int) {
        guard let connection = connections[id] else { return }
        if !connection.output.isEmpty { retire(id); return }
        let body = status == 200 ? "ChatGPT sign-in was received. Return to Coincide." : "This sign-in request was not accepted."
        let reason = status == 200 ? "OK" : "Bad Request"
        connection.output = Data("HTTP/1.1 \(status) \(reason)\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nX-Content-Type-Options: nosniff\r\n\r\n\(body)".utf8)
        write(id)
    }
    private func write(_ id: UUID) {
        guard let connection = connections[id] else { return }
        while connection.offset < connection.output.count {
            let sent = connection.output.withUnsafeBytes { bytes in
                Darwin.send(connection.fd, bytes.baseAddress!.advanced(by: connection.offset), bytes.count - connection.offset, 0)
            }
            if sent < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    if connection.write == nil {
                        let source = DispatchSource.makeWriteSource(fileDescriptor: connection.fd, queue: queue)
                        connection.write = source; self.descriptors += 1
                        source.setEventHandler { [weak self] in self?.write(id) }
                        source.setCancelHandler { [weak self] in self?.descriptorClosed() }; source.resume()
                    }
                    return
                }
                retire(id); return
            }
            if sent == 0 { retire(id); return }; connection.offset += sent
        }
        retire(id)
    }
    private func retire(_ id: UUID) {
        guard let connection = connections.removeValue(forKey: id) else { return }
        connection.timer.cancel(); connection.write?.cancel(); connection.read.cancel()
    }
    private func descriptorClosed() {
        descriptors -= 1
        if closing && descriptors == 0 {
            let pending = closeWaiters; closeWaiters = []; for waiter in pending { waiter.resume() }
        }
    }
    private func stopOnQueue() {
        closing = true; listener?.cancel(); listener = nil; sink.finish()
        for id in Array(connections.keys) { retire(id) }
    }
    func stop() { queue.async { self.stopOnQueue() } }
    func close() async {
        await withCheckedContinuation { continuation in
            queue.async {
                self.stopOnQueue()
                if self.descriptors == 0 { continuation.resume() } else { self.closeWaiters.append(continuation) }
            }
        }
    }
    private func joined() async {
        await withCheckedContinuation { continuation in
            queue.async {
                if self.descriptors == 0 { continuation.resume() } else { self.closeWaiters.append(continuation) }
            }
        }
    }
}
