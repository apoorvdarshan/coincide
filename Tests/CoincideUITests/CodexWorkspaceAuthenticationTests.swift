import Darwin
import Foundation
import Testing
@testable import Coincide
@testable import CoincideCore

private final class WorkspaceCodexMemoryCredentials: CodexCredentialStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [UUID: Data] = [:]
    private var calls = 0
    var count: Int { lock.withLock { calls } }
    func read(instanceID: UUID) -> Data? { lock.withLock { calls += 1; return records[instanceID] } }
    func write(_ data: Data, instanceID: UUID) { lock.withLock { calls += 1; records[instanceID] = data } }
    func delete(instanceID: UUID) { _ = lock.withLock { calls += 1; return records.removeValue(forKey: instanceID) } }
    func createIfAbsent(_ data: Data, instanceID: UUID) -> Bool {
        lock.withLock { calls += 1; guard records[instanceID] == nil else { return false }; records[instanceID] = data; return true }
    }
}
private actor WorkspaceCodexTransport: CodexOAuthTransport {
    private(set) var paths: [String] = []
    func response(for request: URLRequest, maximumBytes: Int) throws -> CodexOAuthHTTPResponse {
        let url = try #require(request.url)
        guard url.host == "auth.openai.com", url.query == nil else { throw CodexOAuthError(.protocolViolation) }
        paths.append(url.path)
        let discovery = JSONValue.object(["issuer": .string("https://auth.openai.com"),
            "authorization_endpoint": .string("https://auth.openai.com/api/accounts/authorize"),
            "token_endpoint": .string("https://auth.openai.com/token"), "jwks_uri": .string("https://auth.openai.com/keys"),
            "revocation_endpoint": .string("https://auth.openai.com/revoke")])
        switch url.path {
        case "/.well-known/openid-configuration":
            return .init(statusCode: 200, url: url, body: try JSONEncoder().encode(discovery))
        case "/revoke": return .init(statusCode: 200, url: url, body: Data())
        case "/token":
            // A valid callback can still fail before an identity is verified.
            // No synthetic successful JWT exchange is claimed by these tests.
            return .init(statusCode: 400, url: url, body: Data(#"{"error":"invalid_grant"}"#.utf8))
        default: throw CodexOAuthError(.protocolViolation)
        }
    }
}
private actor WorkspaceCodexCloseGate {
    private(set) var entered = false
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async { entered = true; if !released { await withCheckedContinuation { waiters.append($0) } } }
    func release() { released = true; let owned = waiters; waiters = []; owned.forEach { $0.resume() } }
}
private actor WorkspaceCodexListener: CodexOAuthCallbackListener {
    nonisolated let redirectURI: URL
    private let closeGate: WorkspaceCodexCloseGate?
    private var accept: (@Sendable (String) async -> Bool)?
    private var buffered: String?
    private var waiter: CheckedContinuation<String, any Error>?
    private var closed = false
    private var closeTask: Task<Void, Never>?
    init(port: Int, closeGate: WorkspaceCodexCloseGate?) {
        redirectURI = URL(string: "http://127.0.0.1:\(port)/auth/callback")!; self.closeGate = closeGate
    }
    func receive(accept: @escaping @Sendable (String) async -> Bool) async throws -> String {
        self.accept = accept
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                guard !closed else { continuation.resume(throwing: CancellationError()); return }
                waiter = continuation
                if buffered != nil { Task { await self.deliver() } }
            }
        } onCancel: { Task { await self.close() } }
    }
    func provide(_ callback: String) async { buffered = callback; await deliver() }
    private func deliver() async {
        guard !closed, let buffered, let accept, waiter != nil, await accept(buffered), !closed else { return }
        let pending = waiter; waiter = nil; pending?.resume(returning: buffered)
    }
    func close() async {
        if let closeTask { await closeTask.value; return }
        let task = Task { [self] in
            await closeGate?.wait(); closed = true
            let pending = waiter; waiter = nil; pending?.resume(throwing: CancellationError())
        }
        closeTask = task; await task.value
    }
    func isClosed() -> Bool { closed }
}
private actor WorkspaceCodexCallbacks {
    private(set) var authorizations = 0
    private(set) var listeners: [WorkspaceCodexListener] = []
    private var mode = "hold"
    private let closeGate: WorkspaceCodexCloseGate?
    init(closeGate: WorkspaceCodexCloseGate? = nil) { self.closeGate = closeGate }
    func configure(_ mode: String) { self.mode = mode }
    func make() -> any CodexOAuthCallbackListener {
        let listener = WorkspaceCodexListener(port: 43_211 + listeners.count, closeGate: closeGate)
        listeners.append(listener); return listener
    }
    func authorize(_ authorization: CodexOAuthAuthorization) async throws {
        authorizations += 1
        guard mode != "hold", let listener = listeners.last else { return }
        let items = try #require(URLComponents(url: authorization.authorizationURL, resolvingAgainstBaseURL: false)?.queryItems)
        let state = try #require(items.first(where: { $0.name == "state" })?.value)
        var callback = try #require(URLComponents(url: authorization.redirectURI, resolvingAgainstBaseURL: false))
        callback.queryItems = [.init(name: "state", value: state)]
        if mode == "decline" { callback.queryItems?.append(.init(name: "error", value: "access_denied")) }
        else {
            callback.queryItems?.append(.init(name: "client_id", value: authorization.clientID ?? "oaiapp_offline_new"))
            callback.queryItems?.append(.init(name: "code", value: "offline-expired-code"))
        }
        await listener.provide(try #require(callback.url?.absoluteString))
    }
    func allClosed() async -> Bool {
        for listener in listeners { if !(await listener.isClosed()) { return false } }; return true
    }
}
private final class WorkspaceCodexProviderAudit: @unchecked Sendable {
    private let lock = NSLock()
    private var countValue = 0
    var count: Int { lock.withLock { countValue } }
    func unexpected() throws -> any ProviderSession {
        lock.withLock { countValue += 1 }
        throw CoincideError("Authentication tests must not start a provider.")
    }
}

@MainActor private final class WorkspaceCodexAuthFixture {
    let root: URL, database: URL, project: WorkspaceProject, legacy: CodingThread
    let storage: WorkspaceCodexMemoryCredentials
    let transport: WorkspaceCodexTransport
    let callbacks: WorkspaceCodexCallbacks
    let providers = WorkspaceCodexProviderAudit()
    let client: CodexOAuthClient
    let broker: CodexOwnedRuntimeBroker
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let lockRoot: URL
    init(closeGate: WorkspaceCodexCloseGate? = nil) throws {
        let storage = WorkspaceCodexMemoryCredentials(), transport = WorkspaceCodexTransport()
        self.storage = storage; self.transport = transport
        let pointer = try #require(realpath(FileManager.default.temporaryDirectory.path, nil))
        let temporary = URL(fileURLWithPath: String(cString: pointer), isDirectory: true); free(pointer)
        let root = temporary.appendingPathComponent("coincide-workspace-codex-auth-" + UUID().uuidString, isDirectory: true)
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        database = root.appendingPathComponent("workspace.sqlite")
        let project = WorkspaceProject(path: root.path); self.project = project
        var old = CodingThread(project: project); old.checkpointPolicy = .disabled; old.draft = "Legacy CLI draft stays in place"; legacy = old
        let lockRoot = root.appendingPathComponent("locks", isDirectory: true); self.lockRoot = lockRoot
        callbacks = WorkspaceCodexCallbacks(closeGate: closeGate)
        let instant = Date(timeIntervalSince1970: 1_800_000_000), client = CodexOAuthClient(transport: transport, now: { instant }); self.client = client
        broker = CodexOwnedRuntimeBroker(storage: storage, lockRoot: lockRoot, homesRoot: root.appendingPathComponent("homes"),
            clientFactory: { client }, now: { instant })
    }
    func makeStore(snapshot: WorkspaceSnapshot? = nil, reopening: Bool = false) async throws -> (WorkspaceStore, WorkspaceEngine) {
        if !reopening {
            var initial = snapshot ?? WorkspaceSnapshot()
            if snapshot == nil { initial.projects = [project]; initial.threads = [legacy] }
            try await WorkspaceDatabase(url: database).save(initial, event: "workspace.codex.auth.fixture")
        }
        let audit = providers, callbacks = callbacks
        let engine = try WorkspaceEngine(url: database, providerFactory: { _ in try audit.unexpected() }, identityResolver: { _ in nil })
        let store = WorkspaceStore(engine: engine, codexOwnedRuntime: broker, codexHostID: UUID(),
            codexListenerFactory: { await callbacks.make() }, codexAuthorization: { try await callbacks.authorize($0) })
        await store.load(); return (store, engine)
    }
    func applyOwned(_ store: WorkspaceStore) async {
        store.codexRuntime.authenticationMode = .ownedChatGPT
        store.codexRuntime.homeDirectory = root.appendingPathComponent("Shared Codex").path
        await store.codexRuntime.applySelection()
    }
    func seedProfile(_ name: String) async throws -> CodexAccountOverview {
        let instant = now, client = client
        let credential = CodexOAuthCredential(clientID: "oaiapp_offline_" + name, accessToken: UUID().uuidString,
            refreshToken: UUID().uuidString, idToken: nil, issuer: URL(string: "https://auth.openai.com")!,
            expiresAt: instant.addingTimeInterval(3_600), earliestRefreshAt: nil, scopes: [CodexOAuthClient.requiredScope],
            identity: .init(subject: "offline-subject-" + name, email: "private-" + name + "@example.invalid"))
        let vault = CodexAccountVault(instanceID: CodexRuntimeConfiguration.defaultInstanceID, storage: storage,
            lockRoot: lockRoot, operations: .init(callback: { try await client.callback(authorization: $0, callbackURL: $1) },
                exchange: { _, _ in credential }, refresh: { $0 }, revoke: { _ in .confirmed }), now: { instant })
        let preparation = try await vault.prepare()
        let auth = try await client.authorization(redirectURI: URL(string: "http://127.0.0.1:43210/auth/callback")!, hostID: UUID())
        let query = try #require(URLComponents(url: auth.authorizationURL, resolvingAgainstBaseURL: false)?.queryItems)
        let state = try #require(query.first(where: { $0.name == "state" })?.value)
        var callback = try #require(URLComponents(url: auth.redirectURI, resolvingAgainstBaseURL: false))
        callback.queryItems = [.init(name: "state", value: state), .init(name: "code", value: "offline-seed-code"), .init(name: "client_id", value: credential.clientID)]
        return try await vault.exchange(preparation: preparation, authorization: auth, callbackURL: try #require(callback.url?.absoluteString))
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}

@MainActor private func waitWorkspaceCodexAuth(file: StaticString = #fileID, line: UInt = #line,
                                              _ condition: () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !(await condition()) {
        guard ContinuousClock.now < deadline else { throw CoincideError("Workspace Codex auth fixture timed out at \(file):\(line).") }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@Test(.timeLimit(.minutes(1)), arguments: ["decline", "expired-code"])
@MainActor func nativeWorkspaceCodexAuthenticationIsExplicitAndFailureKeepsOwnedModeWithoutCLIFallback(mode: String) async throws {
    let fixture = try WorkspaceCodexAuthFixture(), (store, _) = try await fixture.makeStore()
    do {
        #expect(store.codexRuntime.configuration == .init() && fixture.storage.count == 0 && fixture.providers.count == 0)
        let initialPaths = await fixture.transport.paths, initialAuthorizations = await fixture.callbacks.authorizations
        #expect(initialPaths.isEmpty && initialAuthorizations == 0)
        await fixture.applyOwned(store)
        #expect(store.codexRuntime.configuration.authenticationMode == .ownedChatGPT && store.codexRuntime.configuration.accountBinding == nil)
        #expect(fixture.storage.count == 0 && fixture.providers.count == 0)
        let applyPaths = await fixture.transport.paths, applyAuthorizations = await fixture.callbacks.authorizations
        #expect(applyPaths.isEmpty && applyAuthorizations == 0)
        await fixture.callbacks.configure(mode)
        await store.codexAuthentication.startSignIn()
        try await waitWorkspaceCodexAuth { !store.codexAuthentication.isWorking && store.codexAuthentication.state.phase != .idle }
        #expect(store.codexAuthentication.state.phase == (mode == "decline" ? .failed : .expired))
        #expect(store.codexRuntime.configuration.authenticationMode == .ownedChatGPT && store.codexRuntime.configuration.accountBinding == nil)
        #expect(store.thread(fixture.legacy.id)?.codexRuntimeConfiguration == nil && store.thread(fixture.legacy.id)?.draft == fixture.legacy.draft)
        #expect(await fixture.callbacks.authorizations == 1)
        #expect(await fixture.callbacks.allClosed())
        let paths = await fixture.transport.paths
        #expect(paths.filter { $0 == "/token" }.count == (mode == "decline" ? 0 : 1))
        #expect(fixture.providers.count == 0)
        // Both the Engine reservation and the cross-process admission must have
        // ended after the failed explicit flow; there is no automatic retry.
        let lease = try await fixture.broker.beginMutation(instanceID: store.codexRuntime.configuration.instanceID)
        lease.release()
    } catch { await store.shutdown(); fixture.remove(); throw error }
    await store.shutdown(); fixture.remove()
}

@Test(.timeLimit(.minutes(1)))
@MainActor func nativeWorkspaceCodexProfileActivationAndLogoutPublishOpaqueHeadersWhilePreservingCLIAndQueuedInputAcrossReopen() async throws {
    let fixture = try WorkspaceCodexAuthFixture()
    let first = try await fixture.seedProfile("first"), firstProfile = try #require(first.binding?.profileID)
    let second = try await fixture.seedProfile("second"), secondBinding = try #require(second.binding)
    let config = CodexRuntimeConfiguration(homeDirectory: fixture.root.appendingPathComponent("Shared Codex").path,
        authenticationMode: .ownedChatGPT, accountBinding: secondBinding)
    var owned = CodingThread(project: fixture.project); owned.checkpointPolicy = .disabled; owned.codexRuntimeConfiguration = config
    owned.draft = "Existing owned draft"; owned.queuePaused = true
    owned.queuedTurns = [.init(id: UUID(), text: "Captured account input must not replay", configuration: .init(thread: owned), createdAt: .now, checkpointPolicy: .disabled)]
    let queue = owned.queuedTurns
    var snapshot = WorkspaceSnapshot(); snapshot.projects = [fixture.project]; snapshot.threads = [owned, fixture.legacy]
    let (store, _) = try await fixture.makeStore(snapshot: snapshot)
    do {
        let beforeApplyReads = fixture.storage.count, beforeApplyHTTP = await fixture.transport.paths
        await fixture.applyOwned(store)
        let afterApplyHTTP = await fixture.transport.paths
        #expect(fixture.storage.count == beforeApplyReads && afterApplyHTTP == beforeApplyHTTP)
        await store.codexAuthentication.refreshAccounts()
        #expect(store.codexAuthentication.profiles.count == 2)
        store.setDraft("Latest draft typed before selecting another account", id: owned.id)
        await store.codexAuthentication.selectProfile(firstProfile)
        try await waitWorkspaceCodexAuth { store.codexAuthentication.state.phase == .succeeded && !store.codexAuthentication.isWorking }
        let selected = try #require(store.codexRuntime.configuration.accountBinding)
        #expect(selected.profileID == firstProfile && selected.generation != first.binding?.generation)
        let changed = try #require(store.thread(owned.id))
        #expect(changed.codexRuntimeConfiguration?.accountBinding == selected && changed.queuedTurns == queue && changed.queuePaused)
        #expect(changed.draft == "Latest draft typed before selecting another account")
        #expect(store.thread(fixture.legacy.id)?.codexRuntimeConfiguration == nil)
        let previousIDs = Set(store.snapshot.threads.map(\.id))
        store.newThread(projectID: fixture.project.id)
        try await waitWorkspaceCodexAuth { store.snapshot.threads.contains(where: { !previousIDs.contains($0.id) }) }
        let future = try #require(store.snapshot.threads.first { !previousIDs.contains($0.id) })
        #expect(future.codexRuntimeConfiguration?.accountBinding == selected && future.messages.isEmpty && future.queuedTurns.isEmpty)
        await store.codexAuthentication.selectProfile(secondBinding.profileID)
        try await waitWorkspaceCodexAuth { store.codexRuntime.configuration.accountBinding?.profileID == secondBinding.profileID && !store.codexAuthentication.isWorking }
        await store.codexAuthentication.signOut(profileID: secondBinding.profileID)
        try await waitWorkspaceCodexAuth { store.codexAuthentication.state.phase == .signedOut && !store.codexAuthentication.isWorking }
        #expect(store.codexRuntime.configuration.authenticationMode == .ownedChatGPT && store.codexRuntime.configuration.accountBinding == nil)
        let signedOut = try #require(store.thread(owned.id))
        #expect(signedOut.codexRuntimeConfiguration?.authenticationMode == .ownedChatGPT && signedOut.codexRuntimeConfiguration?.accountBinding == nil)
        #expect(signedOut.queuedTurns == queue && signedOut.queuePaused)
        #expect(store.codexAuthentication.profiles.first(where: { $0.id == secondBinding.profileID })?.hasCredential == false)
        #expect(await fixture.callbacks.authorizations == 0)
        #expect(fixture.providers.count == 0)
        let paths = await fixture.transport.paths
        #expect(paths.filter { $0 == "/revoke" }.count == 1 && !paths.contains("/token"))
    } catch { await store.shutdown(); fixture.remove(); throw error }
    await store.shutdown()
    let beforeReopenReads = fixture.storage.count, beforeReopenHTTP = await fixture.transport.paths
    let (reopened, engine) = try await fixture.makeStore(reopening: true)
    do {
        #expect(reopened.codexRuntime.configuration.authenticationMode == .ownedChatGPT && reopened.codexRuntime.configuration.accountBinding == nil)
        let afterReopenHTTP = await fixture.transport.paths
        #expect(fixture.storage.count == beforeReopenReads && afterReopenHTTP == beforeReopenHTTP)
        let saved = try #require(reopened.thread(owned.id))
        #expect(saved.queuedTurns == queue && saved.queuePaused && saved.draft == "Latest draft typed before selecting another account")
        #expect(reopened.thread(fixture.legacy.id)?.codexRuntimeConfiguration == nil)
        await #expect(throws: WorkspaceCommandError.self) { try await engine.dispatch(.resumeQueue(threadID: owned.id)) }
        #expect(fixture.providers.count == 0)
        for file in try FileManager.default.contentsOfDirectory(at: fixture.root, includingPropertiesForKeys: nil) where file.lastPathComponent.hasPrefix("workspace.sqlite") {
            let bytes = try Data(contentsOf: file)
            #expect(!bytes.contains(Data("private-first@example.invalid".utf8)) && !bytes.contains(Data("oaiapp_offline_".utf8)))
        }
    } catch { await reopened.shutdown(); fixture.remove(); throw error }
    await reopened.shutdown(); fixture.remove()
}

@Test(.timeLimit(.minutes(1)))
@MainActor func nativeWorkspaceCodexShutdownJoinsTheExactCallbackBeforeReleasingAuthAdmission() async throws {
    let gate = WorkspaceCodexCloseGate(), fixture = try WorkspaceCodexAuthFixture(closeGate: gate)
    let (store, _) = try await fixture.makeStore()
    do {
        await fixture.applyOwned(store)
        await store.codexAuthentication.startSignIn()
        try await waitWorkspaceCodexAuth { store.codexAuthentication.state.phase == .waitingForBrowser }
    } catch { await gate.release(); await store.shutdown(); fixture.remove(); throw error }
    var finished = false
    let shutdown = Task { await store.shutdown(); finished = true }
    do {
        try await waitWorkspaceCodexAuth { await gate.entered }
        #expect(!finished)
        await #expect(throws: CodexRuntimeAdmissionError.busy) {
            try await CodexRuntimeAdmission.acquireRuntime(instanceID: store.codexRuntime.configuration.instanceID, root: fixture.lockRoot, timeout: .zero)
        }
        await gate.release(); await shutdown.value
        #expect(finished && fixture.providers.count == 0)
        #expect(await fixture.callbacks.allClosed())
        let lease = try await CodexRuntimeAdmission.acquireMutation(instanceID: store.codexRuntime.configuration.instanceID, root: fixture.lockRoot, timeout: .zero)
        lease.release()
        #expect(store.codexRuntime.configuration.authenticationMode == .ownedChatGPT && store.codexRuntime.configuration.accountBinding == nil)
    } catch { await gate.release(); await shutdown.value; fixture.remove(); throw error }
    fixture.remove()
}
