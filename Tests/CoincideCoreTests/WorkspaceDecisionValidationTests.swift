import Foundation
import Testing
@testable import CoincideCore

private func heldLedgerCommand(_ action: String, fixture: ConversationHistoryFilesFixture) -> EngineCommand {
    switch action {
    case "draft": return .client(.editThread(fixture.threadID, .draft("Latest typing while file restoration is held")))
    case "pin": return .client(.editThread(fixture.threadID, .pinned(true)))
    default:
        let project = WorkspaceProject(path: "/tmp/coincide-registration-with-held-ledger")
        return .client(.addProjectWithThread(project: project, thread: CodingThread(project: project)))
    }
}

/// Ordinary edits and unrelated registration still encounter the complete
/// retained file ledger. This guards against dropping validation while moving
/// its encoding work outside the general reducer's temporary stack buffers.
@Test(arguments: ["draft", "pin", "registration"])
func workspaceDecisionValidatesRetainedFileLedgerForGeneralEditsAndUnrelatedRegistration(action: String) throws {
    var fixture = try ConversationHistoryFilesFixture()
    let review = try fixture.review()
    try fixture.accept(review); try fixture.dispatchProvider(review); try fixture.finishProvider(review)
    let held = try fixture.operation(review), original = try #require(fixture.snapshot.threads.first { $0.id == fixture.threadID })
    let fingerprint = try fixture.snapshot.checkpointRestoreSourceFingerprint(threadID: fixture.threadID)
    #expect(held.phase == .applied && held.files?.phase == .accepted && held.locksFiles)
    let command = heldLedgerCommand(action, fixture: fixture)
    let result = try fixture.command(command)
    let after = try #require(fixture.snapshot.threads.first { $0.id == fixture.threadID })
    #expect(try fixture.operation(review) == held)
    #expect(try fixture.snapshot.checkpointRestoreSourceFingerprint(threadID: fixture.threadID) == fingerprint)
    #expect(after.messages == original.messages && after.runHistory == original.runHistory && after.activeRun == nil)
    #expect(result.effects.isEmpty && result.closeRuntimes.isEmpty)
    switch action {
    case "draft": #expect(after.draft == "Latest typing while file restoration is held")
    case "pin": #expect(after.isPinned)
    default:
        #expect(fixture.snapshot.projects.count == 2 && fixture.snapshot.threads.count == 2)
        #expect(fixture.snapshot.threads.contains { $0.projectID != original.projectID && $0.messages.isEmpty && $0.activeRun == nil })
    }
    try WorkspaceJournal.validate(fixture.snapshot)
}

@Test(arguments: ["draft", "pin", "registration"])
func workspaceDecisionRejectsMismatchedHeldLedgerWithoutPublishingAnOrdinaryMutation(action: String) throws {
    var fixture = try ConversationHistoryFilesFixture()
    let review = try fixture.review()
    try fixture.accept(review); try fixture.dispatchProvider(review); try fixture.finishProvider(review)
    let index = try #require(fixture.snapshot.conversationHistoryOperations?.firstIndex { $0.id == review.id })
    fixture.snapshot.conversationHistoryOperations?[index].files?.postHistorySourceFingerprint = String(repeating: "0", count: 64)
    let before = fixture.snapshot
    let command = heldLedgerCommand(action, fixture: fixture)
    #expect(throws: CoincideError.self) { try fixture.command(command) }
    #expect(fixture.snapshot == before, "A full-ledger failure must reject the edit or atomic project registration, not publish a partial decision.")
}

@Test func workspaceDecisionIgnoredProviderEventPreservesTheExactHeldHistoryAndFilesSnapshot() throws {
    var fixture = try ConversationHistoryFilesFixture()
    let review = try fixture.review()
    try fixture.accept(review); try fixture.dispatchProvider(review); try fixture.finishProvider(review)
    let before = fixture.snapshot
    let ignored = try fixture.command(.provider(threadID: fixture.threadID, runtimeID: UUID(),
        event: .delta(id: "late-retired-message", role: .assistant, text: "This retired provider cannot modify a file-held conversation.")))
    #expect(ignored.snapshot == before && ignored.effects.isEmpty && ignored.closeRuntimes.isEmpty)
    #expect(try fixture.operation(review).files?.phase == .accepted)
}
