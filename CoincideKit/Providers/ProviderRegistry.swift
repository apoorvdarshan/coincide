import Foundation

/// Holds every provider, their detected status and their models.
@MainActor
public final class ProviderRegistry {
    public static let shared = ProviderRegistry(store: .shared)

    public let providers: [ProviderKind: AgentProvider]
    public private(set) var statuses: [ProviderKind: ProviderStatus] = [:]
    public private(set) var discoveredModels: [ProviderKind: [ModelOption]] = [:]
    private var discoveredCommands: [ProviderKind: [ProviderCommand]] = [:]
    /// True while any provider or account is being checked.
    public var isRefreshing: Bool { !running.isEmpty || !accountChecks.isEmpty }

    /// The added accounts' state, by account id; the default accounts' is in `statuses` and the other maps above.
    /// Each account gets a provider instance of its own, because providers cache what their last check found.
    private var accountProviders: [String: AgentProvider] = [:]
    private var accountStatuses: [String: ProviderStatus] = [:]
    private var accountModels: [String: [ModelOption]] = [:]
    private var accountCommands: [String: [ProviderCommand]] = [:]
    private var accountChecks: [String: Task<Void, Never>] = [:]
    private let makeProvider: (ProviderAccount) -> AgentProvider?
    /// What API-key accounts' own usage reads (`APIKeyUsage`) last found, by account id.
    private var keyUsage: [String: UsageLimits] = [:]
    /// Sends those reads; tests answer them without the network.
    var keyUsageFetch: UsageLimitsFetch = UsageLimitsHTTP.live
    /// Where the accounts' API keys are kept.
    public let secrets: ProviderAccountSecrets

    private let store: AppStore
    private let shell: ShellEnvironment
    /// Per provider: the latest check asked for, the latest one finished, and the one running.
    /// One check runs at a time; a request made while one runs gets a fresh check after it.
    private var requested: [ProviderKind: Int] = [:]
    private var completed: [ProviderKind: Int] = [:]
    private var running: [ProviderKind: Task<Void, Never>] = [:]
    private var lastChecked: [ProviderKind: Date] = [:]
    private var activationObserver: NSObjectProtocol?
    /// How old the login shell environment must be before `refreshUnavailable` reads it again for a CLI
    /// that is not installed. Reading it costs a full interactive shell startup; Settings' Refresh still
    /// reads it at once.
    var environmentRereadAge: TimeInterval = 15 * 60

