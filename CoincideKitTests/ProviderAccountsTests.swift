import Foundation
import Testing

@testable import CoincideKit

/// Accounts per provider: decoding data written before them, each account's environment, the runner keeping each
/// account's native session apart, and the Keychain wrapper.
struct ProviderAccountDecodingTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    @Test func selectionsAndSessionsWrittenBeforeAccountsUseTheDefaultAccount() throws {
        let selection = try decode(ModelSelection.self, #"{"provider":"claude","modelID":"sonnet","effort":"high"}"#)
        #expect(selection.accountID == nil)
        #expect(selection.account == ProviderAccount.defaultID)
        let ref = try decode(ProviderSessionRef.self, #"{"sessionID":"s1","seenItemCount":4}"#)
        #expect(ref.accountID == nil)
        #expect(ref.foreignItemsBefore == nil)
        // Nothing new is written for the default account, so old versions read the files as before.
        let encoded = String(decoding: try JSONEncoder().encode(selection), as: UTF8.self)
        #expect(!encoded.contains("accountID"))
    }

    @Test func aThreadWithoutAccountSessionsLoadsAndSavesWithoutThem() throws {
        let project = UUID()
        let json = """
            {"id":"\(UUID().uuidString)","projectID":"\(project.uuidString)","title":"T",
             "selection":{"provider":"codex","modelID":"gpt"},"items":[],"sessions":["codex",{"sessionID":"c1","seenItemCount":0}]}
            """
        let thread = try decode(ChatThread.self, json)
        #expect(thread.accountSessions == nil)
        #expect(thread.sessions[.codex]?.sessionID == "c1")
        let encoded = String(decoding: try JSONEncoder().encode(thread), as: UTF8.self)
        #expect(!encoded.contains("accountSessions"))
    }

    @Test func unreadableAccountsAreSkippedAndTheDefaultIdIsReserved() throws {
        let json = """
            {"isEnabled":true,"accounts":[
              {"id":"a","provider":"claude","name":"Work","auth":"apiKey"},
              {"id":"default","provider":"claude","name":"Impostor"},
              {"id":"b","provider":"claude","auth":"someFutureMethod"},
              {"provider":"claude"},
              {"id":"a","provider":"claude","name":"Duplicate"}]}
            """
        let settings = try decode(ProviderSettings.self, json)
        #expect(settings.accounts.map(\.id) == ["a", "b"])
        #expect(settings.accounts[1].auth == .login)
        #expect(settings.accounts[1].name == ProviderKind.claude.displayName)
        #expect(settings.allAccounts(of: .claude).map(\.id) == ["default", "a", "b"])
        let old = try decode(ProviderSettings.self, #"{"isEnabled":false,"customModels":["x"]}"#)
        #expect(old.accounts.isEmpty)
    }
}

struct ProviderAccountEnvironmentTests {
    private let data = URL(fileURLWithPath: "/tmp/coincide-data")
    private let shell = ["PATH": "/usr/bin", "ANTHROPIC_API_KEY": "from-shell", "OPENROUTER_API_KEY": "shell-router"]

    @Test func theDefaultAccountChangesNothing() {
        let account = ProviderAccount.defaultAccount(for: .claude)
        #expect(account.environment(shell, dataDirectory: data, apiKey: "ignored") == shell)
    }

    @Test func aLoginAccountGetsItsOwnHomeAndNoInheritedKey() {
        let account = ProviderAccount(id: "work", provider: .claude, name: "Work", auth: .login, environment: ["EXTRA": "1"])
        let environment = account.environment(shell, dataDirectory: data, apiKey: nil)
        #expect(environment["CLAUDE_CONFIG_DIR"] == "/tmp/coincide-data/providers/claude/work")
        #expect(environment["ANTHROPIC_API_KEY"] == nil)
        #expect(environment["EXTRA"] == "1")
        #expect(environment["PATH"] == "/usr/bin")
    }

    @Test func anAPIKeyAccountGetsItsKeyInTheCLIsVariable() {
        let claude = ProviderAccount(id: "api", provider: .claude, name: "API", auth: .apiKey)
        let environment = claude.environment(shell, dataDirectory: data, apiKey: "sk-test")
        #expect(environment["ANTHROPIC_API_KEY"] == "sk-test")
        // Claude reads a key over its shared settings, so it keeps the usual home.
        #expect(environment["CLAUDE_CONFIG_DIR"] == nil)
        let codex = ProviderAccount(id: "key", provider: .codex, name: "Key", auth: .apiKey)
        let codexEnvironment = codex.environment([:], dataDirectory: data, apiKey: "sk-openai")
        #expect(codexEnvironment["OPENAI_API_KEY"] == "sk-openai")
        #expect(codexEnvironment["CODEX_HOME"] == "/tmp/coincide-data/providers/codex/key")
        let cursor = ProviderAccount(id: "c", provider: .cursor, name: "C", auth: .apiKey)
        #expect(cursor.environment([:], dataDirectory: data, apiKey: "ck")["CURSOR_API_KEY"] == "ck")
        let grok = ProviderAccount(id: "g", provider: .grok, name: "G", auth: .apiKey)
        #expect(grok.environment([:], dataDirectory: data, apiKey: "xk")["XAI_API_KEY"] == "xk")
    }

    @Test func anOpenCodeAccountUsesTheChosenServicesKeyInAHomeOfItsOwn() {
        var account = ProviderAccount(id: "zen", provider: .opencode, name: "Zen", auth: .apiKey)
        var environment = account.environment(shell, dataDirectory: data, apiKey: "zen-key")
        #expect(environment["OPENCODE_API_KEY"] == "zen-key")
        #expect(environment["XDG_DATA_HOME"] == "/tmp/coincide-data/providers/opencode/zen")
        // Other services' keys from the shell would add their providers to this account too.
        #expect(environment["ANTHROPIC_API_KEY"] == nil && environment["OPENROUTER_API_KEY"] == nil)
        account.apiKeyVariable = "OPENROUTER_API_KEY"
        environment = account.environment(shell, dataDirectory: data, apiKey: "router-key")
        #expect(environment["OPENROUTER_API_KEY"] == "router-key")
        #expect(environment["OPENCODE_API_KEY"] == nil)
        // A variable the agent does not offer falls back to its own.
        account.apiKeyVariable = "PATH"
        #expect(account.keyVariable == "OPENCODE_API_KEY")
    }

    @Test func everyProviderOffersAccountsWithTheMethodsItsCLISupports() {
        #expect(ProviderKind.claude.accountAuthMethods == [.login, .apiKey])
        #expect(ProviderKind.codex.accountAuthMethods == [.login, .apiKey])
        #expect(ProviderKind.grok.accountAuthMethods == [.login, .apiKey])
        #expect(ProviderKind.opencode.accountAuthMethods == [.login, .apiKey])
        #expect(ProviderKind.cursor.accountAuthMethods == [.apiKey])
        #expect(ProviderKind.antigravity.accountAuthMethods == [.apiKey])
        #expect(ProviderKind.opencode.loginArguments == ["auth", "login", "--standalone"])
    }
}

struct AccountSessionTests {
    private func thread(items: Int) -> ChatThread {
        var thread = ChatThread(projectID: UUID(), selection: ModelSelection(provider: .claude, modelID: "m"))
        thread.items = (0..<items).map { _ in TranscriptItem(kind: .assistant, text: "x", provider: .claude) }
        return thread
    }

    @Test func switchingAccountsSetsTheOtherSessionAsideAndBringsItBack() {
        var thread = thread(items: 2)
        thread.sessions[.claude] = ProviderSessionRef(sessionID: "default-1", seenItemCount: 2)
        let parked = thread.activateAccount("work", for: .claude)
        #expect(parked)
        #expect(thread.sessions[.claude] == nil)
        #expect(thread.session(.claude, account: ProviderAccount.defaultID)?.sessionID == "default-1")
        thread.sessions[.claude] = ProviderSessionRef(sessionID: "work-1", seenItemCount: 4, accountID: "work")
        thread.items += [TranscriptItem(kind: .user, text: "q"), TranscriptItem(kind: .assistant, text: "a", provider: .claude)]
        let restored = thread.activateAccount(ProviderAccount.defaultID, for: .claude)
        #expect(restored)
        #expect(thread.sessions[.claude]?.sessionID == "default-1")
        #expect(thread.sessions[.claude]?.foreignItemsBefore == 4)
        #expect(thread.accountSessions?["claude/work"]?.sessionID == "work-1")
        let again = thread.activateAccount(ProviderAccount.defaultID, for: .claude)
        #expect(!again)
    }

    @Test func theRecapCoversWhatAnotherAccountOfTheSameAgentDid() {
        var thread = thread(items: 0)
        thread.items = [
            TranscriptItem(kind: .user, text: "first"), TranscriptItem(kind: .assistant, text: "one", provider: .claude),
        ]
        thread.sessions[.claude] = ProviderSessionRef(sessionID: "d", seenItemCount: 2)
        thread.activateAccount("work", for: .claude)
        thread.items += [
            TranscriptItem(kind: .user, text: "second"), TranscriptItem(kind: .assistant, text: "two", provider: .claude),
        ]
        thread.sessions[.claude] = ProviderSessionRef(sessionID: "w", seenItemCount: 4, accountID: "work")
        // Without accounts the default would think the provider's own items need no recap.
        thread.activateAccount(ProviderAccount.defaultID, for: .claude)
        let missed = Handoff.missedItems(in: thread, for: .claude)
        #expect(missed.map(\.text) == ["second", "two"])
        #expect(Handoff.recap(thread: thread, provider: .claude)?.contains("two") == true)
    }
}

@MainActor
struct ProviderAccountRunnerTests {
    private let store: AppStore
    private let defaultClaude = ScriptedProvider(kind: .claude)
    private let workClaude = ScriptedProvider(kind: .claude)
    private let registry: ProviderRegistry
    private let runner: ThreadRunner
    private let threadID: UUID
    private let work = ProviderAccount(id: "work", provider: .claude, name: "Work", auth: .login)

    init() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-accounts-\(UUID().uuidString)")
        store = AppStore(directory: dir)
        let accounts = [work]
        store.updateSettings {
            $0.checkpointsEnabled = false
            $0.generatesThreadTitles = false
            $0.providers[.claude] = ProviderSettings(accounts: accounts)
        }
        let workProvider = workClaude
        registry = ProviderRegistry(
            store: store, providers: [defaultClaude], makeProvider: { account in account.id == "work" ? workProvider : nil })
        runner = ThreadRunner(store: store, registry: registry)
        let project = store.addProject(at: URL(fileURLWithPath: "/tmp"))
        threadID = store.createThread(in: project.id, selection: ModelSelection(provider: .claude, modelID: "m")).id
        for provider in [defaultClaude, workClaude] {
            provider.configure = { session in
                session.onSend = { session, _ in
                    session.emit(.assistantText(itemID: UUID().uuidString, text: "reply"))
                    session.emit(.turnCompleted(.completed))
                }
            }
        }
    }

    private func use(_ account: String?) {
        store.updateThread(threadID) { $0.selection = ModelSelection(provider: .claude, modelID: "m", accountID: account) }
    }

    @Test func eachAccountRunsItsOwnSessionWithItsOwnHome() async throws {
        await registry.refresh(.claude, account: "work")
        #expect(registry.status(.claude, account: "work").state == .ready)
        await runner.send(threadID: threadID, text: "hello")
        let first = try #require(defaultClaude.last)
        #expect(defaultClaude.launches.last?.environment["CLAUDE_CONFIG_DIR"] == nil)

        use("work")
        await runner.send(threadID: threadID, text: "now on work")
        #expect(first.isShutDown)
        let launch = try #require(workClaude.launches.last)
        #expect(launch.resumeSessionID == nil)
        #expect(launch.environment["CLAUDE_CONFIG_DIR"] == work.home(in: store.directory).path)
        #expect(workClaude.last?.sent.last?.handoffRecap?.contains("hello") == true)
        let thread = try #require(store.thread(threadID))
        #expect(thread.sessions[.claude]?.accountID == "work")
        #expect(thread.accountSessions?["claude/default"]?.sessionID == first.sessionID)

        // Back on the default account: its own session resumes and hears what the work account did.
        use(nil)
        await runner.send(threadID: threadID, text: "back")
        #expect(defaultClaude.launches.last?.resumeSessionID == first.sessionID)
        #expect(defaultClaude.last?.sent.last?.handoffRecap?.contains("now on work") == true)
        #expect(store.thread(threadID)?.sessions[.claude]?.accountID == nil)
    }

    @Test func aRemovedAccountFallsBackToTheDefault() {
        store.updateSettings { $0.providers[.claude]?.accounts = [] }
        let selection = ModelSelection(provider: .claude, modelID: "m", accountID: "work")
        #expect(registry.account(for: selection).isDefault)
    }

    @Test func usageLimitsAreKeptPerAccount() {
        let window = UsageLimitWindow(id: "session", kind: .session, label: "Session", usedPercent: 90, resetsAt: nil)
        _ = runner.recordUsageLimits([window], for: .claude, account: "work")
        #expect(runner.usageLimits(for: .claude, account: "work")?.windows.first?.usedPercent == 90)
        #expect(runner.usageLimits(for: .claude)?.windows.isEmpty != false)
    }
}

/// Uses a service of its own, so it never touches Coincide's real items.
/// Whether this machine's Keychain takes items (a locked or missing one, as on some CI runners, does not).
private let keychainAvailable: Bool = {
    let probe = KeychainStore(service: "com.apoorvdarshan.coincide.tests.probe.\(UUID().uuidString)")
    guard (try? probe.set("x", for: "probe")) != nil else { return false }
    try? probe.remove("probe")
    return true
}()

@Suite(.enabled(if: keychainAvailable))
struct KeychainStoreTests {
    @Test func storesReplacesAndRemovesAValue() throws {
        let keychain = KeychainStore(service: "com.apoorvdarshan.coincide.tests.\(UUID().uuidString)")
        defer { try? keychain.remove("account") }
        #expect(try keychain.value(for: "account") == nil)
        #expect(!keychain.contains("account"))
        try keychain.set("first", for: "account")
        #expect(try keychain.value(for: "account") == "first")
        try keychain.set("second", for: "account", label: "Test")
        #expect(try keychain.value(for: "account") == "second")
        #expect(keychain.contains("account"))
        try keychain.remove("account")
        #expect(try keychain.value(for: "account") == nil)
        try keychain.remove("account")
    }

