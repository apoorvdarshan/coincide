import Foundation
import Testing
@testable import CoincideCore

/// Explicit opt-in: two small model turns per installed provider, using its
/// existing CLI login. All app tools address a newly generated private database;
/// no sign-in, provider configuration or existing conversation is changed.
@Test(.enabled(if: ProcessInfo.processInfo.environment["COINCIDE_LIVE_APP_MCP"] == "1"),
      .timeLimit(.minutes(6)), arguments: [ProviderKind.codex, .claude])
func installedProvidersUseAppMCPThroughNativeEngineAndRetainChangesAcrossRestart(_ kind: ProviderKind) async throws {
    let manager = FileManager.default, testID = UUID()
    let root = manager.temporaryDirectory.appendingPathComponent("coincide-live-app-mcp-" + testID.uuidString)
    try manager.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let workspace = root.appendingPathComponent("generated-workspace")
    try manager.createDirectory(at: workspace, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let sentinel = workspace.appendingPathComponent("untouched.txt")
    let bytes = Data("Generated app-tool acceptance sentinel.\n".utf8)
    try bytes.write(to: sentinel, options: .withoutOverwriting)
    let database = root.appendingPathComponent("workspace.sqlite")
    let project = WorkspaceProject(path: workspace.path)
    var source = CodingThread(project: project)
    source.provider = kind; source.permission = .supervised; source.checkpointPolicy = .disabled
    source.title = "Generated app-tool acceptance"
    if kind == .claude {
        source.claudeRuntimeConfiguration = try ClaudeRuntimeConfiguration.capture(workspacePath: project.path)
    }
    let targetID = source.id.uuidString.lowercased()
    let title = "MCP_" + testID.uuidString.replacingOccurrences(of: "-", with: "")
    let requestID = "live-mcp-" + testID.uuidString.lowercased()
    let draft = "Unsent generated draft " + testID.uuidString
    let engine = try WorkspaceEngine(url: database, appMCPEnabled: true, identityResolver: { _ in nil })
    var restarted: WorkspaceEngine?
    var stage = "load"
    do {
        _ = try await engine.load()
        let added = try await engine.dispatch(.addProjectWithThread(project: project, thread: source))
        guard added.rejection == nil else { throw LiveAppMCPFailure("create-rejected") }
        stage = "rename-turn"
        let firstID = UUID()
        let prompt = """
        This is an isolated Coincide app-tool acceptance test. Use the Coincide MCP tool t3_thread_read to read threadId \(targetID).
        Then call t3_thread_update with action rename, threadId \(targetID), title \(title), and clientRequestId \(requestID).
        Use only those two tools, sequentially. Do not read files, run commands, delegate, use other servers, or change any other state.
        After the rename succeeds, reply with exactly \(title).
        """
        let firstSubmission = try await engine.dispatch(.submit(threadID: source.id, text: prompt), id: firstID)
        guard firstSubmission.rejection == nil else { throw LiveAppMCPFailure("submit-rejected") }
        _ = try await engine.dispatch(.editThread(source.id, .draft(draft)))
        let first = try await liveAppMCPCompleted(engine, threadID: source.id, runID: firstID,
            expectedTitle: title, clientRequestID: requestID)
        guard first.title == title, first.draft == draft,
              liveAppMCPHasTool(first, runID: firstID, name: "t3_thread_read"),
              liveAppMCPHasTool(first, runID: firstID, name: "t3_thread_update"),
              first.messages.contains(where: { $0.role == .assistant && $0.runReference?.runID == firstID && $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == title }),
              let runtimeID = first.runtimeID, first.providerThreadID != nil else {
            throw LiveAppMCPFailure("rename-or-first-answer-mismatch")
        }
        // The model is not given the answer in the second prompt. It must read
        // the actual renamed thread through the same provider runtime.
        stage = "read-successor"
        let secondID = UUID()
        let secondSubmission = try await engine.dispatch(.submit(threadID: source.id,
            text: "Use only the Coincide MCP tool t3_thread_read with threadId \(targetID). Reply with exactly its current title. Do not use other tools or change state."), id: secondID)
        guard secondSubmission.rejection == nil else { throw LiveAppMCPFailure("successor-rejected") }
        _ = try await engine.dispatch(.editThread(source.id, .draft(draft)))
        let second = try await liveAppMCPCompleted(engine, threadID: source.id, runID: secondID,
            expectedTitle: nil, clientRequestID: nil)
        guard second.runtimeID == runtimeID, second.providerThreadID == first.providerThreadID,
              second.title == title, second.draft == draft,
              liveAppMCPHasTool(second, runID: secondID, name: "t3_thread_read"),
              second.messages.contains(where: { $0.role == .assistant && $0.runReference?.runID == secondID && $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == title }) else {
            throw LiveAppMCPFailure("successor-or-runtime-mismatch")
        }
        stage = "durability"
        let store = try WorkspaceDatabase(url: database)
        let journal = try await store.journal(limit: 2_000)
        let encoded = String(decoding: try JSONEncoder().encode(journal), as: UTF8.self)
        guard !encoded.contains("Bearer "), !encoded.contains("authorizationHeader"),
              !encoded.contains("http_headers"), try Data(contentsOf: sentinel) == bytes else {
            throw LiveAppMCPFailure("privacy-or-workspace-mismatch")
        }
        let rebuilt = try await store.rebuildProjection().snapshot
        try WorkspaceJournal.validate(rebuilt)
        guard rebuilt.threads.first(where: { $0.id == source.id })?.title == title else {
            throw LiveAppMCPFailure("rebuild-mismatch")
        }
        await engine.shutdown()
        let reopened = try WorkspaceEngine(url: database, appMCPEnabled: true, identityResolver: { _ in nil })
        restarted = reopened
        let restored = try await reopened.load()
        guard let restoredThread = restored.threads.first(where: { $0.id == source.id }),
              restoredThread.title == title, restoredThread.draft == draft,
              restoredThread.runHistory == second.runHistory,
              restoredThread.activeRun == nil, restoredThread.queuedTurns.isEmpty else {
            throw LiveAppMCPFailure("restart-mismatch")
        }
        await reopened.shutdown()
        // Save only generated identities and pass evidence, never provider
        // response text, account information or ephemeral registration headers.
        let evidence: [String: String] = ["provider": kind.rawValue, "result": "passed",
            "threadID": targetID, "nativeThreadID": second.providerThreadID!,
            "firstRunID": firstID.uuidString, "secondRunID": secondID.uuidString]
        let evidenceURL = manager.temporaryDirectory.appendingPathComponent("coincide-live-app-mcp-evidence-" + testID.uuidString + ".json")
        try JSONSerialization.data(withJSONObject: evidence, options: .sortedKeys).write(to: evidenceURL, options: .withoutOverwriting)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: evidenceURL.path)
        try manager.removeItem(at: root)
    } catch {
        await engine.shutdown(); await restarted?.shutdown()
        // Preserve the generated workspace for diagnosis, without echoing
        // arbitrary provider errors or credentials into test/CI logs.
        throw LiveAppMCPFailure(kind.rawValue + ":" + stage + ":" + ((error as? LiveAppMCPFailure)?.category ?? "operation-failed") + ":" + root.path)
    }
}

