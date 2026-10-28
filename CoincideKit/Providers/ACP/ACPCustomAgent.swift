import Foundation

/// A user-added ACP agent (T3 Code's ACP Registry provider, for both its `registry` and `local` sources): any agent
/// that speaks the Agent Client Protocol over stdio, run through the shared `ACPSession`.
///
/// A local command starts its executable with the user's literal arguments, never through a shell. A registry agent
/// starts the executable Coincide installed, with the registry's arguments and environment; a custom path in
/// Settings replaces only the executable, as T3 Code's executable override does. The agent signs in with its own
/// methods (`ACPAgentSignIn`), and its models, modes and options come from ACP.
///
/// What T3 Code adds for single agents is ported where Coincide has the same hook: Devin's tool names, and Devin's
/// commands running in Coincide's terminals.
struct ACPCustomFlavor: ACPAgentFlavor {
    let config: ACPAgentConfig
    var paths: ACPRegistryPaths = .standard
    /// Leases the installed version a launch runs from; nil uses the shared tools for managed executables.
    var tools: ACPRegistryTools?
    /// Replaces the real process in tests.
    var transport: ACPTransportFactory?
    /// How long a probe waits for each answer (T3 Code's `PROBE_TIMEOUT`).
    var probeTimeout: TimeInterval = 60

    var provider: ProviderKind { config.kind }
    var name: String { config.displayName }
    var registryAgentID: String? { config.source == .registry ? config.registry?.agentID : nil }

    // MARK: Launch

    func arguments(for accessMode: AccessMode) -> [String] { config.launchArguments }

    /// The registry's environment goes over the provider's (as T3 Code merges it), and a package's `bin` folder first
    /// on PATH.
    func environment(_ base: [String: String], executable: URL) -> [String: String] {
        guard config.source == .registry, let install = config.registry else { return base }
        var environment = base.merging(install.environment) { $1 }
        if let bin = install.binDirectory, let components = ACPRegistryPaths.relativeComponents(bin) {
            let directory = components.reduce(paths.versionDirectory(for: install)) { $0.appendingPathComponent($1) }
            environment["PATH"] = ([directory.path] + (environment["PATH"] ?? "").split(separator: ":").map(String.init))
                .joined(separator: ":")
        }
        return environment
    }

    /// Keeps an installed version in place while it runs.
    func prepareLaunch(executable: URL, environment: [String: String]) async throws -> ACPLaunchLease? {
        guard paths.isManaged(executable) else { return nil }
        return (tools ?? ACPRegistryTools.shared).lease(for: executable)
    }

    // MARK: Handshake

    /// Devin runs its commands in Coincide's terminals, as it runs them in T3 Code's.
    var clientCapabilities: ACPClientCapabilities {
        ACPClientCapabilities(terminal: registryAgentID == "devin")
    }

    func authMethodID(environment: [String: String]) -> String? { config.authMethodID }

    // MARK: Presentation

    /// Devin's generic "Tool" titles name the tool in `_meta` (T3 Code's `normalizeDevinToolCall`).
    func normalize(_ toolCall: inout ACPToolCallState) {
        if let name = toolCall.meta?["cognition.ai/inferenceToolName"]?.string.flatMap(ACPToolCallState.nonEmpty),
            toolCall.title.flatMap(ACPToolCallState.nonEmpty) == nil || toolCall.title == "Tool"
        {
            toolCall.title = name
        }
    }

    func message(for error: Error) -> String {
        if let error = error as? ACPError, error.code == ACPError.authRequired {
            return String(localized: "\(name) needs you to sign in. Sign in to it in Settings, then try again.")
        }
        return error.localizedDescription
    }

    // MARK: Detection

