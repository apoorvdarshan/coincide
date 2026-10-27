import Foundation

/// A failed request to the OpenCode server: its `{"_tag", "message"}` error body, or a transport failure.
struct OpenCodeAPIError: LocalizedError, Sendable {
    var status: Int?
    var tag: String?
    var message: String

    nonisolated var errorDescription: String? { message }
    nonisolated var isSessionNotFound: Bool { tag == "SessionNotFoundError" }
    /// The permission or form no longer waits for an answer.
    nonisolated var isSettled: Bool { status == 404 || status == 409 }
    /// The server did not answer, or is not ready yet.
    nonisolated var isTransient: Bool { status == nil || status == 503 }

    nonisolated init(status: Int?, tag: String?, message: String) {
        self.status = status
        self.tag = tag
        self.message = message
    }

    /// Builds the error from a non-2xx response.
    nonisolated init(status: Int, body: Data) {
        let json = JSONValue.parse(body)
        let tag = json?["_tag"]?.string
        let message = json?["message"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.init(
            status: status, tag: tag,
            message: message.flatMap { $0.isEmpty ? nil : $0 }
                ?? String(localized: "The OpenCode server returned HTTP \(status)."))
    }
}

/// A model reference in OpenCode's `provider/model` form, with an optional reasoning variant.
struct OpenCodeModelRef: Hashable, Sendable {
    var providerID: String
    var modelID: String
    var variant: String?

    nonisolated init(providerID: String, modelID: String, variant: String? = nil) {
        self.providerID = providerID
        self.modelID = modelID
        self.variant = variant
    }

    /// Parses a Coincide selection; nil when its id is not `provider/model` (for example "default").
    nonisolated init?(selection: ModelSelection) {
        let trimmed = selection.modelID.trimmingCharacters(in: .whitespaces)
        guard let slash = trimmed.firstIndex(of: "/"), slash != trimmed.startIndex,
            trimmed.index(after: slash) != trimmed.endIndex
        else { return nil }
        let effort = selection.effort?.trimmingCharacters(in: .whitespaces)
        self.init(
            providerID: String(trimmed[..<slash]), modelID: String(trimmed[trimmed.index(after: slash)...]),
            variant: effort.flatMap { $0.isEmpty ? nil : $0 })
    }

    nonisolated init?(json: JSONValue?) {
        guard let providerID = json?["providerID"]?.string, let modelID = json?["id"]?.string else { return nil }
        self.init(providerID: providerID, modelID: modelID, variant: json?["variant"]?.string)
    }

    nonisolated var slug: String { "\(providerID)/\(modelID)" }

    nonisolated var json: JSONValue {
        var object: [String: JSONValue] = ["providerID": .string(providerID), "id": .string(modelID)]
        if let variant { object["variant"] = .string(variant) }
        return .object(object)
    }

    /// OpenCode reports the unset variant as "default".
    nonisolated func isSameModel(as other: OpenCodeModelRef?) -> Bool {
        guard let other else { return false }
        return providerID == other.providerID && modelID == other.modelID
            && (variant ?? "default") == (other.variant ?? "default")
    }
}

/// Talks to one `opencode serve` process over its v2 HTTP API.
struct OpenCodeAPI: Sendable {
    /// OpenCode 2 accepts only HTTP Basic auth, always with this user name.
    nonisolated static let username = "opencode"

    let baseURL: URL
    let authorization: String
    let urlSession: URLSession

    nonisolated init(baseURL: URL, password: String, urlSession: URLSession) {
        self.baseURL = baseURL
        self.authorization = Self.authorization(password: password)
        self.urlSession = urlSession
    }

    /// UTF-8 Basic credentials, as the OpenCode server expects them.
    nonisolated static func authorization(password: String) -> String {
        "Basic " + Data("\(username):\(password)".utf8).base64EncodedString()
    }

    /// A session for talking to a local server: no proxies, caches or cookies.
    nonisolated static func makeURLSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30
        return URLSession(configuration: configuration)
    }

