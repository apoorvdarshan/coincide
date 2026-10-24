import Darwin
import Foundation
import Testing
@testable import Coincide
@testable import CoincideCore

private final class FirstRunMemoryCredentials: CodexCredentialStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [UUID: Data] = [:]
    private var count = 0
    var reads: Int { lock.withLock { count } }
    func read(instanceID: UUID) -> Data? { lock.withLock { count += 1; return records[instanceID] } }
    func write(_ data: Data, instanceID: UUID) { lock.withLock { records[instanceID] = data } }
    func delete(instanceID: UUID) { _ = lock.withLock { records.removeValue(forKey: instanceID) } }
    func createIfAbsent(_ data: Data, instanceID: UUID) -> Bool {
        lock.withLock { guard records[instanceID] == nil else { return false }; records[instanceID] = data; return true }
    }
}

private actor FirstRunOfflineTransport: CodexOAuthTransport {
    private(set) var requests = 0
    func response(for request: URLRequest, maximumBytes: Int) throws -> CodexOAuthHTTPResponse {
        requests += 1
        let url = try #require(request.url)
        guard url.absoluteString == "https://auth.openai.com/.well-known/openid-configuration" else {
            Issue.record("Readiness fixtures never make live authorization or token requests.")
            throw CodexOAuthError(.protocolViolation)
        }
        let discovery = JSONValue.object(["issuer": .string("https://auth.openai.com"),
            "authorization_endpoint": .string("https://auth.openai.com/api/accounts/authorize"),
            "token_endpoint": .string("https://auth.openai.com/token"), "jwks_uri": .string("https://auth.openai.com/keys"),
            "revocation_endpoint": .string("https://auth.openai.com/revoke")])
        return .init(statusCode: 200, url: url, body: try JSONEncoder().encode(discovery))
    }
}

@MainActor private struct FirstRunProfileFixture {
    private enum Stage: String { case filesystem, vaultPreparation, authorization, vaultExchange, workspace }
    private struct Failure: Error, CustomStringConvertible {
        let stage: Stage
        var description: String { "Private first-run fixture failed at " + stage.rawValue }
    }
    let root: URL, codex: URL, claude: URL, marker: URL
    let project: WorkspaceProject
    let store: WorkspaceStore
    let installation: CodexInstallation
    let storage: FirstRunMemoryCredentials
    let transport: FirstRunOfflineTransport

