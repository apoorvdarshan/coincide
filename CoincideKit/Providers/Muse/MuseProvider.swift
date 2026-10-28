import Foundation

/// Muse Code, Meta's `muse` CLI, driven through `muse serve` (MSP, JSON-RPC over stdio) as T3 Code does. It is off
/// until the user turns it on, as in T3.
///
/// MSP has no sign-in check, and Muse lists its models even when signed out (T3), so finding models means ready; a
/// signed-out account shows when a turn fails. The check reads the version, then asks a short-lived host without
/// shell or file writes for the model catalog and the plan's usage.
@MainActor
public final class MuseProvider: AgentProvider {
    public let kind: ProviderKind = .muse
    public let executableNames = ["muse"]
    public let setupHint = String(localized: "Install Muse Code and run `muse login`.")

    typealias VersionProbe = @MainActor (_ executable: URL, _ environment: [String: String]) async -> ProcessRunner.Result
    typealias ProbeTransport = @MainActor (_ executable: URL, _ environment: [String: String]) -> MuseTransport

    private struct Probe {
        var executable: URL
        var date: Date
        var models: [ModelOption]
        var usage: MuseSubscriptionUsage?
    }

    private let probeVersion: VersionProbe
    private let probeTransport: ProbeTransport
    private let probeTimeout: Duration
    /// `detect` reads the catalog and `models` follows right after, so one read serves both.
    private var lastProbe: Probe?

    public convenience init() {
        self.init(
            probeVersion: { executable, environment in
                await ProcessRunner.run(executable, ["--version"], environment: environment, timeout: 10)
            },
            probeTransport: { executable, environment in
                // The home folder, so no project's configuration is involved.
                MuseProcessTransport(
                    executable: executable, arguments: MuseProtocol.probeArguments,
                    workingDirectory: FileManager.default.homeDirectoryForCurrentUser, environment: environment)
            })
    }

    init(probeVersion: @escaping VersionProbe, probeTransport: @escaping ProbeTransport, probeTimeout: Duration = .seconds(12)) {
        self.probeVersion = probeVersion
        self.probeTransport = probeTransport
        self.probeTimeout = probeTimeout
    }

    /// Without the login shell's `META_API_KEY`, so Muse uses the `muse login` sign-in; a key set for Muse in
    /// Coincide's settings still applies.
    public func inheritedEnvironment(_ environment: [String: String]) -> [String: String] {
        MuseProtocol.environment(inherited: environment)
    }

    public func detect(executable: URL?, environment: [String: String]) async -> ProviderStatus {
        guard let executable else { return ProviderStatus(state: .notInstalled, message: setupHint) }
        let output = await probeVersion(executable, environment)
        let version = MuseProtocol.version(in: output.stdout + "\n" + output.stderr)
        guard output.succeeded else {
            lastProbe = nil
            // What Muse printed is left out: it can carry account details (T3 leaves it out too).
            let message =
                output.stderr.hasSuffix("The command timed out.")
                ? String(localized: "Muse Code did not answer `muse --version` in time.")
                : String(localized: "Muse Code is installed but failed to run. Check its executable path.")
            return ProviderStatus(state: .error, version: version, executable: executable, message: message)
        }
        let probe: Probe
        do {
            probe = try await self.probe(executable: executable, environment: environment)
        } catch {
            return ProviderStatus(
                state: .error, version: version, executable: executable,
                message: String(
                    localized: "Muse Code could not read its model catalog. Check your Muse Code installation and run `muse login`."))
        }
        let limits = probe.usage.map { UsageLimits(windows: $0.windows, checkedAt: Date()) }
        guard !probe.models.isEmpty else {
            return ProviderStatus(
                state: .notAuthenticated, version: version, executable: executable,
                message: String(localized: "Muse Code returned no models. Run `muse login`, then check again."),
                usageLimits: limits)
        }
        return ProviderStatus(state: .ready, version: version, executable: executable, usageLimits: limits)
    }

    /// Muse's catalog. There is no built-in fallback: an empty catalog stays empty, as in T3, and custom models still
    /// show.
    public func models(status: ProviderStatus, environment: [String: String]) async -> [ModelOption] {
        guard let executable = status.executable else { return [] }
        if let lastProbe, lastProbe.executable == executable, Date().timeIntervalSince(lastProbe.date) < 60 {
            return lastProbe.models
        }
        return (try? await probe(executable: executable, environment: environment).models) ?? []
    }

    public func makeSession(_ launch: AgentLaunch) -> AgentSession {
        MuseSession(launch: launch)
    }

    /// Starts a host, reads `model/list` and `usage/read`, and ends it (T3's `discoverMuseModels`).
    private func probe(executable: URL, environment: [String: String]) async throws -> Probe {
        let connection = MuseConnection(transport: probeTransport(executable, environment), ids: .uuidV7())
        try connection.start()
        defer { connection.close() }
        let result = try await connection.request("initialize", MuseProtocol.initializeParams(), timeout: .seconds(8))
        try MuseProtocol.checkInitializeResult(result)
        connection.notify("initialized")
        let list = try await connection.request("model/list", [:], timeout: probeTimeout)
        guard let models = MuseProtocol.models(fromList: list) else {
            throw AgentError.protocolError(String(localized: "Muse Code returned a model catalog of another provider."))
        }
        // The plan's usage is a bonus: a host that cannot say keeps the check ready.
        let usage = (try? await connection.request("usage/read", [:], timeout: .seconds(5))).flatMap {
            MuseSubscriptionUsage($0["usage"])
        }
        let probe = Probe(executable: executable, date: Date(), models: models, usage: usage)
        lastProbe = probe
        return probe
    }
}
