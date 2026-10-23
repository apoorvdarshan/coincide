import Foundation
import Testing
@testable import CoincideCore

private extension RemoteSteeringFixture {
    func actions(_ binding: RemoteThreadActionBinding? = nil, threadID: UUID? = nil) async throws -> RemoteThreadActionsReadResult {
        let snapshot = try await service.snapshot(.init(environmentID: service.environmentID)).workspace
        let thread = try #require(snapshot.threads.first { $0.id == (threadID ?? self.threadID) })
        return try await service.readThreadActions(.init(environmentID: service.environmentID, binding: binding,
            target: .init(environmentID: service.environmentID, projectID: thread.projectID, threadID: thread.id, configuration: .init(thread: thread))))
    }
    func idle() async throws {
        let thread = try await thread()
        if let run = thread.activeRun, let runtime = thread.runtimeID {
            _ = try await service.command(.init(environmentID: service.environmentID, command: .stop(threadID: thread.id, runID: run.id, runtimeID: runtime)))
            try await remoteSteeringEventually { try await self.thread().activeRun == nil }
        }
    }
    func pin(_ value: Bool, binding: RemoteThreadActionBinding, threadID: UUID? = nil) async throws -> RemoteEnvironmentCommandResult {
        let read = try await actions(binding, threadID: threadID), capture = try #require(read.capture)
        return try await service.command(.init(environmentID: service.environmentID, command: .threadAction(.setPinned(capture: capture, value: value)), undoOwner: binding))
    }
    func undoRequest(_ group: RemoteThreadUndoGroup, binding: RemoteThreadActionBinding) -> RemoteEnvironmentCommandRequest {
        .init(environmentID: service.environmentID, id: UUID(), command: .threadAction(.undo(binding: binding, groupID: group.id, digest: group.digest, claimIDs: group.claimIDs)))
    }
}
private actor RemoteActionCompletion { var finished = false; func complete() { finished = true } }

@Test(.timeLimit(.minutes(1)))
func remoteThreadActionsUseRealGroupedClaimsOriginalInverseUUIDAndRestartReceiptWithoutReapplying() async throws {
    let f = try await RemoteSteeringFixture.make()
    do {
        let binding = try await f.actions().binding
        #expect(try await f.pin(true, binding: binding).receipt.rejection == nil)
        let forward = try await f.pin(false, binding: binding)
        let read = try await f.actions(binding), group = try #require(read.undo)
        #expect(group.kind == .unpin && group.claimIDs.count == 1 && group.forwardCommandIDs == [forward.receipt.commandID])
        let request = f.undoRequest(group, binding: binding)
        async let first = f.service.command(request); async let duplicate = f.service.command(request)
        let (a, b) = try await (first, duplicate)
        #expect(a == b && a.receipt.rejection == nil)
        #expect(try await f.thread().isPinned)
        #expect(try await f.actions(binding).undo == nil)
        #expect(await f.session.sends.count == 1)
        #expect(await f.session.steers.isEmpty)
        await f.service.close()
        let reopened = try RemoteEnvironmentService(dataDirectory: f.data, expectedEnvironmentID: f.service.environmentID, options: f.options,
            providerFactory: { _ in Issue.record("Undo receipt recovery cannot start a provider"); throw CancellationError() })
        do {
            #expect(try await reopened.command(request) == a)
            #expect(try await reopened.receipt(request).receipt == a.receipt)
            let replay = try await reopened.command(.init(environmentID: f.service.environmentID, id: UUID(), command: request.command))
            #expect(replay.receipt.rejection != nil)
            #expect(try await reopened.snapshot(.init(environmentID: f.service.environmentID)).workspace.threads.first { $0.id == f.threadID }?.isPinned == true)
        } catch { await reopened.close(); throw error }
        await reopened.close()
    } catch { await f.close(); throw error }
    await f.close()
}

