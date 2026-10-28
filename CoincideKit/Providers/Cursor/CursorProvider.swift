import Foundation

/// Cursor's coding agent, driven through the `cursor-agent` CLI with the user's own Cursor login.
@MainActor
public final class CursorProvider: AgentProvider {
    public let kind: ProviderKind = .cursor
    public let executableNames = ["cursor-agent"]
    public let setupHint = String(localized: "Install the Cursor CLI and run `cursor-agent login`.")

    /// The model the CLI is set to, shown on the picker's default entry.
    private var currentModelName: String?
    /// Whether the user let Coincide read the CLI's Keychain login for the plan's usage (T3 Code's "Cursor account
    /// usage" setting).
    private let keychainUsageAllowed: @MainActor () -> Bool
    private let usageCredentials: CursorUsageLimits.Credentials
    private let fetchUsage: UsageLimitsFetch
    /// The plan's windows from the last check, kept when a later read fails.
    private var usageLimits: UsageLimits?

    public convenience init(keychainUsageAllowed: @escaping @MainActor () -> Bool = { false }) {
        self.init(keychainUsageAllowed: keychainUsageAllowed, usageCredentials: .live, fetchUsage: UsageLimitsHTTP.live)
    }

    init(
        keychainUsageAllowed: @escaping @MainActor () -> Bool, usageCredentials: CursorUsageLimits.Credentials,
        fetchUsage: @escaping UsageLimitsFetch
    ) {
        self.keychainUsageAllowed = keychainUsageAllowed
        self.usageCredentials = usageCredentials
        self.fetchUsage = fetchUsage
    }

    /// Checks the CLI and, once it is signed in, reads the plan's usage windows, as T3 Code does.
    public func detect(executable: URL?, environment: [String: String]) async -> ProviderStatus {
        var status = await checkInstallation(executable: executable, environment: environment)
        guard status.state == .ready else {
            usageLimits = nil
            return status
        }
        let outcome = await CursorUsageLimits.read(
            environment: environment, allowKeychain: keychainUsageAllowed(), credentials: usageCredentials,
            fetch: fetchUsage)
        usageLimits = outcome.resolved(after: usageLimits)
        status.usageLimits = usageLimits
        return status
    }

