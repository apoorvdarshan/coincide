import Foundation

/// Pi (`@earendil-works/pi-coding-agent`), driven through `pi --mode rpc`.
///
/// Pi signs in to many model providers (subscriptions through `/login`, or API keys), so "signed in"
/// means it lists at least one usable model. Models are discovered by asking a short-lived RPC process.
@MainActor
public final class PiProvider: AgentProvider {
    public let kind: ProviderKind = .pi
    public let executableNames = ["pi"]
    public let setupHint = String(
        localized: "Install Pi with `npm install -g --ignore-scripts @earendil-works/pi-coding-agent`, then run `pi` and sign in with /login.")

    typealias VersionProbe = @MainActor (_ executable: URL, _ environment: [String: String]) async -> ProcessRunner.Result
    typealias DiscoveryTransport = @MainActor (_ executable: URL, _ environment: [String: String]) -> PiTransport

    private struct Discovery {
        var executable: URL
        var date: Date
        /// Nil when discovery failed or Pi's inventory was malformed.
        var models: [ModelOption]?
    }

    private let probeVersion: VersionProbe
    private let discoveryTransport: DiscoveryTransport
    private let discoveryTimeout: Duration
    /// `detect` discovers models and `models` follows right after, so one discovery serves both.
    private var lastDiscovery: Discovery?

    public convenience init() {
        self.init(
            probeVersion: { executable, environment in
                await ProcessRunner.run(executable, ["--version"], environment: environment, timeout: 10)
            },
            discoveryTransport: { executable, environment in
                // An in-memory session in the home folder, so no project configuration is involved.
                PiProcessTransport(
                    executable: executable, arguments: ["--mode", "rpc", "--no-session"],
                    workingDirectory: FileManager.default.homeDirectoryForCurrentUser, environment: environment)
            })
    }

    init(probeVersion: @escaping VersionProbe, discoveryTransport: @escaping DiscoveryTransport, discoveryTimeout: Duration = .seconds(30)) {
        self.probeVersion = probeVersion
        self.discoveryTransport = discoveryTransport
        self.discoveryTimeout = discoveryTimeout
    }

    public func detect(executable: URL?, environment: [String: String]) async -> ProviderStatus {
        guard let executable else { return ProviderStatus(state: .notInstalled, message: setupHint) }
        let probe = await probeVersion(executable, environment)
        let version = PiModels.version(in: probe.stdout + "\n" + probe.stderr)
        guard probe.succeeded else {
            var message = String(localized: "Pi is installed but `pi --version` failed.")
            if let detail = PiText.nonEmpty(probe.stderr) { message += "\n" + PiText.summary(detail, limit: 200) }
            return ProviderStatus(state: .error, version: version, executable: executable, message: message)
        }
        guard let version else {
            return ProviderStatus(
                state: .error, executable: executable,
                message: String(localized: "Coincide could not tell which Pi version is installed. Pi \(PiModels.minimumVersion) or newer is required."))
        }
        guard PiModels.isSupported(version: version) else {
            return ProviderStatus(
                state: .error, version: version, executable: executable,
                message: String(localized: "Pi \(version) is too old. Update to Pi \(PiModels.minimumVersion) or newer with `pi update`."))
        }
        let discovered: (models: [ModelOption]?, providers: [String])
        do {
            discovered = try await discover(executable: executable, environment: environment)
        } catch {
            return ProviderStatus(
                state: .ready, version: version, executable: executable,
                message: String(localized: "Pi is available, but Coincide could not load its models. Sessions still start with Pi’s default model."))
        }
        guard let models = discovered.models else {
            return ProviderStatus(
                state: .ready, version: version, executable: executable,
                message: String(localized: "Pi is available, but its model list could not be read."))
        }
        // The list always starts with "Default"; anything after it is a model Pi can use.
        guard models.count > 1 else {
            return ProviderStatus(
                state: .notAuthenticated, version: version, executable: executable,
                message: String(localized: "Pi has no usable models. Run `pi` in a terminal and sign in with /login, or set a provider’s API key."))
        }
        return ProviderStatus(
            state: .ready, version: version, executable: executable, account: discovered.providers.joined(separator: ", "))
    }

    public func models(status: ProviderStatus, environment: [String: String]) async -> [ModelOption] {
        guard let executable = status.executable else { return PiModels.fallback }
        if let lastDiscovery, lastDiscovery.executable == executable, Date().timeIntervalSince(lastDiscovery.date) < 60 {
            return lastDiscovery.models ?? PiModels.fallback
        }
        let models = try? await discover(executable: executable, environment: environment).models
        return models ?? PiModels.fallback
    }

    public func makeSession(_ launch: AgentLaunch) -> AgentSession {
        PiSession(launch: launch)
    }

    /// Asks a short-lived `pi --mode rpc --no-session` for its state and the models it can use.
    private func discover(
        executable: URL, environment: [String: String]
    ) async throws -> (models: [ModelOption]?, providers: [String]) {
        let client = PiRPCClient(transport: discoveryTransport(executable, environment))
        // Nobody can answer a dialog an extension raises in this short-lived process; dismissing it keeps
        // Pi from waiting on it instead of answering.
        client.onEvent = { [weak client] record in
            guard record["type"]?.string == "extension_ui_request", let dialog = PiDialog(record, tool: { _ in nil }) else { return }
            client?.send(dialog.cancellation)
        }
        defer { client.shutDown(grace: .seconds(1)) }
        do {
            try client.start()
            let state = try await client.request(["type": "get_state"], timeout: discoveryTimeout)
            let inventory = try await client.request(["type": "get_available_models"], timeout: discoveryTimeout)
            let models = PiModels.catalog(models: inventory, state: state)
            lastDiscovery = Discovery(executable: executable, date: Date(), models: models)
            return (models, PiModels.providers(in: inventory))
        } catch {
            lastDiscovery = Discovery(executable: executable, date: Date(), models: nil)
            throw error
        }
    }
}
