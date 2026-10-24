import CoincideCore
import Foundation
import Testing
@testable import Coincide

private struct ConfigurationStoreFixture {
    let root: URL
    let codex: CodexRuntimeConfiguration
    let otherCodex: CodexRuntimeConfiguration
    let claude: ClaudeRuntimeProfile
    let project: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-config-store-" + UUID().uuidString).resolvingSymlinksInPath()
        project = root.appendingPathComponent("project")
        let first = root.appendingPathComponent("codex-one"), second = root.appendingPathComponent("codex-two")
        let claudeHome = root.appendingPathComponent("claude")
        for directory in [first, second, claudeHome, project.appendingPathComponent(".codex"), project.appendingPathComponent(".claude")] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        codex = .init(homeDirectory: first.path)
        otherCodex = .init(instanceID: UUID(), homeDirectory: second.path)
        claude = .init(configurationDirectory: claudeHome.path)
        try write("model = 'codex-one'\n", at: first.appendingPathComponent("config.toml"))
        try write("model = 'codex-two'\n", at: second.appendingPathComponent("config.toml"))
        try write(#"{"model":"claude-user"}"#, at: claudeHome.appendingPathComponent("settings.json"))
        try write("model = 'project-model'\n", at: project.appendingPathComponent(".codex/config.toml"))
        try write(#"{"model":"claude-local"}"#, at: project.appendingPathComponent(".claude/settings.local.json"))
    }
    func source(_ runtime: CodexRuntimeConfiguration? = nil) -> URL {
        URL(fileURLWithPath: (runtime ?? codex).homeDirectory!).appendingPathComponent("config.toml")
    }
    func write(_ text: String, at url: URL) throws {
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    func text(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }
    func clean() { try? FileManager.default.removeItem(at: root) }
    @MainActor func load(_ store: ProviderConfigurationEditorStore, runtime: CodexRuntimeConfiguration? = nil, force: Bool = false) async {
        await store.load(codex: runtime ?? codex, claude: claude, workspacePath: project.path, force: force)
    }
    @MainActor func model(_ store: ProviderConfigurationEditorStore) throws -> ProviderConfigurationField {
        try #require(store.document?.fields.first { $0.id == "model" })
    }
}

@MainActor @Test func providerConfigurationStoreReturningToThePageRetainsDraftAndOriginalRevision() async throws {
    let f = try ConfigurationStoreFixture(); defer { f.clean() }
    let store = ProviderConfigurationEditorStore()
    await f.load(store)
    let field = try f.model(store), source = try #require(store.document?.sourceURL)
    store.setValue("unsaved", for: field)
    try f.write("model = 'external'\n", at: source)
    // A Settings page's task reruns when the user returns. It must not replace
    // either the draft or its original compare-and-swap revision.
    await f.load(store)
    #expect(store.value(try f.model(store)) == "unsaved" && store.hasChanges)
    #expect(store.document?.sourceURL == source && !store.isBusy)
    await store.save()
    #expect(store.errorMessage != nil && store.message == nil && store.hasChanges)
    #expect(store.value(try f.model(store)) == "unsaved")
    #expect(try f.text(source) == "model = 'external'\n")
}

@MainActor @Test func providerConfigurationStoreRuntimeSwitchRetainsDistinctDraftsAndSavesOnlyCurrentSource() async throws {
    let f = try ConfigurationStoreFixture(); defer { f.clean() }
    let store = ProviderConfigurationEditorStore()
    await f.load(store)
    store.setValue("first-draft", for: try f.model(store))
    await f.load(store, runtime: f.otherCodex)
    #expect(store.document?.sourceURL == f.source(f.otherCodex))
    #expect(store.value(try f.model(store)) == "codex-two" && !store.hasChanges)
    store.setValue("second-draft", for: try f.model(store))
    await store.save()
    #expect(store.errorMessage == nil && !store.hasChanges && store.message != nil)
    #expect(try f.text(f.source()).contains("codex-one"))
    #expect(try f.text(f.source(f.otherCodex)).contains("second-draft"))
    await f.load(store)
    #expect(store.value(try f.model(store)) == "first-draft" && store.hasChanges)
    await store.save()
    #expect(try f.text(f.source()).contains("first-draft"))
    #expect(try f.text(f.source(f.otherCodex)).contains("second-draft"))
}

@MainActor @Test func providerConfigurationStoreRestoredDraftCannotOverwriteAnExternallyChangedSource() async throws {
    let f = try ConfigurationStoreFixture(); defer { f.clean() }
    let store = ProviderConfigurationEditorStore()
    await f.load(store)
    store.setValue("stale-draft", for: try f.model(store))
    await f.load(store, runtime: f.otherCodex)
    try f.write("model = 'external-while-away'\n", at: f.source())
    await f.load(store)
    #expect(store.value(try f.model(store)) == "stale-draft")
    await store.save()
    #expect(store.errorMessage != nil && store.hasChanges && !store.isBusy)
    #expect(try f.text(f.source()) == "model = 'external-while-away'\n")
    #expect(try f.text(f.source(f.otherCodex)) == "model = 'codex-two'\n")
    await f.load(store, force: true)
    #expect(store.value(try f.model(store)) == "external-while-away" && !store.hasChanges)
    #expect(store.errorMessage == nil && store.message == nil)
}

@MainActor @Test func providerConfigurationStoreExplicitDiscardDoesNotRestoreDiscardedDraftLater() async throws {
    let f = try ConfigurationStoreFixture(); defer { f.clean() }
    let store = ProviderConfigurationEditorStore()
    await f.load(store)
    store.setValue("discard-me", for: try f.model(store))
    await f.load(store, runtime: f.otherCodex)
    await f.load(store)
    #expect(store.hasChanges)
    store.discard()
    #expect(store.value(try f.model(store)) == "codex-one" && !store.hasChanges)
    await f.load(store, runtime: f.otherCodex)
    await f.load(store)
    #expect(store.value(try f.model(store)) == "codex-one" && !store.hasChanges)
    #expect(try f.text(f.source()) == "model = 'codex-one'\n")
}

@MainActor @Test func providerConfigurationStoreScopesAndProvidersDoNotReuseEachOthersDrafts() async throws {
    let f = try ConfigurationStoreFixture(); defer { f.clean() }
    let store = ProviderConfigurationEditorStore()
    await f.load(store)
    store.setValue("codex-user-draft", for: try f.model(store))
    store.scope = .project; await f.load(store)
    #expect(store.value(try f.model(store)) == "project-model" && !store.hasChanges)
    store.setValue("codex-project-draft", for: try f.model(store))
    store.provider = .claude; store.scope = .local; await f.load(store)
    #expect(store.value(try f.model(store)) == "claude-local" && !store.hasChanges)
    store.setValue("claude-local-draft", for: try f.model(store))
    store.scope = .user; await f.load(store)
    #expect(store.value(try f.model(store)) == "claude-user" && !store.hasChanges)
    store.provider = .codex; await f.load(store)
    #expect(store.value(try f.model(store)) == "codex-user-draft")
    store.scope = .project; await f.load(store)
    #expect(store.value(try f.model(store)) == "codex-project-draft")
    store.provider = .claude; store.scope = .local; await f.load(store)
    #expect(store.value(try f.model(store)) == "claude-local-draft")
    #expect(try f.text(f.source()) == "model = 'codex-one'\n")
}

@MainActor @Test func providerConfigurationStoreInvalidSourceClearsVisibleAuthorityAndRestoresOnlyItsOwnDraft() async throws {
    let f = try ConfigurationStoreFixture(); defer { f.clean() }
    let store = ProviderConfigurationEditorStore()
    await f.load(store)
    store.setValue("keep-this", for: try f.model(store))
    store.scope = .project
    await store.load(codex: f.codex, claude: f.claude, workspacePath: nil)
    #expect(store.document == nil && store.drafts.isEmpty && !store.hasChanges && !store.isBusy)
    #expect(store.errorMessage != nil)
    await store.save()
    #expect(try f.text(f.source()) == "model = 'codex-one'\n")
    store.scope = .user; await f.load(store)
    #expect(store.value(try f.model(store)) == "keep-this" && store.hasChanges)
    #expect(store.document?.sourceURL == f.source() && store.errorMessage == nil)
}

@MainActor @Test func providerConfigurationIntegrationNavigationTargetsExactProviderScopeAndRestoresBothDrafts() async throws {
    let f = try ConfigurationStoreFixture(); defer { f.clean() }
    let store = ProviderConfigurationEditorStore()
    await f.load(store)
    store.setValue("codex-unsaved", for: try f.model(store))
    let localSource = f.project.appendingPathComponent(".claude/settings.local.json")
    let claudeItem = ProviderIntegrationItem(provider: .claude, kind: .hooks, name: "PreToolUse", summary: "Configured hook",
        sourcePath: localSource.path, scope: "Local")
    let codexItem = ProviderIntegrationItem(provider: .codex, kind: .mcp, name: "fixture", summary: "Configured MCP server",
        sourcePath: f.source().path, scope: "User")
    let claudeTarget = try #require(ProviderConfigurationEditorStore.destination(for: claudeItem,
        codex: f.codex, claude: f.claude, workspacePath: f.project.path))
    let codexTarget = try #require(ProviderConfigurationEditorStore.destination(for: codexItem,
        codex: f.codex, claude: f.claude, workspacePath: f.project.path))
    try await store.selectSource(claudeTarget, codex: f.codex, claude: f.claude, workspacePath: f.project.path)
    #expect(store.provider == .claude && store.scope == .local && store.document?.sourceURL == localSource)
    #expect(store.value(try f.model(store)) == "claude-local" && !store.hasChanges)
    store.setValue("claude-unsaved", for: try f.model(store))
    try await store.selectSource(codexTarget, codex: f.codex, claude: f.claude, workspacePath: f.project.path)
    #expect(store.provider == .codex && store.scope == .user)
    #expect(store.value(try f.model(store)) == "codex-unsaved" && store.hasChanges)
    try await store.selectSource(claudeTarget, codex: f.codex, claude: f.claude, workspacePath: f.project.path)
    #expect(store.value(try f.model(store)) == "claude-unsaved" && store.hasChanges)
    #expect(try f.text(f.source()) == "model = 'codex-one'\n")
    #expect(try f.text(localSource) == #"{"model":"claude-local"}"#)
}

