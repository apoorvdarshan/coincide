import Foundation

/// Holds every provider, their detected status and their models.
@MainActor
public final class ProviderRegistry {
    public static let shared = ProviderRegistry(store: .shared)

    /// The providers Coincide was built with (or a test passed in), by kind.
    private let fixedProviders: [ProviderKind: AgentProvider]
    /// Providers of the user's ACP agents, made on first use and kept while the agent is in settings.
    private var customProviders: [String: AgentProvider] = [:]
    private let makeCustomProvider: @MainActor (String) -> AgentProvider
    public private(set) var statuses: [ProviderKind: ProviderStatus] = [:]
    public private(set) var discoveredModels: [ProviderKind: [ModelOption]] = [:]
    /// True while any provider is being checked.
    public var isRefreshing: Bool { !running.isEmpty }

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

    /// `custom` makes the provider of a user-added ACP agent from its instance ID; tests replace it.
    public init(
        store: AppStore, providers: [AgentProvider]? = nil, shell: ShellEnvironment = .shared,
        custom: (@MainActor (String) -> AgentProvider)? = nil
    ) {
        self.store = store
        self.shell = shell
        let all = providers ?? Self.builtInProviders(store: store)
        fixedProviders = Dictionary(all.map { ($0.kind, $0) }, uniquingKeysWith: { first, _ in first })
        makeCustomProvider = custom ?? { ACPProvider(agent: $0, store: store) }
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
        [
            ClaudeProvider(),
            CodexProvider(),
            CursorProvider(keychainUsageAllowed: { store.settings.cursorKeychainUsageEnabled }),
            ACPProvider(profile: .grok),
            OpenCodeProvider(),
            PiProvider(),
            ACPProvider(profile: .antigravity),
            ACPProvider(profile: .fx),
            MuseProvider(),
        ]
    }

    /// The provider of `kind`; for a user-added ACP agent, only while the agent is in settings.
    public func provider(_ kind: ProviderKind) -> AgentProvider? {
        if let fixed = fixedProviders[kind] { return fixed }
        guard let id = kind.acpAgentID, store.settings.acpAgent(id) != nil else { return nil }
        if let existing = customProviders[id] { return existing }
        let created = makeCustomProvider(id)
        customProviders[id] = created
        return created
    }

    public func status(_ kind: ProviderKind) -> ProviderStatus { statuses[kind] ?? .unknown }

    /// Providers in display order: the built-in agents, then the user's ACP agents in the order they were added.
    public var orderedKinds: [ProviderKind] {
        let builtIn = ProviderKind.allCases.filter { fixedProviders[$0] != nil }
        let custom = store.settings.acpAgents.map(\.kind)
        let fixedCustom = fixedProviders.keys.filter { $0.acpAgentID != nil && !custom.contains($0) }.sorted { $0.rawValue < $1.rawValue }
        return builtIn + custom + fixedCustom
    }

    /// Providers that are enabled, installed and signed in.
    public var readyKinds: [ProviderKind] { orderedKinds.filter { status($0).state == .ready } }

    /// Models for the picker: discovered ones plus the user's custom ids.
    public func models(for kind: ProviderKind) -> [ModelOption] {
        var models = discoveredModels[kind] ?? []
        for custom in store.settings.settings(for: kind).customModels where !models.contains(where: { $0.modelID == custom }) {
            models.append(ModelOption(provider: kind, modelID: custom, displayName: custom))
        }
        return models
    }

    public func model(for selection: ModelSelection) -> ModelOption? {
        models(for: selection.provider).first { $0.modelID == selection.modelID }
    }

    /// Display name for a selection, falling back to the raw id.
    public func displayName(for selection: ModelSelection) -> String {
        model(for: selection)?.displayName ?? selection.modelID
    }

    /// The skills the composer's `$` menu offers on `kind` for a thread working in `workingDirectory`; none while the
    /// provider is not ready.
    public func skills(for kind: ProviderKind, workingDirectory: URL) async -> [ProviderSkill] {
        guard status(kind).state == .ready, let provider = provider(kind) else { return [] }
        return await provider.skills(workingDirectory: workingDirectory, environment: environment(for: kind))
    }

    /// Lets a running session update the model list it discovered.
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

    /// How to start the user-added ACP agent `id` outside a thread, for signing in from Settings: the executable,
    /// arguments and environment its sessions get. Nil when it has no executable.
    public func acpLaunch(for id: String, paths: ACPRegistryPaths = .standard) async -> ACPAgentLaunch? {
        guard store.settings.acpAgent(id) != nil, let executable = await executable(for: .acp(id)) else { return nil }
        let environment = await environment(for: .acp(id))
        // Settings may have changed while the environment was read.
        guard let config = store.settings.acpAgent(id) else { return nil }
        let flavor = ACPCustomFlavor(config: config, paths: paths)
        return ACPAgentLaunch(
            name: config.displayName, executable: executable, arguments: flavor.arguments(for: .approval),
            environment: flavor.environment(environment, executable: executable),
            registryEnvironment: config.source == .registry ? config.registry?.environment ?? [:] : [:])
    }

    /// Drops what the registry knows about a user-added agent that was removed from settings.
    public func forget(_ kind: ProviderKind) {
        guard let id = kind.acpAgentID, store.settings.acpAgent(id) == nil else { return }
        customProviders[id] = nil
        statuses[kind] = nil
        discoveredModels[kind] = nil
        store.notify(.providers)
    }

    /// With `fresh`, waits for a login shell environment that is being read again instead of using the
    /// previous one, so a check sees a PATH the user just changed.
    private func executable(for kind: ProviderKind, fresh: Bool) async -> URL? {
        if let override = store.settings.settings(for: kind).executablePath, !override.isEmpty {
            let url = URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
            return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
        }
        guard let provider = provider(kind) else { return nil }
        for name in provider.executableNames {
            if let url = await shell.which(name, fresh: fresh) { return url }
        }
        return nil
    }

    private func environment(for kind: ProviderKind, fresh: Bool) async -> [String: String] {
        var env = fresh ? await shell.freshEnvironment() : await shell.environment()
        // The provider may leave out what it must not inherit (Muse Code drops a shell's `META_API_KEY`); variables the
        // user set for it apply afterwards, so theirs always win.
        if let provider = provider(kind) { env = provider.inheritedEnvironment(env) }
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

    private func refresh(_ kinds: [ProviderKind]) async {
        store.notify(.providers)
        await withTaskGroup(of: Void.self) { group in
            for kind in kinds {
                group.addTask { await self.check(kind) }
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
        guard let provider = provider(kind) else { return }
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

    /// Picks a usable selection: the requested one if its provider is ready, otherwise the first ready model. With
    /// `writingText`, only providers that support text generation count (fx does not; see
    /// `ProviderKind.supportsTextGeneration`).
    public func usableSelection(preferring selection: ModelSelection, writingText: Bool = false) -> ModelSelection {
        let usable = { (kind: ProviderKind) in !writingText || kind.supportsTextGeneration }
        if status(selection.provider).state == .ready, usable(selection.provider) { return selection }
        for kind in readyKinds where usable(kind) {
            if let first = models(for: kind).first {
                return ModelSelection(provider: kind, modelID: first.modelID, effort: first.defaultEffort)
            }
        }
        return selection
    }
}
