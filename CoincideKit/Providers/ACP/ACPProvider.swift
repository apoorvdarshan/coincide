import Foundation

/// Agents that speak the Agent Client Protocol. Each one is a small `ACPAgentFlavor`; see its
/// documentation for how to add another.
public enum ACPProfile: String, Sendable, CaseIterable {
    case grok
    case antigravity

    public nonisolated var kind: ProviderKind {
        switch self {
        case .grok: .grok
        case .antigravity: .antigravity
        }
    }

    public nonisolated var executableNames: [String] {
        switch self {
        case .grok: ["grok"]
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
        }
    }

    @MainActor public var flavor: ACPAgentFlavor {
        switch self {
        case .grok: GrokFlavor()
        case .antigravity: AntigravityFlavor()
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

    /// Models the last probe listed, with the executable it probed.
    private var probed: (executable: URL, models: [ModelOption])?

    public init(profile: ACPProfile) {
        self.profile = profile
    }

    public func detect(executable: URL?, environment: [String: String]) async -> ProviderStatus {
        guard let executable else {
            probed = nil
            return ProviderStatus(state: .notInstalled, message: setupHint)
        }
        let probe = await profile.flavor.probe(executable: executable, environment: environment)
        probed = (executable, probe.models)
        return probe.status
    }

    public func models(status: ProviderStatus, environment: [String: String]) async -> [ModelOption] {
        let flavor = profile.flavor
        if let probed, probed.executable == status.executable, !probed.models.isEmpty { return probed.models }
        if let executable = status.executable, status.state == .ready || status.state == .notAuthenticated {
            let models = await flavor.probe(executable: executable, environment: environment).models
            if !models.isEmpty { return models }
        }
        return flavor.offlineModels(environment: environment)
    }

    public func makeSession(_ launch: AgentLaunch) -> AgentSession {
        ACPSession(launch: launch, flavor: profile.flavor)
    }
}
