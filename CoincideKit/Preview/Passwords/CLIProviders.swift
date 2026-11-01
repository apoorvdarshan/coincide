import Foundation

/// 1Password through its CLI (`op`), signed in with the 1Password app's CLI integration, so the app asks for Touch ID
/// or the account password itself. Coincide never sees the 1Password account password.
public nonisolated struct OnePasswordProvider: PasswordProvider {
    public let kind = PasswordManagerKind.onePassword
    public let capabilities = PasswordCapabilities(lookupByDomain: false, totp: true)
    let runner: PasswordCommandRunner

    public init(runner: PasswordCommandRunner = SystemPasswordCommandRunner()) { self.runner = runner }

    public func status() async -> PasswordProviderStatus {
        guard let op = await runner.locate("op") else { return .notInstalled }
        let accounts = await runner.run(op, ["account", "list", "--format", "json"], environment: [:], input: nil)
        guard accounts.succeeded, let list = JSONValue.parse(Data(accounts.stdout.utf8))?.array else {
            return .unavailable(Self.firstLine(accounts.stderr))
        }
        guard let first = list.first else { return .needsSetup }
        return .unlocksOnUse(account: first["email"]?.string ?? first["url"]?.string)
    }

    public func logins(for page: URL) async throws -> [LoginItem] {
        let output = try await run(["item", "list", "--categories", "Login", "--format", "json"])
        return Self.parseList(output)
    }

    public func secret(for item: LoginItem) async throws -> LoginSecret {
        let output = try await run(["item", "get", item.itemID, "--format", "json", "--reveal"])
        guard let secret = Self.parseItem(output) else { throw PasswordProviderError.notFound }
        return secret
    }

    private func run(_ arguments: [String]) async throws -> String {
        guard let op = await runner.locate("op") else { throw PasswordProviderError.notInstalled("1Password CLI") }
        let result = await runner.run(op, arguments, environment: [:], input: nil)
        guard result.succeeded else { throw PasswordProviderError.failed(Self.firstLine(result.stderr)) }
        return result.stdout
    }

    /// `op item list --format json`: id, title, `additional_information` (the username) and `urls[].href`.
    static func parseList(_ json: String) -> [LoginItem] {
        (JSONValue.parse(Data(json.utf8))?.array ?? []).compactMap { entry in
            guard let id = entry["id"]?.string else { return nil }
            let urls = (entry["urls"]?.array ?? []).compactMap { $0["href"]?.string }
            return LoginItem(source: .onePassword, itemID: id, title: entry["title"]?.string ?? "",
                username: entry["additional_information"]?.string ?? "", urls: urls)
        }
    }

    /// `op item get --format json --reveal`: fields by purpose, and the current code of an OTP field in `totp`.
    static func parseItem(_ json: String) -> LoginSecret? {
        guard let fields = JSONValue.parse(Data(json.utf8))?["fields"]?.array else { return nil }
        let username = fields.first { $0["purpose"]?.string == "USERNAME" }?["value"]?.string ?? ""
        guard let password = fields.first(where: { $0["purpose"]?.string == "PASSWORD" })?["value"]?.string else { return nil }
        let totp = fields.first { $0["type"]?.string == "OTP" }?["totp"]?.string
        return LoginSecret(username: username, password: password, totp: totp)
    }

    static func firstLine(_ text: String) -> String {
        String(text.split(whereSeparator: \.isNewline).first ?? "").trimmingCharacters(in: .whitespaces).prefix(300).description
    }
}

