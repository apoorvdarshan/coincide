import Foundation
import Testing
@testable import CoincideCore

private final class AntigravityAuthTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []
    private var values: [UUID: AntigravityRuntimeCredential] = [:]
    func add(_ value: String) { lock.withLock { entries.append(value) } }
    var events: [String] { lock.withLock { entries } }
    var generations: Set<UUID> { lock.withLock { Set(values.keys) } }
    var credentials: AntigravityCredentialAccess {
        .init(read: { config in self.lock.withLock { self.entries.append("key-read"); return self.values[config.authGeneration] } },
            write: { value, config in self.lock.withLock { self.entries.append("key-write"); self.values[config.authGeneration] = value } },
            remove: { config in self.lock.withLock { self.entries.append("key-remove"); _ = self.values.removeValue(forKey: config.authGeneration) } })
    }
}
private actor AntigravityAuthPeer: AntigravityAuthenticationSession {
    let trace: AntigravityAuthTrace
    let hold: Bool
    let fail: Bool
    let handler: AntigravityAuthentication.AuthorizationHandler?
    var entered = false
    var waiter: CheckedContinuation<Void, Never>?
    init(trace: AntigravityAuthTrace, hold: Bool = false, fail: Bool = false,
         handler: AntigravityAuthentication.AuthorizationHandler? = nil) {
        self.trace = trace; self.hold = hold; self.fail = fail; self.handler = handler
    }
    func authenticate() async throws -> [ProviderModel] {
        trace.add("authenticate"); entered = true
        if let handler {
            try await handler(AntigravityAuthorizationURL("https://accounts.google.com/o/oauth2/v2/auth?response_type=code&redirect_uri=http%3A%2F%2F127.0.0.1%3A49152%2F&state=isolated-test-state"))
        }
        if hold { await withCheckedContinuation { waiter = $0 } }
        if fail { throw CoincideError("private-provider-payload-canary") }
        return [.init(id: "native-model", name: "Native model")]
    }
    func logout() async throws {
        trace.add("logout"); entered = true
        if hold { await withCheckedContinuation { waiter = $0 } }
        if fail { throw CoincideError("private-logout-canary") }
    }
    func healthCheck() async throws -> JSONValue { trace.add("health"); return .object(["initialized": .bool(true)]) }
    func close() async { trace.add("close"); waiter?.resume(); waiter = nil }
    func discardOwnedProfile() async { trace.add("discard-profile") }
}
private func waitAntigravityAuth(_ predicate: @escaping @Sendable () async -> Bool,
                                file: StaticString = #fileID, line: UInt = #line) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while !(await predicate()) {
        guard ContinuousClock.now < deadline else { throw CoincideError("Authentication fixture did not reach its expected boundary at \(file):\(line).") }
        try await Task.sleep(for: .milliseconds(5))
    }
}
private func authCoordinator(_ trace: AntigravityAuthTrace,
                             factory: @escaping AntigravityAuthentication.SessionFactory,
                             timeout: Duration = .seconds(3)) -> AntigravityAuthentication {
    AntigravityAuthentication(sessionFactory: factory, credentials: trace.credentials, timeout: timeout,
        beginLease: { _ in trace.add("lease"); return UUID() }, endLease: { _ in trace.add("release") },
        apply: { _ in trace.add("apply") })
}

@Test func antigravityAuthenticationStagesAnExactKeyAndCommitsOnlyAfterModelAccessAndDrain() async throws {
    let trace = AntigravityAuthTrace(), source = AntigravityConfiguration(authMethod: .geminiAPIKey)
    let auth = authCoordinator(trace, factory: { config, credential, handler in
        #expect(config.authGeneration != source.authGeneration && credential != nil && handler != nil)
        return AntigravityAuthPeer(trace: trace)
    })
    _ = try await auth.start(configuration: source, apiKey: "task-owned-synthetic-key")
    try await waitAntigravityAuth { await auth.state.phase == .succeeded }
    let state = await auth.state
    let saved = try #require(state.configuration)
    #expect(saved.authGeneration != source.authGeneration && state.models.map(\.id) == ["native-model"])
    #expect(trace.generations == [saved.authGeneration])
    let events = trace.events
    #expect(!events.contains("key-read") && !events.contains("discard-profile"))
    let lease = try #require(events.firstIndex(of: "lease")), write = try #require(events.firstIndex(of: "key-write"))
    let authenticate = try #require(events.firstIndex(of: "authenticate")), close = try #require(events.firstIndex(of: "close"))
    let apply = try #require(events.firstIndex(of: "apply")), release = try #require(events.firstIndex(of: "release"))
    #expect(lease < write && authenticate < close && close < apply && apply < release)
    #expect(!String(describing: state).contains("synthetic-key"))
    await auth.shutdown()
}

@Test func antigravityFailedAccessRemovesOnlyStagedCredentialAndNeverAppliesOrLeaksProviderErrors() async throws {
    let trace = AntigravityAuthTrace(), source = AntigravityConfiguration(authMethod: .geminiAPIKey)
    try trace.credentials.write(AntigravityRuntimeCredential(apiKey: "working-synthetic-key"), source)
    let auth = authCoordinator(trace, factory: { _, _, _ in AntigravityAuthPeer(trace: trace, fail: true) })
    _ = try await auth.start(configuration: source, apiKey: "staged-synthetic-key")
    try await waitAntigravityAuth { await auth.state.phase == .failed }
    #expect(trace.generations == [source.authGeneration])
    #expect(!trace.events.contains("apply") && trace.events.contains("discard-profile"))
    let state = await auth.state
    #expect(state.authorization == nil && state.models.isEmpty)
    #expect(!(state.message ?? "").contains("private-provider-payload-canary"))
    await auth.shutdown()
}

