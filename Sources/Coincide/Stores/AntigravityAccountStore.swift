import CoincideCore
import Foundation
import Observation

@MainActor @Observable final class AntigravityAccountStore {
    enum AgentPlatformCredentialMode: String, CaseIterable, Identifiable {
        case project, apiKey
        var id: Self { self }
    }
    private(set) var configuration: AntigravityConfiguration
    private(set) var accessState: AntigravityAccountRegistry.AccessState?
    private(set) var state = AntigravityAuthenticationState()
    private(set) var errorMessage: String?
    private var runtimeObservation: AntigravityConfiguration?
    private(set) var isCheckingRuntime = false
    private var isStarting = false
    var executable: String
    var harnessPath: String
    var runtimeSelection: AntigravityRuntimeSelection
    var authMethod: AntigravityAuthMethod
    var gcpProject: String
    var gcpLocation: String
    var apiKey = ""
    var reuseStoredCredential = false
    var agentPlatformCredentialMode: AgentPlatformCredentialMode = .project
    @ObservationIgnored private let registryRoot: URL
    @ObservationIgnored private let sessionFactory: AntigravityAuthentication.SessionFactory
    @ObservationIgnored private let credentials: AntigravityCredentialAccess
    @ObservationIgnored private let timeout: Duration
    @ObservationIgnored private var authentication: AntigravityAuthentication?
    @ObservationIgnored private var observer: Task<Void, Never>?
    @ObservationIgnored private var runtimeRead: Task<Void, Never>?
    @ObservationIgnored private var signingOut = false
    @ObservationIgnored private var isClosed = false

    init(stateRoot: URL? = nil,
         sessionFactory: @escaping AntigravityAuthentication.SessionFactory = AntigravityAuthentication.nativeSessionFactory(),
         credentials: AntigravityCredentialAccess = .keychain, timeout: Duration = .seconds(300)) {
        let root = stateRoot ?? AntigravityAccountRegistry.defaultRoot
        registryRoot = root; self.sessionFactory = sessionFactory; self.credentials = credentials; self.timeout = timeout
        let record: AntigravityAccountRegistry.Record?
        do { record = try AntigravityAccountRegistry.load(rootURL: root) }
        catch { record = nil; errorMessage = String(localized: "The saved Antigravity account could not be loaded. Check its configuration before signing in.") }
        let config = record?.configuration ?? AntigravityConfiguration(runtimeSelection: .managed)
        configuration = config; accessState = record?.accessState
        runtimeSelection = config.runtimeSelection
        executable = config.executable; harnessPath = config.harnessPath ?? ""; authMethod = config.authMethod
        gcpProject = config.gcpProject ?? ""; gcpLocation = config.gcpLocation ?? ""
        if config.authMethod == .agentPlatform, config.gcpProject == nil { agentPlatformCredentialMode = .apiKey }
    }

