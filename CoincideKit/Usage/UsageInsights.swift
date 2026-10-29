import Foundation

/// What Settings › Usage, the menu bar item and the navigation rail show: every account's plan limits, and the tokens
/// spent, from Coincide's turns and the Claude Code and Codex logs on this Mac. One instance serves them all, so the
/// logs are read and the limits checked once, however many places show them.
///
/// Nothing polls. Logs are read again when Settings › Usage or the menu opens (at most every `scanInterval`), when the
/// user refreshes, and a while after turns finish; limits come from the providers' sessions as they run and from their
/// checks, which run again when a view opens and the last check is older than `limitsInterval`.
@MainActor
public final class UsageInsights {
    public static let shared = UsageInsights(store: .shared, registry: .shared, runner: .shared)

    /// Posted when the events, limits or scanning state changed.
    public static let didChange = Notification.Name("Coincide.usageInsightsChanged")

    /// Providers whose logs Coincide reads.
    public nonisolated static let loggedProviders: Set<ProviderKind> = [.claude, .codex]

    /// Within this long of the previous scan, opening a view does not read the logs again.
    public var scanInterval: TimeInterval = 60
    /// After a turn finishes, the logs are read again at most this often.
    public var turnScanInterval: TimeInterval = 5 * 60
    /// Limits checked longer ago than this are checked again when a view opens.
    public var limitsInterval: TimeInterval = 5 * 60

    public private(set) var logEvents: [UsageEvent] = [] {
        didSet { eventsVersion += 1 }
    }
    /// Goes up whenever `logEvents` changes, so views can tell whether to sum them again.
    public private(set) var eventsVersion = 0
    public private(set) var isScanning = false
    public private(set) var isCheckingLimits = false
    public private(set) var lastScan: Date?
    /// How the last scan went: files read anew and how long it took.
    public private(set) var lastScanStats: (files: Int, bytes: Int64, duration: TimeInterval)?
    /// The accounts whose logs were read, by provider.
    public private(set) var scannedSources: [UsageLogSource] = []

    private let store: AppStore
    private let registry: ProviderRegistry
    private let runner: ThreadRunner
    private let scanner: UsageLogScanner
    /// The highest each bare balance has been, which its bar measures against.
    public let balanceMarks: UsageBalanceMarks
    private var scanTask: Task<Void, Never>?
    private var pendingTurnScan: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var storeObserver: ObservationToken?
    private var lastLimitsCheck: Date?

    public init(store: AppStore, registry: ProviderRegistry, runner: ThreadRunner, scanner: UsageLogScanner? = nil) {
        self.store = store
        self.registry = registry
        self.runner = runner
        self.scanner = scanner ?? UsageLogScanner(cacheFile: store.directory.appendingPathComponent("usage-log-cache.plist"))
        balanceMarks = UsageBalanceMarks(directory: store.directory)
        observers.append(
            NotificationCenter.default.addObserver(forName: ThreadRunner.usageLimitsChangedNotification, object: runner, queue: .main) {
                [weak self] _ in MainActor.assumeIsolated { self?.changed() }
            })
        observers.append(
            NotificationCenter.default.addObserver(forName: UsageHistory.didChange, object: runner.usageHistory, queue: .main) {
                [weak self] _ in MainActor.assumeIsolated { self?.turnFinished() }
            })
        observers.append(
            NotificationCenter.default.addObserver(forName: LastActiveAgentStore.didChange, object: runner.lastActiveAgent, queue: .main) {
                [weak self] _ in MainActor.assumeIsolated { self?.changed() }
            })
        storeObserver = store.observe { [weak self] change in
            if change == .providers || change == .settings { self?.changed() }
        }
    }

