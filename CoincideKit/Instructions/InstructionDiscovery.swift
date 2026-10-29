import Foundation

/// Whose instructions: one project's, or the user's global ones.
public enum InstructionScope: Hashable, Sendable {
    case project(URL)
    case global
}

/// Where the agents keep their global instruction files on this Mac, checked against the installed CLIs:
///
/// - Claude Code: `$CLAUDE_CONFIG_DIR/CLAUDE.md`, default `~/.claude/CLAUDE.md`.
/// - Codex: `$CODEX_HOME/AGENTS.md` (or `AGENTS.override.md`), default `~/.codex`.
/// - Grok Build: `$GROK_HOME/AGENTS.md`, default `~/.grok` (Grok's Project Rules guide). With its Claude compatibility
///   on, the default, it also reads `~/.claude/CLAUDE.md`.
/// - OpenCode: `AGENTS.md` in its config folder, `$XDG_CONFIG_HOME/opencode`, default `~/.config/opencode`
///   (`opencode debug paths`).
/// - Antigravity: `~/.gemini/GEMINI.md` and `~/.gemini/AGENTS.md` for `agy`; Coincide runs Antigravity in a private
///   profile (`AntigravityProfile`), whose own `GEMINI.md` is listed separately.
/// - Cursor keeps its user rules in its settings, not a file, so it has no global file here.
public struct InstructionLocations: Sendable, Hashable {
    /// A provider account with a config home of its own (`ProviderAccount.usesOwnHome`).
    public struct AccountHome: Sendable, Hashable {
        public var provider: ProviderKind
        public var name: String
        public var home: URL

        public nonisolated init(provider: ProviderKind, name: String, home: URL) {
            self.provider = provider
            self.name = name
            self.home = home
        }
    }

    public var home: URL
    public var claudeHome: URL
    public var codexHome: URL
    public var grokHome: URL
    public var openCodeConfig: URL
    public var geminiHome: URL
    /// Coincide's private Antigravity profile, when it was set up.
    public var antigravityProfile: URL?
    /// Where a global master file lives by default: a folder no agent owns, so removing one agent keeps it.
    public var coincideConfig: URL
    public var accountHomes: [AccountHome]

    public nonisolated init(
        home: URL, claudeHome: URL? = nil, codexHome: URL? = nil, grokHome: URL? = nil, openCodeConfig: URL? = nil,
        geminiHome: URL? = nil, antigravityProfile: URL? = nil, coincideConfig: URL? = nil, accountHomes: [AccountHome] = []
    ) {
        self.home = home
        self.claudeHome = claudeHome ?? home.appendingPathComponent(".claude", isDirectory: true)
        self.codexHome = codexHome ?? home.appendingPathComponent(".codex", isDirectory: true)
        self.grokHome = grokHome ?? home.appendingPathComponent(".grok", isDirectory: true)
        self.openCodeConfig = openCodeConfig ?? home.appendingPathComponent(".config/opencode", isDirectory: true)
        self.geminiHome = geminiHome ?? home.appendingPathComponent(".gemini", isDirectory: true)
        self.antigravityProfile = antigravityProfile
        self.coincideConfig = coincideConfig ?? home.appendingPathComponent(".config/coincide", isDirectory: true)
        self.accountHomes = accountHomes
    }

