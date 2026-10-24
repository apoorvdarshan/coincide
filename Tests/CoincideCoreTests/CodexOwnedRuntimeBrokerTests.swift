import Darwin
import CryptoKit
import Foundation
import Testing
@testable import CoincideCore

private final class OwnedBrokerMemory: CodexCredentialStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UUID: Data] = [:]
    private var reads = 0
    private var factories = 0
    var readCount: Int { lock.withLock { reads } }
    var factoryCount: Int { lock.withLock { factories } }
    func madeClient() { lock.withLock { factories += 1 } }
    func read(instanceID: UUID) throws -> Data? { lock.withLock { reads += 1; return values[instanceID] } }
    func createIfAbsent(_ data: Data, instanceID: UUID) throws -> Bool {
        lock.withLock { guard values[instanceID] == nil else { return false }; values[instanceID] = data; return true }
    }
    func write(_ data: Data, instanceID: UUID) throws { lock.withLock { values[instanceID] = data } }
    func delete(instanceID: UUID) throws { _ = lock.withLock { values.removeValue(forKey: instanceID) } }
}

private final class OwnedBrokerFixture: @unchecked Sendable {
    let root: URL
    let instanceID = UUID()
    let storage: OwnedBrokerMemory
    let clock: CodexOAuthTestClock
    let peer: CodexOAuthPeer
    let broker: CodexOwnedRuntimeBroker
    let installation: CodexInstallation
    var executable: URL { root.appendingPathComponent("owned-runtime-peer") }
    var shared: URL { root.appendingPathComponent("shared-cli-home") }
    var workspace: URL { root.appendingPathComponent("checkout 工作") }
    var database: URL { root.appendingPathComponent("workspace.sqlite") }
    init() throws {
        guard let physical = realpath(FileManager.default.temporaryDirectory.path, nil) else { throw CoincideError("The private test temporary root is unavailable.") }
        defer { free(physical) }
        root = URL(fileURLWithPath: String(cString: physical)).appendingPathComponent("coincide-owned-broker-" + UUID().uuidString)
        let storage = OwnedBrokerMemory(), clock = CodexOAuthTestClock(), peer = try CodexOAuthPeer(clock: clock)
        self.storage = storage; self.clock = clock; self.peer = peer
        broker = .init(storage: storage, lockRoot: root.appendingPathComponent("locks"), homesRoot: root.appendingPathComponent("homes"),
            clientFactory: { storage.madeClient(); return CodexOAuthClient(transport: peer, now: { clock.now() }) }, now: { clock.now() })
        installation = .init(rootURL: root.appendingPathComponent("unused-managed-installation"), release: nil)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            for directory in [shared, workspace] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
            try Data("PRIVATE SYNTHETIC CLI AUTH MUST STAY UNCHANGED".utf8).write(to: shared.appendingPathComponent("auth.json"))
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: shared.appendingPathComponent("auth.json").path)
            let source = try #require(Bundle.module.url(forResource: "codex_owned_runtime", withExtension: "py", subdirectory: "Fixtures"))
            try FileManager.default.copyItem(at: source, to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            try options(binding: nil, owned: false)
        } catch { try? FileManager.default.removeItem(at: root); throw error }
    }
    func configuration(_ binding: CodexAccountBinding?, owned: Bool = true, sharedHome: URL? = nil) -> CodexRuntimeConfiguration {
        .init(instanceID: instanceID, selection: .custom, executable: executable.path, homeDirectory: (sharedHome ?? shared).path,
              authenticationMode: owned ? .ownedChatGPT : .cliDefault, accountBinding: owned ? binding : nil)
    }
    func thread(_ binding: CodexAccountBinding?, owned: Bool = true, sharedHome: URL? = nil) -> CodingThread {
        var thread = CodingThread(project: .init(path: workspace.path))
        thread.provider = .codex; thread.model = "owned-wire-model"; thread.reasoningEffort = "medium"
        thread.codexRuntimeConfiguration = configuration(binding, owned: owned, sharedHome: sharedHome); thread.checkpointPolicy = .disabled
        return thread
    }
    func overlay(_ binding: CodexAccountBinding, sharedHome: URL? = nil) throws -> URL {
        let continuationPath = try CodexHomeLayout.resolvedPathForAdmission(sharedHome ?? shared)
        return root.appendingPathComponent("homes/" + instanceID.uuidString.lowercased() + "/" + binding.generation.uuidString.lowercased())
            .appendingPathComponent(SHA256.hash(data: Data(continuationPath.utf8)).map { String(format: "%02x", $0) }.joined())
    }
    func options(binding: CodexAccountBinding?, owned: Bool = true, sharedHome: URL? = nil) throws {
        let home = sharedHome ?? shared
        let expectedOverlay = try binding.map { try overlay($0, sharedHome: home) }
        let object: JSONValue = .object(["owned": .bool(owned), "shared": .string(home.path), "overlay": expectedOverlay.map { .string($0.path) } ?? .null])
        try JSONEncoder().encode(object).write(to: root.appendingPathComponent("options.json"), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: root.appendingPathComponent("options.json").path)
    }
    func signIn() async throws -> CodexAccountBinding {
        let admission = try await broker.beginMutation(instanceID: instanceID)
        defer { admission.release() }
        let components = await broker.components(instanceID: instanceID)
        let preparation = try await components.vault.prepare()
        let authorization = try await components.client.authorization(redirectURI: URL(string: "http://127.0.0.1:41234/auth/callback")!, hostID: UUID())
        await peer.setAuthorization(authorization)
        let items = try #require(URLComponents(url: authorization.authorizationURL, resolvingAgainstBaseURL: false)?.queryItems)
        let state = try #require(items.first { $0.name == "state" }?.value)
        var callback = URLComponents(url: authorization.redirectURI, resolvingAgainstBaseURL: false)!
        callback.queryItems = [.init(name: "state", value: state), .init(name: "code", value: "synthetic-code"), .init(name: "client_id", value: "oaiapp_fixture")]
        let callbackString = try #require(callback.url?.absoluteString)
        let overview = try await components.vault.exchange(preparation: preparation, authorization: authorization, callbackURL: callbackString)
        let binding = try #require(overview.binding)
        try options(binding: binding)
        return binding
    }
    func rows(_ kind: String) throws -> [JSONValue] {
        let path = root.appendingPathComponent("wire.jsonl")
        guard FileManager.default.fileExists(atPath: path.path) else { return [] }
        let bytes = try Data(contentsOf: path)
        guard let newline = bytes.lastIndex(of: 10) else { return [] }
        return try bytes[...newline].split(separator: 10).map { try JSONDecoder().decode(JSONValue.self, from: Data($0)) }.filter { $0["kind"] == .string(kind) }
    }
    func allProcessesStopped() throws -> Bool {
        try rows("launch").allSatisfy { row in
            guard case .number(let number) = row["pid"] else { return false }
            return Darwin.kill(Int32(number), 0) != 0 && errno == ESRCH
        }
    }
    func remove() throws {
        guard try allProcessesStopped() else { throw CoincideError("The private owned-runtime fixture still has its exact child process.") }
        try FileManager.default.removeItem(at: root)
    }
    func provePrivateBytesAbsent(_ additional: Data = Data()) async throws {
        let bytes = (try? Data(contentsOf: root.appendingPathComponent("wire.jsonl"))) ?? Data()
        let access = peer.access, refresh = peer.refresh
        let documentData = try storage.read(instanceID: instanceID)
        let document = try documentData.map { try JSONDecoder().decode(JSONValue.self, from: $0) }
        let idTokens = document?["profiles"].array?.compactMap { $0["credential"]["idToken"].string } ?? []
        let privateValues = [access, refresh, "synthetic@example.invalid", "synthetic-subject", "oaiapp_fixture"] + idTokens
        let wal = URL(fileURLWithPath: database.path + "-wal")
        let databaseBytes = ((try? Data(contentsOf: database)) ?? Data()) + ((try? Data(contentsOf: wal)) ?? Data())
        let leaked = privateValues.contains { bytes.range(of: Data($0.utf8)) != nil || additional.range(of: Data($0.utf8)) != nil || databaseBytes.range(of: Data($0.utf8)) != nil }
        #expect(!leaked)
        let requests = try rows("request").compactMap { $0["method"].string }
        #expect(!requests.contains("account/read") && !requests.contains("account/rateLimits/read"))
        #expect(try Data(contentsOf: shared.appendingPathComponent("auth.json")) == Data("PRIVATE SYNTHETIC CLI AUTH MUST STAY UNCHANGED".utf8))
    }
}

