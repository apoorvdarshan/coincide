import Darwin
import Foundation
import Testing
@testable import CoincideCore

private final class AuthenticationJournal: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []
    private var held = false
    private var shouldFailApply = false
    func record(_ event: String) { lock.withLock { entries.append(event) } }
    func begin() -> UUID { lock.withLock { held = true; entries.append("begin"); return UUID() } }
    func end() { lock.withLock { entries.append("end"); held = false } }
    func requireLease(_ event: String) throws {
        try lock.withLock {
            guard held else { throw CoincideError("Synthetic account access escaped the Engine lease") }
            entries.append(event)
        }
    }
    func apply() throws {
        try requireLease("apply")
        if lock.withLock({ shouldFailApply }) { throw CoincideError("Synthetic apply failed") }
    }
    func failApply(_ value: Bool) { lock.withLock { shouldFailApply = value } }
    var events: [String] { lock.withLock { entries } }
    var leaseHeld: Bool { lock.withLock { held } }
}
private final class AuthenticationMemoryStorage: CodexCredentialStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UUID: Data] = [:]
    let journal: AuthenticationJournal
    init(_ journal: AuthenticationJournal) { self.journal = journal }
    func read(instanceID: UUID) throws -> Data? { try journal.requireLease("read"); return lock.withLock { values[instanceID] } }
    func write(_ data: Data, instanceID: UUID) throws { try journal.requireLease("write"); lock.withLock { values[instanceID] = data } }
    func createIfAbsent(_ data: Data, instanceID: UUID) throws -> Bool {
        try journal.requireLease("create")
        return lock.withLock { guard values[instanceID] == nil else { return false }; values[instanceID] = data; return true }
    }
    func delete(instanceID: UUID) throws { try journal.requireLease("delete"); _ = lock.withLock { values.removeValue(forKey: instanceID) } }
}
private struct AuthenticationDiscovery: CodexOAuthTransport {
    let journal: AuthenticationJournal
    func response(for request: URLRequest, maximumBytes: Int) async throws -> CodexOAuthHTTPResponse {
        try journal.requireLease("discovery")
        guard let url = request.url, url.path == "/.well-known/openid-configuration", request.httpBody == nil else { throw CodexOAuthError(.protocolViolation) }
        let object: JSONValue = .object(["issuer": .string("https://auth.openai.com"),
            "authorization_endpoint": .string("https://auth.openai.com/api/accounts/authorize"),
            "token_endpoint": .string("https://auth.openai.com/token"), "jwks_uri": .string("https://auth.openai.com/keys")])
        return .init(statusCode: 200, url: url, body: try JSONEncoder().encode(object))
    }
}
private actor AuthenticationListener: CodexOAuthCallbackListener {
    nonisolated let redirectURI: URL
    private let journal: AuthenticationJournal
    private var callback: String?
    private var accept: (@Sendable (String) async -> Bool)?
    private var waiter: CheckedContinuation<String, any Error>?
    private var closed = false
    init(port: Int, journal: AuthenticationJournal) { redirectURI = URL(string: "http://127.0.0.1:\(port)/auth/callback")!; self.journal = journal }
    func receive(accept: @escaping @Sendable (String) async -> Bool) async throws -> String {
        try journal.requireLease("receive")
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let result = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, any Error>) in
                if closed { continuation.resume(throwing: CancellationError()); return }
                self.accept = accept; waiter = continuation
                if callback != nil { Task { await self.deliver() } }
            }
            return result
        } onCancel: { Task { await self.close() } }
    }
    func provide(_ value: String) async { callback = value; await deliver() }
    private func deliver() async {
        guard !closed, let callback, let accept, waiter != nil else { return }
        guard await accept(callback), !closed else { return }
        let pending = waiter; waiter = nil; pending?.resume(returning: callback)
    }
    func close() {
        if !closed { journal.record("listenerClosed"); closed = true }
        let pending = waiter; waiter = nil; pending?.resume(throwing: CancellationError())
    }
    func isClosed() -> Bool { closed }
}
private actor AuthenticationListenerPool {
    private var listeners: [AuthenticationListener] = []
    private var autoCallback = true
    let journal: AuthenticationJournal
    init(_ journal: AuthenticationJournal) { self.journal = journal }
    func make() throws -> any CodexOAuthCallbackListener {
        try journal.requireLease("listener")
        let value = AuthenticationListener(port: 42_421 + listeners.count, journal: journal); listeners.append(value); return value
    }
    func enableCallback(_ value: Bool) { autoCallback = value }
    func authorize(_ authorization: CodexOAuthAuthorization, clientID: String) async throws {
        try journal.requireLease("browser")
        guard autoCallback, let current = listeners.last else { return }
        let query = URLComponents(url: authorization.authorizationURL, resolvingAgainstBaseURL: false)!.queryItems!
        let state = query.first { $0.name == "state" }!.value!
        var callback = URLComponents(url: current.redirectURI, resolvingAgainstBaseURL: false)!
        callback.queryItems = [.init(name: "state", value: state), .init(name: "client_id", value: authorization.clientID ?? clientID),
                              .init(name: "code", value: UUID().uuidString)]
        await current.provide(callback.url!.absoluteString)
    }
    func allClosed() async -> Bool { for listener in listeners { if await !listener.isClosed() { return false } }; return true }
}
private actor AuthenticationNetwork {
    var credential: CodexOAuthCredential
    private var hold = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var entered = false
    private var exchangeFailure: CodexOAuthError?
    var revocation: CodexOAuthRevocation = .confirmed
    private(set) var exchanges = 0, revocations = 0
    let now: Date
    let journal: AuthenticationJournal
    init(now: Date, journal: AuthenticationJournal) { self.now = now; self.journal = journal; credential = Self.make(now) }
    static func make(_ now: Date, sharing: Bool = true) -> CodexOAuthCredential {
        .init(clientID: "oaiapp_" + UUID().uuidString.replacingOccurrences(of: "-", with: ""), accessToken: UUID().uuidString,
            refreshToken: UUID().uuidString, idToken: nil, issuer: URL(string: "https://auth.openai.com")!,
            expiresAt: now.addingTimeInterval(3_600), earliestRefreshAt: nil, scopes: sharing ? [CodexOAuthClient.requiredScope] : ["openid"],
            identity: .init(subject: UUID().uuidString, email: "synthetic@example.invalid"))
    }
    func next(sharing: Bool = true) { credential = Self.make(now, sharing: sharing) }
    func holdExchange() { hold = true; entered = false }
    func hasEntered() -> Bool { entered }
    func failExpiredCode() { exchangeFailure = .init(.codeExpired, issuedClientID: credential.clientID) }
    func failUncertainExchange() { exchangeFailure = .init(.outcomeUncertain, mayHaveChangedCredentials: true) }
    func clearExchangeFailure() { exchangeFailure = nil }
    func release() { hold = false; let pending = waiter; waiter = nil; pending?.resume() }
    func exchange() async throws -> CodexOAuthCredential {
        try journal.requireLease("exchange"); exchanges += 1; entered = true
        if hold { await withCheckedContinuation { waiter = $0 } }
        if let exchangeFailure { throw exchangeFailure }
        return credential
    }
    func revoke() throws -> CodexOAuthRevocation { try journal.requireLease("revoke"); revocations += 1; return revocation }
    func revokeUnconfirmed() { revocation = .unconfirmed }
}
private struct AuthenticationFixture: Sendable {
    let root: URL, instanceID = UUID(), hostID = UUID()
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let journal: AuthenticationJournal
    let pool: AuthenticationListenerPool
    let network: AuthenticationNetwork
    let client: CodexOAuthClient
    let vault: CodexAccountVault
    init() throws {
        let temporary = try temporaryWorkspace()
        guard let path = realpath(temporary.path, nil) else { throw CoincideError("Synthetic lock root could not be resolved") }
        root = URL(fileURLWithPath: String(cString: path), isDirectory: true); free(path)
        let journal = AuthenticationJournal(); self.journal = journal
        pool = AuthenticationListenerPool(journal)
        let network = AuthenticationNetwork(now: Date(timeIntervalSince1970: 1_800_000_000), journal: journal); self.network = network
        let client = CodexOAuthClient(transport: AuthenticationDiscovery(journal: journal), now: { Date(timeIntervalSince1970: 1_800_000_000) })
        self.client = client
        let operations = CodexAccountOAuthOperations(callback: { try await client.callback(authorization: $0, callbackURL: $1) },
            exchange: { _, _ in try await network.exchange() }, refresh: { $0 }, revoke: { _ in try await network.revoke() })
        vault = CodexAccountVault(instanceID: instanceID, storage: AuthenticationMemoryStorage(journal),
            lockRoot: root.appendingPathComponent("locks"), operations: operations, now: { Date(timeIntervalSince1970: 1_800_000_000) })
    }
    func controller(timeout: Duration = .seconds(3)) -> CodexAuthentication {
        let pool = pool, network = network, journal = journal, instanceID = instanceID, hostID = hostID
        return CodexAuthentication(instanceID: instanceID, hostID: hostID, vault: vault, client: client,
            listenerFactory: { try await pool.make() }, authorizationHandler: { auth in
                let clientID = await network.credential.clientID; try await pool.authorize(auth, clientID: clientID)
            }, timeout: timeout,
            beginLease: { id in guard id == instanceID else { throw CodexAccountError.staleAccount }; return journal.begin() },
            endLease: { _ in journal.end() }, apply: { _ in try journal.apply() }, invalidate: { journal.record("invalidate") })
    }
}
private func authenticationWait(_ predicate: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while try await !predicate() { guard ContinuousClock.now < deadline else { throw CoincideError("Synthetic authentication boundary timed out") }; try await Task.sleep(for: .milliseconds(5)) }
}
private func withAuthentication(_ body: (AuthenticationFixture, CodexAuthentication) async throws -> Void) async throws {
    let fixture = try AuthenticationFixture(), controller = fixture.controller()
    do { try await body(fixture, controller); await fixture.network.release(); await controller.shutdown() }
    catch { await fixture.network.release(); await controller.shutdown(); try? FileManager.default.removeItem(at: fixture.root); throw error }
    try FileManager.default.removeItem(at: fixture.root)
}
private func signIn(_ controller: CodexAuthentication) async throws -> CodexAuthenticationState {
    let id = try await controller.start()
    try await authenticationWait { let state = await controller.state; return state.flowID == id && !state.phase.isWorking }
    return await controller.state
}

