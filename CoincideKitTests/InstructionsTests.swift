import Foundation
import Testing

@testable import CoincideKit

/// Instruction files are only ever created in temporary folders here; the user's own files are never touched.
struct InstructionsTests {
    private func folder(_ name: String = "project") throws -> URL {
        try TestRepository.makeDirectory(name)
    }

    private func write(_ text: String, _ path: String, in root: URL) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func read(_ path: String, in root: URL) -> String? {
        try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private func link(_ path: String, to destination: String, in root: URL) throws {
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent(path).path, withDestinationPath: destination)
    }

    private func destination(_ path: String, in root: URL) -> String? {
        try? FileManager.default.destinationOfSymbolicLink(atPath: root.appendingPathComponent(path).path)
    }

    // MARK: Discovery

    @Test func projectDiscoveryListsEachAgentsFiles() throws {
        let root = try folder()
        try write("agents", "AGENTS.md", in: root)
        try write("claude", "CLAUDE.md", in: root)
        try write("gemini", "GEMINI.md", in: root)
        try write("local", "CLAUDE.local.md", in: root)
        try write("override", "AGENTS.override.md", in: root)
        try write("claude folder", ".claude/CLAUDE.md", in: root)
        try write("rule", ".cursor/rules/style.mdc", in: root)
        try write("nested", "packages/app/AGENTS.md", in: root)
        try write("dependency", "node_modules/lib/AGENTS.md", in: root)

        let files = InstructionDiscovery.projectFiles(in: root)
        let readers = Dictionary(uniqueKeysWithValues: files.map { ($0.displayName, Set($0.readers)) })
        #expect(readers["AGENTS.md"] == [.codex, .cursor, .grok, .opencode, .antigravity])
        #expect(readers["CLAUDE.md"] == [.claude, .grok])
        #expect(readers["GEMINI.md"] == [.antigravity])
        #expect(readers["CLAUDE.local.md"] == [.claude, .grok])
        #expect(readers["AGENTS.override.md"] == [.codex])
        #expect(readers[".claude/CLAUDE.md"] == [.claude, .grok])
        #expect(readers[".cursor/rules/style.mdc"] == [.cursor])
        #expect(readers["packages/app/AGENTS.md"] != nil)
        #expect(readers["node_modules/lib/AGENTS.md"] == nil)
        #expect(files.allSatisfy { $0.exists })
        #expect(Array(files.prefix(3).map(\.displayName)) == ["AGENTS.md", "CLAUDE.md", "GEMINI.md"])
    }

    @Test func missingFilesAreListedOnlyForEnabledAgents() throws {
        let root = try folder()
        let claudeOnly = InstructionDiscovery.projectFiles(in: root, enabled: [.claude])
        #expect(claudeOnly.map(\.displayName) == ["CLAUDE.md"])
        #expect(!claudeOnly.contains { $0.exists })
        let codex = InstructionDiscovery.projectFiles(in: root, enabled: [.codex])
        #expect(codex.map(\.displayName) == ["AGENTS.md"])
        let antigravity = InstructionDiscovery.projectFiles(in: root, enabled: [.antigravity])
        #expect(antigravity.map(\.displayName) == ["AGENTS.md", "GEMINI.md"])
    }

