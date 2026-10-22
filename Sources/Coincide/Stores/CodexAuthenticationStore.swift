import CoincideCore
import Foundation
import Observation

/// Owns transient account presentation only. The controller owns admission,
/// credential publication and joined cancellation; this store never persists
/// account labels, authorization URLs or credentials.
@MainActor @Observable final class CodexAuthenticationStore {
    struct Client: Sendable {
        let id: UUID
        let instanceID: UUID
        let state: @Sendable () async -> CodexAuthenticationState
        let updates: @Sendable () async -> AsyncStream<CodexAuthenticationState>
        let overview: @Sendable () async throws -> CodexAccountOverview
        let start: @Sendable (UUID?, Bool) async throws -> UUID
        let activate: @Sendable (UUID) async throws -> UUID
        let signOut: @Sendable (UUID) async throws -> UUID
        let cancel: @Sendable (UUID) async -> Void
        let shutdown: @Sendable () async -> Void

        init(instanceID: UUID, controller: CodexAuthentication, vault: CodexAccountVault) {
            self.init(instanceID: instanceID, state: { await controller.state },
                updates: { await controller.updates() }, overview: { try await vault.overview() },
                start: { try await controller.start(profileID: $0, requiresConsent: $1) },
                activate: { try await controller.activate(profileID: $0) },
                signOut: { try await controller.signOut(profileID: $0) },
                cancel: { await controller.cancel(flowID: $0) }, shutdown: { await controller.shutdown() })
        }
        init(id: UUID = UUID(), instanceID: UUID,
             state: @escaping @Sendable () async -> CodexAuthenticationState,
             updates: @escaping @Sendable () async -> AsyncStream<CodexAuthenticationState>,
             overview: @escaping @Sendable () async throws -> CodexAccountOverview,
             start: @escaping @Sendable (UUID?, Bool) async throws -> UUID,
             activate: @escaping @Sendable (UUID) async throws -> UUID,
             signOut: @escaping @Sendable (UUID) async throws -> UUID,
             cancel: @escaping @Sendable (UUID) async -> Void,
             shutdown: @escaping @Sendable () async -> Void) {
            self.id = id; self.instanceID = instanceID; self.state = state; self.updates = updates
            self.overview = overview; self.start = start; self.activate = activate
            self.signOut = signOut; self.cancel = cancel; self.shutdown = shutdown
        }
    }

    private(set) var configuration: CodexRuntimeConfiguration
    private(set) var state: CodexAuthenticationState
    private(set) var overview: CodexAccountOverview?
    private(set) var errorMessage: String?
    private(set) var isRefreshing = false
    private(set) var isStarting = false
    private(set) var isCancelling = false
    @ObservationIgnored private var client: Client?
    @ObservationIgnored private var boundConfiguration: CodexRuntimeConfiguration?
    @ObservationIgnored private var observer: Task<Void, Never>?
    @ObservationIgnored private var refresh: Task<CodexAccountOverview, any Error>?
    @ObservationIgnored private var reads: [UUID: Task<CodexAccountOverview, any Error>] = [:]
    @ObservationIgnored private var refreshID: UUID?
    @ObservationIgnored private var bindingID = UUID()
    @ObservationIgnored private var action: Task<Void, Never>?
    @ObservationIgnored private var closed = false
    @ObservationIgnored private var shutdownTask: Task<Void, Never>?

    init(configuration: CodexRuntimeConfiguration = .init(), client: Client? = nil) {
        self.configuration = configuration; state = .init(instanceID: configuration.instanceID)
        if let client, client.instanceID == configuration.instanceID {
            self.client = client; boundConfiguration = configuration
            observe(client, epoch: bindingID)
        }
    }

    /// Replacing a controller is an explicit joined lifecycle boundary. Root
    /// publication must call updateConfiguration instead of awaiting this from
    /// that same controller's apply callback.
    func bind(client replacement: Client, configuration: CodexRuntimeConfiguration) async {
        guard !closed, replacement.instanceID == configuration.instanceID else { return }
        if client?.id == replacement.id {
            updateConfiguration(configuration); return
        }
        let epoch = UUID(); bindingID = epoch
        let previous = client, reading = Array(reads.values), observing = observer, starting = action
        client = nil; boundConfiguration = nil; refreshID = nil
        refresh = nil; observer = nil; reading.forEach { $0.cancel() }; observing?.cancel()
        if let previous { await previous.shutdown() }
        for read in reading { _ = try? await read.value }
        await observing?.value; await starting?.value
        guard !closed, bindingID == epoch else { await replacement.shutdown(); return }
        self.configuration = configuration; state = .init(instanceID: configuration.instanceID)
        overview = nil; errorMessage = nil; isRefreshing = false; isStarting = false; isCancelling = false
        client = replacement; boundConfiguration = configuration
        observe(replacement, epoch: epoch)
    }