@Test func codexAuthenticationLeaseCoversTheEntireExplicitFlowAndCleanup() async throws {
    try await withAuthentication { fixture, controller in
        let state = try await signIn(controller)
        #expect(state.phase == .succeeded && state.overview?.binding != nil && state.authorizationURL == nil)
        #expect(await fixture.pool.allClosed())
        let events = fixture.journal.events
        #expect(events.first == "begin" && events.last == "end")
        #expect(events.firstIndex(of: "begin")! < events.firstIndex(of: "read")!)
        #expect(events.firstIndex(of: "write")! < events.firstIndex(of: "apply")!)
        #expect(events.lastIndex(of: "listenerClosed")! < events.lastIndex(of: "end")!)
        #expect(!fixture.journal.leaseHeld && !events.contains("invalidate"))
        #expect(Mirror(reflecting: state).children.isEmpty)
    }
}

@Test func codexAuthenticationCancellationKeepsPreviousAccountAndCoalescesOnlySameRequest() async throws {
    try await withAuthentication { fixture, controller in
        let first = try await signIn(controller), binding = try #require(first.overview?.binding)
        await fixture.pool.enableCallback(false); await fixture.network.next()
        let flow = try await controller.start()
        try await authenticationWait { await controller.state.phase == .waitingForBrowser }
        #expect(try await controller.start() == flow)
        await #expect(throws: CodexAccountError.busy) { try await controller.activate(profileID: binding.profileID) }
        await controller.cancel(flowID: UUID())
        #expect(await controller.state.phase == .waitingForBrowser)
        await controller.cancel(flowID: flow)
        let cancelled = await controller.state
        #expect(cancelled.phase == .cancelled && cancelled.overview?.binding == binding && cancelled.authorizationURL == nil)
        #expect(await fixture.network.exchanges == 1)
        #expect(await fixture.pool.allClosed())
        #expect(!fixture.journal.leaseHeld)
    }
}

