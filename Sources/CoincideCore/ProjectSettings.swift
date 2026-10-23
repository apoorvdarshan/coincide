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
    public var icon: ProjectIconOverride?
    public init(key: String, actions: [ProjectAction]? = nil, defaultThreadEnvMode: ProjectThreadEnvironmentMode? = nil,
                worktreeSubmodules: ProjectWorktreeSubmoduleMode? = nil, icon: ProjectIconOverride? = nil) {
        self.key = key; self.actions = actions; self.defaultThreadEnvMode = defaultThreadEnvMode
        self.worktreeSubmodules = worktreeSubmodules; self.icon = icon
    }
    public var isEmpty: Bool { actions == nil && defaultThreadEnvMode == nil && worktreeSubmodules == nil && icon == nil }
    public func validate() throws {
        guard !key.isEmpty, key.utf8.count <= 65_536, !key.contains("\0") else { throw ProjectSettingsFiles.invalid }
        if let actions { try ProjectActions.validate(actions) }
        try icon?.validate()
    }
    private enum CodingKeys: String, CodingKey { case version, key, actions, defaultThreadEnvMode, worktreeSubmodules, icon }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard try c.decode(Int.self, forKey: .version) <= Self.currentVersion else {
            throw CoincideError("These project settings were saved by a newer version of Coincide.")
        }
        key = try c.decode(String.self, forKey: .key)
        actions = try c.decodeIfPresent([ProjectAction].self, forKey: .actions)
        defaultThreadEnvMode = try c.decodeIfPresent(ProjectThreadEnvironmentMode.self, forKey: .defaultThreadEnvMode)
        worktreeSubmodules = try c.decodeIfPresent(ProjectWorktreeSubmoduleMode.self, forKey: .worktreeSubmodules)
        icon = try c.decodeIfPresent(ProjectIconOverride.self, forKey: .icon)
        try validate()
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.currentVersion, forKey: .version); try c.encode(key, forKey: .key)
        try c.encodeIfPresent(actions, forKey: .actions); try c.encodeIfPresent(defaultThreadEnvMode, forKey: .defaultThreadEnvMode)
        try c.encodeIfPresent(worktreeSubmodules, forKey: .worktreeSubmodules); try c.encodeIfPresent(icon, forKey: .icon)
    }
}

/// Bounded owner-only settings files, one per settings key, written by atomic replacement.
/// The managed helper reads the same file to verify an app-owned action plan before spawn.
public enum ProjectSettingsFiles {
    public static let maximumBytes = 262_144
    static var invalid: CoincideError { CoincideError("The project settings file is not valid. It was left unchanged.") }
    public static func root(dataRoot: URL) -> URL {
        dataRoot.standardizedFileURL.resolvingSymlinksInPath().appendingPathComponent("ProjectSettings", isDirectory: true)
    }
    public static func fileName(for key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined() + ".json"
    }
    public static func fileURL(root: URL, key: String) -> URL { root.appendingPathComponent(fileName(for: key), isDirectory: false) }
    /// The first existing document among candidate keys; nil when none has been saved.
    public static func load(root: URL, keys: [String]) throws -> (key: String, document: ProjectSettingsDocument)? {
        for key in keys { if let document = try load(root: root, key: key) { return (key, document) } }
        return nil
    }
    public static func load(root: URL, key: String) throws -> ProjectSettingsDocument? {
        guard let document = try read(fileURL: fileURL(root: root, key: key)) else { return nil }
        guard document.key == key else { throw invalid }
        return document
    }
    public static func read(fileURL: URL) throws -> ProjectSettingsDocument? {
        guard fileURL.isFileURL, fileURL.path.hasPrefix("/"), !fileURL.path.contains("\0") else { throw invalid }
        let parent = open(fileURL.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if parent < 0 && errno == ENOENT { return nil }
        guard parent >= 0 else { throw invalid }; defer { Darwin.close(parent) }
        try validateDirectory(parent)
        let fd = openat(parent, fileURL.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 && errno == ENOENT { return nil }
        guard fd >= 0 else { throw invalid }; defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_mode & 0o022 == 0,
              info.st_size > 0, info.st_size <= maximumBytes else { throw invalid }
        var bytes = [UInt8](repeating: 0, count: Int(info.st_size)), offset = 0
        while offset < bytes.count {
            let count = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!.advanced(by: offset), $0.count - offset) }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw invalid }; offset += count
        }
        do { return try JSONDecoder().decode(ProjectSettingsDocument.self, from: Data(bytes)) }
        catch let error as CoincideError { throw error }
        catch { throw invalid }
    }
    /// Empty documents remove their file, so resetting every override returns to inheritance.
    public static func save(_ document: ProjectSettingsDocument, root: URL) throws {
        try document.validate()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let parent = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw invalid }; defer { Darwin.close(parent) }
        try validateDirectory(parent)
        let name = fileName(for: document.key)
        if document.isEmpty {
            guard unlinkat(parent, name, 0) == 0 || errno == ENOENT else { throw invalid }
            return
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(document)
        guard data.count <= maximumBytes else { throw CoincideError("These project settings exceed the 256 KB limit.") }
        let temporary = ".settings-" + UUID().uuidString
        let fd = openat(parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw invalid }
        defer { Darwin.close(fd); _ = unlinkat(parent, temporary, 0) }
        var offset = 0
        while offset < data.count {
            let count = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: offset), $0.count - offset) }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw invalid }; offset += count
        }
        guard fsync(fd) == 0, renameat(parent, temporary, parent, name) == 0 else { throw invalid }
    }
    private static func validateDirectory(_ fd: Int32) throws {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else { throw invalid }
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
        guard let document, document.key == settingsKey, let action = document.actions?.first(where: { $0.id == actionID }),
              action.digest == digest, (try? action.script()) == script else { throw ProjectScriptExecutionError(.configurationChanged) }
        return action
    }
}