@MainActor @Test func providerConfigurationIntegrationNavigationRejectsForeignAndUnsupportedSourcePaths() async throws {
    let f = try ConfigurationStoreFixture(); defer { f.clean() }
    let foreign = ProviderIntegrationItem(provider: .codex, kind: .plugins, name: "fixture", summary: "Linked plugin",
        sourcePath: f.source(f.otherCodex).path, scope: "User", importMode: .linked)
    let manifest = ProviderIntegrationItem(provider: .claude, kind: .plugins, name: "fixture", summary: "Plugin manifest",
        sourcePath: f.project.appendingPathComponent("plugin.json").path, scope: "Project")
    let mcp = ProviderIntegrationItem(provider: .claude, kind: .mcp, name: "fixture", summary: "Project MCP file",
        sourcePath: f.project.appendingPathComponent(".mcp.json").path, scope: "Project")
    for item in [foreign, manifest, mcp] {
        #expect(ProviderConfigurationEditorStore.destination(for: item,
            codex: f.codex, claude: f.claude, workspacePath: f.project.path) == nil)
    }
    let registry = URL(fileURLWithPath: try #require(f.claude.configurationDirectory)).appendingPathComponent("plugins/installed_plugins.json")
    let installed = ProviderIntegrationItem(provider: .claude, kind: .plugins, name: "fixture", summary: "Installed plugin",
        sourcePath: registry.path, scope: "Project")
    let destination = try #require(ProviderConfigurationEditorStore.destination(for: installed,
        codex: f.codex, claude: f.claude, workspacePath: f.project.path))
    #expect(destination.provider == .claude && destination.scope == .project)
    #expect(destination.sourceURL == f.project.appendingPathComponent(".claude/settings.json"))
    #expect(ProviderConfigurationEditorStore.destination(for: installed,
        codex: f.codex, claude: f.claude, workspacePath: nil) == nil)

    let store = ProviderConfigurationEditorStore()
    await f.load(store)
    store.setValue("keep-draft", for: try f.model(store))
    let stale = ProviderConfigurationEditorStore.Destination(provider: .codex, scope: .user, sourceURL: f.source())
    await #expect(throws: CoincideError.self) {
        try await store.selectSource(stale, codex: f.otherCodex, claude: f.claude, workspacePath: f.project.path)
    }
    #expect(store.value(try f.model(store)) == "keep-draft" && store.hasChanges)
    #expect(store.document?.sourceURL == f.source())
}
