import Foundation
import Testing
@testable import CoincideCore

@Test func appMCPIndependentSendPreservesLiteralTextComposerAttachmentsAndExplicitIdleQueue() async throws {
    let root = try temporaryWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
    let attachment = try await AttachmentStore(root: root.appendingPathComponent("Attachments")).importData(Data("personal draft".utf8), name: "draft.txt")
    let project = WorkspaceProject(path: root.path)
    var thread = CodingThread(project: project)
    thread.title = "Keep my explicit title"
    thread.draft = "Do not replace my draft"; thread.draftAttachments = [attachment]
    var snapshot = WorkspaceSnapshot(); snapshot.projects = [project]; snapshot.threads = [thread]
    let id = UUID(), literal = "  Explicit 😀 input\n$HOME  "
    let decision = try WorkspaceDecision.make(.client(.submitFromAppMCP(threadID: thread.id, text: literal, queueEvenWhenIdle: true)), id: id, snapshot: snapshot, now: Date())
    let after = try #require(decision.snapshot.threads.first)
    #expect(after.activeRun == nil && after.queuePaused)
    #expect(after.queuedTurns.map(\.id) == [id])
    #expect(after.queuedTurns.first?.text == literal && after.queuedTurns.first?.attachments == nil)
    #expect(after.draft == thread.draft && after.draftAttachments == [attachment])
    #expect(decision.effects.isEmpty && after.messages.isEmpty)
    let next = try WorkspaceDecision.make(.client(.submitFromAppMCP(threadID: thread.id, text: "next", queueEvenWhenIdle: false)), id: UUID(), snapshot: decision.snapshot, now: Date())
    #expect(next.snapshot.threads[0].activeRun == nil && next.snapshot.threads[0].queuedTurns.count == 2)
    #expect(next.snapshot.threads[0].queuedTurns.first?.id == id && next.effects.isEmpty)
    let resumed = try WorkspaceDecision.make(.client(.resumeQueue(threadID: thread.id)), id: UUID(), snapshot: next.snapshot, now: Date())
    #expect(resumed.snapshot.threads[0].title == thread.title && resumed.snapshot.threads[0].messages.first?.text == literal)
    #expect(resumed.snapshot.threads[0].draft == thread.draft && resumed.snapshot.threads[0].draftAttachments == [attachment])
}

@Test func appMCPQueuedTextRevisionAndReorderPreserveCapturesAndSurviveJournalRebuild() async throws {
    let root = try temporaryWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
    let attachment = try await AttachmentStore(root: root.appendingPathComponent("Attachments")).importData(Data("queued file".utf8), name: "queued.txt")
    let project = WorkspaceProject(path: root.path)
    var thread = CodingThread(project: project)
    thread.draft = "Current user draft"; thread.draftAttachments = [attachment]; thread.queuePaused = true
    let first = QueuedTurn(id: UUID(), text: "first", configuration: .init(thread: thread), createdAt: Date(), attachments: [attachment], checkpointPolicy: thread.effectiveCheckpointPolicy)
    thread.model = "future model"
    let second = QueuedTurn(id: UUID(), text: "second", configuration: .init(thread: thread), createdAt: Date())
    thread.queuedTurns = [first, second]
    var snapshot = WorkspaceSnapshot(); snapshot.projects = [project]; snapshot.threads = [thread]
    let database = try WorkspaceDatabase(url: root.appendingPathComponent("workspace.sqlite"))
    _ = try await database.commit(snapshot, event: "fixture.queue", commandID: UUID())
    let literal = "  Revised 😀 工作  "
    let edited = try WorkspaceDecision.make(.client(.replaceQueuedText(threadID: thread.id, queuedID: first.id, expectedText: first.text, text: literal)), id: UUID(), snapshot: snapshot, now: Date())
    var expected = first; expected.text = literal
    #expect(edited.snapshot.threads[0].queuedTurns == [expected, second])
    let reordered = try WorkspaceDecision.make(.client(.moveQueued(threadID: thread.id, queuedID: second.id, beforeID: first.id, expectedOrder: [first.id, second.id])), id: UUID(), snapshot: edited.snapshot, now: Date())
    #expect(reordered.snapshot.threads[0].queuedTurns == [second, expected])
    #expect(reordered.snapshot.threads[0].draft == thread.draft && reordered.snapshot.threads[0].draftAttachments == [attachment])
    #expect(reordered.effects.isEmpty && reordered.closeRuntimes.isEmpty)
    _ = try await database.commit(reordered.snapshot, event: "queue.edited", commandID: UUID())
    #expect(try await database.rebuildProjection().snapshot == reordered.snapshot)
    #expect(try await WorkspaceDatabase(url: root.appendingPathComponent("workspace.sqlite")).load() == reordered.snapshot)
    #expect(throws: WorkspaceCommandError.self) { try WorkspaceDecision.make(.client(.replaceQueuedText(threadID: thread.id, queuedID: first.id, expectedText: first.text, text: "stale")), id: UUID(), snapshot: reordered.snapshot, now: Date()) }
    #expect(throws: WorkspaceCommandError.self) { try WorkspaceDecision.make(.client(.moveQueued(threadID: thread.id, queuedID: first.id, beforeID: nil, expectedOrder: [first.id, second.id])), id: UUID(), snapshot: reordered.snapshot, now: Date()) }
}