/// Bitwarden through its CLI (`bw`). The user logs in with `bw login` once; unlocking in Settings sends the master
/// password to `bw unlock` in an environment variable (never an argument), and the session key it returns is kept
/// only in the Keychain and passed back to `bw` the same way.
public nonisolated struct BitwardenProvider: PasswordProvider {
    public let kind = PasswordManagerKind.bitwarden
    public let capabilities = PasswordCapabilities(lookupByDomain: true, totp: true)
    let runner: PasswordCommandRunner
    let sessions: SecretStore
    static let sessionAccount = "bitwarden-session"

    public init(runner: PasswordCommandRunner = SystemPasswordCommandRunner(), sessions: SecretStore = KeychainSecretStore()) {
        self.runner = runner
        self.sessions = sessions
    }

    private var environment: [String: String] {
        guard let session = sessions.read(Self.sessionAccount) else { return [:] }
        return ["BW_SESSION": session]
    }

    public func status() async -> PasswordProviderStatus {
        guard let bw = await runner.locate("bw") else { return .notInstalled }
        let result = await runner.run(bw, ["status"], environment: environment, input: nil)
        guard let status = JSONValue.parse(Data(result.stdout.utf8)) else { return .unavailable(OnePasswordProvider.firstLine(result.stderr)) }
        switch status["status"]?.string {
        case "unlocked": return .unlocked(account: status["userEmail"]?.string)
        case "locked": return .locked
        case "unauthenticated": return .needsSetup
        default: return .unavailable(OnePasswordProvider.firstLine(result.stderr))
        }
    }

    /// The unlocked session, so an agent's `bw` reads the vault without unlocking it again.
    public func agentEnvironment() -> [String: String] { environment }

    /// Unlocks with the master password the user typed, and keeps the session in the Keychain.
    public func unlock(password: String) async throws {
        guard let bw = await runner.locate("bw") else { throw PasswordProviderError.notInstalled("Bitwarden CLI") }
        let result = await runner.run(bw, ["unlock", "--passwordenv", "COINCIDE_BW_PASSWORD", "--raw"],
            environment: ["COINCIDE_BW_PASSWORD": password], input: nil)
        let session = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.succeeded, !session.isEmpty, !session.contains(where: \.isWhitespace) else {
            throw PasswordProviderError.failed(OnePasswordProvider.firstLine(result.stderr))
        }
        try sessions.write(session, for: Self.sessionAccount)
    }

    /// Locks the vault and forgets the session.
    public func lock() async {
        if let bw = await runner.locate("bw") { _ = await runner.run(bw, ["lock"], environment: environment, input: nil) }
        sessions.delete(Self.sessionAccount)
    }

    public func logins(for page: URL) async throws -> [LoginItem] {
        Self.parseList(try await run(["list", "items", "--url", page.absoluteString]))
    }

    public func secret(for item: LoginItem) async throws -> LoginSecret {
        guard let secret = Self.parseItem(try await run(["get", "item", item.itemID])) else { throw PasswordProviderError.notFound }
        guard secret.hasTOTP else { return secret }
        // The item holds the TOTP seed; `bw get totp` turns it into the current code.
        let code = try? await run(["get", "totp", item.itemID]).trimmingCharacters(in: .whitespacesAndNewlines)
        return LoginSecret(username: secret.username, password: secret.password, totp: code)
    }

    /// Runs `bw` with the session. Secrets it needs go in `input` (its standard input), never in `arguments`.
    func run(_ arguments: [String], input: String? = nil) async throws -> String {
        guard let bw = await runner.locate("bw") else { throw PasswordProviderError.notInstalled("Bitwarden CLI") }
        let environment = environment
        guard !environment.isEmpty else { throw PasswordProviderError.locked }
        let result = await runner.run(bw, arguments + ["--nointeraction"], environment: environment, input: input)
        guard result.succeeded else {
            if result.stderr.localizedCaseInsensitiveContains("locked") { throw PasswordProviderError.locked }
            throw PasswordProviderError.failed(OnePasswordProvider.firstLine(result.stderr))
        }
        return result.stdout
    }

    /// `bw list items`: logins (`type` 1) with `login.username`, `login.uris[].uri` and whether `login.totp` is set.
    static func parseList(_ json: String) -> [LoginItem] {
        (JSONValue.parse(Data(json.utf8))?.array ?? []).compactMap { entry in
            guard entry["type"]?.int == 1, let id = entry["id"]?.string, let login = entry["login"] else { return nil }
            return LoginItem(source: .bitwarden, itemID: id, title: entry["name"]?.string ?? "", username: login["username"]?.string ?? "",
                urls: (login["uris"]?.array ?? []).compactMap { $0["uri"]?.string },
                hasTOTP: login["totp"]?.string.map { !$0.isEmpty } ?? false)
        }
    }

    /// `bw get item`: the login's username and password; `totp` here is the seed, reported only as present.
    static func parseItem(_ json: String) -> LoginSecret? {
        guard let login = JSONValue.parse(Data(json.utf8))?["login"], let password = login["password"]?.string else { return nil }
        let hasSeed = login["totp"]?.string.map { !$0.isEmpty } ?? false
        return LoginSecret(username: login["username"]?.string ?? "", password: password, totp: hasSeed ? "pending" : nil)
    }
}
