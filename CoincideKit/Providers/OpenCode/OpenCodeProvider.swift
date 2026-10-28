import Foundation

/// OpenCode 2, driven through `opencode serve` and its HTTP API, as T3 Code does.
///
/// Detection runs `opencode --version`, then asks a pooled server for its models and connected
/// integrations; the same catalog feeds the model picker. Model ids are OpenCode's `provider/model`
/// slugs and efforts are the model's reasoning variants.
public final class OpenCodeProvider: AgentProvider {
    public let kind: ProviderKind = .opencode
    public let executableNames = ["opencode"]
    public let setupHint = String(localized: "Install OpenCode and run `opencode auth login`.")

    /// The catalog from the last detection, reused by `models` right after it.
    private var catalog: (snapshot: OpenCodeCatalog.Snapshot, executable: String, loadedAt: Date)?
    private nonisolated static let catalogLifetime: TimeInterval = 60
    private let usageCredentials: OpenCodeUsageLimits.Credentials
    private let fetchUsage: UsageLimitsFetch
    /// The Go plan's windows from the last check, kept when a later read fails.
    private var usageLimits: UsageLimits?

    public convenience init() {
        self.init(usageCredentials: .live, fetchUsage: UsageLimitsHTTP.live)
    }

    init(usageCredentials: OpenCodeUsageLimits.Credentials, fetchUsage: @escaping UsageLimitsFetch) {
        self.usageCredentials = usageCredentials
        self.fetchUsage = fetchUsage
    }

    /// Checks OpenCode and reads the OpenCode Go plan's usage windows alongside, as T3 Code does.
    public func detect(executable: URL?, environment: [String: String]) async -> ProviderStatus {
        let credentials = usageCredentials
        let fetch = fetchUsage
        async let outcome = executable == nil
            ? UsageLimitsOutcome.unsupported
            : OpenCodeUsageLimits.read(environment: environment, credentials: credentials, fetch: fetch)
        var status = await checkInstallation(executable: executable, environment: environment)
        // Only a ready OpenCode offers models whose usage the windows count.
        usageLimits = status.state == .ready ? (await outcome).resolved(after: usageLimits) : nil
        status.usageLimits = usageLimits
        return status
    }

    private func checkInstallation(executable: URL?, environment: [String: String]) async -> ProviderStatus {
        guard let executable else { return ProviderStatus(state: .notInstalled, message: setupHint) }
        let probe = await ProcessRunner.run(executable, ["--version"], environment: environment, timeout: 10)
        guard probe.succeeded, let version = OpenCodeCatalog.parseVersion(probe.stdout + "\n" + probe.stderr) else {
            let output = (probe.stderr.isEmpty ? probe.stdout : probe.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
            return ProviderStatus(
                state: .error, executable: executable,
                message: output.isEmpty
                    ? String(localized: "`opencode --version` failed.")
                    : String(localized: "`opencode --version` failed: \(output)"))
        }
        guard let major = OpenCodeCatalog.majorVersion(version), major >= 2 else {
            return ProviderStatus(
                state: .error, version: version, executable: executable,
                message: String(localized: "Coincide needs OpenCode 2 or newer. Run `opencode upgrade`."))
        }
        do {
            let snapshot = try await loadCatalog(executable: executable, environment: environment)
            guard !snapshot.models.isEmpty else {
                return ProviderStatus(
                    state: .notAuthenticated, version: version, executable: executable,
                    message: String(localized: "OpenCode lists no models. Run `opencode auth login` to connect a provider."))
            }
            return ProviderStatus(
                state: .ready, version: version, executable: executable, account: snapshot.account,
                message: String(localized: "OpenCode \(version) lists \(snapshot.models.count) models."))
        } catch {
            return ProviderStatus(
                state: .error, version: version, executable: executable,
                message: String(localized: "OpenCode could not list its models: \(error.localizedDescription)"))
        }
    }

    public func models(status: ProviderStatus, environment: [String: String]) async -> [ModelOption] {
        guard let executable = status.executable else { return OpenCodeCatalog.fallbackModels }
        if let catalog, catalog.executable == executable.path, Date().timeIntervalSince(catalog.loadedAt) < Self.catalogLifetime,
            !catalog.snapshot.models.isEmpty
        {
            return catalog.snapshot.models
        }
        let models = (try? await loadCatalog(executable: executable, environment: environment))?.models ?? []
        return models.isEmpty ? OpenCodeCatalog.fallbackModels : models
    }

    public func makeSession(_ launch: AgentLaunch) -> AgentSession {
        OpenCodeSession(launch: launch)
    }

    private func loadCatalog(executable: URL, environment: [String: String]) async throws -> OpenCodeCatalog.Snapshot {
        let lease = try await OpenCodeServerPool.shared.borrow(executable: executable, environment: environment)
        defer { lease.release() }
        let snapshot = try await OpenCodeCatalog.load(
            api: lease.server.api, directory: FileManager.default.homeDirectoryForCurrentUser.path)
        catalog = (snapshot, executable.path, Date())
        return snapshot
    }
}