@Test func antigravityBrowserCancelAndExpiryDrainExactFlowWithoutReplacingWorkingAccount() async throws {
    for expired in [false, true] {
        let trace = AntigravityAuthTrace(), source = AntigravityConfiguration()
        let auth = authCoordinator(trace, factory: { _, _, handler in AntigravityAuthPeer(trace: trace, hold: true, handler: handler) },
                                   timeout: expired ? .milliseconds(100) : .seconds(3))
        let id = try await auth.start(configuration: source)
        try await waitAntigravityAuth { await auth.state.phase == .waitingForBrowser }
        if !expired { await auth.cancel(flowID: id) }
        try await waitAntigravityAuth { await auth.state.phase == (expired ? .expired : .cancelled) }
        let state = await auth.state
        #expect(!trace.events.contains("apply") && !trace.events.contains("key-read"))
        #expect(trace.events.contains("close") && trace.events.contains("discard-profile") && trace.events.contains("release"))
        #expect(state.authorization == nil && state.models.isEmpty)
        await auth.shutdown()
    }
}

@Test func antigravityRuntimeCheckCannotAuthenticateReadAKeyOrClaimAccess() async throws {
    let trace = AntigravityAuthTrace(), source = AntigravityConfiguration(authMethod: .geminiAPIKey)
    let auth = authCoordinator(trace, factory: { probe, key, handler in
        #expect(probe.authGeneration != source.authGeneration && probe.authMethod == .oauthPersonal)
        #expect(key == nil && handler == nil)
        return AntigravityAuthPeer(trace: trace)
    })
    _ = try await auth.checkRuntime(configuration: source)
    #expect(trace.events == ["health", "close", "discard-profile"])
    #expect(await auth.state.phase == .idle)
    await auth.shutdown()
}

@Test func antigravitySignOutUsesWorkingGenerationAndNeverRepeatsUnknownLogout() async throws {
    for fails in [false, true] {
        let trace = AntigravityAuthTrace(), source = AntigravityConfiguration(authMethod: .geminiAPIKey)
        try trace.credentials.write(AntigravityRuntimeCredential(apiKey: "working-synthetic-key"), source)
        let auth = authCoordinator(trace, factory: { current, credential, handler in
            #expect(current == source && credential != nil && handler == nil)
            return AntigravityAuthPeer(trace: trace, fail: fails)
        })
        _ = try await auth.signOut(configuration: source)
        try await waitAntigravityAuth { await auth.state.phase == (fails ? .unconfirmed : .signedOut) }
        #expect(trace.events.filter { $0 == "logout" }.count == 1 && !trace.events.contains("authenticate"))
        #expect(trace.generations == (fails ? [source.authGeneration] : []))
        #expect(trace.events.contains("apply") == !fails)
        #expect(await auth.state.models.isEmpty)
        await auth.shutdown()
    }
}

@Test func antigravityRegistryAcceptsOnlyVerifiedExactIdentityAndContainsNoSecrets() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-auth-registry-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let config = AntigravityConfiguration(authGeneration: UUID())
    for phase in [AntigravityAccountRegistry.AccessState.pending, .signedOut] {
        try AntigravityAccountRegistry.save(.init(configuration: config, accessState: phase), rootURL: root)
        #expect(throws: (any Error).self) { try AntigravityAccountRegistry.validateKnownGeneration(config, rootURL: root) }
    }
    try AntigravityAccountRegistry.save(.init(configuration: config, accessState: .verified), rootURL: root)
    try AntigravityAccountRegistry.validateKnownGeneration(config, rootURL: root)
    let other = AntigravityConfiguration(authGeneration: UUID())
    #expect(throws: (any Error).self) { try AntigravityAccountRegistry.validateKnownGeneration(other, rootURL: root) }
    let record = try #require(try AntigravityAccountRegistry.load(rootURL: root))
    #expect(record.configuration == config && record.accessState == .verified)
    let bytes = try Data(contentsOf: root.appendingPathComponent("account.json"))
    let object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    #expect(Set(object.keys) == ["configuration", "accessState", "checkedAt"])
    try FileManager.default.removeItem(at: root.appendingPathComponent("account.json"))
    let outside = root.appendingPathComponent("outside.json")
    try bytes.write(to: outside)
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("account.json"), withDestinationURL: outside)
    #expect(throws: (any Error).self) { try AntigravityAccountRegistry.load(rootURL: root) }
}

@Test func antigravityCancelledLogoutInvalidatesOnlyItsExactSourceBeforeReleasingLease() async throws {
    let trace = AntigravityAuthTrace(), source = AntigravityConfiguration()
    let peer = AntigravityAuthPeer(trace: trace, hold: true)
    let auth = AntigravityAuthentication(sessionFactory: { _, _, _ in peer }, credentials: trace.credentials,
        invalidateAccess: { config in #expect(config.runtimeIdentity == source.runtimeIdentity); trace.add("invalidate") },
        beginLease: { _ in trace.add("lease"); return UUID() }, endLease: { _ in trace.add("release") },
        apply: { _ in trace.add("apply") })
    let id = try await auth.signOut(configuration: source)
    try await waitAntigravityAuth { await peer.entered }
    await auth.cancel(flowID: id)
    #expect(await auth.state.phase == .unconfirmed)
    let events = trace.events
    let invalidated = try #require(events.firstIndex(of: "invalidate")), released = try #require(events.firstIndex(of: "release"))
    #expect(invalidated < released && !events.contains("apply"))
    #expect(events.filter { $0 == "logout" }.count == 1)
    await auth.shutdown()
}
