import Foundation

/// Holds every provider, their detected status and their models.
@MainActor
public final class ProviderRegistry {
    public static let shared = ProviderRegistry(store: .shared)

    public let providers: [ProviderKind: AgentProvider]
    public private(set) var statuses: [ProviderKind: ProviderStatus] = [:]
    public private(set) var discoveredModels: [ProviderKind: [ModelOption]] = [:]
    public private(set) var isRefreshing = false

    private let store: AppStore

    public init(store: AppStore, providers: [AgentProvider]? = nil) {
        self.store = store
        let all = providers ?? Self.builtInProviders()
        self.providers = Dictionary(all.map { ($0.kind, $0) }, uniquingKeysWith: { first, _ in first })
    }

    public static func builtInProviders() -> [AgentProvider] {
        [
            ClaudeProvider(),
            CodexProvider(),
            CursorProvider(),
            ACPProvider(profile: .grok),
            OpenCodeProvider(),
            PiProvider(),
            ACPProvider(profile: .antigravity),
        ]
    }

    public func provider(_ kind: ProviderKind) -> AgentProvider? { providers[kind] }

    public func status(_ kind: ProviderKind) -> ProviderStatus { statuses[kind] ?? .unknown }

    /// Providers in display order.
    public var orderedKinds: [ProviderKind] { ProviderKind.allCases.filter { providers[$0] != nil } }

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

    /// Lets a running session update the model list it discovered.
    public func updateModels(_ models: [ModelOption], for kind: ProviderKind) {
        guard !models.isEmpty else { return }
        discoveredModels[kind] = models
        store.notify(.providers)
    }

    /// Resolves the executable for a provider, honoring the user's override.
    public func executable(for kind: ProviderKind) async -> URL? {
        if let override = store.settings.settings(for: kind).executablePath, !override.isEmpty {
            let url = URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
            return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
        }
        guard let provider = providers[kind] else { return nil }
        for name in provider.executableNames {
            if let url = await ShellEnvironment.shared.which(name) { return url }
        }
        return nil
    }

    /// The environment for a provider's process: the login shell environment plus the user's extras.
    public func environment(for kind: ProviderKind) async -> [String: String] {
        var env = await ShellEnvironment.shared.environment()
        for (key, value) in store.settings.settings(for: kind).environment { env[key] = value }
        return env
    }

    /// Re-detects every enabled provider and reloads its models.
    public func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        store.notify(.providers)
        await withTaskGroup(of: Void.self) { group in
            for kind in orderedKinds {
                group.addTask { await self.refreshOne(kind) }
            }
        }
        isRefreshing = false
        store.notify(.providers)
    }

    public func refresh(_ kind: ProviderKind) async {
        await refreshOne(kind)
        store.notify(.providers)
    }

    private func refreshOne(_ kind: ProviderKind) async {
        guard let provider = providers[kind] else { return }
        guard store.settings.settings(for: kind).isEnabled else {
            statuses[kind] = ProviderStatus(state: .unknown, message: String(localized: "Disabled in Settings"))
            discoveredModels[kind] = []
            return
        }
        let environment = await environment(for: kind)
        let executable = await executable(for: kind)
        let status = await provider.detect(executable: executable, environment: environment)
        statuses[kind] = status
        if status.state == .ready || status.state == .notAuthenticated {
            discoveredModels[kind] = await provider.models(status: status, environment: environment)
        } else {
            discoveredModels[kind] = []
        }
        store.notify(.providers)
    }

    /// Picks a usable selection: the requested one if its provider is ready, otherwise the first ready model.
    public func usableSelection(preferring selection: ModelSelection) -> ModelSelection {
        if status(selection.provider).state == .ready { return selection }
        for kind in readyKinds {
            if let first = models(for: kind).first {
                return ModelSelection(provider: kind, modelID: first.modelID, effort: first.defaultEffort)
            }
        }
        return selection
    }
}
