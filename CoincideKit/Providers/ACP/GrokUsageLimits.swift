import Foundation

/// Reads Grok Build's subscription allowance from xAI's billing endpoint with the CLI's own grok.com sign-in, following
/// T3 Code's `readGrokAccount` and `grokUsageResponseToLimits`. An API key, or a setup that may pick another account or
/// endpoint, is left to the CLI and reports no limits.
enum GrokUsageLimits {
    nonisolated static let billingURL = URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!
    /// The login scopes `auth.json` keeps a grok.com sign-in under, current first. Other scopes belong to other
    /// deployments, and no account is ever picked from them.
    nonisolated static let loginScopes = [
        "https://auth.x.ai::b1a00492-073a-47ea-816f-4c329264a828", "https://accounts.x.ai/sign-in",
    ]
    /// Variables that select another scope, account or endpoint (T3's list). With any of them set, the CLI decides.
    nonisolated static let customAuthVariables = [
        "GROK_OIDC_ISSUER", "GROK_OIDC_CLIENT_ID", "GROK_OAUTH2_ISSUER", "GROK_OAUTH2_CLIENT_ID",
        "GROK_OAUTH2_PRINCIPAL_TYPE", "GROK_OAUTH2_PRINCIPAL_ID", "GROK_AUTH_PROVIDER_COMMAND", "GROK_LOCAL_AUTH",
        "GROK_CLI_CHAT_PROXY_BASE_URL", "GROK_MODELS_BASE_URL", "GROK_CONFIG", "GROK_CONFIG_PATH",
    ]
    /// A config section that can change the account or endpoint: `[auth]`, `[[endpoints]]`, `auth.x = …`, `"auth" = …`.
    nonisolated static let customConfigPattern = #"(?m)^\s*(?:\[\[?\s*)?["']?(?:auth|grok_com_config|endpoints)["']?\s*[.\]=]"#

    /// Where a check gets its files and answers. Tests replace both, so they never read real credentials or reach xAI.
    struct Reader: Sendable {
        /// A file's contents, nil when there is no such file; throws when it exists but cannot be read.
        var readFile: @Sendable (URL) throws -> Data?
        var fetch: UsageLimitsFetch

        nonisolated static let live = Reader(readFile: readFileIfPresent, fetch: UsageLimitsHTTP.live)

        /// The allowance of the signed-in grok.com account. The token goes only in the request's Authorization header.
        /// Reading the credentials and the request each get `timeout` (T3's 10 seconds).
        @concurrent nonisolated func read(
            environment: [String: String], timeout: Duration = .seconds(10), at now: Date = Date()
        ) async -> UsageLimitsOutcome {
            let token: String?
            do {
                token = try await usageLimitsWithTimeout(timeout) { [readFile] in
                    try GrokUsageLimits.token(environment: environment, readFile: readFile)
                }
            } catch {
                return .failed
            }
            guard let token else { return .unsupported }
            let request = UsageLimitsHTTP.request(billingURL, token: token, timeout: timeout.timeInterval)
            let outcome = try? await usageLimitsWithTimeout(timeout) { [fetch] () async throws -> UsageLimitsOutcome in
                let (data, response) = try await fetch(request)
                guard (200..<300).contains(response.statusCode), let body = JSONValue.parse(data),
                    let windows = windows(fromBilling: body)
                else { return .failed }
                return .limits(UsageLimits(windows: windows, checkedAt: now))
            }
            return outcome ?? .failed
        }
    }

    private struct Malformed: Error {}

    /// The grok.com sign-in's token, as T3's `readGrokCredential` finds it: from `GROK_AUTH`, else `auth.json` in Grok's
    /// home. Nil when there is none Coincide may use (an API key, a custom deployment, no sign-in). Throws when a file
    /// cannot be read or the credentials are malformed.
    nonisolated static func token(environment: [String: String], readFile: (URL) throws -> Data?) throws -> String? {
        func value(_ name: String) -> String? { environment[name]?.trimmedNonEmpty }
        func text(_ url: URL) throws -> String? { try readFile(url).map { String(decoding: $0, as: UTF8.self) } }
        // T3's ACP adapter signs in with the API key whenever it is set.
        if value(GrokFlavor.apiKeyVariable) != nil { return nil }
        if customAuthVariables.contains(where: { value($0) != nil }) { return nil }
        let home = GrokCLI.home(environment)
        let configs = ["config.toml", "managed_config.toml", "requirements.toml"].map { home.appendingPathComponent($0) }
            + ["/etc/grok/managed_config.toml", "/etc/grok/requirements.toml"].map { URL(fileURLWithPath: $0) }
        for config in configs {
            if let config = try text(config), config.range(of: customConfigPattern, options: .regularExpression) != nil {
                return nil
            }
        }
        let contents = try value("GROK_AUTH") ?? text(home.appendingPathComponent("auth.json")) ?? "{}"
        // Every entry must have the expected shape, as T3's schema requires.
        guard let credentials = JSONValue.parse(contents)?.object,
            credentials.values.allSatisfy({ entry in
                entry.object != nil && ["key", "auth_mode", "email"].allSatisfy { entry[$0] == nil || entry[$0]?.string != nil }
            })
        else { throw Malformed() }
        guard let credential = loginScopes.lazy.compactMap({ credentials[$0] }).first,
            credential["auth_mode"]?.string != "api_key"
        else { return nil }
        return credential["key"]?.string?.trimmedNonEmpty
    }

    /// The allowance a billing answer reports: `config.creditUsagePercent` of `config.currentPeriod`, a weekly or
    /// monthly period or else a plain subscription. Nil when the answer is not the expected shape; empty when it names
    /// no allowance, which is never invented.
    nonisolated static func windows(fromBilling response: JSONValue) -> [UsageLimitWindow]? {
        guard let root = response.object else { return nil }
        let config: [String: JSONValue]?
        let reportedPercent: Double?
        let period: [String: JSONValue]?
        let periodType: String?
        let end: String?
        do {
            config = try field(root["config"], \.object)
            reportedPercent = try field(config?["creditUsagePercent"], \.number)
            period = try field(config?["currentPeriod"], \.object)
            periodType = try field(period?["type"], \.string)
            end = try field(period?["end"], \.string)
        } catch {
            return nil
        }
        let kind: UsageLimitWindow.Kind =
            switch periodType.map({ $0.replacing(/^USAGE_PERIOD_TYPE_/, with: "") }) {
            case "WEEKLY": .weekly
            case "MONTHLY": .monthly
            default: .other
            }
        var usedPercent = reportedPercent
        // Grok leaves out a zero percentage but keeps the whole subscription period.
        if usedPercent == nil, kind != .other, let start = UsageLimitDates.instant(period?["start"]?.string),
            let finish = UsageLimitDates.instant(end), start < finish
        {
            usedPercent = 0
        }
        guard let usedPercent, usedPercent.isFinite else { return [] }
        let label =
            switch kind {
            case .weekly: String(localized: "Weekly")
            case .monthly: String(localized: "Monthly")
            default: String(localized: "Subscription")
            }
        return [
            UsageLimitWindow(id: "subscription", kind: kind, label: label, usedPercent: usedPercent, resetsAt: UsageLimitDates.instant(end))
        ]
    }

    /// An optional field: absent is fine, a value of another type than `read` takes is not.
    private nonisolated static func field<T>(_ value: JSONValue?, _ read: (JSONValue) -> T?) throws -> T? {
        guard let value else { return nil }
        guard let typed = read(value) else { throw Malformed() }
        return typed
    }
}