@Test(.timeLimit(.minutes(1)))
func remoteArchiveAcknowledgmentJoinsExactRuntimeDrainAndUndoKeepsDraftAndPausedQueueWithoutAProviderTurn() async throws {
    let f = try await RemoteSteeringFixture.make()
    do {
        var thread = try await f.thread()
        _ = try await f.service.command(.init(environmentID: f.service.environmentID, command: .submit(threadID: thread.id, text: "Keep this queued input", expectedConfiguration: .init(thread: thread))))
        _ = try await f.service.command(.init(environmentID: f.service.environmentID, command: .editThread(threadID: thread.id, edit: .draft("Unsent exact draft e\u{301}\u{327}"), expectedConfiguration: .init(thread: thread))))
        try await f.idle()
        thread = try await f.thread()
        let read = try await f.actions(), capture = try #require(read.capture), completed = RemoteActionCompletion()
        await f.session.holdClose()
        let request = RemoteEnvironmentCommandRequest(environmentID: f.service.environmentID, command: .threadAction(.setArchived(capture: capture, value: true)), undoOwner: read.binding)
        let archiving = Task { let result = try await f.service.command(request); await completed.complete(); return result }
        await f.session.closingEntered()
        #expect(await completed.finished == false)
        let stored = try await WorkspaceDatabase(url: f.data.appendingPathComponent("workspace.sqlite")).receipt(request.id, matching: RemoteEnvironmentProtocol.payload(request))
        #expect(stored?.rejection == nil && stored != nil)
        await f.session.releaseClose()
        let archived = try await archiving.value
        #expect(archived.receipt.rejection == nil)
        let after = try await f.thread()
        #expect(after.isArchived && after.queuePaused && after.activeRun == nil)
        #expect(after.draft.utf8.elementsEqual(thread.draft.utf8) && after.queuedTurns == thread.queuedTurns)
        let undo = try await f.actions(read.binding), group = try #require(undo.undo)
        #expect(group.kind == .archive)
        #expect(try await f.service.command(f.undoRequest(group, binding: read.binding)).receipt.rejection == nil)
        let restored = try await f.thread()
        #expect(!restored.isArchived && restored.queuePaused && restored.activeRun == nil)
        #expect(restored.draft.utf8.elementsEqual(thread.draft.utf8) && restored.queuedTurns == thread.queuedTurns)
        #expect(await f.session.sends.count == 1)
        #expect(try await f.service.command(request) == archived)
        #expect(await f.session.closes == 1)
    } catch { await f.session.releaseClose(); await f.close(); throw error }
    await f.close()
}

@Test(.timeLimit(.minutes(1)))
func remoteThreadActionsStaleGroupedButtonsAndForgedClaimsNeverConsumeOrApplyTheNewGroup() async throws {
    let f = try await RemoteSteeringFixture.make()
    do {
        let binding = try await f.actions().binding, a = try await f.thread(), secondID = UUID()
        _ = try await f.service.command(.init(environmentID: f.service.environmentID, command: .createThread(id: secondID, projectID: a.projectID,
            provider: .codex, title: "Second actual host conversation", model: "", permission: .supervised, checkpointPolicy: .disabled)))
        _ = try await f.pin(true, binding: binding); _ = try await f.pin(false, binding: binding)
        let old = try #require(try await f.actions(binding).undo)
        _ = try await f.pin(true, binding: binding, threadID: secondID); _ = try await f.pin(false, binding: binding, threadID: secondID)
        let current = try #require(try await f.actions(binding).undo)
        #expect(current.claimIDs.count == 2 && current.id != old.id)
        #expect(try await f.service.command(f.undoRequest(old, binding: binding)).receipt.rejection != nil)
        let forged = RemoteEnvironmentCommandRequest(environmentID: f.service.environmentID, command: .threadAction(.undo(binding: binding,
            groupID: current.id, digest: current.digest, claimIDs: [UUID()])))
        #expect(try await f.service.command(forged).receipt.rejection != nil)
        let before = try await f.service.snapshot(.init(environmentID: f.service.environmentID)).workspace
        #expect(before.threads.allSatisfy { !$0.isPinned })
        #expect(try await f.service.command(f.undoRequest(current, binding: binding)).receipt.rejection == nil)
        let after = try await f.service.snapshot(.init(environmentID: f.service.environmentID)).workspace
        #expect(after.threads.allSatisfy { $0.isPinned })
        _ = try await f.pin(false, binding: binding, threadID: secondID)
        let catalog = try await f.service.openProjection(.init(environmentID: f.service.environmentID))
        guard case .threads(let ordered) = try await f.service.projectionCatalog(.init(binding: catalog, query: .threads(projectID: nil, includeArchived: false))) else { throw CancellationError() }
        #expect(ordered.items.first?.id == f.threadID && ordered.items.first?.isPinned == true)
        #expect(await f.session.sends.count == 1)
    } catch { await f.close(); throw error }
    await f.close()
}