private func liveAppMCPCompleted(_ engine: WorkspaceEngine, threadID: UUID, runID: UUID,
                                 expectedTitle: String?, clientRequestID: String?) async throws -> CodingThread {
    let deadline = ContinuousClock.now + .seconds(140)
    while ContinuousClock.now < deadline {
        let update = await engine.current()
        guard update.error == nil, let thread = update.snapshot.threads.first(where: { $0.id == threadID }) else {
            throw LiveAppMCPFailure("engine-failure")
        }
        if let run = thread.runHistory?.first(where: { $0.id == runID }), run.status.isTerminal {
            guard run.status == .completed, thread.activeRun == nil else { throw LiveAppMCPFailure("turn-not-completed") }
            return thread
        }
        for pending in thread.runtimeRequests where !pending.responding {
            let request = pending.request, input = request.params["input"]
            let isRead = request.params["tool_name"] == .string("mcp__coincide__t3_thread_read")
                && input["threadId"] == .string(threadID.uuidString.lowercased())
            let isRename = request.params["tool_name"] == .string("mcp__coincide__t3_thread_update")
                && input["threadId"] == .string(threadID.uuidString.lowercased())
                && input["action"] == .string("rename") && expectedTitle != nil && clientRequestID != nil
                && input["title"] == .string(expectedTitle!) && input["clientRequestId"] == .string(clientRequestID!)
            let codex = request.codexMCPApproval
            let codexInput = codex?.toolArguments ?? .null
            let codexRename = codex?.serverName == "coincide"
                && codex?.message.contains("t3_thread_update") == true
                && codexInput["threadId"] == .string(threadID.uuidString.lowercased())
                && codexInput["action"] == .string("rename") && expectedTitle != nil && clientRequestID != nil
                && codexInput["title"] == .string(expectedTitle!) && codexInput["clientRequestId"] == .string(clientRequestID!)
            guard (request.method == "can_use_tool" && (isRead || isRename)) || codexRename else {
                _ = try? await engine.dispatch(.interrupt(threadID: threadID))
                throw LiveAppMCPFailure("unexpected-tool-or-question")
            }
            let response = try await engine.dispatch(.respond(threadID: threadID, requestID: request.id, response: .decision(true)))
            guard response.rejection == nil else { throw LiveAppMCPFailure("approval-rejected") }
        }
        try await Task.sleep(for: .milliseconds(100))
    }
    _ = try? await engine.dispatch(.interrupt(threadID: threadID))
    throw LiveAppMCPFailure("turn-timeout")
}

private func liveAppMCPHasTool(_ thread: CodingThread, runID: UUID, name: String) -> Bool {
    thread.messages.contains { message in
        guard message.role == .tool, message.runReference?.runID == runID else { return false }
        if thread.provider == .codex {
            return message.providerEntity?.fields["title"] == .string("coincide." + name)
                && message.providerEntity?.fields["status"] == .string("completed")
        }
        return message.text.hasPrefix("mcp__coincide__" + name + "\n")
    }
}

private struct LiveAppMCPFailure: Error, LocalizedError {
    let category: String
    init(_ category: String) { self.category = category }
    var errorDescription: String? { "Live app-tool acceptance: " + category }
}
