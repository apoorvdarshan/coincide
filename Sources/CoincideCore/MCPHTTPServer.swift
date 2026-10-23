import Darwin
import Foundation

/// Private app-owned MCP endpoint. JSON-only Streamable HTTP is intentional:
/// there are no unsolicited server messages, SSE replay, or public OAuth routes.
public actor MCPHTTPServer {
    public typealias InvocationHandler = @Sendable (MCPInvocation) async throws -> MCPToolResult
    public nonisolated let endpoint: URL
    private let owner: MCPHTTPListener
    private let registry: MCPSessionRegistry
    private let tools: [MCPToolDefinition]
    private let invoke: InvocationHandler
    private let requestTimeout: Duration
    private struct Job: Sendable { let task: Task<Void, Never>; let timer: Task<Void, Never> }
    private var jobs: [UUID: Job] = [:]
    private var reader: Task<Void, Never>?
    private var closing = false
    private var closeTask: Task<Void, Never>?

    private init(owner: MCPHTTPListener, registry: MCPSessionRegistry, tools: [MCPToolDefinition],
                 requestTimeout: Duration, invoke: @escaping InvocationHandler) {
        self.owner = owner; self.registry = registry; self.tools = tools; self.invoke = invoke
        self.requestTimeout = requestTimeout; endpoint = owner.endpoint
    }
    public static func start(registry: MCPSessionRegistry, tools: [MCPToolDefinition],
                             requestTimeout: Duration = .seconds(30), invoke: @escaping InvocationHandler) async throws -> MCPHTTPServer {
        guard tools.count <= 256, Set(tools.map(\.name)).count == tools.count,
              requestTimeout > .zero, requestTimeout <= .seconds(900) else { throw MCPError(.invalidConfiguration) }
        for tool in tools { try tool.validate() }
        _ = try MCPProtocol.encode(.object(["tools": .array(tools.map(\.json))]))
        try Task.checkCancellation()
        let owner = try MCPHTTPListener()
        let server = MCPHTTPServer(owner: owner, registry: registry, tools: tools, requestTimeout: requestTimeout, invoke: invoke)
        await server.activate()
        if Task.isCancelled { await server.close(); throw MCPError(.cancelled) }
        return server
    }
    private func activate() {
        let requests = owner.requests
        reader = Task { [weak self] in
            for await request in requests {
                guard !Task.isCancelled else { break }
                await self?.accept(request)
            }
            await self?.sourceEnded()
        }
    }
    private func sourceEnded() {
        guard !closing else { return }
        // Do not await our reader from that reader's own call stack.
        Task { await self.close() }
    }
    private func accept(_ request: MCPHTTPListener.Request) async {
        guard !closing, jobs.count < 64 else {
            await owner.respond(request.id, status: 503, body: nil); return
        }
        let task = Task { [weak self] in
            await self?.serve(request)
            await self?.finished(request.id)
        }
        let timer = Task { [weak self, requestTimeout] in
            do { try await Task.sleep(for: requestTimeout) } catch { return }
            await self?.expire(request.id)
        }
        jobs[request.id] = Job(task: task, timer: timer)
    }
    private func finished(_ id: UUID) { jobs.removeValue(forKey: id)?.timer.cancel() }
    private func expire(_ id: UUID) async {
        guard let job = jobs[id] else { return }
        job.task.cancel()
        await owner.respond(id, status: 408, body: try? MCPProtocol.encode(MCPProtocol.failure(error: .init(.timedOut))))
    }
    private func serve(_ request: MCPHTTPListener.Request) async {
        var responseID: JSONValue = .null
        do {
            try Task.checkCancellation()
            let scope = try await registry.authenticate(request.headers["authorization"])
            guard !closing else { throw MCPError(.cancelled) }
            guard request.method == "POST" else { await owner.respond(request.id, status: 405, body: nil); return }
            guard request.headers["mcp-session-id"] == nil else { throw MCPError(.invalidRequest) }
            let headerVersion = request.headers["mcp-protocol-version"]
            if let headerVersion, !MCPProtocol.supportedVersions.contains(headerVersion) { throw MCPError(.invalidRequest) }
            guard request.headers["content-type"]?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() == "application/json" else { throw MCPError(.invalidRequest) }
            let accepts = Set((request.headers["accept"] ?? "").split(separator: ",").compactMap { $0.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() })
            guard accepts.contains("application/json"), accepts.contains("text/event-stream") else { throw MCPError(.invalidRequest) }
            let message = try MCPProtocol.decode(request.body)
            guard let object = message.object, message["jsonrpc"].string == "2.0" else { throw MCPError(.invalidRequest) }
            if object["method"] == nil {
                // We initiate no server requests, so no client response is owned.
                throw MCPError(.invalidRequest)
            }
            guard let method = message["method"].string, MCPProtocol.text(method, maximum: 128),
                  object["result"] == nil, object["error"] == nil,
                  object["params"] == nil || message["params"].object != nil else { throw MCPError(.invalidRequest) }
            let params = message["params"]
            guard let id = object["id"] else {
                switch method {
                case "notifications/initialized": try await registry.initialized(sessionID: scope.sessionID, version: headerVersion)
                case "notifications/cancelled":
                    try await registry.ready(sessionID: scope.sessionID, version: headerVersion)
                    let cancelledID = try MCPRequestID(params["requestId"])
                    await registry.cancel(sessionID: scope.sessionID, requestID: cancelledID)
                default: try await registry.ready(sessionID: scope.sessionID, version: headerVersion)
                }
                await owner.respond(request.id, status: 202, body: nil); return
            }
            let requestID = try MCPRequestID(id); responseID = id
            try await registry.claim(sessionID: scope.sessionID, requestID: requestID)
            let result: JSONValue
            switch method {
            case "initialize":
                guard let version = params["protocolVersion"].string, MCPProtocol.text(version, maximum: 32),
                      params["capabilities"].object != nil, params["clientInfo"].object != nil,
                      let name = params["clientInfo"]["name"].string, MCPProtocol.text(name, maximum: 256),
                      let clientVersion = params["clientInfo"]["version"].string, MCPProtocol.text(clientVersion, maximum: 128) else { throw MCPError(.invalidParams) }
                let negotiated = try await registry.initialize(sessionID: scope.sessionID, requestedVersion: version)
                result = .object(["protocolVersion": .string(negotiated), "capabilities": .object(["tools": .object(["listChanged": .bool(false)])]),
                    "serverInfo": .object(["name": .string("Coincide"), "version": .string("1.0")])])
            case "ping": result = .object([:])
            case "tools/list":
                try await registry.ready(sessionID: scope.sessionID, version: headerVersion)
                guard params["cursor"] == .null else { throw MCPError(.invalidParams) }
                result = .object(["tools": .array(tools.filter { scope.capabilities.contains($0.capability) }.map(\.json))])
            case "tools/call":
                try await registry.ready(sessionID: scope.sessionID, version: headerVersion)
                guard let name = params["name"].string, let tool = tools.first(where: { $0.name == name }),
                      scope.capabilities.contains(tool.capability) else { throw MCPError(.unavailable) }
                let arguments = params.object?["arguments"] ?? .object([:])
                guard arguments.object != nil else { throw MCPError(.invalidParams) }
                let handler = invoke
                let value = try await registry.invoke(sessionID: scope.sessionID, requestID: requestID, capability: tool.capability) { context in
                    try await handler(MCPInvocation(scope: context, requestID: id, toolName: name, arguments: arguments))
                }
                guard value.content.count <= 256, value.structuredContent == nil || value.structuredContent?.object != nil else { throw MCPError(.limitExceeded) }
                result = value.json
            default:
                try await registry.ready(sessionID: scope.sessionID, version: headerVersion)
                throw MCPError(.methodNotFound)
            }
            try Task.checkCancellation()
            guard !closing else { throw MCPError(.cancelled) }
            await owner.respond(request.id, status: 200, body: try MCPProtocol.encode(MCPProtocol.response(id: id, result: result)))
        } catch {
            let safe: MCPError
            if let error = error as? MCPError { safe = error }
            else if error is CancellationError { safe = .init(.cancelled) }
            else { safe = .init(.internalFailure) }
            let status = safe.kind == .unauthorized ? 401 : (responseID == .null ? 400 : 200)
            await owner.respond(request.id, status: status, body: try? MCPProtocol.encode(MCPProtocol.failure(id: responseID, error: safe)))
        }
    }

    /// Cancellation joins actual callbacks, including cancellation-resistant
    /// ones. The injected handler must cooperate and must not close its own
    /// server/credential from within the invocation it is currently executing.
    public func close() async {
        if let closeTask { await closeTask.value; return }
        closing = true
        reader?.cancel()
        let jobs = Array(jobs.values), reader = reader, registry = registry, owner = owner
        for job in jobs { job.timer.cancel(); job.task.cancel() }
        let task = Task {
            await owner.close()
            await registry.revokeAll()
            for job in jobs { await job.task.value }
            await reader?.value
        }
        closeTask = task
        await task.value
        self.jobs = [:]; self.reader = nil
    }
    deinit {
        owner.stop(); reader?.cancel()
        for job in jobs.values { job.task.cancel(); job.timer.cancel() }
    }
}

