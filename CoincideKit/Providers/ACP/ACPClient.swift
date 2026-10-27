import Foundation

/// Typed Agent Client Protocol calls over a JSON-RPC connection, plus the client-side methods
/// agents call back into (permissions, files, terminals). It speaks ACP v1 and adapts the
/// handful of methods that differ when an agent answers `initialize` with the v2 preview shape.
@MainActor
public final class ACPClient {
    public let connection: ACPConnection
    public private(set) var agent: ACPInitializeResult?

    /// Serves `fs/*` requests when set.
    public var fileSystem: ACPFileSystem?
    /// Serves `terminal/*` requests when set.
    public var terminals: ACPTerminals?
    public var onSessionUpdate: ((ACPSessionNotification) -> Void)?
    /// Answer through `respondToPermission(_:optionID:)`.
    public var onPermissionRequest: ((ACPPermissionRequest, ACPConnection.IncomingRequest) -> Void)?
    /// Vendor extension requests. Return true when handled; others get "method not found".
    public var onExtensionRequest: ((ACPConnection.IncomingRequest) -> Bool)?
    public var onExtensionNotification: ((_ method: String, _ params: JSONValue) -> Void)?

    /// v2 prompts finish with an idle state update; v1 prompts finish with their response.
    private struct PendingPrompt {
        var completion: (Result<ACPPromptResult, Error>) -> Void
        var acknowledged = false
        var idle: ACPPromptResult?
    }

    private var pendingPrompts: [String: PendingPrompt] = [:]

    public init(connection: ACPConnection) {
        self.connection = connection
        connection.onRequest = { [weak self] in self?.handle($0) }
        connection.onNotification = { [weak self] in self?.handleNotification($0, $1) }
    }

    private var isV2: Bool { agent?.generation == 2 }

    // MARK: Agent methods

    public func initialize(
        capabilities: ACPClientCapabilities, clientInfo: JSONValue, meta: JSONValue? = nil, timeout: TimeInterval? = nil
    ) async throws -> ACPInitializeResult {
        var params: [String: JSONValue] = [
            "protocolVersion": 1, "clientCapabilities": capabilities.json, "clientInfo": clientInfo,
        ]
        if let meta { params["_meta"] = meta }
        let result = ACPInitializeResult(json: try await connection.request("initialize", params: .object(params), timeout: timeout))
        agent = result
        return result
    }

    public func authenticate(methodID: String, timeout: TimeInterval? = nil) async throws {
        _ = try await connection.request(isV2 ? "auth/login" : "authenticate", params: ["methodId": .string(methodID)], timeout: timeout)
    }

    public func newSession(cwd: URL, meta: JSONValue? = nil, timeout: TimeInterval? = nil) async throws -> ACPSessionSetup {
        var params: [String: JSONValue] = ["cwd": .string(cwd.path), "mcpServers": []]
        if let meta { params["_meta"] = meta }
        let setup = ACPSessionSetup(json: try await connection.request("session/new", params: .object(params), timeout: timeout))
        guard setup.sessionID?.isEmpty == false else { throw AgentError.protocolError("session/new returned no session id") }
        return setup
    }

    /// `session/load`, which replays the conversation as `session/update` notifications before it
    /// returns. `onResponse` runs as the response is read, before later notifications. On v2 this is
    /// `session/resume` without replay.
    public func loadSession(
        id: String, cwd: URL, timeout: TimeInterval? = nil, onResponse: (() -> Void)? = nil
    ) async throws -> ACPSessionSetup {
        let method = isV2 ? "session/resume" : "session/load"
        let params: JSONValue = ["sessionId": .string(id), "cwd": .string(cwd.path), "mcpServers": []]
        let result = try await withCheckedThrowingContinuation { continuation in
            connection.send(method, params: params, timeout: timeout) { result in
                onResponse?()
                continuation.resume(with: result)
            }
        }
        return ACPSessionSetup(json: result)
    }

    /// `session/resume`: reopens a session without replaying its history.
    public func resumeSession(id: String, cwd: URL, timeout: TimeInterval? = nil) async throws -> ACPSessionSetup {
        let params: JSONValue = ["sessionId": .string(id), "cwd": .string(cwd.path), "mcpServers": []]
        return ACPSessionSetup(json: try await connection.request("session/resume", params: params, timeout: timeout))
    }

    /// Sends `session/prompt`. `completion` runs once the agent ends the turn.
    @discardableResult
    public func prompt(
        sessionID: String, blocks: [ACPContentBlock], meta: JSONValue? = nil,
        completion: @escaping (Result<ACPPromptResult, Error>) -> Void
    ) -> Int {
        var params: [String: JSONValue] = ["sessionId": .string(sessionID), "prompt": .array(blocks.map(\.json))]
        if let meta { params["_meta"] = meta }
        guard isV2 else {
            return connection.send("session/prompt", params: .object(params)) { result in
                completion(result.map(ACPPromptResult.init(json:)))
            }
        }
        pendingPrompts[sessionID] = PendingPrompt(completion: completion)
        return connection.send("session/prompt", params: .object(params)) { [weak self] result in
            guard let self, var pending = self.pendingPrompts[sessionID] else { return }
            switch result {
            case .failure(let error):
                self.pendingPrompts[sessionID] = nil
                pending.completion(.failure(error))
            case .success:
                pending.acknowledged = true
                if let idle = pending.idle {
                    self.pendingPrompts[sessionID] = nil
                    pending.completion(.success(idle))
                } else {
                    self.pendingPrompts[sessionID] = pending
                }
            }
        }
    }

