import Foundation
import Testing
@testable import CoincideCore

private func undoSnapshot() -> WorkspaceSnapshot {
    let project = WorkspaceProject(path: "/private/coincide-thread-undo")
    var thread = CodingThread(project: project); thread.checkpointPolicy = .disabled
    thread.draft = "  a\u{301}\u{327} — unsent\n"
    thread.draftAttachments = [.init(id: UUID(), name: "e\u{301}.txt", mimeType: "text/plain", byteCount: 3,
        digest: String(repeating: "a", count: 64), fileExtension: "txt")]
    var snapshot = WorkspaceSnapshot(); snapshot.projects = [project]; snapshot.threads = [thread]; return snapshot
}
private func undoForward(_ kind: ThreadActionUndoKind, snapshot: WorkspaceSnapshot, until: Date) -> WorkspaceCommand {
    let thread = snapshot.threads[0]
    switch kind {
    case .archive: return .editThread(thread.id, .archived(true))
    case .unpin: return .editThread(thread.id, .pinned(false))
    case .settle: return .settleThread(threadID: thread.id, expectedWorkspacePath: thread.workspacePath, reviewScript: false)
    case .snooze: return .workspaceLifecycle(.snooze(threadID: thread.id, until: until))
    case .discard: return .discardComposerDraft(.init(thread: thread))
    }
}

@Test(arguments: [ThreadActionUndoKind.archive, .unpin, .settle, .snooze, .discard])
func threadActionUndoRestoresOnlyItsNativeInverseAndNeverSendsOrRestoresFiles(kind: ThreadActionUndoKind) throws {
    let now = Date(), id = UUID(), owner = UUID(); var before = undoSnapshot()
    before.threads[0].isPinned = kind == .unpin || kind == .settle
    if kind == .unpin || kind == .settle {
        before.threads[0].workspaceLifecycle = .init(snoozedUntil: now.addingTimeInterval(3_600), snoozedAt: now.addingTimeInterval(-10))
    }
    let command = undoForward(kind, snapshot: before, until: now.addingTimeInterval(600))
    let forward = try WorkspaceDecision.make(.client(command), id: id, snapshot: before, now: now)
    let claim = try #require(ThreadActionUndoClaim.capture(.client(command), id: id, previous: before, next: forward.snapshot))
    let registry = ThreadActionUndoRegistry(); registry.record(claim, now: now)
    let owned = try #require(registry.take(forwardID: id, ownerID: owner, now: now))
    try registry.validate(owned, commandID: owned.id, now: now)
    let inverse = try WorkspaceDecision.make(.client(.threadActionUndo(owned)), id: owned.id, snapshot: forward.snapshot, now: now.addingTimeInterval(1))
    let thread = inverse.snapshot.threads[0]
    #expect(thread.activeRun == nil && thread.queuedTurns.isEmpty && thread.runHistory == nil)
    #expect(thread.messages == before.threads[0].messages && thread.workspacePreparation == nil)
    #expect(thread.draft.utf8.elementsEqual(before.threads[0].draft.utf8))
    #expect(ComposerDraftSnapshot.sameAttachments(thread.draftAttachments, before.threads[0].draftAttachments))
    switch kind {
    case .archive: #expect(!thread.isArchived && thread.queuePaused)
    case .unpin: #expect(thread.isPinned && thread.workspaceLifecycle?.snoozedUntil == before.threads[0].workspaceLifecycle?.snoozedUntil)
    case .settle:
        #expect(thread.settlement?.id == id && thread.settlement?.phase == .resuming && thread.isPinned)
        #expect(thread.workspaceLifecycle?.snoozedUntil == before.threads[0].workspaceLifecycle?.snoozedUntil)
        #expect(thread.workspaceLifecycle?.settledOverride == .active)
    case .snooze: #expect(thread.workspaceLifecycle?.snoozedUntil == nil && thread.workspaceLifecycle?.lastSnoozeWakeAt != nil)
    case .discard: #expect(inverse.effects.isEmpty)
    }
}

@Test(arguments: ["birth", "project-birth", "workspace-bytes", "provider", "new-draft", "new-attachment"])
func threadActionUndoRefusesChangedOriginalScopeAndPreservesNewDraftReferences(change: String) throws {
    let now = Date(), before = undoSnapshot(), forwardID = UUID()
    let command = undoForward(.discard, snapshot: before, until: now)
    let forward = try WorkspaceDecision.make(.client(command), id: forwardID, snapshot: before, now: now)
    let claim = try #require(ThreadActionUndoClaim.capture(.client(command), id: forwardID, previous: before, next: forward.snapshot))
    var newer = forward.snapshot
    switch change {
    case "birth": newer.threads[0].createdAt.addTimeInterval(1)
    case "project-birth": newer.projects[0].createdAt = Date().addingTimeInterval(1)
    case "workspace-bytes": newer.threads[0].workspacePath += "/a\u{301}\u{327}"
    case "provider": newer.threads[0].model = "new-selection"
    case "new-draft": newer.threads[0].draft = "New input must survive"
    case "new-attachment": newer.threads[0].draftAttachments = before.threads[0].draftAttachments
    default: Issue.record("Unknown Undo mismatch")
    }
    #expect(!claim.isApplicable(to: newer))
    #expect(throws: WorkspaceCommandError.self) {
        _ = try WorkspaceDecision.make(.client(.threadActionUndo(claim)), id: claim.id, snapshot: newer, now: now)
    }
    #expect(newer.threads[0].draft == (change == "new-draft" ? "New input must survive" : ""))
}

