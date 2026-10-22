import Foundation

public struct OpenCodeServerIdentity: Sendable, Equatable {
    public let generation: OpenCodeGeneration
    public let version: OpenCodeVersion
    public let processIdentifier: Int32?
}

public struct OpenCodeMetadataSnapshot: Sendable, Equatable {
    public let server: OpenCodeServerIdentity
    public let directory: String
    public let models: [OpenCodeModelDescriptor]
    public let agents: [OpenCodeAgentDescriptor]
    public let defaults: [OpenCodeModelSelection]
}

/// Read-only native metadata on an explicit connection. It never creates or
/// attaches a session, authenticates a model provider, or infers model entitlement.
public actor OpenCodeMetadataConnection {
    private let client: OpenCodeHTTPClient
    private let expectedGeneration: OpenCodeGeneration?
    private let ownedProcessIdentifier: Int32?
    private var closed = false
    private var reads: [UUID: Task<OpenCodeHTTPResponse, any Error>] = [:]

    public init(client: OpenCodeHTTPClient, expectedGeneration: OpenCodeGeneration? = nil,
                ownedProcessIdentifier: Int32? = nil) {
        self.client = client; self.expectedGeneration = expectedGeneration
        self.ownedProcessIdentifier = ownedProcessIdentifier
    }

    public func identify() async throws -> OpenCodeServerIdentity {
        guard !closed else { throw OpenCodeProtocolError.closed }
        for generation in expectedGeneration.map({ [$0] }) ?? [.v2, .v1] {
            try Task.checkCancellation()
            let path = generation == .v2 ? ["api", "info"] : ["global", "health"]
            let response = try await read(path: path, maximumBytes: 65_536)
            guard !closed else { throw OpenCodeProtocolError.closed }
            if response.status == 401 || response.status == 403 { throw OpenCodeProtocolError.unauthorized }
            if response.status == 503 { throw OpenCodeProtocolError.unavailable }
            guard response.status == 200, Self.isJSON(response) else { continue }
            guard let value = try? JSONDecoder().decode(JSONValue.self, from: response.body),
                  let rawVersion = value["version"].string,
                  let version = try? OpenCodeVersion(rawVersion) else { continue }
            let pid: Int32?
            if generation == .v2 {
                guard case .number(let number) = value["pid"], number.isFinite, number > 0,
                      number.rounded(.towardZero) == number, number <= Double(Int32.max) else { continue }
                pid = Int32(number)
                if let ownedProcessIdentifier, pid != ownedProcessIdentifier { throw OpenCodeProtocolError.invalidIdentity }
            } else {
                guard value["healthy"] == .bool(true) else { continue }
                pid = nil // v1 health does not prove a native process identity.
            }
            guard let supported = version.supportedGeneration else { throw OpenCodeProtocolError.unsupportedVersion }
            guard supported == generation else { throw OpenCodeProtocolError.wrongGeneration }
            return .init(generation: generation, version: version, processIdentifier: pid)
        }
        throw OpenCodeProtocolError.invalidIdentity
    }

    public func inventory(directory: URL) async throws -> OpenCodeMetadataSnapshot {
        guard !closed else { throw OpenCodeProtocolError.closed }
        let path = directory.path
        guard directory.isFileURL, directory.host == nil || directory.host == "" || directory.host == "localhost",
              directory.user == nil, directory.password == nil, directory.query == nil, directory.fragment == nil,
              path.hasPrefix("/"), path == directory.standardizedFileURL.path, path.utf8.count <= 16_384,
              !path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            throw OpenCodeProtocolError.wrongDirectory
        }
        let before = try await identify()
        let models: [OpenCodeModelDescriptor], agents: [OpenCodeAgentDescriptor], defaults: [OpenCodeModelSelection]
        switch before.generation {
        case .v2:
            let query = [URLQueryItem(name: "location[directory]", value: path)]
            async let modelsRead = read(path: ["api", "model"], query: query, maximumBytes: 16_777_216)
            async let agentsRead = read(path: ["api", "agent"], query: query)
            async let defaultRead = read(path: ["api", "model", "default"], query: query)
            let (modelResponse, agentResponse, defaultResponse) = try await (modelsRead, agentsRead, defaultRead)
            models = try OpenCodeCatalog.v2Models(Self.json(modelResponse), directory: path)
            agents = try OpenCodeCatalog.v2Agents(Self.json(agentResponse), directory: path)
            defaults = try OpenCodeCatalog.v2Default(Self.json(defaultResponse), directory: path).map { [$0] } ?? []
        case .v1:
            let query = [URLQueryItem(name: "directory", value: path)]
            async let modelsRead = read(path: ["provider"], query: query, maximumBytes: 16_777_216)
            async let agentsRead = read(path: ["agent"], query: query)
            let (modelResponse, agentResponse) = try await (modelsRead, agentsRead)
            let decoded = try OpenCodeCatalog.v1Models(Self.json(modelResponse))
            models = decoded.models; defaults = decoded.defaults
            agents = try OpenCodeCatalog.v1Agents(Self.json(agentResponse))
        }
        let after = try await identify()
        guard before == after else { throw OpenCodeProtocolError.invalidIdentity }
        guard !closed else { throw OpenCodeProtocolError.closed }
        try Task.checkCancellation()
        return .init(server: after, directory: path, models: models, agents: agents, defaults: defaults)
    }

    public func close() async {
        closed = true
        let owned = Array(reads.values)
        for read in owned { read.cancel() }
        for read in owned { _ = try? await read.value }
    }

    // The HTTP client can also own a live event subscription. Closing this
    // metadata reader cancels only its own requests, never that shared client.
    private func read(path: [String], query: [URLQueryItem] = [], maximumBytes: Int = 4_194_304) async throws -> OpenCodeHTTPResponse {
        guard !closed else { throw OpenCodeProtocolError.closed }
        try Task.checkCancellation()
        let id = UUID(), client = client
        let task = Task { try await client.request(path: path, query: query, maximumBytes: maximumBytes) }
        reads[id] = task
        defer { reads.removeValue(forKey: id) }
        return try await withTaskCancellationHandler {
            let result = try await task.value
            try Task.checkCancellation()
            return result
        } onCancel: { task.cancel() }
    }

    private static func isJSON(_ response: OpenCodeHTTPResponse) -> Bool {
        let media = response.headers["content-type"]?.split(separator: ";", maxSplits: 1).first?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return media == "application/json" || (media?.hasPrefix("application/") == true && media?.hasSuffix("+json") == true)
    }

    private static func json(_ response: OpenCodeHTTPResponse) throws -> JSONValue {
        if response.status == 401 || response.status == 403 { throw OpenCodeProtocolError.unauthorized }
        if response.status == 503 { throw OpenCodeProtocolError.unavailable }
        guard response.status == 200, isJSON(response),
              let result = try? JSONDecoder().decode(JSONValue.self, from: response.body) else { throw OpenCodeProtocolError.invalidCatalog }
        return result
    }
}
