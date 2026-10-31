import Foundation
import Network
import Security

/// An ephemeral, loopback-only capability for one thread's schedules (`coincide_schedule`), as `ComputerUseBridge` is
/// for Computer Use: each thread gets its own token in a private curl config (0600, in a 0700 folder), sent as an
/// Authorization header, never in the URL. The thread comes from the grant the token matches, so a request can only
/// reach its own thread. Requests a browser could make (with an Origin header, or not JSON) are refused.
@MainActor
public final class ScheduleBridge {
    public struct Access: Sendable {
        public let configuration: URL
        public let directory: URL
    }

    public typealias Handler = @MainActor (ScheduleRequest, UUID) throws -> JSONValue
    private struct Grant {
        let token: String
        let access: Access
    }

    private static let pathPrefix = "/schedule/"
    private static let maximumConnections = 16
    private static let maximumResponse = 1_048_576
    private let directory: URL
    private let handler: Handler
    private var listener: NWListener?
    private var port: UInt16?
    private var starting: Task<UInt16, Error>?
    private var generation = UUID()
    private var grants: [UUID: Grant] = [:]
    private var connections: [UUID: NWConnection] = [:]

    public init(directory: URL? = nil, handler: @escaping Handler) {
        self.directory = directory ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("CoincideSchedule-" + UUID().uuidString, isDirectory: true)
        self.handler = handler
    }

    public var isReady: Bool { port != nil }
    /// The loopback port, once listening.
    var listeningPort: UInt16? { port }
    public func access(for threadID: UUID) -> Access? { grants[threadID]?.access }

    /// Starts the loopback listener ahead of the first grant, so `enableNow` works synchronously.
    public func prepare() async throws { _ = try await start() }

    /// Grants access at once when the listener is running; nil otherwise.
    public func enableNow(threadID: UUID) -> Access? {
        if let access = access(for: threadID) { return access }
        guard isReady else { return nil }
        return try? grant(threadID: threadID)
    }

    /// Grants access, waiting for the listener if needed. For tests.
    public func enable(threadID: UUID) async throws -> Access {
        if let access = access(for: threadID) { return access }
        try await prepare()
        if let access = access(for: threadID) { return access }
        return try grant(threadID: threadID)
    }

    private func grant(threadID: UUID) throws -> Access {
        guard let port else { throw ScheduleError.invalidRequest("Scheduling is unavailable.") }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw ScheduleError.invalidRequest("Scheduling is unavailable.")
        }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        let folder = directory.appendingPathComponent(threadID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let configuration = folder.appendingPathComponent("schedule.curl")
        let config = """
            url = "http://127.0.0.1:\(port)\(Self.pathPrefix)\(threadID.uuidString)"
            header = "Authorization: Bearer \(token)"
            header = "Content-Type: application/json"
            silent
            show-error
            max-time = 30
            noproxy = "*"
            \n
            """
        guard FileManager.default.createFile(atPath: configuration.path, contents: Data(config.utf8), attributes: [.posixPermissions: 0o600])
        else {
            try? FileManager.default.removeItem(at: folder)
            throw ScheduleError.invalidRequest("Scheduling is unavailable.")
        }
        let access = Access(configuration: configuration, directory: folder)
        grants[threadID] = Grant(token: token, access: access)
        return access
    }

    /// Revokes a thread's access, for a thread that no longer exists.
    public func disable(threadID: UUID) {
        guard let grant = grants.removeValue(forKey: threadID) else { return }
        try? FileManager.default.removeItem(at: grant.access.directory)
    }

    public func stop() {
        generation = UUID()
        grants.removeAll()
        listener?.cancel()
        listener = nil
        port = nil
        starting?.cancel()
        starting = nil
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
        try? FileManager.default.removeItem(at: directory)
    }