    var isWorking: Bool { isStarting || isCheckingRuntime || state.phase.isWorking }
    var runtimeConfiguration: AntigravityConfiguration? {
        let trim: (String) -> String = { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let candidate = AntigravityConfiguration(instanceID: configuration.instanceID, runtimeSelection: runtimeSelection,
            executable: runtimeSelection == .managed ? "agy_acp_server.par" : trim(executable),
            harnessPath: runtimeSelection == .managed || trim(harnessPath).isEmpty ? nil : trim(harnessPath), authGeneration: UUID())
        do { try candidate.validate(); return candidate } catch { return nil }
    }
    var runtimeChecked: Bool {
        guard let observed = runtimeObservation, let current = runtimeConfiguration else { return false }
        return observed.runtimeSelection == current.runtimeSelection && observed.executable == current.executable && observed.harnessPath == current.harnessPath
    }
    var canReuseStoredCredential: Bool {
        !authMethod.usesBrowser && accessState == .verified &&
        selectedConfiguration?.runtimeIdentity == configuration.runtimeIdentity &&
        (authMethod != .agentPlatform || agentPlatformCredentialMode == .apiKey)
    }
    var selectedConfiguration: AntigravityConfiguration? {
        let needsProject = authMethod == .oauthBusiness || (authMethod == .agentPlatform && agentPlatformCredentialMode == .project)
        let trim: (String) -> String = { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let candidate = AntigravityConfiguration(instanceID: configuration.instanceID, runtimeSelection: runtimeSelection,
            executable: runtimeSelection == .managed ? "agy_acp_server.par" : trim(executable),
            harnessPath: runtimeSelection == .managed || trim(harnessPath).isEmpty ? nil : trim(harnessPath), authMethod: authMethod,
            gcpProject: needsProject && !trim(gcpProject).isEmpty ? trim(gcpProject) : nil,
            gcpLocation: needsProject && !trim(gcpLocation).isEmpty ? trim(gcpLocation) : nil,
            authGeneration: configuration.authGeneration, model: configuration.model)
        do { try candidate.validate(); return candidate } catch { return nil }
    }
    var requiresAPIKey: Bool { authMethod == .geminiAPIKey || (authMethod == .agentPlatform && agentPlatformCredentialMode == .apiKey) }
    var canStart: Bool {
        authentication != nil && !isWorking && selectedConfiguration != nil &&
        (!requiresAPIKey || !apiKey.isEmpty || (reuseStoredCredential && canReuseStoredCredential))
    }
    var statusText: String {
        switch state.phase {
        case .idle:
            switch accessState {
            case .verified: String(localized: "Access was verified for the saved account. Check access again to refresh it.")
            case .signedOut: String(localized: "Signed out")
            case .pending: String(localized: "The last account update is unconfirmed. Check the account before continuing.")
            case nil: String(localized: "Not signed in")
            }
        case .starting: String(localized: "Preparing account access…")
        case .waitingForBrowser: String(localized: "Use Open Google Sign-In to continue in your browser.")
        case .verifying: String(localized: "Verifying account access…")
        case .committing: String(localized: "Saving the verified account…")
        case .succeeded: String(localized: "Account access and available models verified")
        case .signedOut: String(localized: "Signed out")
        case .cancelling: String(localized: "Stopping account setup…")
        case .cancelled: String(localized: "Account setup cancelled")
        case .expired: String(localized: "Account setup expired after five minutes")
        case .failed: String(localized: "Account access could not be verified")
        case .unconfirmed: String(localized: "Account change unconfirmed")
        }
    }

    func bind(engine: WorkspaceEngine) {
        bind(beginLease: { try await engine.beginAntigravityAuthentication(instanceID: $0) },
             endLease: { await engine.endAntigravityAuthentication(leaseID: $0) },
             apply: { try await engine.applyAntigravityAccountConfiguration($0) })
    }
    /// Injection for native fixtures: no CLI, Keychain, or production registry.
    func bind(beginLease: @escaping AntigravityAuthentication.BeginLease,
              endLease: @escaping AntigravityAuthentication.EndLease,
              apply: @escaping AntigravityAuthentication.Apply) {
        guard authentication == nil, !isClosed else { return }
        let auth = AntigravityAuthentication(sessionFactory: sessionFactory, credentials: credentials, timeout: timeout,
            invalidateAccess: { [weak self] source in try await self?.invalidateAccess(source) },
            beginLease: beginLease, endLease: endLease, apply: { [weak self] candidate in
                guard let self else { throw CancellationError() }
                try await self.commit(candidate, apply: apply)
            })
        authentication = auth
        observer = Task { [weak self] in
            let updates = await auth.updates()
            for await value in updates {
                guard !Task.isCancelled, let self else { return }
                self.state = value
                if let message = value.message { self.errorMessage = message }
            }
        }
    }
    func signIn() async {
        guard canStart, let candidate = selectedConfiguration, let authentication else { return }
        isStarting = true; signingOut = false; errorMessage = nil
        defer { isStarting = false }
        let key: String? = requiresAPIKey ? (apiKey.isEmpty ? nil : apiKey) : ""
        let reuse = requiresAPIKey && reuseStoredCredential && canReuseStoredCredential
        do {
            _ = try await authentication.start(configuration: candidate, apiKey: key, reuseStoredCredential: reuse)
            state = await authentication.state; apiKey = ""; reuseStoredCredential = false
        } catch { errorMessage = String(localized: "Account setup could not start. Check the runtime, selected method and required fields.") }
    }
    func signOut() async {
        guard !isWorking, accessState == .verified, state.phase != .unconfirmed, let authentication else { return }
        isStarting = true; signingOut = true; errorMessage = nil
        defer { isStarting = false }
        do { _ = try await authentication.signOut(configuration: configuration); state = await authentication.state }
        catch { errorMessage = String(localized: "Sign-out could not start. Check the saved account and try again.") }
    }
    func cancel() async {
        guard let id = state.flowID, state.canCancel, let authentication else { return }
        await authentication.cancel(flowID: id); state = await authentication.state
    }
    func checkRuntime() async {
        guard !isWorking, let candidate = runtimeConfiguration, let authentication else { return }
        isCheckingRuntime = true; runtimeObservation = nil; errorMessage = nil
        let task = Task { [weak self] in
            do {
                _ = try await authentication.checkRuntime(configuration: candidate)
                guard !Task.isCancelled else { return }; self?.runtimeObservation = candidate
            } catch is CancellationError {} catch {
                self?.errorMessage = String(localized: "The Antigravity runtime could not be checked. Verify the server and sibling harness.")
            }
        }
        runtimeRead = task; await task.value; runtimeRead = nil; isCheckingRuntime = false
    }
    func shutdown() async {
        isClosed = true; runtimeRead?.cancel()
        await authentication?.shutdown(); await runtimeRead?.value
        observer?.cancel(); await observer?.value
        observer = nil; apiKey = ""
    }
    private func commit(_ candidate: AntigravityConfiguration, apply: AntigravityAuthentication.Apply) async throws {
        // Both durable stores remain inside the instance lease. A lost final ACK
        // leaves the candidate pending, rather than claiming old credentials work.
        try AntigravityAccountRegistry.save(.init(configuration: candidate, accessState: .pending), rootURL: registryRoot)
        configuration = candidate; accessState = .pending
        try await apply(candidate)
        let final: AntigravityAccountRegistry.AccessState = signingOut ? .signedOut : .verified
        try AntigravityAccountRegistry.save(.init(configuration: candidate, accessState: final), rootURL: registryRoot)
        accessState = final
    }
    private func invalidateAccess(_ source: AntigravityConfiguration) throws {
        guard configuration.runtimeIdentity == source.runtimeIdentity,
              let record = try AntigravityAccountRegistry.load(rootURL: registryRoot),
              record.configuration.runtimeIdentity == source.runtimeIdentity else { return }
        accessState = .pending
        try AntigravityAccountRegistry.save(.init(configuration: source, accessState: .pending), rootURL: registryRoot)
    }
}
