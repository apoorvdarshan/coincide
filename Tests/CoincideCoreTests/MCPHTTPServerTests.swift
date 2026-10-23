import Foundation
import Network
import Testing
@testable import CoincideCore

private final class MCPHTTPPeer: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "coincide.synthetic-mcp-http-peer")
    private let timer: DispatchSourceTimer
    init(_ endpoint: URL) throws {
        guard let port = endpoint.port, let port = NWEndpoint.Port(rawValue: UInt16(port)) else { throw CoincideError("Invalid synthetic MCP port") }
        connection = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        timer = DispatchSource.makeTimerSource(queue: queue)
        let connection = connection
        timer.schedule(deadline: .now() + .seconds(5)); timer.setEventHandler { connection.cancel() }; timer.resume()
        connection.start(queue: queue)
    }
    func send(_ bytes: Data) async throws {
        try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<Void, any Error>) in
            connection.send(content: bytes, completion: .contentProcessed { error in
                if error != nil { waiter.resume(throwing: CoincideError("Synthetic MCP HTTP write failed")) } else { waiter.resume() }
            })
        }
    }
    func response() async throws -> Data {
        try await withTaskCancellationHandler {
            var bytes = Data()
            while true {
                let part: (Data?, Bool) = try await withCheckedThrowingContinuation { waiter in
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, complete, error in
                        if let error {
                            if case .posix(.ECONNRESET) = error { waiter.resume(returning: (data, true)) }
                            else { waiter.resume(throwing: CoincideError("Synthetic MCP HTTP read failed")) }
                        } else { waiter.resume(returning: (data, complete)) }
                    }
                }
                if let data = part.0 { bytes.append(data) }
                guard bytes.count <= MCPProtocol.maximumBodyBytes + 16_384 else { throw CoincideError("Synthetic MCP response exceeded its limit") }
                if part.1 { return bytes }
            }
        } onCancel: { self.connection.cancel() }
    }
    func close() { timer.cancel(); connection.cancel() }
    deinit { timer.cancel(); connection.cancel() }
}
private struct MCPHTTPResponse {
    let status: Int
    let body: JSONValue?
    let raw: Data
    init(_ data: Data) throws {
        guard let end = data.range(of: Data([13, 10, 13, 10])),
              let header = String(data: data[..<end.lowerBound], encoding: .utf8),
              let status = header.split(separator: "\r\n").first?.split(separator: " ").dropFirst().first.flatMap({ Int($0) }) else { throw CoincideError("Synthetic MCP response was not HTTP") }
        self.status = status; self.raw = data
        let bytes = Data(data[end.upperBound...]); self.body = bytes.isEmpty ? nil : try MCPProtocol.decode(bytes)
    }
}
private actor MCPHTTPCalls {
    private(set) var values: [MCPInvocation] = []
    func record(_ value: MCPInvocation) -> MCPToolResult {
        values.append(value)
        return .init(content: ["native-loopback-result"], structuredContent: .object(["requestWasScoped": .bool(true)]))
    }
    func count() -> Int { values.count }
}
private actor MCPHTTPGate {
    private var entered = false, released = false, waiters: [CheckedContinuation<Void, Never>] = []
    func hold() async {
        entered = true
        if !released { await withCheckedContinuation { waiters.append($0) } }
    }
    func hasEntered() -> Bool { entered }
    func release() { released = true; let pending = waiters; waiters = []; for waiter in pending { waiter.resume() } }
}
private func httpScope(capabilities: Set<MCPCapability> = [.orchestration]) -> MCPInvocationScope {
    .init(threadID: UUID(), projectID: UUID(), provider: .pi, runtimeID: UUID(), incarnation: UUID(), providerInstanceID: UUID(),
          workspacePath: "/private/tmp/synthetic-mcp-workspace", permission: .supervised, capabilities: capabilities)
}
private let httpTools: [MCPToolDefinition] = [
    .init(name: "thread_read", description: "Read the current thread.", inputSchema: .object(["type": .string("object")]), capability: .orchestration, readOnly: true),
    .init(name: "worktree_read", description: "Read an owned worktree.", inputSchema: .object(["type": .string("object")]), capability: .worktree, readOnly: true),
]
private func httpRequest(endpoint: URL, credential: MCPSessionCredential?, value: JSONValue, version: String? = "2025-06-18", fault: String? = nil) throws -> Data {
    let body = try MCPProtocol.encode(value)
    var host = "127.0.0.1:\(endpoint.port!)", target = "/mcp", method = "POST"
    if fault == "host" { host = "localhost:\(endpoint.port!)" }
    if fault == "query" { target += "?access_token=synthetic-not-authority" }
    if fault == "method" { method = "GET" }
    var header = "\(method) \(target) HTTP/1.1\r\nHost: \(host)\r\nAccept: application/json, text/event-stream\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\n"
    if let credential { header += "Authorization: \(credential.authorizationHeader)\r\n" }
    if let version { header += "MCP-Protocol-Version: \(version)\r\n" }
    if fault == "origin" { header += "Origin: https://untrusted.invalid\r\n" }
    if fault == "duplicate" { header += "Content-Length: \(body.count)\r\n" }
    if fault == "transfer" { header += "Transfer-Encoding: chunked\r\n" }
    if fault == "accept" { header = header.replacingOccurrences(of: "application/json, text/event-stream", with: ";") }
    header += "\r\n"
    var result = Data(header.utf8); result.append(body); return result
}
private func httpExchange(_ server: MCPHTTPServer, credential: MCPSessionCredential?, value: JSONValue,
                          version: String? = "2025-06-18", fault: String? = nil) async throws -> MCPHTTPResponse {
    let peer = try MCPHTTPPeer(server.endpoint); defer { peer.close() }
    try await peer.send(httpRequest(endpoint: server.endpoint, credential: credential, value: value, version: version, fault: fault))
    let response = try await peer.response()
    return try MCPHTTPResponse(response)
}
private func httpRPC(_ method: String, id: JSONValue? = .number(1), params: JSONValue = .object([:])) -> JSONValue {
    var value: [String: JSONValue] = ["jsonrpc": .string("2.0"), "method": .string(method), "params": params]
    if let id { value["id"] = id }; return .object(value)
}
private func httpInitialize(_ server: MCPHTTPServer, credential: MCPSessionCredential, version: String = "2025-06-18") async throws {
    let initialized = try await httpExchange(server, credential: credential,
        value: httpRPC("initialize", params: .object(["protocolVersion": .string(version), "capabilities": .object([:]),
                                                     "clientInfo": .object(["name": .string("synthetic-native-provider"), "version": .string("1")])])), version: nil)
    #expect(initialized.status == 200 && initialized.body?["result"]["protocolVersion"] == .string(version))
    let ready = try await httpExchange(server, credential: credential, value: httpRPC("notifications/initialized", id: nil), version: version)
    #expect(ready.status == 202 && ready.body == nil)
}
private func httpEventually(_ predicate: @escaping @Sendable () async -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while !(await predicate()) {
        guard ContinuousClock.now < deadline else { throw CoincideError("Synthetic MCP HTTP milestone was not reached") }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@Test(arguments: ["2025-06-18", "2025-11-25"])
func mcpHTTPInitializesListsOnlyGrantedToolsAndInvokesExactOwnedScope(version: String) async throws {
    let registry = MCPSessionRegistry(), scope = httpScope(), calls = MCPHTTPCalls()
    let credential = try await registry.issue(scope: scope)
    let server = try await MCPHTTPServer.start(registry: registry, tools: httpTools) { await calls.record($0) }
    do {
        #expect(server.endpoint.host == "127.0.0.1" && server.endpoint.path == "/mcp" && server.endpoint.query == nil)
        try await httpInitialize(server, credential: credential, version: version)
        let listed = try await httpExchange(server, credential: credential, value: httpRPC("tools/list", id: .number(2)), version: version)
        #expect(listed.body?["result"]["tools"].array?.map { $0["name"].string } == ["thread_read"])
        let called = try await httpExchange(server, credential: credential,
            value: httpRPC("tools/call", id: .string("owned-call"), params: .object(["name": .string("thread_read"), "arguments": .object(["includeCompleted": .bool(true)])])), version: version)
        #expect(called.status == 200 && called.body?["id"] == .string("owned-call"))
        #expect(called.body?["result"]["content"].array?.first?["text"] == .string("native-loopback-result"))
        let invocations = await calls.values
        #expect(invocations.count == 1 && invocations.first?.scope == scope)
        #expect(invocations.first?.arguments["includeCompleted"] == .bool(true))
        let replay = try await httpExchange(server, credential: credential, value: httpRPC("tools/call", id: .string("owned-call"), params: .object(["name": .string("thread_read")])), version: version)
        #expect(replay.body?["error"]["code"] == .number(-32600))
        let hidden = try await httpExchange(server, credential: credential, value: httpRPC("tools/call", id: .number(3), params: .object(["name": .string("worktree_read")])), version: version)
        #expect(hidden.body?["error"] != .null)
        #expect(await calls.count() == 1)
        let leaked = String(decoding: called.raw + listed.raw + replay.raw + hidden.raw, as: UTF8.self).contains(credential.authorizationHeader)
        #expect(!leaked)
        await server.close()
    } catch { await server.close(); throw error }
}

@Test(arguments: ["host", "query", "origin", "duplicate", "transfer", "accept", "method", "missingCredential"])
func mcpHTTPRejectsHostileTransportWithoutDispatchOrCredentialReflection(fault: String) async throws {
    let registry = MCPSessionRegistry(), credential = try await registry.issue(scope: httpScope()), calls = MCPHTTPCalls()
    let server = try await MCPHTTPServer.start(registry: registry, tools: httpTools) { await calls.record($0) }
    do {
        let response = try await httpExchange(server, credential: fault == "missingCredential" ? nil : credential,
            value: httpRPC("ping"), fault: fault)
        let expected = fault == "origin" ? 403 : fault == "query" ? 404 : fault == "method" ? 405 : fault == "missingCredential" ? 401 : 400
        #expect(response.status == expected)
        #expect(await calls.count() == 0)
        let leaked = String(decoding: response.raw, as: UTF8.self).contains(credential.authorizationHeader)
        #expect(!leaked)
        await server.close()
    } catch { await server.close(); throw error }
}

@Test func mcpHTTPRequiresReadyVersionAndSanitizesThrownProviderFailures() async throws {
    let registry = MCPSessionRegistry(), credential = try await registry.issue(scope: httpScope())
    let privateText = UUID().uuidString
    let server = try await MCPHTTPServer.start(registry: registry, tools: httpTools) { _ in throw CoincideError(privateText) }
    do {
        let early = try await httpExchange(server, credential: credential, value: httpRPC("tools/list", id: .number(8)))
        #expect(early.body?["error"]["code"] == .number(-32000))
        try await httpInitialize(server, credential: credential)
        let wrong = try await httpExchange(server, credential: credential, value: httpRPC("tools/list", id: .number(9)), version: "2025-11-25")
        #expect(wrong.body?["error"]["code"] == .number(-32000))
        let failed = try await httpExchange(server, credential: credential, value: httpRPC("tools/call", id: .number(10), params: .object(["name": .string("thread_read")])))
        #expect(failed.body?["error"]["code"] == .number(-32603))
        let leaked = String(decoding: failed.raw, as: UTF8.self).contains(privateText)
        #expect(!leaked)
        await server.close()
    } catch { await server.close(); throw error }
}

@Test func mcpHTTPExplicitCancellationKeepsOtherCredentialAndServerHealthy() async throws {
    let registry = MCPSessionRegistry(), first = try await registry.issue(scope: httpScope()), second = try await registry.issue(scope: httpScope()), gate = MCPHTTPGate()
    let server = try await MCPHTTPServer.start(registry: registry, tools: httpTools) { invocation in
        if invocation.scope.sessionID == first.sessionID { await gate.hold(); try Task.checkCancellation() }
        return .init(content: ["healthy"])
    }
    let safety = Task { try? await Task.sleep(for: .seconds(3)); await gate.release() }
    var pending: Task<MCPHTTPResponse, any Error>?
    do {
        try await httpInitialize(server, credential: first); try await httpInitialize(server, credential: second)
        let call = Task { try await httpExchange(server, credential: first, value: httpRPC("tools/call", id: .number(20), params: .object(["name": .string("thread_read")]))) }
        pending = call
        try await httpEventually { await gate.hasEntered() }
        let cancel = try await httpExchange(server, credential: first, value: httpRPC("notifications/cancelled", id: nil, params: .object(["requestId": .number(20)])))
        #expect(cancel.status == 202)
        await gate.release()
        let cancelled = try await call.value
        #expect(cancelled.body?["error"]["code"] == .number(-32800))
        let healthy = try await httpExchange(server, credential: second, value: httpRPC("tools/call", id: .number(20), params: .object(["name": .string("thread_read")])))
        #expect(healthy.body?["result"]["content"].array?.first?["text"] == .string("healthy"))
        safety.cancel(); await safety.value; await server.close()
    } catch { await gate.release(); pending?.cancel(); _ = await pending?.result; safety.cancel(); await safety.value; await server.close(); throw error }
}

@Test func mcpHTTPCloseJoinsIdleSocketsAndCancellationResistantInvocationBeforeReturning() async throws {
    let registry = MCPSessionRegistry(), credential = try await registry.issue(scope: httpScope()), gate = MCPHTTPGate()
    let server = try await MCPHTTPServer.start(registry: registry, tools: httpTools) { _ in await gate.hold(); return .init(content: ["late"])
    }
    let idle = try MCPHTTPPeer(server.endpoint)
    let safety = Task { try? await Task.sleep(for: .seconds(3)); await gate.release() }
    var pending: Task<MCPHTTPResponse, any Error>?
    do {
        try await httpInitialize(server, credential: credential)
        try await idle.send(Data("POST /mcp HTTP/1.1\r\n".utf8))
        pending = Task { try await httpExchange(server, credential: credential, value: httpRPC("tools/call", id: .number(4), params: .object(["name": .string("thread_read")]))) }
        try await httpEventually { await gate.hasEntered() }
        let close = Task { await server.close() }
        try await httpEventually { do { _ = try await registry.authenticate(credential.authorizationHeader); return false } catch { return true } }
        let idleResponse = try await idle.response()
        #expect(idleResponse.isEmpty)
        await gate.release(); await close.value; await server.close()
        _ = await pending?.result
        safety.cancel(); await safety.value; idle.close()
    } catch { await gate.release(); pending?.cancel(); _ = await pending?.result; safety.cancel(); await safety.value; idle.close(); await server.close(); throw error }
}

@Test func mcpHTTPDisconnectDoesNotCancelAdmittedActionOrPermitAutomaticReplay() async throws {
    let registry = MCPSessionRegistry(), credential = try await registry.issue(scope: httpScope()), gate = MCPHTTPGate(), calls = MCPHTTPCalls()
    let server = try await MCPHTTPServer.start(registry: registry, tools: httpTools) { invocation in
        await gate.hold()
        try Task.checkCancellation()
        return await calls.record(invocation)
    }
    let peer = try MCPHTTPPeer(server.endpoint)
    let safety = Task { try? await Task.sleep(for: .seconds(3)); await gate.release() }
    do {
        try await httpInitialize(server, credential: credential)
        let request = httpRPC("tools/call", id: .string("lost-response"), params: .object(["name": .string("thread_read")]))
        try await peer.send(httpRequest(endpoint: server.endpoint, credential: credential, value: request))
        try await httpEventually { await gate.hasEntered() }
        peer.close()
        // An unrelated round trip proves the listener is live after losing the
        // response socket. Only an explicit notification revokes this call.
        let ping = try await httpExchange(server, credential: credential, value: httpRPC("ping", id: .number(90)))
        #expect(ping.body?["result"] == .object([:]))
        await gate.release()
        try await httpEventually { await calls.count() == 1 }
        let replay = try await httpExchange(server, credential: credential, value: request)
        #expect(replay.body?["error"]["code"] == .number(-32600))
        #expect(await calls.count() == 1)
        safety.cancel(); await safety.value; await server.close()
    } catch { peer.close(); await gate.release(); safety.cancel(); await safety.value; await server.close(); throw error }
}

@Test func mcpHTTPBoundsFramingAndRejectsBatchesBeforeToolDispatch() async throws {
    let registry = MCPSessionRegistry(), credential = try await registry.issue(scope: httpScope()), calls = MCPHTTPCalls()
    let server = try await MCPHTTPServer.start(registry: registry, tools: httpTools) { await calls.record($0) }
    let peer = try MCPHTTPPeer(server.endpoint)
    do {
        let header = "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:\(server.endpoint.port!)\r\nContent-Length: \(MCPProtocol.maximumBodyBytes + 1)\r\n\r\n"
        try await peer.send(Data(header.utf8))
        let oversized = try MCPHTTPResponse(await peer.response())
        #expect(oversized.status == 413)
        let batch = try await httpExchange(server, credential: credential, value: .array([httpRPC("ping")]))
        #expect(batch.status == 400)
        let invalidVersion = try await httpExchange(server, credential: credential, value: httpRPC("ping"), version: "unsupported")
        #expect(invalidVersion.status == 400)
        #expect(await calls.count() == 0)
        peer.close(); await server.close()
    } catch { peer.close(); await server.close(); throw error }
}
