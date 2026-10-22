import Foundation
import Network
import Testing
@testable import CoincideCore

private final class OAuthLoopbackHTTPPeer: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "coincide.synthetic-oauth-http-peer")
    init(_ redirect: URL) throws {
        guard let port = redirect.port, let endpointPort = NWEndpoint.Port(rawValue: UInt16(port)) else { throw CoincideError("Invalid synthetic port") }
        connection = NWConnection(host: "127.0.0.1", port: endpointPort, using: .tcp)
        connection.start(queue: queue)
    }
    func send(_ text: String) async throws {
        try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<Void, any Error>) in
            connection.send(content: Data(text.utf8), completion: .contentProcessed { error in
                if error != nil { waiter.resume(throwing: CoincideError("Synthetic HTTP write failed")) } else { waiter.resume() }
            })
        }
    }
    func response() async throws -> String {
        var bytes = Data()
        while true {
            let part: (Data?, Bool) = try await withCheckedThrowingContinuation { waiter in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 4_096) { data, _, complete, error in
                    if let error {
                        if case .posix(.ECONNRESET) = error { waiter.resume(returning: (data, true)) }
                        else { waiter.resume(throwing: CoincideError("Synthetic HTTP read failed")) }
                    } else { waiter.resume(returning: (data, complete)) }
                }
            }
            if let chunk = part.0 { bytes.append(chunk) }
            guard bytes.count <= 16_384 else { throw CoincideError("Synthetic HTTP response exceeded limit") }
            if part.1 { return String(decoding: bytes, as: UTF8.self) }
        }
    }
    func close() { connection.cancel() }
    deinit { connection.cancel() }
}
private func loopbackRequest(_ listener: CodexOAuthLoopback, query: String = "state=accepted", fault: String? = nil) -> String {
    let host = "127.0.0.1:\(listener.redirectURI.port!)"
    var method = "GET", target = "/auth/callback?" + query, headers = "Host: \(host)\r\n"
    switch fault {
    case "host": headers = "Host: localhost:\(listener.redirectURI.port!)\r\n"
    case "port": headers = "Host: 127.0.0.1:1\r\n"
    case "duplicateHost": headers += "Host: \(host)\r\n"
    case "method": method = "POST"
    case "encodedPath": target = "/auth/%63allback?" + query
    case "fragment": target += "#fragment"
    case "absolute": target = listener.redirectURI.absoluteString + "?" + query
    case "body": headers += "Content-Length: 1\r\n"
    case "transfer": headers += "Transfer-Encoding: chunked\r\n"
    default: break
    }
    return "\(method) \(target) HTTP/1.1\r\n\(headers)\r\n"
}
private func loopbackHTTP(_ listener: CodexOAuthLoopback, request: String) async throws -> String {
    let peer = try OAuthLoopbackHTTPPeer(listener.redirectURI)
    defer { peer.close() }
    try await peer.send(request)
    return try await peer.response()
}

@Test(arguments: ["host", "port", "duplicateHost", "method", "encodedPath", "fragment", "absolute", "body", "transfer"])
func codexOAuthLoopbackRejectsUntrustedHTTPWithoutConsumingFlow(fault: String) async throws {
    let listener = try await CodexOAuthLoopback.start(timeout: .seconds(5))
    let expected = listener.redirectURI.absoluteString + "?state=accepted"
    let receive = Task { try await listener.receive { $0 == expected } }
    do {
        #expect(listener.redirectURI.host == "127.0.0.1" && listener.redirectURI.port != nil)
        let rejected = try await loopbackHTTP(listener, request: loopbackRequest(listener, fault: fault))
        #expect(rejected.hasPrefix("HTTP/1.1 400") && !rejected.contains(expected))
        let accepted = try await loopbackHTTP(listener, request: loopbackRequest(listener))
        #expect(accepted.hasPrefix("HTTP/1.1 200") && accepted.contains("Cache-Control: no-store"))
        let observed = try await receive.value
        #expect(observed == expected)
        await listener.close()
    } catch { receive.cancel(); await listener.close(); _ = await receive.result; throw error }
}

@Test func codexOAuthLoopbackValidatesStateBeforeSingleUseAndDoesNotReflectCallback() async throws {
    let listener = try await CodexOAuthLoopback.start(timeout: .seconds(5)), code = UUID().uuidString
    let query = "state=accepted&code=" + code, expected = listener.redirectURI.absoluteString + "?" + query
    let receive = Task { try await listener.receive { $0 == expected } }
    do {
        let bad = try await loopbackHTTP(listener, request: loopbackRequest(listener, query: "state=foreign&code=" + code))
        #expect(bad.hasPrefix("HTTP/1.1 400") && !bad.contains(code))
        let good = try await loopbackHTTP(listener, request: loopbackRequest(listener, query: query))
        #expect(good.hasPrefix("HTTP/1.1 200") && !good.contains(code))
        let callback = try await receive.value
        #expect(callback == expected)
        await #expect(throws: CodexOAuthError.self) { _ = try await listener.receive { _ in true } }
        await listener.close()
    } catch { receive.cancel(); await listener.close(); _ = await receive.result; throw error }
}