/// Nonblocking descriptor ownership is confined to queue. A connection carries
/// exactly one HTTP request; neither TCP EOF nor an interrupted response implies
/// that a previously admitted tool action was cancelled or safe to replay.
private final class MCPHTTPListener: @unchecked Sendable {
    struct Request: Sendable {
        let id: UUID
        let method: String
        let headers: [String: String]
        let body: Data
    }
    let endpoint: URL
    let requests: AsyncStream<Request>
    private let sink: AsyncStream<Request>.Continuation
    private let queue = DispatchQueue(label: "com.apoorvdarshan.coincide.mcp-http")
    private var listener: DispatchSourceRead?
    private var connections: [UUID: Connection] = [:]
    private var closing = false
    private var descriptors = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let port: UInt16
    private final class Connection {
        let id = UUID(), fd: Int32
        let read: DispatchSourceRead, timer: DispatchSourceTimer
        var write: DispatchSourceWrite?
        var input = Data(), output = Data(), offset = 0
        var headerEnd: Int?, contentLength: Int?, method: String?, headers: [String: String] = [:]
        var dispatched = false
        init(fd: Int32, queue: DispatchQueue) {
            self.fd = fd; read = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            timer = DispatchSource.makeTimerSource(queue: queue)
        }
    }
    init() throws {
        let pair = AsyncStream<Request>.makeStream(bufferingPolicy: .bufferingOldest(32))
        requests = pair.stream; sink = pair.continuation
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw MCPError(.unavailable) }
        var valid = false
        defer { if !valid { Darwin.close(fd) } }
        guard Self.configure(fd) else { throw MCPError(.unavailable) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        guard inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1 else { throw MCPError(.unavailable) }
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0, Darwin.listen(fd, 32) == 0 else { throw MCPError(.unavailable) }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let observed = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) } }
        let port = UInt16(bigEndian: address.sin_port)
        guard observed == 0, port > 0 else { throw MCPError(.unavailable) }
        self.port = port; endpoint = URL(string: "http://127.0.0.1:\(port)/mcp")!
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        listener = source; descriptors = 1
        source.setEventHandler { [weak self] in self?.acceptConnections(fd) }
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
    private func acceptConnections(_ socket: Int32) {
        guard !closing else { return }
        for _ in 0..<32 {
            var address = sockaddr_in(), size = socklen_t(MemoryLayout<sockaddr_in>.size)
            let fd = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.accept(socket, $0, &size) } }
            if fd < 0 {
                if errno == EINTR { continue }
                if errno != EAGAIN && errno != EWOULDBLOCK { stopOnQueue() }
                return
            }
            guard connections.count < 32, address.sin_addr.s_addr == inet_addr("127.0.0.1"), Self.configure(fd) else { Darwin.close(fd); continue }
            let connection = Connection(fd: fd, queue: queue), id = connection.id
            connections[id] = connection; descriptors += 2
            connection.read.setEventHandler { [weak self] in self?.read(id) }
            connection.read.setCancelHandler { [weak self] in Darwin.close(fd); self?.descriptorClosed() }
            connection.timer.schedule(deadline: .now() + .seconds(10))
            connection.timer.setEventHandler { [weak self] in self?.expireConnection(id) }
            connection.timer.setCancelHandler { [weak self] in self?.descriptorClosed() }
            connection.read.resume(); connection.timer.resume()
        }
    }
    private func read(_ id: UUID) {
        guard let connection = connections[id] else { return }
        var bytes = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = Darwin.recv(connection.fd, &bytes, bytes.count, 0)
            if count == 0 { retire(id); return }
            if count < 0 {
                if errno == EINTR { continue }
                if errno != EAGAIN && errno != EWOULDBLOCK { retire(id) }
                return
            }
            guard !connection.dispatched, connection.output.isEmpty else { retire(id); return }
            guard connection.input.count + count <= MCPProtocol.maximumBodyBytes + 16_384 else { reply(id, status: 413, body: nil); return }
            connection.input.append(contentsOf: bytes.prefix(count))
            if connection.headerEnd == nil {
                if let end = connection.input.range(of: Data([13, 10, 13, 10])) {
                    guard end.upperBound <= 16_384 else { reply(id, status: 431, body: nil); return }
                    let status = parseHeader(connection, end: end.upperBound)
                    guard status == nil else { reply(id, status: status!, body: nil); return }
                } else {
                    if connection.input.count > 16_384 { reply(id, status: 431, body: nil) }
                    continue
                }
            }
            guard let headerEnd = connection.headerEnd, let length = connection.contentLength else { reply(id, status: 400, body: nil); return }
            let expected = headerEnd + length
            guard connection.input.count <= expected else { reply(id, status: 400, body: nil); return }
            if connection.input.count == expected {
                connection.dispatched = true
                connection.timer.schedule(deadline: .distantFuture)
                let request = Request(id: id, method: connection.method!, headers: connection.headers, body: Data(connection.input[headerEnd...]))
                connection.input = Data(); connection.headers = [:]
                switch sink.yield(request) {
                case .enqueued: break
                case .dropped, .terminated: reply(id, status: 503, body: nil)
                @unknown default: reply(id, status: 503, body: nil)
                }
                return
            }
        }
    }
    private func parseHeader(_ connection: Connection, end: Int) -> Int? {
        guard let text = String(data: connection.input.prefix(end), encoding: .utf8) else { return 400 }
        let lines = text.components(separatedBy: "\r\n")
        guard let first = lines.first else { return 400 }
        let parts = first.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[2] == "HTTP/1.1", !parts[0].isEmpty else { return 400 }
        guard parts[1] == "/mcp" else { return 404 }
        var headers: [String: String] = [:]
        guard lines.count <= 68 else { return 431 }
        for line in lines.dropFirst().dropLast(2) {
            guard let colon = line.firstIndex(of: ":") else { return 400 }
            let rawName = String(line[..<colon]), name = rawName.lowercased()
            guard !name.isEmpty, rawName.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }), headers[name] == nil else { return 400 }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard MCPProtocol.text(value, maximum: 8_192, empty: true) else { return 400 }
            headers[name] = value
        }
        guard headers["host"] == "127.0.0.1:\(port)" else { return 400 }
        if let origin = headers["origin"], origin != "http://127.0.0.1:\(port)" { return 403 }
        guard headers["transfer-encoding"] == nil, headers["expect"] == nil else { return 400 }
        let length: Int
        if let raw = headers["content-length"] {
            guard !raw.isEmpty, raw.utf8.allSatisfy({ (48...57).contains($0) }), raw.count <= 8, let parsed = Int(raw) else { return 400 }
            length = parsed
        } else if parts[0] == "POST" { return 411 }
        else { length = 0 }
        guard length <= MCPProtocol.maximumBodyBytes else { return 413 }
        connection.headerEnd = end; connection.contentLength = length; connection.method = String(parts[0]); connection.headers = headers
        return nil
    }
    func respond(_ id: UUID, status: Int, body: Data?) async {
        await withCheckedContinuation { continuation in queue.async { self.reply(id, status: status, body: body); continuation.resume() } }
    }
    private func reply(_ id: UUID, status: Int, body: Data?) {
        guard let connection = connections[id], connection.output.isEmpty else { return }
        let data = body ?? Data()
        let reason: String
        switch status { case 200: reason = "OK"; case 202: reason = "Accepted"; case 400: reason = "Bad Request"; case 401: reason = "Unauthorized"; case 403: reason = "Forbidden"; case 404: reason = "Not Found"; case 405: reason = "Method Not Allowed"; case 408: reason = "Request Timeout"; case 411: reason = "Length Required"; case 413: reason = "Content Too Large"; case 431: reason = "Request Header Fields Too Large"; default: reason = "Service Unavailable" }
        var header = "HTTP/1.1 \(status) \(reason)\r\nContent-Length: \(data.count)\r\nConnection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\n"
        if !data.isEmpty { header += "Content-Type: application/json\r\n" }
        if status == 405 { header += "Allow: POST, GET\r\n" }
        // Private provider credentials have no public OAuth discovery route.
        if status == 401 { header += "WWW-Authenticate: Bearer\r\n" }
        header += "\r\n"
        connection.input = Data(); connection.headers = [:]
        connection.output = Data(header.utf8); connection.output.append(data)
        connection.timer.schedule(deadline: .now() + .seconds(5))
        write(id)
    }
    private func write(_ id: UUID) {
        guard let connection = connections[id] else { return }
        while connection.offset < connection.output.count {
            let count = connection.output.withUnsafeBytes { Darwin.send(connection.fd, $0.baseAddress!.advanced(by: connection.offset), $0.count - connection.offset, 0) }
            if count < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    if connection.write == nil {
                        let source = DispatchSource.makeWriteSource(fileDescriptor: connection.fd, queue: queue)
                        connection.write = source; descriptors += 1
                        source.setEventHandler { [weak self] in self?.write(id) }
                        source.setCancelHandler { [weak self] in self?.descriptorClosed() }; source.resume()
                    }
                    return
                }
                retire(id); return
            }
            guard count > 0 else { retire(id); return }
            connection.offset += count
        }
        retire(id)
    }
    private func retire(_ id: UUID) {
        guard let connection = connections.removeValue(forKey: id) else { return }
        connection.timer.cancel(); connection.write?.cancel(); connection.read.cancel()
    }
    private func expireConnection(_ id: UUID) {
        guard let connection = connections[id] else { return }
        if connection.output.isEmpty { reply(id, status: 408, body: nil) }
        else { retire(id) }
    }
    private func descriptorClosed() {
        descriptors -= 1
        if closing && descriptors == 0 { let pending = waiters; waiters = []; for waiter in pending { waiter.resume() } }
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
                if self.descriptors == 0 { continuation.resume() } else { self.waiters.append(continuation) }
            }
        }
    }
}
