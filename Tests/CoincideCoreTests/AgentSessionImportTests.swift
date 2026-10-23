import Darwin
import Foundation
import Testing
@testable import CoincideCore

struct AgentSessionImportFixture {
    let root: URL, workspace: URL, codex: URL, claude: URL
    let profiles: [AgentSessionProfile]
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    static func make() throws -> Self {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-agent-import-" + UUID().uuidString).standardizedFileURL.resolvingSymlinksInPath()
        let workspace = root.appendingPathComponent("Workspace"), codex = root.appendingPathComponent("Codex"), claude = root.appendingPathComponent("Claude")
        for directory in [workspace, codex.appendingPathComponent("sessions/2026/10/23"), claude.appendingPathComponent("projects/encoded-project")] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let project = WorkspaceProject(path: workspace.path); var first = CodingThread(project: project)
        first.codexRuntimeConfiguration = .init(instanceID: UUID(), selection: .custom, executable: root.appendingPathComponent("must-not-run-codex").path, homeDirectory: codex.path)
        var second = CodingThread(project: project); second.provider = .claude
        second.claudeRuntimeConfiguration = .init(instanceID: UUID(), executable: root.appendingPathComponent("must-not-run-claude").path, configurationDirectory: claude.path, workspacePath: workspace.path)
        return .init(root: root, workspace: workspace, codex: codex, claude: claude,
            profiles: [try .init(configuration: .init(thread: first), transcriptsRoot: codex.path), try .init(configuration: .init(thread: second), transcriptsRoot: claude.path)])
    }
    func install(_ source: AgentSessionSource, suffix: String = "") throws -> URL {
        let name = source == .codex ? "agent_session_codex" : "agent_session_claude"
        let fixture = try #require(Bundle.module.url(forResource: name, withExtension: "jsonl", subdirectory: "Fixtures"))
        let text = try String(contentsOf: fixture, encoding: .utf8).replacingOccurrences(of: "__WORKSPACE__", with: workspace.path)
        let file = source == .codex ? codex.appendingPathComponent("sessions/2026/10/23/rollout-fixture\(suffix).jsonl") : claude.appendingPathComponent("projects/encoded-project/22222222-2222-4222-8222-222222222222\(suffix).jsonl")
        try Data(text.utf8).write(to: file); try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-60)], ofItemAtPath: file.path); return file
    }
    func scanner() throws -> AgentSessionScanner { try .init(profiles: profiles, homeDirectory: root.path, now: { now }) }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

@Test(.timeLimit(.minutes(1))) func agentSessionNativeFormatsRetainCanonicalPublicTextAndCapturedProviderOwnership() async throws {
    let f = try AgentSessionImportFixture.make(); defer { f.cleanup() }
    _ = try f.install(.codex); _ = try f.install(.claudeAgent)
    let scanner = try f.scanner()
    do {
        let scan = try await scanner.scan()
        #expect(scan.candidates.count == 1 && scan.candidates[0].threadCount == 2)
        #expect(Set(scan.candidates[0].sources) == Set([.codex, .claudeAgent]))
        let project = UUID(), first = try await scanner.prepareImport(scanID: scan.id, projectID: project, expectedWorkspaceRoot: f.workspace.path)
        let next = try #require(first.nextCursor)
        let second = try await scanner.prepareImport(scanID: scan.id, projectID: project, expectedWorkspaceRoot: f.workspace.path, cursor: next)
        let reviews = first.reviews + second.reviews
        #expect(reviews.count == 2 && second.complete)
        let codex = try #require(reviews.first { $0.profile.source == .codex }), claude = try #require(reviews.first { $0.profile.source == .claudeAgent })
        #expect(codex.transcript.messages.map(\.text) == ["Inspect the captured project", "Public answer one", "A distinct second question", "Public answer two"])
        #expect(codex.transcript.model == "codex-captured-model")
        #expect(claude.transcript.messages.map(\.text) == ["Public Claude request", "Public Claude answer"])
        #expect(claude.transcript.title == "Exact user title" && claude.transcript.model == "claude-captured-model")
        #expect(codex.profile.configuration.codexRuntimeConfiguration == f.profiles[0].configuration.codexRuntimeConfiguration)
        try await scanner.validate(codex); try await scanner.validate(claude)
        #expect(try await scanner.prepareImport(scanID: scan.id, projectID: project, expectedWorkspaceRoot: f.workspace.path) == first)
    } catch { await scanner.close(); throw error }; await scanner.close()
}

