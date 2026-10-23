import Foundation
@preconcurrency import Network

public struct ScheduledTaskHTTPRequest: Sendable {
    public let method: String
    public let path: String
    public let headers: [String: String]
    public let body: Data
    public init(method: String, path: String, headers: [String: String], body: Data) {
        self.method = method; self.path = path; self.headers = headers; self.body = body
    }
}
public struct ScheduledTaskHTTPResponse: Sendable {
    public let status: Int
    public let outcome: String
    public init(status: Int, outcome: String = "refused") { self.status = status; self.outcome = outcome }
}
public enum ScheduledTaskHTTPParser {
    public static let maximumHeaderBytes = 16_384
    public static let maximumBodyBytes = 1_048_576
    /// Exactly one request per connection. Reject ambiguous framing and duplicate
    /// headers rather than accepting a proxy-dependent interpretation.
    public static func parse(_ bytes: Data) throws -> ScheduledTaskHTTPRequest? {
        let separator = Data([13, 10, 13, 10])
        guard let boundary = bytes.range(of: separator) else {
            guard bytes.count <= maximumHeaderBytes else { throw ScheduledTaskError.invalidWebhook }; return nil
        }
        let headerBytes = bytes[..<boundary.lowerBound]
        guard headerBytes.count <= maximumHeaderBytes, let header = String(data: headerBytes, encoding: .ascii) else { throw ScheduledTaskError.invalidWebhook }
        let lines = header.components(separatedBy: "\r\n")
        guard let first = lines.first, lines.count <= 65 else { throw ScheduledTaskError.invalidWebhook }
        let parts = first.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "POST", parts[2] == "HTTP/1.1", parts[1].hasPrefix("/"),
              parts[1].utf8.count <= 4096, !parts[1].contains("#"), !parts[1].contains("\0") else { throw ScheduledTaskError.invalidWebhook }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":"), colon != line.startIndex else { throw ScheduledTaskError.invalidWebhook }
            let name = line[..<colon].lowercased(), value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard ScheduledTaskWebhookSecurity.headerName(name), headers[name] == nil,
                  !value.unicodeScalars.contains(where: { $0.value < 32 && $0 != "\t" || $0.value == 127 }) else { throw ScheduledTaskError.invalidWebhook }
            headers[name] = value
        }
        guard headers["transfer-encoding"] == nil, let length = headers["content-length"], !length.isEmpty,
              length.utf8.allSatisfy({ (48...57).contains($0) }), let count = Int(length), count <= maximumBodyBytes,
              headers["expect"] == nil else { throw ScheduledTaskError.invalidWebhook }
        let offset = boundary.upperBound, remaining = bytes.count - offset
        guard remaining <= count else { throw ScheduledTaskError.invalidWebhook }
        guard remaining == count else { return nil }
        return .init(method: String(parts[0]), path: String(parts[1]), headers: headers, body: Data(bytes[offset...]))
    }
}

/// An explicit loopback-only endpoint. Constructing the service does not listen.
/// Connections and their accepted handlers are joined before shutdown returns.
public actor ScheduledTaskHTTPServer {
    public typealias Handler = @Sendable (ScheduledTaskHTTPRequest) async -> ScheduledTaskHTTPResponse
    private let handler: Handler
    private let queue = DispatchQueue(label: "coincide.scheduled-webhook")
    private var listener: NWListener?
    private var startup: CheckedContinuation<UInt16, any Error>?
    public private(set) var isListening = false
    private var closed = false
    private struct Peer { let connection: NWConnection; let task: Task<Void, Never> }
    private var peers: [UUID: Peer] = [:]
    var activeConnectionCount: Int { peers.count }
    public init(handler: @escaping Handler) { self.handler = handler }
    public func start(port: UInt16 = 0) async throws -> UInt16 {
        guard listener == nil, !closed else { throw ScheduledTaskError.unavailable }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in Task { guard let self else { connection.cancel(); return }; await self.accept(connection) } }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            switch state {
            case .ready: if let port = listener?.port?.rawValue { Task { await self?.started(.success(port)) } }
            case .failed: Task { await self?.started(.failure(ScheduledTaskError.unavailable)) }
            case .cancelled: Task { await self?.started(.failure(CancellationError())) }
            default: break
            }
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                startup = continuation; listener.start(queue: queue)
            }
        } onCancel: { listener.cancel(); Task { await self.started(.failure(CancellationError())) } }
    }
    private func started(_ result: Result<UInt16, any Error>) {
        if case .success = result { isListening = !closed } else { isListening = false }
        let continuation = startup; startup = nil; continuation?.resume(with: result)
    }
    private func accept(_ connection: NWConnection) {
        guard !closed, peers.count < 8 else { connection.cancel(); return }
        let id = UUID(), handler = handler, queue = queue
        let task = Task { [weak self] in
            let timeout = Task { try? await Task.sleep(for: .seconds(5)); if !Task.isCancelled { connection.cancel() } }
            connection.start(queue: queue)
            var response = ScheduledTaskHTTPResponse(status: 400)
            do {
                var bytes = Data()
                while !Task.isCancelled {
                    let chunk: Data = try await withCheckedThrowingContinuation { continuation in
                        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, complete, error in
                            if error != nil { continuation.resume(throwing: ScheduledTaskError.invalidWebhook) }
                            else if let data, !data.isEmpty { continuation.resume(returning: data) }
                            else if complete { continuation.resume(throwing: ScheduledTaskError.invalidWebhook) }
                            else { continuation.resume(throwing: ScheduledTaskError.invalidWebhook) }
                        }
                    }
                    guard bytes.count + chunk.count <= ScheduledTaskHTTPParser.maximumBodyBytes + ScheduledTaskHTTPParser.maximumHeaderBytes + 4 else { throw ScheduledTaskError.invalidWebhook }
                    bytes.append(chunk)
                    if let request = try ScheduledTaskHTTPParser.parse(bytes) {
                        timeout.cancel(); await timeout.value
                        response = await handler(request)
                        break
                    }
                }
            } catch { }
            timeout.cancel(); await timeout.value
            let body = (try? JSONSerialization.data(withJSONObject: ["outcome": response.outcome], options: [.sortedKeys])) ?? Data("{}".utf8)
            let head = "HTTP/1.1 \(response.status) Response\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            var output = Data(head.utf8); output.append(body)
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                connection.send(content: output, completion: .contentProcessed { _ in continuation.resume() })
            }
            connection.cancel()
            await self?.finished(id)
        }
        peers[id] = .init(connection: connection, task: task)
    }
    private func finished(_ id: UUID) { peers.removeValue(forKey: id) }
    public func shutdown() async {
        closed = true; listener?.cancel(); listener = nil; started(.failure(CancellationError()))
        let active = Array(peers.values)
        // Close sockets to finish bounded reads; accepted input handlers are joined,
        // not cancelled or replayed, while their own Engine command completes.
        for peer in active { peer.connection.cancel() }
        for peer in active { await peer.task.value }
    }
}
