import Foundation

/// Claude Code, driven over the stream-json control protocol the Claude Agent SDK uses.
@MainActor
public final class ClaudeProvider: AgentProvider {
    public let kind: ProviderKind = .claude
    public let executableNames = ["claude"]
    public var setupHint: String { String(localized: "Install Claude Code and run `claude auth login`.") }

    /// The last `initialize` probe, reused while fresh so detection and model loading share one spawn.
    private var probe: (executable: URL, date: Date, info: ClaudeInitializeInfo)?
    /// The CLI's model rows, so sessions can resolve `default` and aliases before their own handshake.
    private var knownModels: [JSONValue] = []

    public init() {}

    public func detect(executable: URL?, environment: [String: String]) async -> ProviderStatus {
        guard let executable else { return ProviderStatus(state: .notInstalled, message: setupHint) }
        let environment = ClaudeLaunchConfig.environment(environment)
        let versionResult = await ProcessRunner.run(executable, ["--version"], environment: environment, timeout: 20)
        guard versionResult.status != -1 else {
            // It could not be launched at all; the runner reports why on stderr.
            let reason = Self.outputTail(versionResult) ?? String(localized: "status \(Int(versionResult.status))")
            return ProviderStatus(
                state: .error, executable: executable, message: String(localized: "Claude Code could not be started: \(reason)"))
        }
        let version = ClaudeModelCatalog.parseVersion(versionResult.stdout + "\n" + versionResult.stderr)
        guard versionResult.succeeded else {
            var message = String(localized: "Claude Code is installed but failed to run.")
            if let tail = Self.outputTail(versionResult) { message += "\n" + tail }
            return ProviderStatus(state: .error, version: version, executable: executable, message: message)
        }

        let authResult = await ProcessRunner.run(
            executable, ["auth", "status", "--json"], environment: environment, timeout: 15)
        var auth = JSONValue.parse(authResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
            .flatMap(ClaudeAuth.parseStatus)
        if auth == nil, let account = await initializeInfo(executable: executable, environment: environment)?.account {
            auth = ClaudeAuth.status(fromAccount: account)
        }
        let customEndpoint = ClaudeAuth.usesCustomEndpoint(environment)
        let upgrade = ClaudeModelCatalog.upgradeMessage(version: version)
        guard let auth else {
            return ProviderStatus(
                state: .ready, version: version, executable: executable,
                account: customEndpoint ? String(localized: "Custom API endpoint") : nil,
                message: customEndpoint ? upgrade : String(localized: "Could not verify the Claude Code sign-in."))
        }
        if !auth.loggedIn && !customEndpoint {
            return ProviderStatus(
                state: .notAuthenticated, version: version, executable: executable,
                message: String(localized: "Claude Code is not signed in. Run `claude auth login` in Terminal, then refresh."))
        }
        return ProviderStatus(
            state: .ready, version: version, executable: executable,
            account: auth.account ?? (customEndpoint ? String(localized: "Custom API endpoint") : nil), message: upgrade)
    }

    public func models(status: ProviderStatus, environment: [String: String]) async -> [ModelOption] {
        if let executable = status.executable,
            let info = await initializeInfo(executable: executable, environment: environment)
        {
            let models = ClaudeModelCatalog.models(fromInitialize: info.models)
            if !models.isEmpty {
                knownModels = info.models
                return models
            }
        }
        return ClaudeModelCatalog.fallbackModels(version: status.version)
    }

    public func makeSession(_ launch: AgentLaunch) -> AgentSession {
        ClaudeSession(launch: launch, knownModels: knownModels)
    }

    /// The last lines a failed command printed (stderr, else stdout), without escape sequences, for a status message.
    nonisolated static func outputTail(_ result: ProcessRunner.Result) -> String? {
        TerminalText.tail(result.stderr, lines: 3, maxLength: 400) ?? TerminalText.tail(result.stdout, lines: 3, maxLength: 400)
    }

    private func initializeInfo(executable: URL, environment: [String: String]) async -> ClaudeInitializeInfo? {
        if let probe, probe.executable == executable, Date().timeIntervalSince(probe.date) < 60 { return probe.info }
        guard let info = await ClaudeCapabilitiesProbe.run(executable: executable, environment: environment) else {
            return nil
        }
        probe = (executable, Date(), info)
        return info
    }
}

/// What the CLI reports in its `initialize` response.
struct ClaudeInitializeInfo: Sendable {
    var models: [JSONValue]
    var account: JSONValue?
    var permissionMode: String?

    init(response: JSONValue) {
        models = response["models"]?.array ?? []
        account = response["account"]
        permissionMode = response["current_permission_mode"]?.string
    }

    /// The concrete model behind a model value such as `default` or `opus`.
    static func resolvedModel(for modelID: String, in models: [JSONValue]) -> String? {
        models.first { $0["value"]?.string == modelID }?["resolvedModel"]?.string
    }
}

/// Runs only the `initialize` handshake, like T3's capabilities probe: it reads the model list and
/// account without sending a prompt, with hooks and MCP servers off and nothing persisted.
@MainActor
enum ClaudeCapabilitiesProbe {
    nonisolated static func arguments(managedMCPConfig: Bool) -> [String] {
        var arguments = [
            "--output-format", "stream-json", "--verbose", "--input-format", "stream-json",
            "--setting-sources=user,project,local", "--no-session-persistence",
            "--settings", JSONValue.object(["disableAllHooks": true]).compactJSON,
        ]
        // managed-mcp.json forbids --strict-mcp-config and already excludes other MCP config.
        if !managedMCPConfig { arguments.append("--strict-mcp-config") }
        return arguments
    }

