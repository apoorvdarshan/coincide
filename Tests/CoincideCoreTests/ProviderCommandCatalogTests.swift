import Foundation
import Testing
@testable import CoincideCore

private func piCommandRow(_ name: String, source: String = "extension", extra: [String: JSONValue] = [:]) -> JSONValue {
    .object(["name": .string(name), "source": .string(source)].merging(extra) { _, new in new })
}
private func commandSkillRow(_ name: String, id: String? = nil, extra: [String: JSONValue] = [:]) -> JSONValue {
    var fields: [String: JSONValue] = ["name": .string(name), "location": .string("native/legacy/SKILL.md"), "path": .string("native/v2/SKILL.md")]
    if let id { fields["id"] = .string(id) }
    return .object(fields.merging(extra) { _, new in new })
}

@Test func providerPiCommandsSeparateNativeTemplatesSkillsAndBuiltinWithoutRetainingPrivatePayloads() throws {
    let payload: JSONValue = .object(["commands": .array([
        piCommandRow("review", extra: ["description": .string("Review this workspace"), "template": .string("private-template-canary")]),
        piCommandRow("brief", source: "prompt", extra: ["content": .string("private-prompt-canary")]),
        piCommandRow("compact", source: "extension", extra: ["description": .string("Must not replace native builtin")]),
        piCommandRow("skill:ship", source: "skill", extra: [
            "sourceInfo": .object(["path": .string("relative/SKILL.md"), "scope": .string("personal"), "displayName": .string("Publish review 工作")]),
            "interface": .object(["displayName": .string("Lower priority"), "shortDescription": .string("Safe release inspection")]),
            "content": .string("private-skill-body-canary")]),
        piCommandRow("hidden", extra: ["enabled": .bool(false)]),
        piCommandRow("skill:agent-only", source: "skill", extra: ["userInvocable": .bool(false)]),
        piCommandRow("invalid", extra: ["enabled": .string("true")]),
        piCommandRow("unknown-source", source: "future-kind")
    ])])
    let inventory = try ProviderCommandCatalog.pi(payload, cwd: "/private-fixture/工作")
    #expect(inventory.commands.map(\.name) == ["compact", "review", "brief", "hidden"])
    #expect(inventory.commands.filter(\.canInvokeFromComposer).map(\.name) == ["compact", "review", "brief"])
    #expect(inventory.commands[0].source == "builtin" && inventory.commands[0].hints == ["Optional instructions"])
    let skill = try #require(inventory.skills.first)
    #expect(skill.name == "ship" && skill.nativeID == "skill:ship" && skill.promptToken == "$ship")
    #expect(skill.path == "relative/SKILL.md" && skill.scope == "user" && skill.displayName == "Publish review 工作")
    #expect(skill.shortDescription == "Safe release inspection")
    #expect(inventory.skills.last?.canInvokeFromComposer == false)
    #expect(inventory.isPartial && inventory.problems.count == 2)
    for canary in ["private-template-canary", "private-prompt-canary", "private-skill-body-canary"] {
        #expect(!String(reflecting: inventory).contains(canary))
    }
}

