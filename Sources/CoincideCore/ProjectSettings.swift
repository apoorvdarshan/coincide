import CryptoKit
import Darwin
import Foundation

/// Settings identity for a project. A resolved repository identity shares settings across its
/// checkouts (T3 applies project settings to the whole group); otherwise the checkout path is used.
/// The checkout key stays a fallback so settings saved before identity resolution remain visible.
public enum ProjectSettingsKey {
    public static func candidates(for project: WorkspaceProject) -> [String] {
        let checkout = key("checkout", [URL(fileURLWithPath: project.path).standardizedFileURL.path])
        guard let identity = project.repositoryIdentity else { return [checkout] }
        let repository: String
        if let relative = identity.projectRelativePath, !relative.isEmpty { repository = key("repository_path", [identity.groupingKey, relative]) }
        else { repository = key("repository", [identity.groupingKey]) }
        return repository == checkout ? [checkout] : [repository, checkout]
    }
    public static func primary(for project: WorkspaceProject) -> String { candidates(for: project)[0] }
    private static func key(_ kind: String, _ parts: [String]) -> String { kind + ":" + parts.map { String($0.utf8.count) + ":" + $0 }.joined() }
}

public enum ProjectIconColor: String, Codable, CaseIterable, Sendable, Identifiable {
    case gray, red, orange, amber, yellow, lime, green, emerald, teal, cyan, sky, blue, indigo, violet, purple, fuchsia, pink, rose
    public var id: String { rawValue }
}

/// A user-chosen project icon. `nil` in settings means Automatic: t3.json `iconPath`, then
/// well-known favicon locations, then a monogram derived from the project name.
public enum ProjectIconOverride: Codable, Sendable, Equatable {
    case symbol(name: String, color: ProjectIconColor)
    case emoji(String)
    case monogram(text: String, color: ProjectIconColor)
    case image(path: String)

    public static let imageExtensions: Set<String> = ["svg", "png", "ico", "icns", "jpg", "jpeg", "gif", "webp", "avif"]
    public func validate() throws {
        switch self {
        case .symbol(let name, _):
            guard !name.isEmpty, name.utf8.count <= 64, name.unicodeScalars.allSatisfy({ ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "." }) else { throw Self.invalid }
        case .emoji(let value):
            guard !value.isEmpty, value.count <= 2, value.utf8.count <= 32, value == value.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw Self.invalid }
        case .monogram(let text, _):
            guard (1...2).contains(text.count), text.utf8.count <= 32,
                  text.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || CharacterSet.nonBaseCharacters.contains($0) }) else { throw Self.invalid }
        case .image(let path):
            guard ProjectIconResolver.isRelativePath(path), Self.imageExtensions.contains(URL(fileURLWithPath: path).pathExtension.lowercased()) else { throw Self.invalid }
        }
    }
    private static var invalid: CoincideError { CoincideError("This project icon is not valid.") }
    private enum CodingKeys: String, CodingKey { case kind, name, color, emoji, text, path }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "symbol": self = .symbol(name: try c.decode(String.self, forKey: .name), color: try c.decode(ProjectIconColor.self, forKey: .color))
        case "emoji": self = .emoji(try c.decode(String.self, forKey: .emoji))
        case "monogram": self = .monogram(text: try c.decode(String.self, forKey: .text), color: try c.decode(ProjectIconColor.self, forKey: .color))
        case "image": self = .image(path: try c.decode(String.self, forKey: .path))
        default: throw Self.invalid
        }
        try validate()
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .symbol(let name, let color): try c.encode("symbol", forKey: .kind); try c.encode(name, forKey: .name); try c.encode(color, forKey: .color)
        case .emoji(let value): try c.encode("emoji", forKey: .kind); try c.encode(value, forKey: .emoji)
        case .monogram(let text, let color): try c.encode("monogram", forKey: .kind); try c.encode(text, forKey: .text); try c.encode(color, forKey: .color)
        case .image(let path): try c.encode("image", forKey: .kind); try c.encode(path, forKey: .path)
        }
    }
}

