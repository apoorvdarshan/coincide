import Foundation

/// Where an older Coincide moved the master to sync it. Settings saved since then always say `off`: the master stays in
/// its place and `InstructionMasterConfig.iCloud` and `.git` keep copies of it in step instead.
/// `InstructionCopyMigration` brings settings that still say otherwise forward.
public enum InstructionSyncMethod: Codable, Hashable, Sendable {
    case off
    /// The master lives in iCloud Drive (`InstructionCloud`).
    case iCloud
    /// The master lives in a Git repository's work tree and is committed on save (`InstructionGitRepository`).
    case git(repository: String, pushOnSave: Bool)

    public nonisolated var isOff: Bool { self == .off }
}

/// "Use one file for all agents" for a project or the global configuration: every agent's file becomes a link to
/// one master file. Off by default.
public struct InstructionMasterConfig: Codable, Hashable, Sendable {
    public var isEnabled: Bool
    public var masterPath: String
    /// Only in settings from an older Coincide, which moved the master to sync it (`InstructionCopyMigration`).
    public var sync: InstructionSyncMethod
    /// Where the master was before an older Coincide moved it.
    public var localMasterPath: String?
    /// A copy in iCloud Drive kept in step with the master, or nil when that sync is off.
    public var iCloud: InstructionICloudCopy?
    /// A copy in a Git repository kept in step with the master, or nil when that sync is off.
    public var git: InstructionGitCopy?

    public nonisolated init(
        isEnabled: Bool = false, masterPath: String, sync: InstructionSyncMethod = .off, localMasterPath: String? = nil,
        iCloud: InstructionICloudCopy? = nil, git: InstructionGitCopy? = nil
    ) {
        self.isEnabled = isEnabled
        self.masterPath = masterPath
        self.sync = sync
        self.localMasterPath = localMasterPath
        self.iCloud = iCloud
        self.git = git
    }

    public nonisolated var masterURL: URL { URL(fileURLWithPath: masterPath) }

    /// A project's default: its `AGENTS.md`, which most agents read already.
    public nonisolated static func projectDefault(_ root: URL) -> InstructionMasterConfig {
        InstructionMasterConfig(masterPath: root.appendingPathComponent("AGENTS.md").path)
    }

    public nonisolated static func globalDefault(_ locations: InstructionLocations) -> InstructionMasterConfig {
        InstructionMasterConfig(masterPath: locations.defaultGlobalMaster.path)
    }
}

/// The master settings, kept in `instructions.json` in Coincide's data folder.
public struct InstructionSettings: Codable, Hashable, Sendable {
    public var global: InstructionMasterConfig?
    /// By project folder path.
    public var projects: [String: InstructionMasterConfig]

    public nonisolated init(global: InstructionMasterConfig? = nil, projects: [String: InstructionMasterConfig] = [:]) {
        self.global = global
        self.projects = projects
    }

    public nonisolated static func file(in dataDirectory: URL) -> URL { dataDirectory.appendingPathComponent("instructions.json") }

    /// The saved settings; none (everything off) when the file is missing or unreadable.
    public nonisolated static func load(from url: URL) -> InstructionSettings {
        guard let data = try? Data(contentsOf: url) else { return InstructionSettings() }
        return (try? JSONDecoder().decode(InstructionSettings.self, from: data)) ?? InstructionSettings()
    }

    public nonisolated func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

/// A file master mode links to the master, with the agents that read it.
public struct MasterTarget: Hashable, Sendable, Identifiable {
    public var url: URL
    public var displayName: String
    public var readers: [ProviderKind]
    public var note: String?

    public nonisolated var id: String { url.path }

    public nonisolated init(url: URL, displayName: String, readers: [ProviderKind], note: String? = nil) {
        self.url = url
        self.displayName = displayName
        self.readers = readers
        self.note = note
    }
}

/// Where a target stands against the master.
public enum MasterTargetState: Hashable, Sendable {
    /// A link that leads to the master.
    case linked
    /// Nothing there yet.
    case missing
    /// A separate file with the master's text.
    case identical
    /// A separate file with other text, which linking would replace.
    case differs(String)
    /// A link to some other file.
    case foreignLink(String)
    /// A link to nothing.
    case brokenLink(String)
    /// Its folder doesn't exist: the agent isn't set up on this Mac.
    case folderMissing
    case unreadable

    /// Whether the link health check should flag it.
    public nonisolated var needsAttention: Bool {
        switch self {
        case .linked, .folderMissing: false
        default: true
        }
    }
}

public struct MasterTargetStatus: Hashable, Sendable, Identifiable {
    public var target: MasterTarget
    public var state: MasterTargetState
    public nonisolated var id: String { target.id }
}

/// What to do with a target when linking.
public enum MasterChoice: Hashable, Sendable {
    /// Append the file's text to the master under a heading, then link it.
    case merge
    /// Link it to the master; a file's own text is kept only in its backup. For a link to elsewhere, replace it.
    case useMaster
    case skip
}

/// The checked situation before linking: the master's text, seeded from an agent's file when the master doesn't
/// exist yet, and each target's state.
public struct MasterPlan: Sendable {
    public var master: URL
    public var masterText: String
    /// The file whose text starts a master that doesn't exist yet.
    public var seed: URL?
    public var statuses: [MasterTargetStatus]