private func ownedBrokerEventually(_ description: String, _ predicate: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while !(try await predicate()) {
        guard ContinuousClock.now < deadline else { throw CoincideError("The synthetic owned Codex fixture did not observe " + description + ".") }
        try await Task.sleep(for: .milliseconds(10))
    }
}

@Test(.timeLimit(.minutes(1))) func codexOwnedBrokerProductionFactoryIsInertAndTheCLIPathNeverTouchesItsVault() async throws {
    let fixture = try OwnedBrokerFixture()
    var active: (any ProviderSession)?
    do {
        let owned = try ProviderSessions.make(for: fixture.thread(.init(profileID: UUID(), generation: UUID())), codexInstallation: fixture.installation, codexOwnedRuntime: fixture.broker)
        active = owned
        #expect(fixture.storage.readCount == 0 && fixture.storage.factoryCount == 0)
        #expect(try fixture.rows("launch").isEmpty)
        await owned.close(); active = nil
        #expect(fixture.storage.readCount == 0 && fixture.storage.factoryCount == 0)
        let cli = try ProviderSessions.make(for: fixture.thread(nil, owned: false), codexInstallation: fixture.installation, codexOwnedRuntime: fixture.broker)
        active = cli
        _ = try await cli.models()
        await cli.close(); active = nil
        #expect(fixture.storage.readCount == 0 && fixture.storage.factoryCount == 0)
        #expect(try fixture.rows("launch").allSatisfy { $0["basicArguments"] == .bool(true) })
        try fixture.remove()
    } catch { await active?.close(); try? fixture.remove(); throw error }
}

