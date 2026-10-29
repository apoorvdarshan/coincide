import Foundation
import Security

/// How an account of an agent signs in.
public enum ProviderAccountAuth: String, Codable, Sendable, CaseIterable {
    /// The CLI's own sign-in. Every account but the default keeps it in a config home of its own under Coincide's
    /// data folder, so two subscription logins of one agent live side by side.
    case login
    /// An API key from the Keychain, handed to the CLI in the variable it reads (`ProviderKind.apiKeyVariable`).
    case apiKey
}

/// One account of an agent, as T3 Code's provider instances: "Claude Code" signed in with a subscription next to
/// "Claude Code (API)" with an Anthropic API key, or two ChatGPT logins of Codex. A thread picks one in its
/// `ModelSelection.accountID`.
///
/// Every agent has a default account (`defaultID`), which is the setup Coincide always used: the CLI's own login in
/// its usual home, with the provider's environment. Settings only store the accounts added besides it, so nothing
/// changes for anyone who never adds one.
public struct ProviderAccount: Codable, Hashable, Sendable, Identifiable {
    public nonisolated static let defaultID = ProviderAccountID.default

    public var id: String
    public var provider: ProviderKind
    public var name: String
    public var auth: ProviderAccountAuth
    /// Variables added to this account's processes on top of the provider's own.
    public var environment: [String: String]
    /// The variable its API key goes in, for agents that take keys of several services (OpenCode: an OpenCode Zen,
    /// Anthropic or OpenRouter key, say). Nil uses the agent's own (`ProviderKind.apiKeyVariable`).
    public var apiKeyVariable: String?

    public nonisolated init(
        id: String = UUID().uuidString, provider: ProviderKind, name: String, auth: ProviderAccountAuth = .login,
        environment: [String: String] = [:], apiKeyVariable: String? = nil
    ) {
        self.id = id
        self.provider = provider
        self.name = name
        self.auth = auth
        self.environment = environment
        self.apiKeyVariable = apiKeyVariable
    }

    /// Where the account's API key goes: its chosen variable when the agent offers it, else the agent's own.
    public nonisolated var keyVariable: String? {
        if let apiKeyVariable, provider.apiKeyChoices.contains(where: { $0.variable == apiKeyVariable }) { return apiKeyVariable }
        return provider.apiKeyVariable
    }

    public nonisolated var isDefault: Bool { id == Self.defaultID }

    /// The account the agent always had, named after it.
    public nonisolated static func defaultAccount(for kind: ProviderKind) -> ProviderAccount {
        ProviderAccount(id: defaultID, provider: kind, name: kind.displayName)
    }

    /// The id and provider are required; a name, sign-in method or variables this version cannot read fall back.
    public nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        provider = try container.decode(ProviderKind.self, forKey: .provider)
        let name = container.lenient(String.self, forKey: .name)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.name = name.isEmpty ? provider.displayName : name
        auth = container.lenient(ProviderAccountAuth.self, forKey: .auth) ?? .login
        environment = container.lenient([String: String].self, forKey: .environment) ?? [:]
        apiKeyVariable = container.lenient(String.self, forKey: .apiKeyVariable)
    }

    /// The id a selection or session stores for this account: nil for the default, so their files stay as before.
    public nonisolated var storedID: String? { Self.storedID(id) }

    /// `id` as selections and sessions store it: nil for the default account or an empty id.
    public nonisolated static func storedID(_ id: String?) -> String? { ProviderAccountID.stored(id) }

    /// Whether the account keeps the CLI's state in a home of its own. Logins always do. So do API keys of the agents
    /// that would otherwise also sign in with the default account's stored login: Codex, whose app server reads a key
    /// only from `auth.json` in its home (`codex login --with-api-key`); OpenCode, which would add every provider in
    /// the default `auth.json`; and Antigravity, whose profile holds its sign-in method.
    public nonisolated var usesOwnHome: Bool {
        guard !isDefault else { return false }
        switch auth {
        case .login: return provider.accountHomeVariable != nil
        case .apiKey: return [.codex, .opencode, .antigravity].contains(provider)
        }
    }

    /// `<data>/providers/<agent>/<account id>/`, laid out like Antigravity's profile.
    public nonisolated func home(in dataDirectory: URL) -> URL {
        dataDirectory.appendingPathComponent("providers", isDirectory: true)
            .appendingPathComponent(provider.rawValue, isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
    }

    /// `base` with what the account changes: its own home, its API key (or, for a login, none inherited from the
    /// shell, which most CLIs would prefer over the login) and its variables. The default account changes nothing.
    public nonisolated func environment(
        _ base: [String: String], dataDirectory: URL, apiKey: String?
    ) -> [String: String] {
        guard !isDefault else { return base }
        var environment = base
        if usesOwnHome, let variable = provider.accountHomeVariable {
            environment[variable] = home(in: dataDirectory).path
        }
        // Keys inherited from the shell would sign a login in with them, or an API-key account with another service's.
        for choice in provider.apiKeyChoices { environment[choice.variable] = nil }
        if auth == .apiKey, let variable = keyVariable, let apiKey, !apiKey.isEmpty {
            environment[variable] = apiKey
        }
        for (key, value) in self.environment { environment[key] = value }
        return environment
    }
}