@Test func threadActionUndoRegistryExtendsGroupedWindowClaimsButRefusesForgedReplayedExpiredAndChangedBackTokens() throws {
    let now = Date(), owner = UUID(); var initial = undoSnapshot()
    let second = CodingThread(project: initial.projects[0]); initial.threads.append(second)
    let aID = UUID(), command = WorkspaceCommand.editThread(initial.threads[0].id, .archived(true))
    let a = try WorkspaceDecision.make(.client(command), id: aID, snapshot: initial, now: now)
    let registry = ThreadActionUndoRegistry()
    registry.record(try #require(ThreadActionUndoClaim.capture(.client(command), id: aID, previous: initial, next: a.snapshot)), now: now)
    let first = try #require(registry.take(forwardID: aID, ownerID: owner, now: now))
    #expect(registry.take(forwardID: aID, ownerID: UUID(), now: now) == nil)
    #expect(throws: WorkspaceCommandError.self) { try registry.validate(first.owned(by: UUID()), commandID: first.id, now: now) }
    #expect(throws: WorkspaceCommandError.self) { try registry.validate(first, commandID: UUID(), now: now) }
    let bID = UUID(), other = WorkspaceCommand.editThread(second.id, .archived(true))
    let b = try WorkspaceDecision.make(.client(other), id: bID, snapshot: a.snapshot, now: now.addingTimeInterval(4))
    registry.record(try #require(ThreadActionUndoClaim.capture(.client(other), id: bID, previous: a.snapshot, next: b.snapshot)), now: now.addingTimeInterval(4))
    _ = try #require(registry.take(forwardID: bID, ownerID: owner, now: now.addingTimeInterval(4)))
    try registry.validate(first, commandID: first.id, now: now.addingTimeInterval(6))
    // A real intervening change invalidates authority permanently, even if a later edit restores the same state.
    registry.reconcile(snapshot: initial, now: now.addingTimeInterval(6))
    registry.reconcile(snapshot: b.snapshot, now: now.addingTimeInterval(6))
    #expect(throws: WorkspaceCommandError.self) { try registry.validate(first, commandID: first.id, now: now.addingTimeInterval(6)) }
    let fresh = ThreadActionUndoRegistry(); fresh.record(try #require(ThreadActionUndoClaim.capture(.client(command), id: aID, previous: initial, next: a.snapshot)), now: now)
    let expired = try #require(fresh.take(forwardID: aID, ownerID: owner, now: now))
    #expect(throws: WorkspaceCommandError.self) { try fresh.validate(expired, commandID: expired.id, now: now.addingTimeInterval(5)) }
}

private final class UndoProviderProbe: @unchecked Sendable {
    private let lock = NSLock(); private var count = 0
    var calls: Int { lock.withLock { count } }
    func forbidden() throws -> any ProviderSession { lock.withLock { count += 1 }; throw CoincideError("Undo must never start a provider") }
}

@Test func threadActionUndoEngineRequiresOwnedClaimAndOriginalReceiptWinsAfterConsumptionAndRestart() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-undo-engine-" + UUID().uuidString).resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let url = root.appendingPathComponent("workspace.sqlite"), probe = UndoProviderProbe()
    var seed = undoSnapshot(); let project = WorkspaceProject(path: root.path)
    seed.projects = [project]; seed.threads[0].projectID = project.id; seed.threads[0].workspacePath = project.path
    try await WorkspaceDatabase(url: url).save(seed, event: "undo.fixture")
    let engine = try WorkspaceEngine(url: url, providerFactory: { _ in try probe.forbidden() }, identityResolver: { _ in nil })
    do {
        _ = try await engine.load()
        let threadID = seed.threads[0].id, forward = try await engine.dispatch(.editThread(threadID, .archived(true)))
        let owned = try #require(await engine.takeThreadActionUndo(forwardCommandID: forward.commandID, ownerID: UUID()))
        let forged = owned.owned(by: UUID())
        await #expect(throws: WorkspaceCommandError.self) { _ = try await engine.dispatch(.threadActionUndo(forged), id: UUID()) }
        let claim = owned
        #expect(await engine.takeThreadActionUndo(forwardCommandID: forward.commandID, ownerID: UUID()) == nil)
        await #expect(throws: WorkspaceCommandError.self) { _ = try await engine.dispatch(.threadActionUndo(claim), id: UUID()) }
        async let accepted = engine.undoThreadAction(claim)
        async let concurrent = engine.undoThreadAction(claim)
        let (receipt, sameReceipt) = try await (accepted, concurrent)
        #expect(receipt.commandID == claim.id && receipt.rejection == nil && sameReceipt.commandID == receipt.commandID)
        let nextForward = try await engine.dispatch(.editThread(threadID, .archived(true)))
        let neverAccepted = try #require(await engine.takeThreadActionUndo(forwardCommandID: nextForward.commandID, ownerID: UUID()))
        let duplicate = try await engine.undoThreadAction(claim)
        let afterDuplicate = await engine.current()
        #expect(duplicate.commandID == receipt.commandID && afterDuplicate.snapshot.threads[0].isArchived)
        await engine.shutdown()
        let reopened = try WorkspaceEngine(url: url, providerFactory: { _ in try probe.forbidden() }, identityResolver: { _ in nil })
        do {
            _ = try await reopened.load()
            let replay = try await reopened.undoThreadAction(claim)
            let afterRestart = await reopened.current()
            #expect(replay.commandID == receipt.commandID && afterRestart.snapshot.threads[0].isArchived)
            await #expect(throws: WorkspaceCommandError.self) { _ = try await reopened.undoThreadAction(neverAccepted) }
            #expect(await reopened.current().snapshot.threads[0].isArchived)
        } catch { await reopened.shutdown(); throw error }
        await reopened.shutdown()
        #expect(probe.calls == 0)
    } catch { await engine.shutdown(); throw error }
    await engine.shutdown(); try? FileManager.default.removeItem(at: root)
}
