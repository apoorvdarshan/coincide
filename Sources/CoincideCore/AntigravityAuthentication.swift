import Foundation
import Darwin

public protocol AntigravityAuthenticationSession: Sendable {
    func authenticate() async throws -> [ProviderModel]
    func logout() async throws
    func healthCheck() async throws -> JSONValue
    func close() async
    func discardOwnedProfile() async
}

public extension AntigravityAuthenticationSession {
    func discardOwnedProfile() async {}
}

extension AntigravitySession: AntigravityAuthenticationSession {}

public enum AntigravityAuthenticationPhase: String, Sendable {
    case idle, starting, waitingForBrowser, verifying, committing, succeeded, signedOut
    case cancelling, failed, cancelled, expired, unconfirmed
    public var isWorking: Bool {
        [.starting, .waitingForBrowser, .verifying, .committing, .cancelling].contains(self)
    }
}

/// Transient presentation only. Authorization URLs and runtime credentials are
/// deliberately not Codable and never belong to a workspace snapshot.
public struct AntigravityAuthenticationState: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let flowID: UUID?
    public let phase: AntigravityAuthenticationPhase
    public let configuration: AntigravityConfiguration?
    public let authorization: AntigravityAuthorizationURL?
    public let expiresAt: Date?
    public let models: [ProviderModel]
    public let message: String?
    public var canCancel: Bool { phase.isWorking && phase != .committing && phase != .cancelling }
    public var description: String { "AntigravityAuthenticationState(\(phase.rawValue), <redacted>)" }
    public var debugDescription: String { description }
    public init(flowID: UUID? = nil, phase: AntigravityAuthenticationPhase = .idle,
                configuration: AntigravityConfiguration? = nil, authorization: AntigravityAuthorizationURL? = nil,
                expiresAt: Date? = nil, models: [ProviderModel] = [], message: String? = nil) {
        self.flowID = flowID; self.phase = phase; self.configuration = configuration
        self.authorization = authorization; self.expiresAt = expiresAt; self.models = models; self.message = message
    }
}