extension ProviderKind {
    /// The variable that moves the CLI's sign-in to another folder, for agents where that keeps two logins apart.
    /// Cursor keeps its login in the macOS Keychain whatever its config folder, and Antigravity runs in a Google
    /// profile Coincide manages itself, so neither has one.
    public nonisolated var accountHomeVariable: String? {
        switch self {
        case .claude: "CLAUDE_CONFIG_DIR"
        case .codex: "CODEX_HOME"
        case .grok: "GROK_HOME"
        // OpenCode keeps `auth.json` (and its sessions) in `$XDG_DATA_HOME/opencode`.
        case .opencode: "XDG_DATA_HOME"
        case .cursor, .antigravity: nil
        }
    }

    /// The variable the CLI reads its own API key from: `claude` reads `ANTHROPIC_API_KEY`, `cursor-agent`
    /// `CURSOR_API_KEY` (its `--api-key`), Grok `XAI_API_KEY`, OpenCode `OPENCODE_API_KEY` for OpenCode Zen, and
    /// Antigravity `GEMINI_API_KEY` with its `gemini-api-key` sign-in. Codex gets `OPENAI_API_KEY`, which
    /// `codex login --with-api-key` stores in the account's home.
    public nonisolated var apiKeyVariable: String? { apiKeyChoices.first?.variable }

    /// The kinds of API key the agent takes, its own first. OpenCode reads each service's key from that service's
    /// variable (models.dev's names), so an OpenCode account can use OpenCode Zen or one of those services.
    public nonisolated var apiKeyChoices: [(variable: String, name: String)] {
        switch self {
        case .claude: [("ANTHROPIC_API_KEY", String(localized: "Anthropic API key"))]
        case .codex: [("OPENAI_API_KEY", String(localized: "OpenAI API key"))]
        case .cursor: [("CURSOR_API_KEY", String(localized: "Cursor API key"))]
        case .grok: [(GrokFlavor.apiKeyVariable, String(localized: "xAI API key"))]
        case .antigravity: [(AntigravityFlavor.apiKeyVariable, String(localized: "Gemini API key"))]
        case .opencode:
            [
                ("OPENCODE_API_KEY", String(localized: "OpenCode Zen")),
                ("ANTHROPIC_API_KEY", String(localized: "Anthropic")),
                ("OPENAI_API_KEY", String(localized: "OpenAI")),
                ("OPENROUTER_API_KEY", String(localized: "OpenRouter")),
                ("GOOGLE_GENERATIVE_AI_API_KEY", String(localized: "Google Gemini")),
                ("XAI_API_KEY", String(localized: "xAI")),
                ("GROQ_API_KEY", String(localized: "Groq")),
                ("DEEPSEEK_API_KEY", String(localized: "DeepSeek")),
                ("MISTRAL_API_KEY", String(localized: "Mistral")),
            ]
        }
    }

