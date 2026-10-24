import Foundation
import Testing
@testable import CoincideCore

private struct ConfigurationEditorFixture {
    let root: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-configuration-editor-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    func file(_ text: String, name: String = "settings.json") throws -> URL {
        let path = root.appendingPathComponent(name)
        try Data(text.utf8).write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        return path
    }
    func clean() { try? FileManager.default.removeItem(at: root) }
}

@Test func providerConfigurationJSONPreservesUnknownCredentialsAndHidesSensitiveRules() async throws {
    let fixture = try ConfigurationEditorFixture(); defer { fixture.clean() }
    let source = try fixture.file(#"{"model":"sonnet","env":{"TEST_PRIVATE_VALUE":"fixture-secret"},"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"fixture-hook"}]}]},"permissions":{"allow":["Bash(curl -H 'Authorization: Bearer fixture')"]},"enabledPlugins":{"sample@local":true}}"#)
    let editor = ProviderConfigurationEditor()
    let document = try await editor.load(provider: .claude, scope: .user, sourceURL: source)
    #expect(!document.fields.contains(where: { $0.value.contains("fixture-secret") || $0.value.contains("fixture-hook") || $0.value.contains("Bearer") }))
    #expect(document.fields.first(where: { $0.id == "permissions/allow" })?.isEditable == false)
    #expect(document.fields.first(where: { $0.id == "enabledPlugins/sample@local" })?.value == "true")
    let updated = try await editor.save(document, changes: ["model": "opus", "disableAllHooks": "true", "enabledPlugins/sample@local": "false"])
    #expect(updated.fields.first(where: { $0.id == "model" })?.value == "opus")
    let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: source)) as? [String: Any])
    #expect((object["env"] as? [String: String])?["TEST_PRIVATE_VALUE"] == "fixture-secret")
    #expect((object["hooks"] as? [String: Any])?["PreToolUse"] != nil)
    #expect((object["disableAllHooks"] as? Bool) == true)
    #expect((object["permissions"] as? [String: Any])?["allow"] as? [String] == ["Bash(curl -H 'Authorization: Bearer fixture')"])
}

@Test func providerConfigurationRejectsExternalChangesWithoutOverwriting() async throws {
    let fixture = try ConfigurationEditorFixture(); defer { fixture.clean() }
    let source = try fixture.file(#"{"model":"sonnet"}"#)
    let editor = ProviderConfigurationEditor()
    let document = try await editor.load(provider: .claude, scope: .user, sourceURL: source)
    let other = #"{"model":"external-model"}"#
    try Data(other.utf8).write(to: source)
    await #expect(throws: CoincideError.self) { try await editor.save(document, changes: ["model": "opus"]) }
    #expect(try String(contentsOf: source, encoding: .utf8) == other)
}

@Test func providerConfigurationPreservesSymlinkAndRejectsRetargeting() async throws {
    let fixture = try ConfigurationEditorFixture(); defer { fixture.clean() }
    let first = try fixture.file(#"{"model":"sonnet"}"#, name: "first.json")
    let second = try fixture.file(#"{"model":"other"}"#, name: "second.json")
    let link = fixture.root.appendingPathComponent("settings.json")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: first)
    let editor = ProviderConfigurationEditor()
    let document = try await editor.load(provider: .claude, scope: .user, sourceURL: link)
    let saved = try await editor.save(document, changes: ["model": "opus"])
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == first.path)
    #expect(try String(contentsOf: first, encoding: .utf8).contains("opus"))
    try FileManager.default.removeItem(at: link)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: second)
    await #expect(throws: CoincideError.self) { try await editor.save(saved, changes: ["model": "sonnet"]) }
    #expect(try String(contentsOf: second, encoding: .utf8) == #"{"model":"other"}"#)
}