@Test func codexAuthenticationDeclinedSharingIsExplicitAndKeepsPreviousActiveProfile() async throws {
    try await withAuthentication { fixture, controller in
        let first = try await signIn(controller), binding = try #require(first.overview?.binding)
        await fixture.network.next(sharing: false)
        let second = try await signIn(controller)
        #expect(second.phase == .sharingRequired && second.overview?.binding == binding)
        #expect(second.overview?.profiles.count == 2 && second.message?.contains("sharing") == true)
        #expect(second.overview?.profiles.contains(where: { !$0.sharingEnabled && !$0.isActive }) == true)
    }
}

@Test func codexAuthenticationApplyFailureRetainsActualPublicationAndInvalidatesAccess() async throws {
    try await withAuthentication { fixture, controller in
        fixture.journal.failApply(true)
        let state = try await signIn(controller)
        #expect(state.phase == .unconfirmed && state.overview?.binding != nil)
        #expect(fixture.journal.events.contains("write") && fixture.journal.events.contains("invalidate"))
        #expect(fixture.journal.events.last == "end" && !fixture.journal.leaseHeld)
        #expect(await fixture.network.exchanges == 1)
        #expect(await fixture.pool.allClosed())
    }
}

@Test(arguments: [true, false])
func codexAuthenticationLateCancelPublishesVerifiedCredentialWithoutFalseActivation(reconnect: Bool) async throws {
    try await withAuthentication { fixture, controller in
        let previous: CodexAccountBinding?
        if reconnect { previous = try await signIn(controller).overview?.binding } else { previous = nil }
        await fixture.network.holdExchange()
        let flow = try await controller.start(profileID: previous?.profileID)
        try await authenticationWait { await fixture.network.hasEntered() }
        let cancellation = Task { await controller.cancel(flowID: flow) }
        try await authenticationWait { await controller.state.phase == .cancelling }
        #expect(fixture.journal.leaseHeld)
        await fixture.network.release(); await cancellation.value
        let state = await controller.state
        #expect(state.phase == .cancelled && state.overview?.profiles.last?.hasCredential == true)
        if let previous {
            #expect(state.overview?.binding?.profileID == previous.profileID && state.overview?.binding?.generation != previous.generation)
        } else { #expect(state.overview?.binding == nil) }
        #expect(fixture.journal.events.contains("apply") && !fixture.journal.events.contains("invalidate"))
        #expect(!fixture.journal.leaseHeld && state.authorizationURL == nil)
    }
}

@Test func codexAuthenticationActivationAndUnknownRevocationPreserveOtherProfiles() async throws {
    try await withAuthentication { fixture, controller in
        let first = try await signIn(controller), binding = try #require(first.overview?.binding)
        await fixture.network.next()
        let second = try await signIn(controller), other = try #require(second.overview?.binding)
        let activated = try await controller.activate(profileID: binding.profileID)
        try await authenticationWait { let state = await controller.state; return state.flowID == activated && !state.phase.isWorking }
        let active = await controller.state
        #expect(active.phase == .succeeded && active.overview?.binding?.profileID == binding.profileID)
        await fixture.network.revokeUnconfirmed()
        let signOut = try await controller.signOut(profileID: binding.profileID)
        try await authenticationWait { let state = await controller.state; return state.flowID == signOut && !state.phase.isWorking }
        let state = await controller.state
        #expect(state.phase == .signedOut && state.overview?.binding == nil && state.message?.contains("locally") == true)
        #expect(state.overview?.profiles.first(where: { $0.id == binding.profileID })?.hasCredential == false)
        #expect(state.overview?.profiles.first(where: { $0.id == other.profileID })?.hasCredential == true)
        #expect(await fixture.network.revocations == 1)
    }
}

@Test func codexAuthenticationDeadlineAndShutdownJoinCallbackBeforeEndingLease() async throws {
    let fixture = try AuthenticationFixture(), controller = fixture.controller(timeout: .seconds(1))
    do {
        await fixture.pool.enableCallback(false)
        let flow = try await controller.start()
        try await authenticationWait { await controller.state.phase == .waitingForBrowser }
        try await authenticationWait { let state = await controller.state; return state.flowID == flow && !state.phase.isWorking }
        #expect(await controller.state.phase == .expired)
        #expect(await fixture.pool.allClosed())
        #expect(fixture.journal.events.last == "end" && !fixture.journal.leaseHeld)
        await controller.shutdown()
        await #expect(throws: CodexAccountError.busy) { try await controller.start() }
    } catch { await fixture.network.release(); await controller.shutdown(); try? FileManager.default.removeItem(at: fixture.root); throw error }
    try FileManager.default.removeItem(at: fixture.root)
}

@Test(arguments: [true, false])
func codexAuthenticationExpiredInitialCodeKeepsAReconnectRegistrationWithoutFalseUncertainty(previousAccount: Bool) async throws {
    try await withAuthentication { fixture, controller in
        let binding: CodexAccountBinding?
        if previousAccount {
            binding = try await signIn(controller).overview?.binding
            await fixture.network.next()
        } else { binding = nil }
        let previousApplyCount = fixture.journal.events.filter { $0 == "apply" }.count
        await fixture.network.failExpiredCode()
        let expired = try await signIn(controller)
        #expect(expired.phase == .expired && expired.overview?.binding == binding)
        #expect(expired.message?.contains("Reconnect") == true && expired.authorizationURL == nil)
        let pending = try #require(expired.overview?.profiles.first(where: { !$0.hasCredential }))
        #expect(!pending.isActive && !pending.sharingEnabled && pending.requiresReconnect && pending.email == nil)
        #expect(!fixture.journal.events.contains("invalidate"))
        #expect(fixture.journal.events.filter { $0 == "apply" }.count == previousApplyCount)
        #expect(!fixture.journal.leaseHeld && fixture.journal.events.last == "end")
        await fixture.network.clearExchangeFailure()
        let flow = try await controller.start(profileID: pending.id)
        try await authenticationWait { let state = await controller.state; return state.flowID == flow && !state.phase.isWorking }
        let reconnected = await controller.state
        #expect(reconnected.phase == .succeeded && reconnected.overview?.binding?.profileID == pending.id)
        #expect(reconnected.overview?.profiles.first(where: { $0.id == pending.id })?.hasCredential == true)
        #expect(await fixture.pool.allClosed())
    }
}

@Test func codexAuthenticationUncertainExistingCredentialStillInvalidatesAccess() async throws {
    try await withAuthentication { fixture, controller in
        let first = try await signIn(controller), binding = try #require(first.overview?.binding)
        await fixture.network.failUncertainExchange()
        let flow = try await controller.start(profileID: binding.profileID)
        try await authenticationWait { let state = await controller.state; return state.flowID == flow && !state.phase.isWorking }
        let unknown = await controller.state
        #expect(unknown.phase == .unconfirmed && unknown.overview?.binding == nil)
        #expect(unknown.overview?.profiles.first(where: { $0.id == binding.profileID })?.requiresReconnect == true)
        #expect(fixture.journal.events.contains("invalidate") && fixture.journal.events.last == "end")
        #expect(!fixture.journal.leaseHeld)
    }
}