    /// `makeProvider` builds the provider instance of an added account. It defaults to a built-in provider, or with
    /// `providers` given (tests), to that provider itself.
    public init(
        store: AppStore, providers: [AgentProvider]? = nil, shell: ShellEnvironment = .shared,
        secrets: ProviderAccountSecrets = .standard, makeProvider: ((ProviderAccount) -> AgentProvider?)? = nil
    ) {
        self.store = store
        self.shell = shell
        self.secrets = secrets
        let all = providers ?? Self.builtInProviders(store: store)
        let byKind = Dictionary(all.map { ($0.kind, $0) }, uniquingKeysWith: { first, _ in first })
        self.providers = byKind
        self.makeProvider =
            makeProvider
            ?? (providers == nil
                ? { account in Self.builtInProvider(for: account, store: store) } : { byKind[$0.provider] })
        // Coming back to Coincide after installing or signing in to an agent finds it without a manual refresh.
        activationObserver = NotificationCenter.default.addObserver(
            forName: Self.didBecomeActive, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.refreshUnavailable(olderThan: 60) }
            }
        }
    }

    isolated deinit {
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
    }

    /// `NSApplication.didBecomeActiveNotification`, without importing AppKit.
    private static let didBecomeActive = Notification.Name("NSApplicationDidBecomeActiveNotification")

    /// Every provider Coincide ships, reading their settings from `store`.
    public static func builtInProviders(store: AppStore = .shared) -> [AgentProvider] {
        [.claude, .codex, .cursor, .grok, .opencode, .antigravity].map { builtInProvider($0, store: store) }
    }

    static func builtInProvider(_ kind: ProviderKind, store: AppStore?) -> AgentProvider {
        switch kind {
        case .claude: ClaudeProvider()
        case .codex: CodexProvider()
        case .cursor: CursorProvider(keychainUsageAllowed: { store?.settings.cursorKeychainUsageEnabled ?? false })
        case .grok: ACPProvider(profile: .grok)
        case .opencode: OpenCodeProvider()
        case .antigravity: ACPProvider(profile: .antigravity)
        }
    }

    /// An added account's provider. An Antigravity account runs in a private profile of its own, in its home.
    static func builtInProvider(for account: ProviderAccount, store: AppStore) -> AgentProvider {
        builtInProvider(
            for: account, dataDirectory: store.directory,
            cursorKeychainUsageAllowed: { store.settings.cursorKeychainUsageEnabled })
    }

    /// The built-in provider of an account, without a store: the agent host makes its sessions from these.
    public static func builtInProvider(
        for account: ProviderAccount, dataDirectory: URL, cursorKeychainUsageAllowed: @escaping @MainActor () -> Bool
    ) -> AgentProvider {
        guard account.provider == .antigravity, !account.isDefault else {
            if account.provider == .cursor { return CursorProvider(keychainUsageAllowed: cursorKeychainUsageAllowed) }
            return builtInProvider(account.provider, store: nil)
        }
        let profile = AntigravityProfile(geminiHome: account.home(in: dataDirectory))
        let usesAPIKey = account.auth == .apiKey
        return ACPProvider(profile: .antigravity) { AntigravityFlavor(profile: profile, usesAPIKey: usesAPIKey) }
    }

    public func provider(_ kind: ProviderKind) -> AgentProvider? { providers[kind] }

    public func status(_ kind: ProviderKind) -> ProviderStatus { statuses[kind] ?? .unknown }

    /// Providers in display order.
    public var orderedKinds: [ProviderKind] { ProviderKind.allCases.filter { providers[$0] != nil } }

    /// Providers that are enabled, installed and signed in with at least one account.
    public var readyKinds: [ProviderKind] { orderedKinds.filter(isReady) }

    /// Whether any account of the provider can run.
    public func isReady(_ kind: ProviderKind) -> Bool {
        accounts(for: kind).contains { status(kind, account: $0.id).state == .ready }
    }

    // MARK: Accounts

    /// The provider's default account followed by the ones the user added.
    public func accounts(for kind: ProviderKind) -> [ProviderAccount] {
        store.settings.settings(for: kind).allAccounts(of: kind)
    }

    /// The account with `id`, or the default account for nil or an account that was removed, so a thread that used
    /// it keeps working.
    public func account(_ id: String?, of kind: ProviderKind) -> ProviderAccount {
        accounts(for: kind).first { $0.id == (id ?? ProviderAccount.defaultID) } ?? .defaultAccount(for: kind)
    }

    public func account(for selection: ModelSelection) -> ProviderAccount { account(selection.accountID, of: selection.provider) }

    /// The selection's account name, when the provider has more than one account to tell apart.
    public func accountName(for selection: ModelSelection) -> String? {
        accounts(for: selection.provider).count > 1 ? account(for: selection).name : nil
    }

    public func status(_ kind: ProviderKind, account id: String?) -> ProviderStatus {
        let account = self.account(id, of: kind)
        guard !account.isDefault else { return status(kind) }
        // A disabled provider's accounts are off with it.
        guard store.settings.settings(for: kind).isEnabled else { return status(kind) }
        return accountStatuses[account.id] ?? .unknown
    }

    public func status(for selection: ModelSelection) -> ProviderStatus { status(selection.provider, account: selection.accountID) }

    /// The provider instance that runs an account's sessions.
    public func provider(_ kind: ProviderKind, account id: String?) -> AgentProvider? {
        let account = self.account(id, of: kind)
        guard !account.isDefault else { return providers[kind] }
        if let existing = accountProviders[account.id] { return existing }
        guard providers[kind] != nil, let made = makeProvider(account) else { return nil }
        accountProviders[account.id] = made
        return made
    }

    /// An account's models: what its own check found plus the user's custom ids.
    public func models(for kind: ProviderKind, account id: String?) -> [ModelOption] {
        let account = self.account(id, of: kind)
        guard !account.isDefault else { return models(for: kind) }
        return withCustomModels(accountModels[account.id] ?? [], of: kind)
    }

    public func pickerModels(for kind: ProviderKind, account id: String?, current: ModelSelection?) -> [ModelOption] {
        store.settings.pickerModels(models(for: kind, account: id), current: current)
    }

    public func commands(for kind: ProviderKind, account id: String?) -> [ProviderCommand] {
        let account = self.account(id, of: kind)
        guard !account.isDefault else { return commands(for: kind) }
        return accountCommands[account.id] ?? status(kind, account: account.id).commands
    }

    public func updateCommands(_ commands: [ProviderCommand], for kind: ProviderKind, account id: String?) {
        let account = self.account(id, of: kind)
        guard !account.isDefault else { return updateCommands(commands, for: kind) }
        guard accountCommands[account.id] != commands else { return }
        accountCommands[account.id] = commands
        store.notify(.providers)
    }

    public func updateModels(_ models: [ModelOption], for kind: ProviderKind, account id: String?) {
        let account = self.account(id, of: kind)
        guard !account.isDefault else { return updateModels(models, for: kind) }
        guard !models.isEmpty else { return }
        accountModels[account.id] = models
        store.notify(.providers)
    }

    /// An account's environment: the provider's (`environment(for:)`) with the account's home, API key and variables.
    public func environment(for kind: ProviderKind, account id: String?) async -> [String: String] {
        await environment(for: kind, account: account(id, of: kind), fresh: false)
    }

    public func environment(for selection: ModelSelection) async -> [String: String] {
        await environment(for: selection.provider, account: selection.accountID)
    }

    private func environment(for kind: ProviderKind, account: ProviderAccount, fresh: Bool) async -> [String: String] {
        let base = await environment(for: kind, fresh: fresh)
        guard !account.isDefault else { return base }
        if account.usesOwnHome { Self.prepareHome(account.home(in: store.directory)) }
        let apiKey = account.auth == .apiKey ? secrets.apiKey(for: account) : nil
        return account.environment(base, dataDirectory: store.directory, apiKey: apiKey)
    }

    /// What a terminal signing an account in needs on top of the login shell's environment: the provider's variables,
    /// the account's own and its home. Never its API key.
    public func signInEnvironment(for kind: ProviderKind, account id: String?) -> [String: String] {
        let account = self.account(id, of: kind)
        var environment = store.settings.settings(for: kind).environment
        if account.usesOwnHome { Self.prepareHome(account.home(in: store.directory)) }
        environment = account.environment(environment, dataDirectory: store.directory, apiKey: nil)
        return environment
    }

    /// The folder an account keeps its CLI state in, readable only by the user.
    private static func prepareHome(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    /// Stores an account's API key in the Keychain and checks the account again. Codex reads a key only from
    /// `auth.json`, so for Codex the key is also handed to `codex login --with-api-key` (on stdin) in the account's home.
    public func saveAPIKey(_ key: String, for account: ProviderAccount) async throws {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !account.isDefault, !key.isEmpty else { return }
        try secrets.setAPIKey(key, for: account)
        if account.provider == .codex, let executable = await executable(for: .codex) {
            let environment = await environment(for: .codex, account: account, fresh: false)
            let result = await ProcessRunner.run(
                executable, ["login", "--with-api-key"], environment: environment, timeout: 60, input: key + "\n")
            if !result.succeeded {
                throw ProviderAccountError(message: String(localized: "Codex didn’t accept the API key (status \(Int(result.status)))."))
            }
        }
        // A provider instance remembers what its last check found, so the next check starts afresh.
        accountProviders[account.id] = nil
        await refresh(account.provider, account: account.id)
    }

    /// Removes an account's API key from the Keychain; Codex's copy goes with the account's home.
    public func removeAPIKey(for account: ProviderAccount) async throws {
        try secrets.removeAPIKey(for: account)
        accountProviders[account.id] = nil
        await refresh(account.provider, account: account.id)
    }

    /// Forgets what the registry knew of an account the user removed: its checks, models and provider instance.
    public func forgetAccount(_ id: String) {
        accountChecks.removeValue(forKey: id)?.cancel()
        accountProviders[id] = nil
        accountStatuses[id] = nil
        accountModels[id] = nil
        accountCommands[id] = nil
        keyUsage[id] = nil
        store.notify(.providers)
    }

    /// Checks one account again, waiting for a check that already runs to finish first so the result reflects the
    /// latest settings.
    public func refresh(_ kind: ProviderKind, account id: String) async {
        let account = self.account(id, of: kind)
        guard !account.isDefault else { return await refresh(kind) }
        store.notify(.providers)
        await checkAccount(account)
        store.notify(.providers)
    }

    private func checkAccount(_ account: ProviderAccount) async {
        if let current = accountChecks[account.id] { await current.value }
        let task = Task { @MainActor in await self.refreshAccountNow(account.id, of: account.provider) }
        accountChecks[account.id] = task
        await task.value
        if accountChecks[account.id] == task { accountChecks[account.id] = nil }
    }

    private func refreshAccountNow(_ id: String, of kind: ProviderKind) async {
        // Read again: the account may have changed or gone while an earlier check ran.
        guard let account = accounts(for: kind).first(where: { $0.id == id }), !account.isDefault else { return }
        guard store.settings.settings(for: kind).isEnabled, let provider = self.provider(kind, account: id) else {
            accountStatuses[id] = nil
            accountModels[id] = []
            return
        }
        if account.auth == .apiKey, !secrets.hasAPIKey(account) {
            let executable = await executable(for: kind, fresh: true)
            accountStatuses[id] = ProviderStatus(
                state: executable == nil ? .notInstalled : .notAuthenticated, executable: executable,
                message: String(localized: "Add an API key for \(account.name) in Settings › Providers."))
            accountModels[id] = []
            return
        }
        let environment = await environment(for: kind, account: account, fresh: true)
        let executable = await executable(for: kind, fresh: true)
        var status = await provider.detect(executable: executable, environment: environment)
        guard !Task.isCancelled else { return }
        if account.auth == .apiKey, status.state == .ready, let key = secrets.apiKey(for: account),
            let outcome = await APIKeyUsage.read(variable: account.keyVariable, key: key, fetch: keyUsageFetch)
        {
            // A failed read keeps what the last one found.
            let read = outcome.resolved(after: keyUsage[id])
            keyUsage[id] = read
            if let read { status.usageLimits = status.usageLimits.map { $0.adding(read) } ?? read }
        }
        guard !Task.isCancelled else { return }
        accountStatuses[id] = status
        if status.state == .ready || status.state == .notAuthenticated {
            accountModels[id] = await provider.models(status: status, environment: environment)
        } else {
            accountModels[id] = []
        }
        store.notify(.providers)
    }

    /// Models for the picker: discovered ones plus the user's custom ids.
    public func models(for kind: ProviderKind) -> [ModelOption] {
        withCustomModels(discoveredModels[kind] ?? [], of: kind)
    }

    private func withCustomModels(_ discovered: [ModelOption], of kind: ProviderKind) -> [ModelOption] {
        var models = discovered
        for custom in store.settings.settings(for: kind).customModels where !models.contains(where: { $0.modelID == custom }) {
            models.append(ModelOption(provider: kind, modelID: custom, displayName: custom))
        }
        return models
    }

    /// An agent's models as the picker lists them: favorites first, hidden ones left out (`AppSettings.pickerModels`).
    public func pickerModels(for kind: ProviderKind, current: ModelSelection?) -> [ModelOption] {
        store.settings.pickerModels(models(for: kind), current: current)
    }

    /// The ready agents' favorite models, in display order.
    public var favoriteModels: [ModelOption] {
        store.settings.favorites(in: readyKinds.flatMap { models(for: $0) })
    }

    /// The selection's model as its account lists it, or as the default account does before the account's check
    /// lists any (models of one agent mostly match across accounts).
    public func model(for selection: ModelSelection) -> ModelOption? {
        let own = models(for: selection.provider, account: selection.accountID)
        if let model = own.first(where: { $0.modelID == selection.modelID }) { return model }
        guard selection.accountID != nil else { return nil }
        return models(for: selection.provider).first { $0.modelID == selection.modelID }
    }

    /// Display name for a selection, falling back to the raw id.
    public func displayName(for selection: ModelSelection) -> String {
        model(for: selection)?.displayName ?? selection.modelID
    }

    /// Lets a running session update the model list it discovered.
    /// The commands and skills a provider offers: what its latest session reported, else what its check found.
    public func commands(for kind: ProviderKind) -> [ProviderCommand] {
        discoveredCommands[kind] ?? status(kind).commands
    }

    public func updateCommands(_ commands: [ProviderCommand], for kind: ProviderKind) {
        guard discoveredCommands[kind] != commands else { return }
        discoveredCommands[kind] = commands
        store.notify(.providers)
    }

    public func updateModels(_ models: [ModelOption], for kind: ProviderKind) {
        guard !models.isEmpty else { return }
        discoveredModels[kind] = models
        store.notify(.providers)
    }

    /// Resolves the executable for a provider, honoring the user's override.
    public func executable(for kind: ProviderKind) async -> URL? {
        await executable(for: kind, fresh: false)
    }

    /// The environment for a provider's process: the login shell environment plus the user's extras.
    public func environment(for kind: ProviderKind) async -> [String: String] {
        await environment(for: kind, fresh: false)
    }

    /// With `fresh`, waits for a login shell environment that is being read again instead of using the
    /// previous one, so a check sees a PATH the user just changed.
    private func executable(for kind: ProviderKind, fresh: Bool) async -> URL? {
        if let override = store.settings.settings(for: kind).executablePath, !override.isEmpty {
            let url = URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
            return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
        }
        guard let provider = providers[kind] else { return nil }
        for name in provider.executableNames {
            if let url = await shell.which(name, fresh: fresh) { return url }
        }
        return nil
    }

    private func environment(for kind: ProviderKind, fresh: Bool) async -> [String: String] {
        var env = fresh ? await shell.freshEnvironment() : await shell.environment()
        for (key, value) in store.settings.settings(for: kind).environment { env[key] = value }
        return env
    }

    /// Re-detects every enabled provider and reloads its models. A refresh asked for while another
    /// runs (after a settings change, say) waits for it and then checks again, so it is never lost.
    public func refresh() async {
        await refresh(orderedKinds)
    }

    public func refresh(_ kind: ProviderKind) async {
        await refresh([kind])
    }

    /// Checks again the enabled providers that are not ready, if their last check is older than `age`
    /// seconds: the user may have installed or signed in to one meanwhile. Runs when Coincide becomes active.
    public func refreshUnavailable(olderThan age: TimeInterval = 60) async {
        let now = Date()
        let stale = orderedKinds.filter { kind in
            store.settings.settings(for: kind).isEnabled && status(kind).state != .ready && running[kind] == nil
                && now.timeIntervalSince(lastChecked[kind] ?? .distantPast) > age
        }
        guard !stale.isEmpty else { return }
        // A newly installed CLI may live in a folder the login shell only now adds to PATH. Folders the
        // merged PATH already covers are searched afresh on every check, so the shell is only read again
        // when what it gave is old.
        if stale.contains(where: { status($0).state == .notInstalled }) {
            shell.invalidate(olderThan: environmentRereadAge)
        }
        await refresh(stale)
    }

    /// Checks `kinds` and every account added to them.
    private func refresh(_ kinds: [ProviderKind]) async {
        store.notify(.providers)
        await withTaskGroup(of: Void.self) { group in
            for kind in kinds {
                group.addTask { await self.check(kind) }
                for account in self.accounts(for: kind) where !account.isDefault {
                    group.addTask { await self.checkAccount(account) }
                }
            }
        }
        store.notify(.providers)
    }

    /// Runs a check of `kind` that starts after this call, sharing it with concurrent callers.
    private func check(_ kind: ProviderKind) async {
        requested[kind, default: 0] += 1
        let wanted = requested[kind] ?? 0
        while (completed[kind] ?? 0) < wanted {
            if let current = running[kind] {
                await current.value
                continue
            }
            let generation = requested[kind] ?? wanted
            let task = Task { @MainActor in
                await self.refreshOne(kind)
                // Updated before anyone waiting sees the task finish.
                self.completed[kind] = max(self.completed[kind] ?? 0, generation)
                self.lastChecked[kind] = Date()
                self.running[kind] = nil
            }
            running[kind] = task
            await task.value
        }
    }

    private func refreshOne(_ kind: ProviderKind) async {
        guard let provider = providers[kind] else { return }
        guard store.settings.settings(for: kind).isEnabled else {
            statuses[kind] = ProviderStatus(state: .unknown, message: String(localized: "Disabled in Settings"))
            discoveredModels[kind] = []
            return
        }
        // A check waits for a login shell environment that is being read again (after Settings' Refresh,
        // say); everything else keeps using the previous one meanwhile.
        let environment = await environment(for: kind, fresh: true)
        let executable = await executable(for: kind, fresh: true)
        let status = await provider.detect(executable: executable, environment: environment)
        statuses[kind] = status
        if status.state == .ready || status.state == .notAuthenticated {
            discoveredModels[kind] = await provider.models(status: status, environment: environment)
        } else {
            discoveredModels[kind] = []
        }
        store.notify(.providers)
    }

    /// Picks a usable selection: the requested one if its account is ready, otherwise the first ready account's
    /// first model.
    public func usableSelection(preferring selection: ModelSelection) -> ModelSelection {
        if status(for: selection).state == .ready { return selection }
        for kind in readyKinds {
            for account in accounts(for: kind) where status(kind, account: account.id).state == .ready {
                if let first = models(for: kind, account: account.id).first {
                    return ModelSelection(
                        provider: kind, modelID: first.modelID, effort: first.defaultEffort, accountID: account.storedID)
                }
            }
        }
        return selection
    }
}