    /// The choice made for each target unless the user picks another: link what is missing or the same, merge what
    /// differs, and leave links to other files alone until the user says to replace them.
    public nonisolated func defaultChoice(for status: MasterTargetStatus) -> MasterChoice {
        switch status.state {
        case .missing, .identical: .useMaster
        case .differs: .merge
        default: .skip
        }
    }
}

/// What linking did to one target.
public struct MasterLinkResult: Hashable, Sendable {
    public enum Outcome: Hashable, Sendable {
        case linked
        case alreadyLinked
        case skipped
        case failed(String)
    }

    public var target: MasterTarget
    public var outcome: Outcome
    /// Where the file's own text was moved before linking.
    public var backup: URL?
    /// The destination of a link that was replaced.
    public var replacedLink: String?
}

/// Master mode's file work: which files it links, what they hold, linking them and undoing it.
public enum InstructionMaster {
    /// The files linked to the master: the project's `AGENTS.md`, `CLAUDE.md` and `GEMINI.md`, or each agent's global
    /// file (`InstructionLocations`). The master itself is left out.
    public nonisolated static func targets(for scope: InstructionScope, master: URL, locations: InstructionLocations) -> [MasterTarget] {
        var targets: [MasterTarget] = []
        switch scope {
        case .project(let root):
            for name in ["AGENTS.md", "CLAUDE.md", "GEMINI.md"] {
                targets.append(MasterTarget(
                    url: root.appendingPathComponent(name), displayName: name,
                    readers: InstructionDiscovery.readers(ofProjectFile: name)))
            }
        case .global:
            func add(_ url: URL, _ readers: [ProviderKind], note: String? = nil) {
                targets.append(MasterTarget(url: url, displayName: InstructionPaths.abbreviated(url, home: locations.home), readers: readers, note: note))
            }
            add(locations.claudeHome.appendingPathComponent("CLAUDE.md"), [.claude, .grok])
            add(locations.codexHome.appendingPathComponent("AGENTS.md"), [.codex])
            add(locations.grokHome.appendingPathComponent("AGENTS.md"), [.grok])
            add(locations.openCodeConfig.appendingPathComponent("AGENTS.md"), [.opencode])
            add(locations.geminiHome.appendingPathComponent("GEMINI.md"), [.antigravity], note: String(localized: "Antigravity CLI"))
            if let profile = locations.antigravityProfile {
                add(profile.appendingPathComponent("GEMINI.md"), [.antigravity], note: String(localized: "Antigravity in Coincide"))
            }
        }
        let masterPath = canonicalItem(master)
        return targets.filter { canonicalItem($0.url) != masterPath }
    }

    /// The path with its folders resolved but not the item itself, so a link and its destination stay apart.
    nonisolated static func canonicalItem(_ url: URL) -> String {
        InstructionPaths.canonical(url.deletingLastPathComponent()).appendingPathComponent(url.lastPathComponent).path
    }

    /// Where `target` stands against the master holding `masterText`.
    public nonisolated static func state(of target: MasterTarget, master: URL, masterText: String) -> MasterTargetState {
        let url = target.url
        guard InstructionPaths.isDirectory(url.deletingLastPathComponent()) else { return .folderMissing }
        if InstructionPaths.isSymbolicLink(url) {
            let resolved = InstructionPaths.resolve(url)
            let destination = resolved.link?.destination ?? ""
            if resolved.url == InstructionPaths.resolve(master).url || resolved.url.path == InstructionPaths.canonical(master).path {
                return .linked
            }
            return resolved.link?.isBroken == true ? .brokenLink(destination) : .foreignLink(destination)
        }
        guard InstructionPaths.itemExists(url) else { return .missing }
        guard InstructionPaths.isRegularFile(url), let text = try? InstructionFileStore.read(url).text else { return .unreadable }
        return text == masterText ? .identical : .differs(text)
    }

    /// Checks every target. When the master doesn't exist, the first agent file that is a regular file seeds it.
    public nonisolated static func plan(master: URL, targets: [MasterTarget]) -> MasterPlan {
        var text = ""
        var seed: URL?
        if InstructionPaths.isRegularFile(master) {
            text = (try? InstructionFileStore.read(master).text) ?? ""
        } else if let first = targets.first(where: {
            !InstructionPaths.isSymbolicLink($0.url) && InstructionPaths.isRegularFile($0.url)
        }), let seeded = try? InstructionFileStore.read(first.url).text {
            text = seeded
            seed = first.url
        }
        let statuses = targets.map { MasterTargetStatus(target: $0, state: state(of: $0, master: master, masterText: text)) }
        return MasterPlan(master: master, masterText: text, seed: seed, statuses: statuses)
    }

