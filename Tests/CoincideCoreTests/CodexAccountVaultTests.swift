import Darwin
import Foundation
import Testing
@testable import CoincideCore

private final class VaultMemoryStorage: CodexCredentialStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [UUID: Data] = [:]
    private var failWrite = false
    func read(instanceID: UUID) throws -> Data? { lock.withLock { records[instanceID] } }
    func write(_ data: Data, instanceID: UUID) throws {
        try lock.withLock {
            if failWrite { failWrite = false; throw CodexCredentialStorageError.unavailable }
            records[instanceID] = data
        }
    }
    func delete(instanceID: UUID) throws { _ = lock.withLock { records.removeValue(forKey: instanceID) } }
    func createIfAbsent(_ data: Data, instanceID: UUID) throws -> Bool {
        lock.withLock {
            guard records[instanceID] == nil else { return false }
            records[instanceID] = data; return true
        }
    }
    func failNextWrite() { lock.withLock { failWrite = true } }
}
private struct VaultDiscovery: CodexOAuthTransport {
    func response(for request: URLRequest, maximumBytes: Int) async throws -> CodexOAuthHTTPResponse {
        let url = try #require(request.url)
        #expect(url.absoluteString == "https://auth.openai.com/.well-known/openid-configuration")
        return .init(statusCode: 200, url: url, body: Data(#"{"issuer":"https://auth.openai.com","authorization_endpoint":"https://auth.openai.com/api/accounts/authorize","token_endpoint":"https://auth.openai.com/token","jwks_uri":"https://auth.openai.com/jwks"}"#.utf8))
    }
}
private actor VaultNetwork {
    enum Refresh { case success, lost, revoked, cancelled, discoveryFailed }
    var credential: CodexOAuthCredential
    private(set) var refreshes = 0
    private(set) var exchanges = 0
    private(set) var revocations = 0
    private var refreshMode: Refresh = .success
    private var exchangeFailure: CodexOAuthError?
    private var hold = false
    private var entered = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    init(now: Date) { credential = Self.make(now: now) }
    static func make(now: Date, clientID: String = "oaiapp_first", subject: String = "subject-first",
                     access: String = "fixture-access-first", refresh: String? = "fixture-refresh-first",
                     lifetime: TimeInterval = 3600, earliest: Date? = nil, sharing: Bool = true) -> CodexOAuthCredential {
        .init(clientID: clientID, accessToken: access, refreshToken: refresh, idToken: nil,
              issuer: URL(string: "https://auth.openai.com")!, expiresAt: now.addingTimeInterval(lifetime), earliestRefreshAt: earliest,
              scopes: sharing ? [CodexOAuthClient.requiredScope] : ["openid"],
              identity: .init(subject: subject, email: "\(subject)@example.invalid"))
    }
    func set(_ value: CodexOAuthCredential) { credential = value }
    func mode(_ value: Refresh, hold: Bool = false) { refreshMode = value; self.hold = hold; entered = false }
    func failExchange(_ error: CodexOAuthError?) { exchangeFailure = error }
    func exchange() throws -> CodexOAuthCredential { exchanges += 1; if let exchangeFailure { throw exchangeFailure }; return credential }
    func refresh(_ original: CodexOAuthCredential, now: Date) async throws -> CodexOAuthCredential {
        refreshes += 1; entered = true
        for waiter in entryWaiters { waiter.resume() }; entryWaiters = []
        if hold { await withCheckedContinuation { releaseWaiter = $0 } }
        switch refreshMode {
        case .discoveryFailed: throw CodexOAuthError(.discoveryFailed)
        case .lost: throw CodexOAuthError(.outcomeUncertain, mayHaveChangedCredentials: true)
        case .revoked: throw CodexOAuthError(.revoked)
        case .cancelled: throw CodexOAuthError(.cancelled, mayHaveChangedCredentials: true)
        case .success:
            return Self.make(now: now, clientID: original.clientID, subject: original.identity.subject,
                access: "fixture-access-rotated", refresh: "fixture-refresh-rotated", lifetime: 3600)
        }
    }
    func revoke() -> CodexOAuthRevocation { revocations += 1; return .unconfirmed }
    func waitForRefresh() async { if !entered { await withCheckedContinuation { entryWaiters.append($0) } } }
    func release() { hold = false; releaseWaiter?.resume(); releaseWaiter = nil }
}
private final class VaultFixture: Sendable {
    let root: URL
    let instanceID = UUID()
    let storage = VaultMemoryStorage()
    let network: VaultNetwork
    let client: CodexOAuthClient
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    init() throws {
        let pointer = try #require(realpath(FileManager.default.temporaryDirectory.path, nil))
        let physicalTemporary = URL(fileURLWithPath: String(cString: pointer), isDirectory: true)
        free(pointer)
        root = physicalTemporary.appendingPathComponent("coincide-vault-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        network = VaultNetwork(now: now)
        let now = self.now
        client = CodexOAuthClient(transport: VaultDiscovery(), now: { now })
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    func vault(lockTimeout: Duration = .seconds(2)) -> CodexAccountVault {
        let client = client, network = network, now = now
        return .init(instanceID: instanceID, storage: storage, lockRoot: root,
            operations: .init(callback: { try await client.callback(authorization: $0, callbackURL: $1) },
                              exchange: { _, _ in try await network.exchange() },
                              refresh: { try await network.refresh($0, now: now) }, revoke: { _ in await network.revoke() }),
            lockTimeout: lockTimeout, now: { now })
    }
    func connect(_ vault: CodexAccountVault, credential: CodexOAuthCredential? = nil, profileID: UUID? = nil) async throws -> CodexAccountOverview {
        if let credential { await network.set(credential) }
        let preparation = try await vault.prepare(profileID: profileID)
        let authorization = try await client.authorization(redirectURI: URL(string: "http://127.0.0.1:40001/auth/callback")!, hostID: UUID(),
            clientID: preparation.clientID, expectedSubject: preparation.expectedSubject)
        let params = try #require(URLComponents(url: authorization.url, resolvingAgainstBaseURL: false)?.queryItems)
        let state = try #require(params.first(where: { $0.name == "state" })?.value)
        let issued = await network.credential.clientID
        var callback = URLComponents(url: authorization.redirectURI, resolvingAgainstBaseURL: false)!
        callback.queryItems = [.init(name: "state", value: state), .init(name: "code", value: "fixture-code"), .init(name: "client_id", value: issued)]
        return try await vault.exchange(preparation: preparation, authorization: authorization, callbackURL: try #require(callback.url?.absoluteString))
    }
}

@Test func codexAccountVaultPersistsOnlyKeychainSecretsAndPublishesOpaqueBindings() async throws {
    let fixture = try VaultFixture(), vault = fixture.vault()
    let empty = try await vault.overview()
    #expect(empty.binding == nil && empty.profiles.isEmpty)
    let connected = try await fixture.connect(vault), binding = try #require(connected.binding)
    #expect(connected.profiles.count == 1 && connected.profiles[0].isActive && connected.profiles[0].sharingEnabled)
    let bytes = try JSONEncoder().encode(binding)
    #expect(!String(decoding: bytes, as: UTF8.self).contains("oaiapp_") && !String(decoding: bytes, as: UTF8.self).contains("subject-first"))
    let credential = try await vault.access(binding: binding)
    #expect(credential.clientID == "oaiapp_first")
    #expect(await fixture.network.refreshes == 0)
    for name in try FileManager.default.contentsOfDirectory(atPath: fixture.root.path) {
        #expect(try Data(contentsOf: fixture.root.appendingPathComponent(name)).isEmpty, "Filesystem receipts contain no identity or secret bytes.")
    }
    let reopened = fixture.vault()
    #expect(try await reopened.overview() == connected)
    #expect(try await reopened.access(binding: binding).clientID == credential.clientID)
}

@Test func codexAccountVaultSerializesRotationAcrossSeparateActorsAndPreservesCapturedGeneration() async throws {
    let fixture = try VaultFixture(), first = fixture.vault(), second = fixture.vault()
    let original = VaultNetwork.make(now: fixture.now, lifetime: 1)
    let connected = try await fixture.connect(first, credential: original), binding = try #require(connected.binding)
    await fixture.network.mode(.success, hold: true)
    let one = Task { try await first.access(binding: binding) }
    await fixture.network.waitForRefresh()
    let two = Task { try await second.access(binding: binding) }
    await fixture.network.release()
    let values = try await [one.value, two.value]
    #expect(values.allSatisfy { $0.accessToken == "fixture-access-rotated" && $0.refreshToken == "fixture-refresh-rotated" })
    #expect(await fixture.network.refreshes == 1, "A second actor must read the rotated Keychain item after acquiring the same process-wide lease.")
    #expect(try await first.overview().binding == binding)
    #expect(try await second.overview().binding == binding)
}

@Test(arguments: [VaultNetwork.Refresh.lost, .cancelled])
private func codexAccountVaultNeverRetriesAnUncertainRefreshAfterReopening(mode: VaultNetwork.Refresh) async throws {
    let fixture = try VaultFixture(), vault = fixture.vault()
    let connected = try await fixture.connect(vault, credential: VaultNetwork.make(now: fixture.now, lifetime: 1))
    let binding = try #require(connected.binding)
    await fixture.network.mode(mode)
    await #expect(throws: CodexAccountError.reconnectRequired) { try await vault.access(binding: binding) }
    let reopened = fixture.vault(), overview = try await reopened.overview()
    #expect(overview.binding == nil && overview.profiles[0].requiresReconnect)
    await #expect(throws: CodexAccountError.reconnectRequired) { try await reopened.access(binding: binding) }
    #expect(await fixture.network.refreshes == 1)
    let reconnected = try await fixture.connect(reopened, credential: VaultNetwork.make(now: fixture.now), profileID: binding.profileID)
    #expect(reconnected.binding?.profileID == binding.profileID && reconnected.binding?.generation != binding.generation)
    #expect(reconnected.profiles[0].requiresReconnect == false)
    await #expect(throws: CodexAccountError.staleAccount) { try await vault.access(binding: binding) }
}

@Test func codexAccountVaultFailedPublicationKeepsDurableUncertaintyInsteadOfReusingOldToken() async throws {
    let fixture = try VaultFixture(), vault = fixture.vault()
    let connected = try await fixture.connect(vault, credential: VaultNetwork.make(now: fixture.now, lifetime: 1))
    let binding = try #require(connected.binding), before = try fixture.storage.read(instanceID: fixture.instanceID)
    fixture.storage.failNextWrite()
    await #expect(throws: CodexAccountError.reconnectRequired) { try await vault.access(binding: binding) }
    #expect(try fixture.storage.read(instanceID: fixture.instanceID) == before, "An unsuccessful publication cannot be claimed as a committed rotation.")
    let reopened = fixture.vault()
    await #expect(throws: CodexAccountError.reconnectRequired) { try await reopened.access(binding: binding) }
    #expect(await fixture.network.refreshes == 1)
}

@Test func codexAccountVaultCancellationAfterAReceivedRotationStillCommitsItsExactResult() async throws {
    let fixture = try VaultFixture(), vault = fixture.vault()
    let connected = try await fixture.connect(vault, credential: VaultNetwork.make(now: fixture.now, lifetime: 1)), binding = try #require(connected.binding)
    await fixture.network.mode(.success, hold: true)
    let task = Task { try await vault.access(binding: binding) }
    await fixture.network.waitForRefresh(); task.cancel(); await fixture.network.release()
    await #expect(throws: CancellationError.self) { try await task.value }
    let reopened = fixture.vault(), result = try await reopened.access(binding: binding)
    #expect(result.accessToken == "fixture-access-rotated")
    #expect(await fixture.network.refreshes == 1)
    #expect(try await reopened.overview().binding == binding)
}

@Test func codexAccountVaultDeclinedSharingPreservesThePreviousActiveAccountAndBlocksSelection() async throws {
    let fixture = try VaultFixture(), vault = fixture.vault()
    let first = try await fixture.connect(vault), binding = try #require(first.binding)
    let declined = VaultNetwork.make(now: fixture.now, clientID: "oaiapp_second", subject: "subject-second", sharing: false)
    let second = try await fixture.connect(vault, credential: declined)
    #expect(second.binding == binding && second.profiles.count == 2)
    let other = try #require(second.profiles.first(where: { $0.id != binding.profileID }))
    #expect(!other.isActive && !other.sharingEnabled && other.hasCredential)
    await #expect(throws: CodexAccountError.sharingRequired) { try await vault.activate(profileID: other.id) }
    #expect(try await vault.access(binding: binding).clientID == "oaiapp_first")
}

@Test func codexAccountVaultRevocationAndLogoutPreserveRegistrationsOtherProfilesAndCLIData() async throws {
    let fixture = try VaultFixture(), vault = fixture.vault()
    let cli = fixture.root.appendingPathComponent("auth.json"), cliBytes = Data("fixture CLI auth remains untouched".utf8)
    try cliBytes.write(to: cli)
    let first = try await fixture.connect(vault), oldBinding = try #require(first.binding)
    let second = try await fixture.connect(vault, credential: VaultNetwork.make(now: fixture.now, clientID: "oaiapp_second", subject: "subject-second", lifetime: 1))
    let active = try #require(second.binding)
    await #expect(throws: CodexAccountError.staleAccount) { try await vault.access(binding: oldBinding) }
    await fixture.network.mode(.revoked)
    await #expect(throws: CodexAccountError.signInRequired) { try await vault.access(binding: active) }
    let afterRevoke = try await vault.overview()
    #expect(afterRevoke.profiles.count == 2 && afterRevoke.binding == nil)
    #expect(afterRevoke.profiles.first(where: { $0.id == oldBinding.profileID })?.hasCredential == true)
    let restored = try await vault.activate(profileID: oldBinding.profileID), restoredBinding = try #require(restored.binding)
    #expect(try await vault.logout(profileID: oldBinding.profileID) == .unconfirmed)
    #expect(await fixture.network.revocations == 1)
    let signedOut = try await vault.overview()
    #expect(signedOut.binding == nil && signedOut.profiles.count == 2 && signedOut.profiles.allSatisfy { !$0.hasCredential })
    #expect(try Data(contentsOf: cli) == cliBytes)
    await #expect(throws: CodexAccountError.staleAccount) { try await vault.access(binding: restoredBinding) }
}

@Test func codexAccountVaultRespectsEarliestRefreshAndRejectsExpiredTokensWithoutPosting() async throws {
    let fixture = try VaultFixture(), vault = fixture.vault()
    let valid = VaultNetwork.make(now: fixture.now, lifetime: 30, earliest: fixture.now.addingTimeInterval(120))
    let connected = try await fixture.connect(vault, credential: valid), binding = try #require(connected.binding)
    #expect(try await vault.access(binding: binding).expiresAt == valid.expiresAt)
    #expect(await fixture.network.refreshes == 0)
    let late = CodexAccountVault(instanceID: fixture.instanceID, storage: fixture.storage, lockRoot: fixture.root,
        operations: .init(callback: { _, _ in throw CodexOAuthError(.invalidCallback) }, exchange: { _, _ in throw CodexOAuthError(.invalidCallback) },
                          refresh: { _ in Issue.record("An expired earliest-refresh gate cannot post."); throw CodexOAuthError(.protocolViolation) }, revoke: { _ in .unconfirmed }),
        now: { fixture.now.addingTimeInterval(60) })
    await #expect(throws: CodexOAuthError(.refreshTooEarly)) { try await late.access(binding: binding) }
}

@Test func codexAccountVaultPreservesMalformedKeychainRecordsAndRejectsForeignLockEntries() async throws {
    let fixture = try VaultFixture(), vault = fixture.vault()
    let bytes = Data(#"{"version":1,"version":1}"#.utf8)
    try fixture.storage.write(bytes, instanceID: fixture.instanceID)
    await #expect(throws: CodexAccountError.invalidRecord) { try await vault.overview() }
    #expect(try fixture.storage.read(instanceID: fixture.instanceID) == bytes)
    let lock = fixture.root.appendingPathComponent(fixture.instanceID.uuidString.lowercased() + ".lock")
    try FileManager.default.removeItem(at: lock)
    let target = fixture.root.appendingPathComponent("foreign")
    try Data("preserve".utf8).write(to: target)
    try FileManager.default.createSymbolicLink(atPath: lock.path, withDestinationPath: target.path)
    await #expect(throws: CodexAccountError.storageUnavailable) { try await vault.overview() }
    #expect(try Data(contentsOf: target) == Data("preserve".utf8))
}

@Test func codexAccountVaultRefusesReplacedRootBeforePublishingARotatedToken() async throws {
    let fixture = try VaultFixture(), vault = fixture.vault()
    let connected = try await fixture.connect(vault, credential: VaultNetwork.make(now: fixture.now, lifetime: 1)), binding = try #require(connected.binding)
    let before = try fixture.storage.read(instanceID: fixture.instanceID)
    await fixture.network.mode(.success, hold: true)
    let task = Task { try await vault.access(binding: binding) }
    await fixture.network.waitForRefresh()
    let moved = fixture.root.appendingPathExtension("moved")
    try FileManager.default.moveItem(at: fixture.root, to: moved)
    defer { try? FileManager.default.removeItem(at: moved) }
    try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    await fixture.network.release()
    await #expect(throws: CodexAccountError.reconnectRequired) { try await task.value }
    #expect(try fixture.storage.read(instanceID: fixture.instanceID) == before)
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).isEmpty)
    #expect(try FileManager.default.contentsOfDirectory(atPath: moved.path).contains(where: { $0.hasSuffix(".uncertain") }))
    await #expect(throws: CodexAccountError.invalidRecord) { try await fixture.vault().access(binding: binding) }
    #expect(await fixture.network.refreshes == 1)
}

@Test func codexAccountVaultAllowsRetryAfterProvenPreDispatchDiscoveryFailure() async throws {
    let fixture = try VaultFixture(), vault = fixture.vault()
    let connected = try await fixture.connect(vault, credential: VaultNetwork.make(now: fixture.now, lifetime: 1)), binding = try #require(connected.binding)
    await fixture.network.mode(.discoveryFailed)
    await #expect(throws: CodexOAuthError(.discoveryFailed)) { try await vault.access(binding: binding) }
    #expect(try await vault.overview().binding == binding)
    await fixture.network.mode(.success)
    #expect(try await fixture.vault().access(binding: binding).accessToken == "fixture-access-rotated")
    #expect(await fixture.network.refreshes == 2)
}

@Test func codexAccountVaultAtomicInitialClaimRejectsSameInstanceUsingAnotherRoot() async throws {
    let fixture = try VaultFixture()
    let otherRoot = fixture.root.appendingPathComponent("other", isDirectory: true)
    let first = fixture.vault()
    let second = CodexAccountVault(instanceID: fixture.instanceID, storage: fixture.storage, lockRoot: otherRoot,
        operations: .init(callback: { _, _ in throw CodexOAuthError(.invalidCallback) },
                          exchange: { _, _ in Issue.record("A foreign root cannot exchange a token."); throw CodexOAuthError(.invalidCallback) },
                          refresh: { _ in Issue.record("A foreign root cannot refresh a token."); throw CodexOAuthError(.protocolViolation) }, revoke: { _ in .unconfirmed }), now: { fixture.now })
    let outcomes = await withTaskGroup(of: Bool.self) { group in
        group.addTask { do { _ = try await first.prepare(); return true } catch { return false } }
        group.addTask { do { _ = try await second.prepare(); return true } catch { return false } }
        var outcomes: [Bool] = []; for await value in group { outcomes.append(value) }; return outcomes
    }
    #expect(outcomes.filter { $0 }.count == 1, "Only one root can atomically claim a missing instance item; no read/write CAS is assumed.")
    #expect(await fixture.network.exchanges == 0)
    #expect(await fixture.network.refreshes == 0)
}

@Test func codexAccountVaultRetainsAnIssuedExpiredRegistrationWithoutTrustingAnIdentityOrChangingTheActiveAccount() async throws {
    let fixture = try VaultFixture(), vault = fixture.vault()
    let first = try await fixture.connect(vault), active = try #require(first.binding)
    let issued = VaultNetwork.make(now: fixture.now, clientID: "oaiapp_expired", subject: "subject-second")
    await fixture.network.failExchange(.init(.codeExpired, issuedClientID: issued.clientID))
    await #expect(throws: CodexOAuthError(.codeExpired, issuedClientID: issued.clientID)) {
        try await fixture.connect(vault, credential: issued)
    }
    let after = try await vault.overview(), pending = try #require(after.profiles.first(where: { $0.id != active.profileID }))
    #expect(after.binding == active && pending.email == nil && !pending.sharingEnabled && !pending.hasCredential && pending.requiresReconnect)
    await #expect(throws: CodexAccountError.signInRequired) { try await vault.activate(profileID: pending.id) }
    let preparation = try await vault.prepare(profileID: pending.id)
    #expect(preparation.clientID == issued.clientID && preparation.expectedSubject == nil && preparation.loginHint == nil)
    await fixture.network.failExchange(nil)
    let verified = try await fixture.connect(vault, credential: issued, profileID: pending.id)
    #expect(verified.binding?.profileID == pending.id && verified.profiles.count == 2)
    #expect(verified.profiles.first(where: { $0.id == pending.id })?.email == issued.identity.email)
}

@Test(.timeLimit(.minutes(1))) func codexAccountVaultHonorsAnIndependentProcessRotationLease() async throws {
    let fixture = try VaultFixture(), vault = fixture.vault(lockTimeout: .milliseconds(30))
    let initial = try await vault.overview()
    let lockPath = fixture.root.appendingPathComponent(fixture.instanceID.uuidString.lowercased() + ".lock").path
    let script = "import fcntl,sys\nf=open(sys.argv[1],'r+b')\nfcntl.flock(f,fcntl.LOCK_EX)\nprint('locked',flush=True)\nsys.stdin.buffer.read(1)\n"
    let process = try ProcessChannel(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-c", script, lockPath], eventBufferLimit: 8)
    do {
        var ready = false
        for await event in process.events {
            if case .stdout(let data) = event, String(decoding: data, as: UTF8.self).contains("locked") { ready = true; break }
            if case .exited = event { break }
        }
        #expect(ready)
        await #expect(throws: CodexAccountError.busy) { try await vault.overview() }
        try await process.write(Data([0x01])); _ = await process.stopAndDrain()
        #expect(try await vault.overview() == initial)
    } catch { _ = await process.stopAndDrain(); throw error }
}
