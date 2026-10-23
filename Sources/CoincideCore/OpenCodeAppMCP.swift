import Foundation

enum OpenCodeAppMCPError: Error, Sendable, LocalizedError {
    case unavailable
    var errorDescription: String? { "The native OpenCode app tool connection could not be verified. No input was sent." }
}

extension AppMCPConnection {
    /// Decode before scrubbing so JSON's Unicode escapes cannot conceal an
    /// otherwise exact credential echo. Invalid JSON remains a protocol error.
    func redactingOpenCodeJSON(_ data: Data) throws -> Data {
        guard !data.isEmpty else { return data }
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: data) else { throw OpenCodeHTTPError.invalidResponse }
        return try JSONEncoder().encode(redacting(value))
    }

    func redactingOpenCodeEvent(_ event: OpenCodeSSEEvent) throws -> OpenCodeSSEEvent {
        .init(event: redacting(event.event), data: String(decoding: try redactingOpenCodeJSON(Data(event.data.utf8)), as: UTF8.self),
            id: event.id.map(redacting), retryMilliseconds: event.retryMilliseconds)
    }
}

/// App tools belong to one owned OpenCode process. Native MCP registration is
/// runtime-only; it never edits a workspace or the user's MCP configuration.
actor OpenCodeAppMCP {
    static let serverName = "coincide"
    private let client: OpenCodeHTTPClient
    private let generation: OpenCodeGeneration
    private let directory: URL
    private let connection: AppMCPConnection
    private var registered = false
    private var failed = false
    private var closed = false
    private var preparing: Task<Void, any Error>?

    init(client: OpenCodeHTTPClient, generation: OpenCodeGeneration, directory: URL, connection: AppMCPConnection) {
        self.client = client; self.generation = generation; self.directory = directory; self.connection = connection
    }

    static func failure() -> OpenCodeAppMCPError { .unavailable }

    /// A connected native catalogue is required before every input. Location
    /// eviction may remove v2's runtime registration between ordinary turns.
    func prepare() async throws {
        guard !closed, !failed else { throw Self.failure() }
        if let preparing { try await preparing.value; return }
        let task = Task {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await self.registerIfNeeded() }
                group.addTask { try await Task.sleep(for: .seconds(30)); throw Self.failure() }
                defer { group.cancelAll() }
                _ = try await group.next()
            }
        }
        preparing = task
        do {
            try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            preparing = nil
            guard !closed else { throw Self.failure() }
        } catch { preparing = nil; failed = true; throw Self.failure() }
    }

    private var query: [URLQueryItem] {
        [.init(name: generation == .v1 ? "directory" : "location[directory]", value: directory.path)]
    }

    private func statuses() async throws -> [String: String] {
        try Task.checkCancellation()
        let response = try await client.request(path: generation == .v1 ? ["mcp"] : ["api", "mcp"], query: query, maximumBytes: 1_048_576)
        let raw = try Self.json(response)
        var result: [String: String] = [:]
        if generation == .v1 {
            guard let values = raw.object, values.count <= 256 else { throw Self.failure() }
            for (name, value) in values { try Self.addStatus(name: name, value: value, result: &result) }
        } else {
            let located = try OpenCodeCatalog.located(raw, directory: directory.path)
            guard let values = located.array, values.count <= 256 else { throw Self.failure() }
            for value in values {
                guard let name = value["name"].string else { throw Self.failure() }
                try Self.addStatus(name: name, value: value["status"], result: &result)
            }
        }
        // Native tool IDs flatten a server prefix and tool name. Reserving the
        // whole prefix avoids granting our native allowance to a foreign server
        // such as coincide_extra, including case or punctuation variants.
        guard !result.keys.contains(where: { $0 != Self.serverName && $0.hasPrefix(Self.serverName) }) else { throw Self.failure() }
        return result
    }

    private static func addStatus(name: String, value: JSONValue, result: inout [String: String]) throws {
        guard MCPProtocol.text(name, maximum: 256), let status = value["status"].string,
              ["connected", "pending", "disabled", "failed", "needs_auth", "needs_client_registration"].contains(status),
              result[name.lowercased()] == nil else { throw failure() }
        result[name.lowercased()] = status
    }

    private static func json(_ response: OpenCodeHTTPResponse) throws -> JSONValue {
        let media = response.headers["content-type"]?.split(separator: ";", maxSplits: 1).first?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard response.status == 200, media == "application/json",
              let value = try? JSONDecoder().decode(JSONValue.self, from: response.body) else { throw failure() }
        try MCPProtocol.validateJSON(value)
        return value
    }

    private func registerIfNeeded() async throws {
        let initial = try await statuses()
        guard !closed else { throw Self.failure() }
        if !registered { guard initial[Self.serverName] == nil else { throw Self.failure() } }
        if registered, initial[Self.serverName] == "connected" { return }
        // A present failed/disabled server must not be silently replaced. Only
        // absence after this actor's registration permits v2 eviction recovery.
        guard initial[Self.serverName] == nil else { throw Self.failure() }
        let timeout: JSONValue = generation == .v1 ? .number(3_660_000) :
            .object(["startup": .number(10_000), "catalog": .number(10_000), "execution": .number(3_660_000)])
        let config: JSONValue = .object(["type": .string("remote"), "url": .string(connection.endpoint.absoluteString),
            "headers": .object(["Authorization": .string(connection.authorizationHeader)]), "oauth": .bool(false), "timeout": timeout])
        let body: JSONValue = generation == .v1 ? .object(["name": .string(Self.serverName), "config": config]) : .object(["config": config])
        // Set before the mutation: a lost HTTP response can still mean that the
        // native process accepted this actor's credential. Close drains it.
        registered = true
        let response = try await client.request(method: generation == .v1 ? "POST" : "PUT",
            path: generation == .v1 ? ["mcp"] : ["api", "experimental", "mcp", Self.serverName], query: query,
            body: JSONEncoder().encode(body), maximumBytes: 1_048_576)
        guard !closed else { throw Self.failure() }
        if generation == .v1 {
            let value = try Self.json(response)
            guard value.object != nil, value[Self.serverName]["status"] == .string("connected") else { throw Self.failure() }
        } else { guard response.status == 204, response.body.isEmpty else { throw Self.failure() } }
        for _ in 0..<100 {
            let current = try await statuses()
            guard !closed else { throw Self.failure() }
            if current[Self.serverName] == "connected" { return }
            guard current[Self.serverName] == "pending" else { throw Self.failure() }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw Self.failure()
    }

    func close() async {
        guard !closed else { return }
        closed = true
        preparing?.cancel(); _ = await preparing?.result; preparing = nil
        guard registered else { return }
        // Only the exact name installed by this actor is removed. V1 exposes
        // disconnect; the subsequently joined owned process drops its runtime set.
        let client = client, generation = generation, query = query
        try? await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                _ = try await client.request(method: generation == .v1 ? "POST" : "DELETE",
                    path: generation == .v1 ? ["mcp", Self.serverName, "disconnect"] : ["api", "experimental", "mcp", Self.serverName],
                    query: query, body: generation == .v1 ? Data("{}".utf8) : nil, maximumBytes: 1_048_576)
            }
            group.addTask { try await Task.sleep(for: .seconds(2)); throw CancellationError() }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
        registered = false
    }
}