public actor AntigravityAuthentication {
    public typealias AuthorizationHandler = @Sendable (AntigravityAuthorizationURL) async throws -> Void
    public typealias SessionFactory = @Sendable (AntigravityConfiguration, AntigravityRuntimeCredential?, AuthorizationHandler?) async throws -> any AntigravityAuthenticationSession
    public typealias BeginLease = @Sendable (UUID) async throws -> UUID
    public typealias EndLease = @Sendable (UUID) async -> Void
    public typealias Apply = @Sendable (AntigravityConfiguration) async throws -> Void

    private final class Flow {
        let id: UUID
        let source: AntigravityConfiguration
        let staged: AntigravityConfiguration
        let signingOut: Bool
        let credential: AntigravityRuntimeCredential?
        let expiresAt: Date
        var lease: UUID?
        var session: (any AntigravityAuthenticationSession)?
        var task: Task<Void, Never>?
        var deadline: Task<Void, Never>?
        var cancellation: AntigravityAuthenticationPhase?
        var wroteCredential = false
        var applyStarted = false
        var logoutStarted = false
        init(id: UUID, source: AntigravityConfiguration, staged: AntigravityConfiguration,
             signingOut: Bool, credential: AntigravityRuntimeCredential?, expiresAt: Date) {
            self.id = id; self.source = source; self.staged = staged; self.signingOut = signingOut
            self.credential = credential; self.expiresAt = expiresAt
        }
    }
    private let sessionFactory: SessionFactory
    private let credentials: AntigravityCredentialAccess
    private let beginLease: BeginLease
    private let endLease: EndLease
    private let apply: Apply
    private let invalidateAccess: Apply
    private let timeout: Duration
    private var active: Flow?
    private var closed = false
    private var observers: [UUID: AsyncStream<AntigravityAuthenticationState>.Continuation] = [:]
    private var probes: [UUID: Task<JSONValue, any Error>] = [:]
    public private(set) var state = AntigravityAuthenticationState()

    public init(sessionFactory: @escaping SessionFactory = AntigravityAuthentication.nativeSessionFactory(),
                credentials: AntigravityCredentialAccess = .keychain,
                timeout: Duration = .seconds(300), invalidateAccess: Apply? = nil, beginLease: @escaping BeginLease,
                endLease: @escaping EndLease, apply: @escaping Apply) {
        self.sessionFactory = sessionFactory; self.credentials = credentials
        self.timeout = min(max(timeout, .milliseconds(1)), .seconds(300))
        self.beginLease = beginLease; self.endLease = endLease; self.apply = apply
        self.invalidateAccess = invalidateAccess ?? { _ in }
    }

    public func updates() -> AsyncStream<AntigravityAuthenticationState> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            observers[id] = continuation; continuation.yield(state)
            continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
        }
    }

    @discardableResult public func start(configuration: AntigravityConfiguration, apiKey: String? = nil,
                                        reuseStoredCredential: Bool = false) throws -> UUID {
        guard !closed, active == nil else { throw busy() }
        try configuration.validate()
        let credential: AntigravityRuntimeCredential?
        if configuration.authMethod.usesBrowser { credential = nil }
        else if let apiKey { credential = apiKey.isEmpty ? nil : try AntigravityRuntimeCredential(apiKey: apiKey) }
        else { credential = reuseStoredCredential ? try credentials.read(configuration) : nil }
        guard configuration.authMethod != .geminiAPIKey || credential != nil,
              configuration.authMethod != .agentPlatform || credential != nil ||
                (configuration.gcpProject != nil && configuration.gcpLocation != nil) else {
            throw CoincideError("Provide the selected Antigravity account method's credential or project and location.")
        }
        return begin(configuration, credential: credential, signingOut: false)
    }

    @discardableResult public func signOut(configuration: AntigravityConfiguration) throws -> UUID {
        guard !closed, active == nil else { throw busy() }
        try configuration.validate()
        let credential = try credentials.read(configuration)
        return begin(configuration, credential: credential, signingOut: true)
    }

    public func cancel(flowID: UUID) async {
        guard let flow = active, flow.id == flowID, !flow.applyStarted else { return }
        flow.cancellation = .cancelled; flow.deadline?.cancel(); flow.task?.cancel()
        publish(flow, phase: .cancelling)
        if let session = flow.session { await session.close() }
        await flow.task?.value
    }

    /// This uses a separate empty profile and never authenticates, reads a stored
    /// key, reconfigures a working account, or opens a browser.
    public func checkRuntime(configuration: AntigravityConfiguration) async throws -> JSONValue {
        guard !closed, active == nil else { throw busy() }
        let probe = AntigravityConfiguration(instanceID: configuration.instanceID, runtimeSelection: configuration.runtimeSelection, executable: configuration.executable,
            harnessPath: configuration.harnessPath, authGeneration: UUID())
        try probe.validate()
        let id = UUID(), factory = sessionFactory
        let task = Task<JSONValue, any Error> {
            let session = try await factory(probe, nil, nil)
            do {
                try Task.checkCancellation()
                let result = try await withTaskCancellationHandler { try await session.healthCheck() }
                    onCancel: { Task { await session.close() } }
                await session.close(); await session.discardOwnedProfile(); try Task.checkCancellation(); return result
            } catch { await session.close(); await session.discardOwnedProfile(); throw error }
        }
        probes[id] = task
        defer { probes.removeValue(forKey: id) }
        do { return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() } }
        catch is CancellationError { throw CancellationError() }
        catch { throw CoincideError("The Antigravity runtime could not be checked. Verify the server and its sibling harness.") }
    }

    public func shutdown() async {
        closed = true
        if let flow = active {
            if flow.applyStarted { await flow.task?.value } else { await cancel(flowID: flow.id) }
        }
        let tasks = Array(probes.values)
        for task in tasks { task.cancel() }
        for task in tasks { _ = try? await task.value }
        for continuation in observers.values { continuation.finish() }
        observers.removeAll()
    }

    private func begin(_ source: AntigravityConfiguration, credential: AntigravityRuntimeCredential?, signingOut: Bool) -> UUID {
        let id = UUID(), seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
        let staged = AntigravityConfiguration(instanceID: source.instanceID, runtimeSelection: source.runtimeSelection, executable: source.executable,
            harnessPath: source.harnessPath, authMethod: source.authMethod, gcpProject: source.gcpProject,
            gcpLocation: source.gcpLocation, authGeneration: UUID(), model: source.model)
        let flow = Flow(id: id, source: source, staged: staged, signingOut: signingOut,
                        credential: credential, expiresAt: Date().addingTimeInterval(seconds))
        active = flow; publish(flow, phase: .starting)
        flow.task = Task { await self.run(id) }
        let timeout = timeout
        flow.deadline = Task {
            do { try await Task.sleep(for: timeout) } catch { return }
            await self.expire(id)
        }
        return id
    }

    private func run(_ id: UUID) async {
        guard let flow = active, flow.id == id else { return }
        var result: [ProviderModel] = [], terminal: AntigravityAuthenticationPhase = .failed
        var message: String?
        do {
            let ownedProbes = Array(probes.values)
            for task in ownedProbes { task.cancel() }
            for task in ownedProbes { _ = try? await task.value }
            try requireCurrent(id)
            flow.lease = try await beginLease(flow.source.instanceID)
            try requireCurrent(id)
            if !flow.signingOut, let credential = flow.credential {
                try credentials.write(credential, flow.staged); flow.wroteCredential = true
            }
            let configuration = flow.signingOut ? flow.source : flow.staged
            let handler: AuthorizationHandler?
            if flow.signingOut { handler = nil }
            else {
                handler = { [weak self] authorization in
                    guard let self else { throw CancellationError() }
                    try await self.receive(authorization, id: id)
                }
            }
            let session = try await sessionFactory(configuration, flow.credential, handler)
            flow.session = session
            try requireCurrent(id)
            if flow.signingOut { flow.logoutStarted = true; try await session.logout() }
            else {
                result = try await session.authenticate()
                guard !result.isEmpty else { throw CoincideError("No Antigravity models are available for this account.") }
            }
            try requireCurrent(id); publish(flow, phase: .verifying)
            await session.close(); try requireCurrent(id)
            flow.applyStarted = true; flow.deadline?.cancel(); publish(flow, phase: .committing)
            try await apply(flow.staged)
            if flow.signingOut { try credentials.remove(flow.source) }
            terminal = flow.signingOut ? .signedOut : .succeeded
        } catch {
            if let cancellation = flow.cancellation {
                terminal = flow.logoutStarted ? .unconfirmed : cancellation
                if flow.logoutStarted { message = "Antigravity sign-out could not be confirmed. It was not repeated. Check the account before continuing." }
            }
            else if flow.applyStarted {
                terminal = .unconfirmed
                message = "Antigravity access changed, but the saved account change could not be confirmed. Check the account configuration before trying again."
            } else {
                terminal = flow.logoutStarted ? .unconfirmed : .failed
                message = flow.signingOut
                    ? "Antigravity sign-out could not be confirmed. It was not repeated. Check the account before continuing."
                    : "Antigravity could not verify this account and its available models. Check the selected method and try again."
            }
        }
        flow.deadline?.cancel()
        if let session = flow.session {
            await session.close()
            if !flow.signingOut && !flow.applyStarted { await session.discardOwnedProfile() }
        }
        if flow.signingOut && terminal == .unconfirmed {
            // A lost/cancelled logout may already have revoked the native account.
            // Downgrade only that exact source while the instance lease is held.
            do { try await invalidateAccess(flow.source) }
            catch { message = "Antigravity sign-out and its saved access state are unconfirmed. Check account settings before continuing." }
        }
        if flow.wroteCredential && !flow.applyStarted {
            do { try credentials.remove(flow.staged) }
            catch { message = "The staged Antigravity credential could not be removed from Keychain. The working account was not replaced." }
        }
        if let lease = flow.lease { await endLease(lease) }
        guard active?.id == id else { return }
        publish(flow, phase: terminal, models: terminal == .succeeded ? result : [], message: message)
        active = nil
    }

    private func receive(_ authorization: AntigravityAuthorizationURL, id: UUID) throws {
        try requireCurrent(id)
        guard let flow = active, flow.staged.authMethod.usesBrowser else { throw busy() }
        if let current = state.authorization, current.authorizationURL != authorization.authorizationURL { throw busy() }
        publish(flow, phase: .waitingForBrowser, authorization: authorization)
    }
    private func expire(_ id: UUID) async {
        guard let flow = active, flow.id == id, !flow.applyStarted else { return }
        flow.cancellation = .expired; flow.task?.cancel(); publish(flow, phase: .cancelling)
        if let session = flow.session { await session.close() }
        await flow.task?.value
    }
    private func requireCurrent(_ id: UUID) throws {
        try Task.checkCancellation()
        guard let flow = active, flow.id == id, flow.cancellation == nil else { throw CancellationError() }
    }
    private func publish(_ flow: Flow, phase: AntigravityAuthenticationPhase,
                         authorization: AntigravityAuthorizationURL? = nil, models: [ProviderModel] = [], message: String? = nil) {
        state = .init(flowID: flow.id, phase: phase, configuration: flow.staged,
                      authorization: authorization, expiresAt: phase.isWorking ? flow.expiresAt : nil, models: models, message: message)
        for continuation in observers.values { continuation.yield(state) }
    }
    private func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }
    private func busy() -> CoincideError { .init("Antigravity account setup is already running or stopping. Wait for it to finish.") }

    public static func nativeSessionFactory(stateRoot: URL = AntigravityRuntime.defaultStateRoot,
                                           installation: AntigravityInstallation = .shared) -> SessionFactory {
        { configuration, credential, handler in
            try AntigravityOwnedAuthenticationSession(configuration: configuration, credential: credential, handler: handler, stateRoot: stateRoot, installation: installation)
        }
    }
}