    @Test func globalDiscoveryFollowsEachAgentsHome() throws {
        let home = try folder("home")
        let data = try folder("data")
        let claude = home.appendingPathComponent("claude-config")
        for path in ["claude-config", ".codex", ".grok", "xdg/opencode", ".gemini", ".claude"] {
            try FileManager.default.createDirectory(at: home.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        try write("codex", ".codex/AGENTS.md", in: home)
        try write("standard claude", ".claude/CLAUDE.md", in: home)
        let account = ProviderAccount(id: "work", provider: .codex, name: "Work")
        let accountHome = account.home(in: data)
        try FileManager.default.createDirectory(at: accountHome, withIntermediateDirectories: true)

        let locations = InstructionLocations.standard(
            environment: ["XDG_CONFIG_HOME": home.appendingPathComponent("xdg").path],
            providerEnvironments: [.claude: ["CLAUDE_CONFIG_DIR": claude.path]], accounts: [account], dataDirectory: data,
            home: home)
        #expect(locations.claudeHome.path == claude.path)
        #expect(locations.openCodeConfig.path == home.appendingPathComponent("xdg/opencode").path)
        #expect(locations.defaultGlobalMaster.path == home.appendingPathComponent(".config/coincide/AGENTS.md").path)

        let files = InstructionDiscovery.globalFiles(locations)
        let byName = Dictionary(uniqueKeysWithValues: files.map { ($0.displayName, $0) })
        #expect(byName["~/claude-config/CLAUDE.md"]?.readers == [.claude])
        #expect(byName["~/claude-config/CLAUDE.md"]?.exists == false)
        // Grok reads ~/.claude even when Claude Code's home moved.
        #expect(byName["~/.claude/CLAUDE.md"]?.readers == [.grok])
        #expect(byName["~/.codex/AGENTS.md"]?.exists == true)
        #expect(byName["~/.grok/AGENTS.md"]?.readers == [.grok])
        #expect(byName["~/xdg/opencode/AGENTS.md"]?.readers == [.opencode])
        #expect(byName["~/.gemini/GEMINI.md"]?.readers == [.antigravity])
        #expect(files.contains { $0.url == accountHome.appendingPathComponent("AGENTS.md") && $0.note == "Work" })
        // A disabled agent's missing file is left out.
        let onlyCodex = InstructionDiscovery.globalFiles(locations, enabled: [.codex])
        #expect(!onlyCodex.contains { $0.displayName == "~/.grok/AGENTS.md" })
    }

    @Test func symbolicLinksAreResolvedAndShareReaders() throws {
        let root = try folder()
        try write("shared", "AGENTS.md", in: root)
        try link("CLAUDE.md", to: "AGENTS.md", in: root)
        try link("GEMINI.md", to: "missing.md", in: root)
        let files = InstructionDiscovery.projectFiles(in: root)
        let claude = try #require(files.first { $0.displayName == "CLAUDE.md" })
        let agents = try #require(files.first { $0.displayName == "AGENTS.md" })
        let gemini = try #require(files.first { $0.displayName == "GEMINI.md" })
        #expect(claude.linkDescription == "CLAUDE.md → AGENTS.md")
        #expect(claude.resolvedURL == agents.resolvedURL)
        #expect(claude.link?.isBroken == false)
        #expect(gemini.link?.isBroken == true)
        #expect(!gemini.exists)
        #expect(Set(InstructionDiscovery.usedBy(agents, among: files)).isSuperset(of: [.claude, .codex, .grok]))
        #expect(InstructionDivergence.find(in: root).isEmpty)
    }

    @Test func separateClaudeAndAgentsFilesWithDifferentTextDiverge() throws {
        let root = try folder()
        try write("one", "AGENTS.md", in: root)
        try write("two", "CLAUDE.md", in: root)
        #expect(InstructionDivergence.find(in: root) == [
            InstructionDivergence(first: root.appendingPathComponent("CLAUDE.md"), second: root.appendingPathComponent("AGENTS.md"))
        ])
        try write("one", "CLAUDE.md", in: root)
        #expect(InstructionDivergence.find(in: root).isEmpty)
    }

    // MARK: Editing

    @Test func savingThroughALinkKeepsTheLink() throws {
        let root = try folder()
        try write("before\n", "AGENTS.md", in: root)
        try link("CLAUDE.md", to: "AGENTS.md", in: root)
        let claude = root.appendingPathComponent("CLAUDE.md")
        let snapshot = try InstructionFileStore.read(claude)
        #expect(snapshot.text == "before\n")
        try InstructionFileStore.write("after\n", to: claude, expecting: snapshot)
        #expect(destination("CLAUDE.md", in: root) == "AGENTS.md")
        #expect(InstructionPaths.isSymbolicLink(claude))
        #expect(read("AGENTS.md", in: root) == "after\n")
    }

