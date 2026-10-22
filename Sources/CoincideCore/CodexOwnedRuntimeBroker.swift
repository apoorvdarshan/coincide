import Foundation
import CryptoKit

/// The production owned-auth path. Constructing the broker/session is inert;
/// credentials and native processes are admitted only by an explicit operation.
public actor CodexOwnedRuntimeBroker {
    public static let shared = CodexOwnedRuntimeBroker()
    public static var defaultHomesRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Coincide/CodexHomes", isDirectory: true)
    }
    public struct Components: Sendable {
        public let vault: CodexAccountVault
        public let client: CodexOAuthClient
    }
    private struct Revision {
        let accessToken: String
        let id: UUID
    }
    private let storage: any CodexCredentialStorage
    public nonisolated let lockRoot: URL
    private let homesRoot: URL
    private let clientFactory: @Sendable () -> CodexOAuthClient
    private let now: @Sendable () -> Date
    private var accounts: [UUID: Components] = [:]
    private var revisions: [UUID: [CodexAccountBinding: Revision]] = [:]
    public init(storage: any CodexCredentialStorage = KeychainCodexCredentialStorage(),
                lockRoot: URL = CodexAccountVault.defaultLockRoot,
                homesRoot: URL = CodexOwnedRuntimeBroker.defaultHomesRoot,
                clientFactory: @escaping @Sendable () -> CodexOAuthClient = { CodexOAuthClient() },
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.storage = storage; self.lockRoot = lockRoot; self.homesRoot = homesRoot
        self.clientFactory = clientFactory; self.now = now
    }
    public func components(instanceID: UUID) -> Components {
        if let existing = accounts[instanceID] { return existing }
        let client = clientFactory()
        let components = Components(vault: CodexAccountVault(instanceID: instanceID, storage: storage,
            lockRoot: lockRoot, client: client, now: now), client: client)
        accounts[instanceID] = components; return components
    }
    public nonisolated func makeSession(configuration: CodexRuntimeConfiguration, cwd: URL,
                                        installation: CodexInstallation = .shared) throws -> CodexOwnedSession {
        try configuration.validate()
        guard configuration.authenticationMode == .ownedChatGPT else { throw CodexRuntimeConfiguration.invalid() }
        return CodexOwnedSession(configuration: configuration, cwd: cwd,
            acquireAccess: { try await self.access(configuration: configuration, cwd: cwd, installation: installation) },
            accountSnapshot: { try await self.accountSnapshot(configuration: configuration) })
    }
    /// Call after Engine-local reservation and complete runtime drain, before
    /// vault mutation. A different app process's live child causes a busy error.
    public func beginMutation(instanceID: UUID) async throws -> CodexRuntimeAdmissionLease {
        try await CodexRuntimeAdmission.acquireMutation(instanceID: instanceID, root: lockRoot)
    }
    private func access(configuration: CodexRuntimeConfiguration, cwd: URL,
                        installation: CodexInstallation) async throws -> CodexOwnedSessionAccess {
        try configuration.validate()
        guard configuration.authenticationMode == .ownedChatGPT, let binding = configuration.accountBinding,
              let sharedHome = configuration.homeDirectory else { throw CodexAccountError.signInRequired }
        let admission = try await CodexRuntimeAdmission.acquireRuntime(instanceID: configuration.instanceID, root: lockRoot)
        do {
            let credential = try await components(instanceID: configuration.instanceID).vault.access(binding: binding)
            try Task.checkCancellation(); try admission.validate()
            let sharedURL = URL(fileURLWithPath: sharedHome, isDirectory: true)
            let continuationPath = try CodexHomeLayout.resolvedPathForAdmission(sharedURL)
            let overlay = homesRoot.appendingPathComponent(configuration.instanceID.uuidString.lowercased(), isDirectory: true)
                .appendingPathComponent(binding.generation.uuidString.lowercased(), isDirectory: true)
                .appendingPathComponent(SHA256.hash(data: Data(continuationPath.utf8)).map { String(format: "%02x", $0) }.joined(), isDirectory: true)
            let layout = try await admission.prepareHome(generation: binding.generation,
                sharedHome: sharedURL, overlayHome: overlay)
            try Task.checkCancellation(); try admission.validate()
            let revision: UUID
            if let previous = revisions[configuration.instanceID]?[binding], previous.accessToken == credential.accessToken { revision = previous.id }
            else {
                revision = UUID()
                // Token identity is private memory only. It is never a persisted
                // configuration, event, hash, log value or externally shown revision.
                revisions[configuration.instanceID, default: [:]][binding] = .init(accessToken: credential.accessToken, id: revision)
            }
            let launch = try CodexOwnedRuntimeLaunch.make(layout: layout, credential: credential,
                baseEnvironment: ProcessChannel.environment(), now: now())
            let ticket = CodexOwnedLaunchTicket(configuration: configuration, cwd: cwd, installation: installation,
                admission: admission, layout: layout, launch: launch, revision: revision)
            return .init(credentialRevision: revision, resolve: { try await ticket.resolve() }, release: { await ticket.release() })
        } catch { admission.release(); throw error }
    }
    private func accountSnapshot(configuration: CodexRuntimeConfiguration) async throws -> CodexAccountSnapshot {
        try configuration.validate()
        guard configuration.authenticationMode == .ownedChatGPT, let binding = configuration.accountBinding else { throw CodexAccountError.signInRequired }
        let admission = try await CodexRuntimeAdmission.acquireRuntime(instanceID: configuration.instanceID, root: lockRoot)
        defer { admission.release() }
        let credential = try await components(instanceID: configuration.instanceID).vault.access(binding: binding)
        try Task.checkCancellation(); try admission.validate()
        return .init(identity: .init(kind: .chatgpt, requiresOpenAIAuth: false, email: credential.identity.email,
            accountID: binding.profileID.uuidString.lowercased()), usage: .unsupported, checkedAt: now())
    }
}

/// A ticket pins the already refreshed credential and admission. Its one-use
/// resolve transfers the runtime lease to the child resource; releasing the
/// spent ticket cannot unlock a still-running native child.
private actor CodexOwnedLaunchTicket {
    let configuration: CodexRuntimeConfiguration
    let cwd: URL
    let installation: CodexInstallation
    let layout: CodexHomeLayout.Prepared
    let launch: CodexOwnedRuntimeLaunch
    let revision: UUID
    private var admission: CodexRuntimeAdmissionLease?
    private var used = false
    init(configuration: CodexRuntimeConfiguration, cwd: URL, installation: CodexInstallation,
         admission: CodexRuntimeAdmissionLease, layout: CodexHomeLayout.Prepared,
         launch: CodexOwnedRuntimeLaunch, revision: UUID) {
        self.configuration = configuration; self.cwd = cwd; self.installation = installation
        self.admission = admission; self.layout = layout; self.launch = launch; self.revision = revision
    }
    func resolve() throws -> CodexOwnedSessionResource {
        guard !used, let admission else { throw CancellationError() }
        try Task.checkCancellation(); try admission.validate(); try CodexHomeLayout.validate(layout)
        let binary = try installation.acquire(configuration: configuration)
        do {
            let session = try CodexSession(executable: binary.resolved.executable, cwd: cwd,
                arguments: launch.arguments, environment: launch.environment, installationLease: binary,
                runtimeConfiguration: configuration)
            used = true; self.admission = nil
            return .init(session: session, credentialRevision: revision, release: { admission.release() })
        } catch { binary.release(); throw error }
    }
    func release() { admission?.release(); admission = nil; used = true }
    deinit { admission?.release() }
}