    static func make(owned: Bool = false) async throws -> Self {
        // Resolve the existing parent before appending a nonexistent child.
        // The vault deliberately rejects symlink ancestors such as /var.
        let pointer = try #require(realpath(FileManager.default.temporaryDirectory.path, nil))
        let temporary = URL(fileURLWithPath: String(cString: pointer), isDirectory: true); free(pointer)
        let root = temporary.appendingPathComponent("coincide-first-run-profile-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var stage = Stage.filesystem
        do {
            let marker = root.appendingPathComponent("cli-invoked"), codex = root.appendingPathComponent("codex-custom"), claude = root.appendingPathComponent("claude-custom")
            let home = root.appendingPathComponent("codex-home")
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            for (tool, namespace) in [(codex, "CODEX_HOME"), (claude, "CLAUDE_CONFIG_DIR")] {
                let script = "#!/bin/sh\nprintf '%s' invoked > " + CLIShim.shellWord(marker.path)
                    + "\n[ -n \"$" + namespace + "\" ] || exit 9\nprintf 'Selected profile ready'\n"
                try script.write(to: tool, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
            }
            let storage = FirstRunMemoryCredentials(), transport = FirstRunOfflineTransport()
            let instant = Date(timeIntervalSince1970: 1_800_000_000)
            let client = CodexOAuthClient(transport: transport, now: { instant })
            let locks = root.appendingPathComponent("account-locks")
            var binding: CodexAccountBinding?
            if owned {
                let credential = CodexOAuthCredential(clientID: "oaiapp_offline_first_run", accessToken: UUID().uuidString,
                    refreshToken: UUID().uuidString, idToken: nil, issuer: URL(string: "https://auth.openai.com")!,
                    expiresAt: instant.addingTimeInterval(3600), earliestRefreshAt: nil, scopes: [CodexOAuthClient.requiredScope],
                    identity: .init(subject: "offline-first-run", email: "offline@example.invalid"))
                let vault = CodexAccountVault(instanceID: CodexRuntimeConfiguration.defaultInstanceID, storage: storage, lockRoot: locks,
                    operations: .init(callback: { try await client.callback(authorization: $0, callbackURL: $1) },
                        exchange: { _, _ in credential }, refresh: { $0 }, revoke: { _ in .confirmed }), now: { instant })
                stage = .vaultPreparation
                let preparation = try await vault.prepare()
                stage = .authorization
                let authorization = try await client.authorization(redirectURI: URL(string: "http://127.0.0.1:43210/auth/callback")!, hostID: UUID())
                let query = try #require(URLComponents(url: authorization.authorizationURL, resolvingAgainstBaseURL: false)?.queryItems)
                let state = try #require(query.first(where: { $0.name == "state" })?.value)
                var callback = try #require(URLComponents(url: authorization.redirectURI, resolvingAgainstBaseURL: false))
                callback.queryItems = [.init(name: "state", value: state), .init(name: "code", value: "offline-fixture-code"), .init(name: "client_id", value: credential.clientID)]
                stage = .vaultExchange
                let overview = try await vault.exchange(preparation: preparation, authorization: authorization, callbackURL: try #require(callback.url?.absoluteString))
                binding = overview.binding
            }
            stage = .workspace
            let configuration = CodexRuntimeConfiguration(selection: .custom, executable: codex.path, homeDirectory: home.path,
                authenticationMode: owned ? .ownedChatGPT : .cliDefault, accountBinding: binding)
            let settings = root.appendingPathComponent("CodexSettings")
            try FileManager.default.createDirectory(at: settings, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let preference = settings.appendingPathComponent("runtime.json")
            try JSONEncoder().encode(configuration).write(to: preference)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: preference.path)
            let installation = CodexInstallation(rootURL: root.appendingPathComponent("Tools/Codex"), release: nil,
                downloader: { _, _, _ in throw CoincideError("A readiness check cannot install a CLI.") },
                inspector: { _, _ in throw CoincideError("A readiness capture cannot inspect a CLI.") },
                localResolver: { value in [codex.path, claude.path].contains(value) ? URL(fileURLWithPath: value) : nil })
            let broker = CodexOwnedRuntimeBroker(storage: storage, lockRoot: locks, homesRoot: root.appendingPathComponent("owned-homes"),
                clientFactory: { client }, now: { instant })
            let project = WorkspaceProject(path: root.path)
            var thread = CodingThread(project: project); thread.checkpointPolicy = .disabled
            var snapshot = WorkspaceSnapshot(); snapshot.projects = [project]; snapshot.threads = [thread]
            let database = root.appendingPathComponent("workspace.sqlite")
            try await WorkspaceDatabase(url: database).save(snapshot, event: "first-run-profile-fixture")
            let engine = try WorkspaceEngine(url: database, providerFactory: { _ in
                Issue.record("Readiness cannot launch a provider runtime."); throw CancellationError()
            }, identityResolver: { _ in nil })
            let store = WorkspaceStore(engine: engine, codexInstallation: installation, codexOwnedRuntime: broker, codexHostID: UUID(),
                codexListenerFactory: { throw CoincideError("Readiness cannot open an authorization listener.") },
                codexAuthorization: { _ in throw CoincideError("Readiness cannot open authorization.") })
            await store.load()
            store.selectedThreadID = thread.id; store.selectedProjectID = project.id
            return .init(root: root, codex: codex, claude: claude, marker: marker, project: project, store: store,
                         installation: installation, storage: storage, transport: transport)
        } catch { try? FileManager.default.removeItem(at: root); throw Failure(stage: stage) }
    }
    func close() async {
        await store.shutdown(); await installation.shutdown()
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor @Test(.timeLimit(.minutes(1)))
func firstRunWorkspaceCapturesSelectedCodexHomeAndClaudeNamespaceAndRejectsReplacedProfiles() async throws {
    let f = try await FirstRunProfileFixture.make()
    do {
        let codex = try f.store.captureFirstRunReadiness(.codex)
        #expect(codex.executable == f.codex && codex.environment["CODEX_HOME"] == f.root.appendingPathComponent("codex-home").path)
        #expect(codex.directory.utf8.elementsEqual(f.project.path.utf8))
        #expect(f.store.isCurrentFirstRunReadiness(codex))
        #expect(!FileManager.default.fileExists(atPath: f.marker.path), "Capturing status never starts the selected executable.")
        #expect(await ProviderReadiness.check(codex) == .ready("Selected profile ready"))
        f.store.codexRuntime.homeDirectory = f.root.appendingPathComponent("next-home").path
        await f.store.codexRuntime.applySelection()
        #expect(!f.store.isCurrentFirstRunReadiness(codex))
        #expect(try f.store.captureFirstRunReadiness(.codex).environment["CODEX_HOME"] == f.root.appendingPathComponent("next-home").path)

        f.store.claudeRuntime.executable = f.claude.path
        f.store.claudeRuntime.configurationDirectory = f.root.appendingPathComponent("claude-profile-one").path
        await f.store.claudeRuntime.applySelection()
        let claude = try f.store.captureFirstRunReadiness(.claude)
        #expect(claude.executable == f.claude && claude.environment["CLAUDE_CONFIG_DIR"] == f.root.appendingPathComponent("claude-profile-one").path)
        #expect(claude.directory.utf8.elementsEqual(f.project.path.utf8))
        #expect(f.store.isCurrentFirstRunReadiness(claude))
        #expect(await ProviderReadiness.check(claude) == .ready("Selected profile ready"))
        f.store.claudeRuntime.configurationDirectory = f.root.appendingPathComponent("claude-profile-two").path
        await f.store.claudeRuntime.applySelection()
        #expect(!f.store.isCurrentFirstRunReadiness(claude))
        #expect(try f.store.captureFirstRunReadiness(.claude).environment["CLAUDE_CONFIG_DIR"] == f.root.appendingPathComponent("claude-profile-two").path)
    } catch { await f.close(); throw error }
    await f.close()
}

@MainActor @Test(.timeLimit(.minutes(1)))
func firstRunWorkspaceOwnedCodexUsesExistingVerifiedVaultOverviewWithoutLaunchingCLIOrAuthentication() async throws {
    let f = try await FirstRunProfileFixture.make(owned: true)
    do {
        let deadline = ContinuousClock.now + .seconds(5)
        while !f.store.codexAuthentication.canRefresh {
            guard ContinuousClock.now < deadline else { throw CoincideError("The private account controller did not bind.") }
            try await Task.sleep(for: .milliseconds(5))
        }
        // Explicit fixture preparation reads its injected in-memory vault once.
        // Capturing/checking readiness subsequently uses that verified overview.
        await f.store.codexAuthentication.refreshAccounts()
        #expect(f.store.codexAuthentication.overview?.binding == f.store.codexRuntime.configuration.accountBinding)
        let reads = f.storage.reads, requests = await f.transport.requests
        let capture = try f.store.captureFirstRunReadiness(.codex)
        #expect(capture.resultOverride == .ready(nil) && capture.loginCommand == nil)
        #expect(await ProviderReadiness.check(capture) == .ready(nil))
        #expect(f.store.isCurrentFirstRunReadiness(capture))
        #expect(f.storage.reads == reads)
        #expect(await f.transport.requests == requests)
        #expect(!FileManager.default.fileExists(atPath: f.marker.path))
    } catch { await f.close(); throw error }
    await f.close()
}

@MainActor @Test(.timeLimit(.minutes(1)))
func firstRunPublishedReadinessRevisionPreventsRetainedRowsFromCopyingAnOldProfileCommand() async throws {
    let f = try await FirstRunProfileFixture.make()
    do {
        f.store.claudeRuntime.executable = f.claude.path
        f.store.claudeRuntime.configurationDirectory = f.root.appendingPathComponent("private-claude").path
        await f.store.claudeRuntime.applySelection()
        let model = AgentReadinessModel { _ in .signIn("Private fixture needs sign-in") }
        let environment = ShellEnvironmentController(available: false)
        let originalRevision = f.store.firstRunReadinessRevision
        await model.checkAll(environment: environment, capture: f.store.captureFirstRunReadiness,
                             isCurrent: f.store.isCurrentFirstRunReadiness, revision: originalRevision)
        let capture = try #require(model.captures[.codex]), command = try #require(capture.loginCommand)
        let rowRevision = model.capturedRevision[.codex]
        let retained = AgentReadinessRow(agent: .codex, readiness: try #require(model.states[.codex]), executable: capture.executable,
            capturedLoginCommand: command, usesCapturedProfile: true,
            isCurrent: { rowRevision == f.store.firstRunReadinessRevision })
        var copied: [String] = []
        #expect(retained.copyCommand(command, write: { copied.append($0) }))
        f.store.codexRuntime.homeDirectory = f.root.appendingPathComponent("replacement-home").path
        await f.store.codexRuntime.applySelection()
        #expect(f.store.firstRunReadinessRevision != originalRevision)
        #expect(!retained.copyCommand(command, write: { copied.append($0) }))
        // Refreshing the model cannot grant an already retained old row the
        // new revision. Each row owns the revision of its displayed command.
        await model.checkAll(environment: environment, capture: f.store.captureFirstRunReadiness,
                             isCurrent: f.store.isCurrentFirstRunReadiness, revision: f.store.firstRunReadinessRevision)
        #expect(model.capturedRevision[.codex] == f.store.firstRunReadinessRevision)
        #expect(!retained.copyCommand(command, write: { copied.append($0) }))
        #expect(copied == [command])
        #expect(!FileManager.default.fileExists(atPath: f.marker.path))
        await model.shutdown()
    } catch { await f.close(); throw error }
    await f.close()
}

/// Currency that a readiness row's closure reads after the test retires it.
@MainActor private final class FirstRunRowCurrency { var value = true }

@MainActor @Test
func firstRunReadinessRepairsOnlyDefaultCLISelectionsAndGuardsSettingsForConfiguredRuntimes() {
    let scopes: [(ProviderReadiness.Capture.Scope, Bool)] = [
        (.codex(.init(selection: .existingCLI)), true),
        (.codex(.init(selection: .managed)), false),
        (.codex(.init(selection: .custom, executable: "/private/missing-codex")), false),
        (.unavailableClaude(.init()), true),
        (.unavailableClaude(.init(executable: "/private/missing-claude")), false),
    ]
    for (scope, offersInstaller) in scopes {
        let capture = ProviderReadiness.Capture(scope: scope, executable: nil, environment: [:], directory: "/private/tmp")
        let current = FirstRunRowCurrency()
        var writes = 0, settings = 0
        let row = AgentReadinessRow(agent: capture.agent, readiness: .install, executable: nil,
            capturedLoginCommand: capture.loginCommand, capturedInstallCommand: capture.capturedInstallCommand,
            usesCapturedProfile: true, isCurrent: { current.value })
        #expect((capture.capturedInstallCommand != nil) == offersInstaller)
        #expect(row.copyCommand(capture.agent.installCommand, write: { _ in writes += 1 }) == offersInstaller)
        #expect(row.reviewSettings(using: { settings += 1 }) == !offersInstaller)
        current.value = false
        #expect(!row.copyCommand(capture.agent.installCommand, write: { _ in writes += 1 }))
        #expect(!row.reviewSettings(using: { settings += 1 }))
        #expect(writes == (offersInstaller ? 1 : 0) && settings == (offersInstaller ? 0 : 1))
    }
    let owned = ProviderReadiness.Capture(scope: .codex(.init(homeDirectory: "/private/owned", authenticationMode: .ownedChatGPT)),
        executable: URL(fileURLWithPath: "/private/codex"), environment: [:], directory: "/private/tmp")
    for status in [ProviderReadiness.signIn(nil), .attention("Review account settings")] {
        var settings = 0, writes = 0
        let row = AgentReadinessRow(agent: .codex, readiness: status, executable: owned.executable,
            capturedLoginCommand: owned.loginCommand, capturedInstallCommand: owned.capturedInstallCommand, usesCapturedProfile: true)
        #expect(!row.copyCommand("codex login", write: { _ in writes += 1 }))
        #expect(row.reviewSettings(using: { settings += 1 }))
        #expect(settings == 1 && writes == 0)
    }
}