    /// Starts the agent once, as T3 Code's probe does: `initialize`, then a test session in an empty folder, which
    /// lists the models and shows whether the agent needs a sign-in. The probe never signs in; elicitations and
    /// permission requests are refused.
    func probe(executable: URL, environment: [String: String]) async -> ACPProbe {
        let models = offlineModels(environment: environment)
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("coincide-acp-probe-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let lease = try? await prepareLaunch(executable: executable, environment: environment)
        let process = ACPHelperProcess(
            executable: executable, arguments: arguments(for: .approval), workingDirectory: workspace,
            environment: self.environment(environment, executable: executable), name: name, transport: transport)
        defer {
            process.stop()
            lease?.release()
            Task {
                await process.waitForExit(timeout: 5)
                try? FileManager.default.removeItem(at: workspace)
            }
        }
        let initialized: ACPInitializeResult
        do {
            try process.start()
            // T3 Code's probe offers no files or terminals: nothing in it runs a tool.
            initialized = try await process.client.initialize(
                capabilities: ACPClientCapabilities(), clientInfo: ACPSession.clientInfo, timeout: probeTimeout)
        } catch {
            return ACPProbe(status: ProviderStatus(state: .error, executable: executable, message: failure(error)), models: models)
        }
        let version = initialized.agentInfo?.version ?? config.registry?.version
        do {
            let setup = try await process.client.newSession(cwd: workspace, timeout: probeTimeout)
            if let id = setup.sessionID, initialized.closeSession {
                process.client.closeSession(id: id, timeout: 2) {}
            }
            let found = self.models(initialize: initialized, setup: setup)
            return ACPProbe(
                status: ProviderStatus(state: .ready, version: version, executable: executable), models: found.isEmpty ? models : found)
        } catch let error as ACPError where error.code == ACPError.authRequired {
            return ACPProbe(
                status: ProviderStatus(
                    state: .notAuthenticated, version: version, executable: executable,
                    message: signInMessage(initialized.authMethods)),
                models: models)
        } catch {
            return ACPProbe(
                status: ProviderStatus(state: .error, version: version, executable: executable, message: failure(error)),
                models: models)
        }
    }

    /// How to sign in, for a probe the agent refused (T3 Code's `authenticationMessage`).
    func signInMessage(_ methods: [ACPAuthMethod]) -> String {
        guard let method = methods.first(where: { $0.id == config.authMethodID }) ?? methods.first else {
            return String(localized: "\(name) needs you to sign in.")
        }
        switch method.type {
        case "terminal":
            return String(localized: "Sign in to \(name) in Settings with “\(method.name)”. It runs in Terminal.")
        case "env_var" where !method.variables.isEmpty:
            let names = method.variables.joined(separator: ", ")
            return String(localized: "Set \(names) in \(name)’s environment variables in Settings, then check again.")
        default:
            return String(localized: "Sign in to \(name) in Settings with “\(method.name)”.")
        }
    }

    private func failure(_ error: Error) -> String {
        String(localized: "\(name) couldn’t start a session: \(error.localizedDescription)")
    }

    // MARK: Settings

    /// What `ProviderRegistry` looks up: a local command's name or path, or the installed executable.
    nonisolated static func executableNames(_ config: ACPAgentConfig, paths: ACPRegistryPaths) -> [String] {
        switch config.source {
        case .local:
            let command = config.command.trimmingCharacters(in: .whitespacesAndNewlines)
            guard ACPAgentConfig.isValidCommand(command) else { return [] }
            return [command]
        case .registry:
            return config.registry.flatMap { paths.validatedExecutable(for: $0) }.map { [$0.path] } ?? []
        }
    }

    nonisolated static func setupHint(_ config: ACPAgentConfig) -> String {
        switch config.source {
        case .local:
            let command = config.command.trimmingCharacters(in: .whitespacesAndNewlines)
            return command.isEmpty
                ? String(localized: "Enter the executable that starts \(config.displayName)’s ACP server.")
                : String(localized: "Coincide can’t find “\(command)”. Install it, or enter the executable’s full path.")
        case .registry:
            return String(localized: "\(config.displayName) isn’t installed. Reinstall it from the ACP Registry below.")
        }
    }
}

/// One short-lived process of a custom ACP agent outside a thread: a probe, a sign-in or a sign-out. It refuses
/// whatever the agent asks unless the owner answers, and stops the agent with everything it started.
@MainActor
final class ACPHelperProcess {
    let client: ACPClient
    private(set) var stderrTail = ""
    private(set) var hasExited = false

    private let name: String
    private let transport: ACPTransport
    private var exitWaiters: [CheckedContinuation<Void, Never>] = []
    private var stopped = false

    init(
        executable: URL, arguments: [String], workingDirectory: URL, environment: [String: String], name: String,
        transport factory: ACPTransportFactory? = nil
    ) {
        self.name = name
        let make =
            factory ?? { executable, arguments, directory, environment in
                ACPProcessTransport(executable: executable, arguments: arguments, workingDirectory: directory, environment: environment)
            }
        transport = make(executable, arguments, workingDirectory, environment)
        let connection = ACPConnection(write: { [weak transport] line in transport?.write(line) })
        client = ACPClient(connection: connection)
        client.onPermissionRequest = { [weak client] _, incoming in client?.respondToPermission(incoming, optionID: nil) }
        client.onElicitation = { [weak client] _, incoming in client?.respondToElicitation(incoming, action: "cancel") }
        transport.onLine = { [weak connection] line in connection?.receive(line) }
        transport.onStderr = { [weak self] text in
            guard let self else { return }
            self.stderrTail = String((self.stderrTail + text).suffix(4_096))
        }
        transport.onExit = { [weak self] status, tail in self?.exited(status: status, tail: tail) }
    }

    func start() throws {
        do {
            try transport.start()
        } catch {
            stop()
            throw AgentError.providerError(String(localized: "Couldn’t start \(name): \(error.localizedDescription)"))
        }
    }

    /// Stops the process (and everything it started). Pending requests fail at once.
    func stop() {
        guard !stopped else { return }
        stopped = true
        client.connection.close(with: AgentError.notRunning)
        transport.terminate()
    }

    /// Waits until the process has exited, at most `timeout` seconds.
    func waitForExit(timeout: TimeInterval) async {
        guard !hasExited else { return }
        let timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            self?.resumeWaiters()
        }
        await withCheckedContinuation { exitWaiters.append($0) }
        timer.cancel()
    }

    private func exited(status: Int32, tail: String) {
        hasExited = true
        if !tail.isEmpty { stderrTail = String((stderrTail + tail).suffix(4_096)) }
        client.connection.close(with: AgentError.providerError(String(localized: "\(name) exited unexpectedly (status \(status)).")))
        resumeWaiters()
    }

    private func resumeWaiters() {
        let waiters = exitWaiters
        exitWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}