@Test func providerConfigurationTOMLEditsPreserveUnknownSectionsAndMultilineStrings() async throws {
    let fixture = try ConfigurationEditorFixture(); defer { fixture.clean() }
    let original = #"""
    # keep this comment
    model = "original"
    developer_instructions = """
    model = "this is not a key"
    [features]
    shell_tool = false
    """
    [features]
    shell_tool = true
    [mcp_servers."fixture.server"]
    command = "never-execute-this"
    env = { PRIVATE_VALUE = "fixture-secret" }
    """#
    let source = try fixture.file(original, name: "config.toml")
    let editor = ProviderConfigurationEditor()
    let document = try await editor.load(provider: .codex, scope: .user, sourceURL: source)
    #expect(document.fields.first(where: { $0.id == "features/shell_tool" })?.value == "true")
    #expect(!document.fields.contains(where: { $0.value.contains("fixture-secret") || $0.value.contains("never-execute") }))
    _ = try await editor.save(document, changes: ["model": "updated", "features/shell_tool": "false", "mcp_servers/fixture.server/enabled": "false", "sandbox_workspace_write/network_access": "false"])
    let text = try String(contentsOf: source, encoding: .utf8)
    #expect(text.contains("# keep this comment"))
    #expect(text.contains("model = \"this is not a key\""))
    #expect(text.contains("env = { PRIVATE_VALUE = \"fixture-secret\" }"))
    let parsed = try ProviderConfigurationTOML(data: Data(text.utf8))
    #expect(parsed.value(at: ["model"]) as? String == "updated")
    #expect(parsed.value(at: ["features", "shell_tool"]) as? Bool == false)
    #expect(parsed.value(at: ["mcp_servers", "fixture.server", "enabled"]) as? Bool == false)
    #expect(parsed.value(at: ["sandbox_workspace_write", "network_access"]) as? Bool == false)
}

@Test func providerConfigurationCodexPluginTogglePreservesManifestAndCustomSettings() async throws {
    let fixture = try ConfigurationEditorFixture(); defer { fixture.clean() }
    let original = #"""
    # preserve user configuration
    unknown_root = "keep"
    [plugins."fixture.plugin@local"]
    enabled = false
    manifest = "/fixture/plugins/sample/plugin.json"
    unknown_setting = "keep this too"
    [plugins."fixture.plugin@local".custom_settings]
    env = { PRIVATE_VALUE = "fixture-secret" }
    mode = "custom"
    [plugins."inherited@local"]
    manifest = "/fixture/plugins/inherited/plugin.json"
    [plugins."advanced@local"]
    enabled = "provider-specific-format"
    """# + "\n"
    let source = try fixture.file(original, name: "config.toml")
    let editor = ProviderConfigurationEditor()
    let document = try await editor.load(provider: .codex, scope: .user, sourceURL: source)
    let toggle = try #require(document.fields.first(where: { $0.id == "plugins/fixture.plugin@local/enabled" }))
    #expect(toggle.control == .toggle && toggle.group == "Plugins")
    #expect(toggle.value == "false" && toggle.isEditable)
    #expect(document.fields.first(where: { $0.id == "plugins/inherited@local/enabled" })?.value == "")
    #expect(document.fields.first(where: { $0.id == "plugins/advanced@local/enabled" })?.isEditable == false)
    #expect(!document.fields.contains(where: { $0.value.contains("fixture-secret") || $0.path.contains("manifest") || $0.path.contains("custom_settings") }))
    await #expect(throws: CoincideError.self) {
        try await editor.save(document, changes: ["plugins/not-configured/enabled": "true"])
    }
    let saved = try await editor.save(document, changes: [toggle.id: "true"])
    #expect(saved.fields.first(where: { $0.id == toggle.id })?.value == "true")
    #expect(try String(contentsOf: source, encoding: .utf8) == original.replacingOccurrences(of: "enabled = false\n", with: "enabled = true\n"))
}

@Test func providerConfigurationRejectsDuplicatesInlineParentsAndUnvalidatedEdits() async throws {
    let fixture = try ConfigurationEditorFixture(); defer { fixture.clean() }
    let editor = ProviderConfigurationEditor()
    let duplicate = try fixture.file(#"{"env":{"PRIVATE_VALUE":"a","PRIVATE_VALUE":"b"}}"#)
    await #expect(throws: CoincideError.self) { try await editor.load(provider: .claude, scope: .user, sourceURL: duplicate) }
    let source = try fixture.file("sandbox_workspace_write = { network_access = false }\nmodel = 'sample'\n", name: "config.toml")
    let document = try await editor.load(provider: .codex, scope: .user, sourceURL: source)
    #expect(document.fields.first(where: { $0.id == "sandbox_workspace_write/network_access" })?.isEditable == false)
    await #expect(throws: CoincideError.self) { try await editor.save(document, changes: ["sandbox_mode": "invalid-value"]) }
    await #expect(throws: CoincideError.self) { try await editor.save(document, changes: ["unknown/credential": "anything"]) }
    await #expect(throws: CoincideError.self) { try await editor.save(document, changes: ["model": "sk-private-fixture"]) }
}

@Test func providerConfigurationScopeResolutionAndInheritance() async throws {
    let fixture = try ConfigurationEditorFixture(); defer { fixture.clean() }
    let environment = ["HOME": fixture.root.path, "CODEX_HOME": fixture.root.path + "/codex-profile", "CLAUDE_CONFIG_DIR": fixture.root.path + "/claude-profile"]
    let codex = try ProviderConfigurationEditor.sourceURL(provider: .codex, scope: .user, codex: .init(), claude: .init(), workspacePath: nil, environment: environment)
    #expect(codex.path.hasSuffix("/codex-profile/config.toml"))
    let claude = try ProviderConfigurationEditor.sourceURL(provider: .claude, scope: .local, codex: .init(), claude: .init(), workspacePath: fixture.root.path, environment: environment)
    #expect(claude.path.hasSuffix("/.claude/settings.local.json"))
    let editor = ProviderConfigurationEditor()
    let absent = try await editor.load(provider: .claude, scope: .local, sourceURL: claude)
    #expect(!absent.exists && !FileManager.default.fileExists(atPath: claude.path))
    let saved = try await editor.save(absent, changes: ["effortLevel": "high", "permissions/deny": "Read(.env)\nRead(.env)\nBash(rm *)"])
    #expect(saved.exists)
    #expect(saved.fields.first(where: { $0.id == "permissions/deny" })?.value == "Read(.env)\nBash(rm *)")
    let inherited = try await editor.save(saved, changes: ["effortLevel": ""])
    #expect(inherited.fields.first(where: { $0.id == "effortLevel" })?.value == "")
    #expect(inherited.fields.first(where: { $0.id == "permissions/deny" })?.value == "Read(.env)\nBash(rm *)")
    #expect(throws: CoincideError.self) { try ProviderConfigurationEditor.sourceURL(provider: .codex, scope: .local, codex: .init(), claude: .init(), workspacePath: fixture.root.path, environment: environment) }
}

@Test func providerConfigurationTOMLHandlesDottedKeysAndHeaderWithoutNewline() throws {
    var dotted = try ProviderConfigurationTOML(data: Data("sandbox_workspace_write.network_access = true\n".utf8))
    try dotted.set(["sandbox_workspace_write", "network_access"], value: false)
    #expect(dotted.source == "sandbox_workspace_write.network_access = false\n")
    var table = try ProviderConfigurationTOML(data: Data("[features]".utf8))
    try table.set(["features", "shell_tool"], value: false)
    #expect(table.source == "[features]\nshell_tool = false\n")
    #expect(throws: CoincideError.self) { try ProviderConfigurationTOML(data: Data("model = 'a'\nmodel = 'b'\n".utf8)) }
}

@Test(arguments: [
    "unknown = this is not TOML\n",
    "unknown = 01\n",
    "unknown = [true false]\n",
    "unknown = { name = 'first', name = 'second' }\n",
    "unknown = { child = 'value', child.nested = true }\n",
    "unknown = 'value'\n[unknown]\nchild = true\n",
    "unknown.child = true\nunknown = 'value'\n",
    "unknown.child = true\n[unknown]\nother = false\n",
    "[[unknown]]\nname = 'first'\nname = 'second'\n",
    "unknown = \"bad\\qescape\"\n",
    "'bad'key'part' = true\n",
    "unknown = {\n}\n",
    "unknown = \u{000B}'value'\n",
    "unknown = 2026-02-31\n"
])
func providerConfigurationRejectsMalformedTOMLBeforeAnyWrite(malformed: String) async throws {
    let fixture = try ConfigurationEditorFixture(); defer { fixture.clean() }
    let original = "model = 'original'\n" + malformed
    let source = try fixture.file(original, name: "config.toml")
    let editor = ProviderConfigurationEditor()
    await #expect(throws: CoincideError.self) { try await editor.load(provider: .codex, scope: .user, sourceURL: source) }
    #expect(try String(contentsOf: source, encoding: .utf8) == original)
}

@Test func providerConfigurationPreservesValidOpaqueTOMLWhileEditingKnownValue() async throws {
    let fixture = try ConfigurationEditorFixture(); defer { fixture.clean() }
    let original = #"""
    model = "original"
    mixed = ["value", 1_024, -2.5e+2, 0xFF, true, { label = "nested", values = [1, 2,] }]
    stamp = 2024-02-29T23:59:59Z
    literal = '\not-an-escape'
    unicode = "\U0001F980"
    instructions = """
    Multiline content with \n and \
        continuation
    """
    [[skills.config]]
    path = "/fixture/first"
    enabled = false
    [skills.config.extra]
    nested = { safe = true }
    [[skills.config]]
    path = "/fixture/second"
    enabled = true
    [skills.config.extra]
    nested = { safe = false }
    """# + "\n"
    let source = try fixture.file(original, name: "config.toml")
    let editor = ProviderConfigurationEditor()
    let document = try await editor.load(provider: .codex, scope: .user, sourceURL: source)
    _ = try await editor.save(document, changes: ["model": "updated"])
    #expect(try String(contentsOf: source, encoding: .utf8) == original.replacingOccurrences(of: "model = \"original\"", with: "model = \"updated\""))
}

@Test(arguments: ["Bash(curl --token fixture-value)", "Bash(FOO_SECRET=fixture-value command)", "Bash(curl -H 'X-Api-Token: fixture-value')", "Bash(curl -H 'X-Custom: fixture-value')", "Bash(EXAMPLE_VALUE=fixture-value command)", "Bash(curl https://user:fixture-value@example.invalid)", "Bash(curl https://example.invalid?q=fixture-value)"]) // gitleaks:allow -- Literal synthetic redaction fixtures; no credentials.
func providerConfigurationHidesCredentialBearingPermissionRules(rule: String) async throws {
    let fixture = try ConfigurationEditorFixture(); defer { fixture.clean() }
    let object: [String: Any] = ["permissions": ["allow": [rule]]]
    let source = fixture.root.appendingPathComponent("settings.json")
    let bytes = try JSONSerialization.data(withJSONObject: object); try bytes.write(to: source)
    let editor = ProviderConfigurationEditor()
    let document = try await editor.load(provider: .claude, scope: .user, sourceURL: source)
    let field = try #require(document.fields.first(where: { $0.id == "permissions/allow" }))
    #expect(!field.isEditable && field.value.isEmpty)
    #expect(!document.fields.contains(where: { $0.value.contains("fixture-value") }))
    _ = try await editor.save(document, changes: ["model": "sonnet"])
    let saved = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: source)) as? [String: Any])
    #expect((saved["permissions"] as? [String: Any])?["allow"] as? [String] == [rule])
}