@Test(.timeLimit(.minutes(1)), arguments: ["configuration", "replacement-lease", "lease"])
func remoteThreadMetadataStaleScopeIsAKnownRefusalAndKeepsTheEngineUsable(change: String) async throws {
    let f = try await RemoteSteeringFixture.make()
    do {
        try await f.idle()
        let read = try await f.actions(), capture = try #require(read.capture), before = try await f.thread()
        switch change {
        case "configuration": _ = try await f.service.command(.init(environmentID: f.service.environmentID, command: .editThread(threadID: before.id, edit: .model("New target configuration"), expectedConfiguration: .init(thread: before))))
        case "lease": _ = try await f.service.releaseThreadActions(.init(binding: read.binding))
        default:
            // The original host lease is released; a new lease for identical
            // public target IDs never authorizes a retained old capture.
            _ = try await f.service.releaseThreadActions(.init(binding: read.binding)); _ = try await f.actions()
        }
        let result = try await f.service.command(.init(environmentID: f.service.environmentID, command: .threadAction(.setArchived(capture: capture, value: true)), undoOwner: read.binding))
        #expect(result.receipt.rejection != nil)
        let current = try await f.thread()
        #expect(!current.isArchived)
        #expect(try await f.service.command(.init(environmentID: f.service.environmentID, command: .editThread(threadID: current.id, edit: .draft("Engine still accepts ordinary edits"), expectedConfiguration: .init(thread: current)))).receipt.rejection == nil)
        #expect(await f.session.sends.count == 1)
    } catch { await f.close(); throw error }
    await f.close()
}

@Test(.timeLimit(.minutes(1)))
func remoteUndoExpiresAtNativeAdmissionWhileAnOriginalForwardReceiptStillWinsAfterTTL() async throws {
    let f = try await RemoteSteeringFixture.make()
    do {
        try await f.idle()
        let read = try await f.actions(), capture = try #require(read.capture)
        let request = RemoteEnvironmentCommandRequest(environmentID: f.service.environmentID, command: .threadAction(.setArchived(capture: capture, value: true)), undoOwner: read.binding)
        let receipt = try await f.service.command(request)
        let group = try #require(try await f.actions(read.binding).undo)
        try await Task.sleep(for: .milliseconds(5_050)) // Actual product lifetime, not a test retry/deadline extension.
        #expect(try await f.service.command(request) == receipt)
        #expect(try await f.service.command(f.undoRequest(group, binding: read.binding)).receipt.rejection != nil)
        #expect(try await f.thread().isArchived)
        #expect(await f.session.sends.count == 1)
    } catch { await f.close(); throw error }
    await f.close()
}