private actor AntigravityOwnedAuthenticationSession: AntigravityAuthenticationSession {
    private let session: AntigravitySession
    private let workspace: URL
    private var closeTask: Task<Void, Never>?
    private let ownedProfile: AntigravityOwnedProfile?
    init(configuration: AntigravityConfiguration, credential: AntigravityRuntimeCredential?,
         handler: AntigravityAuthentication.AuthorizationHandler?, stateRoot: URL, installation: AntigravityInstallation) throws {
        let pair = try AntigravityRuntime.resolvePair(configuration: configuration, installation: installation)
        let profile = try AntigravityRuntime.profileDirectory(configuration: configuration, stateRoot: stateRoot)
        ownedProfile = try AntigravityOwnedProfile.reserve(profile)
        let root = stateRoot.appendingPathComponent("AuthenticationWorkspaces", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let workspace = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        self.workspace = workspace
        session = AntigravitySession(executable: pair.executable, cwd: workspace, configuration: configuration,
            credentialProvider: { credential }, authorizationURLHandler: handler, stateRoot: stateRoot, installation: installation)
    }
    func authenticate() async throws -> [ProviderModel] { try await session.authenticate() }
    func logout() async throws { try await session.logout() }
    func healthCheck() async throws -> JSONValue { try await session.healthCheck() }
    func discardOwnedProfile() async { await close(); ownedProfile?.remove() }
    func close() async {
        if let closeTask { await closeTask.value; return }
        let session = session, workspace = workspace
        let task = Task { await session.close(); try? FileManager.default.removeItem(at: workspace) }
        closeTask = task; await task.value
    }
}

/// A freshly reserved generation is deleted through its retained descriptor.
/// Symlinks in provider-created content are unlinked, never followed.
private final class AntigravityOwnedProfile: @unchecked Sendable {
    private let parent: Int32, directory: Int32, name: String
    private let identity: stat
    private let lock = NSLock()
    private var removed = false
    private init(parent: Int32, directory: Int32, name: String, identity: stat) {
        self.parent = parent; self.directory = directory; self.name = name; self.identity = identity
    }
    deinit { Darwin.close(directory); Darwin.close(parent) }
    static func reserve(_ url: URL) throws -> AntigravityOwnedProfile? {
        let manager = FileManager.default, parentURL = url.deletingLastPathComponent()
        try manager.createDirectory(at: parentURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let parent = open(parentURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw AntigravityConfiguration.invalid() }
        guard mkdirat(parent, url.lastPathComponent, 0o700) == 0 else {
            let exists = errno == EEXIST; Darwin.close(parent)
            if exists { return nil }; throw AntigravityConfiguration.invalid()
        }
        let fd = openat(parent, url.lastPathComponent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        var info = stat()
        guard fd >= 0, fstat(fd, &info) == 0 else {
            if fd >= 0 { Darwin.close(fd) }; Darwin.close(parent); throw AntigravityConfiguration.invalid()
        }
        return .init(parent: parent, directory: fd, name: url.lastPathComponent, identity: info)
    }
    func remove() {
        lock.lock(); defer { lock.unlock() }
        guard !removed else { return }; removed = true
        var current = stat(), remaining = 8_192
        guard fstatat(parent, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
              current.st_dev == identity.st_dev, current.st_ino == identity.st_ino,
              Self.empty(directory, depth: 0, remaining: &remaining) else { return }
        guard fstatat(parent, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
              current.st_dev == identity.st_dev, current.st_ino == identity.st_ino else { return }
        _ = unlinkat(parent, name, AT_REMOVEDIR)
    }
    private static func empty(_ fd: Int32, depth: Int, remaining: inout Int) -> Bool {
        guard depth < 32, let stream = fdopendir(dup(fd)) else { return false }
        defer { closedir(stream) }
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            remaining -= 1; guard remaining >= 0 else { return false }
            var info = stat()
            guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return false }
            if info.st_mode & S_IFMT == S_IFDIR {
                let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard child >= 0 else { return false }
                var opened = stat(); let matches = fstat(child, &opened) == 0 && opened.st_ino == info.st_ino && opened.st_dev == info.st_dev
                let emptied = matches && empty(child, depth: depth + 1, remaining: &remaining)
                Darwin.close(child)
                var latest = stat()
                guard emptied, fstatat(fd, name, &latest, AT_SYMLINK_NOFOLLOW) == 0,
                      latest.st_ino == info.st_ino, latest.st_dev == info.st_dev,
                      unlinkat(fd, name, AT_REMOVEDIR) == 0 else { return false }
            } else {
                guard unlinkat(fd, name, 0) == 0 else { return false }
            }
        }
        return true
    }
}