/// App-owned per-project overrides. Absent fields inherit; an absent action list uses the checkout's
/// t3.json, while an empty list is an explicit override with no actions. T3 never writes t3.json.
public struct ProjectSettingsDocument: Codable, Sendable, Equatable {
    public static let currentVersion = 1
    public var key: String
    public var actions: [ProjectAction]?
    public var defaultThreadEnvMode: ProjectThreadEnvironmentMode?
    public var worktreeSubmodules: ProjectWorktreeSubmoduleMode?
    public var newWorktreesStartFromOrigin: Bool?
    public var icon: ProjectIconOverride?
    public init(key: String, actions: [ProjectAction]? = nil, defaultThreadEnvMode: ProjectThreadEnvironmentMode? = nil,
                worktreeSubmodules: ProjectWorktreeSubmoduleMode? = nil, icon: ProjectIconOverride? = nil,
                newWorktreesStartFromOrigin: Bool? = nil) {
        self.key = key; self.actions = actions; self.defaultThreadEnvMode = defaultThreadEnvMode
        self.worktreeSubmodules = worktreeSubmodules; self.icon = icon
        self.newWorktreesStartFromOrigin = newWorktreesStartFromOrigin
    }
    public var isEmpty: Bool { actions == nil && defaultThreadEnvMode == nil && worktreeSubmodules == nil && icon == nil && newWorktreesStartFromOrigin == nil }
    public func validate() throws {
        guard !key.isEmpty, key.utf8.count <= 65_536, !key.contains("\0") else { throw ProjectSettingsFiles.invalid }
        if let actions { try ProjectActions.validate(actions) }
        try icon?.validate()
    }
    private enum CodingKeys: String, CodingKey { case version, key, actions, defaultThreadEnvMode, worktreeSubmodules, icon, newWorktreesStartFromOrigin }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard try c.decode(Int.self, forKey: .version) <= Self.currentVersion else {
            throw CoincideError("These project settings were saved by a newer version of Coincide.")
        }
        guard try c.decode(Int.self, forKey: .version) >= 1 else { throw ProjectSettingsFiles.invalid }
        key = try c.decode(String.self, forKey: .key)
        actions = try c.decodeIfPresent([ProjectAction].self, forKey: .actions)
        defaultThreadEnvMode = try c.decodeIfPresent(ProjectThreadEnvironmentMode.self, forKey: .defaultThreadEnvMode)
        worktreeSubmodules = try c.decodeIfPresent(ProjectWorktreeSubmoduleMode.self, forKey: .worktreeSubmodules)
        newWorktreesStartFromOrigin = try c.decodeIfPresent(Bool.self, forKey: .newWorktreesStartFromOrigin)
        icon = try c.decodeIfPresent(ProjectIconOverride.self, forKey: .icon)
        try validate()
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.currentVersion, forKey: .version); try c.encode(key, forKey: .key)
        try c.encodeIfPresent(actions, forKey: .actions); try c.encodeIfPresent(defaultThreadEnvMode, forKey: .defaultThreadEnvMode)
        try c.encodeIfPresent(worktreeSubmodules, forKey: .worktreeSubmodules); try c.encodeIfPresent(icon, forKey: .icon)
        try c.encodeIfPresent(newWorktreesStartFromOrigin, forKey: .newWorktreesStartFromOrigin)
    }
}

/// A plan pin for an app-owned action: the managed helper re-reads this settings file and
/// requires the same action identity and execution digest immediately before spawn.
public struct ProjectActionPin: Codable, Sendable, Equatable {
    public let actionID: String
    public let digest: Data
    public let settingsKey: String
    public let settingsPath: String
    public init(action: ProjectAction, settingsKey: String, settingsFile: URL) {
        actionID = action.id; digest = action.digest; self.settingsKey = settingsKey; settingsPath = settingsFile.path
    }
    public func validate() throws {
        guard ProjectActions.isValidID(actionID), digest.count == 32, !settingsKey.isEmpty, settingsKey.utf8.count <= 65_536, !settingsKey.contains("\0"),
              ProjectScriptExecutionPlan.path(settingsPath), settingsPath.hasSuffix(".json") else { throw ProjectScriptExecutionError(.invalidPlan) }
    }
    /// The current action for this pin, or a configuration-changed failure.
    public func verify(script: ProjectScript) throws -> ProjectAction {
        let document: ProjectSettingsDocument?
        do { document = try ProjectSettingsFiles.read(fileURL: URL(fileURLWithPath: settingsPath)) }
        catch { throw ProjectScriptExecutionError(.configurationChanged) }
        guard let document, document.key.utf8.elementsEqual(settingsKey.utf8), let action = document.actions?.first(where: { $0.id == actionID }),
              action.digest == digest, (try? action.script()) == script else { throw ProjectScriptExecutionError(.configurationChanged) }
        return action
    }
}