@Test(arguments: [OpenCodeGeneration.v1, .v2])
func providerOpenCodeCatalogKeepsExactInvocationIdentityAndDistinctFriendlyNames(generation: OpenCodeGeneration) throws {
    let rows = generation == .v2
        ? [commandSkillRow("Same Friendly Label", id: "native-first"), commandSkillRow("Same Friendly Label", id: "native-second")]
        : [commandSkillRow("native-first"), commandSkillRow("native-second")]
    let inventory = try ProviderCommandCatalog.openCode(commands: .array([
        .object(["name": .string("inspect"), "description": .string("Inspect changes"), "hints": .array([.string("Optional instructions")]),
                 "template": .string("private-command-template-canary")]),
        .object(["name": .string("disabled"), "enabled": .bool(false)]),
        .object(["name": .string("agent-only"), "userInvocable": .bool(false)])
    ]), skills: .array(rows), generation: generation, cwd: "/fixture/workspace")
    #expect(inventory.commands.filter(\.canInvokeFromComposer).map(\.promptToken) == ["/compact", "/inspect"])
    #expect(inventory.skills.map(\.name) == ["native-first", "native-second"])
    #expect(inventory.skills.map(\.nativeID) == ["native-first", "native-second"])
    #expect(inventory.skills.map(\.promptToken) == ["$native-first", "$native-second"])
    if generation == .v2 {
        #expect(inventory.skills.allSatisfy { $0.displayName == "Same Friendly Label" && $0.path == "native/v2/SKILL.md" })
    } else { #expect(inventory.skills.allSatisfy { $0.displayName == nil && $0.path == "native/legacy/SKILL.md" }) }
    #expect(!String(reflecting: inventory).contains("private-command-template-canary"))
    #expect(!inventory.isPartial)
}

@Test func providerCommandConflictsAreOmittedRatherThanSelectedFirstAndEveryMentionSpellingIsRefused() throws {
    let duplicate = piCommandRow("same", extra: ["description": .string("Identical row")])
    let inventory = try ProviderCommandCatalog.pi(.object(["commands": .array([
        duplicate, duplicate,
        piCommandRow("review", extra: ["description": .string("First native command")]),
        piCommandRow("REVIEW", extra: ["description": .string("Conflicting native command")]),
        piCommandRow("skill:shared", source: "skill", extra: ["path": .string("first/SKILL.md")]),
        piCommandRow("skill:SHARED", source: "skill", extra: ["path": .string("second/SKILL.md")])
    ])]), cwd: "/fixture/workspace")
    #expect(inventory.commands.map(\.name) == ["compact", "same"] && inventory.skills.isEmpty)
    #expect(inventory.problems.count == 2)
    #expect(inventory.problems.contains { $0.component == .commands } && inventory.problems.contains { $0.component == .skills })
    for text in ["$shared", "$SHARED"] {
        #expect(throws: ProviderCommandError(.invalidResponse)) { try ProviderCommandCatalog.skillIDs(in: text, inventory: inventory) }
    }
    for text in ["/review", "/REVIEW"] {
        #expect(throws: ProviderCommandError(.invalidResponse)) { try ProviderCommandCatalog.selection(in: text, inventory: inventory) }
    }
}

@Test func providerNativeSkillResolutionPreservesFirstMentionOrderLiteralGrammarAndDisabledRefusal() throws {
    let inventory = try ProviderCommandCatalog.openCode(commands: .array([]), skills: .array([
        commandSkillRow("Friendly A", id: "native-a"), commandSkillRow("Friendly B", id: "native-b"),
        commandSkillRow("Hidden", id: "disabled", extra: ["enabled": .bool(false)]),
        commandSkillRow("Agent", id: "agent-only", extra: ["userInvocable": .bool(false)])
    ]), generation: .v2, cwd: "/fixture/workspace")
    #expect(try ProviderCommandCatalog.skillIDs(in: "$native-b $native-a $native-b", inventory: inventory) == ["native-b", "native-a"])
    #expect(try ProviderCommandCatalog.skillIDs(in: "$Friendly A $unknown cost $2k $2e3", inventory: inventory).isEmpty)
    #expect(try ProviderCommandCatalog.skillMentions("😀 $native-a\n€native-b $native-a $2spec $2k path/$native-a") == ["native-a", "native-b", "2spec"])
    for text in ["$disabled", "$agent-only"] {
        #expect(throws: ProviderCommandError(.invalidResponse)) { try ProviderCommandCatalog.skillIDs(in: text, inventory: inventory) }
    }
}

@Test func providerCatalogRefusesGlobalBoundsWhileRetainingHealthyRowsBesideMalformedMetadata() throws {
    let partial = try ProviderCommandCatalog.openCode(commands: .array([
        .object(["name": .string("healthy")]), .object(["name": .string("bad-hints"), "hints": .array([.bool(true)])]),
        .object(["name": .number(1)]), .object(["name": .string("oversized-description"), "description": .string(String(repeating: "x", count: 16_385))])
    ]), skills: .array([commandSkillRow("Healthy", id: "healthy-skill"), .object(["name": .string("Missing ID")])]),
        generation: .v2, cwd: "/fixture/workspace")
    #expect(partial.commands.map(\.name) == ["compact", "healthy"] && partial.skills.map(\.name) == ["healthy-skill"])
    #expect(partial.problems.count == 4 && partial.isPartial)
    for payload: JSONValue in [.null, .object(["commands": .object([:])]), .object(["commands": .array(Array(repeating: piCommandRow("row"), count: 4_001))]),
                               .object(["commands": .array([]), "ignored": .string(String(repeating: "x", count: 4_194_305))]),
                               .object(["commands": .array(Array(repeating: .null, count: 257))])] {
        #expect(throws: ProviderCommandError(.invalidResponse)) { try ProviderCommandCatalog.pi(payload, cwd: "/fixture/workspace") }
    }
    #expect(throws: ProviderCommandError(.invalidResponse)) {
        try ProviderCommandCatalog.openCode(commands: .array(Array(repeating: .object(["name": .string("same")]), count: 2_001)), skills: nil,
            generation: .v1, cwd: "/fixture/workspace")
    }
    #expect(throws: ProviderCommandError(.invalidResponse)) { try ProviderCommandCatalog.skillMentions(String(repeating: "x", count: 4_194_305)) }
    #expect(throws: ProviderCommandError(.invalidResponse)) { try ProviderCommandCatalog.skillMentions((0...256).map { "$skill-\($0)" }.joined(separator: " ")) }
}

