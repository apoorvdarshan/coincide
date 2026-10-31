import CoincideKit
import Darwin
import Foundation

/// The computer-use helper belongs to the signed GUI app, so its macOS permissions belong to Coincide.
/// Each thread has its own MCP transport and lifecycle; none connects to the standalone driver's service.
@MainActor
final class ComputerUseRuntime {
    enum Failure: LocalizedError {
        case missingExecutable, startTimedOut, stopped, invalidEndpoint, invalidResponse, incompatibleVersion
        case helperExited(Int32), unknownTool

        var errorDescription: String? {
            switch self {
            case .missingExecutable: String(localized: "This copy of Coincide doesn’t include the computer-use helper.")
            case .startTimedOut: String(localized: "The computer-use helper did not start in time.")
            case .stopped: String(localized: "Computer Use is stopped.")
            case .invalidEndpoint: String(localized: "The computer-use helper’s private connection could not be verified.")
            case .invalidResponse: String(localized: "The computer-use helper returned an invalid response.")
            case .incompatibleVersion: String(localized: "The computer-use helper does not match this version of Coincide.")
            case .helperExited(let status): String(localized: "The computer-use helper exited with status \(status).")
            case .unknownTool: String(localized: "That computer-use action is unavailable.")
            }
        }
    }

    @MainActor private final class Client {
        let process: LineProcess
        let connection: ACPConnection
        let session: String
        var tools: [JSONValue] = []
        var initialization: Task<Void, Error>?
        var initialized = false

        init(process: LineProcess, session: String) {
            self.process = process
            self.session = session
            connection = ACPConnection { [weak process] line in process?.write(line) }
        }

        func hasTool(_ name: String) -> Bool { tools.contains { $0["name"]?.string == name } }

        func close(_ error: Error, gracefully: Bool) {
            initialization?.cancel()
            initialization = nil
            if gracefully, initialized, hasTool("end_session"), !connection.isClosed {
                // Queue the explicit release before EOF. Closing the transport also cleans up its lifecycle
                // if the helper cannot finish this request; no user action is retried.
                connection.send("tools/call", params: ["name": "end_session", "arguments": ["session": .string(session)]],
                    timeout: 1) { _ in }
            }
            connection.close(with: error)
            process.closeInput()
            if gracefully {
                let process = process
                Task {
                    try? await Task.sleep(for: .seconds(1))
                    process.terminate()
                }
            } else {
                process.terminate()
            }
        }
    }

    static let backendVersion = "0.38.0"
    private let executable: URL?
    private let startupTimeout: TimeInterval
    private let requestTimeout: TimeInterval
    private var daemon: LineProcess?
    private var folder: URL?
    private var socket: String?
    private var ready = false
    private var generation = UUID()
    private var starting: Task<Void, Error>?
    private var clients: [UUID: Client] = [:]

    /// Only unexpected daemon exits are reported. Stopping a thread's proxy does not stop other threads.
    var onExit: (() -> Void)?
    var isRunning: Bool { ready && daemon?.isRunning == true }

    init(executable: URL? = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/cua-driver"),
        startupTimeout: TimeInterval = 10, requestTimeout: TimeInterval = 115)
    {
        self.executable = executable
        self.startupTimeout = min(max(startupTimeout, 0.1), 30)
        self.requestTimeout = min(max(requestTimeout, 0.1), 115)
    }