    static func run(executable: URL, environment: [String: String], timeout: TimeInterval = 25) async -> ClaudeInitializeInfo? {
        var environment = ClaudeLaunchConfig.environment(environment)
        environment["ENABLE_CLAUDEAI_MCP_SERVERS"] = "false"
        environment["CLAUDE_CODE_AUTO_CONNECT_IDE"] = "0"
        environment["CLAUDE_CODE_IDE_SKIP_AUTO_INSTALL"] = "1"
        let managed = FileManager.default.fileExists(atPath: "/Library/Application Support/ClaudeCode/managed-mcp.json")
        let process = LineProcess(
            executable: executable, arguments: arguments(managedMCPConfig: managed),
            workingDirectory: FileManager.default.homeDirectoryForCurrentUser, environment: environment)
        let requestID = UUID().uuidString.lowercased()
        let response: JSONValue? = await withCheckedContinuation { continuation in
            let waiter = Waiter(continuation)
            process.onLine = { line in
                guard let frame = JSONValue.parse(line), frame["type"]?.string == "control_response",
                    frame.at("response.request_id")?.string == requestID
                else { return }
                waiter.finish(frame.at("response.subtype")?.string == "success" ? frame.at("response.response") : nil)
            }
            process.onExit = { _, _ in waiter.finish(nil) }
            do {
                try process.start()
            } catch {
                waiter.finish(nil)
                return
            }
            process.write(json: ["request_id": .string(requestID), "type": "control_request", "request": ["subtype": "initialize"]])
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(timeout))
                waiter.finish(nil)
            }
        }
        process.closeInput()
        process.terminate()
        return response.map(ClaudeInitializeInfo.init(response:))
    }

    @MainActor
    private final class Waiter {
        private var continuation: CheckedContinuation<JSONValue?, Never>?

        init(_ continuation: CheckedContinuation<JSONValue?, Never>) {
            self.continuation = continuation
        }

        func finish(_ value: JSONValue?) {
            continuation?.resume(returning: value)
            continuation = nil
        }
    }
}

/// Sign-in state from `claude auth status --json` or the `initialize` account.
enum ClaudeAuth {
    struct Status: Sendable, Hashable {
        var loggedIn: Bool
        /// Shown in Settings, e.g. "user@example.com (Max)" or "API key".
        var account: String?
    }

    static func parseStatus(_ json: JSONValue) -> Status? {
        guard let loggedIn = json["loggedIn"]?.bool else { return nil }
        let email = nonEmpty(json["email"]?.string)
        let account: String?
        switch json["authMethod"]?.string {
        case "claude.ai"?, "oauth_token"?:
            account = label(email: email, plan: subscriptionLabel(json["subscriptionType"]?.string))
        case "api_key"?, "api_key_helper"?:
            account = String(localized: "API key")
        case "third_party"?:
            account = providerLabel(json["apiProvider"]?.string)
        default:
            account = email
        }
        return Status(loggedIn: loggedIn, account: account)
    }

    /// T3's rule: finishing `initialize` only proves Claude started; only `tokenSource: none`
    /// without a key or account disproves sign-in.
    static func status(fromAccount account: JSONValue) -> Status {
        if let apiProvider = account["apiProvider"]?.string, apiProvider != "firstParty" {
            return Status(loggedIn: true, account: providerLabel(apiProvider))
        }
        let email = nonEmpty(account["email"]?.string)
        let plan = subscriptionLabel(account["subscriptionType"]?.string)
        let tokenSource = account["tokenSource"]?.string
        let hasKey = nonEmpty(account["apiKeySource"]?.string).map { $0 != "none" } ?? false
        let loggedIn = (tokenSource != nil && tokenSource != "none") || hasKey || email != nil || plan != nil
        return Status(loggedIn: loggedIn, account: label(email: email, plan: plan) ?? (hasKey ? String(localized: "API key") : nil))
    }

    private static func label(email: String?, plan: String?) -> String? {
        switch (email, plan) {
        case let (email?, plan?): "\(email) (\(plan))"
        case let (email?, nil): email
        case let (nil, plan?): plan
        case (nil, nil): nil
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        return value
    }

    /// "max", "Claude Max" or "claude_max_20x_subscription" → "Max 20x", as T3 labels plans.
    static func subscriptionLabel(_ raw: String?) -> String? {
        guard let raw, !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        var key = raw.lowercased().replacingOccurrences(of: #"[\s_-]+"#, with: "", options: .regularExpression)
        if key.hasPrefix("claude") { key.removeFirst("claude".count) }
        if key.hasSuffix("subscription") { key.removeLast("subscription".count) }
        switch key {
        case "max", "maxplan": return "Max"
        case "max5", "max5x": return "Max 5x"
        case "max20", "max20x": return "Max 20x"
        case "enterprise": return "Enterprise"
        case "team": return "Team"
        case "pro": return "Pro"
        case "free": return "Free"
        default:
            return raw.split(whereSeparator: { $0 == " " || $0 == "_" || $0 == "-" })
                .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
                .joined(separator: " ")
        }
    }

    static func providerLabel(_ apiProvider: String?) -> String? {
        switch apiProvider {
        case "bedrock"?: "Amazon Bedrock"
        case "vertex"?: "Google Vertex AI"
        case "foundry"?: "Microsoft Foundry"
        case "gateway"?: String(localized: "Enterprise gateway")
        case let other?: other
        case nil: nil
        }
    }

    /// First-party account fields cannot vouch for a custom endpoint's credentials.
    static func usesCustomEndpoint(_ environment: [String: String]) -> Bool {
        guard let raw = environment["ANTHROPIC_BASE_URL"]?.trimmingCharacters(in: .whitespaces),
            let url = URL(string: raw), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
            let host = url.host, !host.isEmpty
        else { return false }
        return host != "api.anthropic.com"
    }
}