    isolated deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        scanTask?.cancel()
        pendingTurnScan?.cancel()
    }

    private func changed() {
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    // MARK: Tokens

    /// Coincide's recorded turns.
    public var records: [UsageRecord] { runner.usageHistory.records }

    /// Why the turn history could not be saved, if it could not.
    public var historyError: String? { runner.usageHistory.error }

    /// Every event, from the logs (only Coincide's sessions unless `includeOtherSessions`) and from Coincide's turns of
    /// the providers whose logs are not read.
    public func events(includeOtherSessions: Bool) -> [UsageEvent] {
        let logged = includeOtherSessions ? logEvents : logEvents.filter(\.isFromCoincide)
        return logged + UsageEvents.fromRecords(runner.usageHistory.records, excluding: Self.loggedProviders)
    }

    /// The events with the user's choice of whether other sessions count.
    public var events: [UsageEvent] { events(includeOtherSessions: store.settings.usageIncludesOtherSessions) }

    /// Reads the logs again, unless the last read is recent (`force` reads anyway). Returns when the read is done.
    public func scan(force: Bool = false) async {
        if let scanTask {
            await scanTask.value
            if !force { return }
        }
        if !force, let lastScan, Date().timeIntervalSince(lastScan) < scanInterval { return }
        let task = Task { await self.runScan() }
        scanTask = task
        await task.value
        if scanTask == task { scanTask = nil }
    }

    private func runScan() async {
        isScanning = true
        changed()
        let sources = await logSources()
        let owners = sessionOwners()
        let scanner = scanner
        let (scan, events) = await Task.detached(priority: .utility) {
            let scan = scanner.scan(sources)
            return (scan, UsageEvents.fromLogs(scan.sessions, owners: owners))
        }.value
        logEvents = events
        scannedSources = sources
        lastScan = Date()
        lastScanStats = (scan.filesRead, scan.bytesRead, scan.duration)
        isScanning = false
        changed()
    }

    /// A finished turn may have added to the logs; read them again in a while.
    private func turnFinished() {
        changed()
        guard pendingTurnScan == nil, lastScan != nil else { return }
        let delay = max(0, turnScanInterval - Date().timeIntervalSince(lastScan ?? .distantPast))
        pendingTurnScan = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(delay, 30)))
            guard !Task.isCancelled, let self else { return }
            self.pendingTurnScan = nil
            await self.scan(force: true)
        }
    }

    /// The log folders of every Claude Code and Codex account, each folder once: an account without a home of its own
    /// (an API key) writes into the default account's.
    func logSources() async -> [UsageLogSource] {
        var sources: [UsageLogSource] = []
        var roots: Set<String> = []
        for kind in [ProviderKind.claude, .codex] {
            for account in registry.accounts(for: kind) {
                let environment = await registry.environment(for: kind, account: account.id)
                guard let home = UsageLogSource.home(for: kind, environment: environment) else { continue }
                let folders = UsageLogSource.roots(for: kind, home: home).filter { roots.insert($0.standardizedFileURL.path).inserted }
                guard !folders.isEmpty else { continue }
                sources.append(UsageLogSource(provider: kind, accountID: account.id, roots: folders))
            }
        }
        return sources
    }

    /// The project of each native session a Coincide thread holds.
    private func sessionOwners() -> [ProviderKind: [String: UsageEvents.SessionOwner]] {
        var owners: [ProviderKind: [String: UsageEvents.SessionOwner]] = [:]
        for summary in store.threadSummaries.values {
            for (provider, sessionID) in summary.nativeSessionIDs where Self.loggedProviders.contains(provider) {
                owners[provider, default: [:]][sessionID] = UsageEvents.SessionOwner(
                    projectID: summary.projectID, accountID: summary.nativeSessionAccounts?[provider])
            }
        }
        return owners
    }

    // MARK: Limits

    /// One provider account and what its plan allows.
    public struct AccountLimits: Sendable, Hashable, Identifiable {
        public var provider: ProviderKind
        public var account: ProviderAccount
        /// Whether the provider has more than one account, so views name this one.
        public var showsAccountName: Bool
        public var status: ProviderStatus
        public var limits: UsageLimits?
        /// The highest each of its bare balances has been, as Coincide saw them, by figure ID
        /// (`UsageBalanceMarks.creditsID` for its credits).
        public var balanceMarks: [String: UsageBalanceMark]
        public var id: String { provider.rawValue + "/" + account.id }

        public nonisolated init(
            provider: ProviderKind, account: ProviderAccount, showsAccountName: Bool, status: ProviderStatus, limits: UsageLimits?,
            balanceMarks: [String: UsageBalanceMark] = [:]
        ) {
            self.provider = provider
            self.account = account
            self.showsAccountName = showsAccountName
            self.status = status
            self.limits = limits
            self.balanceMarks = balanceMarks
        }
    }

    /// Every enabled provider's accounts, in display order.
    public func accountLimits(now: Date = Date()) -> [AccountLimits] {
        registry.orderedKinds.filter { store.settings.settings(for: $0).isEnabled }.flatMap { kind in
            let accounts = registry.accounts(for: kind)
            return accounts.map { account in
                var limits = runner.usageLimits(for: kind, account: account.id)
                if let rateLimits = rateLimitReadings[UsageReport.accountKey(kind, account.id)] {
                    limits = limits.map { $0.adding(rateLimits) } ?? rateLimits
                }
                if let admin = adminLimits(UsageReport.accountKey(kind, account.id)) {
                    // The reports answer the note that only an Admin key reads them; what they can't show stays noted.
                    let unanswered = Set(APIKeyUsage.notes(for: .anthropic))
                    var base = limits ?? UsageLimits(windows: [], checkedAt: admin.checkedAt)
                    base.notes.removeAll { unanswered.contains($0) }
                    limits = base.adding(admin)
                }
                let current = limits?.current(at: now)
                return AccountLimits(
                    provider: kind, account: account, showsAccountName: accounts.count > 1,
                    status: registry.status(kind, account: account.id), limits: current,
                    balanceMarks: current.map { balanceMarks.observe($0, provider: kind, account: account.id, at: $0.checkedAt) } ?? [:])
            }
        }
    }

    /// The agent account of the last turn started in Coincide, which the menu bar follows by default.
    public var lastActive: LastActiveAgent? { runner.lastActiveAgent.value }

    // MARK: API-key rate limits

    /// Rate limits read on request for API-key accounts (`checkRateLimits`), by `UsageReport.accountKey`.
    private var rateLimitReadings: [String: UsageLimits] = [:]
    /// Accounts whose rate limits are being read.
    public private(set) var checkingRateLimits: Set<String> = []
    /// Sends the rate-limit reads; tests answer them without the network.
    var rateLimitFetch: UsageLimitsFetch = UsageLimitsHTTP.live

    /// Whether the account holds an Anthropic API key, whose rate limits `checkRateLimits` can read.
    public func canCheckRateLimits(_ account: ProviderAccount) -> Bool {
        account.auth == .apiKey && APIKeyUsage.service(forVariable: account.keyVariable) == .anthropic
            && registry.secrets.hasAPIKey(account)
    }

    /// Reads the account's rate limits from the headers of a one-token message, which costs a fraction of a cent.
    /// Returns whether the read worked; a failed read keeps the last one.
    @discardableResult
    public func checkRateLimits(_ account: ProviderAccount) async -> Bool {
        let key = UsageReport.accountKey(account.provider, account.id)
        guard canCheckRateLimits(account), !checkingRateLimits.contains(key), let apiKey = registry.secrets.apiKey(for: account)
        else { return false }
        checkingRateLimits.insert(key)
        changed()
        let outcome = await APIKeyUsage.probeAnthropicRateLimits(key: apiKey, fetch: rateLimitFetch)
        checkingRateLimits.remove(key)
        if let limits = outcome.limits { rateLimitReadings[key] = limits }
        changed()
        return outcome.limits != nil
    }

    // MARK: Anthropic Admin API reports

    /// An account's Admin API reports are read again at most this often, unless the user refreshes.
    public var adminReportsInterval: TimeInterval = 15 * 60
    /// The last report of each account with an Admin key, by `UsageReport.accountKey`.
    private var adminReports: [String: AnthropicAdminUsage.Report] = [:]
    /// Why an account's last read failed, by `UsageReport.accountKey`; cleared by a read that works.
    private var adminProblems: [String: String] = [:]
    private var adminChecked: [String: Date] = [:]
    private var adminReading: Set<String> = []
    /// Sends the report reads; tests answer them without the network.
    var adminFetch: UsageLimitsFetch = UsageLimitsHTTP.live

    /// Whether the account is an Anthropic API-key account, which can hold an Admin API key.
    public nonisolated static func takesAdminKey(_ account: ProviderAccount) -> Bool {
        !account.isDefault && account.auth == .apiKey && APIKeyUsage.service(forVariable: account.keyVariable) == .anthropic
    }

    /// The account's last Admin API report, if it has an Admin key and a read worked.
    public func adminReport(for account: ProviderAccount) -> AnthropicAdminUsage.Report? {
        adminReports[UsageReport.accountKey(account.provider, account.id)]
    }

    /// The report (or why it failed) as limits to add to the account's.
    private func adminLimits(_ key: String) -> UsageLimits? {
        let report = adminReports[key]
        let problem = adminProblems[key]
        guard report != nil || problem != nil else { return nil }
        return UsageLimits(
            windows: [], checkedAt: report?.checkedAt ?? adminChecked[key] ?? Date(),
            figures: report.map(AnthropicAdminUsage.figures) ?? [],
            notes: [problem, AnthropicAdminUsage.balanceNote].compactMap { $0 })
    }

    /// Reads the Admin API reports of every Anthropic API-key account with an Admin key, each at most every
    /// `adminReportsInterval` unless `force`.
    public func readAdminReports(force: Bool = false) async {
        let accounts = registry.accounts(for: .claude).filter(Self.takesAdminKey)
        await withTaskGroup(of: Void.self) { group in
            for account in accounts {
                group.addTask { await self.readAdminReport(account, force: force) }
            }
        }
    }

    /// Reads one account's Admin API reports. An account without an Admin key (or no longer one) is forgotten.
    public func readAdminReport(_ account: ProviderAccount, force: Bool = false) async {
        let key = UsageReport.accountKey(account.provider, account.id)
        guard Self.takesAdminKey(account), let adminKey = registry.secrets.adminKey(for: account) else {
            if adminReports.removeValue(forKey: key) != nil || adminProblems.removeValue(forKey: key) != nil { changed() }
            adminChecked[key] = nil
            return
        }
        guard !adminReading.contains(key) else { return }
        if !force, let checked = adminChecked[key], Date().timeIntervalSince(checked) < adminReportsInterval { return }
        adminReading.insert(key)
        let outcome = await AnthropicAdminUsage.read(adminKey: adminKey, apiKey: registry.secrets.apiKey(for: account), fetch: adminFetch)
        adminReading.remove(key)
        adminChecked[key] = Date()
        switch outcome {
        case .report(let report):
            adminReports[key] = report
            adminProblems[key] = nil
        case .unauthorized, .forbidden:
            // A refused key's old figures would mislead.
            adminReports[key] = nil
            adminProblems[key] = AnthropicAdminUsage.problem(outcome)
        case .failed:
            adminProblems[key] = AnthropicAdminUsage.problem(outcome)
        }
        changed()
    }

    /// Checks the providers again when the last check is older than `limitsInterval` (or always, with `force`).
    public func checkLimits(force: Bool = false) async {
        guard !isCheckingLimits else { return }
        if !force, let lastLimitsCheck, Date().timeIntervalSince(lastLimitsCheck) < limitsInterval { return }
        isCheckingLimits = true
        changed()
        await registry.refresh()
        lastLimitsCheck = Date()
        isCheckingLimits = false
        changed()
    }

    /// What opening a usage view does: reads the logs and checks the limits if either is stale.
    public func refreshIfStale() {
        Task {
            async let scan: Void = scan()
            async let limits: Void = checkLimits()
            async let admin: Void = readAdminReports()
            _ = await (scan, limits, admin)
        }
    }

    /// The Refresh button: reads the logs and checks every provider now.
    public func refreshNow() async {
        async let scan: Void = scan(force: true)
        async let limits: Void = checkLimits(force: true)
        async let admin: Void = readAdminReports(force: true)
        _ = await (scan, limits, admin)
    }

    /// The most used window across `accounts`: the one closest to its limit, which the menu bar shows. Model-specific
    /// windows count too, since they also stop work for their model. Ties go to the window that resets last.
    public nonisolated static func mostConstrained(_ accounts: [AccountLimits])
        -> (account: AccountLimits, window: UsageLimitWindow)?
    {
        var best: (account: AccountLimits, window: UsageLimitWindow)?
        for account in accounts {
            for window in (account.limits?.windows ?? []) + (account.limits?.modelWindows ?? []) {
                guard let current = best else {
                    best = (account, window)
                    continue
                }
                if window.usedPercent > current.window.usedPercent
                    || (window.usedPercent == current.window.usedPercent
                        && (window.resetsAt ?? .distantPast) > (current.window.resetsAt ?? .distantPast))
                {
                    best = (account, window)
                }
            }
        }
        return best
    }
}