    isolated deinit {
        starting?.cancel()
        for client in clients.values { client.close(Failure.stopped, gracefully: false) }
        daemon?.terminate()
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    func start() async throws {
        if isRunning { return }
        if let starting { return try await starting.value }
        if daemon != nil { stop() }
        let generation = UUID()
        self.generation = generation
        let task = Task { [weak self] in
            guard let self else { throw Failure.stopped }
            try await self.startDaemon(generation: generation)
        }
        starting = task
        do {
            try await task.value
            guard self.generation == generation else { throw Failure.stopped }
            starting = nil
        } catch {
            if self.generation == generation { stop() }
            throw error
        }
    }

    func stop() {
        generation = UUID()
        ready = false
        let starting = starting
        self.starting = nil
        starting?.cancel()
        let clients = clients
        self.clients.removeAll()
        for client in clients.values { client.close(Failure.stopped, gracefully: false) }
        let daemon = daemon
        self.daemon = nil
        daemon?.terminate()
        socket = nil
        if let folder { try? FileManager.default.removeItem(at: folder) }
        folder = nil
    }

    func toolCatalog(threadID: UUID) async throws -> [JSONValue] {
        try await withTaskCancellationHandler {
            let client = try await client(for: threadID)
            try Task.checkCancellation()
            return client.tools
        } onCancel: {
            Task { @MainActor [weak self] in self?.end(threadID: threadID) }
        }
    }

    func call(threadID: UUID, name: String, arguments: JSONValue) async throws -> JSONValue {
        guard let arguments = arguments.object else { throw Failure.invalidResponse }
        try ComputerUseToolPolicy.validate(name: name, arguments: arguments)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let client = try await client(for: threadID)
            try Task.checkCancellation()
            guard let tool = client.tools.first(where: { $0["name"]?.string == name }) else { throw Failure.unknownTool }
            var scoped = arguments
            // Session controls in agent input were rejected above. A session is lifecycle metadata, not a grant.
            if tool.at("inputSchema.properties.session") != nil { scoped["session"] = .string(client.session) }
            let result: JSONValue
            do {
                result = try await client.connection.request("tools/call",
                    params: ["name": .string(name), "arguments": .object(scoped)], timeout: requestTimeout)
            } catch {
                // A transport failure or timeout has an unknown action outcome. End that transport rather than
                // allowing later input to race it; the action is never replayed on a replacement connection.
                if clients[threadID] === client { end(threadID: threadID) }
                throw error
            }
            try Task.checkCancellation()
            guard clients[threadID] === client, isRunning else { throw Failure.stopped }
            return result
        } onCancel: {
            Task { @MainActor [weak self] in self?.end(threadID: threadID) }
        }
    }

    func end(threadID: UUID) {
        clients.removeValue(forKey: threadID)?.close(Failure.stopped, gracefully: true)
    }

    private func startDaemon(generation: UUID) async throws {
        guard let executable, FileManager.default.isExecutableFile(atPath: executable.path) else { throw Failure.missingExecutable }
        let folder = try Self.privateDirectory()
        self.folder = folder
        let socket = folder.appendingPathComponent("driver.sock").path
        self.socket = socket
        let arguments = [
            "serve", "--embedded", "--socket", socket, "--permission-mode", "standard",
            "--host-bundle-id", Bundle.main.bundleIdentifier ?? "com.apoorvdarshan.coincide",
        ]
        let process = LineProcess(executable: executable, arguments: arguments,
            workingDirectory: folder, environment: Self.environment(directory: folder))
        daemon = process
        process.onExit = { [weak self, weak process] _, _ in
            guard let self, self.generation == generation, self.daemon === process else { return }
            self.stop()
            self.onExit?()
        }
        try process.start()
        let deadline = Date().addingTimeInterval(startupTimeout)
        while Date() < deadline {
            try Task.checkCancellation()
            guard self.generation == generation, daemon === process else { throw Failure.stopped }
            guard process.isRunning else { throw Failure.stopped }
            if try Self.socketIsReady(socket) {
                ready = true
                return
            }
            try await Task.sleep(for: .milliseconds(40))
        }
        throw Failure.startTimedOut
    }

    private func client(for threadID: UUID) async throws -> Client {
        try await start()
        try Task.checkCancellation()
        if let existing = clients[threadID] {
            if let initialization = existing.initialization { try await initialization.value }
            try Task.checkCancellation()
            guard clients[threadID] === existing, existing.initialized, isRunning else { throw Failure.stopped }
            return existing
        }
        guard let executable, let folder, let socket else { throw Failure.stopped }
        let generation = generation
        let process = LineProcess(executable: executable, arguments: ["mcp", "--embedded", "--socket", socket],
            workingDirectory: folder, environment: Self.environment(directory: folder))
        let client = Client(process: process, session: "coincide-" + threadID.uuidString.lowercased())
        clients[threadID] = client
        process.onLine = { [weak client] line in client?.connection.receive(line) }
        process.onExit = { [weak self, weak client] status, _ in
            guard let client else { return }
            client.connection.close(with: Failure.helperExited(status))
            if self?.clients[threadID] === client { self?.clients[threadID] = nil }
        }
        // This client never grants authority to the helper through MCP callbacks.
        client.connection.onRequest = { [weak client] request in
            client?.connection.respond(to: request, error: .methodNotFound(request.method))
        }
        do {
            try process.start()
            let initialization = Task { [weak self, weak client] in
                guard let self, let client else { throw Failure.stopped }
                try await self.initialize(client)
            }
            client.initialization = initialization
            try await initialization.value
            try Task.checkCancellation()
            guard self.generation == generation, clients[threadID] === client, isRunning else { throw Failure.stopped }
            client.initialization = nil
            return client
        } catch {
            if clients[threadID] === client { clients[threadID] = nil }
            client.close(error, gracefully: false)
            throw error
        }
    }

