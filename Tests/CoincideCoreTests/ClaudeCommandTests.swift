import Foundation
import Testing
@testable import CoincideCore

private func nativeClaudeCommand(_ name: String, description: String = "Advertised metadata", aliases: [String] = []) -> JSONValue {
    .object(["name": .string(name), "description": .string(description), "argumentHint": .string("<focus>"),
        "aliases": .array(aliases.map(JSONValue.string)), "content": .string("private-body-must-not-be-retained"),
        "path": .string("untrusted-path-must-not-be-inferred")])
}

@Test func claudeCommandCatalogUsesOnlyNativeMetadataAndKeepsAliasesAndHints() throws {
    let inventory = try ClaudeCommands.inventory(.array([nativeClaudeCommand("plugin:review", aliases: ["pr"])]), cwd: "/fixture")
    #expect(inventory.commands.map(\.promptToken) == ["/plugin:review", "/pr"])
    #expect(inventory.commands.allSatisfy { $0.source == "native" && $0.hints == ["<focus>"] })
    #expect(inventory.skills.isEmpty && !inventory.isPartial)
    #expect(!String(reflecting: inventory).contains("private-body-must-not-be-retained"))
    #expect(!String(reflecting: inventory).contains("untrusted-path-must-not-be-inferred"))
    let empty = try ClaudeCommands.inventory(.array([]), cwd: "/fixture")
    #expect(empty.commands.isEmpty && empty.skills.isEmpty)
}

@Test func claudeCommandCatalogOmitsAmbiguousOrMalformedRowsAndRejectsBounds() throws {
    let inventory = try ClaudeCommands.inventory(.array([
        nativeClaudeCommand("healthy"), nativeClaudeCommand("healthy"), nativeClaudeCommand("first", aliases: ["shared"]),
        nativeClaudeCommand("SHARED", description: "Conflicting owner"), nativeClaudeCommand("bad name"),
        .object(["name": .string("missing-metadata")])
    ]), cwd: "/fixture")
    #expect(inventory.commands.map(\.name) == ["healthy", "first"])
    #expect(inventory.problems.count == 3 && inventory.isPartial)
    #expect(inventory.problems.contains { $0.name == "SHARED" })
    for value in [JSONValue.null, .object([:]), .array(Array(repeating: nativeClaudeCommand("same"), count: 2_001))] {
        #expect(throws: ProviderCommandError(.invalidResponse)) { try ClaudeCommands.inventory(value, cwd: "/fixture") }
    }
}

@Test(.timeLimit(.minutes(1)), arguments: ["literal", "changed", "empty", "malformed", "unsupported", "foreign"])
func claudeCommandsReadNativeInitializeAndChangesWithoutSubmittingOrReloading(scenario: String) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-claude-commands-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: root) }
    let peer = try #require(Bundle.module.url(forResource: "claude_commands", withExtension: "py", subdirectory: "Fixtures"))
    let session = try ClaudeSession(executable: URL(fileURLWithPath: "/usr/bin/python3"), cwd: root,
        arguments: [peer.path, scenario, root.path])
    do {
        if scenario == "unsupported" || scenario == "malformed" {
            await #expect(throws: ProviderCommandError(scenario == "unsupported" ? .unsupported : .invalidResponse)) {
                try await session.providerCommands(forceReload: true)
            }
        } else {
            let inventory = try await session.providerCommands(forceReload: true)
            #expect(inventory.cwd == root.path && inventory.skills.isEmpty)
            #expect(inventory.commands.map(\.name) == (scenario == "changed" ? ["replacement"] : scenario == "empty" ? [] : ["demo:review", "dr"]))
        }
        let before = try commandWire(root)
        #expect(before.count == 1 && before[0]["request"]["subtype"] == .string("initialize"))
        if scenario == "literal" {
            let observed = Task {
                var replies: [String] = []
                for await event in session.events {
                    switch event {
                    case .message(let value) where value.role == .assistant: replies.append(value.text)
                    case .completed: return replies
                    case .failure(let message): throw CoincideError(message)
                    default: break
                    }
                }
                throw CoincideError("The native command fixture ended before completion.")
            }
            var thread = CodingThread(project: WorkspaceProject(path: root.path)); thread.provider = .claude
            try await session.send(text: "/demo:review  literal 工作\n/other remains arguments\n$HOME untouched ", thread: thread)
            #expect(try await observed.value == ["Command completed"])
            let after = try commandWire(root)
            #expect(after.filter { $0["type"] == .string("user") }.count == 1)
            #expect(after.filter { $0["type"] == .string("control_request") }.map { $0["request"]["subtype"].string } == ["initialize", "set_permission_mode", "set_model"])
        }
        await session.close()
    } catch { await session.close(); throw error }
}

private func commandWire(_ root: URL) throws -> [JSONValue] {
    try Data(contentsOf: root.appendingPathComponent("wire.jsonl")).split(separator: 10).map {
        try JSONDecoder().decode(JSONValue.self, from: Data($0))
    }
}