@Test(.timeLimit(.minutes(1)))
func remoteThreadActionsRefuseARecreatedNativeTargetWithIdenticalPublicIDsPathAndConfiguration() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-remote-actions-birth-" + UUID().uuidString).resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let project = WorkspaceProject(path: root.path), thread = CodingThread(project: project), environment = UUID()
    var snapshot = WorkspaceSnapshot(); snapshot.projects = [project]; snapshot.threads = [thread]
    let database = root.appendingPathComponent("workspace.sqlite")
    try await WorkspaceDatabase(url: database).save(snapshot, event: "remote.actions.birth.fixture")
    let engine = try WorkspaceEngine(url: database, providerFactory: { _ in Issue.record("Metadata actions cannot launch a provider"); throw CancellationError() }, identityResolver: { _ in nil })
    _ = try await engine.load()
    let workspace = try RemoteWorkspaceService(environmentID: environment, engine: engine, dataDirectory: root)
    let service = RemoteThreadActionsService(environmentID: environment, hostID: UUID(), engine: engine, workspace: workspace)
    do {
        let target = RemoteWorkspaceTarget(environmentID: environment, projectID: project.id, threadID: thread.id, configuration: .init(thread: thread))
        let read = try await service.read(.init(environmentID: environment, target: target)), capture = try #require(read.capture)
        let action = RemoteThreadAction.setArchived(capture: capture, value: true)
        let request = RemoteEnvironmentCommandRequest(environmentID: environment, command: .threadAction(action), undoOwner: read.binding)
        let prepared = try await service.prepare(commandID: request.id, action: action)
        _ = try await engine.dispatch(.removeProject(projectID: project.id, expectedThreadIDs: [thread.id]))
        await engine.awaitProjectRemovalCleanup(projectID: project.id)
        var replacementProject = project; replacementProject.createdAt = Date().addingTimeInterval(1)
        var replacement = CodingThread(project: replacementProject); replacement.id = thread.id; replacement.createdAt = thread.createdAt.addingTimeInterval(1)
        #expect(ProviderConfiguration(thread: replacement) == ProviderConfiguration(thread: thread))
        _ = try await engine.dispatch(.addProjectWithThread(project: replacementProject, thread: replacement))
        let refused = try await engine.dispatchRemoteEnvironment(request, preparation: .threadActions(prepared))
        #expect(refused.rejection != nil)
        let current = await engine.current().snapshot
        #expect(current.threads.first?.createdAt == replacement.createdAt && current.threads.first?.isArchived == false)
        #expect(try await engine.dispatch(.editThread(thread.id, .draft("Still accepts native commands"))).rejection == nil)
    } catch { await service.close(); await workspace.close(); await engine.shutdown(); throw error }
    await service.close(); await workspace.close(); await engine.shutdown()
    try FileManager.default.removeItem(at: root)
}

@Test(.timeLimit(.minutes(1)))
func remoteArchivedCatalogRemainsBrowsableWithoutChangingOldPinnedViews() async throws {
    let f = try await RemoteSteeringFixture.make()
    do {
        try await f.idle()
        let read = try await f.actions(), capture = try #require(read.capture), original = try await f.thread()
        let old = try await f.service.openProjection(.init(environmentID: f.service.environmentID, scope: .catalog))
        #expect(try await f.service.command(.init(environmentID: f.service.environmentID, command: .threadAction(.setArchived(capture: capture, value: true)), undoOwner: read.binding)).receipt.rejection == nil)
        let latest = try await f.service.openProjection(.init(environmentID: f.service.environmentID, scope: .catalog))
        guard case .threads(let hidden) = try await f.service.projectionCatalog(.init(binding: latest, query: .threads(projectID: nil, includeArchived: false))),
              case .threads(let visible) = try await f.service.projectionCatalog(.init(binding: latest, query: .threads(projectID: nil, includeArchived: true))),
              case .threads(let pinnedOld) = try await f.service.projectionCatalog(.init(binding: old, query: .threads(projectID: nil, includeArchived: false))) else { throw CancellationError() }
        #expect(hidden.items.isEmpty && visible.items.map(\.id) == [original.id] && visible.items[0].isArchived)
        #expect(pinnedOld.items.map(\.id) == [original.id] && !pinnedOld.items[0].isArchived)
        #expect(await f.session.sends.count == 1)
    } catch { await f.close(); throw error }
    await f.close()
}

