import CryptoKit
import Foundation
import Testing
@testable import CoincideCore

final class CodexOAuthTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_800_000_000)
    func now() -> Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value = value.addingTimeInterval(seconds) } }
}
actor CodexOAuthPeer: CodexOAuthTransport {
    enum Fault: Sendable, Equatable { case none, discoveryForeign, discoveryRedirect, oversized, lost, malformed, revoked, invalidClient, codeExpired, noRotation, badIdentity }
    let key: CodexOAuthTestKey
    let clock: CodexOAuthTestClock
    let access = UUID().uuidString, refresh = UUID().uuidString
    var fault: Fault = .none
    var nonce = ""
    var challenge = ""
    var sharing = true
    var delayJWKS = false
    var tokenCalls = 0, revocationCalls = 0
    var revokeStatuses = [200]
    var requests: [URLRequest] = []
    var held = false
    var waiting: CheckedContinuation<Void, any Error>?
    var entered = false
    private(set) var checkedVerifier = false
    init(clock: CodexOAuthTestClock) throws { self.clock = clock; key = try .init(.ec) }
    func configure(fault: Fault = .none, sharing: Bool = true, hold: Bool = false, delayJWKS: Bool = false) {
        self.fault = fault; self.sharing = sharing; self.held = hold; self.delayJWKS = delayJWKS
    }
    func setAuthorization(_ value: CodexOAuthAuthorization) {
        let items = URLComponents(url: value.authorizationURL, resolvingAgainstBaseURL: false)!.queryItems!
        nonce = items.first { $0.name == "nonce" }!.value!
        challenge = items.first { $0.name == "code_challenge" }!.value!
    }
    func setRevokeStatuses(_ values: [Int]) { revokeStatuses = values }
    func response(for request: URLRequest, maximumBytes: Int) async throws -> CodexOAuthHTTPResponse {
        requests.append(request)
        let url = request.url!
        if url.path.contains("openid-configuration") {
            if fault == .discoveryRedirect { return .init(statusCode: 200, url: URL(string: "https://foreign.invalid/config")!, body: Data()) }
            var values = discovery
            if fault == .discoveryForeign { values["token_endpoint"] = .string("https://foreign.invalid/token") }
            return try response(url, .object(values))
        }
        if url.path == "/keys" {
            if delayJWKS { clock.advance(20) }
            return .init(statusCode: 200, url: url, body: try key.jwks)
        }
        if url.path == "/revoke" {
            revocationCalls += 1
            let status = revokeStatuses.isEmpty ? 200 : revokeStatuses.removeFirst()
            return .init(statusCode: status, url: url, body: Data())
        }
        guard url.path == "/token" else { throw CoincideError("Unexpected synthetic OAuth route") }
        tokenCalls += 1
        let form = Self.form(request.httpBody ?? Data())
        if form["grant_type"] == "authorization_code", let verifier = form["code_verifier"] {
            checkedVerifier = CodexOAuthParsing.base64url(Data(SHA256.hash(data: Data(verifier.utf8)))) == challenge
        }
        if held {
            entered = true
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try await withCheckedThrowingContinuation { waiting = $0 }
            } onCancel: { Task { await self.release(cancelled: true) } }
        }
        switch fault {
        case .lost: throw CoincideError("Synthetic transport lost its reply")
        case .oversized: return .init(statusCode: 200, url: url, body: Data(repeating: 65, count: maximumBytes + 1))
        case .malformed: return .init(statusCode: 200, url: url, body: Data("not-json".utf8))
        case .revoked: return try response(url, .object(["error": .string("refresh_token_reused")]), status: 400)
        case .invalidClient: return try response(url, .object(["error": .string("invalid_client")]), status: 400)
        case .codeExpired: return try response(url, .object(["error": .string("invalid_grant")]), status: 400)
        default: break
        }
        let clientID = form["client_id"] ?? "oaiapp_fixture"
        var claims = codexOAuthTestClaims(now: clock.now(), nonce: nonce)
        claims["aud"] = .string(clientID)
        if fault == .badIdentity { claims["nonce"] = .string("wrong") }
        var token: [String: JSONValue] = ["access_token": .string(access), "token_type": .string("Bearer"), "expires_in": .number(120),
            "scope": .string(sharing ? "openid chatgpt.tokens.use.direct" : "openid"),
            "earliest_refresh_at": .number(clock.now().timeIntervalSince1970 + 10)]
        if fault != .noRotation { token["refresh_token"] = .string(refresh) }
        if form["grant_type"] == "authorization_code" { token["id_token"] = .string(try key.token(claims: claims)) }
        return try response(url, .object(token))
    }
    func release(cancelled: Bool = false) {
        held = false; let current = waiting; waiting = nil
        if cancelled { current?.resume(throwing: CancellationError()) } else { current?.resume() }
    }
    func allRequests() -> [URLRequest] { requests }
    func mutationCounts() -> (Int, Int) { (tokenCalls, revocationCalls) }
    func hasEntered() -> Bool { entered }
    private var discovery: [String: JSONValue] {
        ["issuer": .string("https://auth.openai.com"), "authorization_endpoint": .string("https://auth.openai.com/api/accounts/authorize"),
         "token_endpoint": .string("https://auth.openai.com/token"), "jwks_uri": .string("https://auth.openai.com/keys"),
         "revocation_endpoint": .string("https://auth.openai.com/revoke")]
    }
    private func response(_ url: URL, _ value: JSONValue, status: Int = 200) throws -> CodexOAuthHTTPResponse {
        .init(statusCode: status, url: url, body: try JSONEncoder().encode(value))
    }
    static func form(_ data: Data) -> [String: String] {
        URLComponents(string: "https://synthetic.invalid/?" + String(decoding: data, as: UTF8.self))!.queryItems!.reduce(into: [:]) { $0[$1.name] = $1.value }
    }
}

