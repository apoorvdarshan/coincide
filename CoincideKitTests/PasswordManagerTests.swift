import Foundation
import Testing
@testable import CoincideKit

/// Synthetic CLI outputs and in-memory secret stores only. No real password manager, vault or Keychain item is used.
@Suite struct LoginMatcherTests {
    func url(_ text: String) -> URL { URL(string: text)! }

    @Test func matchesLikeAPasswordManager() {
        let page = url("https://login.example.com/session")
        #expect(LoginMatcher.match(saved: "https://login.example.com", page: page) == .exactHost)
        #expect(LoginMatcher.match(saved: "example.com", page: page) == .parentHost)
        #expect(LoginMatcher.match(saved: "https://www.example.com/login", page: page) == .site)
        #expect(LoginMatcher.match(saved: "https://example.co.uk", page: page) == nil)
        for lookalike in ["https://example.com.evil.test", "https://evil-example.com", "https://login.example.com.attacker.io"] {
            #expect(LoginMatcher.match(saved: "https://example.com", page: url(lookalike)) == nil)
            #expect(LoginMatcher.match(saved: lookalike, page: page) == nil)
        }
        // Customers of a hosting platform are separate sites.
        #expect(LoginMatcher.match(saved: "https://alice.github.io", page: url("https://bob.github.io")) == nil)
        // An HTTPS login is never offered on plain HTTP; an address saved without a scheme may be.
        #expect(LoginMatcher.match(saved: "https://example.com", page: url("http://example.com")) == nil)
        #expect(LoginMatcher.match(saved: "example.com", page: url("http://example.com")) == .exactHost)
        // Local addresses: exact host and port only.
        #expect(LoginMatcher.match(saved: "http://localhost:3000", page: url("http://localhost:3000/login")) == .exactHost)
        #expect(LoginMatcher.match(saved: "http://localhost:3000", page: url("http://localhost:4000")) == nil)
        #expect(LoginMatcher.match(saved: "http://127.0.0.1", page: url("http://127.0.0.2")) == nil)
        #expect(LoginMatcher.match(saved: "ftp://example.com", page: page) == nil)
        #expect(LoginMatcher.match(saved: "https://example.com", page: url("file:///etc/passwd")) == nil)
    }

    @Test func ranksAndFiltersByHint() {
        let page = url("https://accounts.example.com/")
        let site = LoginItem(source: .coincide, itemID: "1", title: "Example", username: "a@x.test", urls: ["https://www.example.com"])
        let exact = LoginItem(source: .onePassword, itemID: "2", title: "Accounts", username: "b@x.test", urls: ["https://accounts.example.com"])
        let other = LoginItem(source: .bitwarden, itemID: "3", title: "Other", username: "c", urls: ["https://other.test"])
        #expect(LoginMatcher.ranked([site, other, exact], page: page).map(\.itemID) == ["2", "1"])
        #expect(LoginMatcher.filter([site, exact], hint: "a@x").map(\.itemID) == ["1"])
        #expect(LoginMatcher.filter([site, exact], hint: "2").map(\.itemID) == ["2"])
        #expect(LoginMatcher.filter([site, exact], hint: nil).count == 2)
    }
}

@Suite struct TOTPTests {
    @Test func rfc6238Vectors() throws {
        let secret = Data("12345678901234567890".utf8)
        let totp = TOTP(secret: secret, digits: 8)
        #expect(totp.code(at: Date(timeIntervalSince1970: 59)) == "94287082")
        #expect(totp.code(at: Date(timeIntervalSince1970: 1_111_111_109)) == "07081804")
        #expect(totp.code(at: Date(timeIntervalSince1970: 2_000_000_000)) == "69279037")
        #expect(TOTP.base32("GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ") == secret)
        let uri = try #require(TOTP("otpauth://totp/Example:a@x.test?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ&digits=8&issuer=Example"))
        #expect(uri.code(at: Date(timeIntervalSince1970: 59)) == "94287082")
        #expect(TOTP("not base32 !") == nil)
        #expect(TOTP("otpauth://hotp/x?secret=GEZDGNBV") == nil)
    }
}

/// Plays back scripted CLI output and records every call.
final class FakeRunner: PasswordCommandRunner, @unchecked Sendable {
    struct Call { var arguments: [String]; var environment: [String: String]; var input: String? }
    var installed: Set<String>
    var replies: [(prefix: [String], result: ProcessRunner.Result)] = []
    private(set) var calls: [Call] = []
    private let lock = NSLock()