    private func start() async throws -> UInt16 {
        if let port { return port }
        if let starting { return try await starting.value }
        let generation = self.generation
        let failure = ScheduleError.invalidRequest("Scheduling is unavailable.")
        let task = Task { @MainActor [weak self] () throws -> UInt16 in
            guard let self, generation == self.generation, !Task.isCancelled else { throw failure }
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            let listener = try NWListener(using: parameters)
            self.listener = listener
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            return try await withCheckedThrowingContinuation { continuation in
                var settled = false
                listener.stateUpdateHandler = { state in
                    MainActor.assumeIsolated {
                        guard !settled else { return }
                        switch state {
                        case .ready:
                            settled = true
                            listener.stateUpdateHandler = nil
                            if generation != self.generation {
                                listener.cancel()
                                continuation.resume(throwing: failure)
                            } else if let port = listener.port?.rawValue { continuation.resume(returning: port) }
                            else { continuation.resume(throwing: failure) }
                        case .failed, .cancelled:
                            settled = true
                            listener.stateUpdateHandler = nil
                            continuation.resume(throwing: failure)
                        default: break
                        }
                    }
                }
                listener.start(queue: .main)
            }
        }
        starting = task
        do {
            let ready = try await task.value
            guard generation == self.generation, !Task.isCancelled else { throw failure }
            port = ready
            starting = nil
            return ready
        } catch {
            if generation == self.generation {
                starting = nil
                listener?.cancel()
                listener = nil
            }
            throw error
        }
    }

    private func accept(_ connection: NWConnection) {
        guard connections.count < Self.maximumConnections else { connection.cancel(); return }
        let id = UUID()
        connections[id] = connection
        connection.start(queue: .main)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(15))
            self?.close(id)
        }
        receive(connection, id: id, data: Data())
    }

    private func receive(_ connection: NWConnection, id: UUID, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] chunk, _, complete, error in
            Task { @MainActor in
                guard let self, self.connections[id] != nil else { return }
                var data = data
                if let chunk { data.append(chunk) }
                do {
                    guard data.count <= ComputerUseHTTPRequest.maximumBody + ComputerUseHTTPRequest.maximumHeaders else {
                        throw ComputerUseError.invalidRequest
                    }
                    if let request = try ComputerUseHTTPRequest.parse(data) {
                        self.respond(to: request, connection: connection, id: id)
                    } else if complete || error != nil { self.close(id) }
                    else { self.receive(connection, id: id, data: data) }
                } catch {
                    self.reply(["error": .string("Send one JSON POST request.")], status: 400, to: connection, id: id)
                }
            }
        }
    }

    /// Answers one request.
    private func respond(to request: ComputerUseHTTPRequest, connection: NWConnection, id: UUID) {
        let (body, status) = answer(path: request.path, host: request.host, authorization: request.authorization, body: request.body)
        reply(body, status: status, to: connection, id: id)
    }

    /// The reply to a parsed request: the thread named in the path must hold a grant whose token the Authorization
    /// header carries.
    func answer(path: String, host: String, authorization: String, body: Data) -> (JSONValue, Int) {
        guard let port, host == "127.0.0.1:\(port)", path.hasPrefix(Self.pathPrefix),
            let thread = UUID(uuidString: String(path.dropFirst(Self.pathPrefix.count))),
            let grant = grants[thread], Self.matches(authorization, "Bearer " + grant.token)
        else { return (["error": "Schedule access denied"], 403) }
        do {
            guard let json = JSONValue.parse(body) else {
                throw ScheduleError.invalidRequest("The body must be JSON.")
            }
            let request = try ScheduleRequest(json: json)
            return (try handler(request, thread), 200)
        } catch {
            return (["error": .string(error.localizedDescription)], 400)
        }
    }

    private static func matches(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8), right = Array(rhs.utf8)
        guard left.count == right.count else { return false }
        return zip(left, right).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    private func reply(_ value: JSONValue, status: Int, to connection: NWConnection, id: UUID) {
        guard connections[id] != nil else { return }
        var body = Data(value.compactJSON.utf8)
        var status = status
        if body.isEmpty || body.count > Self.maximumResponse {
            body = Data(JSONValue.object(["error": "The response was too large."]).compactJSON.utf8)
            status = 400
        }
        var response = Data("HTTP/1.1 \(status) \(status == 200 ? "OK" : "Error")\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { [weak self] _ in
            Task { @MainActor in self?.close(id) }
        })
    }

    private func close(_ id: UUID) {
        connections.removeValue(forKey: id)?.cancel()
    }
}