    /// The locations the agents Coincide starts would use: each provider's variables over the shell's `environment`,
    /// and the homes of the added accounts that keep their own.
    public nonisolated static func standard(
        environment: [String: String], providerEnvironments: [ProviderKind: [String: String]] = [:],
        accounts: [ProviderAccount] = [], dataDirectory: URL,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> InstructionLocations {
        func variable(_ name: String, _ kind: ProviderKind) -> URL? {
            let value = providerEnvironments[kind]?[name] ?? environment[name]
            guard let value, !value.isEmpty else { return nil }
            return URL(fileURLWithPath: (value as NSString).expandingTildeInPath, isDirectory: true)
        }
        let xdgConfig = variable("XDG_CONFIG_HOME", .opencode)
        let profile = AntigravityPaths(dataDirectory: dataDirectory).profileDirectory
        let homes = accounts.filter { $0.usesOwnHome && [.claude, .codex, .grok].contains($0.provider) }.map {
            AccountHome(provider: $0.provider, name: $0.name, home: $0.home(in: dataDirectory))
        }
        return InstructionLocations(
            home: home, claudeHome: variable("CLAUDE_CONFIG_DIR", .claude), codexHome: variable("CODEX_HOME", .codex),
            grokHome: variable("GROK_HOME", .grok), openCodeConfig: xdgConfig?.appendingPathComponent("opencode", isDirectory: true),
            antigravityProfile: InstructionPaths.isDirectory(profile) ? profile : nil, accountHomes: homes)
    }

    /// The default global master file.
    public nonisolated var defaultGlobalMaster: URL { coincideConfig.appendingPathComponent("AGENTS.md") }
}

/// One instruction file an agent reads, or would read once it exists.
public struct InstructionFile: Identifiable, Hashable, Sendable {
    /// The path the agents read, which may be a symbolic link.
    public var url: URL
    /// The path relative to the project, or with `~` for the home folder.
    public var displayName: String
    /// The agents that read this path.
    public var readers: [ProviderKind]
    /// Which account or install reads it, when that needs saying ("Antigravity CLI", an account's name).
    public var note: String?
    public var link: InstructionLink?
    /// The file the path stands for after following links.
    public var resolvedURL: URL
    public var exists: Bool

    public nonisolated var id: String { url.path }

    public nonisolated init(url: URL, displayName: String, readers: [ProviderKind], note: String? = nil) {
        self.url = url
        self.displayName = displayName
        self.readers = readers
        self.note = note
        let resolved = InstructionPaths.resolve(url)
        self.link = resolved.link
        self.resolvedURL = resolved.url
        self.exists = InstructionPaths.isRegularFile(url)
    }

    /// `CLAUDE.md → AGENTS.md` for a link, else the plain name.
    public nonisolated var linkDescription: String {
        guard let link else { return displayName }
        return "\(displayName) → \(link.destination)"
    }
}

/// Finds the instruction files of a project or of the user's global configuration.
public enum InstructionDiscovery {
    /// The agents that read a file of this name inside a project, from each CLI's own lookup: Codex, Cursor, Grok,
    /// OpenCode and Antigravity read `AGENTS.md`; Claude Code reads `CLAUDE.md`, `CLAUDE.local.md` and
    /// `.claude/CLAUDE.md`, as Grok does for compatibility; Antigravity reads `GEMINI.md`; Codex prefers
    /// `AGENTS.override.md`. Cursor also reads `CLAUDE.md` when its third-party rules setting is on, which Coincide
    /// cannot see, so it is not listed for it.
    public nonisolated static func readers(ofProjectFile name: String, inClaudeFolder: Bool = false) -> [ProviderKind] {
        if inClaudeFolder { return name == "CLAUDE.md" ? [.claude, .grok] : [] }
        switch name {
        case "AGENTS.md": return [.codex, .cursor, .grok, .opencode, .antigravity]
        case "AGENTS.override.md": return [.codex]
        case "CLAUDE.md", "CLAUDE.local.md": return [.claude, .grok]
        case "GEMINI.md": return [.antigravity]
        case ".cursorrules": return [.cursor]
        default: return name.hasSuffix(".mdc") ? [.cursor] : []
        }
    }

    /// Folders never searched for nested instruction files: dependencies, build output and version control.
    nonisolated static let skippedFolders: Set<String> = [
        ".git", ".hg", ".svn", "node_modules", ".build", "build", "DerivedData", "Pods", "Carthage", "vendor", "dist",
        ".venv", "venv", "target", ".next", ".nuxt", ".turbo", ".cache", "__pycache__", ".gradle", ".idea",
    ]