    /// Builds a request for `path` (e.g. "/api/session") with query items in OpenCode's bracket form.
    nonisolated func urlRequest(
        _ method: String, _ path: String, query: [(String, String)] = [], body: JSONValue? = nil,
        timeout: TimeInterval = 30
    ) -> URLRequest {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) ?? URLComponents()
        var basePath = components.percentEncodedPath
        while basePath.hasSuffix("/") { basePath.removeLast() }
        components.percentEncodedPath = basePath + path
        if !query.isEmpty {
            components.percentEncodedQuery = query.map { "\(Self.encodeQuery($0.0))=\(Self.encodeQuery($0.1))" }
                .joined(separator: "&")
        }
        var request = URLRequest(url: components.url ?? baseURL, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(body.compactJSON.utf8)
        }
        return request
    }

    /// Sends a request and returns its JSON body (nil for 204 No Content).
    @discardableResult
    nonisolated func send(
        _ method: String, _ path: String, query: [(String, String)] = [], body: JSONValue? = nil,
        timeout: TimeInterval = 30
    ) async throws -> JSONValue? {
        let request = urlRequest(method, path, query: query, body: body, timeout: timeout)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw OpenCodeAPIError(
                status: nil, tag: nil, message: String(localized: "The OpenCode server did not answer in time."))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw OpenCodeAPIError(
                status: nil, tag: nil,
                message: String(localized: "Could not reach the OpenCode server: \(error.localizedDescription)"))
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw OpenCodeAPIError(status: status, body: data) }
        guard !data.isEmpty else { return nil }
        guard let json = JSONValue.parse(data) else {
            throw OpenCodeAPIError(
                status: status, tag: nil,
                message: String(localized: "The OpenCode server sent a response Coincide could not read."))
        }
        return json
    }

    /// Escapes an id for use as a path segment. OpenCode's ids never need it, but one read from disk might.
    nonisolated static func segment(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/")))
            ?? value
    }

    nonisolated static func location(_ directory: String) -> [(String, String)] {
        [("location[directory]", directory)]
    }

    private nonisolated static let queryAllowed: CharacterSet = {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?#[]")
        return allowed
    }()

    private nonisolated static func encodeQuery(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: queryAllowed) ?? value
    }
}

// MARK: Endpoints

extension OpenCodeAPI {
    nonisolated func serverVersion(timeout: TimeInterval = 5) async throws -> String {
        let info = try await send("GET", "/api/info", timeout: timeout)
        guard let version = info?["version"]?.string, info?["pid"]?.number != nil else {
            throw OpenCodeAPIError(status: nil, tag: nil, message: String(localized: "The server is not an OpenCode 2 server."))
        }
        return version
    }

    nonisolated func models(directory: String, timeout: TimeInterval = 10) async throws -> [JSONValue] {
        try await send("GET", "/api/model", query: Self.location(directory), timeout: timeout)?["data"]?.array ?? []
    }

    nonisolated func providers(directory: String, timeout: TimeInterval = 5) async throws -> [JSONValue] {
        try await send("GET", "/api/provider", query: Self.location(directory), timeout: timeout)?["data"]?.array ?? []
    }

    nonisolated func integrations(directory: String, timeout: TimeInterval = 5) async throws -> [JSONValue] {
        try await send("GET", "/api/integration", query: Self.location(directory), timeout: timeout)?["data"]?.array ?? []
    }

    nonisolated func agents(directory: String, timeout: TimeInterval = 5) async throws -> [JSONValue] {
        try await send("GET", "/api/agent", query: Self.location(directory), timeout: timeout)?["data"]?.array ?? []
    }

    nonisolated func createSession(
        directory: String, model: OpenCodeModelRef?, agent: String, permissions: [OpenCodeRule]
    ) async throws -> JSONValue {
        var body: [String: JSONValue] = [
            "location": ["directory": .string(directory)],
            "agent": .string(agent),
            "permissions": .array(permissions.map(\.json)),
        ]
        if let model { body["model"] = model.json }
        guard let session = try await send("POST", "/api/session", body: .object(body))?["data"],
            session["id"]?.string != nil
        else {
            throw OpenCodeAPIError(
                status: nil, tag: nil, message: String(localized: "OpenCode did not return the new session."))
        }
        return session
    }

    nonisolated func session(_ id: String) async throws -> JSONValue {
        guard let session = try await send("GET", "/api/session/\(Self.segment(id))")?["data"] else {
            throw OpenCodeAPIError(
                status: 404, tag: "SessionNotFoundError", message: String(localized: "Session not found: \(id)"))
        }
        return session
    }

    nonisolated func deleteSession(_ id: String) async throws {
        try await send("DELETE", "/api/session/\(Self.segment(id))")
    }

    nonisolated func updateSession(_ id: String, permissions: [OpenCodeRule]? = nil, title: String? = nil) async throws {
        var body: [String: JSONValue] = [:]
        if let permissions { body["permissions"] = .array(permissions.map(\.json)) }
        if let title { body["title"] = .string(title) }
        try await send("PATCH", "/api/session/\(Self.segment(id))", body: .object(body))
    }

