import AppKit
import CoincideKit
import Observation
import SwiftUI

/// What the settings sidebar shows on the right.
nonisolated enum SettingsPane: Hashable, Sendable {
    case section(SettingsSection)
    case provider(ProviderKind)
}

/// Rows that search results can scroll to.
nonisolated enum SettingsRowID: String, Hashable, Sendable {
    case appearance
    case fontSize
    case sendShortcut
    case followUpBehavior
    case showReasoning
    case defaultModel
    case accessMode
    case confirmDelete
    case notifications
    case checkpoints
    case branchPrefix
    case idleTimeout
}

/// A request to scroll a pane to a row and highlight it. The id makes repeated requests distinct.
nonisolated struct SettingsRevealRequest: Equatable, Sendable {
    let setting: SettingsRowID
    let id = UUID()
}

/// Bridges `AppStore` settings and `ProviderRegistry` state into SwiftUI, and owns sidebar navigation.
@Observable
final class SettingsModel {
    var pane: SettingsPane = .section(.general) {
        didSet { if pane != oldValue { onPaneChange?(pane) } }
    }
    var searchText = ""
    private(set) var reveal: SettingsRevealRequest?

    private(set) var settings: AppSettings
    private(set) var statuses: [ProviderKind: ProviderStatus] = [:]
    /// Models offered in the picker: discovered ones plus custom ids.
    private(set) var models: [ProviderKind: [ModelOption]] = [:]
    /// Models the providers reported themselves, without custom ids.
    private(set) var discoveredModels: [ProviderKind: [ModelOption]] = [:]
    private(set) var isCheckingAll = false
    private(set) var checking: Set<ProviderKind> = []
    private(set) var lastChecked: Date?

    /// Lets the window controller keep the window title in sync.
    @ObservationIgnored var onPaneChange: ((SettingsPane) -> Void)?
    @ObservationIgnored private let store: AppStore
    @ObservationIgnored private let registry: ProviderRegistry
    @ObservationIgnored private var token: ObservationToken?
    @ObservationIgnored private var recheck: Set<ProviderKind> = []

    init(store: AppStore = .shared, registry: ProviderRegistry = .shared) {
        self.store = store
        self.registry = registry
        settings = store.settings
        syncProviders()
        token = store.observe { [weak self] change in
            switch change {
            case .settings:
                self?.syncSettings()
                self?.syncProviders()
            case .providers:
                self?.syncProviders()
            default:
                break
            }
        }
    }

    var kinds: [ProviderKind] { registry.orderedKinds }

    /// Re-reads settings and provider state, and detects providers if nothing has checked them yet.
    func resync() {
        syncSettings()
        syncProviders()
        let enabled = kinds.filter { isEnabled($0) }
        if !registry.isRefreshing, !enabled.isEmpty, enabled.allSatisfy({ status($0).state == .unknown }) {
            Task { await registry.refresh() }
        }
    }

    // MARK: Navigation

    func navigate(to pane: SettingsPane, reveal setting: SettingsRowID? = nil) {
        self.pane = pane
        reveal = setting.map { SettingsRevealRequest(setting: $0) }
    }

    // MARK: Settings

    /// A binding that writes through to the store when the value changes.
    func binding<Value: Equatable>(_ keyPath: WritableKeyPath<AppSettings, Value>) -> Binding<Value> {
        Binding(
            get: { self.settings[keyPath: keyPath] },
            set: { value in
                guard self.settings[keyPath: keyPath] != value else { return }
                self.store.updateSettings { $0[keyPath: keyPath] = value }
            })
    }

    func update(_ mutate: (inout AppSettings) -> Void) {
        store.updateSettings(mutate)
    }

    func providerSettings(_ kind: ProviderKind) -> ProviderSettings { settings.settings(for: kind) }

    /// Changes one provider's settings and, when the change affects detection, checks it again.
    func updateProvider(_ kind: ProviderKind, recheck: Bool = true, _ mutate: (inout ProviderSettings) -> Void) {
        var value = settings.settings(for: kind)
        let before = value
        mutate(&value)
        guard value != before else { return }
        store.updateSettings { $0.providers[kind] = value }
        if recheck { check(kind) }
    }

    // MARK: Providers

    func status(_ kind: ProviderKind) -> ProviderStatus { statuses[kind] ?? .unknown }

    func isChecking(_ kind: ProviderKind) -> Bool { checking.contains(kind) || isCheckingAll }

    func isEnabled(_ kind: ProviderKind) -> Bool { settings.settings(for: kind).isEnabled }

    func setupHint(_ kind: ProviderKind) -> String { registry.provider(kind)?.setupHint ?? "" }

    func executableNames(_ kind: ProviderKind) -> [String] { registry.provider(kind)?.executableNames ?? [] }

    /// Re-detects one provider. Asking again while a check runs queues one more check, so the result
    /// always reflects the latest settings.
    func check(_ kind: ProviderKind, reloadEnvironment: Bool = false) {
        if reloadEnvironment { ShellEnvironment.shared.invalidate() }
        guard !checking.contains(kind) else {
            recheck.insert(kind)
            return
        }
        checking.insert(kind)
        Task {
            await registry.refresh(kind)
            checking.remove(kind)
            lastChecked = Date()
            if recheck.remove(kind) != nil { check(kind) }
        }
    }

    /// Re-detects every provider, reloading the login shell environment first so newly installed CLIs show up.
    func checkAll() {
        guard !registry.isRefreshing else { return }
        ShellEnvironment.shared.invalidate()
        Task { await registry.refresh() }
    }