    /// Safe during a controller's apply callback: no controller cancellation,
    /// shutdown, Keychain access or provider I/O occurs here.
    func updateConfiguration(_ configuration: CodexRuntimeConfiguration) {
        guard !closed, self.configuration != configuration else { return }
        let sameScope = Self.sameControllerScope(self.configuration, configuration)
        self.configuration = configuration
        refreshID = nil; reads.values.forEach { $0.cancel() }; isRefreshing = false
        overview = nil; errorMessage = nil
        if !sameScope { state = .init(instanceID: configuration.instanceID) }
    }

    var profiles: [CodexAccountProfile] { overview?.profiles ?? [] }
    var isWorking: Bool { isStarting || isCancelling || state.phase.isWorking }
    var canStart: Bool {
        !closed && !isWorking && !isRefreshing && controllerIsCurrent &&
        configuration.authenticationMode == .ownedChatGPT && configuration.homeDirectory != nil &&
        (try? configuration.validate()) != nil
    }
    var canRefresh: Bool { !closed && !isWorking && !isRefreshing && controllerIsCurrent && configuration.authenticationMode == .ownedChatGPT }
    var canCancel: Bool { !closed && controllerIsCurrent && !isCancelling && state.canCancel && state.flowID != nil }
    var authorizationURL: URL? {
        guard !closed, controllerIsCurrent, state.phase == .waitingForBrowser, state.flowID != nil,
              let expires = state.expiresAt, expires > Date(), let url = state.authorizationURL,
              url.absoluteString.utf8.count <= 16_384,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "https", parts.host == "auth.openai.com", parts.port == nil || parts.port == 443,
              parts.user == nil, parts.password == nil, parts.fragment == nil,
              parts.path == "/api/accounts/authorize" else { return nil }
        return url
    }
    var statusText: String {
        switch state.phase {
        case .idle:
            if let binding = overview?.binding, binding == configuration.accountBinding,
               profiles.contains(where: { $0.id == binding.profileID && $0.hasCredential && $0.sharingEnabled && !$0.requiresReconnect }) {
                String(localized: "A saved ChatGPT account is selected.")
            } else if overview?.binding != nil {
                String(localized: "The saved account differs from this connection. Choose Use Account before sending with it.")
            } else { String(localized: "Sign in or refresh the saved ChatGPT accounts.") }
        case .starting: String(localized: "Preparing ChatGPT sign-in…")
        case .waitingForBrowser: String(localized: "Continue ChatGPT sign-in in your browser.")
        case .verifying: String(localized: "Verifying the ChatGPT account…")
        case .committing: String(localized: "Saving the account change…")
        case .succeeded: String(localized: "ChatGPT account change saved")
        case .sharingRequired: String(localized: "Reconnect and enable token sharing")
        case .signedOut: String(localized: "Signed out of this ChatGPT connection")
        case .cancelling: String(localized: "Stopping ChatGPT sign-in…")
        case .failed: String(localized: "ChatGPT account change could not finish")
        case .cancelled: String(localized: "ChatGPT account change cancelled")
        case .expired: String(localized: "ChatGPT sign-in expired")
        case .unconfirmed: String(localized: "ChatGPT account change is unconfirmed")
        }
    }

    func refreshAccounts() async {
        guard canRefresh, let client else { return }
        let id = UUID(), epoch = bindingID, captured = configuration
        refreshID = id; isRefreshing = true; errorMessage = nil
        let task = Task { try await client.overview() }; refresh = task; reads[id] = task
        defer {
            reads.removeValue(forKey: id)
            if refreshID == id { refreshID = nil; refresh = nil; isRefreshing = false }
        }
        do {
            let value = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try Task.checkCancellation()
            guard !closed, bindingID == epoch, refreshID == id, configuration == captured, !task.isCancelled else { return }
            overview = value
        } catch {
            guard !closed, bindingID == epoch, refreshID == id, !(error is CancellationError) else { return }
            errorMessage = String(localized: "The saved ChatGPT accounts could not be refreshed. Check account storage and try again.")
        }
    }