    nonisolated func moveSession(_ id: String, directory: String) async throws {
        try await send("POST", "/api/session/\(Self.segment(id))/move", body: ["directory": .string(directory)])
    }

    nonisolated func switchAgent(_ id: String, agent: String) async throws {
        try await send("POST", "/api/session/\(Self.segment(id))/agent", body: ["agent": .string(agent)])
    }

    nonisolated func switchModel(_ id: String, model: OpenCodeModelRef) async throws {
        try await send("POST", "/api/session/\(Self.segment(id))/model", body: ["model": model.json])
    }

    /// Admits a user message; the agent loop runs it and reports progress on the event stream.
    nonisolated func prompt(_ id: String, messageID: String, text: String, files: [JSONValue]) async throws {
        var body: [String: JSONValue] = ["id": .string(messageID), "text": .string(text)]
        if !files.isEmpty { body["files"] = .array(files) }
        try await send("POST", "/api/session/\(Self.segment(id))/prompt", body: .object(body))
    }

    /// Stops the running execution. Returns false when nothing was running.
    nonisolated func interrupt(_ id: String, timeout: TimeInterval = 10) async throws -> Bool {
        try await send("POST", "/api/session/\(Self.segment(id))/interrupt", timeout: timeout)?["interrupted"]?.bool ?? false
    }

    /// Withdraws a message that has not been delivered yet.
    nonisolated func cancelInbox(_ id: String, inboxID: String, timeout: TimeInterval = 30) async throws {
        try await send("DELETE", "/api/session/\(Self.segment(id))/inbox/\(Self.segment(inboxID))", timeout: timeout)
    }

    nonisolated func activeSessions(timeout: TimeInterval = 5) async throws -> Set<String> {
        let active = try await send("GET", "/api/session/active", timeout: timeout)?["data"]?.object ?? [:]
        return Set(active.keys)
    }

    nonisolated func messages(_ id: String, newestFirst: Bool, limit: Int) async throws -> [JSONValue] {
        let query = [("order", newestFirst ? "desc" : "asc"), ("limit", String(limit))]
        return try await send("GET", "/api/session/\(Self.segment(id))/message", query: query)?["data"]?.array ?? []
    }

    nonisolated func pendingPermissions(_ id: String) async throws -> [JSONValue] {
        try await send("GET", "/api/session/\(Self.segment(id))/permission")?["data"]?.array ?? []
    }

    /// `decision` is "once", "always" or "reject". A rejection with a message lets the turn continue;
    /// without one it stops the turn.
    nonisolated func replyPermission(sessionID: String, requestID: String, decision: String, message: String? = nil)
        async throws
    {
        var body: [String: JSONValue] = ["decision": .string(decision)]
        if let message { body["message"] = .string(message) }
        let path = "/api/session/\(Self.segment(sessionID))/permission/\(Self.segment(requestID))/reply"
        try await send("POST", path, body: .object(body))
    }

    /// Adds a note the agent reads at its next step, without starting a new turn.
    nonisolated func steer(_ id: String, text: String) async throws {
        try await send(
            "POST", "/api/session/\(Self.segment(id))/synthetic",
            body: ["text": .string(text), "delivery": "steer", "resume": false])
    }

    nonisolated func pendingForms(_ id: String) async throws -> [JSONValue] {
        try await send("GET", "/api/session/\(Self.segment(id))/form")?["data"]?.array ?? []
    }

    nonisolated func replyForm(sessionID: String, formID: String, answer: [String: JSONValue]) async throws {
        let path = "/api/session/\(Self.segment(sessionID))/form/\(Self.segment(formID))/reply"
        try await send("POST", path, body: ["answer": .object(answer)])
    }

    /// Cancels a question. With a message the agent continues without the answer.
    nonisolated func cancelForm(sessionID: String, formID: String, message: String?) async throws {
        let path = "/api/session/\(Self.segment(sessionID))/form/\(Self.segment(formID))"
        try await send("DELETE", path, query: message.map { [("message", $0)] } ?? [])
    }

    /// Output a shell command printed since `cursor` (a byte offset), and the next cursor.
    nonisolated func shellOutput(
        _ shellID: String, directory: String, cursor: Int
    ) async throws -> (output: String, cursor: Int) {
        let query = Self.location(directory) + [("cursor", String(cursor))]
        let data = try await send("GET", "/api/shell/\(Self.segment(shellID))/output", query: query, timeout: 5)?["data"]
        return (data?["output"]?.string ?? "", data?["cursor"]?.int ?? cursor)
    }
}
