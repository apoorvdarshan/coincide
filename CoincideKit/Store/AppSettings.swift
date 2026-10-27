import Foundation

public enum AppearanceMode: String, Codable, CaseIterable, Sendable {
    case system
    case light
    case dark

    public nonisolated var displayName: String {
        switch self {
        case .system: String(localized: "System")
        case .light: String(localized: "Light")
        case .dark: String(localized: "Dark")
        }
    }
}

public struct ProviderSettings: Codable, Hashable, Sendable {
    public var isEnabled: Bool
    /// Absolute path to the CLI, when the user overrides PATH lookup.
    public var executablePath: String?
    /// Extra model ids the user added by hand, shown in the picker.
    public var customModels: [String]
    /// Extra environment variables for this provider's process.
    public var environment: [String: String]

    public nonisolated init(
        isEnabled: Bool = true, executablePath: String? = nil, customModels: [String] = [],
        environment: [String: String] = [:]
    ) {
        self.isEnabled = isEnabled
        self.executablePath = executablePath
        self.customModels = customModels
        self.environment = environment
    }

    public nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        executablePath = try container.decodeIfPresent(String.self, forKey: .executablePath)
        customModels = try container.decodeIfPresent([String].self, forKey: .customModels) ?? []
        environment = try container.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
    }
}

public struct AppSettings: Codable, Hashable, Sendable {
    public var defaultSelection: ModelSelection
    public var defaultAccessMode: AccessMode
    public var providers: [ProviderKind: ProviderSettings]
    public var appearance: AppearanceMode
    /// Return sends; Shift-Return inserts a newline. When false, Command-Return sends.
    public var sendOnReturn: Bool
    public var showReasoning: Bool
    public var confirmBeforeDeletingThreads: Bool
    /// Provider sessions idle this long are shut down to free memory; their ids are kept for resume.
    public var idleSessionTimeoutMinutes: Int
    /// Post a system notification when a turn finishes or needs approval while Coincide is in the background.
    public var notifyWhenInBackground: Bool
    /// Create a git checkpoint before each turn so the turn can be reverted.
    public var checkpointsEnabled: Bool
    /// Branch name prefix for new worktrees.
    public var worktreeBranchPrefix: String
    /// Font size for the transcript and composer.
    public var fontSize: Double

    public nonisolated init() {
        defaultSelection = ModelSelection(provider: .claude, modelID: "default")
        defaultAccessMode = .fullAccess
        providers = [:]
        appearance = .system
        sendOnReturn = true
        showReasoning = true
        confirmBeforeDeletingThreads = true
        idleSessionTimeoutMinutes = 30
        notifyWhenInBackground = true
        checkpointsEnabled = true
        worktreeBranchPrefix = "coincide/"
        fontSize = 13
    }

    public nonisolated func settings(for provider: ProviderKind) -> ProviderSettings {
        providers[provider] ?? ProviderSettings()
    }

    public nonisolated init(from decoder: Decoder) throws {
        let defaults = AppSettings()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? container.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        defaultSelection = value(.defaultSelection, defaults.defaultSelection)
        defaultAccessMode = value(.defaultAccessMode, defaults.defaultAccessMode)
        // Settings of providers this version does not know are skipped, not the whole list.
        providers = container.lenientProviderMap(ProviderSettings.self, forKey: .providers)
        appearance = value(.appearance, defaults.appearance)
        sendOnReturn = value(.sendOnReturn, defaults.sendOnReturn)
        showReasoning = value(.showReasoning, defaults.showReasoning)
        confirmBeforeDeletingThreads = value(.confirmBeforeDeletingThreads, defaults.confirmBeforeDeletingThreads)
        idleSessionTimeoutMinutes = value(.idleSessionTimeoutMinutes, defaults.idleSessionTimeoutMinutes)
        notifyWhenInBackground = value(.notifyWhenInBackground, defaults.notifyWhenInBackground)
        checkpointsEnabled = value(.checkpointsEnabled, defaults.checkpointsEnabled)
        worktreeBranchPrefix = value(.worktreeBranchPrefix, defaults.worktreeBranchPrefix)
        fontSize = value(.fontSize, defaults.fontSize)
    }
}