private func oauthCallback(_ authorization: CodexOAuthAuthorization, clientID: String? = "oaiapp_fixture", duplicateState: Bool = false) -> String {
    let state = URLComponents(url: authorization.authorizationURL, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "state" }!.value!
    var result = URLComponents(url: authorization.redirectURI, resolvingAgainstBaseURL: false)!
    result.queryItems = [.init(name: "state", value: state), .init(name: "code", value: UUID().uuidString)]
    if let clientID { result.queryItems!.append(.init(name: "client_id", value: clientID)) }
    if duplicateState { result.queryItems!.append(.init(name: "state", value: state)) }
    return result.url!.absoluteString
}
private func oauthCredential(_ clock: CodexOAuthTestClock, expires: TimeInterval, earliest: TimeInterval? = nil) -> CodexOAuthCredential {
    .init(clientID: "oaiapp_fixture", accessToken: UUID().uuidString, refreshToken: UUID().uuidString, idToken: nil,
        issuer: URL(string: "https://auth.openai.com")!, expiresAt: clock.now().addingTimeInterval(expires),
        earliestRefreshAt: earliest.map { clock.now().addingTimeInterval($0) }, scopes: [CodexOAuthClient.requiredScope],
        identity: .init(subject: "synthetic-subject", email: nil))
}
private func oauthWait(_ condition: @escaping () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while await !condition() {
        guard ContinuousClock.now < deadline else { throw CoincideError("Synthetic OAuth gate timed out") }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@Test(arguments: [true, false])
func codexOAuthAuthorizationExchangesOneUsePKCEAndPreservesSharingDecision(sharing: Bool) async throws {
    let clock = CodexOAuthTestClock(), peer = try CodexOAuthPeer(clock: clock), client = CodexOAuthClient(transport: peer, now: { clock.now() })
    await peer.configure(sharing: sharing, delayJWKS: true)
    let first = try await client.authorization(redirectURI: URL(string: "http://127.0.0.1:42421/auth/callback")!, hostID: UUID())
    let second = try await client.authorization(redirectURI: first.redirectURI, hostID: UUID())
    let firstQuery = URLComponents(url: first.authorizationURL, resolvingAgainstBaseURL: false)!.queryItems!
    let secondQuery = URLComponents(url: second.authorizationURL, resolvingAgainstBaseURL: false)!.queryItems!
    #expect(firstQuery.first { $0.name == "client_id" }?.value == "dynamic_agent_client")
    #expect(firstQuery.first { $0.name == "state" }?.value != secondQuery.first { $0.name == "state" }?.value)
    #expect(firstQuery.first { $0.name == "nonce" }?.value != secondQuery.first { $0.name == "nonce" }?.value)
    #expect(firstQuery.allSatisfy { $0.name != "id_token_hint" })
    await peer.setAuthorization(first)
    let receivedAt = clock.now()
    let credential = try await client.exchange(authorization: first, callbackURL: oauthCallback(first))
    #expect(await peer.checkedVerifier)
    #expect(credential.permitsDirectUse == sharing && credential.clientID == "oaiapp_fixture")
    #expect(credential.expiresAt == receivedAt.addingTimeInterval(120), "JWKS latency must not extend token expiry")
    #expect(credential.identity.subject == "synthetic-subject")
    #expect(!String(reflecting: credential).contains(credential.accessToken) && Mirror(reflecting: credential).children.isEmpty)
    #expect(!String(reflecting: first).contains(first.authorizationURL.absoluteString) && Mirror(reflecting: first).children.isEmpty)
    do { _ = try await client.exchange(authorization: first, callbackURL: oauthCallback(first)); Issue.record("One-use code was replayed") }
    catch let error as CodexOAuthError { #expect(error.kind == .invalidCallback) }
    let requests = await peer.allRequests()
    #expect(requests.filter { $0.url?.path == "/token" }.count == 1)
    #expect(requests.allSatisfy { $0.url?.query == nil && $0.url?.user == nil && $0.url?.password == nil })
    let token = try #require(requests.first { $0.url?.path == "/token" })
    #expect(token.httpMethod == "POST" && token.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
    #expect(CodexOAuthPeer.form(token.httpBody!)["resource"] == CodexOAuthClient.resource)
}

@Test(arguments: ["duplicate", "foreign", "wrongClient", "encodedPath", "cancelled", "expired"])
func codexOAuthInvalidCallbackCannotExchangeOrReplaceAnAccount(fault: String) async throws {
    let clock = CodexOAuthTestClock(), peer = try CodexOAuthPeer(clock: clock), client = CodexOAuthClient(transport: peer, now: { clock.now() })
    let auth = try await client.authorization(redirectURI: URL(string: "http://127.0.0.1:42421/auth/callback")!, hostID: UUID(),
        clientID: "oaiapp_fixture", expectedSubject: "synthetic-subject", requiresConsent: true)
    await peer.setAuthorization(auth)
    var callback = oauthCallback(auth, clientID: fault == "wrongClient" ? "oaiapp_other" : nil, duplicateState: fault == "duplicate")
    if fault == "foreign" { callback = callback.replacingOccurrences(of: "127.0.0.1", with: "foreign.invalid") }
    if fault == "encodedPath" { callback = callback.replacingOccurrences(of: "/auth/callback", with: "/auth/%63allback") }
    if fault == "cancelled" { await client.cancel(auth) }
    if fault == "expired" { clock.advance(301) }
    do { _ = try await client.exchange(authorization: auth, callbackURL: callback); Issue.record("Invalid callback was accepted") }
    catch let error as CodexOAuthError { #expect(error.kind == (fault == "expired" ? .expired : .invalidCallback)) }
    let counts = await peer.mutationCounts(); #expect(counts.0 == 0)
    if ["duplicate", "foreign", "wrongClient", "encodedPath"].contains(fault) {
        _ = try await client.exchange(authorization: auth, callbackURL: oauthCallback(auth, clientID: nil))
        let finalCounts = await peer.mutationCounts(); #expect(finalCounts.0 == 1, "A malformed callback must not consume the actual flow")
    }
}

@Test(arguments: [CodexOAuthPeer.Fault.discoveryForeign, .discoveryRedirect])
func codexOAuthDiscoveryRejectsCredentialRedirection(fault: CodexOAuthPeer.Fault) async throws {
    let clock = CodexOAuthTestClock(), peer = try CodexOAuthPeer(clock: clock), client = CodexOAuthClient(transport: peer)
    await peer.configure(fault: fault)
    do { _ = try await client.discovery(); Issue.record("Untrusted discovery was accepted") }
    catch let error as CodexOAuthError { #expect(error.kind == .discoveryFailed) }
    let requests = await peer.allRequests(); #expect(requests.count == 1 && requests.allSatisfy { $0.httpBody == nil })
}

@Test(arguments: [CodexOAuthPeer.Fault.lost, .malformed, .oversized, .noRotation, .revoked, .invalidClient])
func codexOAuthRefreshClassifiesLostOrRejectedRotationWithoutRetry(fault: CodexOAuthPeer.Fault) async throws {
    let clock = CodexOAuthTestClock(), peer = try CodexOAuthPeer(clock: clock), client = CodexOAuthClient(transport: peer, now: { clock.now() })
    await peer.configure(fault: fault)
    do { _ = try await client.refresh(oauthCredential(clock, expires: -1)); Issue.record("Invalid renewal was accepted") }
    catch let error as CodexOAuthError {
        if fault == .revoked { #expect(error.kind == .revoked && !error.mayHaveChangedCredentials) }
        else if fault == .invalidClient { #expect(error.kind == .invalidClient && !error.mayHaveChangedCredentials) }
        else { #expect(error.kind == .outcomeUncertain && error.mayHaveChangedCredentials) }
    }
    let counts = await peer.mutationCounts(); #expect(counts.0 == 1)
}

@Test func codexOAuthRefreshRespectsEarliestTimeAndRotatesOnce() async throws {
    let clock = CodexOAuthTestClock(), peer = try CodexOAuthPeer(clock: clock), client = CodexOAuthClient(transport: peer, now: { clock.now() })
    let valid = oauthCredential(clock, expires: 120), tooEarly = oauthCredential(clock, expires: 20, earliest: 40)
    let preserved = try await client.refresh(valid), early = try await client.refresh(tooEarly)
    #expect(preserved === valid && early === tooEarly)
    do { _ = try await client.refresh(oauthCredential(clock, expires: -1, earliest: 40)); Issue.record("Renewed before allowed time") }
    catch let error as CodexOAuthError { #expect(error.kind == .refreshTooEarly) }
    let before = await peer.mutationCounts(); #expect(before.0 == 0)
    let rotated = try await client.refresh(oauthCredential(clock, expires: -1))
    #expect(rotated.permitsDirectUse && rotated.identity.subject == "synthetic-subject")
    let after = await peer.mutationCounts(); #expect(after.0 == 1)
}

@Test func codexOAuthCancelledExchangeIsUncertainAndCannotReplayCode() async throws {
    let clock = CodexOAuthTestClock(), peer = try CodexOAuthPeer(clock: clock), client = CodexOAuthClient(transport: peer, now: { clock.now() })
    let auth = try await client.authorization(redirectURI: URL(string: "http://127.0.0.1:42421/auth/callback")!, hostID: UUID())
    await peer.setAuthorization(auth); await peer.configure(hold: true)
    let task = Task { try await client.exchange(authorization: auth, callbackURL: oauthCallback(auth)) }
    do {
        try await oauthWait { await peer.hasEntered() }
        task.cancel()
        do { _ = try await task.value; Issue.record("Cancelled exchange succeeded") }
        catch let error as CodexOAuthError { #expect(error.kind == .cancelled && error.mayHaveChangedCredentials) }
        do { _ = try await client.exchange(authorization: auth, callbackURL: oauthCallback(auth)); Issue.record("Cancelled code was replayed") }
        catch let error as CodexOAuthError { #expect(error.kind == .invalidCallback) }
        let counts = await peer.mutationCounts(); #expect(counts.0 == 1)
    } catch { task.cancel(); await peer.release(cancelled: true); _ = await task.result; throw error }
}

@Test(arguments: [true, false])
func codexOAuthRevokeReportsConfirmedVersusUnknownWithoutCredentialURL(confirmed: Bool) async throws {
    let clock = CodexOAuthTestClock(), peer = try CodexOAuthPeer(clock: clock), client = CodexOAuthClient(transport: peer, now: { clock.now() })
    await peer.setRevokeStatuses(confirmed ? [500, 200] : [400])
    let result = try await client.revoke(oauthCredential(clock, expires: 100))
    #expect(result == (confirmed ? .confirmed : .unconfirmed))
    let requests = await peer.allRequests(), calls = requests.filter { $0.url?.path == "/revoke" }
    #expect(calls.count == (confirmed ? 2 : 1))
    #expect(calls.allSatisfy { $0.url?.query == nil && $0.httpMethod == "POST" && $0.timeoutInterval == 10 })
}

@Test func codexOAuthInitialExpiryRetainsOnlyIssuedRegistrationAndIdentityFailureIsSafe() async throws {
    let clock = CodexOAuthTestClock(), peer = try CodexOAuthPeer(clock: clock), client = CodexOAuthClient(transport: peer, now: { clock.now() })
    let uri = URL(string: "http://127.0.0.1:42421/auth/callback")!
    let auth = try await client.authorization(redirectURI: uri, hostID: UUID())
    await peer.configure(fault: .codeExpired)
    do { _ = try await client.exchange(authorization: auth, callbackURL: oauthCallback(auth)); Issue.record("Expired code accepted") }
    catch let error as CodexOAuthError { #expect(error.kind == .codeExpired && error.issuedClientID == "oaiapp_fixture") }
    let next = try await client.authorization(redirectURI: uri, hostID: UUID())
    await peer.setAuthorization(next); await peer.configure(fault: .badIdentity)
    do { _ = try await client.exchange(authorization: next, callbackURL: oauthCallback(next)); Issue.record("Foreign identity accepted") }
    catch let error as CodexOAuthError { #expect(error.kind == .identityInvalid && error.mayHaveChangedCredentials) }
}
