import Foundation
import Testing
@testable import CoincideCore

private func truthCall(_ name: String, _ values: [String: JSONValue], id: String = "call") -> ChatMessage {
    .init(id: id, role: .tool, text: name + "\n" + JSONValue.object(values).pretty)
}
private func truthResult(_ text: String, flag: Bool? = nil, status: String? = nil, id: String = "call") -> ChatMessage {
    var message = ChatMessage(id: "result-" + id, role: .tool, text: text)
    var fields: [String: JSONValue] = ["tool_use_id": .string(id)]
    if let flag { fields["is_error"] = .bool(flag) }
    if let status { fields["status"] = .string(status) }
    message.providerEntity = ClaudeToolResultMetadata.entity(block: .object(fields), sessionID: "native-source", parent: nil)
    return message
}

@Test(arguments: [true, false])
func transcriptToolNativeErrorFlagsControlOutcomeWithoutRewritingQuotedOutput(flag: Bool) {
    let call = truthCall("Bash", ["command": .string("printf sample")])
    let output = "Quoted <tool_use_error>example</tool_use_error> remains literal e\u{301}\n"
    let card = TranscriptToolPresentation.card(for: call, result: truthResult(output, flag: flag), context: .init(provider: .claude))
    #expect(card.status == (flag ? .failed : .completed) && card.output?.utf8.elementsEqual(output.utf8) == true)
    let whole = "<tool_use_error>Literal example</tool_use_error>"
    let successful = TranscriptToolPresentation.card(for: call, result: truthResult(whole, flag: false), context: .init(provider: .claude))
    #expect(successful.status == .completed && successful.output == whole)
}

@Test func transcriptToolUnknownResultsWholeErrorsAndExplicitDeclinesStayDistinct() {
    let call = truthCall("Bash", ["command": .string("display")])
    let context = TranscriptToolContext(provider: .claude)
    let arbitrary = TranscriptToolPresentation.card(for: call, result: truthResult("unknown free-form output"), context: context)
    #expect(arbitrary.status == .unknown && !arbitrary.isFailure)
    let quoted = "Example: <tool_use_error>quoted</tool_use_error>"
    let literal = TranscriptToolPresentation.card(for: call, result: .init(id: "result-call", role: .tool, text: quoted), context: context)
    #expect(literal.status == .unknown && literal.output == quoted)
    let wrapped = TranscriptToolPresentation.card(for: call, result: .init(id: "result-call", role: .tool, text: " <tool_use_error>Failed completely</tool_use_error>\n"), context: context)
    #expect(wrapped.status == .failed && wrapped.output == "Failed completely")
    let declined = TranscriptToolPresentation.card(for: call, result: truthResult("Declined by the user in Coincide.", flag: true), context: context)
    let typed = TranscriptToolPresentation.card(for: call, result: truthResult("Original provider output", status: "declined"), context: context)
    #expect(declined.status == .declined && typed.status == .declined && !declined.isFailure)
    let quotedDecline = TranscriptToolPresentation.card(for: call, result: truthResult("Example: User declined tool execution."), context: context)
    #expect(quotedDecline.status == .unknown)
}

