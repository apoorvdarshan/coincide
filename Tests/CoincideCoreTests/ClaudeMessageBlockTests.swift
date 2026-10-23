import Foundation
import Testing
@testable import CoincideCore

private func textBlock(_ text: String) -> JSONValue { .object(["type": .string("text"), "text": .string(text)]) }

@Test func claudeBlockReconciliationPreservesNativeIndicesAndIdenticalSeparateSnapshots() throws {
    var blocks = ClaudeMessageBlocks()
    try blocks.start(messageID: "api", parent: nil)
    #expect(try blocks.stream(index: .number(0), kind: "thinking", parent: nil) == "api-0")
    #expect(try blocks.stream(index: .number(1), kind: "text", parent: nil) == "api-1")
    #expect(try blocks.final(messageID: "api", content: [textBlock("same")], envelopeID: "first", parent: nil) == ["api-1"])
    #expect(try blocks.final(messageID: "api", content: [textBlock("same")], envelopeID: "first", parent: nil) == nil)
    #expect(try blocks.stream(index: .number(1), kind: "text", parent: nil) == nil)
    #expect(try blocks.stream(index: .number(2), kind: "text", parent: nil) == "api-2")
    #expect(try blocks.final(messageID: "api", content: [textBlock("same")], envelopeID: nil, parent: nil) == ["api-2"])
    // No stream/UUID is available: two equal per-block snapshots are two blocks.
    #expect(try blocks.final(messageID: "unstreamed", content: [textBlock("same")], envelopeID: nil, parent: nil) == ["unstreamed-0"])
    #expect(try blocks.final(messageID: "unstreamed", content: [textBlock("same")], envelopeID: nil, parent: nil) == ["unstreamed-1"])
    let thinking: JSONValue = .object(["type": .string("thinking"), "thinking": .string("reason")])
    #expect(try blocks.final(messageID: "api", content: [thinking, textBlock("same"), textBlock("same")], envelopeID: "aggregate", parent: nil) == ["api-0", "api-1", "api-2"])
}

@Test func claudeBlockReconciliationIsolatesInterleavedChildrenAndToolIdentities() throws {
    var blocks = ClaudeMessageBlocks()
    try blocks.start(messageID: "api", parent: nil)
    let root = try blocks.stream(index: .number(0), kind: "text", parent: nil)
    #expect(try blocks.stream(index: .number(0), kind: "text", parent: "orphan") == nil)
    try blocks.start(messageID: "api", parent: "child")
    let child = try blocks.stream(index: .number(0), kind: "text", parent: "child")
    #expect(root != child)
    #expect(try blocks.stream(index: .number(0), kind: "text", parent: nil) == root)
    #expect(try blocks.final(messageID: "api", content: [textBlock("child")], envelopeID: "same-uuid", parent: "child") == [child!])
    #expect(try blocks.final(messageID: "api", content: [textBlock("root")], envelopeID: "same-uuid", parent: nil) == [root!])
    #expect(try blocks.stream(index: .number(1), kind: "tool_use", toolID: "native-tool", parent: nil) == "native-tool")
    let tool: JSONValue = .object(["type": .string("tool_use"), "id": .string("native-tool")])
    #expect(try blocks.final(messageID: "api", content: [tool], envelopeID: nil, parent: nil) == ["native-tool"])
    try blocks.start(messageID: "background", parent: "background-child")
    let background = try blocks.stream(index: .number(1), kind: "text", parent: "background-child")
    blocks.stop(parent: "child")
    #expect(try blocks.stream(index: .number(1), kind: "text", parent: "child") == nil)
    blocks.beginTurn()
    #expect(try blocks.stream(index: .number(1), kind: "text", parent: "background-child") == background)
    #expect(try blocks.stream(index: .number(0), kind: "text", parent: nil) == nil)
    try blocks.start(messageID: "api", parent: nil)
    #expect(try blocks.stream(index: .number(0), kind: "text", parent: nil) == root)
}