    private func checkInstallation(executable: URL?, environment: [String: String]) async -> ProviderStatus {
        guard let executable else { return ProviderStatus(state: .notInstalled, message: setupHint) }
        async let versionRun = ProcessRunner.run(executable, ["--version"], environment: environment, timeout: 15)
        async let statusRun = ProcessRunner.run(
            executable, ["status", "--format", "json"], environment: environment, timeout: 30)
        async let aboutRun = ProcessRunner.run(executable, ["about", "--format", "json"], environment: environment, timeout: 30)

        let versionResult = await versionRun
        guard versionResult.succeeded, let version = Self.version(from: versionResult.stdout) else {
            let output = versionResult.stderr.isEmpty ? versionResult.stdout : versionResult.stderr
            return ProviderStatus(
                state: .error, executable: executable,
                message: CursorConnection.exitMessage(status: versionResult.status, stderr: output))
        }
        let about = CursorAbout.parse((await aboutRun).stdout)
        currentModelName = about?.model
        let statusResult = await statusRun
        let account = CursorAccount.parse(statusResult.stdout)
        let hasAPIKey = !(environment["CURSOR_API_KEY"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        if account?.auth == .signedIn {
            let label = Self.accountLabel(email: account?.email ?? about?.email, plan: about?.tier ?? account?.team)
            return ProviderStatus(state: .ready, version: version, executable: executable, account: label)
        }
        if hasAPIKey {
            return ProviderStatus(
                state: .ready, version: version, executable: executable, account: String(localized: "Cursor API key"))
        }
        switch account?.auth {
        case .signedOut:
            return ProviderStatus(
                state: .notAuthenticated, version: version, executable: executable,
                message: String(localized: "Not signed in. Run `cursor-agent login` in Terminal."))
        case .failed(let message):
            return ProviderStatus(state: .error, version: version, executable: executable, message: message)
        default:
            let output = statusResult.stderr.isEmpty ? statusResult.stdout : statusResult.stderr
            return ProviderStatus(
                state: .error, version: version, executable: executable,
                message: CursorConnection.exitMessage(status: statusResult.status, stderr: output))
        }
    }

    /// The account's models from Cursor's ACP server (with efforts where Cursor exposes them),
    /// falling back to `cursor-agent models` and then a built-in list.
    public func models(status: ProviderStatus, environment: [String: String]) async -> [ModelOption] {
        guard status.state == .ready, let executable = status.executable else {
            return CursorModels.withDefault(CursorModels.fallback, currentModelName: currentModelName)
        }
        if let catalog = await Self.catalog(executable: executable, environment: environment), !catalog.isEmpty {
            return CursorModels.withDefault(catalog, currentModelName: currentModelName)
        }
        let listed = await ProcessRunner.run(executable, ["models"], environment: environment, timeout: 30)
        let parsed = listed.succeeded ? CursorModels.parseModelsCommand(listed.stdout) : []
        return CursorModels.withDefault(parsed.isEmpty ? CursorModels.fallback : parsed, currentModelName: currentModelName)
    }

    public func makeSession(_ launch: AgentLaunch) -> AgentSession {
        CursorSession(launch: launch)
    }

    /// Asks `cursor-agent acp` for the account's models through its `cursor/list_available_models` extension.
    private static func catalog(executable: URL, environment: [String: String]) async -> [ModelOption]? {
        let transport = CursorProcessTransport(
            executable: executable, arguments: ["acp"], workingDirectory: FileManager.default.temporaryDirectory,
            environment: environment)
        let connection = CursorConnection(transport: transport)
        // Listing the models makes Cursor sync (and possibly save) its current model selection.
        let settings = CursorModelSettings.shared(environment: environment)
        settings.begin()
        defer {
            connection.close()
            settings.end(touching: [])
        }
        do {
            try connection.start()
            _ = try await connection.request("initialize", CursorSession.initializeParams, timeout: .seconds(30))
            return CursorModels.catalog(try await connection.request("cursor/list_available_models", [:], timeout: .seconds(45)))
        } catch {
            return nil
        }
    }

    nonisolated static func version(from output: String) -> String? {
        guard let line = output.split(whereSeparator: \.isNewline).first?.trimmingCharacters(in: .whitespaces),
            line.contains(where: \.isNumber)
        else { return nil }
        return line.hasPrefix("v") ? String(line.dropFirst()) : line
    }

    nonisolated static func accountLabel(email: String?, plan: String?) -> String? {
        switch (email.flatMap { $0.isEmpty ? nil : $0 }, plan.flatMap { $0.isEmpty ? nil : $0 }) {
        case let (email?, plan?): "\(email) (\(plan))"
        case let (email?, nil): email
        case let (nil, plan?): plan
        case (nil, nil): nil
        }
    }
}

/// What `cursor-agent status --format json` reports.
struct CursorAccount: Equatable, Sendable {
    enum Auth: Equatable, Sendable {
        case signedIn
        case signedOut
        case failed(String)
    }

    var auth: Auth
    var email: String?
    var team: String?

    nonisolated static func parse(_ output: String) -> CursorAccount? {
        guard let json = jsonObject(in: output) else {
            // Plain-text output from CLIs without `--format`.
            if let range = output.range(of: "Logged in as ") {
                let email = output[range.upperBound...].prefix { !$0.isNewline && !$0.isWhitespace }
                return CursorAccount(auth: .signedIn, email: String(email))
            }
            return output.localizedCaseInsensitiveContains("not logged in") ? CursorAccount(auth: .signedOut) : nil
        }
        let status = json["status"]?.string
        let auth: Auth
        if json["isAuthenticated"]?.bool == true || status == "authenticated" {
            auth = .signedIn
        } else if status == "error" {
            auth = .failed(json["message"]?.string ?? String(localized: "Cursor couldn't check the sign-in."))
        } else {
            auth = .signedOut
        }
        return CursorAccount(
            auth: auth, email: json["userInfo"]?["email"]?.string, team: json["userInfo"]?["teamName"]?.string)
    }
}

/// What `cursor-agent about --format json` reports.
struct CursorAbout: Equatable, Sendable {
    var version: String?
    var tier: String?
    var email: String?
    /// Display name of the CLI's current model.
    var model: String?

    nonisolated static func parse(_ output: String) -> CursorAbout? {
        guard let json = jsonObject(in: output) else { return nil }
        func text(_ key: String) -> String? {
            json[key]?.string.flatMap { $0.isEmpty ? nil : $0 }
        }
        return CursorAbout(version: text("cliVersion"), tier: text("subscriptionTier"), email: text("userEmail"), model: text("model"))
    }
}

/// The JSON object in a command's output, ignoring anything printed around it.
private nonisolated func jsonObject(in output: String) -> JSONValue? {
    guard let start = output.firstIndex(of: "{"), let end = output.lastIndex(of: "}"), start < end,
        let value = JSONValue.parse(String(output[start...end])), value.object != nil
    else { return nil }
    return value
}
