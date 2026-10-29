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
        observers.append(
            NotificationCenter.default.addObserver(forName: ThreadRunner.usageLimitsChangedNotification, object: runner, queue: .main) {
                [weak self] _ in MainActor.assumeIsolated { self?.changed() }
            })
        observers.append(
            NotificationCenter.default.addObserver(forName: UsageHistory.didChange, object: runner.usageHistory, queue: .main) {
                [weak self] _ in MainActor.assumeIsolated { self?.turnFinished() }
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
                owners[provider, default: [:]][sessionID] = UsageEvents.SessionOwner(projectID: summary.projectID)
            }
        }
        return owners
    }

    // MARK: Limits

    /// One provider account and what its plan allows.
    public struct AccountLimits: Sendable, Identifiable {
        public var provider: ProviderKind
        public var account: ProviderAccount
        /// Whether the provider has more than one account, so views name this one.
        public var showsAccountName: Bool
        public var status: ProviderStatus
        public var limits: UsageLimits?
        public var id: String { provider.rawValue + "/" + account.id }

        public nonisolated init(
            provider: ProviderKind, account: ProviderAccount, showsAccountName: Bool, status: ProviderStatus, limits: UsageLimits?
        ) {
            self.provider = provider
            self.account = account
            self.showsAccountName = showsAccountName
            self.status = status
            self.limits = limits
        }
    }

    /// Every enabled provider's accounts, in display order.
    public func accountLimits(now: Date = Date()) -> [AccountLimits] {
        registry.orderedKinds.filter { store.settings.settings(for: $0).isEnabled }.flatMap { kind in
            let accounts = registry.accounts(for: kind)
            return accounts.map { account in
                AccountLimits(
                    provider: kind, account: account, showsAccountName: accounts.count > 1,
                    status: registry.status(kind, account: account.id),
                    limits: runner.usageLimits(for: kind, account: account.id)?.current(at: now))
            }
        }
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
            _ = await (scan, limits)
        }
    }

    /// The Refresh button: reads the logs and checks every provider now.
    public func refreshNow() async {
        async let scan: Void = scan(force: true)
        async let limits: Void = checkLimits(force: true)
        _ = await (scan, limits)
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