    /// The model new threads start with, when it is still offered.
    var defaultModel: ModelOption? {
        models[settings.defaultSelection.provider]?.first { $0.modelID == settings.defaultSelection.modelID }
    }

    func setDefaultModel(_ option: ModelOption) {
        let current = settings.defaultSelection
        // Keep the effort when the new model accepts it; otherwise use the model's default.
        let effort = current.effort.flatMap { option.efforts.contains($0) ? $0 : nil }
        update { $0.defaultSelection = ModelSelection(provider: option.provider, modelID: option.modelID, effort: effort) }
    }

    /// Adds a custom model id, returning a message when it cannot be added.
    func addCustomModel(_ rawID: String, to kind: ProviderKind) -> String? {
        let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        if id.isEmpty { return String(localized: "Enter a model ID.") }
        if id.contains(where: \.isWhitespace) { return String(localized: "Model IDs can’t contain spaces.") }
        if id.count > 256 { return String(localized: "Model IDs must be 256 characters or fewer.") }
        if discoveredModels[kind]?.contains(where: { $0.modelID == id }) == true {
            return String(localized: "\(kind.displayName) already offers that model.")
        }
        if providerSettings(kind).customModels.contains(id) {
            return String(localized: "That custom model is already added.")
        }
        updateProvider(kind, recheck: false) { $0.customModels.append(id) }
        return nil
    }

    func removeCustomModel(_ id: String, from kind: ProviderKind) {
        updateProvider(kind, recheck: false) { $0.customModels.removeAll { $0 == id } }
    }

    // MARK: ACP agents

    /// The user-added ACP agent `kind` runs, if it is one.
    func acpAgent(_ kind: ProviderKind) -> ACPAgentConfig? { kind.acpAgentID.flatMap(settings.acpAgent) }

    /// Adds an agent with its environment variables, and checks it.
    func addACPAgent(_ agent: ACPAgentConfig, environment: [String: String] = [:]) {
        store.updateSettings {
            $0.acpAgents.append(agent)
            $0.providers[agent.kind] = ProviderSettings(environment: environment)
        }
        check(agent.kind)
    }

    /// Changes an agent's settings and, when asked, checks it again.
    func updateACPAgent(_ id: String, recheck: Bool = true, _ mutate: (inout ACPAgentConfig) -> Void) {
        guard var agent = settings.acpAgent(id) else { return }
        let before = agent
        mutate(&agent)
        guard agent != before else { return }
        store.updateSettings { settings in
            if let index = settings.acpAgents.firstIndex(where: { $0.id == id }) { settings.acpAgents[index] = agent }
        }
        if recheck { check(agent.kind) }
    }

    /// Removes an agent and its settings. Its threads keep their history; files Coincide installed for it go once
    /// no other agent uses them and nothing runs from them.
    func removeACPAgent(_ id: String) {
        let kind = ProviderKind.acp(id)
        if pane == .provider(kind) { pane = .section(.providers) }
        store.updateSettings {
            $0.acpAgents.removeAll { $0.id == id }
            $0.providers[kind] = nil
        }
        registry.forget(kind)
        ACPRegistryTools.shared.removeUnused(keeping: store.settings.acpAgents)
    }

    /// Installs a registry agent and adds it; returns its kind.
    func addRegistryAgent(_ result: ACPRegistrySearchResult) async throws -> ProviderKind {
        let install = try await ACPRegistryTools.shared.install(
            result.agent, result.distribution, environment: await ShellEnvironment.shared.environment())
        let id = ACPAgentConfig.makeID(from: result.agent.id, existing: Set(store.settings.acpAgents.map(\.id)))
        addACPAgent(ACPAgentConfig(id: id, name: result.agent.name, source: .registry, registry: install))
        return .acp(id)
    }

    /// Installs `agent`'s current registry version for the added agent `id` (an update, or a reinstall of files that
    /// went missing), then removes the version it replaced once nothing runs from it.
    func reinstallRegistryAgent(_ id: String, from agent: ACPRegistryAgent) async throws {
        guard let distribution = agent.distribution(for: ACPRegistryPlatform.current) else {
            throw ACPRegistryInstallError(String(localized: "This agent has no download for this Mac."))
        }
        let install = try await ACPRegistryTools.shared.install(
            agent, distribution, environment: await ShellEnvironment.shared.environment())
        updateACPAgent(id) { $0.registry = install }
        ACPRegistryTools.shared.removeUnused(keeping: store.settings.acpAgents)
    }

    /// How to start an added agent outside a thread, for signing in.
    func acpLaunch(_ id: String) async -> ACPAgentLaunch? { await registry.acpLaunch(for: id) }

    // MARK: Sync

    private func syncSettings() {
        let value = store.settings
        if value != settings { settings = value }
    }

    private func syncProviders() {
        let kinds = registry.orderedKinds
        let newStatuses = Dictionary(uniqueKeysWithValues: kinds.map { ($0, registry.status($0)) })
        let newModels = Dictionary(uniqueKeysWithValues: kinds.map { ($0, registry.models(for: $0)) })
        let newDiscovered = Dictionary(uniqueKeysWithValues: kinds.map { ($0, registry.discoveredModels[$0] ?? []) })
        if newStatuses != statuses { statuses = newStatuses }
        if newModels != models { models = newModels }
        if newDiscovered != discoveredModels { discoveredModels = newDiscovered }
        let refreshing = registry.isRefreshing
        if refreshing != isCheckingAll {
            if !refreshing { lastChecked = Date() }
            isCheckingAll = refreshing
        }
    }
}
