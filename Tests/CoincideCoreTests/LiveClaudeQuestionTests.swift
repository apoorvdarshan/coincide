import Foundation
import Testing
@testable import CoincideCore

/// Explicit opt-in: one installed-Claude model turn, existing CLI sign-in,
/// generated workspace/database only. Native tools are restricted to questions;
/// hooks, skills and all MCP servers are disabled for this invocation.
@Test(.enabled(if: ProcessInfo.processInfo.environment["COINCIDE_LIVE_CLAUDE_QUESTION"] == "1"), .timeLimit(.minutes(3)))
func installedClaudeQuestionAcceptsNativeSelectionsNotesAndPreservesPrivateWorkspace() async throws {
    let manager = FileManager.default, acceptanceID = UUID()
    let root = manager.temporaryDirectory.appendingPathComponent("coincide-live-claude-question-" + acceptanceID.uuidString)
    try manager.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let workspace = root.appendingPathComponent("generated-workspace")
    try manager.createDirectory(at: workspace, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let sentinel = workspace.appendingPathComponent("untouched.txt"), original = Data("Generated native question acceptance sentinel.\n".utf8)
    try original.write(to: sentinel, options: .withoutOverwriting)
    let runtime = try ClaudeRuntimeConfiguration.capture(workspacePath: workspace.path)
    let arguments = ["--print", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
        "--include-partial-messages", "--permission-prompt-tool", "stdio", "--tools", "AskUserQuestion",
        "--disable-slash-commands", "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}",
        "--settings", "{\"disableAllHooks\":true}"]
    let database = root.appendingPathComponent("workspace.sqlite"), project = WorkspaceProject(path: workspace.path)
    var source = CodingThread(project: project)
    source.provider = .claude; source.permission = .supervised; source.checkpointPolicy = .disabled
    source.claudeRuntimeConfiguration = runtime
    let marker = "QUESTION_" + acceptanceID.uuidString.replacingOccurrences(of: "-", with: "")
    let notes = "Generated native question notes " + acceptanceID.uuidString
    let draft = "Unsent generated question draft " + acceptanceID.uuidString
    let question = "Which verification labels should be returned?"
    let selected = ["Native Alpha", "Native Beta", marker]
    let engine = try WorkspaceEngine(url: database, appMCPEnabled: false, providerFactory: { thread in
        guard thread.provider == .claude, thread.claudeRuntimeConfiguration == runtime else { throw LiveClaudeQuestionFailure("unexpected-runtime") }
        return try ClaudeSession(executable: URL(fileURLWithPath: runtime.executable), cwd: workspace,
            arguments: arguments, configuration: runtime)
    }, identityResolver: { _ in nil })
    var stage = "load"
    do {
        _ = try await engine.load()
        let added = try await engine.dispatch(.addProjectWithThread(project: project, thread: source))
        guard added.rejection == nil else { throw LiveClaudeQuestionFailure("create-rejected") }
        let runID = UUID()
        let prompt = """
        This is an isolated native question acceptance test. Call AskUserQuestion exactly once with exactly this input:
        {"questions":[{"question":"\(question)","header":"Verify","multiSelect":true,"options":[{"label":"Native Alpha","description":"First literal label"},{"label":"Native Beta","description":"Second literal label"}]}]}
        Wait for the user's structured answer. After the tool returns, put exactly the complete answer string for that question on the first line, preserving its punctuation and spaces. Then mention the complete user notes verbatim. Do not put quotes or commentary on the first line. Do not use other tools, read files, run commands or delegate. Do not guess the user's answer or notes.
        """
        stage = "native-question-turn"
        let submitted = try await engine.dispatch(.submit(threadID: source.id, text: prompt), id: runID)
        guard submitted.rejection == nil else { throw LiveClaudeQuestionFailure("submit-rejected") }
        _ = try await engine.dispatch(.editThread(source.id, .draft(draft)))
        let deadline = ContinuousClock.now + .seconds(110)
        var answered = false, finished: CodingThread?
        while ContinuousClock.now < deadline {
            let update = await engine.current()
            guard update.error == nil, let thread = update.snapshot.threads.first(where: { $0.id == source.id }) else {
                throw LiveClaudeQuestionFailure("engine-failure")
            }
            if let record = thread.runHistory?.first(where: { $0.id == runID }), record.status.isTerminal {
                guard record.status == .completed, thread.activeRun == nil, answered else {
                    throw LiveClaudeQuestionFailure(answered ? "turn-not-completed" : "question-not-observed")
                }
                finished = thread; break
            }
            for pending in thread.runtimeRequests where !pending.responding {
                let request = pending.request
                guard !answered, let native = request.claudeQuestion, native.questions.count == 1,
                      let field = native.questions.first, field.question == question, field.multiSelect,
                      field.options.map(\.label) == ["Native Alpha", "Native Beta"] else {
                    _ = try? await engine.dispatch(.respond(threadID: source.id, requestID: request.id, response: .decision(false)))
                    _ = try? await engine.dispatch(.interrupt(threadID: source.id))
                    throw LiveClaudeQuestionFailure("unexpected-tool-or-question")
                }
                let response = try await engine.dispatch(.respond(threadID: source.id, requestID: request.id,
                    response: .selectionsWithNotes(selections: [question: selected], notes: [question: notes])))
                guard response.rejection == nil else { throw LiveClaudeQuestionFailure("answer-rejected") }
                answered = true
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard let finished else {
            _ = try? await engine.dispatch(.interrupt(threadID: source.id)); throw LiveClaudeQuestionFailure("turn-timeout")
        }
        stage = "durability"
        try await verifyLiveClaudeQuestionTurn(root: root, finished: finished, runID: runID, question: question,
            selected: selected, notes: notes, draft: draft, sentinel: sentinel, original: original)
        await engine.shutdown()
        try await verifyLiveClaudeQuestionRestart(root: root, finished: finished, draft: draft, sentinel: sentinel, original: original)
        let evidence = ["provider": "claude", "result": "passed", "threadID": source.id.uuidString,
            "runID": runID.uuidString, "nativeThreadID": finished.providerThreadID ?? ""]
        let evidenceURL = manager.temporaryDirectory.appendingPathComponent("coincide-live-claude-question-evidence-" + acceptanceID.uuidString + ".json")
        try JSONSerialization.data(withJSONObject: evidence, options: .sortedKeys).write(to: evidenceURL, options: .withoutOverwriting)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: evidenceURL.path)
        try manager.removeItem(at: root)
    } catch {
        await engine.shutdown()
        throw LiveClaudeQuestionFailure(stage + ":" + ((error as? LiveClaudeQuestionFailure)?.category ?? "operation-failed") + ":" + root.path)
    }
}

private func verifyLiveClaudeQuestionTurn(root: URL, finished: CodingThread, runID: UUID, question: String,
                                        selected: [String], notes: String, draft: String, sentinel: URL, original: Data) async throws {
    guard finished.draft == draft, finished.runtimeRequests.isEmpty,
          finished.messages.contains(where: { message in
              guard message.role == .assistant, message.runReference?.runID == runID else { return false }
              let lines = message.text.split(separator: "\n", omittingEmptySubsequences: false)
              return lines.first.map(String.init) == selected.joined(separator: ", ")
                  && lines.dropFirst().joined(separator: "\n").contains(notes)
          }), try Data(contentsOf: sentinel) == original else { throw LiveClaudeQuestionFailure("answer-draft-or-workspace-mismatch") }
    let store = try WorkspaceDatabase(url: root.appendingPathComponent("workspace.sqlite"))
    let journal = try await store.journal(limit: 1_000), effects = try await store.effects()
    let answered = effects.filter { effect in
        guard effect.status == .succeeded,
              case .providerRespond(let threadID, let effectRunID, let request, .selectionsWithNotes(let choices, let annotations)) = effect.request else { return false }
        return threadID == finished.id && effectRunID == runID && request.claudeQuestion != nil
            && choices == [question: selected] && annotations == [question: notes]
    }
    guard answered.count == 1 else { throw LiveClaudeQuestionFailure("exact-native-response-receipt-mismatch") }
    let encoded = String(decoding: try JSONEncoder().encode(journal), as: UTF8.self)
    guard encoded.contains(selected.last!), encoded.contains(notes), !encoded.contains("Bearer "),
          !encoded.contains("authorizationHeader"), !encoded.contains("http_headers") else {
        throw LiveClaudeQuestionFailure("journal-answer-or-privacy-mismatch")
    }
    let rebuilt = try await store.rebuildProjection().snapshot
    try WorkspaceJournal.validate(rebuilt)
    guard let thread = rebuilt.threads.first(where: { $0.id == finished.id }), thread.runHistory == finished.runHistory,
          thread.draft == draft else { throw LiveClaudeQuestionFailure("journal-rebuild-mismatch") }
}

private func verifyLiveClaudeQuestionRestart(root: URL, finished: CodingThread, draft: String, sentinel: URL, original: Data) async throws {
    let reopened = try WorkspaceEngine(url: root.appendingPathComponent("workspace.sqlite"), appMCPEnabled: false,
        providerFactory: { _ in throw LiveClaudeQuestionFailure("restart-must-not-open-provider") }, identityResolver: { _ in nil })
    do {
        let restored = try await reopened.load()
        guard let thread = restored.threads.first(where: { $0.id == finished.id }), thread.draft == draft,
              thread.activeRun == nil, thread.runtimeRequests.isEmpty, thread.runHistory == finished.runHistory,
              try Data(contentsOf: sentinel) == original else { throw LiveClaudeQuestionFailure("restart-mismatch") }
        await reopened.shutdown()
    } catch { await reopened.shutdown(); throw error }
}

private struct LiveClaudeQuestionFailure: Error, LocalizedError {
    let category: String
    init(_ category: String) { self.category = category }
    var errorDescription: String? { "Live native Claude question acceptance: " + category }
}