    @Test func savingKeepsPermissions() throws {
        let root = try folder()
        try write("x", "AGENTS.md", in: root)
        let url = root.appendingPathComponent("AGENTS.md")
        chmod(url.path, 0o600)
        try InstructionFileStore.write("y", to: url)
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
    }

    @Test func externalChangesAreDetectedAndBlockSaving() throws {
        let root = try folder()
        let url = root.appendingPathComponent("AGENTS.md")
        try write("one", "AGENTS.md", in: root)
        let snapshot = try InstructionFileStore.read(url)
        #expect(!InstructionFileStore.hasChanged(url, since: snapshot))
        // Rewriting the same text, as some editors do, isn't a change.
        try write("one", "AGENTS.md", in: root)
        #expect(!InstructionFileStore.hasChanged(url, since: snapshot))
        try write("two, from another editor", "AGENTS.md", in: root)
        #expect(InstructionFileStore.hasChanged(url, since: snapshot))
        #expect(throws: InstructionFileError.changedOnDisk("AGENTS.md")) {
            try InstructionFileStore.write("mine", to: url, expecting: snapshot)
        }
        #expect(read("AGENTS.md", in: root) == "two, from another editor")
        // A file created after an empty snapshot is a change too.
        let missing = root.appendingPathComponent("CLAUDE.md")
        let empty = try InstructionFileStore.read(missing)
        try write("new", "CLAUDE.md", in: root)
        #expect(InstructionFileStore.hasChanged(missing, since: empty))
    }

    @Test func savingIntoAMissingFolderFails() throws {
        let root = try folder()
        try link("CLAUDE.md", to: "gone/AGENTS.md", in: root)
        #expect(throws: InstructionFileError.self) {
            try InstructionFileStore.write("text", to: root.appendingPathComponent("CLAUDE.md"))
        }
        #expect(destination("CLAUDE.md", in: root) == "gone/AGENTS.md")
    }

    // MARK: Helpers

    @Test func createAgentsFileUsesTheTemplateAndNeverOverwrites() throws {
        let root = try folder()
        try InstructionHelpers.createAgentsFile(in: root)
        #expect(read("AGENTS.md", in: root) == InstructionHelpers.agentsTemplate)
        try write("mine", "AGENTS.md", in: root)
        #expect(throws: InstructionFileError.alreadyExists("AGENTS.md")) { try InstructionHelpers.createAgentsFile(in: root) }
        #expect(read("AGENTS.md", in: root) == "mine")
    }

    @Test func linkClaudeHelperCreatesARelativeLinkAndRefusesToOverwrite() throws {
        let root = try folder()
        #expect(throws: InstructionFileError.missing("AGENTS.md")) { try InstructionHelpers.link("CLAUDE.md", in: root) }
        try write("shared", "AGENTS.md", in: root)
        try InstructionHelpers.link("CLAUDE.md", in: root)
        #expect(destination("CLAUDE.md", in: root) == "AGENTS.md")
        #expect(read("CLAUDE.md", in: root) == "shared")

        let other = try folder("other")
        try write("shared", "AGENTS.md", in: other)
        try write("claude's own", "CLAUDE.md", in: other)
        #expect(throws: InstructionFileError.alreadyExists("CLAUDE.md")) { try InstructionHelpers.link("CLAUDE.md", in: other) }
        #expect(read("CLAUDE.md", in: other) == "claude's own")
        try link("GEMINI.md", to: "nowhere.md", in: other)
        #expect(throws: InstructionFileError.alreadyExists("GEMINI.md")) { try InstructionHelpers.link("GEMINI.md", in: other) }
        #expect(destination("GEMINI.md", in: other) == "nowhere.md")
    }

    @Test func diffMarksAddedAndRemovedLines() {
        let lines = InstructionDiff.lines(from: "a\nb\nc", to: "a\nc\nd")
        #expect(lines == [.same("a"), .removed("b"), .same("c"), .added("d")])
    }

    // MARK: Master mode

    @Test func masterModeIsOffByDefault() throws {
        let data = try folder("data")
        let settings = InstructionSettings.load(from: InstructionSettings.file(in: data))
        #expect(settings.global == nil && settings.projects.isEmpty)
        let config = InstructionMasterConfig.projectDefault(data)
        #expect(!config.isEnabled)
        #expect(config.sync == .off)
        #expect(config.masterPath.hasSuffix("/AGENTS.md"))
        var saved = InstructionSettings()
        saved.projects[data.path] = config
        try saved.save(to: InstructionSettings.file(in: data))
        #expect(InstructionSettings.load(from: InstructionSettings.file(in: data)) == saved)
    }

    @Test func linkingCreatesRelativeLinksAndBacksUpDifferingFiles() throws {
        let root = try folder()
        try write("master\n", "AGENTS.md", in: root)
        try write("claude rules\n", "CLAUDE.md", in: root)
        let master = root.appendingPathComponent("AGENTS.md")
        let targets = InstructionMaster.targets(for: .project(root), master: master, locations: InstructionLocations(home: root))
        #expect(targets.map(\.displayName) == ["CLAUDE.md", "GEMINI.md"])

        let plan = InstructionMaster.plan(master: master, targets: targets)
        let states = Dictionary(uniqueKeysWithValues: plan.statuses.map { ($0.target.displayName, $0.state) })
        #expect(states["CLAUDE.md"] == .differs("claude rules\n"))
        #expect(states["GEMINI.md"] == .missing)

        let results = try InstructionMaster.apply(plan)
        #expect(destination("CLAUDE.md", in: root) == "AGENTS.md")
        #expect(destination("GEMINI.md", in: root) == "AGENTS.md")
        // Merged into the master under a heading, and the original kept in a backup.
        #expect(read("AGENTS.md", in: root) == "master\n\n## From CLAUDE.md\n\nclaude rules\n")
        let backup = try #require(results.first { $0.target.displayName == "CLAUDE.md" }?.backup)
        #expect(backup.lastPathComponent.hasPrefix("CLAUDE.md.coincide-backup-"))
        #expect(try String(contentsOf: backup, encoding: .utf8) == "claude rules\n")
        #expect(InstructionMaster.health(master: master, targets: targets).allSatisfy { $0.state == .linked })

        // Linking again leaves the links alone.
        let again = try InstructionMaster.apply(InstructionMaster.plan(master: master, targets: targets))
        #expect(again.allSatisfy { $0.outcome == .alreadyLinked })
    }

    @Test func keepMasterOnlyAndSkipChoices() throws {
        let root = try folder()
        try write("master", "AGENTS.md", in: root)
        try write("claude", "CLAUDE.md", in: root)
        try write("gemini", "GEMINI.md", in: root)
        let master = root.appendingPathComponent("AGENTS.md")
        let targets = InstructionMaster.targets(for: .project(root), master: master, locations: InstructionLocations(home: root))
        let plan = InstructionMaster.plan(master: master, targets: targets)
        let claude = root.appendingPathComponent("CLAUDE.md").path
        let gemini = root.appendingPathComponent("GEMINI.md").path
        let results = try InstructionMaster.apply(plan, choices: [claude: .useMaster, gemini: .skip])
        #expect(read("AGENTS.md", in: root) == "master")
        #expect(destination("CLAUDE.md", in: root) == "AGENTS.md")
        #expect(results.first { $0.target.url.path == claude }?.backup != nil)
        #expect(!InstructionPaths.isSymbolicLink(root.appendingPathComponent("GEMINI.md")))
        #expect(read("GEMINI.md", in: root) == "gemini")
        let health = InstructionMaster.health(master: master, targets: targets)
        #expect(health.first { $0.target.url.path == gemini }?.state == .differs("gemini"))
    }

    @Test func foreignLinksAreReportedAndReplacedOnlyWhenConfirmed() throws {
        let root = try folder()
        try write("master", "AGENTS.md", in: root)
        try write("elsewhere", "docs/RULES.md", in: root)
        try link("CLAUDE.md", to: "docs/RULES.md", in: root)
        let master = root.appendingPathComponent("AGENTS.md")
        let targets = InstructionMaster.targets(for: .project(root), master: master, locations: InstructionLocations(home: root))
        let plan = InstructionMaster.plan(master: master, targets: targets)
        let claude = try #require(plan.statuses.first { $0.target.displayName == "CLAUDE.md" })
        #expect(claude.state == .foreignLink("docs/RULES.md"))
        #expect(plan.defaultChoice(for: claude) == .skip)

        _ = try InstructionMaster.apply(plan)
        #expect(destination("CLAUDE.md", in: root) == "docs/RULES.md")

        let results = try InstructionMaster.apply(plan, choices: [claude.id: .useMaster])
        #expect(destination("CLAUDE.md", in: root) == "AGENTS.md")
        #expect(results.first { $0.target.id == claude.id }?.replacedLink == "docs/RULES.md")
        #expect(read("docs/RULES.md", in: root) == "elsewhere")
    }

    @Test func aMissingMasterIsSeededFromAnAgentsFile() throws {
        let home = try folder("home")
        try write("claude global", ".claude/CLAUDE.md", in: home)
        try write("codex global", ".codex/AGENTS.md", in: home)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".grok"), withIntermediateDirectories: true)
        let locations = InstructionLocations(home: home)
        let master = locations.defaultGlobalMaster
        let targets = InstructionMaster.targets(for: .global, master: master, locations: locations)
        let plan = InstructionMaster.plan(master: master, targets: targets)
        #expect(plan.seed == home.appendingPathComponent(".claude/CLAUDE.md"))
        #expect(plan.masterText == "claude global")
        let states = Dictionary(uniqueKeysWithValues: plan.statuses.map { ($0.target.displayName, $0.state) })
        #expect(states["~/.claude/CLAUDE.md"] == .identical)
        #expect(states["~/.codex/AGENTS.md"] == .differs("codex global"))
        #expect(states["~/.grok/AGENTS.md"] == .missing)
        #expect(states["~/.config/opencode/AGENTS.md"] == .folderMissing)

        _ = try InstructionMaster.apply(plan)
        #expect(read(".config/coincide/AGENTS.md", in: home)?.contains("## From ~/.codex/AGENTS.md") == true)
        #expect(destination(".claude/CLAUDE.md", in: home) == "../.config/coincide/AGENTS.md")
        #expect(destination(".grok/AGENTS.md", in: home) == "../.config/coincide/AGENTS.md")
        #expect(read(".grok/AGENTS.md", in: home)?.hasPrefix("claude global") == true)
        #expect(!InstructionPaths.itemExists(home.appendingPathComponent(".config/opencode/AGENTS.md")))
    }

    @Test func turningMasterModeOffReplacesLinksWithCopiesOrLeavesThem() throws {
        let root = try folder()
        try write("master", "AGENTS.md", in: root)
        let master = root.appendingPathComponent("AGENTS.md")
        let targets = InstructionMaster.targets(for: .project(root), master: master, locations: InstructionLocations(home: root))
        _ = try InstructionMaster.apply(InstructionMaster.plan(master: master, targets: targets))

        #expect(try InstructionMaster.disable(master: master, targets: targets, replaceWithCopies: false).isEmpty)
        #expect(destination("CLAUDE.md", in: root) == "AGENTS.md")

        let replaced = try InstructionMaster.disable(master: master, targets: targets, replaceWithCopies: true)
        #expect(Set(replaced.map(\.lastPathComponent)) == ["CLAUDE.md", "GEMINI.md"])
        #expect(!InstructionPaths.isSymbolicLink(root.appendingPathComponent("CLAUDE.md")))
        #expect(read("CLAUDE.md", in: root) == "master")
        #expect(read("GEMINI.md", in: root) == "master")
    }

    // MARK: Sync

    @Test func movingToICloudRelinksAndKeepsABackup() throws {
        let root = try folder()
        let cloud = InstructionCloud(root: try folder("iCloud"))
        #expect(cloud.isAvailable)
        #expect(!InstructionCloud(root: root.appendingPathComponent("no-icloud")).isAvailable)
        try write("master", "AGENTS.md", in: root)
        let master = root.appendingPathComponent("AGENTS.md")
        let targets = InstructionMaster.targets(for: .project(root), master: master, locations: InstructionLocations(home: root))
        _ = try InstructionMaster.apply(InstructionMaster.plan(master: master, targets: targets))

        let synced = cloud.file(named: "My: Project")
        #expect(synced.lastPathComponent == "My- Project.md")
        let report = try InstructionMasterMove.move(master: master, to: synced, targets: targets)
        #expect(!report.adoptedExisting)
        let backup = try #require(report.backup)
        #expect(try String(contentsOf: backup, encoding: .utf8) == "master")
        #expect(try String(contentsOf: synced, encoding: .utf8) == "master")
        #expect(destination("AGENTS.md", in: root) == synced.path)
        for name in ["CLAUDE.md", "GEMINI.md"] {
            #expect(InstructionPaths.resolve(root.appendingPathComponent(name)).url == InstructionPaths.canonical(synced))
        }
        // Edits through any agent's file land in iCloud Drive.
        try InstructionFileStore.write("edited", to: root.appendingPathComponent("CLAUDE.md"))
        #expect(try String(contentsOf: synced, encoding: .utf8) == "edited")

        // Turning sync off brings a regular file back and relinks the agents to it.
        try InstructionMasterMove.restore(from: synced, to: master, targets: targets)
        #expect(!InstructionPaths.isSymbolicLink(master))
        #expect(read("AGENTS.md", in: root) == "edited")
        #expect(destination("CLAUDE.md", in: root) == "AGENTS.md")
        #expect(InstructionPaths.isRegularFile(synced))
    }

    @Test func movingAdoptsTheCopyAnotherMacPutInICloud() throws {
        let root = try folder()
        let cloud = InstructionCloud(root: try folder("iCloud"))
        try write("this Mac", "AGENTS.md", in: root)
        let synced = cloud.file(named: "Global")
        try write("other Mac", "Coincide/Instructions/Global.md", in: cloud.root)
        let master = root.appendingPathComponent("AGENTS.md")
        let report = try InstructionMasterMove.move(master: master, to: synced, targets: [])
        #expect(report.adoptedExisting)
        #expect(read("AGENTS.md", in: root) == "other Mac")
        #expect(try String(contentsOf: try #require(report.backup), encoding: .utf8) == "this Mac")
    }

    @Test func evictedICloudFilesAreReportedNotOverwritten() throws {
        let root = try folder()
        let cloud = InstructionCloud(root: try folder("iCloud"))
        try write("local", "AGENTS.md", in: root)
        try write("", "Coincide/Instructions/.Global.md.icloud", in: cloud.root)
        let synced = cloud.file(named: "Global")
        #expect(InstructionCloud.state(of: synced) == .notDownloaded)
        #expect(throws: InstructionSyncError.notDownloaded("Global.md")) {
            try InstructionMasterMove.move(master: root.appendingPathComponent("AGENTS.md"), to: synced, targets: [])
        }
        #expect(read("AGENTS.md", in: root) == "local")
        #expect(!InstructionPaths.isSymbolicLink(root.appendingPathComponent("AGENTS.md")))
    }

    /// A repository cloned from a new bare remote, with test identity settings.
    private func clone(_ remote: URL, as name: String) async throws -> TestRepository {
        let parent = try folder("clones")
        let url = parent.appendingPathComponent(name)
        _ = await GitCLI.git(["clone", "-q", remote.path, url.path], in: parent)
        let repository = TestRepository(url: url)
        for (key, value) in [("user.email", "test@example.com"), ("user.name", "Test"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] {
            try await repository.git("config", key, value)
        }
        return repository
    }

    private func bareRemote() async throws -> (TestRepository, URL) {
        let seed = try await TestRepository.make()
        let remote = try folder("remote").appendingPathComponent("instructions.git")
        try await seed.git(["init", "-q", "--bare", "-b", "main", remote.path], in: seed.url)
        try await seed.git("remote", "add", "origin", remote.path)
        try await seed.git("push", "-q", "-u", "origin", "main")
        return (seed, remote)
    }

    @Test func commitOnSaveCommitsOnlyTheInstructionsAndPushes() async throws {
        let (_, remote) = try await bareRemote()
        let local = try await clone(remote, as: "local")
        let repository = try await InstructionGitRepository.open(local.url)
        let file = repository.file(named: "Global")
        try local.write("notes.txt", "not instructions\n")
        try InstructionFileStore.write("rules\n", to: file)
        #expect(try await repository.commit(file))
        #expect(try await repository.commit(file) == false)
        let committed = try await local.git("show", "--name-only", "--format=%s", "HEAD")
        #expect(committed.contains("Update Global.md"))
        #expect(committed.contains("Global.md"))
        #expect(!committed.contains("notes.txt"))
        #expect(try await repository.sync(allowedFiles: ["Global.md"]) == .pushed)
        let other = try await clone(remote, as: "other")
        #expect(other.read("Global.md") == "rules\n")
        #expect(try await repository.sync(allowedFiles: ["Global.md"]) == .upToDate)
    }

    @Test func syncRefusesToPushOtherFiles() async throws {
        let (_, remote) = try await bareRemote()
        let local = try await clone(remote, as: "local")
        try local.write("code.swift", "let x = 1\n")
        try await local.git("add", ".")
        try await local.git("commit", "-q", "-m", "code")
        let repository = try await InstructionGitRepository.open(local.url)
        await #expect(throws: InstructionSyncError.otherChanges(["code.swift"])) {
            try await repository.sync(allowedFiles: ["Global.md"])
        }
    }

    @Test func conflictingEditsAreReportedInsteadOfOverwritten() async throws {
        let (_, remote) = try await bareRemote()
        let first = try await clone(remote, as: "first")
        let second = try await clone(remote, as: "second")
        let one = try await InstructionGitRepository.open(first.url)
        let two = try await InstructionGitRepository.open(second.url)
        let fileOne = one.file(named: "Global")
        let fileTwo = two.file(named: "Global")
        try InstructionFileStore.write("base\n", to: fileOne)
        try await one.commit(fileOne)
        _ = try await one.sync(allowedFiles: ["Global.md"])
        #expect(try await two.sync(allowedFiles: ["Global.md"]) == .pulled)

        try InstructionFileStore.write("from the first Mac\n", to: fileOne)
        try await one.commit(fileOne)
        _ = try await one.sync(allowedFiles: ["Global.md"])
        try InstructionFileStore.write("from the second Mac\n", to: fileTwo)
        try await two.commit(fileTwo)
        await #expect(throws: InstructionSyncError.self) { try await two.sync(allowedFiles: ["Global.md"]) }
        // The second Mac keeps its own text and its commit; the remote keeps the first's.
        #expect(second.read("Global.md") == "from the second Mac\n")
        let status = try await second.git("status", "--porcelain")
        #expect(status.isEmpty)
        let third = try await clone(remote, as: "third")
        #expect(third.read("Global.md") == "from the first Mac\n")
    }

    @Test func gitHubRepositoriesAreAlwaysPrivate() {
        let arguments = InstructionGitRepository.gitHubCreateArguments(name: "coincide-instructions", folder: URL(fileURLWithPath: "/tmp/x"))
        #expect(arguments.contains("--private"))
        #expect(!arguments.contains("--public") && !arguments.contains("--internal"))
    }
}
