import Darwin
import Foundation
import Testing
@testable import CoincideCore

private struct IntegrationFixture {
    let root: URL
    var codex: URL { root.appendingPathComponent("home/.codex") }
    var claude: URL { root.appendingPathComponent("home/.claude") }
    var workspace: URL { root.appendingPathComponent("repo") }
    var library: URL { root.appendingPathComponent("library") }
    init() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-integration-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        root = directory.resolvingSymlinksInPath()
        for path in [codex, claude, workspace] {
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
    }
    func close() { try? FileManager.default.removeItem(at: root) }
    func write(_ path: URL, _ text: String) throws {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Data(text.utf8).write(to: path)
    }
    func scan() throws -> ProviderIntegrationScan {
        try ProviderIntegrationCatalog.scan(workspacePath: workspace.path, codexHome: codex.path, claudeHome: claude.path, libraryRoot: library)
    }
}

@Test func integrationTOMLRespectsQuotedKeysAndMultilinePayloadsWithoutInventingServers() throws {
    let text = #"""
    instructions = """
    [mcp_servers.fake]
    enabled = true
    """
    [mcp_servers."real.server"]
    enabled = false
    args = ["a#b", "[plugins.fake]", "secret"]
    [mcp_servers."real.server".env]
    TOKEN = 'private'
    [plugins.'tool@market']
    enabled = true
    """#
    let tables = try ProviderIntegrationTOML.tables(text)
    #expect(!tables.contains { $0.path == ["mcp_servers", "fake"] })
    #expect(tables.first { $0.path == ["mcp_servers", "real.server"] }?.values["enabled"] == "false")
    #expect(tables.contains { $0.path == ["plugins", "tool@market"] })
    #expect(throws: (any Error).self) { try ProviderIntegrationTOML.tables("[mcp_servers.bad]\nargs = [\"unterminated") }
}

@Test func integrationCatalogKeepsCredentialValuesAndHookBodiesOutOfDisplayMetadata() throws {
    let f = try IntegrationFixture(); defer { f.close() }
    try f.write(f.codex.appendingPathComponent("config.toml"), #"""
    notify = ["secret-hook-command", "secret-argument"]
    [mcp_servers."a.server"]
    url = "https://example.invalid/?key=secret-url"
    enabled = false
    args = ["secret-argument"]
    [mcp_servers."a.server".env]
    TOKEN = "secret-env"
    [mcp_servers."a.server".http_headers]
    Authorization = "secret-header"
    [plugins."tool@market"]
    enabled = false
    """#)
    try f.write(f.claude.appendingPathComponent("settings.json"), #"""
    { // JSONC is supported without evaluation
      "enabledPlugins": {"tool@market": true},
      "disableAllHooks": true,
      "hooks": {"PreToolUse": [{"matcher":"secret-matcher","hooks":[{"type":"command","command":"secret-command"}]}]},
      "mcpServers": {"local": {"command":"secret-executable","env":{"KEY":"secret-env"}}},
    }
    """#)
    let result = try f.scan()
    let serialized = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
    for token in ["secret-hook-command", "secret-argument", "secret-url", "secret-env", "secret-header", "secret-matcher", "secret-command", "secret-executable"] {
        #expect(!serialized.contains(token))
    }
    #expect(result.items.first { $0.name == "a.server" }?.enabled == false)
    #expect(result.items.first { $0.name == "PreToolUse" }?.enabled == false)
    #expect(result.items.contains { $0.provider == .claude && $0.kind == .plugins && $0.name == "tool@market" && $0.enabled })
    #expect(result.issues.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: f.library.path))
}

@Test func integrationCopiedSkillsKeepAssetsAndProvenanceAfterSourceDeletion() throws {
    let f = try IntegrationFixture(); defer { f.close() }
    let directory = f.codex.appendingPathComponent("skills/review")
    let instructions = "---\nname: review\ndescription: Review changes\n---\nRead references/rules.md.\nPRIVATE-INSTRUCTIONS"
    try f.write(directory.appendingPathComponent("SKILL.md"), instructions)
    try f.write(directory.appendingPathComponent("references/rules.md"), "Independent rules")
    let source = try #require(try f.scan().items.first { $0.name == "review" })
    #expect(!String(decoding: try JSONEncoder().encode(source), as: UTF8.self).contains("PRIVATE-INSTRUCTIONS"))
    #expect(throws: (any Error).self) { try ProviderIntegrationCatalog.invocationText(for: source, libraryRoot: f.library) }
    let imported = try ProviderIntegrationCatalog.importItem(source, libraryRoot: f.library)
    let path = try #require(imported.libraryPath)
    #expect(imported.importMode == .copied && imported.sourcePath == source.sourcePath)
    #expect(try String(contentsOfFile: path, encoding: .utf8) == instructions)
    #expect(try String(contentsOf: URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("references/rules.md"), encoding: .utf8) == "Independent rules")
    try FileManager.default.removeItem(at: directory)
    let listed = try #require(try f.scan().items.first { $0.id == imported.id })
    #expect(listed.available && listed.imported)
    let invocation = try ProviderIntegrationCatalog.invocationText(for: listed, libraryRoot: f.library)
    #expect(invocation.contains(path) && !invocation.contains("PRIVATE-INSTRUCTIONS"))
    let attributes = try FileManager.default.attributesOfItem(atPath: f.library.appendingPathComponent(imported.id).appendingPathComponent("entry.json").path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    try ProviderIntegrationCatalog.removeImport(id: imported.id, libraryRoot: f.library)
    #expect(try ProviderIntegrationCatalog.libraryItems(libraryRoot: f.library).isEmpty)
}

@Test func integrationCommandCopyPreservesSiblingResourcesWithoutChangingOriginal() throws {
    let f = try IntegrationFixture(); defer { f.close() }
    let directory = f.claude.appendingPathComponent("commands/team")
    try f.write(directory.appendingPathComponent("review.md"), "---\ndescription: Review command\n---\nRead rubric.txt")
    try f.write(directory.appendingPathComponent("rubric.txt"), "Command resource")
    let item = try #require(try f.scan().items.first { $0.kind == .commands && $0.name == "team:review" })
    let imported = try ProviderIntegrationCatalog.importItem(item, libraryRoot: f.library)
    let copied = URL(fileURLWithPath: try #require(imported.libraryPath))
    #expect(try String(contentsOf: copied.deletingLastPathComponent().appendingPathComponent("rubric.txt"), encoding: .utf8) == "Command resource")
    try ProviderIntegrationCatalog.removeImport(id: item.id, libraryRoot: f.library)
    #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("review.md").path))
}

@Test func integrationLinksNeverCopyConfigurationAndBecomeUnavailableWhenEntryDisappears() throws {
    let f = try IntegrationFixture(); defer { f.close() }
    let config = f.codex.appendingPathComponent("config.toml")
    let original = "[mcp_servers.local]\ncommand = 'keep-private'\n"
    try f.write(config, original)
    let item = try #require(try f.scan().items.first { $0.kind == .mcp })
    let imported = try ProviderIntegrationCatalog.importItem(item, libraryRoot: f.library)
    #expect(imported.importMode == .linked && imported.libraryPath == nil)
    #expect(try String(contentsOf: config, encoding: .utf8) == original)
    #expect(throws: (any Error).self) { try ProviderIntegrationCatalog.invocationText(for: imported, libraryRoot: f.library) }
    let files = try FileManager.default.contentsOfDirectory(atPath: f.library.appendingPathComponent(item.id).path)
    #expect(files == ["entry.json"])
    let metadata = try String(contentsOf: f.library.appendingPathComponent(item.id).appendingPathComponent("entry.json"), encoding: .utf8)
    #expect(!metadata.contains("keep-private"))
    try f.write(config, "model = 'example'\n")
    #expect(try f.scan().items.first { $0.id == item.id }?.available == false)
    try ProviderIntegrationCatalog.removeImport(id: item.id, libraryRoot: f.library)
    #expect(try String(contentsOf: config, encoding: .utf8) == "model = 'example'\n")
}

@Test func integrationImportsRejectExternalLinksCredentialFilesAndUnsafeLibraryPaths() throws {
    let f = try IntegrationFixture(); defer { f.close() }
    let directory = f.codex.appendingPathComponent("skills/safe")
    try f.write(directory.appendingPathComponent("SKILL.md"), "# Instructions")
    try f.write(f.root.appendingPathComponent("outside.txt"), "PRIVATE-OUTSIDE")
    try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("escape.txt"), withDestinationURL: f.root.appendingPathComponent("outside.txt"))
    let item = try #require(try f.scan().items.first { $0.kind == .skills })
    #expect(throws: (any Error).self) { try ProviderIntegrationCatalog.importItem(item, libraryRoot: f.library) }
    #expect(try ProviderIntegrationCatalog.libraryItems(libraryRoot: f.library).isEmpty)
    try FileManager.default.removeItem(at: directory.appendingPathComponent("escape.txt"))
    try f.write(directory.appendingPathComponent(".env"), "SECRET=private")
    #expect(throws: (any Error).self) { try ProviderIntegrationCatalog.importItem(item, libraryRoot: f.library) }
    try FileManager.default.removeItem(at: directory.appendingPathComponent(".env"))
    let alias = f.root.appendingPathComponent("library-alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: f.library)
    #expect(throws: (any Error).self) { try ProviderIntegrationCatalog.importItem(item, libraryRoot: alias) }
    #expect(throws: (any Error).self) { try ProviderIntegrationCatalog.removeImport(id: "../../outside.txt", libraryRoot: f.library) }
    #expect(try String(contentsOf: f.root.appendingPathComponent("outside.txt"), encoding: .utf8) == "PRIVATE-OUTSIDE")
}

@Test func integrationPhysicalAliasesDeduplicateWithoutLosingImportedProvenanceOrProviderScope() throws {
    let f = try IntegrationFixture(); defer { f.close() }
    let skills = f.codex.appendingPathComponent("skills")
    try f.write(skills.appendingPathComponent("review/SKILL.md"), "---\nname: review\n---\nReview the changes")
    let agentHome = f.codex.deletingLastPathComponent().appendingPathComponent(".agents")
    try FileManager.default.createDirectory(at: agentHome, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: agentHome.appendingPathComponent("skills"), withDestinationURL: skills)
    try FileManager.default.createSymbolicLink(at: f.claude.appendingPathComponent("skills"), withDestinationURL: skills)
    let scan = try f.scan()
    #expect(scan.items.filter { $0.provider == .codex && $0.kind == .skills }.count == 1)
    #expect(scan.items.filter { $0.provider == .claude && $0.kind == .skills }.count == 1)
    let alias = ProviderIntegrationItem(provider: .codex, kind: .skills, name: "review", summary: "Imported earlier through a shared folder",
        sourcePath: agentHome.appendingPathComponent("skills/review/SKILL.md").path, scope: "User", invocation: "$review")
    let imported = try ProviderIntegrationCatalog.importItem(alias, libraryRoot: f.library)
    let after = try f.scan().items.filter { $0.provider == .codex && $0.kind == .skills }
    #expect(after.count == 1 && after.first?.id == imported.id && after.first?.sourcePath == alias.sourcePath)
    #expect(after.first?.importMode == .copied)
}

@Test func integrationCodexRemoteInstallMarkersDiscoverPluginsAndAllVersionedSkillsWithoutConfigEntries() throws {
    let f = try IntegrationFixture(); defer { f.close() }
    let plugin = f.codex.appendingPathComponent("plugins/cache/remote/native-tools")
    try f.write(plugin.appendingPathComponent(".codex-remote-plugin-install.json"), "{\"schema_version\":1,\"remote_plugin_id\":\"opaque/provider/plugin\"}")
    try f.write(plugin.appendingPathComponent("0.1.4/.codex-plugin/plugin.json"), "{\"name\":\"native-tools\",\"skills\":\"./skills/\"}")
    for name in ["build", "signing", "windows"] {
        try f.write(plugin.appendingPathComponent("0.1.4/skills/\(name)/SKILL.md"), "---\nname: \(name)\n---\nInstructions")
    }
    try f.write(plugin.appendingPathComponent("0.1.4/commands/build.md"), "Build instructions")
    let cached = f.codex.appendingPathComponent("plugins/cache/remote/cached-tools")
    try f.write(cached.appendingPathComponent("1.0/.codex-plugin/plugin.json"), "{\"name\":\"cached-tools\"}")
    try f.write(cached.appendingPathComponent("1.0/skills/local/SKILL.md"), "Local cached instructions")
    let scan = try f.scan()
    #expect(scan.issues.isEmpty)
    #expect(scan.items.contains { $0.kind == .plugins && $0.name == "native-tools@remote" && $0.enabled && $0.scope == "Plugin" })
    #expect(scan.items.contains { $0.kind == .plugins && $0.name == "cached-tools@remote" && !$0.enabled && $0.scope == "Cache" })
    #expect(scan.items.filter { $0.kind == .skills && $0.name.hasPrefix("native-tools:") }.count == 3)
    #expect(scan.items.contains { $0.kind == .commands && $0.name == "native-tools:build" })
    #expect(!String(decoding: try JSONEncoder().encode(scan), as: UTF8.self).contains("opaque/provider/plugin"))
}

@Test func integrationCodexPluginAssetsFollowProjectOverride() throws {
    let f = try IntegrationFixture(); defer { f.close() }
    try f.write(f.codex.appendingPathComponent("config.toml"), "[plugins.\"tools@local\"]\nenabled = true\n")
    try f.write(f.workspace.appendingPathComponent(".codex/config.toml"), "[plugins.\"tools@local\"]\nenabled = false\n")
    let plugin = f.codex.appendingPathComponent("plugins/cache/local/tools/1.0")
    try f.write(plugin.appendingPathComponent("skills/review/SKILL.md"), "# Review")
    try f.write(plugin.appendingPathComponent("commands/review.md"), "# Review command")
    let scan = try f.scan()
    let assets = scan.items.filter { $0.provider == .codex && $0.scope == "Plugin" }
    #expect(assets.count == 2)
    #expect(assets.allSatisfy { !$0.enabled })
}

@Test func integrationImportRejectsHardLinksAndDoesNotCreateThroughAncestorSymlinks() throws {
    let f = try IntegrationFixture(); defer { f.close() }
    let directory = f.codex.appendingPathComponent("skills/review")
    try f.write(directory.appendingPathComponent("SKILL.md"), "# Review")
    let outside = f.root.appendingPathComponent("private-source.txt")
    try f.write(outside, "PRIVATE-OUTSIDE")
    let hardLink = directory.appendingPathComponent("reference.txt")
    try FileManager.default.linkItem(at: outside, to: hardLink)
    let item = try #require(try f.scan().items.first { $0.kind == .skills })
    #expect(throws: (any Error).self) { try ProviderIntegrationCatalog.importItem(item, libraryRoot: f.library) }
    #expect(try ProviderIntegrationCatalog.libraryItems(libraryRoot: f.library).isEmpty)
    try FileManager.default.removeItem(at: hardLink)
    let alias = f.root.appendingPathComponent("alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: f.root)
    let redirected = alias.appendingPathComponent("must-not-be-created")
    #expect(throws: (any Error).self) { try ProviderIntegrationCatalog.importItem(item, libraryRoot: redirected) }
    #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("must-not-be-created").path))
    #expect(try String(contentsOf: outside, encoding: .utf8) == "PRIVATE-OUTSIDE")
}

@Test func integrationPluginSkillsCannotReadMetadataOutsideTheirInstallation() throws {
    let f = try IntegrationFixture(); defer { f.close() }
    try f.write(f.codex.appendingPathComponent("config.toml"), "[plugins.\"tools@local\"]\nenabled = true\n")
    let skills = f.codex.appendingPathComponent("plugins/cache/local/tools/1.0/skills")
    try f.write(skills.appendingPathComponent("safe/SKILL.md"), "# Safe instructions")
    let outside = f.root.appendingPathComponent("outside-skill")
    try f.write(outside.appendingPathComponent("SKILL.md"), "---\nname: external\ndescription: PRIVATE-OUTSIDE-DESCRIPTION\n---\nInstructions")
    try FileManager.default.createSymbolicLink(at: skills.appendingPathComponent("external"), withDestinationURL: outside)
    let scan = try f.scan()
    #expect(scan.items.contains { $0.name == "tools:safe" })
    #expect(!scan.items.contains { $0.name == "tools:external" })
    #expect(scan.issues.contains { $0.message.contains("outside its installation") })
    #expect(!String(decoding: try JSONEncoder().encode(scan), as: UTF8.self).contains("PRIVATE-OUTSIDE-DESCRIPTION"))
}
