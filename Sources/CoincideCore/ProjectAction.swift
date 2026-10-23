import CryptoKit
import Foundation

/// A per-action shortcut. Only printable single-character keys with Command or Control are
/// accepted, so an action cannot capture plain typing or a bare Return in an editor.
public struct ProjectActionShortcut: Codable, Sendable, Equatable, Hashable {
    public let key: String
    public let command: Bool
    public let shift: Bool
    public let option: Bool
    public let control: Bool
    public init(key: String, command: Bool = false, shift: Bool = false, option: Bool = false, control: Bool = false) throws {
        self.key = key.lowercased(); self.command = command; self.shift = shift; self.option = option; self.control = control
        try validate()
    }
    public func validate() throws {
        guard key.count == 1, let scalar = key.unicodeScalars.first, key.unicodeScalars.count == 1,
              scalar.isASCII, scalar.value > 0x20, scalar.value < 0x7f, command || control else {
            throw ProjectActionError(.invalidShortcut)
        }
        if Self.reserved.contains(self) { throw ProjectActionError(.reservedShortcut) }
    }
    /// Standard macOS and Coincide window commands that an action must not shadow.
    static let reserved: Set<ProjectActionShortcut> = Set(["q", "w", "n", "o", "t", ",", "c", "v", "x", "z", "a", "f", "h", "m", "s", "p", "."].compactMap {
        ProjectActionShortcut(unchecked: $0, command: true)
    } + ["n", "o", "z"].compactMap { ProjectActionShortcut(unchecked: $0, command: true, shift: true) }
      + ["t", "i"].compactMap { ProjectActionShortcut(unchecked: $0, command: true, option: true) })
    private init?(unchecked key: String, command: Bool = false, shift: Bool = false, option: Bool = false, control: Bool = false) {
        self.key = key; self.command = command; self.shift = shift; self.option = option; self.control = control
    }
    public var displayLabel: String {
        (control ? "⌃" : "") + (option ? "⌥" : "") + (shift ? "⇧" : "") + (command ? "⌘" : "") + key.uppercased()
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(key: c.decode(String.self, forKey: .key), command: c.decodeIfPresent(Bool.self, forKey: .command) ?? false,
                      shift: c.decodeIfPresent(Bool.self, forKey: .shift) ?? false, option: c.decodeIfPresent(Bool.self, forKey: .option) ?? false,
                      control: c.decodeIfPresent(Bool.self, forKey: .control) ?? false)
    }
    private enum CodingKeys: String, CodingKey { case key, command, shift, option, control }
}

/// Editable action fields, mirroring T3's project script editor. Normalization happens when an
/// action is built: waiting applies only to setup roles and a preview opens only with a URL.
public struct ProjectActionInput: Sendable, Equatable {
    public var name: String
    public var command: String
    public var icon: ProjectScriptIcon
    public var runOnWorktreeCreate: Bool
    public var waitForSetup: Bool
    public var runOnSettle: Bool
    public var previewURL: String
    public var autoOpenPreview: Bool
    public var shortcut: ProjectActionShortcut?
    public init(name: String = "", command: String = "", icon: ProjectScriptIcon = .play, runOnWorktreeCreate: Bool = false,
                waitForSetup: Bool = false, runOnSettle: Bool = false, previewURL: String = "", autoOpenPreview: Bool = false,
                shortcut: ProjectActionShortcut? = nil) {
        self.name = name; self.command = command; self.icon = icon; self.runOnWorktreeCreate = runOnWorktreeCreate
        self.waitForSetup = waitForSetup; self.runOnSettle = runOnSettle; self.previewURL = previewURL
        self.autoOpenPreview = autoOpenPreview; self.shortcut = shortcut
    }
    /// Import keeps the file's roles and preview; the shortcut is never imported.
    public init(script: ProjectScript) {
        self.init(name: script.name, command: script.command, icon: script.icon, runOnWorktreeCreate: script.runOnWorktreeCreate,
                  waitForSetup: script.runOnWorktreeCreate && !script.runsAsynchronously, runOnSettle: script.runOnSettle,
                  previewURL: script.previewURL ?? "", autoOpenPreview: script.previewURL != nil && script.autoOpenPreview)
    }
    public init(action: ProjectAction) {
        self.init(name: action.name, command: action.command, icon: action.icon, runOnWorktreeCreate: action.runOnWorktreeCreate,
                  waitForSetup: action.waitForSetup, runOnSettle: action.runOnSettle, previewURL: action.previewURL ?? "",
                  autoOpenPreview: action.autoOpenPreview, shortcut: action.shortcut)
    }
}

/// An app-owned project action. It is stored outside the repository, so editing it never writes t3.json.
public struct ProjectAction: Codable, Sendable, Equatable, Identifiable {
    public static let maximumCount = 50
    public static let maximumIDLength = 24
    public let id: String
    public let name: String
    public let command: String
    public let icon: ProjectScriptIcon
    public let runOnWorktreeCreate: Bool
    public let waitForSetup: Bool
    public let runOnSettle: Bool
    public let previewURL: String?
    public let autoOpenPreview: Bool
    public let shortcut: ProjectActionShortcut?