@Test func agentSessionStreamingSelectorSkipsOversizedPrivateValuesAndKeepsLastDuplicateKey() throws {
    let selector = AgentSessionJSONSelector(maximumSelectedBytes: 4_096)
    let prefix = #"{"ignored":""#
    for byte in prefix.utf8 { try selector.feed(byte) }
    let block = [UInt8](repeating: 120, count: 8_192)
    for _ in 0..<1_024 { for byte in block { try selector.feed(byte) } }
    for byte in #"","type":"user","cwd":"/first","cwd":"/last","message":{"content":[{"type":"text","text":"Public ✓"},{"type":"image","data":"private"}]}}"#.utf8 { try selector.feed(byte) }
    let row = try #require(try selector.finishLine())
    #expect(row["cwd"] == .string("/last") && row["ignored"] == .null)
    let blocks = try #require(row["message"]["content"].array)
    #expect(blocks[0]["text"] == .string("Public ✓"))
    #expect(blocks[1]["data"] == .null)
    #expect(try AgentSessionImportProtocol.payload(row).count < 512)
    let limited = AgentSessionJSONSelector(maximumSelectedBytes: 512)
    #expect(throws: AgentSessionImportError.limit) { for byte in (#"{"message":{"content":""# + String(repeating: "x", count: 1_024) + #""}}"#).utf8 { try limited.feed(byte) } }
}

@Test(.timeLimit(.minutes(1))) func agentSessionImportRejectsChangedFileRootSymlinkAndWrongCursorWithoutChangingNativeFiles() async throws {
    let f = try AgentSessionImportFixture.make(); defer { f.cleanup() }
    let path = try f.install(.codex), original = try Data(contentsOf: path), scanner = try f.scanner()
    do {
        let scan = try await scanner.scan(), project = UUID()
        let page = try await scanner.prepareImport(scanID: scan.id, projectID: project, expectedWorkspaceRoot: f.workspace.path)
        let review = try #require(page.reviews.first)
        try Data((String(decoding: original, as: UTF8.self) + "\n").utf8).write(to: path)
        await #expect(throws: AgentSessionImportError.changed) { try await scanner.validate(review) }
        try original.write(to: path)
        await #expect(throws: AgentSessionImportError.changed) { try await scanner.validate(review) }
        try FileManager.default.removeItem(at: path)
        try FileManager.default.createSymbolicLink(at: path, withDestinationURL: f.workspace.appendingPathComponent("foreign.jsonl"))
        await #expect(throws: AgentSessionImportError.self) { try await scanner.validate(review) }
        await #expect(throws: AgentSessionImportError.staleScan) { try await scanner.prepareImport(scanID: scan.id, projectID: project, expectedWorkspaceRoot: f.workspace.path, cursor: UUID()) }
        await scanner.release(scanID: scan.id)
        await #expect(throws: AgentSessionImportError.staleScan) { try await scanner.validate(review) }
    } catch { await scanner.close(); throw error }; await scanner.close()
}

@Test func agentSessionImportRetainsFirstRequestAndTailWithoutForgingNativeRunProof() throws {
    let f = try AgentSessionImportFixture.make(); defer { f.cleanup() }
    var rows: [JSONValue] = [.object(["type": .string("session_meta"), "payload": .object(["id": .string("opaque-native-session"), "cwd": .string(f.workspace.path)])])]
    for i in 0..<250 { rows.append(.object(["type": .string("event_msg"), "payload": .object(["type": .string("user_message"), "message": .string("Distinct request \(i)")])])) }
    let transcript = try #require(try AgentSessionTranscriptParser.parse(rows, profile: f.profiles[0], fallbackSessionID: "rollout-filename-is-not-sessionID", lastActive: f.now))
    #expect(transcript.providerSessionID == "opaque-native-session" && transcript.messages.count == 200 && transcript.omittedMessageCount == 50)
    #expect(transcript.messages.first?.text == "Distinct request 0" && transcript.messages.last?.text == "Distinct request 249")
    let encoded = try AgentSessionImportProtocol.payload(transcript)
    #expect(!String(decoding: encoded, as: UTF8.self).contains("runReference"))
    rows[0] = .object(["type": .string("session_meta"), "payload": .object(["id": .string("excluded"), "cwd": .string(f.workspace.path), "source": .object(["subagent": .object([:])])])])
    #expect(try AgentSessionTranscriptParser.parse(rows, profile: f.profiles[0], fallbackSessionID: "not-a-native-ID", lastActive: f.now) == nil)
}