    public func cancel(sessionID: String, meta: JSONValue? = nil) {
        var params: [String: JSONValue] = ["sessionId": .string(sessionID)]
        if let meta { params["_meta"] = meta }
        connection.notify("session/cancel", params: .object(params))
    }

    /// `session/set_mode`, for agents that list modes without a mode config option (v1 only).
    public func setMode(sessionID: String, modeID: String, timeout: TimeInterval? = nil) async throws {
        _ = try await connection.request(
            "session/set_mode", params: ["sessionId": .string(sessionID), "modeId": .string(modeID)], timeout: timeout)
    }

    /// The unstable v1 `session/set_model`, which Grok still uses (with `_meta.reasoningEffort`).
    public func setModel(sessionID: String, modelID: String, meta: JSONValue? = nil, timeout: TimeInterval? = nil) async throws {
        var params: [String: JSONValue] = ["sessionId": .string(sessionID), "modelId": .string(modelID)]
        if let meta { params["_meta"] = meta }
        _ = try await connection.request("session/set_model", params: .object(params), timeout: timeout)
    }

    /// Returns the complete option list when the agent sends it back.
    public func setConfigOption(
        sessionID: String, configID: String, value: String, timeout: TimeInterval? = nil
    ) async throws -> [ACPConfigOption]? {
        var params: [String: JSONValue] = [
            "sessionId": .string(sessionID), "configId": .string(configID), "value": .string(value),
        ]
        if isV2 { params["type"] = "id" }
        let result = try await connection.request("session/set_config_option", params: .object(params), timeout: timeout)
        return result["configOptions"]?.array?.compactMap(ACPConfigOption.init(json:))
    }

    /// Answers a permission request with one of its options, or with `cancelled` when `optionID` is nil.
    public func respondToPermission(_ request: ACPConnection.IncomingRequest, optionID: String?) {
        let outcome: JSONValue = optionID.map { ["outcome": "selected", "optionId": .string($0)] } ?? ["outcome": "cancelled"]
        connection.respond(to: request, result: ["outcome": outcome])
    }

    // MARK: Client methods

    private func handle(_ request: ACPConnection.IncomingRequest) {
        switch request.method {
        case "session/request_permission":
            guard let parsed = ACPPermissionRequest(params: request.params, requestID: request.id.displayText),
                let onPermissionRequest
            else {
                respondToPermission(request, optionID: nil)
                return
            }
            onPermissionRequest(parsed, request)
        case "fs/read_text_file":
            answer(request) { try Self.require(fileSystem, request).readTextFile(request.params) }
        case "fs/write_text_file":
            answer(request) { try Self.require(fileSystem, request).writeTextFile(request.params) }
        case "terminal/create":
            answer(request) { try Self.require(terminals, request).create(request.params) }
        case "terminal/output":
            answer(request) { try Self.require(terminals, request).output(request.params) }
        case "terminal/kill":
            answer(request) { try Self.require(terminals, request).kill(request.params) }
        case "terminal/release":
            answer(request) { try Self.require(terminals, request).release(request.params) }
        case "terminal/wait_for_exit":
            guard let terminals else {
                connection.respond(to: request, error: .methodNotFound(request.method))
                return
            }
            Task { [connection] in
                do {
                    connection.respond(to: request, result: try await terminals.waitForExit(request.params))
                } catch {
                    connection.respond(to: request, error: Self.acpError(error))
                }
            }
        default:
            if onExtensionRequest?(request) != true {
                connection.respond(to: request, error: .methodNotFound(request.method))
            }
        }
    }

    private func handleNotification(_ method: String, _ params: JSONValue) {
        guard method == "session/update" else {
            onExtensionNotification?(method, params)
            return
        }
        guard let notification = ACPSessionNotification(params: params) else { return }
        onSessionUpdate?(notification)
        if isV2, case .idle(let stopReason, let error) = notification.update,
            var pending = pendingPrompts[notification.sessionID]
        {
            if let error {
                pendingPrompts[notification.sessionID] = nil
                pending.completion(.failure(error))
                return
            }
            let result = ACPPromptResult(stopReason: stopReason ?? "end_turn")
            if pending.acknowledged {
                pendingPrompts[notification.sessionID] = nil
                pending.completion(.success(result))
            } else {
                pending.idle = result
                pendingPrompts[notification.sessionID] = pending
            }
        }
    }

    private func answer(_ request: ACPConnection.IncomingRequest, _ body: () throws -> JSONValue) {
        do {
            connection.respond(to: request, result: try body())
        } catch {
            connection.respond(to: request, error: Self.acpError(error))
        }
    }

    private nonisolated static func require<T>(_ handler: T?, _ request: ACPConnection.IncomingRequest) throws -> T {
        guard let handler else { throw ACPError.methodNotFound(request.method) }
        return handler
    }

    private nonisolated static func acpError(_ error: Error) -> ACPError {
        error as? ACPError ?? .internalError(error.localizedDescription)
    }
}