    public init(id: String, input: ProjectActionInput) throws {
        let name = input.name.trimmingCharacters(in: .whitespacesAndNewlines), command = input.command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ProjectActionError(.nameRequired) }
        guard !command.isEmpty else { throw ProjectActionError(.commandRequired) }
        let preview = input.previewURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !preview.isEmpty { _ = try PreviewURLPolicy.validate(preview) }
        self.id = id; self.name = name; self.command = command; icon = input.icon
        runOnWorktreeCreate = input.runOnWorktreeCreate; waitForSetup = input.runOnWorktreeCreate && input.waitForSetup
        runOnSettle = input.runOnSettle; previewURL = preview.isEmpty ? nil : preview
        autoOpenPreview = !preview.isEmpty && input.autoOpenPreview; shortcut = input.shortcut
        try validate()
    }
    public func validate() throws {
        guard ProjectActions.isValidID(id) else { throw ProjectActionError(.invalidConfiguration) }
        guard ProjectConfigurationValidation.nonempty(name), ProjectConfigurationValidation.nonempty(command),
              name.utf16.count <= 256, !waitForSetup || runOnWorktreeCreate, previewURL != nil || !autoOpenPreview,
              previewURL.map(ProjectConfigurationValidation.nonempty) ?? true else { throw ProjectActionError(.invalidConfiguration) }
        try shortcut?.validate()
    }
    /// The launch declaration shared with t3.json scripts. Setup actions run asynchronously unless
    /// they wait, matching T3's `async: false` for "Wait for it to finish".
    public func script() throws -> ProjectScript {
        try ProjectScript(name: name, command: command, icon: icon, runOnWorktreeCreate: runOnWorktreeCreate, runOnSettle: runOnSettle,
                          runsAsynchronously: !waitForSetup, previewURL: previewURL, autoOpenPreview: autoOpenPreview)
    }
    /// Execution identity: the stable ID plus every field that changes what runs or how it is gated.
    /// The shortcut is excluded, so assigning a key does not invalidate a reviewed setup plan.
    public var digest: Data {
        struct Pinned: Encodable { let id: String; let script: ProjectScript? }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(Pinned(id: id, script: try? script()))) ?? Data(id.utf8)
        return Data(SHA256.hash(data: data))
    }
    public var menuLabel: String { ProjectActions.menuLabel(name: name, setup: runOnWorktreeCreate, settle: runOnSettle) }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decode(String.self, forKey: .id)
        try self.init(id: id, input: .init(name: c.decode(String.self, forKey: .name), command: c.decode(String.self, forKey: .command),
            icon: c.decodeIfPresent(ProjectScriptIcon.self, forKey: .icon) ?? .play,
            runOnWorktreeCreate: c.decodeIfPresent(Bool.self, forKey: .runOnWorktreeCreate) ?? false,
            waitForSetup: c.decodeIfPresent(Bool.self, forKey: .waitForSetup) ?? false,
            runOnSettle: c.decodeIfPresent(Bool.self, forKey: .runOnSettle) ?? false,
            previewURL: c.decodeIfPresent(String.self, forKey: .previewURL) ?? "",
            autoOpenPreview: c.decodeIfPresent(Bool.self, forKey: .autoOpenPreview) ?? false,
            shortcut: c.decodeIfPresent(ProjectActionShortcut.self, forKey: .shortcut)))
    }
    private enum CodingKeys: String, CodingKey {
        case id, name, command, icon, runOnWorktreeCreate, waitForSetup, runOnSettle, previewURL = "previewUrl", autoOpenPreview, shortcut
    }
}

public struct ProjectActionError: Error, LocalizedError, Sendable, Equatable {
    public enum Failure: String, Sendable, Equatable {
        case nameRequired, commandRequired, invalidConfiguration, invalidShortcut, reservedShortcut, duplicateShortcut, tooMany, missing, invalidPreviewURL
    }
    public let failure: Failure
    public init(_ failure: Failure) { self.failure = failure }
    public var errorDescription: String? {
        switch failure {
        case .nameRequired: "Name is required."
        case .commandRequired: "Command is required."
        case .invalidConfiguration: "This project action is not valid."
        case .invalidShortcut: "Use a single key with Command or Control."
        case .reservedShortcut: "This shortcut is used by Coincide or macOS. Choose another."
        case .duplicateShortcut: "Another action already uses this shortcut."
        case .tooMany: "A project can have at most 50 actions."
        case .missing: "This action no longer exists. Reload the project actions."
        case .invalidPreviewURL: "Use an http or https preview URL without a user name or password."
        }
    }
}