@Test func codexOAuthLoopbackBoundsRequestAndContinuesLegitimateFlow() async throws {
    let listener = try await CodexOAuthLoopback.start(timeout: .seconds(5))
    let receive = Task { try await listener.receive { $0.hasSuffix("?state=accepted") } }
    do {
        let tooLarge = loopbackRequest(listener, query: "state=" + String(repeating: "x", count: 16_384))
        let rejected = try await loopbackHTTP(listener, request: tooLarge)
        #expect(rejected.hasPrefix("HTTP/1.1 400"))
        let accepted = try await loopbackHTTP(listener, request: loopbackRequest(listener))
        #expect(accepted.hasPrefix("HTTP/1.1 200"))
        _ = try await receive.value
        await listener.close()
    } catch { receive.cancel(); await listener.close(); _ = await receive.result; throw error }
}

@Test(arguments: [true, false])
func codexOAuthLoopbackCancellationOrDeadlineJoinsSlowConnection(cancel: Bool) async throws {
    let listener = try await CodexOAuthLoopback.start(timeout: cancel ? .seconds(5) : .milliseconds(100))
    let receive = Task { try await listener.receive { _ in false } }
    let slow = try OAuthLoopbackHTTPPeer(listener.redirectURI)
    do {
        try await slow.send("GET /auth/callback?state=incomplete HTTP/1.1\r\n")
        if cancel { receive.cancel() }
        do { _ = try await receive.value; Issue.record("An incomplete callback completed sign-in") }
        catch let error as CodexOAuthError { #expect(error.kind == (cancel ? .cancelled : .expired)) }
        await listener.close(); await listener.close()
        // close() has joined the accepted descriptor; an incomplete request
        // cannot retain a reader, socket, or delayed callback after it returns.
        let response = try await slow.response()
        #expect(response.isEmpty)
        slow.close()
    } catch { slow.close(); receive.cancel(); await listener.close(); _ = await receive.result; throw error }
}

@Test func codexOAuthLoopbackUnusedListenerAlsoExpiresAndRejectsLaterReceive() async throws {
    let listener = try await CodexOAuthLoopback.start(timeout: .milliseconds(40))
    try await Task.sleep(for: .milliseconds(80))
    await #expect(throws: CodexOAuthError.self) { _ = try await listener.receive { _ in true } }
    await listener.close()
}

@Test func codexOAuthLoopbackUsesLiveFlowValidationWithoutConsumingTheCode() async throws {
    let listener = try await CodexOAuthLoopback.start(timeout: .seconds(5))
    let clock = CodexOAuthTestClock(), peer = try CodexOAuthPeer(clock: clock)
    let client = CodexOAuthClient(transport: peer, now: { clock.now() })
    let auth = try await client.authorization(redirectURI: listener.redirectURI, hostID: UUID())
    await peer.setAuthorization(auth)
    let state = URLComponents(url: auth.authorizationURL, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "state" }!.value!
    let query = "state=\(state)&client_id=oaiapp_fixture&code=\(UUID().uuidString)"
    let receive = Task { try await listener.receive { await client.validates(callbackURL: $0, authorization: auth) } }
    do {
        let invalid = try await loopbackHTTP(listener, request: loopbackRequest(listener, query: "state=foreign&client_id=oaiapp_fixture&code=untrusted"))
        #expect(invalid.hasPrefix("HTTP/1.1 400"))
        let accepted = try await loopbackHTTP(listener, request: loopbackRequest(listener, query: query))
        #expect(accepted.hasPrefix("HTTP/1.1 200"))
        let callbackURL = try await receive.value
        let validated = try await client.callback(authorization: auth, callbackURL: callbackURL)
        #expect(validated.clientID == "oaiapp_fixture" && !validated.declined)
        let credential = try await client.exchange(authorization: auth, callbackURL: callbackURL)
        #expect(credential.permitsDirectUse)
        let stillValid = await client.validates(callbackURL: callbackURL, authorization: auth)
        #expect(!stillValid)
        await listener.close()
    } catch { receive.cancel(); await listener.close(); _ = await receive.result; throw error }
}