@Test func appMCPExactStopAndCatalogGuardRefuseSuccessorRunsAndChangedTargetConfiguration() throws {
    let project = WorkspaceProject(path: "/tmp")
    let thread = CodingThread(project: project), firstID = UUID(), runtimeID = UUID()
    var snapshot = WorkspaceSnapshot(); snapshot.projects = [project]; snapshot.threads = [thread]
    snapshot = try WorkspaceDecision.make(.client(.submit(threadID: thread.id, text: "first")), id: firstID, snapshot: snapshot, now: Date()).snapshot
    snapshot = try WorkspaceDecision.make(.runtimeOpened(threadID: thread.id, runID: firstID, runtimeID: runtimeID), id: UUID(), snapshot: snapshot, now: Date()).snapshot
    let captured = ProviderConfiguration(thread: snapshot.threads[0])
    let stop = EngineCommand.client(.interruptFromAppMCP(threadID: thread.id, expectedRunID: firstID, expectedRuntimeID: runtimeID))
    let exact = try WorkspaceDecision.make(stop, id: UUID(), snapshot: snapshot, now: Date())
    #expect(exact.snapshot.threads[0].activeRun == nil && exact.snapshot.threads[0].state == .interrupted)
    var successor = snapshot; successor.threads[0].activeRun?.id = UUID()
    #expect(throws: WorkspaceCommandError.self) { try WorkspaceDecision.make(stop, id: UUID(), snapshot: successor, now: Date()) }
    var replaced = snapshot; replaced.threads[0].runtimeID = UUID()
    #expect(throws: WorkspaceCommandError.self) { try WorkspaceDecision.make(stop, id: UUID(), snapshot: replaced, now: Date()) }
    _ = try WorkspaceDecision.make(.appMCPTargetGuard(threadID: thread.id, configuration: captured), id: UUID(), snapshot: snapshot, now: Date())
    var changed = snapshot; changed.threads[0].model = "new target selection"
    #expect(throws: WorkspaceCommandError.self) { try WorkspaceDecision.make(.appMCPTargetGuard(threadID: thread.id, configuration: captured), id: UUID(), snapshot: changed, now: Date()) }
    #expect(changed.threads[0].activeRun?.stopRequested == false)
}

@Test func appMCPQuestionGuardRejectsReusedRequestIDsFromAnotherRuntimeOrChangedQuestion() throws {
    let project = WorkspaceProject(path: "/tmp")
    var thread = CodingThread(project: project)
    let runtimeID = UUID()
    let request = ApprovalRequest(id: .number(7), method: "item/tool/requestUserInput", params: .object(["questions": .array([
        .object(["id": .string("question"), "question": .string("Original question"), "options": .array([])])
    ])]))
    thread.runtimeID = runtimeID; thread.runtimeRequests = [.init(request: request, sessionScoped: true)]
    var snapshot = WorkspaceSnapshot(); snapshot.projects = [project]; snapshot.threads = [thread]
    let command = EngineCommand.appMCPRequestGuard(threadID: thread.id, runtimeID: runtimeID, runID: nil, request: request)
    _ = try WorkspaceDecision.make(command, id: UUID(), snapshot: snapshot, now: Date())
    var replacement = snapshot; replacement.threads[0].runtimeID = UUID()
    #expect(throws: WorkspaceCommandError.self) { try WorkspaceDecision.make(command, id: UUID(), snapshot: replacement, now: Date()) }
    let reused = ApprovalRequest(id: request.id, method: request.method, params: .object(["questions": .array([
        .object(["id": .string("question"), "question": .string("Replacement question"), "options": .array([])])
    ])]))
    replacement = snapshot; replacement.threads[0].runtimeRequests = [.init(request: reused, sessionScoped: true)]
    #expect(throws: WorkspaceCommandError.self) { try WorkspaceDecision.make(command, id: UUID(), snapshot: replacement, now: Date()) }
    replacement = snapshot; replacement.threads[0].runtimeRequests[0].responding = true
    #expect(throws: WorkspaceCommandError.self) { try WorkspaceDecision.make(command, id: UUID(), snapshot: replacement, now: Date()) }
}
