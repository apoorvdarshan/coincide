import Foundation

/// The password managers Coincide's browser can fill from. Each is off until the user turns it on in Settings ›
/// Browser › Passwords. Browser extensions can't run inside WebKit views, so each manager's own command-line tool is
/// the integration path; Coincide's own saved logins live in the macOS Keychain.
public nonisolated enum PasswordManagerKind: String, Codable, CaseIterable, Sendable, Hashable, Identifiable {
    case coincide
    case onePassword
    case bitwarden

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .coincide: String(localized: "Coincide Saved Logins")
        case .onePassword: "1Password"
        case .bitwarden: "Bitwarden"
        }
    }

    /// The command-line tool, or nil for the Keychain.
    public var executable: String? {
        switch self {
        case .coincide: nil
        case .onePassword: "op"
        case .bitwarden: "bw"
        }
    }

    /// How to install the tool with Homebrew.
    public var installCommand: String? {
        switch self {
        case .coincide: nil
        case .onePassword: "brew install --cask 1password-cli"
        case .bitwarden: "brew install bitwarden-cli"
        }
    }

    /// The vendor's app, whose installed icon Settings may show.
    public var appBundleIDs: [String] {
        switch self {
        case .coincide: []
        case .onePassword: ["com.1password.1password", "com.agilebits.onepassword7"]
        case .bitwarden: ["com.bitwarden.desktop"]
        }
    }
}

/// What an adapter's tool can do. Settings marks what's missing as unavailable.
public nonisolated struct PasswordCapabilities: Sendable, Hashable {
    /// Finds logins by the page's address (else Coincide lists all logins and matches them itself).
    public var lookupByDomain: Bool
    /// Produces one-time codes for items that have them.
    public var totp: Bool

    public init(lookupByDomain: Bool, totp: Bool) {
        self.lookupByDomain = lookupByDomain
        self.totp = totp
    }
}

public nonisolated enum PasswordProviderStatus: Sendable, Hashable {
    case notInstalled
    /// Installed but not set up, such as 1Password without the app integration or Bitwarden without `bw login`.
    case needsSetup
    case locked
    case unlocked(account: String?)
    /// Ready; the manager's own app asks the user to unlock when Coincide first uses it (1Password).
    case unlocksOnUse(account: String?)
    case unavailable(String)

    public var isUsable: Bool {
        switch self {
        case .unlocked, .unlocksOnUse: true
        default: false
        }
    }
}

/// A login as a password manager lists it, without its secrets. Usernames may be shown to the user and returned to
/// agents; passwords and one-time codes never are.
public nonisolated struct LoginItem: Sendable, Hashable, Identifiable {
    public var id: String { "\(source.rawValue):\(itemID)" }
    public var source: PasswordManagerKind
    public var itemID: String
    public var title: String
    public var username: String
    public var urls: [String]
    /// Nil when the tool's list doesn't say.
    public var hasTOTP: Bool?

    public init(source: PasswordManagerKind, itemID: String, title: String, username: String, urls: [String], hasTOTP: Bool? = nil) {
        self.source = source
        self.itemID = itemID
        self.title = title
        self.username = username
        self.urls = urls
        self.hasTOTP = hasTOTP
    }
}

/// A login's secrets, held only while filling. Never described, mirrored or logged.
public nonisolated struct LoginSecret: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let username: String
    let password: String
    let totp: String?

    public init(username: String, password: String, totp: String?) {
        self.username = username
        self.password = password
        self.totp = totp
    }

    public var hasTOTP: Bool { totp?.isEmpty == false }

    /// The values for the page's fields, handed straight to WebKit as script arguments.
    public var fillArguments: [String: Any] { ["loginUsername": username, "loginPassword": password, "loginCode": totp ?? ""] }

    /// Whether `text` contains one of the secrets. For tests and leak checks.
    public func appears(in text: String) -> Bool {
        (!password.isEmpty && text.contains(password)) || (totp.map { !$0.isEmpty && text.contains($0) } ?? false)
    }

    public var description: String { "LoginSecret(\(username), secrets redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["username": username, "password": "<redacted>", "totp": "<redacted>"]) }
}

public nonisolated enum PasswordProviderError: LocalizedError, Equatable {
    case notInstalled(String)
    case locked
    case notFound
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .notInstalled(let name): String(localized: "\(name) isn’t installed.")
        case .locked: String(localized: "The password manager is locked. Unlock it in Settings › Browser.")
        case .notFound: String(localized: "The login wasn’t found.")
        case .failed(let message): message
        }
    }
}

/// One password manager behind a small adapter.
public protocol PasswordProvider: Sendable {
    var kind: PasswordManagerKind { get }
    var capabilities: PasswordCapabilities { get }
    func status() async -> PasswordProviderStatus
    /// Logins that may belong to `page`. Coincide filters them again with `LoginMatcher`, so an adapter may return more.
    func logins(for page: URL) async throws -> [LoginItem]
    func secret(for item: LoginItem) async throws -> LoginSecret
}

/// Runs a password manager's tool. Secrets go through `environment` or `input`, never `arguments`.
public protocol PasswordCommandRunner: Sendable {
    func locate(_ executable: String) async -> URL?
    func run(_ executable: URL, _ arguments: [String], environment: [String: String], input: String?) async -> ProcessRunner.Result
}

/// The real runner: the user's login-shell PATH (Homebrew included) and `ProcessRunner`.
public nonisolated struct SystemPasswordCommandRunner: PasswordCommandRunner {
    public init() {}

    public func locate(_ executable: String) async -> URL? {
        if let found = await ShellEnvironment.shared.which(executable) { return found }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for folder in ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "/run/current-system/sw/bin"] {
            let candidate = URL(fileURLWithPath: folder).appendingPathComponent(executable)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    public func run(_ executable: URL, _ arguments: [String], environment: [String: String], input: String?) async -> ProcessRunner.Result {
        var merged = await ShellEnvironment.shared.environment()
        merged.merge(environment) { _, new in new }
        return await ProcessRunner.run(executable, arguments, environment: merged, timeout: 60, input: input)
    }
}