@Test(.timeLimit(.minutes(1))) func agentSessionCatalogReadsGitMetadataWithoutLaunchingGitAndExcludesManagedOrNonBareLinkedWorktrees() async throws {
    let f = try AgentSessionImportFixture.make(); defer { f.cleanup() }
    _ = try f.install(.codex)
    let admin = f.workspace.appendingPathComponent(".git"), common = f.root.appendingPathComponent("GitCommon")
    try FileManager.default.createDirectory(at: admin, withIntermediateDirectories: true)
    try Data("[remote \"backup\"]\nurl = https://example.com/Owner/Backup.git\n[remote \"origin\"]\nurl = git@github.com:Owner/Project.git\n".utf8).write(to: admin.appendingPathComponent("config"))
    let scanner = try f.scanner()
    do {
        let result = try await scanner.scan()
        #expect(result.candidates.first?.git?.remoteKey == "github.com/owner/project")
        #expect(result.candidates.first?.git?.repository == "Owner/Project")
        try Data("[remote \"origin\"]\nurl = https://private-user:private-value@github.com/Owner/Project.git\n".utf8).write(to: admin.appendingPathComponent("config"))
        let secretMetadata = try await scanner.scan()
        #expect(secretMetadata.candidates.first?.git?.remoteKey == nil)
        #expect(!String(decoding: try AgentSessionImportProtocol.payload(secretMetadata), as: UTF8.self).contains("private-value"))
        try FileManager.default.removeItem(at: admin)
        let linked = common.appendingPathComponent("worktrees/linked")
        try FileManager.default.createDirectory(at: linked, withIntermediateDirectories: true)
        try Data("gitdir: \(linked.path)\n".utf8).write(to: admin)
        try Data("../..\n".utf8).write(to: linked.appendingPathComponent("commondir"))
        try Data("[core]\nbare = false\n".utf8).write(to: common.appendingPathComponent("config"))
        #expect(try await scanner.scan().candidates.isEmpty)
        try Data("[core] bare = true\n[remote.origin]\nurl = https://github.com/Owner/Bare.git\n".utf8).write(to: common.appendingPathComponent("config"))
        #expect(try await scanner.scan().candidates.first?.git?.remoteKey == "github.com/owner/bare")
    } catch { await scanner.close(); throw error }; await scanner.close()
    let excluded = try AgentSessionScanner(profiles: f.profiles, homeDirectory: f.root.path, excludingWorkspaceRoots: [f.workspace.path], now: { f.now })
    do { #expect(try await excluded.scan().candidates.isEmpty) } catch { await excluded.close(); throw error }; await excluded.close()
}

@Test func agentSessionScannerCacheChargesCompleteMetadataOnlyPagesAndRefusesAggregateOverflow() throws {
    let scan = UUID(), instance = UUID()
    let sources = (0..<128).map { index in
        AgentSessionImportSource(provider: .codex, providerInstanceID: instance, providerSessionID: "native-\(index)",
            filePath: "/private/" + String(repeating: "escaped-\"-", count: 200) + String(index), size: 100, device: 1, inode: UInt64(index + 1),
            modificationNanoseconds: 1, birthNanoseconds: 1, digest: String(repeating: "a", count: 64), changeNanoseconds: 1)
    }
    let empty = AgentSessionImportPage(scanID: scan, reviews: [], alreadyImported: [], duplicates: [], skippedCount: 0, nextCursor: nil, complete: true)
    let metadata = AgentSessionImportPage(scanID: scan, reviews: [], alreadyImported: sources, duplicates: sources,
        skippedCount: 123, nextCursor: UUID(), complete: false)
    let emptyBytes = try AgentSessionScanner.retainedPageBytes(empty), bytes = try AgentSessionScanner.retainedPageBytes(metadata)
    #expect(metadata.reviews.isEmpty && bytes > 500_000 && bytes > emptyBytes)
    let maximum = 128 * 1_024 * 1_024
    #expect(try AgentSessionScanner.validateRetainedPageCapacity(metadata, existingBytes: maximum - bytes, pageCount: 255) == bytes)
    #expect(throws: AgentSessionImportError.limit) { try AgentSessionScanner.validateRetainedPageCapacity(metadata, existingBytes: maximum - bytes + 1, pageCount: 255) }
    #expect(throws: AgentSessionImportError.limit) { try AgentSessionScanner.validateRetainedPageCapacity(empty, existingBytes: 0, pageCount: 256) }
}