    @Test func anAdminKeyIsKeptApartFromTheAccountsAPIKey() throws {
        let secrets = ProviderAccountSecrets(keychain: KeychainStore(service: "com.apoorvdarshan.coincide.tests.\(UUID().uuidString)"))
        let account = ProviderAccount(id: UUID().uuidString, provider: .claude, name: "API", auth: .apiKey)
        defer {
            try? secrets.removeAPIKey(for: account)
            try? secrets.removeAdminKey(for: account)
        }
        try secrets.setAPIKey("sk-ant-api03-test", for: account)
        #expect(!secrets.hasAdminKey(account) && secrets.adminKey(for: account) == nil)
        try secrets.setAdminKey("sk-ant-admin01-test", for: account)
        #expect(secrets.adminKey(for: account) == "sk-ant-admin01-test")
        #expect(secrets.apiKey(for: account) == "sk-ant-api03-test")
        try secrets.removeAdminKey(for: account)
        #expect(!secrets.hasAdminKey(account) && secrets.hasAPIKey(account))
        #expect(secrets.adminKey(for: .defaultAccount(for: .claude)) == nil)
    }

    @Test func secretsAreKeptPerAccountAndNeverForTheDefault() throws {
        let secrets = ProviderAccountSecrets(keychain: KeychainStore(service: "com.apoorvdarshan.coincide.tests.\(UUID().uuidString)"))
        let account = ProviderAccount(id: UUID().uuidString, provider: .claude, name: "API", auth: .apiKey)
        defer { try? secrets.removeAPIKey(for: account) }
        try secrets.setAPIKey("sk-test", for: account)
        #expect(secrets.apiKey(for: account) == "sk-test")
        #expect(secrets.hasAPIKey(account))
        #expect(secrets.apiKey(for: .defaultAccount(for: .claude)) == nil)
    }
}
