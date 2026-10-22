import Foundation

public enum CodexAuthenticationPhase: String, Sendable {
    case idle, starting, waitingForBrowser, verifying, committing, succeeded, sharingRequired, signedOut
    case cancelling, failed, cancelled, expired, unconfirmed
    public var isWorking: Bool { [.starting, .waitingForBrowser, .verifying, .committing, .cancelling].contains(self) }
}

/// Ephemeral Settings state only. Browser URLs and account labels never enter
/// workspace persistence, command fingerprints, or synthesized debug output.
public struct CodexAuthenticationState: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let instanceID: UUID
    public let flowID: UUID?
    public let phase: CodexAuthenticationPhase
    public let authorizationURL: URL?
    public let expiresAt: Date?
    public let overview: CodexAccountOverview?
    public let message: String?
    public var canCancel: Bool { phase.isWorking && phase != .committing && phase != .cancelling }
    public init(instanceID: UUID, flowID: UUID? = nil, phase: CodexAuthenticationPhase = .idle,
                authorizationURL: URL? = nil, expiresAt: Date? = nil, overview: CodexAccountOverview? = nil, message: String? = nil) {
        self.instanceID = instanceID; self.flowID = flowID; self.phase = phase; self.authorizationURL = authorizationURL
        self.expiresAt = expiresAt; self.overview = overview; self.message = message
    }
    public var description: String { "CodexAuthenticationState(\(phase.rawValue), redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// Owns the complete explicit account mutation, including joined cleanup. The
/// injected Engine lease fences every credential-bound workspace admission.
public actor CodexAuthentication {
    public typealias BeginLease = @Sendable (UUID) async throws -> UUID
    public typealias EndLease = @Sendable (UUID) async -> Void
    public typealias Apply = @Sendable (CodexAccountOverview) async throws -> Void
    public typealias Invalidate = @Sendable () async -> Void
    public typealias ListenerFactory = @Sendable () async throws -> any CodexOAuthCallbackListener
    public typealias AuthorizationHandler = @Sendable (CodexOAuthAuthorization) async throws -> Void
    private enum Action: Equatable {
        case signIn(UUID?, Bool), activate(UUID), signOut(UUID)
    }
    private final class Flow {
        let id = UUID()
        let action: Action
        let expiresAt: Date
        var task: Task<Void, Never>?
        var deadline: Task<Void, Never>?
        var callbackTask: Task<String, any Error>?
        var lease: UUID?
        var listener: (any CodexOAuthCallbackListener)?
        var authorization: CodexOAuthAuthorization?
        var cancellation: CodexAuthenticationPhase?
        var mutationStarted = false
        var published = false
        var applyStarted = false
        var before: CodexAccountOverview?
        var observed: CodexAccountOverview?
        init(action: Action, expiresAt: Date) { self.action = action; self.expiresAt = expiresAt }
    }
    private let instanceID: UUID
    private let hostID: UUID
    private let vault: CodexAccountVault
    private let client: CodexOAuthClient
    private let listenerFactory: ListenerFactory
    private let authorizationHandler: AuthorizationHandler
    private let beginLease: BeginLease
    private let endLease: EndLease
    private let apply: Apply
    private let invalidate: Invalidate
    private let timeout: Duration
    private var active: Flow?
    private var closed = false
    private var observers: [UUID: AsyncStream<CodexAuthenticationState>.Continuation] = [:]
    public private(set) var state: CodexAuthenticationState

    public init(instanceID: UUID, hostID: UUID, vault: CodexAccountVault, client: CodexOAuthClient,
                listenerFactory: ListenerFactory? = nil,
                authorizationHandler: @escaping AuthorizationHandler, timeout: Duration = .seconds(300),
                beginLease: @escaping BeginLease, endLease: @escaping EndLease, apply: @escaping Apply,
                invalidate: @escaping Invalidate) {
        self.instanceID = instanceID; self.hostID = hostID; self.vault = vault; self.client = client
        self.listenerFactory = listenerFactory ?? { try await CodexOAuthLoopback.start() }
        self.authorizationHandler = authorizationHandler
        self.beginLease = beginLease; self.endLease = endLease; self.apply = apply; self.invalidate = invalidate
        self.timeout = min(max(timeout, .milliseconds(1)), .seconds(300))
        state = .init(instanceID: instanceID)
    }
    public func updates() -> AsyncStream<CodexAuthenticationState> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            observers[id] = continuation; continuation.yield(state)
            continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
        }
    }
    @discardableResult public func start(profileID: UUID? = nil, requiresConsent: Bool = false) throws -> UUID {
        try begin(.signIn(profileID, requiresConsent))
    }
    @discardableResult public func activate(profileID: UUID) throws -> UUID { try begin(.activate(profileID)) }
    @discardableResult public func signOut(profileID: UUID) throws -> UUID { try begin(.signOut(profileID)) }

    public func cancel(flowID: UUID) async {
        guard let flow = active, flow.id == flowID else { return }
        // Publication/apply is a joined commit boundary. Its actual state wins
        // over a late Cancel; no old credential or binding is restored.
        if flow.applyStarted { await flow.task?.value; return }
        flow.cancellation = .cancelled; flow.deadline?.cancel(); flow.task?.cancel(); flow.callbackTask?.cancel()
        publish(flow, phase: .cancelling)
        if let listener = flow.listener { await listener.close() }
        await flow.task?.value
    }
    public func shutdown() async {
        closed = true
        if let flow = active { await cancel(flowID: flow.id) }
        for continuation in observers.values { continuation.finish() }; observers = [:]
    }
    private func begin(_ action: Action) throws -> UUID {
        guard !closed else { throw CodexAccountError.busy }
        if let active {
            if active.action == action && active.cancellation == nil { return active.id }
            throw CodexAccountError.busy
        }
        let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
        let flow = Flow(action: action, expiresAt: Date().addingTimeInterval(seconds))
        active = flow; publish(flow, phase: .starting)
        flow.task = Task { await self.run(flow.id) }
        let timeout = timeout
        flow.deadline = Task {
            do { try await Task.sleep(for: timeout) } catch { return }
            await self.expire(flow.id)
        }
        return flow.id
    }
    private func run(_ id: UUID) async {
        guard let flow = active, flow.id == id else { return }
        var terminal: CodexAuthenticationPhase = .failed, message: String?
        do {
            // The lease is first: no vault preparation, discovery, listener,
            // browser, or credential work may get ahead of Engine admission.
            flow.lease = try await beginLease(instanceID)
            try requireCurrent(flow)
            flow.before = try await vault.overview()
            try requireCurrent(flow)
            switch flow.action {
            case .signIn(let profileID, let consent):
                let preparation = try await vault.prepare(profileID: profileID)
                try requireCurrent(flow)
                let listener = try await listenerFactory(); flow.listener = listener
                try requireCurrent(flow)
                let authorization = try await client.authorization(redirectURI: listener.redirectURI, hostID: hostID,
                    clientID: preparation.clientID, expectedSubject: preparation.expectedSubject,
                    loginHint: preparation.loginHint, requiresConsent: consent)
                flow.authorization = authorization
                try requireCurrent(flow)
                let client = client
                flow.callbackTask = Task { try await listener.receive { await client.validates(callbackURL: $0, authorization: authorization) } }
                publish(flow, phase: .waitingForBrowser, authorizationURL: authorization.authorizationURL)
                try await authorizationHandler(authorization)
                try requireCurrent(flow)
                guard let callbackTask = flow.callbackTask else { throw CodexOAuthError(.invalidCallback) }
                let callback = try await callbackTask.value
                try requireCurrent(flow)
                publish(flow, phase: .verifying)
                flow.mutationStarted = true
                flow.observed = try await vault.exchange(preparation: preparation, authorization: authorization, callbackURL: callback)
                flow.published = true
                // A received credential can be committed despite cancellation;
                // the vault decides whether the inactive target was activated.
                flow.observed = try await currentOverview()
                try await applyPublished(flow)
                guard let overview = flow.observed else { throw CodexAccountError.invalidRecord }
                let oldIDs = Set(flow.before?.profiles.map(\.id) ?? [])
                let target = overview.profiles.first { $0.id == preparation.profileID || (preparation.profileID == nil && !oldIDs.contains($0.id)) }
                if target?.sharingEnabled == false {
                    terminal = .sharingRequired
                    message = "ChatGPT sign-in was verified, but token sharing is disabled. Reconnect and enable token sharing before using this account."
                } else if let cancellation = flow.cancellation {
                    terminal = cancellation
                    message = overview.binding?.profileID == target?.id
                        ? "The verified account change was saved before cancellation. Current account settings were refreshed."
                        : "The verified connection was saved without changing the active account. Select it when you are ready."
                } else if target?.id == overview.binding?.profileID, target?.sharingEnabled == true {
                    terminal = .succeeded; message = "ChatGPT sign-in complete."
                } else {
                    terminal = .unconfirmed; message = Self.unconfirmedMessage
                    await invalidateJoined()
                }
            case .activate(let profileID):
                try requireCurrent(flow); flow.mutationStarted = true
                flow.observed = try await vault.activate(profileID: profileID); flow.published = true
                flow.observed = try await currentOverview(); try await applyPublished(flow)
                guard flow.observed?.binding?.profileID == profileID else { throw CodexAccountError.staleAccount }
                terminal = flow.cancellation ?? .succeeded
                message = flow.cancellation == nil ? "The selected ChatGPT account is active." : "The selected account was saved before cancellation. Current account settings were refreshed."
            case .signOut(let profileID):
                try requireCurrent(flow); flow.mutationStarted = true
                let outcome = try await vault.logout(profileID: profileID); flow.published = true
                flow.observed = try await currentOverview(); try await applyPublished(flow)
                guard flow.observed?.profiles.first(where: { $0.id == profileID })?.hasCredential == false else { throw CodexAccountError.staleAccount }
                terminal = .signedOut
                message = outcome == .confirmed ? "Signed out of this ChatGPT connection."
                    : "Signed out locally. Remote revocation could not be confirmed. Disconnect the app in ChatGPT Settings."
            }
        } catch {
            if flow.mutationStarted {
                // A thrown result after write admission is not proof of rollback.
                // Read under a fresh uncancelled task and retain the actual vault.
                do { flow.observed = try await currentOverview() } catch { }
                let changed = Self.credentialAccessChanged(before: flow.before, after: flow.observed)
                if flow.published || changed || !Self.provenUnchanged(error) {
                    terminal = .unconfirmed; message = Self.unconfirmedMessage
                    await invalidateJoined()
                } else {
                    terminal = flow.cancellation ?? Self.failurePhase(error)
                    message = Self.failureMessage(error, phase: terminal)
                }
            } else {
                terminal = flow.cancellation ?? Self.failurePhase(error)
                message = Self.failureMessage(error, phase: terminal)
            }
        }
        // Keep the lease through the listener's exact descriptor join, callback
        // task/network completion, attempt retirement, and config invalidation.
        flow.callbackTask?.cancel()
        if let listener = flow.listener { await listener.close() }
        if let callbackTask = flow.callbackTask { _ = await callbackTask.result }
        if let authorization = flow.authorization { await client.cancel(authorization) }
        flow.deadline?.cancel()
        if let lease = flow.lease { await endLease(lease) }
        publish(flow, phase: terminal, message: message)
        if active === flow { active = nil }
    }
    private func applyPublished(_ flow: Flow) async throws {
        guard let observed = flow.observed else { throw CodexAccountError.invalidRecord }
        flow.applyStarted = true; flow.deadline?.cancel()
        publish(flow, phase: .committing)
        let apply = apply
        try await Task.detached { try await apply(observed) }.value
    }
    private func currentOverview() async throws -> CodexAccountOverview {
        let vault = vault
        return try await Task.detached { try await vault.overview() }.value
    }
    private func invalidateJoined() async {
        let invalidate = invalidate
        await Task.detached { await invalidate() }.value
    }
    private func expire(_ id: UUID) async {
        guard let flow = active, flow.id == id, !flow.applyStarted else { return }
        flow.cancellation = .expired; flow.task?.cancel(); flow.callbackTask?.cancel()
        publish(flow, phase: .cancelling)
        if let listener = flow.listener { await listener.close() }
        await flow.task?.value
    }
    private func requireCurrent(_ flow: Flow) throws {
        guard active === flow, !Task.isCancelled, flow.cancellation == nil else { throw CancellationError() }
    }
    private func publish(_ flow: Flow, phase: CodexAuthenticationPhase, authorizationURL: URL? = nil, message: String? = nil) {
        guard active === flow else { return }
        state = .init(instanceID: instanceID, flowID: flow.id, phase: phase, authorizationURL: authorizationURL,
            expiresAt: phase.isWorking ? flow.expiresAt : nil, overview: flow.observed ?? flow.before ?? state.overview, message: message)
        for continuation in observers.values { continuation.yield(state) }
    }
    private func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }
    private static let unconfirmedMessage = "The account change was saved or may have changed, but current app access could not be confirmed. Refresh the account before continuing."
    private static func credentialAccessChanged(before: CodexAccountOverview?, after: CodexAccountOverview?) -> Bool {
        guard let before, let after else { return true }
        guard before.binding == after.binding else { return true }
        let old = Dictionary(uniqueKeysWithValues: before.profiles.map { ($0.id, $0) })
        let current = Dictionary(uniqueKeysWithValues: after.profiles.map { ($0.id, $0) })
        for profile in before.profiles {
            guard let observed = current[profile.id], observed.hasCredential == profile.hasCredential,
                  observed.requiresReconnect == profile.requiresReconnect, observed.sharingEnabled == profile.sharingEnabled,
                  observed.isActive == profile.isActive else { return true }
        }
        // An authorization-issued registration with an expired first code has
        // no credential or execution authority. Saving it for reconnect is not
        // an uncertain replacement of a previously usable account.
        return after.profiles.contains { old[$0.id] == nil && ($0.hasCredential || $0.sharingEnabled || $0.isActive) }
    }
    private static func provenUnchanged(_ error: any Error) -> Bool {
        if let oauth = error as? CodexOAuthError { return !oauth.mayHaveChangedCredentials }
        if error is CancellationError { return true }
        if let account = error as? CodexAccountError { return [.busy, .staleAccount, .signInRequired, .sharingRequired, .profileLimit].contains(account) }
        return false
    }
    private static func failurePhase(_ error: any Error) -> CodexAuthenticationPhase {
        if error is CancellationError || (error as? CodexOAuthError)?.kind == .cancelled { return .cancelled }
        if let oauth = error as? CodexOAuthError, [.expired, .codeExpired].contains(oauth.kind) { return .expired }
        return .failed
    }
    private static func failureMessage(_ error: any Error, phase: CodexAuthenticationPhase) -> String {
        if phase == .cancelled { return "ChatGPT sign-in cancelled. The previous account was kept." }
        if phase == .expired {
            if (error as? CodexOAuthError)?.kind == .codeExpired {
                return "The sign-in code expired. Reconnect the saved ChatGPT connection to start a fresh sign-in."
            }
            return "ChatGPT sign-in expired. Start again."
        }
        if let oauth = error as? CodexOAuthError { return oauth.localizedDescription }
        if let account = error as? CodexAccountError { return account.localizedDescription }
        return "The Codex account operation could not be completed. Try again."
    }
}