@Test(arguments: ["replace-all", "multi-replace-all", "overwrite", "notebook", "missing-content"])
func transcriptToolUnknownWholeFileEvidenceNeverAdvertisesCompleteCounts(kind: String) {
    let call: ChatMessage
    switch kind {
    case "replace-all": call = truthCall("Edit", ["file_path": .string("/w/file"), "old_string": .string("a"), "new_string": .string("b"), "replace_all": .bool(true)])
    case "multi-replace-all": call = truthCall("MultiEdit", ["file_path": .string("/w/file"), "edits": .array([.object(["old_string": .string("a"), "new_string": .string("b"), "replace_all": .bool(true)])])])
    case "notebook": call = truthCall("NotebookEdit", ["notebook_path": .string("/w/file.ipynb"), "new_source": .string("print('cell')\n")])
    case "missing-content": call = truthCall("Write", ["file_path": .string("/w/file")])
    default: call = truthCall("Write", ["file_path": .string("/w/file"), "content": .string("new file body\n")])
    }
    let card = TranscriptToolPresentation.card(for: call, result: truthResult("The file /w/file has been updated successfully.", flag: false), context: .init(provider: .claude))
    #expect(card.stat == nil && card.changes.allSatisfy { !$0.countsComplete })
    if kind == "notebook" { #expect(card.changes.isEmpty && card.paths == ["/w/file.ipynb"] && card.input?.contains("new_source") == true) }
    else { #expect(card.changes.count == 1 && card.changes[0].kind == .modified) }
}

@Test func transcriptToolFileCreationCountsRequireExactSuccessfulCreatedPathEvidence() {
    let call = truthCall("Write", ["file_path": .string("/w/cafe\u{301}.txt"), "content": .string("a\nb\n")])
    let exact = TranscriptToolPresentation.card(for: call, result: truthResult("File created successfully at: /w/cafe\u{301}.txt"), context: .init(provider: .claude))
    #expect(exact.status == .completed && exact.changes.first?.kind == .added && exact.stat == .init(files: 1, additions: 2, deletions: 0))
    for output in ["File created successfully at: /w/café.txt", "Example: File created successfully at: /w/cafe\u{301}.txt"] {
        let unknown = TranscriptToolPresentation.card(for: call, result: truthResult(output), context: .init(provider: .claude))
        #expect(unknown.stat == nil && unknown.changes.first?.kind == .modified)
    }
    let failed = TranscriptToolPresentation.card(for: call, result: truthResult("File created successfully at: /w/cafe\u{301}.txt", flag: true), context: .init(provider: .claude))
    #expect(failed.status == .failed && failed.stat == nil)
}

@Test(.timeLimit(.minutes(1)))
func transcriptToolClaudeProducerRetainsOnlyActualNativeErrorFactsAndOriginalRunScope() async throws {
    let fixture = try #require(Bundle.module.url(forResource: "claude_tool_results", withExtension: "py", subdirectory: "Fixtures"))
    let session = try ClaudeSession(executable: URL(fileURLWithPath: "/usr/bin/python3"), cwd: FileManager.default.temporaryDirectory,
        arguments: [fixture.path])
    var thread = CodingThread(project: WorkspaceProject(path: FileManager.default.temporaryDirectory.path), model: "fixture-model")
    thread.provider = .claude
    let runID = UUID(); thread.activeRun = .init(id: runID, configuration: .init(thread: thread), startedAt: .now)
    let observer = Task { () async throws -> ([ChatMessage], [UUID]) in
        var rows: [ChatMessage] = [], owners: [UUID] = []
        for await event in session.events {
            let inner: ProviderEvent
            if case .context(let id, let value) = event { owners.append(id); inner = value } else { inner = event }
            switch inner {
            case .message(let message) where message.id.hasPrefix("result-"): rows.append(message)
            case .completed: return (rows, owners)
            case .failure(let reason): throw CoincideError(reason)
            default: break
            }
        }
        throw CoincideError("The controlled result peer did not complete.")
    }
    do {
        try await session.send(text: "Controlled input", thread: thread)
        let (rows, owners) = try await observer.value
        #expect(rows.count == 4 && !owners.isEmpty && owners.allSatisfy { $0 == runID })
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        #expect(byID["result-failed"]?.providerEntity?.fields["is_error"] == .bool(true))
        #expect(byID["result-completed"]?.providerEntity?.fields["is_error"] == .bool(false))
        #expect(byID["result-unknown"]?.providerEntity?.fields["is_error"] == .null)
        for row in rows {
            let call = truthCall("Bash", ["command": .string("controlled display only")], id: String(row.id.dropFirst(7)))
            let card = TranscriptToolPresentation.card(for: call, result: row, context: .init(provider: .claude))
            #expect(card.status.rawValue == String(row.id.dropFirst(7)))
        }
    } catch { await session.close(); observer.cancel(); _ = try? await observer.value; throw error }
    await session.close()
}