@Test(.timeLimit(.minutes(1))) func codexOwnedBrokerVerifiedOAuthFeedsTheExactNativeLaunchAndVaultOnlyAccountMetadata() async throws {
    let fixture = try OwnedBrokerFixture()
    let binding: CodexAccountBinding
    do { binding = try await fixture.signIn() } catch { try? fixture.remove(); throw error }
    let session = try ProviderSessions.make(for: fixture.thread(binding), codexInstallation: fixture.installation, codexOwnedRuntime: fixture.broker)
    do {
        let before = fixture.storage.readCount
        let account = try await session.codexAccountSnapshot()
        #expect(account.identity.kind == .chatgpt && account.identity.email == "synthetic@example.invalid" && account.usage == .unsupported)
        let beforeLaunches = try fixture.rows("launch")
        #expect(fixture.storage.readCount > before && beforeLaunches.isEmpty)
        let models = try await session.models()
        #expect(models.map(\.id) == ["owned-wire-model"])
        let launches = try fixture.rows("launch")
        let launch = try #require(launches.first)
        for name in ["exactArguments", "tokenPresent", "syntheticToken", "aliasesScrubbed", "privateHome", "exactHome", "sharedHistory"] { #expect(launch[name] == .bool(true)) }
        #expect(launch["argumentCount"] == .number(24) && launch["authRedirect"] == .bool(false))
        await #expect(throws: CodexRuntimeAdmissionError.busy) { try await fixture.broker.beginMutation(instanceID: fixture.instanceID) }
        async let first: Void = session.close()
        async let second: Void = session.close()
        _ = await (first, second)
        try await ownedBrokerEventually("owned EOF and PID drain") { try fixture.rows("closed").count == 1 && fixture.allProcessesStopped() }
        #expect(try fixture.rows("closed").first?["stdinEOF"] == .bool(true))
        let mutation = try await fixture.broker.beginMutation(instanceID: fixture.instanceID); mutation.release()
        #expect(await fixture.peer.checkedVerifier)
        try await fixture.provePrivateBytesAbsent()
        try fixture.remove()
    } catch { await session.close(); try? fixture.remove(); throw error }
}

@Test(.timeLimit(.minutes(1))) func codexOwnedBrokerRunsAndResumesRealEngineMarkersThroughSharedHistoryWithoutCLIAuthMutation() async throws {
    let fixture = try OwnedBrokerFixture()
    let binding: CodexAccountBinding
    do { binding = try await fixture.signIn() } catch { try? fixture.remove(); throw error }
    let broker = fixture.broker, installation = fixture.installation
    let factory: WorkspaceEngine.ProviderFactory = { try ProviderSessions.make(for: $0, codexInstallation: installation, codexOwnedRuntime: broker) }
    let first = try WorkspaceEngine(url: fixture.database, providerFactory: factory, identityResolver: { _ in nil })
    var second: WorkspaceEngine?
    do {
        _ = try await first.load()
        let thread = fixture.thread(binding)
        var project = WorkspaceProject(path: fixture.workspace.path); project.id = thread.projectID
        try await first.dispatch(.addProject(project)); try await first.dispatch(.createThread(thread))
        try await first.dispatch(.submit(threadID: thread.id, text: "FIRST 工作 🌍"))
        try await ownedBrokerEventually("first persisted Engine marker") {
            let current = await first.current().snapshot.threads.first { $0.id == thread.id }
            return current?.state == .idle && current?.providerThreadID == "owned-native-thread" && current?.messages.contains { $0.role == .assistant && $0.text == "OWNED_REPLY FIRST 工作 🌍" } == true
        }
        await #expect(throws: CodexRuntimeAdmissionError.busy) { try await broker.beginMutation(instanceID: fixture.instanceID) }
        await first.shutdown()
        try await ownedBrokerEventually("first child drain") { try fixture.rows("closed").count == 1 && fixture.allProcessesStopped() }
        let reopened = try WorkspaceEngine(url: fixture.database, providerFactory: factory, identityResolver: { _ in nil }); second = reopened
        _ = try await reopened.load()
        try await reopened.dispatch(.submit(threadID: thread.id, text: "SECOND resumed"))
        try await ownedBrokerEventually("resumed Engine marker") {
            let current = await reopened.current().snapshot.threads.first { $0.id == thread.id }
            return current?.state == .idle && current?.messages.contains { $0.role == .assistant && $0.text == "OWNED_REPLY SECOND resumed" } == true
        }
        let update = await reopened.current()
        let final = try #require(update.snapshot.threads.first { $0.id == thread.id })
        #expect(final.messages.filter { $0.role == .user }.map(\.text) == ["FIRST 工作 🌍", "SECOND resumed"])
        #expect(final.runHistory?.count == 2 && final.runHistory?.allSatisfy { $0.status == .completed } == true)
        #expect(try fixture.rows("thread").map { $0["resumed"] } == [.bool(false), .bool(true)])
        #expect(try fixture.rows("thread").last?["persisted"] == .bool(true))
        #expect(try fixture.rows("turn").allSatisfy { $0["nativeThreadMatches"] == .bool(true) && $0["modelMatches"] == .bool(true) && $0["effortMatches"] == .bool(true) })
        let privateCache = try fixture.overlay(binding).appendingPathComponent("models_cache.json")
        #expect(try String(contentsOf: privateCache, encoding: .utf8) == #"{"syntheticPrivateCache":true}"#)
        #expect(!FileManager.default.fileExists(atPath: fixture.shared.appendingPathComponent("models_cache.json").path))
        await reopened.shutdown()
        try await ownedBrokerEventually("both child drains") { try fixture.rows("closed").count == 2 && fixture.allProcessesStopped() }
        let mutation = try await broker.beginMutation(instanceID: fixture.instanceID); mutation.release()
        try await fixture.provePrivateBytesAbsent(JSONEncoder().encode(update.snapshot))
        #expect(try fixture.rows("peer-failed").isEmpty)
        try fixture.remove()
    } catch { await first.shutdown(); await second?.shutdown(); try? fixture.remove(); throw error }
}

@Test(.timeLimit(.minutes(1))) func codexOwnedBrokerSharedHomeChangesPreserveBothHistoriesAndReopenTheOriginalPrivateOverlay() async throws {
    let fixture = try OwnedBrokerFixture()
    var active: (any ProviderSession)?
    do {
        let binding = try await fixture.signIn()
        let homeB = fixture.root.appendingPathComponent("second-shared-home", isDirectory: true)
        try FileManager.default.createDirectory(at: homeB, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let secondAuth = Data("SECOND PRIVATE SYNTHETIC CLI AUTH MUST STAY UNCHANGED".utf8)
        try secondAuth.write(to: homeB.appendingPathComponent("auth.json"))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: homeB.appendingPathComponent("auth.json").path)
        for home in [fixture.shared, homeB] {
            try FileManager.default.createDirectory(at: home.appendingPathComponent("sessions"), withIntermediateDirectories: false)
        }
        let firstHistory = fixture.shared.appendingPathComponent("sessions/first-home-history"), secondHistory = homeB.appendingPathComponent("sessions/second-home-history")
        try Data("Keep original home history".utf8).write(to: firstHistory)
        try Data("Keep second home history".utf8).write(to: secondHistory)
        let firstOverlay = try fixture.overlay(binding), secondOverlay = try fixture.overlay(binding, sharedHome: homeB)
        #expect(firstOverlay != secondOverlay)

        for (index, home) in [fixture.shared, homeB, fixture.shared].enumerated() {
            try fixture.options(binding: binding, sharedHome: home)
            let thread = fixture.thread(binding, sharedHome: home)
            #expect(thread.codexRuntimeConfiguration?.accountBinding == binding)
            let session = try ProviderSessions.make(for: thread, codexInstallation: fixture.installation, codexOwnedRuntime: fixture.broker)
            active = session
            let models = try await session.models()
            #expect(models.map(\.id) == ["owned-wire-model"])
            await session.close(); active = nil
            try await ownedBrokerEventually("the home-scoped child drain") {
                try fixture.rows("closed").count == index + 1 && fixture.allProcessesStopped()
            }
        }
        let launches = try fixture.rows("launch")
        #expect(launches.count == 3)
        #expect(launches.allSatisfy { $0["privateHome"] == .bool(true) && $0["exactHome"] == .bool(true) && $0["sharedHistory"] == .bool(true) && $0["authRedirect"] == .bool(false) })
        for overlay in [firstOverlay, secondOverlay] {
            let cache = try String(contentsOf: overlay.appendingPathComponent("models_cache.json"), encoding: .utf8)
            #expect(cache == #"{"syntheticPrivateCache":true}"#)
        }
        let firstLink = try FileManager.default.destinationOfSymbolicLink(atPath: firstOverlay.appendingPathComponent("sessions").path)
        let secondLink = try FileManager.default.destinationOfSymbolicLink(atPath: secondOverlay.appendingPathComponent("sessions").path)
        #expect(firstLink == fixture.shared.appendingPathComponent("sessions").path)
        #expect(secondLink == homeB.appendingPathComponent("sessions").path)
        #expect(try Data(contentsOf: firstHistory) == Data("Keep original home history".utf8))
        #expect(try Data(contentsOf: secondHistory) == Data("Keep second home history".utf8))
        #expect(try Data(contentsOf: homeB.appendingPathComponent("auth.json")) == secondAuth)
        #expect(!FileManager.default.fileExists(atPath: fixture.shared.appendingPathComponent("models_cache.json").path))
        #expect(!FileManager.default.fileExists(atPath: homeB.appendingPathComponent("models_cache.json").path))
        #expect(try fixture.rows("peer-failed").isEmpty)
        try await fixture.provePrivateBytesAbsent()
        try fixture.remove()
    } catch { await active?.close(); try? fixture.remove(); throw error }
}