@Test func claudeBlockReconciliationRejectsMalformedAndExcessiveIdentities() throws {
    var blocks = ClaudeMessageBlocks()
    try blocks.start(messageID: "api", parent: nil)
    for index in [JSONValue.number(-1), .number(0.5), .number(.infinity), .number(1e100), .null] {
        #expect(throws: CoincideError.self) { try blocks.stream(index: index, kind: "text", parent: nil) }
    }
    _ = try blocks.stream(index: .number(0), kind: "thinking", parent: nil)
    #expect(throws: CoincideError.self) { try blocks.stream(index: .number(0), kind: "text", parent: nil) }
    for index in 1..<ClaudeMessageBlocks.maximumBlocks {
        _ = try blocks.stream(index: .number(Double(index)), kind: "text", parent: nil)
    }
    #expect(throws: CoincideError.self) {
        try blocks.stream(index: .number(Double(ClaudeMessageBlocks.maximumBlocks)), kind: "text", parent: nil)
    }
    #expect(throws: CoincideError.self) { try blocks.start(messageID: "", parent: nil) }
    blocks = ClaudeMessageBlocks()
    for index in 0..<ClaudeMessageBlocks.maximumMessages { try blocks.start(messageID: "message-\(index)", parent: nil) }
    #expect(throws: CoincideError.self) { try blocks.start(messageID: "over-limit", parent: nil) }
}

@Test(.timeLimit(.minutes(1))) func claudeStreamAndPerBlockFinalsProduceOneDurableAnswerAcrossRepeatedTurns() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-claude-blocks-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: root) }
    let peer = try #require(Bundle.module.url(forResource: "claude_message_blocks", withExtension: "py", subdirectory: "Fixtures"))
    let databaseURL = root.appendingPathComponent("workspace.sqlite"), project = WorkspaceProject(path: root.path)
    var thread = CodingThread(project: project); thread.provider = .claude; thread.checkpointPolicy = .disabled
    let engine = try WorkspaceEngine(url: databaseURL, appMCPEnabled: false, providerFactory: { _ in
        try ClaudeSession(executable: URL(fileURLWithPath: "/usr/bin/python3"), cwd: root, arguments: [peer.path])
    }, identityResolver: { _ in nil })
    do {
        _ = try await engine.load()
        _ = try await engine.dispatch(.addProjectWithThread(project: project, thread: thread))
        for turn in 1...2 {
            let receipt = try await engine.dispatch(.submit(threadID: thread.id, text: "Explicit turn \(turn)"))
            #expect(receipt.rejection == nil)
            let deadline = ContinuousClock.now + .seconds(10)
            while true {
                let current = try #require(await engine.current().snapshot.threads.first { $0.id == thread.id })
                if current.activeRun == nil, current.runHistory?.count == turn {
                    #expect(current.runHistory?.last?.status == .completed)
                    break
                }
                if ContinuousClock.now >= deadline { throw CoincideError("The Claude block peer did not complete.") }
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        let finished = try #require(await engine.current().snapshot.threads.first { $0.id == thread.id })
        try expectClaudeBlockRows(finished)
        await engine.shutdown()
        let database = try WorkspaceDatabase(url: databaseURL)
        let rebuilt = try await database.rebuildProjection().snapshot
        try WorkspaceJournal.validate(rebuilt)
        try expectClaudeBlockRows(#require(rebuilt.threads.first { $0.id == thread.id }))
        let reopened = try WorkspaceEngine(url: databaseURL, appMCPEnabled: false,
            providerFactory: { _ in throw CoincideError("Reopening completed blocks must not start Claude.") }, identityResolver: { _ in nil })
        do {
            let restored = try await reopened.load()
            try expectClaudeBlockRows(#require(restored.threads.first { $0.id == thread.id }))
            await reopened.shutdown()
        } catch { await reopened.shutdown(); throw error }
    } catch { await engine.shutdown(); throw error }
}

private func expectClaudeBlockRows(_ thread: CodingThread) throws {
    #expect(thread.activeRun == nil && thread.runHistory?.count == 2)
    #expect(thread.messages.filter { $0.role == .assistant }.count == 10)
    #expect(thread.messages.filter { $0.role == .reasoning }.count == 2)
    #expect(thread.messages.filter { $0.role == .tool }.count == 2)
    for turn in 1...2 {
        let prefix = "api-message-\(turn)"
        let answer = try #require(thread.messages.first { $0.id == prefix + "-1" })
        #expect(answer.role == .assistant && answer.text == "answer body")
        #expect(thread.messages.filter { $0.role == .assistant && $0.text == "answer body" && $0.runReference == answer.runReference }.count == 1)
        #expect(thread.messages.first { $0.id == prefix + "-0" }?.role == .reasoning)
        #expect(thread.messages.first { $0.id == prefix + "-0" }?.text == "reasoning")
        #expect(thread.messages.first { $0.id == prefix + "-3" }?.text == "same")
        #expect(thread.messages.first { $0.id == prefix + "-4" }?.text == "same")
        #expect(thread.messages.first { $0.id == "native-tool-\(turn)" }?.text.contains("Read") == true)
        #expect(thread.messages.filter { $0.role == .assistant && ["Child A", "Child B"].contains($0.text) && $0.runReference == answer.runReference }.count == 2)
    }
}