    func startSignIn() async { await perform { try await $0.start(nil, false) } }
    func reconnect(profileID: UUID) async {
        guard profiles.contains(where: { $0.id == profileID }) else { return }
        await perform { try await $0.start(profileID, true) }
    }
    func selectProfile(_ profileID: UUID) async {
        guard canSelectProfile(profileID) else { return }
        await perform { try await $0.activate(profileID) }
    }
    func isSelectedProfile(_ profileID: UUID) -> Bool {
        overview?.binding == configuration.accountBinding && configuration.accountBinding?.profileID == profileID
    }
    func canSelectProfile(_ profileID: UUID) -> Bool {
        canStart && profiles.contains(where: {
            $0.id == profileID && $0.hasCredential && $0.sharingEnabled && !$0.requiresReconnect && !isSelectedProfile(profileID)
        })
    }
    func signOut(profileID: UUID) async {
        guard profiles.contains(where: { $0.id == profileID && ($0.hasCredential || $0.requiresReconnect) }) else { return }
        await perform { try await $0.signOut(profileID) }
    }
    func cancel() async {
        guard canCancel, let client, let flow = state.flowID else { return }
        isCancelling = true; defer { isCancelling = false }
        await client.cancel(flow)
    }
    func shutdown() async {
        if let shutdownTask { await shutdownTask.value; return }
        closed = true; bindingID = UUID(); refreshID = nil
        let client = client, reading = Array(reads.values), starting = action, observing = observer
        self.client = nil; reading.forEach { $0.cancel() }; observing?.cancel()
        let task = Task { [self] in
            if let client { await client.shutdown() }
            for read in reading { _ = try? await read.value }
            await starting?.value; await observing?.value
            refresh = nil; action = nil; observer = nil; overview = nil
            state = .init(instanceID: configuration.instanceID)
            isRefreshing = false; isStarting = false; isCancelling = false
        }
        shutdownTask = task; await task.value
    }

    private var controllerIsCurrent: Bool {
        guard client?.instanceID == configuration.instanceID, let boundConfiguration else { return false }
        return Self.sameControllerScope(boundConfiguration, configuration)
    }
    static func sameControllerScope(_ lhs: CodexRuntimeConfiguration, _ rhs: CodexRuntimeConfiguration) -> Bool {
        lhs.instanceID == rhs.instanceID && lhs.selection == rhs.selection && lhs.executable == rhs.executable &&
        lhs.homeDirectory == rhs.homeDirectory && lhs.authenticationMode == rhs.authenticationMode
    }
    private func perform(_ operation: @escaping @Sendable (Client) async throws -> UUID) async {
        guard canStart, let client else { return }
        isStarting = true; errorMessage = nil
        let epoch = bindingID
        let task = Task<Void, Never> { [weak self] in
            do {
                _ = try await operation(client)
                let observed = await client.state()
                self?.receive(observed, epoch: epoch)
            }
            catch {
                guard let self, !self.closed, self.bindingID == epoch, !(error is CancellationError) else { return }
                self.errorMessage = String(localized: "The ChatGPT account action could not start. Finish the current operation and review the selected runtime.")
            }
        }
        action = task; await task.value
        if bindingID == epoch { isStarting = false; action = nil }
    }
    private func observe(_ client: Client, epoch: UUID) {
        observer = Task { [weak self] in
            let initial = await client.state()
            self?.receive(initial, epoch: epoch)
            let updates = await client.updates()
            for await value in updates {
                guard !Task.isCancelled else { break }
                self?.receive(value, epoch: epoch)
            }
        }
    }
    private func receive(_ value: CodexAuthenticationState, epoch: UUID) {
        guard !closed, bindingID == epoch, controllerIsCurrent, value.instanceID == configuration.instanceID else { return }
        state = value
        // A terminal flow still owns its phase and URL cleanup even if the
        // vault's active account differs from this saved connection. Withhold
        // mismatched identity presentation instead of retaining a working UI.
        if let value = value.overview { overview = value.binding == configuration.accountBinding ? value : nil }
    }
}
