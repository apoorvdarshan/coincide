import Foundation

/// Agents that speak the Agent Client Protocol. Each one is a small `ACPAgentFlavor`; see its
/// documentation for how to add another.
public enum ACPProfile: String, Sendable, CaseIterable {
    case grok
    case antigravity
    case fx

    public nonisolated var kind: ProviderKind {
        switch self {
        case .grok: .grok
        case .antigravity: .antigravity
        case .fx: .fx
        }
    }

    public nonisolated var executableNames: [String] {
        switch self {
        case .grok: ["grok"]
        case .fx: ["fx"]
        // Google's ACP agent ships as `agy_acp_server.par` beside its `localharness_external` helper.
        // The runtime Coincide downloaded comes first, as T3 Code prefers it to one on PATH (a custom
        // path in Settings still wins).
        case .antigravity:
            Self.managedAntigravityExecutable().map { [$0.path] + Self.antigravityNames } ?? Self.antigravityNames
        }
    }

    nonisolated static let antigravityNames = ["agy_acp_server.par", "agy_acp_server"]

    /// The downloaded Antigravity executable, when one is installed.
    nonisolated static func managedAntigravityExecutable(paths: AntigravityPaths = .standard) -> URL? {
        let executable = paths.managedExecutable
        return FileManager.default.isExecutableFile(atPath: executable.path) ? executable : nil
    }

    public nonisolated var setupHint: String {
        switch self {
        case .grok: String(localized: "Install the Grok Build CLI and run `grok login`.")
        case .antigravity:
            String(
                localized:
                    "Install Antigravity below to download Google’s runtime, then sign in with Google. To use your own copy instead, choose agy_acp_server (with its localharness_external helper beside it) as the custom path."
            )
        case .fx: String(localized: "Install fx and run `fx login`.")
        }
    }

    @MainActor public var flavor: ACPAgentFlavor {
        switch self {
        case .grok: GrokFlavor()
        case .antigravity: AntigravityFlavor()
        case .fx: FxFlavor()
        }
    }
}

/// Finds, probes and launches an ACP agent CLI.
@MainActor
public final class ACPProvider: AgentProvider {
    public let profile: ACPProfile
    public var kind: ProviderKind { profile.kind }
    public var executableNames: [String] { profile.executableNames }
    public var setupHint: String { profile.setupHint }

    /// Models the last probe listed and the model its default stands for, with the executable it probed.
    private var probed: (executable: URL, models: [ModelOption], defaultModel: String?)?
    /// The plan's usage windows the last check read, with the account they belong to.
    private var checkedUsageLimits: (account: String?, limits: UsageLimits)?
    private let makeFlavor: @MainActor () -> ACPAgentFlavor

    public convenience init(profile: ACPProfile) {
        self.init(profile: profile, flavor: { profile.flavor })
    }

    /// `flavor` replaces the profile's in tests.
    init(profile: ACPProfile, flavor: @escaping @MainActor () -> ACPAgentFlavor) {
        self.profile = profile
        makeFlavor = flavor
    }

    public func detect(executable: URL?, environment: [String: String]) async -> ProviderStatus {
        guard let executable else {
            probed = nil
            checkedUsageLimits = nil
            return ProviderStatus(state: .notInstalled, message: setupHint)
        }
        let flavor = makeFlavor()
        let probe = await flavor.probe(executable: executable, environment: environment)
        probed = (executable, probe.models, probe.defaultModel)
        var status = probe.status
        // Like T3 Code, only a ready agent's limits are read. A failed read keeps what the last check of the same
        // account read; another account, or one without limits to read, starts afresh.
        guard status.state == .ready, let outcome = await flavor.usageLimits(environment: environment) else {
            checkedUsageLimits = nil
            return status
        }
        let previous = checkedUsageLimits.flatMap { $0.account == status.account ? $0.limits : nil }
        status.usageLimits = outcome.resolved(after: previous)
        checkedUsageLimits = status.usageLimits.map { (status.account, $0) }
        return status
    }

    public func models(status: ProviderStatus, environment: [String: String]) async -> [ModelOption] {
        let flavor = makeFlavor()
        if let probed, probed.executable == status.executable, !probed.models.isEmpty { return probed.models }
        if let executable = status.executable, status.state == .ready || status.state == .notAuthenticated {
            let models = await flavor.probe(executable: executable, environment: environment).models
            if !models.isEmpty { return models }
        }
        return flavor.offlineModels(environment: environment)
    }

    public func makeSession(_ launch: AgentLaunch) -> AgentSession {
        // The default model is read when a turn starts, so a later check's answer applies (T3 Code reads its snapshot).
        ACPSession(
            launch: launch, flavor: makeFlavor(),
            defaultModel: { [weak self] in self?.probed.flatMap { $0.executable == launch.executable ? $0.defaultModel : nil } })
    }

    public func skills(workingDirectory: URL, environment: [String: String]) async -> [ProviderSkill] {
        await makeFlavor().skills(workingDirectory: workingDirectory, environment: environment)
    }
}