    /// A project's instruction files: every one that exists, at the top and in subfolders, plus the top-level files
    /// the `enabled` agents would read that don't exist yet. Subfolders are searched to `maximumDepth` and at most
    /// `folderLimit` folders, so a huge checkout stays quick.
    public nonisolated static func projectFiles(
        in root: URL, enabled: Set<ProviderKind> = Set(ProviderKind.allCases), maximumDepth: Int = 6, folderLimit: Int = 4000
    ) -> [InstructionFile] {
        let root = root.standardizedFileURL
        var files: [InstructionFile] = []
        func add(_ url: URL, readers: [ProviderKind]) {
            guard !readers.isEmpty else { return }
            files.append(InstructionFile(url: url, displayName: relative(url, to: root), readers: readers))
        }
        // The top level first, in a fixed order, then subfolders.
        for name in ["AGENTS.md", "CLAUDE.md", "GEMINI.md"] {
            let url = root.appendingPathComponent(name)
            let readers = readers(ofProjectFile: name)
            if InstructionPaths.itemExists(url) || !Set(readers).isDisjoint(with: enabled) { add(url, readers: readers) }
        }
        var queue: [(URL, Int)] = [(root, 0)]
        var visited = 0
        let manager = FileManager.default
        while !queue.isEmpty, visited < folderLimit {
            let (folder, depth) = queue.removeFirst()
            visited += 1
            guard let names = try? manager.contentsOfDirectory(atPath: folder.path) else { continue }
            for name in names.sorted() {
                let url = folder.appendingPathComponent(name)
                let isTop = folder == root
                switch name {
                case "AGENTS.md", "CLAUDE.md", "GEMINI.md":
                    if !isTop { add(url, readers: readers(ofProjectFile: name)) }
                case "AGENTS.override.md", "CLAUDE.local.md", ".cursorrules":
                    add(url, readers: readers(ofProjectFile: name))
                case ".claude":
                    let claude = url.appendingPathComponent("CLAUDE.md")
                    if InstructionPaths.itemExists(claude) { add(claude, readers: readers(ofProjectFile: "CLAUDE.md", inClaudeFolder: true)) }
                case ".cursor":
                    for rule in cursorRules(in: url.appendingPathComponent("rules", isDirectory: true)) {
                        add(rule, readers: [.cursor])
                    }
                default:
                    guard depth < maximumDepth, !name.hasPrefix("."), !skippedFolders.contains(name),
                        !InstructionPaths.isSymbolicLink(url), InstructionPaths.isDirectory(url)
                    else { continue }
                    queue.append((url, depth + 1))
                }
            }
        }
        return files
    }

    /// `.cursor/rules/**/*.mdc`.
    nonisolated static func cursorRules(in folder: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) else { return [] }
        var rules: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "mdc" { rules.append(url) }
        return rules.sorted { $0.path < $1.path }
    }