    /// The ways an added account of this agent can sign in, in the order Settings offers them. A login needs a home
    /// the CLI's sign-in can be moved to (`accountHomeVariable`); Cursor keeps its login in the Keychain whatever its
    /// config folder, and Antigravity's Google sign-in belongs to its one managed profile, so their added accounts use
    /// API keys.
    public nonisolated var accountAuthMethods: [ProviderAccountAuth] {
        (accountHomeVariable != nil ? [.login] : []) + (apiKeyVariable != nil ? [.apiKey] : [])
    }

    public nonisolated var supportsAccounts: Bool { !accountAuthMethods.isEmpty }

    /// The CLI's sign-in command, after the executable, for agents whose login an account can keep apart. OpenCode
    /// signs in through its background service unless `--standalone`, which would store the login in the default home.
    public nonisolated var loginArguments: [String]? {
        switch self {
        case .claude: ["auth", "login"]
        case .codex: ["login"]
        case .grok: ["login"]
        case .opencode: ["auth", "login", "--standalone"]
        case .cursor, .antigravity: nil
        }
    }
}

public struct ProviderAccountError: LocalizedError, Equatable {
    public var message: String
    public nonisolated var errorDescription: String? { message }
}

// MARK: Keychain

/// Generic passwords of one Keychain service. Values never leave this type except to the caller that asked.
public struct KeychainStore: Sendable {
    public struct Failure: LocalizedError, Equatable {
        public var status: OSStatus
        public nonisolated var errorDescription: String? {
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return String(localized: "The Keychain refused the request: \(message)")
        }
    }

    public var service: String

    public nonisolated init(service: String) {
        self.service = service
    }

    private nonisolated func query(_ account: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
    }

    /// Stores `value` for `account`, replacing what was there. `label` is what Keychain Access shows.
    public nonisolated func set(_ value: String, for account: String, label: String? = nil) throws {
        let data = Data(value.utf8)
        var attributes: [CFString: Any] = [kSecValueData: data]
        if let label { attributes[kSecAttrLabel] = label }
        let status = SecItemUpdate(query(account) as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw Failure(status: status) }
        let added = SecItemAdd(query(account).merging(attributes) { _, new in new } as CFDictionary, nil)
        guard added == errSecSuccess else { throw Failure(status: added) }
    }

    /// The value for `account`, or nil when there is none.
    public nonisolated func value(for account: String) throws -> String? {
        var request = query(account)
        request[kSecReturnData] = true
        request[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw Failure(status: status) }
        return String(decoding: data, as: UTF8.self)
    }

    /// Whether `account` has a value, without reading it.
    public nonisolated func contains(_ account: String) -> Bool {
        var request = query(account)
        request[kSecReturnAttributes] = true
        request[kSecMatchLimit] = kSecMatchLimitOne
        return SecItemCopyMatching(request as CFDictionary, nil) == errSecSuccess
    }

    public nonisolated func remove(_ account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure(status: status) }
    }
}

/// Where accounts' API keys are kept: one Keychain item per account, never in settings, logs or thread files.
public struct ProviderAccountSecrets: Sendable {
    public nonisolated static let standard = ProviderAccountSecrets(keychain: KeychainStore(service: "com.apoorvdarshan.coincide.provider-account"))

    public var keychain: KeychainStore

    public nonisolated init(keychain: KeychainStore) {
        self.keychain = keychain
    }

    public nonisolated func apiKey(for account: ProviderAccount) -> String? {
        guard !account.isDefault else { return nil }
        return (try? keychain.value(for: account.id)) ?? nil
    }

    public nonisolated func hasAPIKey(_ account: ProviderAccount) -> Bool {
        !account.isDefault && keychain.contains(account.id)
    }

    public nonisolated func setAPIKey(_ key: String, for account: ProviderAccount) throws {
        try keychain.set(key, for: account.id, label: "Coincide: \(account.name)")
    }

    public nonisolated func removeAPIKey(for account: ProviderAccount) throws {
        try keychain.remove(account.id)
    }
}