    /// The master's text with `text` from `name` appended under a heading.
    public nonisolated static func merged(_ master: String, adding text: String, from name: String) -> String {
        var result = master
        if !result.isEmpty, !result.hasSuffix("\n") { result += "\n" }
        if !result.isEmpty { result += "\n" }
        result += "## From \(name)\n\n" + text.trimmingCharacters(in: .newlines) + "\n"
        return result
    }

    /// Links the targets as `choices` say (missing entries take `plan.defaultChoice`). The master is written first,
    /// with any merged text; a file is moved to a `.coincide-backup-…` name beside it before its link takes its place,
    /// and put back if linking fails. Links already in place are left as they are.
    public nonisolated static func apply(_ plan: MasterPlan, choices: [String: MasterChoice] = [:]) throws -> [MasterLinkResult] {
        func choice(_ status: MasterTargetStatus) -> MasterChoice { choices[status.id] ?? plan.defaultChoice(for: status) }
        var text = plan.masterText
        for status in plan.statuses {
            if case .differs(let other) = status.state, choice(status) == .merge {
                text = merged(text, adding: other, from: status.target.displayName)
            }
        }
        let folder = plan.master.deletingLastPathComponent()
        if !InstructionPaths.isDirectory(folder) {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        if !InstructionPaths.isRegularFile(plan.master) || text != plan.masterText {
            try InstructionFileStore.write(text, to: plan.master)
        }
        return plan.statuses.map { status in
            var result = MasterLinkResult(target: status.target, outcome: .skipped)
            let picked = choice(status)
            switch status.state {
            case .linked:
                result.outcome = .alreadyLinked
            case .folderMissing, .unreadable:
                break
            case .missing:
                guard picked != .skip else { break }
                result.outcome = link(status.target.url, to: plan.master)
            case .identical, .differs:
                guard picked != .skip else { break }
                let backup = InstructionPaths.backupURL(for: status.target.url)
                guard rename(status.target.url.path, backup.path) == 0 else {
                    result.outcome = .failed(String(cString: strerror(errno)))
                    break
                }
                result.outcome = link(status.target.url, to: plan.master)
                if case .failed = result.outcome {
                    rename(backup.path, status.target.url.path)
                } else {
                    result.backup = backup
                }
            case .foreignLink(let destination), .brokenLink(let destination):
                guard picked == .useMaster else { break }
                guard unlink(status.target.url.path) == 0 else {
                    result.outcome = .failed(String(cString: strerror(errno)))
                    break
                }
                result.outcome = link(status.target.url, to: plan.master)
                if case .failed = result.outcome {
                    try? FileManager.default.createSymbolicLink(atPath: status.target.url.path, withDestinationPath: destination)
                } else {
                    result.replacedLink = destination
                }
            }
            return result
        }
    }

    /// Creates `url` as a relative link to `master`.
    nonisolated static func link(_ url: URL, to master: URL) -> MasterLinkResult.Outcome {
        let destination = InstructionPaths.relativePath(to: master, from: url.deletingLastPathComponent())
        do {
            try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: destination)
            return .linked
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Each target's state against the master as it is now, for the link health list.
    public nonisolated static func health(master: URL, targets: [MasterTarget]) -> [MasterTargetStatus] {
        let text = (try? InstructionFileStore.read(master).text) ?? ""
        return targets.map { MasterTargetStatus(target: $0, state: state(of: $0, master: master, masterText: text)) }
    }

    /// Turns master mode off for these targets. With `replaceWithCopies`, each link to the master becomes a regular
    /// file holding the master's text, so every agent keeps its instructions; otherwise the links stay. Returns the
    /// files replaced.
    @discardableResult
    public nonisolated static func disable(master: URL, targets: [MasterTarget], replaceWithCopies: Bool) throws -> [URL] {
        guard replaceWithCopies else { return [] }
        let text = try InstructionFileStore.read(master).text
        var replaced: [URL] = []
        for target in targets where state(of: target, master: master, masterText: text) == .linked {
            guard unlink(target.url.path) == 0 else { continue }
            try InstructionFileStore.writeAtomically(Data(text.utf8), to: target.url, name: target.displayName)
            replaced.append(target.url)
        }
        return replaced
    }

    /// Points every target that leads to `old` at `new` instead. Only links are changed.
    public nonisolated static func relink(_ targets: [MasterTarget], from old: URL, to new: URL) {
        let oldResolved = InstructionPaths.resolve(old).url
        let newResolved = InstructionPaths.resolve(new).url
        for target in targets where InstructionPaths.isSymbolicLink(target.url) {
            let resolved = InstructionPaths.resolve(target.url).url
            guard resolved == oldResolved || resolved == newResolved || resolved.path == InstructionPaths.canonical(old).path
            else { continue }
            guard unlink(target.url.path) == 0 else { continue }
            _ = link(target.url, to: new)
        }
    }
}
