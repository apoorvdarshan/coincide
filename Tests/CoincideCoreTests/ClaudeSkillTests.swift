import Foundation
import Darwin
import Testing
@testable import CoincideCore

private struct ClaudeSkillsFixture {
    let root: URL, workspace: URL, home: URL, managed: URL
    init() throws {
        let requested = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-claude-skills-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: requested, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard let physical = requested.path.withCString({ realpath($0, nil) }) else { throw CoincideError("The owned Claude skills fixture is unavailable") }
        root = URL(fileURLWithPath: String(cString: physical)); free(physical)
        workspace = root.appendingPathComponent("repo/packages/app"); home = root.appendingPathComponent("captured-home/.claude"); managed = root.appendingPathComponent("managed-settings.json")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }
    func write(_ path: String, _ text: String) throws {
        let url = URL(fileURLWithPath: path); try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
    func skill(_ base: String, _ name: String, _ header: String = "description: Metadata only", body: String = "PRIVATE-BODY-MUST-NOT-BE-COPIED") throws {
        try write(base + "/" + name + "/SKILL.md", "---\n" + header + "\n---\n" + body)
    }
    func configuration(args: [String] = [], pluginCache: String? = nil) throws -> ClaudeSkillDiscoveryConfiguration {
        let runtime = ClaudeRuntimeConfiguration(executable: "/offline/claude", configurationDirectory: home.path, workspacePath: workspace.path,
            configurationDirectorySelection: .explicitDirectory(environmentPath: home.path))
        var environment = ["HOME": root.appendingPathComponent("captured-home").path]
        environment["CLAUDE_CODE_PLUGIN_CACHE_DIR"] = pluginCache
        return try .init(runtime: runtime, environment: environment, launchArguments: args, managedSettingsPath: managed.path)
    }
    func inventory(args: [String] = [], pluginCache: String? = nil) throws -> ProviderSkillInventory {
        try ClaudeSkillService.discover(configuration: configuration(args: args, pluginCache: pluginCache))
    }
    func close() { try? FileManager.default.removeItem(at: root) }
}

@Test func claudeFilesystemSkillsUseCapturedScopesNativeFolderNamesAndExplicitInvocationPolicies() throws {
    let f = try ClaudeSkillsFixture(); defer { f.close() }
    try f.skill(f.home.path + "/skills", "review", "name: ignored-alias\ndescription: >-\n  User description\n  with exact folded text\ndisable-model-invocation: yes")
    try f.skill(f.workspace.path + "/.claude/skills", "review", "description: Lower precedence project copy")
    try f.skill(f.workspace.path + "/.claude/skills", "hidden", "user-invocable: false")
    try f.skill(f.root.path + "/additional/.claude/skills", "extra")
    try f.skill(f.root.path + "/captured-home/.agents/skills", "not-claude")
    let value = try f.inventory(args: ["--add-dir", f.root.path + "/additional"])
    #expect(value.skills.map(\.name) == ["extra", "hidden", "review"])
    let review = try #require(value.skills.first { $0.name == "review" })
    #expect(review.scope == "user" && review.userInvocationOnly && review.description == "User description with exact folded text")
    #expect(value.skills.first { $0.name == "hidden" }?.canInvokeFromComposer == false)
    #expect(!String(reflecting: value).contains("PRIVATE-BODY-MUST-NOT-BE-COPIED") && !value.isPartial)
}

@Test func claudeFilesystemSkillSettingsMatchWholeMapValidationJSONCAndRepositoryLocalPrecedence() throws {
    let f = try ClaudeSkillsFixture(); defer { f.close() }
    let repository = f.root.path + "/repo"; try FileManager.default.createDirectory(atPath: repository + "/.git", withIntermediateDirectories: true)
    for name in ["root-off", "root-on", "invalid-sibling"] { try f.skill(f.home.path + "/skills", name) }
    try f.write(f.home.path + "/settings.json", "{ // comment\n\"skillOverrides\": {\"root-off\":\"on\",\"root-on\":\"off\",},}")
    try f.write(f.workspace.path + "/.claude/settings.local.json", "{\"skillOverrides\":{\"root-off\":\"on\"}}")
    try f.write(repository + "/.claude/settings.json", "{\"skillOverrides\":{\"invalid-sibling\":\"off\"}}")
    try f.write(repository + "/.claude/settings.local.json", "{\"skillOverrides\":{\"root-off\":\"off\",\"root-on\":\"user-invocable-only\"}}")
    try f.write(f.managed.path, "{\"skillOverrides\":{\"invalid-sibling\":\"off\",\"bad\":true}}")
    let value = try f.inventory(), rows = Dictionary(uniqueKeysWithValues: value.skills.map { ($0.name, $0) })
    #expect(rows["root-off"]?.enabled == false && rows["root-on"]?.enabled == true && rows["root-on"]?.userInvocationOnly == true)
    #expect(rows["invalid-sibling"]?.enabled == true && value.isPartial)
    try FileManager.default.removeItem(atPath: repository + "/.git")
    let outside = try f.inventory(); #expect(outside.skills.first { $0.name == "root-off" }?.enabled == true)
}

@Test func claudeFilesystemPluginSkillsRespectRegistryOrderNamesNamespacesAndManifestSymlinkBoundaries() throws {
    let f = try ClaudeSkillsFixture(); defer { f.close() }
    let cache = f.root.path + "/cache", plugin = f.root.path + "/plugin", outside = f.root.path + "/outside"
    try f.skill(plugin + "/skills", "review", "name: ignored-native-alias\ndescription: Plugin review\ndisable-model-invocation: true")
    try f.write(plugin + "/.claude-plugin/plugin.json", "{\"name\":\"engineering\",\"skills\":[\"./declared\",\"../outside\",\"./escape\"]}")
    try f.write(plugin + "/declared/SKILL.md", "---\nname: engineering:root.alias\n---\nPRIVATE-BODY-MUST-NOT-BE-COPIED")
    try f.skill(outside, "foreign")
    try FileManager.default.createSymbolicLink(atPath: plugin + "/escape", withDestinationPath: outside)
    try f.write(cache + "/installed_plugins.json", "{\"plugins\":{\"pkg@shop\":[{\"scope\":\"user\",\"installPath\":\"/missing/offline/plugin\"},{\"scope\":\"user\",\"installPath\":\"\(plugin)\"}]}}")
    try f.write(f.home.path + "/settings.json", "{\"enabledPlugins\":{\"pkg@shop\":true},\"skillOverrides\":{\"engineering:review\":\"off\"}}")
    let value = try f.inventory(pluginCache: cache)
    #expect(value.skills.map(\.name) == ["engineering:review", "engineering:root-alias"])
    #expect(value.skills.allSatisfy(\.enabled) && value.skills.first?.userInvocationOnly == true)
    #expect(!String(reflecting: value).contains("PRIVATE-BODY-MUST-NOT-BE-COPIED"))
}

@Test func claudeFilesystemFrontmatterSupportsNativeColonRepairBooleanSpellingAndBoundedYAML() throws {
    let f = try ClaudeSkillsFixture(); defer { f.close() }
    let base = f.home.path + "/skills"
    try f.skill(base, "colon", "description: Run: browser objectives. # retained comment syntax\nuser-invocable: off\ndisable-model-invocation: 1.0")
    try f.skill(base, "alias", "shared: &text \"Quoted: scalar\"\ndescription: *text")
    try f.skill(base, "broken", "description: ok\nallowed-tools: [Read, Write")
    try f.skill(base, "deep", "unknown: " + String(repeating: "[", count: 100) + "x" + String(repeating: "]", count: 100))
    try f.skill(base, "bomb", "a: &a [x,x,x,x,x,x,x,x,x,x]\nb: &b [*a,*a,*a,*a,*a,*a,*a,*a,*a,*a]\nc: &c [*b,*b,*b,*b,*b,*b,*b,*b,*b,*b]\nd: [*c,*c,*c,*c,*c,*c,*c,*c,*c,*c]")
    try f.write(base + "/plain/SKILL.md", "# Plain body only")
    let value = try f.inventory(), names = value.skills.map(\.name)
    #expect(names == ["alias", "colon", "plain"] && value.problems.count == 3)
    #expect(value.skills.first?.description == "Quoted: scalar")
    let colon = try #require(value.skills.first { $0.name == "colon" })
    #expect(colon.description == "Run: browser objectives." && !colon.userInvocable && colon.userInvocationOnly)
}

@Test func claudeFilesystemSkillsAllowSharedSymlinkedSkillsAndRejectSpecialFilesWithoutReadingBodies() throws {
    let f = try ClaudeSkillsFixture(); defer { f.close() }
    let shared = f.root.path + "/shared", root = f.home.path + "/skills"
    try f.skill(shared, "linked", "description: Shared metadata")
    try FileManager.default.createSymbolicLink(atPath: root, withDestinationPath: shared)
    let value = try f.inventory(); #expect(value.skills.map(\.name) == ["linked"])
    try f.write(shared + "/large/SKILL.md", "---\ndescription: Small header\n---\n" + String(repeating: "PRIVATE-BODY", count: 100_000))
    let large = try f.inventory(); #expect(large.skills.map(\.name) == ["large", "linked"])
    #expect(!String(reflecting: large).contains("PRIVATE-BODY"))
}

@Test(arguments: ["$", "€", "£", "¥", "₹", "₩", "₿", "𑿝"])
func claudeSkillDispatchMatchesPinnedCurrencyGrammarAndPreservesTheFullAuthoredRequest(symbol: String) throws {
    let skills = [ProviderSkill(name: "review", path: "/owned/review/SKILL.md", userInvocationOnly: true),
        ProviderSkill(name: "implement", path: "/owned/implement/SKILL.md", userInvocationOnly: true)]
    let prompt = "  \(symbol)review then \(symbol)review then \(symbol)implement 工作\n  "
    let planned = try ClaudeSkillDispatch.plan(text: prompt, skills: skills)
    let value = try #require(planned)
    #expect(value.leadingText == "  /review [The user invoked this skill. Follow the instructions at: /owned/review/SKILL.md] then /review then /implement 工作")
    #expect(value.commandText == "/implement 工作" && value.skillName == "implement")
    #expect(try ClaudeSkillDispatch.plan(text: "5\(symbol)review \(symbol)20k \(symbol)100M \(symbol)1e6 \(symbol)unknown", skills: skills) == nil)
    #expect(try ClaudeSkillDispatch.plan(text: "\(symbol)review\nfocus on auth", skills: skills)?.leadingText == nil)
    #expect(prompt.hasSuffix("\n  "))
}

@Test func claudeSkillDispatchKeepsHistoricalContextImagesAndTheFinalNativeCommandSeparateFromAuthoredText() throws {
    let transfer = UUID(), text = "$review exact authored e\u{301}\n"
    let selection = try ContextHandoffService.select(messages: [.init(id: "archive", role: "assistant", kind: "text", text: "Historical context")],
        coverage: .init(transferID: transfer, sourceThreadID: UUID(), strategy: "portableContext"))
    let input = ProviderInput(text: text, images: [.init(mimeType: "image/png", data: Data([1, 2, 3]))], historicalContext: .init(deliveryID: UUID(), transferIDs: [transfer], selection: selection))
    let plan = try ClaudeSkillDispatch.plan(text: input.text, skills: [.init(name: "review", path: "/owned/review/SKILL.md")])
    let wire = try ClaudeSkillDispatch.content(input: input, plan: plan)
    #expect(wire.array?.first?["text"] == .string(selection.renderedText))
    #expect(wire.array?.last?["text"] == .string("/review exact authored e\u{301}"))
    #expect(wire.array?.contains { $0["type"] == .string("image") } == true)
    #expect(input.text == text && input.historicalContext?.selection == selection)
    #expect(try ClaudeSkillDispatch.content(input: .init(text: "/native   exact\n "), plan: nil) == .string("/native   exact\n "))
}

@Test(.timeLimit(.minutes(1))) func claudeSkillStdioOpeningUsesActualFinalCommandWireAndPreservesAuthoredContextAndImages() async throws {
    let f = try ClaudeSkillsFixture(); defer { f.close() }
    try f.skill(f.home.path + "/skills", "review")
    let peer = try #require(Bundle.module.url(forResource: "claude_skills", withExtension: "py", subdirectory: "Fixtures"))
    let runtime = ClaudeRuntimeConfiguration(executable: "/usr/bin/python3", configurationDirectory: f.home.path, workspacePath: f.workspace.path,
        configurationDirectorySelection: .explicitDirectory(environmentPath: f.home.path))
    let physicalWorkspace = try ClaudeRuntimeValidation.physical(f.workspace.path, allowMissing: false)
    let physicalConfiguration = try ClaudeRuntimeValidation.configurationDirectory(runtime.configurationDirectorySelection)
    #expect(physicalWorkspace == runtime.workspacePath && physicalConfiguration == runtime.configurationDirectory)
    let session = try ClaudeSession(executable: URL(fileURLWithPath: runtime.executable), cwd: f.workspace,
        arguments: [peer.path, f.root.path], configuration: runtime)
    let observed = Task {
        var assistant: [String] = [], evidence: ClaudeRunHistoryEvidence?
        for await event in session.events {
            switch event {
            case .context(_, let inner):
                switch inner { case .message(let message) where message.role == .assistant: assistant.append(message.text)
                case .claudeHistoryEvidence(let value): evidence = value
                case .completed: return (assistant, evidence)
                case .failure(let error): throw CoincideError(error)
                default: break }
            default: break
            }
        }
        throw CoincideError("The private skill peer ended before completion")
    }
    do {
        var thread = CodingThread(project: .init(path: f.workspace.path)); thread.provider = .claude; thread.claudeRuntimeConfiguration = runtime
        let run = ActiveRun(id: UUID(), configuration: .init(thread: thread), startedAt: Date()); thread.activeRun = run
        let transfer = UUID(), selection = try ContextHandoffService.select(messages: [.init(id: "old", role: "assistant", kind: "text", text: "Historical context")],
            coverage: .init(transferID: transfer, sourceThreadID: UUID(), strategy: "portableContext"))
        let image = ProviderImage(mimeType: "image/png", data: Data([1, 2, 3]))
        let literal = "Please $review exact authored 工作 e\u{301}\n  "
        let input = ProviderInput(text: literal, images: [image], historicalContext: .init(deliveryID: UUID(), transferIDs: [transfer], selection: selection))
        try await session.send(input: input, thread: thread)
        let result = try await observed.value
        #expect(result.0 == ["Offline skill completed"])
        #expect(result.1?.observedInputIDs == [ClaudeInputIdentity.opening(runID: run.id)])
        let frames = try Data(contentsOf: f.root.appendingPathComponent("skills-wire.jsonl")).split(separator: 10).map { try JSONDecoder().decode(JSONValue.self, from: Data($0)) }
        let user = try #require(frames.first { $0["type"] == .string("user") }), blocks = try #require(user["message"]["content"].array)
        #expect(user["uuid"] == .string(ClaudeInputIdentity.opening(runID: run.id)))
        #expect(blocks.first?["text"] == .string(selection.renderedText) && blocks.last?["text"] == .string("/review exact authored 工作 e\u{301}"))
        #expect(blocks.contains { $0["type"] == .string("image") && $0["source"]["data"] == .string(image.data.base64EncodedString()) })
        #expect(blocks.contains { $0["text"] == .string("Please /review exact authored 工作 e\u{301}") })
        #expect(input.text == literal && input.images == [image] && input.historicalContext?.selection == selection)
        await session.close()
    } catch { observed.cancel(); await session.close(); _ = await observed.result; throw error }
}
