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
    case replyTypeface
    case darkTheme
    case lightTheme
    case sendShortcut
    case followUpBehavior
    case showReasoning
    case defaultModel
    case accessMode
    case confirmDelete
    case threadTitles
    case newThreadChat
    case resumeAfterLimit
    case notifications
    case checkpoints
    case branchPrefix
    case idleTimeout
    case backgroundAgents
    case remote
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
    /// The added accounts' statuses, by account id.
    private(set) var accountStatuses: [String: ProviderStatus] = [:]
    /// Accounts with an API key in the Keychain. The Keychain is only asked whether a key exists, never for it.
    private(set) var accountsWithKeys: Set<String> = []
    /// Accounts being checked or having their key saved.
    private(set) var busyAccounts: Set<String> = []
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

    // MARK: Accounts

    /// The provider's default account and the ones the user added.
    func accounts(_ kind: ProviderKind) -> [ProviderAccount] { providerSettings(kind).allAccounts(of: kind) }

    func accountStatus(_ account: ProviderAccount) -> ProviderStatus {
        account.isDefault ? status(account.provider) : accountStatuses[account.id] ?? .unknown
    }

    func hasAPIKey(_ account: ProviderAccount) -> Bool { accountsWithKeys.contains(account.id) }

    func isBusy(_ account: ProviderAccount) -> Bool {
        busyAccounts.contains(account.id) || (account.isDefault && isChecking(account.provider))
    }

    /// Adds an account signing in with `auth`, named after the provider and its method, and returns it.
    @discardableResult
    func addAccount(_ kind: ProviderKind, auth: ProviderAccountAuth) -> ProviderAccount {
        let existing = Set(accounts(kind).map(\.name))
        let base =
            switch auth {
            case .login: String(localized: "\(kind.displayName) (Login)")
            case .apiKey: String(localized: "\(kind.displayName) (API)")
            }
        var name = base
        var number = 2
        while existing.contains(name) {
            name = "\(base) \(number)"
            number += 1
        }
        let account = ProviderAccount(provider: kind, name: name, auth: auth)
        updateProvider(kind, recheck: false) { $0.accounts.append(account) }
        checkAccount(account)
        return account
    }

    /// Changes an added account. A new sign-in method or key type is checked again.
    func updateAccount(_ account: ProviderAccount, _ mutate: (inout ProviderAccount) -> Void) {
        guard !account.isDefault else { return }
        var changed = account
        mutate(&changed)
        guard changed != account else { return }
        updateProvider(account.provider, recheck: false) { settings in
            if let index = settings.accounts.firstIndex(where: { $0.id == account.id }) { settings.accounts[index] = changed }
        }
        if changed.auth != account.auth || changed.apiKeyVariable != account.apiKeyVariable
            || changed.environment != account.environment
        {
            checkAccount(changed)
        }
    }

    /// Removes an added account with its Keychain key and its home, where the CLI kept its login. Threads that used
    /// it continue with the provider's default account.
    func removeAccount(_ account: ProviderAccount) {
        guard !account.isDefault else { return }
        updateProvider(account.provider, recheck: false) { $0.accounts.removeAll { $0.id == account.id } }
        if settings.defaultSelection.provider == account.provider, settings.defaultSelection.accountID == account.id {
            update { $0.defaultSelection.accountID = nil }
        }
        try? registry.secrets.removeAPIKey(for: account)
        try? FileManager.default.removeItem(at: account.home(in: store.directory))
        registry.forgetAccount(account.id)
        accountsWithKeys.remove(account.id)
    }

    /// Saves the account's API key to the Keychain; returns a message when that failed.
    func saveAPIKey(_ key: String, for account: ProviderAccount) async -> String? {
        busyAccounts.insert(account.id)
        defer { busyAccounts.remove(account.id) }
        do {
            try await registry.saveAPIKey(key, for: account)
        } catch {
            syncKeys()
            return error.localizedDescription
        }
        syncKeys()
        return nil
    }

    func removeAPIKey(for account: ProviderAccount) {
        busyAccounts.insert(account.id)
        Task {
            try? await registry.removeAPIKey(for: account)
            busyAccounts.remove(account.id)
            syncKeys()
        }
    }

    func checkAccount(_ account: ProviderAccount) {
        guard !account.isDefault else { return check(account.provider) }
        busyAccounts.insert(account.id)
        Task {
            await registry.refresh(account.provider, account: account.id)
            busyAccounts.remove(account.id)
        }
    }

    /// Runs the CLI's sign-in for the account in a terminal with the account's home, and checks it when that closes.
    func signIn(_ account: ProviderAccount) {
        guard let arguments = account.provider.loginArguments else { return }
        Task {
            let executable = await registry.executable(for: account.provider)
            let command = ([executable?.path ?? executableNames(account.provider).first ?? account.provider.rawValue] + arguments)
                .map(Self.shellQuoted).joined(separator: " ")
            let environment = registry.signInEnvironment(for: account.provider, account: account.id)
            AccountSignInWindowController.show(
                title: String(localized: "Sign In to \(account.name)"), command: command, environment: environment
            ) { [weak self] in self?.checkAccount(account) }
        }
    }

    private static func shellQuoted(_ word: String) -> String {
        word.range(of: #"^[A-Za-z0-9_./~=-]+$"#, options: .regularExpression) != nil
            ? word : "'" + word.replacingOccurrences(of: "'", with: #"'"'"'"#) + "'"
    }

    private func syncKeys() {
        let ids = Set(
            kinds.flatMap { accounts($0) }.filter { !$0.isDefault && $0.auth == .apiKey && registry.secrets.hasAPIKey($0) }.map(\.id))
        if ids != accountsWithKeys { accountsWithKeys = ids }
    }

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
        let added = kinds.flatMap { registry.accounts(for: $0) }.filter { !$0.isDefault }
        let newAccountStatuses = Dictionary(added.map { ($0.id, registry.status($0.provider, account: $0.id)) }) { first, _ in first }
        if newAccountStatuses != accountStatuses { accountStatuses = newAccountStatuses }
        syncKeys()
        let refreshing = registry.isRefreshing
        if refreshing != isCheckingAll {
            if !refreshing { lastChecked = Date() }
            isCheckingAll = refreshing
        }
    }
}
