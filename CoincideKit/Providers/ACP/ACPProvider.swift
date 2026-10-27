import Foundation

/// Agents that speak the Agent Client Protocol and differ only in how they are launched.
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
        case .antigravity: ["agy_acp_server.par", "agy_acp_server"]
        }
    }

    public nonisolated var setupHint: String {
        switch self {
        case .grok: String(localized: "Install the Grok Build CLI and run `grok login`.")
        case .antigravity:
            String(
                localized:
                    "Install Google's Antigravity ACP agent (agy_acp_server with its localharness_external helper) from the ACP Registry, then put it on PATH or choose it in Settings."
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

    /// Models `grok models` listed during the last `detect`.
    private var listedModels: [GrokCLI.ListedModel] = []

    public init(profile: ACPProfile) {
        self.profile = profile
    }

    public func detect(executable: URL?, environment: [String: String]) async -> ProviderStatus {
        guard let executable else { return ProviderStatus(state: .notInstalled, message: setupHint) }
        switch profile {
        case .grok: return await detectGrok(executable, environment)
        case .antigravity: return detectAntigravity(executable)
        }
    }

    public func models(status: ProviderStatus, environment: [String: String]) async -> [ModelOption] {
        switch profile {
        case .grok:
            var listed = listedModels
            if listed.isEmpty, let executable = status.executable, status.state == .ready {
                listed = await Self.listGrokModels(executable, environment)?.models ?? []
            }
            let cacheURL = GrokCLI.home(environment).appendingPathComponent("models_cache.json")
            let cache = FileManager.default.contents(atPath: cacheURL.path).map(GrokCLI.parseModelsCache) ?? [:]
            return GrokCLI.modelOptions(listed: listed, cache: cache)
        case .antigravity:
            // Google decides per account; the session reports the real list once it starts.
            return [
                ModelOption(
                    provider: .antigravity, modelID: AntigravityFlavor.defaultModelID, displayName: String(localized: "Default"))
            ]
        }
    }

    public func makeSession(_ launch: AgentLaunch) -> AgentSession {
        ACPSession(launch: launch, flavor: profile.flavor)
    }

    // MARK: Grok

    private func detectGrok(_ executable: URL, _ environment: [String: String]) async -> ProviderStatus {
        let started = Date()
        let versionRun = await ProcessRunner.run(executable, ["--version"], environment: Self.probeEnvironment(environment), timeout: 5)
        let version = GrokCLI.version(from: versionRun.stdout + "\n" + versionRun.stderr)
        guard versionRun.succeeded else {
            // ProcessRunner stops a process that outlives its timeout with SIGTERM.
            let timedOut = versionRun.status == SIGTERM && Date().timeIntervalSince(started) >= 5
            return ProviderStatus(
                state: .error, version: version, executable: executable,
                message: timedOut
                    ? String(localized: "Grok CLI is installed but timed out while running `grok --version`.")
                    : String(localized: "Grok CLI is installed but failed to run."))
        }
        let usesAPIKey = environment[GrokFlavor.apiKeyVariable]?.trimmingCharacters(in: .whitespaces).isEmpty == false
        var listing = await Self.listGrokModels(executable, environment)
        // An expired token prints the logged-out line while the CLI refreshes it; ask once more.
        if listing?.authenticated == false, !usesAPIKey, let recheck = await Self.listGrokModels(executable, environment),
            recheck.authenticated != nil
        {
            listing = recheck
        }
        listedModels = listing?.models ?? []
        if usesAPIKey {
            return ProviderStatus(state: .ready, version: version, executable: executable, account: String(localized: "xAI API key"))
        }
        if listing?.authenticated == false {
            return ProviderStatus(
                state: .notAuthenticated, version: version, executable: executable,
                message: String(localized: "Grok CLI is installed but not logged in. Run `grok login`."))
        }
        let authURL = GrokCLI.home(environment).appendingPathComponent("auth.json")
        let email = FileManager.default.contents(atPath: authURL.path).flatMap(GrokCLI.accountEmail(authJSON:))
        let account = email ?? (listing?.authenticated == true ? String(localized: "Grok account") : nil)
        return ProviderStatus(state: .ready, version: version, executable: executable, account: account)
    }

    /// `grok models` reports the sign-in state and model ids without starting the agent.
    /// Only a clean exit is parsed; failures print help text that is not a model list.
    private nonisolated static func listGrokModels(_ executable: URL, _ environment: [String: String]) async -> GrokCLI.ModelsOutput? {
        let run = await ProcessRunner.run(executable, ["models"], environment: probeEnvironment(environment), timeout: 10)
        guard run.succeeded else { return nil }
        return GrokCLI.parseModels(run.stdout + "\n" + run.stderr)
    }

    /// Keeps probes from starting Grok's self-updater.
    private nonisolated static func probeEnvironment(_ environment: [String: String]) -> [String: String] {
        var environment = environment
        environment["GROK_DISABLE_AUTOUPDATER"] = "1"
        return environment
    }

    // MARK: Antigravity

    /// The agent unpacks about a gigabyte on every launch, so detection never starts it.
    private func detectAntigravity(_ executable: URL) -> ProviderStatus {
        let harness = AntigravityFlavor.harnessURL(for: executable)
        guard FileManager.default.isExecutableFile(atPath: harness.path) else {
            return ProviderStatus(
                state: .error, executable: executable,
                message: String(
                    localized:
                        "Antigravity's \(AntigravityFlavor.harnessName) helper is missing next to \(executable.lastPathComponent). Install both files from the same release."
                ))
        }
        return ProviderStatus(
            state: .ready, executable: executable, message: String(localized: "Google sign-in is checked when a session starts."))
    }
}