    /// The user's global instruction files: each agent's own, those of accounts with their own home, and any extra
    /// ones that exist. A missing file is listed when an `enabled` agent would read it and its folder exists.
    public nonisolated static func globalFiles(
        _ locations: InstructionLocations, enabled: Set<ProviderKind> = Set(ProviderKind.allCases)
    ) -> [InstructionFile] {
        let home = locations.home
        var files: [InstructionFile] = []
        func add(_ url: URL, _ readers: [ProviderKind], note: String? = nil, always: Bool) {
            let exists = InstructionPaths.itemExists(url)
            let wanted = always && !Set(readers).isDisjoint(with: enabled) && InstructionPaths.isDirectory(url.deletingLastPathComponent())
            guard exists || wanted else { return }
            guard !files.contains(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) else { return }
            files.append(InstructionFile(url: url, displayName: InstructionPaths.abbreviated(url, home: home), readers: readers, note: note))
        }
        // Grok reads the named files in `~/.claude`, not wherever CLAUDE_CONFIG_DIR points.
        let standardClaude = home.appendingPathComponent(".claude", isDirectory: true)
        let claudeReaders: [ProviderKind] =
            InstructionPaths.canonical(locations.claudeHome) == InstructionPaths.canonical(standardClaude) ? [.claude, .grok] : [.claude]
        add(locations.claudeHome.appendingPathComponent("CLAUDE.md"), claudeReaders, always: true)
        if claudeReaders == [.claude] {
            add(standardClaude.appendingPathComponent("CLAUDE.md"), [.grok], always: false)
        }
        add(locations.codexHome.appendingPathComponent("AGENTS.md"), [.codex], always: true)
        add(locations.codexHome.appendingPathComponent("AGENTS.override.md"), [.codex], always: false)
        add(locations.grokHome.appendingPathComponent("AGENTS.md"), [.grok], always: true)
        add(locations.openCodeConfig.appendingPathComponent("AGENTS.md"), [.opencode], always: true)
        let cli = String(localized: "Antigravity CLI")
        add(locations.geminiHome.appendingPathComponent("GEMINI.md"), [.antigravity], note: cli, always: true)
        add(locations.geminiHome.appendingPathComponent("AGENTS.md"), [.antigravity], note: cli, always: false)
        if let profile = locations.antigravityProfile {
            add(profile.appendingPathComponent("GEMINI.md"), [.antigravity], note: String(localized: "Antigravity in Coincide"), always: false)
        }
        for account in locations.accountHomes {
            let name = account.provider == .claude ? "CLAUDE.md" : "AGENTS.md"
            add(account.home.appendingPathComponent(name), [account.provider], note: account.name, always: true)
        }
        return files
    }

    /// Who reads `file`: its own readers plus those of every other listed path that leads to the same file, so
    /// `AGENTS.md` shows Claude Code when `CLAUDE.md` links to it.
    public nonisolated static func usedBy(_ file: InstructionFile, among files: [InstructionFile]) -> [ProviderKind] {
        let readers = Set(files.filter { $0.resolvedURL == file.resolvedURL }.flatMap(\.readers) + file.readers)
        return ProviderKind.allCases.filter(readers.contains)
    }

    /// `url` relative to `root` when inside it, else its full path.
    public nonisolated static func relative(_ url: URL, to root: URL) -> String {
        let path = url.standardizedFileURL.path
        let base = root.standardizedFileURL.path
        return path.hasPrefix(base + "/") ? String(path.dropFirst(base.count + 1)) : path
    }
}

/// Two instruction files at one level that agents read side by side but that have drifted apart: separate
/// `CLAUDE.md` and `AGENTS.md` files with different text.
public struct InstructionDivergence: Hashable, Sendable {
    public var first: URL
    public var second: URL

    public nonisolated init(first: URL, second: URL) {
        self.first = first
        self.second = second
    }

    /// The pairs in `folder` that are separate files with different content. Links to one file, or a missing side,
    /// are not a divergence.
    public nonisolated static func find(in folder: URL) -> [InstructionDivergence] {
        let agents = folder.appendingPathComponent("AGENTS.md")
        return ["CLAUDE.md", "GEMINI.md"].compactMap { name in
            let other = folder.appendingPathComponent(name)
            return differ(other, agents) ? InstructionDivergence(first: other, second: agents) : nil
        }
    }

    /// Whether both files exist, are different files, and hold different text.
    public nonisolated static func differ(_ first: URL, _ second: URL) -> Bool {
        guard InstructionPaths.isRegularFile(first), InstructionPaths.isRegularFile(second) else { return false }
        guard InstructionPaths.resolve(first).url != InstructionPaths.resolve(second).url else { return false }
        return (try? Data(contentsOf: first)) != (try? Data(contentsOf: second))
    }
}