/// Pure list operations matching T3's project script editor helpers.
public enum ProjectActions {
    public static func isValidID(_ id: String) -> Bool {
        guard !id.isEmpty, id.count <= ProjectAction.maximumIDLength else { return false }
        return id.split(separator: "-", omittingEmptySubsequences: false).allSatisfy { part in
            !part.isEmpty && part.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) }
        }
    }
    static func normalizedID(_ name: String) -> String {
        var value = "", pendingDash = false
        for scalar in name.lowercased().unicodeScalars {
            if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) {
                if pendingDash && !value.isEmpty { value += "-" }
                pendingDash = false; value.unicodeScalars.append(scalar)
            } else { pendingDash = true }
        }
        guard !value.isEmpty else { return "script" }
        guard value.count > ProjectAction.maximumIDLength else { return value }
        let trimmed = String(value.prefix(ProjectAction.maximumIDLength)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "script" : trimmed
    }
    public static func nextID(name: String, existing: some Sequence<String>) -> String {
        let taken = Set(existing), base = normalizedID(name)
        guard taken.contains(base) else { return base }
        for suffix in 2..<10_000 {
            let tail = "-\(suffix)", candidate = base + tail
            let safe = candidate.count <= ProjectAction.maximumIDLength ? candidate
                : String(base.prefix(max(1, ProjectAction.maximumIDLength - tail.count))).trimmingCharacters(in: CharacterSet(charactersIn: "-")) + tail
            if !taken.contains(safe), isValidID(safe) { return safe }
        }
        return String(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(ProjectAction.maximumIDLength))
    }
    /// One setup and one settle action per project: saving a role releases it from every other action.
    static func releasingRoles(_ action: ProjectAction, claimedBy input: ProjectActionInput) throws -> ProjectAction {
        let setup = input.runOnWorktreeCreate && action.runOnWorktreeCreate, settle = input.runOnSettle && action.runOnSettle
        guard setup || settle else { return action }
        var value = ProjectActionInput(action: action)
        if setup { value.runOnWorktreeCreate = false; value.waitForSetup = false }
        if settle { value.runOnSettle = false }
        return try ProjectAction(id: action.id, input: value)
    }
    public static func adding(_ input: ProjectActionInput, to actions: [ProjectAction]) throws -> [ProjectAction] {
        guard actions.count < ProjectAction.maximumCount else { throw ProjectActionError(.tooMany) }
        let action = try ProjectAction(id: nextID(name: input.name, existing: actions.map(\.id)), input: input)
        let next = try actions.map { try releasingRoles($0, claimedBy: input) } + [action]
        try validate(next); return next
    }
    public static func updating(_ id: String, with input: ProjectActionInput, in actions: [ProjectAction]) throws -> [ProjectAction] {
        guard actions.contains(where: { $0.id == id }) else { throw ProjectActionError(.missing) }
        let next = try actions.map { $0.id == id ? try ProjectAction(id: id, input: input) : try releasingRoles($0, claimedBy: input) }
        try validate(next); return next
    }
    public static func deleting(_ id: String, from actions: [ProjectAction]) throws -> [ProjectAction] {
        guard actions.contains(where: { $0.id == id }) else { throw ProjectActionError(.missing) }
        return actions.filter { $0.id != id }
    }
    public static func moving(_ actions: [ProjectAction], fromOffsets source: IndexSet, toOffset destination: Int) -> [ProjectAction] {
        guard !source.isEmpty, source.allSatisfy({ actions.indices.contains($0) }), (0...actions.count).contains(destination) else { return actions }
        let moving = source.map { actions[$0] }
        var remaining = actions.enumerated().filter { !source.contains($0.offset) }.map(\.element)
        remaining.insert(contentsOf: moving, at: destination - source.filter { $0 < destination }.count)
        return remaining
    }
    /// t3.json scripts not yet represented by an action, compared by command or case-insensitive name.
    public static func importable(_ scripts: [ProjectScript], existing actions: [ProjectAction]) -> [ProjectScript] {
        scripts.filter { script in !actions.contains { $0.command == script.command || $0.name.lowercased() == script.name.lowercased() } }
    }
    public static func validate(_ actions: [ProjectAction]) throws {
        guard actions.count <= ProjectAction.maximumCount else { throw ProjectActionError(.tooMany) }
        guard Set(actions.map(\.id)).count == actions.count,
              actions.filter(\.runOnWorktreeCreate).count <= 1, actions.filter(\.runOnSettle).count <= 1 else {
            throw ProjectActionError(.invalidConfiguration)
        }
        let shortcuts = actions.compactMap(\.shortcut)
        guard Set(shortcuts).count == shortcuts.count else { throw ProjectActionError(.duplicateShortcut) }
        for action in actions { try action.validate() }
    }
    public static func menuLabel(name: String, setup: Bool, settle: Bool) -> String {
        let roles = (setup ? [String(localized: "setup")] : []) + (settle ? [String(localized: "on settle")] : [])
        return roles.isEmpty ? name : "\(name) (\(roles.joined(separator: ", ")))"
    }
}