@Test(.timeLimit(.minutes(1)))
func remoteQueueRemovalAndReorderUseExactNativeRevisionsAndOriginalReceiptsWithoutTouchingDraftsOrSending() async throws {
    let f = try await RemoteSteeringFixture.make()
    do {
        let initial = try await f.thread()
        for text in ["First", "Second", "Third"] { _ = try await f.service.command(.init(environmentID: f.service.environmentID, command: .submit(threadID: initial.id, text: text, expectedConfiguration: .init(thread: initial)))) }
        _ = try await f.service.command(.init(environmentID: f.service.environmentID, command: .editThread(threadID: initial.id, edit: .draft("Keep unsent draft"), expectedConfiguration: .init(thread: initial))))
        let first = try await f.read(), a = first.page.items[0], b = first.page.items[1]
        let oldRevision = try #require(first.page.capture.queueRevision)
        _ = try await f.service.command(.init(environmentID: f.service.environmentID, command: .promptSteering(target: first.target,
            action: .editQueued(capture: first.page.capture, queuedID: a.id, digest: a.digest, text: "Changed exact first content", selectedAttachmentIDs: [], uploadedAttachmentIDs: [], orderedAttachmentIDs: []))))
        let staleMove = try await f.service.command(.init(environmentID: f.service.environmentID, command: .promptSteering(target: first.target,
            action: .moveQueued(capture: first.page.capture, queuedID: b.id, beforeID: a.id, revision: oldRevision))))
        #expect(staleMove.receipt.rejection != nil)
        let read = try await f.read(), revision = try #require(read.page.capture.queueRevision)
        let move = RemoteEnvironmentCommandRequest(environmentID: f.service.environmentID, command: .promptSteering(target: read.target,
            action: .moveQueued(capture: read.page.capture, queuedID: b.id, beforeID: a.id, revision: revision)))
        let moved = try await f.service.command(move)
        #expect(moved.receipt.rejection == nil)
        #expect(try await f.service.command(move) == moved)
        let afterMove = try await f.thread()
        #expect(afterMove.queuedTurns.map(\.id) == [b.id, a.id, first.page.items[2].id] && afterMove.draft == "Keep unsent draft")
        let current = try await f.read(), row = current.page.items[0]
        let remove = RemoteEnvironmentCommandRequest(environmentID: f.service.environmentID, command: .promptSteering(target: current.target,
            action: .removeQueued(capture: current.page.capture, queuedID: row.id, digest: row.digest)))
        let removed = try await f.service.command(remove)
        #expect(removed.receipt.rejection == nil)
        #expect(try await f.service.command(remove) == removed)
        let final = try await f.thread()
        #expect(final.queuedTurns.map(\.id) == [a.id, first.page.items[2].id] && final.draft == "Keep unsent draft")
        #expect(await f.session.sends.count == 1)
        #expect(await f.session.steers.isEmpty)
        await f.service.close()
        let reopened = try RemoteEnvironmentService(dataDirectory: f.data, expectedEnvironmentID: f.service.environmentID, options: f.options,
            providerFactory: { _ in Issue.record("Queue receipt recovery cannot dispatch a provider"); throw CancellationError() })
        do {
            #expect(try await reopened.command(move) == moved)
            #expect(try await reopened.command(remove) == removed)
            let persisted = try await reopened.snapshot(.init(environmentID: f.service.environmentID)).workspace
            #expect(persisted.threads.first(where: { $0.id == f.threadID })?.queuedTurns.map(\.id) == final.queuedTurns.map(\.id))
        } catch { await reopened.close(); throw error }
        await reopened.close()
    } catch { await f.close(); throw error }
    await f.close()
}