    init(installed: Set<String>) { self.installed = installed }

    func reply(_ prefix: [String], stdout: String = "", stderr: String = "", status: Int32 = 0) {
        replies.append((prefix, ProcessRunner.Result(status: status, stdout: stdout, stderr: stderr)))
    }

    func locate(_ executable: String) async -> URL? {
        installed.contains(executable) ? URL(fileURLWithPath: "/fake/bin/" + executable) : nil
    }

    func run(_ executable: URL, _ arguments: [String], environment: [String: String], input: String?) async -> ProcessRunner.Result {
        lock.withLock {
            calls.append(Call(arguments: arguments, environment: environment, input: input))
            return replies.last { arguments.starts(with: $0.prefix) }?.result ?? ProcessRunner.Result(status: 1, stdout: "", stderr: "unexpected")
        }
    }

    var allArguments: String { lock.withLock { calls.flatMap(\.arguments).joined(separator: " ") } }
}

@Suite struct PasswordProviderTests {
    static let page = URL(string: "https://github.com/login")!

    @Test func onePasswordStatusListAndSecret() async throws {
        let runner = FakeRunner(installed: [])
        let provider = OnePasswordProvider(runner: runner)
        #expect(await provider.status() == .notInstalled)
        runner.installed = ["op"]
        runner.reply(["account", "list"], stdout: "[]")
        #expect(await provider.status() == .needsSetup)
        runner.reply(["account", "list"], stdout: #"[{"url":"my.1password.com","email":"me@example.test"}]"#)
        #expect(await provider.status() == .unlocksOnUse(account: "me@example.test"))
        runner.reply(["item", "list"], stdout: #"[{"id":"abc","title":"GitHub","additional_information":"octocat","urls":[{"primary":true,"href":"https://github.com/login"}]},{"id":"n","title":"Note"}]"#)
        let items = try await provider.logins(for: Self.page)
        #expect(items.map(\.itemID) == ["abc", "n"])
        #expect(items.first?.username == "octocat" && items.first?.urls == ["https://github.com/login"])
        runner.reply(["item", "get", "abc"], stdout: #"{"id":"abc","fields":[{"id":"username","purpose":"USERNAME","value":"octocat"},{"id":"password","purpose":"PASSWORD","type":"CONCEALED","value":"fixture-op-pass"},{"id":"t","type":"OTP","value":"otpauth://totp/x?secret=ABC","totp":"246810"}]}"#)
        let secret = try await provider.secret(for: items[0])
        #expect(secret.username == "octocat" && secret.appears(in: "fixture-op-pass") && secret.appears(in: "246810") && secret.hasTOTP)
        #expect(!runner.allArguments.contains("fixture-op-pass"))
        runner.reply(["item", "get", "abc"], stderr: "[ERROR] authorization prompt dismissed", status: 1)
        await #expect(throws: PasswordProviderError.self) { _ = try await provider.secret(for: items[0]) }
    }

    @Test func bitwardenUnlocksThroughTheEnvironmentAndKeepsTheSessionInTheStore() async throws {
        let runner = FakeRunner(installed: ["bw"])
        let store = MemorySecretStore()
        let provider = BitwardenProvider(runner: runner, sessions: store)
        runner.reply(["status"], stdout: #"{"status":"unauthenticated"}"#)
        #expect(await provider.status() == .needsSetup)
        runner.reply(["status"], stdout: #"{"status":"locked","userEmail":"me@example.test"}"#)
        #expect(await provider.status() == .locked)
        await #expect(throws: PasswordProviderError.locked) { _ = try await provider.logins(for: Self.page) }

        runner.reply(["unlock"], stdout: "fixture-session-key\n")
        try await provider.unlock(password: "fixture-master-password")
        let unlock = try #require(runner.calls.last)
        #expect(unlock.environment["COINCIDE_BW_PASSWORD"] == "fixture-master-password")
        #expect(!unlock.arguments.joined().contains("fixture-master-password"))
        #expect(store.read(BitwardenProvider.sessionAccount) == "fixture-session-key")

        runner.reply(["list", "items"], stdout: #"[{"id":"i1","type":1,"name":"GitHub","login":{"username":"octocat","password":"fixture-bw-pass","totp":"otpauth://totp/x?secret=ABC","uris":[{"uri":"https://github.com"}]}},{"id":"card","type":3,"name":"Card"}]"#)
        let items = try await provider.logins(for: Self.page)
        #expect(items.map(\.itemID) == ["i1"] && items[0].hasTOTP == true)
        #expect(runner.calls.last?.environment["BW_SESSION"] == "fixture-session-key")
        runner.reply(["get", "item", "i1"], stdout: #"{"id":"i1","login":{"username":"octocat","password":"fixture-bw-pass","totp":"otpauth://totp/x?secret=ABC"}}"#)
        runner.reply(["get", "totp", "i1"], stdout: "135790\n")
        let secret = try await provider.secret(for: items[0])
        #expect(secret.appears(in: "fixture-bw-pass") && secret.appears(in: "135790") && !secret.appears(in: "pending"))
        #expect(!runner.allArguments.contains("fixture-bw-pass") && !runner.allArguments.contains("fixture-session-key"))

        runner.reply(["lock"])
        await provider.lock()
        #expect(store.read(BitwardenProvider.sessionAccount) == nil)
    }

    @Test func coincideLoginsKeepSecretsOutOfTheirList() async throws {
        let folder = try FixtureFolder()
        let secrets = MemorySecretStore()
        let provider = CoincideLoginProvider(directory: folder.url, secrets: secrets)
        let page = try #require(URL(string: "https://app.example.test/login?next=/"))
        let saved = try provider.save(url: page, username: "me", password: "fixture-saved-pass", totpSeed: "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ")
        #expect(saved.url == "https://app.example.test")
        #expect(provider.isSaved(url: page, username: "me", password: "fixture-saved-pass"))
        #expect(!provider.isSaved(url: page, username: "me", password: "other"))
        let list = try String(contentsOf: folder.url.appendingPathComponent("browser-logins.json"), encoding: .utf8)
        #expect(!list.contains("fixture-saved-pass") && !list.contains("GEZDG"))
        let item = try #require(try await provider.logins(for: page).first)
        let secret = try await provider.secret(for: item)
        #expect(secret.appears(in: "fixture-saved-pass") && secret.hasTOTP)
        // Saving again replaces the password instead of adding a second login.
        try provider.save(url: page, username: "me", password: "fixture-new-pass")
        #expect(provider.saved.count == 1)
        try provider.delete(saved.id)
        #expect(provider.saved.isEmpty && secrets.allAccounts.isEmpty)
    }

    @Test func secretsNeverAppearInDescriptions() {
        let secret = LoginSecret(username: "me", password: "fixture-hidden", totp: "123456")
        var dumped = ""
        dump(secret, to: &dumped)
        for text in [secret.description, String(describing: secret), String(reflecting: secret), dumped, "\([secret])"] {
            #expect(!secret.appears(in: text))
        }
    }
}

/// A provider with fixed logins, for the vault.
struct StaticProvider: PasswordProvider {
    let kind: PasswordManagerKind
    let capabilities = PasswordCapabilities(lookupByDomain: false, totp: false)
    let items: [LoginItem]
    func status() async -> PasswordProviderStatus { .unlocked(account: nil) }
    func logins(for page: URL) async throws -> [LoginItem] { items }
    func secret(for item: LoginItem) async throws -> LoginSecret { LoginSecret(username: item.username, password: "pw-" + item.itemID, totp: nil) }
}

@MainActor @Suite struct PasswordVaultTests {
    @Test func resolvesApprovesAndRevokes() async throws {
        let folder = try FixtureFolder()
        let settings = BrowserSettingsStore(directory: folder.url)
        let work = LoginItem(source: .onePassword, itemID: "w", title: "Work", username: "me@work.test", urls: ["https://example.com"])
        let home = LoginItem(source: .bitwarden, itemID: "h", title: "Home", username: "me@home.test", urls: ["https://example.com"])
        let vault = PasswordVault(settings: settings, providers: [StaticProvider(kind: .onePassword, items: [work]), StaticProvider(kind: .bitwarden, items: [home])])
        let page = try #require(URL(string: "https://example.com/login"))
        await #expect(throws: LoginFillError.noPasswordManager) { _ = try await vault.resolve(page: page, hint: nil) }
        settings.update { $0.passwordManagers = [.onePassword] }
        #expect(try await vault.resolve(page: page, hint: nil) == work)
        await #expect(throws: LoginFillError.noMatch(site: "other.test")) {
            _ = try await vault.resolve(page: URL(string: "https://other.test")!, hint: nil)
        }
        settings.update { $0.passwordManagers = [.onePassword, .bitwarden] }
        await #expect(throws: LoginFillError.self) { _ = try await vault.resolve(page: page, hint: nil) }
        #expect(try await vault.resolve(page: page, hint: "home") == home)

        let thread = UUID(), other = UUID()
        #expect(!vault.isApproved(home, page: page, threadID: thread))
        let now = Date()
        vault.record(.allowOnce, for: home, page: page, threadID: thread, now: now)
        #expect(vault.isApproved(home, page: page, threadID: thread, now: now))
        #expect(!vault.isApproved(home, page: page, threadID: other, now: now))
        #expect(!vault.isApproved(home, page: page, threadID: thread, now: now.addingTimeInterval(PasswordVault.onceDuration + 1)))
        vault.record(.always, for: home, page: URL(string: "https://www.example.com")!, threadID: thread)
        #expect(vault.isApproved(home, page: page, threadID: other))
        // The granted item settles a tie.
        #expect(try await vault.resolve(page: page, hint: nil) == home)
        #expect(settings.settings.loginGrants.map(\.site) == ["example.com"])
        vault.revoke(try #require(settings.settings.loginGrants.first))
        #expect(!vault.isApproved(home, page: page, threadID: other))
        // Signing in anywhere without asking approves every site and thread, and saves to browser.json.
        #expect(!BrowserSettings().agentsSignInWithoutAsking)
        settings.update { $0.agentsSignInWithoutAsking = true }
        #expect(vault.isApproved(home, page: page, threadID: other))
        #expect(vault.isApproved(work, page: URL(string: "https://other.test/login")!, threadID: UUID()))
        #expect(BrowserSettingsStore(directory: folder.url).settings.agentsSignInWithoutAsking)
        settings.update { $0.agentsSignInWithoutAsking = false }
        #expect(!vault.isApproved(home, page: page, threadID: other))
        // A manager that's turned off can't hand out secrets.
        settings.update { $0.passwordManagers = [.onePassword] }
        await #expect(throws: LoginFillError.noPasswordManager) { _ = try await vault.secret(for: home) }
    }

    /// Agents get Bitwarden's unlocked session only while Bitwarden is on and the user lets agents use it.
    @Test func agentsGetTheUnlockedSessionOfEnabledManagers() async throws {
        let folder = try FixtureFolder()
        let settings = BrowserSettingsStore(directory: folder.url)
        let sessions = MemorySecretStore()
        let bitwarden = BitwardenProvider(runner: FakeRunner(installed: ["bw"]), sessions: sessions)
        let vault = PasswordVault(settings: settings, providers: [bitwarden, StaticProvider(kind: .onePassword, items: [])])
        #expect(BrowserSettings().agentsUsePasswordManagers)
        try sessions.write("fixture-session-key", for: BitwardenProvider.sessionAccount)
        #expect(vault.agentEnvironment().isEmpty)
        settings.update { $0.passwordManagers = [.bitwarden, .onePassword] }
        #expect(vault.agentEnvironment() == ["BW_SESSION": "fixture-session-key"])
        settings.update { $0.agentsUsePasswordManagers = false }
        #expect(vault.agentEnvironment().isEmpty)
        settings.update { $0.agentsUsePasswordManagers = true }
        sessions.delete(BitwardenProvider.sessionAccount)
        #expect(vault.agentEnvironment().isEmpty)
        // Settings saved before the switch existed let agents use the managers.
        let old = try JSONDecoder().decode(BrowserSettings.self, from: Data(#"{"passwordManagers": ["bitwarden"]}"#.utf8))
        #expect(old.agentsUsePasswordManagers)
    }

    @Test func approvalGateDeniesOnTimeout() async {
        let gate = LoginApprovalGate()
        let item = LoginItem(source: .coincide, itemID: "1", title: "x", username: "u", urls: [])
        let answer = Task { await gate.ask(site: "example.com", item: item, timeout: 60) }
        await Task.yield()
        #expect(gate.request?.site == "example.com")
        gate.answer(.always)
        #expect(await answer.value == .always)
        #expect(await gate.ask(site: "example.com", item: item, timeout: 0.2) == .deny)
    }

    @Test func fillLoginCommandParses() throws {
        #expect(try PreviewCommand(json: ["action": "fill-login"]) == .fillLogin(item: nil))
        #expect(try PreviewCommand(json: ["action": "fill-login", "item": "Work"]) == .fillLogin(item: "Work"))
        #expect(throws: PreviewError.self) { try PreviewCommand(json: ["action": "fill-login", "item": .string(String(repeating: "x", count: 201))]) }
        #expect(PreviewCommand.fillLogin(item: nil).timeout > LoginApprovalGate.timeout)
    }
}