    private func initialize(_ client: Client) async throws {
        let result = try await client.connection.request("initialize", params: [
            "protocolVersion": "2024-11-05", "capabilities": [:],
            "clientInfo": ["name": "Coincide", "version": "1"],
        ], timeout: min(requestTimeout, 15))
        guard result.at("serverInfo.version")?.string == Self.backendVersion else { throw Failure.incompatibleVersion }
        client.connection.notify("notifications/initialized", params: [:])
        var tools: [JSONValue] = []
        var names: Set<String> = []
        var cursor: String?
        for page in 0..<8 {
            let parameters: JSONValue = cursor.map { ["cursor": .string($0)] } ?? [:]
            let listed = try await client.connection.request("tools/list", params: parameters, timeout: min(requestTimeout, 15))
            guard let rows = listed["tools"]?.array else { throw Failure.invalidResponse }
            for tool in rows {
                guard let name = tool["name"]?.string, !name.isEmpty, names.insert(name).inserted,
                    tool["inputSchema"]?.object != nil else { throw Failure.invalidResponse }
                tools.append(tool)
                guard tools.count <= 512 else { throw Failure.invalidResponse }
            }
            cursor = listed["nextCursor"]?.string
            if cursor == nil { break }
            if page == 7 { throw Failure.invalidResponse }
        }
        guard !tools.isEmpty else { throw Failure.invalidResponse }
        client.tools = tools
        if client.hasTool("start_session") {
            let started = try await client.connection.request("tools/call",
                params: ["name": "start_session", "arguments": ["session": .string(client.session)]], timeout: min(requestTimeout, 15))
            guard started["isError"]?.bool != true else { throw Failure.invalidResponse }
        }
        client.initialized = true
    }

    private static func environment(directory: URL) -> [String: String] {
        // Do not pass providers' API keys, unlocked vault sessions or an old standalone Cua endpoint to the helper.
        let source = ProcessInfo.processInfo.environment
        var environment = source.filter { key, _ in
            ["HOME", "USER", "LOGNAME", "LANG", "__CF_USER_TEXT_ENCODING"].contains(key) || key.hasPrefix("LC_")
        }
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["TMPDIR"] = directory.path + "/"
        environment["CUA_DRIVER_EMBEDDED"] = "1"
        environment["CUA_DRIVER_HOST_BUNDLE_ID"] = "com.apoorvdarshan.coincide"
        environment["CUA_DRIVER_PERMISSION_MODE"] = "standard"
        return environment
    }

    private static func privateDirectory() throws -> URL {
        // macOS Unix sockets allow only a short path; NSTemporaryDirectory can exceed that limit.
        var template = Array("/private/tmp/coincide-cua-XXXXXX".utf8CString)
        let path = template.withUnsafeMutableBufferPointer { buffer -> String? in
            guard let pointer = mkdtemp(buffer.baseAddress!) else { return nil }
            return String(cString: pointer)
        }
        guard let path else { throw Failure.invalidEndpoint }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private static func socketIsReady(_ path: String) throws -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else { return false }
        guard info.st_uid == geteuid(), info.st_mode & S_IFMT == S_IFSOCK, chmod(path, 0o600) == 0 else {
            throw Failure.invalidEndpoint
        }
        var address = sockaddr_un()
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw Failure.invalidEndpoint }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
        }
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw Failure.invalidEndpoint }
        defer { Darwin.close(descriptor) }
        _ = fcntl(descriptor, F_SETFL, O_NONBLOCK)
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
    }
}