@Test func providerOpenCodeV1SkillsRequireOneLeadingAdvertisedNativeSkillCommandAndKeepOrdinaryProseLiteral() throws {
    let inventory = try ProviderCommandCatalog.openCode(commands: .array([
        .object(["name": .string("review"), "source": .string("command")]),
        .object(["name": .string("skill-a"), "source": .string("skill")]),
        .object(["name": .string("skill-b"), "source": .string("skill")]),
        .object(["name": .string("wrong-source"), "source": .string("command")]),
        .object(["name": .string("disabled"), "enabled": .bool(false)])
    ]), skills: .array([commandSkillRow("skill-a"), commandSkillRow("skill-b"), commandSkillRow("missing-command"), commandSkillRow("wrong-source")]),
        generation: .v1, cwd: "/fixture/workspace")
    let expectedCommand = try ProviderCommandSelection(name: "review", arguments: "literal 工作\nمرحبا")
    #expect(try ProviderCommandCatalog.v1Selection(in: "/review literal 工作\nمرحبا", inventory: inventory) == expectedCommand)
    let expectedSkill = try ProviderCommandSelection(name: "skill-a", arguments: "focus 工作")
    for text in ["$skill-a focus 工作", "$skill-a\nfocus 工作", "$skill-a\tfocus 工作"] {
        #expect(try ProviderCommandCatalog.v1Selection(in: text, inventory: inventory) == expectedSkill)
    }
    for text in ["Please use $skill-a now", "$skill-a $skill-b", "$skill-a $skill-a args", "$missing-command focus", "$wrong-source focus", "/disabled"] {
        #expect(throws: ProviderCommandError(.unsupported)) { try ProviderCommandCatalog.v1Selection(in: text, inventory: inventory) }
    }
    for text in ["$HOME remains literal", "Cost $2k and $2e3", "Ordinary $unknown prose", "not a /review command", "/unknown args"] {
        #expect(try ProviderCommandCatalog.v1Selection(in: text, inventory: inventory) == nil)
    }
}

@Test func providerPartialCatalogCannotConvertPotentialNativeInvocationsIntoOrdinaryPrompts() throws {
    let commands: JSONValue = .array([.object(["name": .string("review"), "source": .string("command")])])
    let skills: JSONValue = .array([commandSkillRow("Friendly Skill", id: "native-skill")])
    let healthy = try ProviderCommandCatalog.openCode(commands: commands, skills: skills,
        generation: .v2, cwd: "/fixture/workspace")
    let missingCommands = try ProviderCommandCatalog.openCode(commands: nil, skills: skills,
        generation: .v2, cwd: "/fixture/workspace",
        problems: [.init(component: .commands, message: "Command metadata is unavailable.")])
    let missingSkills = try ProviderCommandCatalog.openCode(commands: commands, skills: nil,
        generation: .v2, cwd: "/fixture/workspace",
        problems: [.init(component: .skills, message: "Skill metadata is unavailable.")])
    for text in ["/review literal 工作", "/unknown args"] {
        #expect(throws: ProviderCommandError(.unavailable)) { try ProviderCommandCatalog.selection(in: text, inventory: missingCommands) }
        #expect(throws: ProviderCommandError(.unavailable)) { try ProviderCommandCatalog.v1Selection(in: text, inventory: missingCommands) }
    }
    for text in ["$native-skill focus", "Use $unknown with care"] {
        #expect(throws: ProviderCommandError(.unavailable)) { try ProviderCommandCatalog.skillIDs(in: text, inventory: missingSkills) }
        #expect(throws: ProviderCommandError(.unavailable)) { try ProviderCommandCatalog.v1Selection(in: text, inventory: missingSkills) }
    }
    #expect(try ProviderCommandCatalog.skillIDs(in: "$native-skill", inventory: missingCommands) == ["native-skill"])
    #expect(try ProviderCommandCatalog.selection(in: "/review args", inventory: missingSkills)?.arguments == "args")
    #expect(try ProviderCommandCatalog.selection(in: "/unknown args", inventory: healthy) == nil)
    #expect(try ProviderCommandCatalog.skillIDs(in: "Ordinary $unknown prose and cost $2k", inventory: healthy).isEmpty)
    #expect(try ProviderCommandCatalog.selection(in: "ordinary prose", inventory: missingCommands) == nil)
    #expect(try ProviderCommandCatalog.skillIDs(in: "ordinary prose", inventory: missingSkills).isEmpty)
}

private actor NoCommandDiscoverySession: ProviderSession {
    nonisolated let events = AsyncStream<ProviderEvent> { $0.finish() }
    func models() -> [ProviderModel] { [] }
    func send(text: String, thread: CodingThread) {}
    func interrupt() {}
    func respond(_ request: ApprovalRequest, allow: Bool) {}
    func answer(_ request: ApprovalRequest, answers: [String: String]) {}
    func close() {}
}
@Test func providerCommandUnsupportedDefaultIsNotAnAvailableEmptyNativeInventory() async throws {
    let session: any ProviderSession = NoCommandDiscoverySession()
    await #expect(throws: ProviderCommandError(.unsupported)) { try await session.providerCommands(forceReload: true) }
    let inventory = try ProviderCommandCatalog.openCode(commands: .array([]), skills: .array([]), generation: .v2, cwd: "/fixture/workspace")
    #expect(inventory.commands.map(\.name) == ["compact"] && inventory.commands.first?.source == "builtin")
    #expect(inventory.skills.isEmpty && !inventory.isPartial)
    await session.close()
}
