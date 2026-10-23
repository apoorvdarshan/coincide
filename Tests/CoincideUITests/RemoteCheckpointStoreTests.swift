import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Coincide
@testable import CoincideCore

private actor RemoteCheckpointBoundary {
    private var waiting = false
    private var released = false
    private var body: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []
    func pause() async { waiting = true; observers.forEach { $0.resume() }; observers = []; if !released { await withCheckedContinuation { body = $0 } } }
    func entered() async { if !waiting { await withCheckedContinuation { observers.append($0) } } }
    func release() { released = true; body?.resume(); body = nil }
}

private actor RemoteCheckpointPeer {
    let rootID = UUID()
    private var thread: CodingThread
    private var reviewBoundary: RemoteCheckpointBoundary?
    private var diffBoundary: RemoteCheckpointBoundary?
    private var discardBoundary: RemoteCheckpointBoundary?
    private var failBind = false
    private var bindings = 0
    private var reads: [RemoteCheckpointReadRequest] = []
    private var reviews: [RemoteCheckpointReview] = []
    private var discarded: [RemoteCheckpointDiscardRequest] = []
    init(thread: CodingThread) { self.thread = thread }
    nonisolated var transport: RemoteCheckpointTransport {
        .init(bind: { try await self.bind($0) }, read: { try await self.read($0) }, review: { try await self.review($0) }, discard: { await self.discard($0) })
    }
    func update(_ thread: CodingThread) { self.thread = thread }
    func holdReview(_ boundary: RemoteCheckpointBoundary) { reviewBoundary = boundary }
    func holdDiff(_ boundary: RemoteCheckpointBoundary) { diffBoundary = boundary }
    func holdDiscard(_ boundary: RemoteCheckpointBoundary) { discardBoundary = boundary }
    func setFailBind(_ value: Bool) { failBind = value }
    func counts() -> [Int] { [bindings, reads.count, reviews.count, discarded.count] }
    func discards() -> [RemoteCheckpointDiscardRequest] { discarded }
    func lastReview() -> RemoteCheckpointReview? { reviews.last }
    private func bind(_ target: RemoteWorkspaceTarget) throws -> RemoteWorkspaceTarget {
        bindings += 1; guard !failBind else { throw RemoteCheckpointFailure(.invalidTarget) }
        return .init(environmentID: target.environmentID, projectID: target.projectID, threadID: target.threadID, configuration: target.configuration, rootID: rootID)
    }
    private func read(_ request: RemoteCheckpointReadRequest) async throws -> RemoteCheckpointReadResult {
        guard request.target.rootID == rootID else { throw RemoteCheckpointFailure(.invalidTarget) }
        reads.append(request)
        let value: RemoteCheckpointValue
        switch request.query {
        case .inventory:
            let runs = (thread.runHistory ?? []).compactMap { record -> RemoteCheckpointRun? in
                guard let saved = record.checkpoints else { return nil }
                var reasons: [UUID: String] = [:]
                for attempt in [saved.baseline] + saved.previousPostRunAttempts + (saved.postRun.map { [$0] } ?? []) {
                    if !attempt.workspacePath.utf8.elementsEqual(thread.workspacePath.utf8) { reasons[attempt.id] = "This checkpoint belongs to an earlier remote worktree." }
                }
                return .init(id: record.id, baseline: saved.baseline, postRun: saved.postRun, previousPostRunAttempts: saved.previousPostRunAttempts, restoreUnavailableReasons: reasons)
            }
            value = .inventory(.init(policy: thread.effectiveCheckpointPolicy, runs: runs))
        case .runDiff(let run, let before, let after, let maximum):
            #expect(maximum == 262_144)
            value = .diff(.init(runID: run, baselineAttemptID: before, postRunAttemptID: after,
                patch: "--- a/notes.txt\n+++ b/notes.txt\n@@ -1 +1 @@\n-before\n+after\n", truncated: true))
            if let boundary = diffBoundary { diffBoundary = nil; await boundary.pause() }
        }
        return .init(target: request.target, value: value)
    }
    func makeReview(_ request: RemoteCheckpointReviewRequest) throws -> RemoteCheckpointReview {
        guard let attempt = thread.runCheckpoint(runID: request.runID, stage: request.stage, expectedAttemptID: request.attemptID), let receipt = attempt.receipt else { throw RemoteCheckpointFailure(.invalidRequest) }
        let id = UUID()
        let git = try GitCheckpointRestoreReview(id: id, targetReceipt: receipt, currentPlan: receipt.plan,
            manifestDigest: String(repeating: "e", count: 64), affectedPaths: ["notes.txt", "added.txt"],
            previewPatch: "--- a/notes.txt\n+++ b/notes.txt\n@@ -1 +1 @@\n-current\n+saved\n", previewTruncated: true)
        let native = try RunCheckpointRestoreReview(id: id, threadID: thread.id, projectID: thread.projectID,
            runID: request.runID, stage: request.stage, attemptID: attempt.id, sourceIncarnation: UUID(), sourceFingerprint: String(repeating: "f", count: 64), checkpoint: attempt, gitReview: git)
        return try .init(target: request.target, value: native)
    }
    private func review(_ request: RemoteCheckpointReviewRequest) async throws -> RemoteCheckpointReview {
        let value = try makeReview(request); reviews.append(value)
        if let boundary = reviewBoundary { reviewBoundary = nil; await boundary.pause() }
        return value
    }
    private func discard(_ request: RemoteCheckpointDiscardRequest) async -> RemoteCheckpointDiscardResult {
        discarded.append(request)
        if let boundary = discardBoundary { discardBoundary = nil; await boundary.pause() }
        return .init(request: request, discarded: true)
    }
}

@Test(.timeLimit(.minutes(1))) @MainActor
func remoteCheckpointReconnectRebindsTheNewHostBeforeReadingOrReviewingFiles() async throws {
    let f = try RemoteCheckpointFixture()
    do {
        await f.update(); let model = try f.model()
        await model.refresh()
        let oldRoot = try #require(model.target.rootID)
        f.store.disconnect()
        let replacement = RemoteCheckpointPeer(thread: f.thread)
        await f.store.select(target: f.target, thread: f.thread, snapshot: f.snapshot, transport: replacement.transport,
            supported: true, canWrite: true, canMutate: true, perform: { _ in false })
        await model.refresh()
        #expect(model.target.rootID != oldRoot && model.target.rootID == replacement.rootID)
        #expect(model.inventory?.runs.first?.id == f.run.id)
        let counts = await replacement.counts()
        #expect(Array(counts.prefix(2)) == [1, 1])
        _ = await model.prepareRestore(runID: f.run.id, stage: .baseline, attemptID: f.run.checkpoints!.baseline.id)
        #expect(model.restoreReview?.target.rootID == replacement.rootID)
        #expect(f.thread.draft == "Keep this unsent remote draft" && f.commands.isEmpty)
        await f.finish()
    } catch { await f.finish(); throw error }
}

@MainActor private final class RemoteCheckpointFixture {
    let store = RemoteCheckpointStore()
    let environmentID = UUID()
    var thread: CodingThread
    let peer: RemoteCheckpointPeer
    var snapshot = WorkspaceSnapshot()
    var commands: [RemoteEnvironmentCommand] = []
    var accepted = false
    var allowRestore = true
    init() throws {
        let project = WorkspaceProject(path: "/remote-only/project")
        var thread = CodingThread(project: project); thread.workspacePath = "/remote-only/isolated-worktree"; thread.draft = "Keep this unsent remote draft"
        thread.checkpointPolicy = .automatic
        thread.runHistory = [try Self.record(thread: thread, path: thread.workspacePath)]
        self.thread = thread; peer = .init(thread: thread)
    }
    var target: RemoteWorkspaceTarget { .init(environmentID: environmentID, projectID: thread.projectID, threadID: thread.id, configuration: .init(thread: thread)) }
    var run: ThreadRunRecord { thread.runHistory![0] }
    func model() throws -> RemoteCheckpointWorkspace { try #require(store.current) }
    func update(canWrite: Bool = true, canMutate: Bool = true) async {
        await peer.update(thread)
        await store.select(target: target, thread: thread, snapshot: snapshot, transport: peer.transport, supported: true,
            canWrite: canWrite, canMutate: canMutate, perform: { [self] command in commands.append(command); return accepted }, canRestore: { [self] _ in allowRestore })
    }
    static func attempt(path: String, later: Bool = false) throws -> ThreadRunCheckpointAttempt {
        let id = UUID(), identity = GitWorktreeNodeIdentity(device: 1, inode: 42)
        let plan = try GitCheckpointPlan(id: id, workspacePath: path, repositoryPath: path, gitDirectoryPath: path + "/.git", commonDirectoryPath: path + "/.git",
            workspaceIdentity: identity, repositoryIdentity: identity, gitDirectoryIdentity: identity, commonDirectoryIdentity: identity,
            objectDirectoryIdentity: identity, headCommit: String(repeating: "a", count: 40), configurationDigest: String(repeating: "b", count: 64), indexRevision: nil)
        var value = ThreadRunCheckpointAttempt(id: id, workspacePath: path, phase: .ready, isLaterObservation: later)
        value.plan = plan; value.receipt = try .init(plan: plan, commit: String(repeating: "c", count: 40), tree: String(repeating: "d", count: 40)); return value
    }
    static func record(thread: CodingThread, path: String) throws -> ThreadRunRecord {
        var configuration = ProviderConfiguration(thread: thread); configuration.workspacePath = path
        var value = ThreadRunRecord(run: .init(id: UUID(), configuration: configuration, startedAt: Date()), origin: .legacy)
        value.status = .completed; value.endedAt = Date()
        var saved = ThreadRunCheckpoints(baseline: try attempt(path: path), providerReleased: true)
        saved.previousPostRunAttempts = [try attempt(path: path, later: true)]; saved.postRun = try attempt(path: path)
        value.checkpoints = saved; return value
    }
    func finish() async { await store.shutdown() }
}

@MainActor private func remoteCheckpointEventually(_ predicate: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !predicate() { guard ContinuousClock.now < deadline else { throw CoincideError("The owned checkpoint fixture did not reach its expected boundary.") }; await Task.yield() }
}

@Test(.timeLimit(.minutes(1))) @MainActor
func remoteCheckpointMetadataSelectionReadsNothingAndHostInventoryPreservesHistoricalWorktreeReasons() async throws {
    let f = try RemoteCheckpointFixture()
    let historicalRecord = try RemoteCheckpointFixture.record(thread: f.thread, path: "/remote-only/old-worktree")
    f.thread.runHistory?.append(historicalRecord)
    await f.update(); let model = try f.model()
    #expect(await f.peer.counts() == [0, 0, 0, 0])
    await model.refresh(); let root = try #require(model.target.rootID)
    #expect(model.inventory?.runs.count == 2 && model.policy == .automatic)
    let historical = try #require(f.thread.runHistory?.last), old = try #require(historical.checkpoints?.baseline)
    #expect(model.restoreUnavailableReason(runID: historical.id, stage: .baseline, attemptID: old.id) == "This checkpoint belongs to an earlier remote worktree.")
    await f.update(); #expect(model.target.rootID == root && f.commands.isEmpty)
    await f.finish()
}

@Test(.timeLimit(.minutes(1))) @MainActor
func remoteCheckpointDiffRejectsChangedExactPostAttemptAndPreservesRemoteDraft() async throws {
    let f = try RemoteCheckpointFixture(), gate = RemoteCheckpointBoundary()
    await f.update(); let model = try f.model(); await model.refresh()
    await f.peer.holdDiff(gate)
    let loading = Task { await model.loadDiff(runID: f.run.id) }; await gate.entered()
    f.thread.runHistory![0].checkpoints!.postRun = try RemoteCheckpointFixture.attempt(path: f.thread.workspacePath, later: true)
    await f.update(); await gate.release(); await loading.value
    #expect(model.diff == nil && f.commands.isEmpty && f.thread.draft == "Keep this unsent remote draft")
    await model.loadDiff(runID: f.run.id)
    #expect(model.diff?.postRunAttemptID == f.run.checkpoints?.postRun?.id && model.diff?.truncated == true)
    await f.finish()
}

@Test(.timeLimit(.minutes(1))) @MainActor
func remoteCheckpointRestoreReviewIsReadOnlyAndDirtyPreflightPreventsApplyWithoutClearingDraft() async throws {
    let f = try RemoteCheckpointFixture()
    await f.update(); let model = try f.model(); await model.refresh()
    let attempt = try #require(f.run.checkpoints?.baseline)
    await model.prepareRestore(runID: f.run.id, stage: .baseline, attemptID: attempt.id)
    let review = try #require(model.restoreReview)
    #expect(f.commands.isEmpty && model.canApply && f.store.review(id: review.id) == review)
    f.allowRestore = false; await model.applyRestore(); #expect(f.commands.isEmpty && !model.canApply)
    f.allowRestore = true; await model.applyRestore()
    #expect(f.commands == [.checkpoint(target: review.target, action: .beginRestore(reviewID: review.id, digest: review.digest))])
    await f.update(canWrite: false); await model.applyRestore(); #expect(f.commands.count == 1)
    f.store.disconnect(); await f.finish()
    #expect(await f.peer.discards().isEmpty)
    #expect(f.thread.draft == "Keep this unsent remote draft")
}

@Test(.timeLimit(.minutes(1))) @MainActor
func remoteCheckpointUnusedReviewDisposalIsRegisteredBeforeSelectionAndShutdownWaitsForCapturedCleanup() async throws {
    let f = try RemoteCheckpointFixture(), gate = RemoteCheckpointBoundary()
    await f.update(); let model = try f.model(); await model.refresh()
    let attempt = try #require(f.run.checkpoints?.baseline)
    await model.prepareRestore(runID: f.run.id, stage: .baseline, attemptID: attempt.id)
    let review = try #require(model.restoreReview)
    await f.peer.holdDiscard(gate); f.store.clearSelection()
    var began = false, finished = false
    let closing = Task { began = true; await f.store.shutdown(); finished = true }
    await gate.entered(); try await remoteCheckpointEventually { began }
    #expect(!finished && model.restoreReview == nil)
    await gate.release(); await closing.value
    let discarded = await f.peer.discards()
    #expect(discarded == [.init(target: review.target, reviewID: review.id, digest: review.digest)] && finished && f.commands.isEmpty)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func remoteCheckpointLateReviewAfterConfigurationChangeIsDisposedEvenAfterDisconnectWithoutApplying() async throws {
    let f = try RemoteCheckpointFixture(), gate = RemoteCheckpointBoundary()
    await f.update(); let model = try f.model(); await model.refresh()
    let attempt = try #require(f.run.checkpoints?.baseline)
    await f.peer.holdReview(gate)
    let preparing = Task { await model.prepareRestore(runID: f.run.id, stage: .baseline, attemptID: attempt.id) }; await gate.entered()
    f.thread.model += "-changed"; await f.update(); f.store.disconnect()
    let closing = Task { await f.store.shutdown() }
    await gate.release(); await preparing.value; await closing.value
    let value = try #require(await f.peer.lastReview()), discarded = await f.peer.discards()
    #expect(discarded == [.init(target: value.target, reviewID: value.id, digest: value.digest)] && model.restoreReview == nil && f.commands.isEmpty)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func remoteCheckpointColdAcknowledgementNeedsNoFolderButInspectionBindsExactPhysicalRoot() async throws {
    let f = try RemoteCheckpointFixture()
    let attempt = try #require(f.run.checkpoints?.baseline)
    let wrapper = try await f.peer.makeReview(.init(target: f.target, runID: f.run.id, stage: .baseline, attemptID: attempt.id))
    f.snapshot.checkpointRestoreOperations = [.init(review: wrapper.value, phase: .unconfirmed, error: RunCheckpointRestoreOperation.unconfirmedMessage)]
    await f.peer.setFailBind(true); await f.update(); let model = try f.model()
    await model.recover(wrapper.id, acknowledge: true)
    #expect(f.commands == [.checkpoint(target: f.target, action: .acknowledgeRestore(operationID: wrapper.id))])
    #expect(await f.peer.counts() == [0, 0, 0, 0])
    await model.recover(wrapper.id); #expect(f.commands.count == 1)
    await f.peer.setFailBind(false); await model.recover(wrapper.id)
    guard case .checkpoint(let bound, .inspectRestore(let id)) = try #require(f.commands.last) else { Issue.record("Expected bound inspection"); await f.finish(); return }
    #expect(bound.rootID != nil && id == wrapper.id)
    await f.finish()
}

@Test(.timeLimit(.minutes(1))) @MainActor
func remoteCheckpointRetryContinueUseOnlyHeldExactAttemptAndAcceptedRestoreReviewIsConsumed() async throws {
    let f = try RemoteCheckpointFixture()
    await f.update(); let model = try f.model(); await model.refresh()
    let attempt = try #require(f.run.checkpoints?.baseline)
    await model.prepareRestore(runID: f.run.id, stage: .baseline, attemptID: attempt.id)
    let review = try #require(model.restoreReview); f.accepted = true; await model.applyRestore(); await model.applyRestore()
    #expect(model.restoreReview == nil && f.commands == [.checkpoint(target: review.target, action: .beginRestore(reviewID: review.id, digest: review.digest))])
    var failed = ThreadRunCheckpointAttempt(workspacePath: f.thread.workspacePath, phase: .failed); failed.error = ThreadRunCheckpointAttempt.failureMessage
    f.thread.runHistory![0].checkpoints!.postRun = failed; await f.update()
    await model.retryPostRun(runID: f.run.id, attemptID: UUID()); #expect(f.commands.count == 1)
    await model.retryPostRun(runID: f.run.id, attemptID: failed.id)
    #expect(f.commands.last == .checkpoint(target: model.target, action: .retryPostRun(runID: f.run.id, attemptID: failed.id)))
    await model.continuePostRun(runID: f.run.id, attemptID: failed.id)
    #expect(f.commands.last == .checkpoint(target: model.target, action: .continuePostRun(runID: f.run.id, attemptID: failed.id)))
    await f.update(canWrite: false); await model.continuePostRun(runID: f.run.id, attemptID: failed.id)
    #expect(f.commands.count == 3 && f.thread.draft == "Keep this unsent remote draft")
    await f.finish()
}

@Test(.timeLimit(.minutes(1))) @MainActor
func remoteCheckpointOffscreenSheetRestoreAndRecoveryFitSmallBoundsWithoutImplicitRPCOrApply() async throws {
    _ = NSApplication.shared
    let f = try RemoteCheckpointFixture()
    await f.update(); let model = try f.model(); await model.refresh()
    let checkpoint = try #require(f.run.checkpoints?.baseline)
    await model.prepareRestore(runID: f.run.id, stage: .baseline, attemptID: checkpoint.id)
    let review = try #require(model.restoreReview)
    #expect(review.value.gitReview.affectedPaths == ["notes.txt", "added.txt"] && review.value.gitReview.previewTruncated)
    let before = await f.peer.counts()
    for scheme in [ColorScheme.light, .dark] {
        for bounds in [CGSize(width: 480, height: 560), CGSize(width: 640, height: 680)] {
            let views: [AnyView] = [
                AnyView(RemoteRunCheckpointHistoryContent(model: model, refresh: { Issue.record("Layout cannot refresh inventory") },
                    showWorkspaceChanges: { _ in Issue.record("Layout cannot request a diff") }, restore: { _, _, _ in Issue.record("Layout cannot request restoration") })),
                AnyView(RemoteCheckpointRestorePresentationContent(model: model, runID: f.run.id, stage: .baseline, attemptID: checkpoint.id,
                    confirm: { Issue.record("Layout cannot apply a checkpoint") },
                    close: { Issue.record("Layout cannot close the captured review") }))
            ]
            for view in views { remoteCheckpointLayoutWithoutWindow(view.environment(\.colorScheme, scheme), bounds: bounds) }
        }
    }
    let uncertain = RunCheckpointRestoreOperation(review: review.value, phase: .unconfirmed, error: RunCheckpointRestoreOperation.unconfirmedMessage)
    f.snapshot.checkpointRestoreOperations = [uncertain]; await f.update(canMutate: false)
    for scheme in [ColorScheme.light, .dark] {
        remoteCheckpointLayoutWithoutWindow(ScrollView {
            RemoteCheckpointRestoreOperationView(model: model, operation: uncertain).padding(12)
        }.environment(\.colorScheme, scheme), bounds: CGSize(width: 480, height: 560))
    }
    let after = await f.peer.counts()
    #expect(after == before)
    #expect(f.commands.isEmpty && f.thread.draft == "Keep this unsent remote draft" && !model.canApply)
    await f.finish()
}

@MainActor private func remoteCheckpointLayoutWithoutWindow<Content: View>(_ content: Content, bounds: CGSize) {
    let hosting = NSHostingController(rootView: content)
    let fitted = hosting.sizeThatFits(in: bounds)
    #expect(fitted.width.isFinite && fitted.height.isFinite && fitted.width > 0 && fitted.height > 0)
    #expect(fitted.width <= bounds.width + 1 && fitted.height <= bounds.height + 1)
    hosting.view.frame = CGRect(origin: .zero, size: fitted); hosting.view.layoutSubtreeIfNeeded()
    #expect(hosting.view.window == nil && hosting.view.bounds.width > 0 && hosting.view.bounds.height > 0)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func remoteCheckpointCancelledPaneDisposesLateReviewAndStalePaneCannotClearNewerReviewInFlightOrReady() async throws {
    let f = try RemoteCheckpointFixture(), cancelledGate = RemoteCheckpointBoundary(), replacementGate = RemoteCheckpointBoundary()
    var preparing: Task<Void, Never>?
    do {
        await f.update(); let model = try f.model(); await model.refresh()
        let attempt = try #require(f.run.checkpoints?.baseline)
        await f.peer.holdReview(cancelledGate)
        preparing = Task { _ = await model.prepareRestore(runID: f.run.id, stage: .baseline, attemptID: attempt.id) }
        await cancelledGate.entered()
        let cancelled = try #require(await f.peer.lastReview())
        preparing?.cancel(); await cancelledGate.release(); await preparing?.value
        #expect(model.restoreReview == nil)
        await model.prepareRestore(runID: f.run.id, stage: .baseline, attemptID: attempt.id)
        let first = try #require(model.restoreReview)
        await f.peer.holdReview(replacementGate)
        preparing = Task { _ = await model.prepareRestore(runID: f.run.id, stage: .baseline, attemptID: attempt.id) }
        await replacementGate.entered()
        model.clearReview(id: first.id)
        await replacementGate.release(); await preparing?.value
        let replacement = try #require(model.restoreReview)
        #expect(replacement.id != first.id && model.canApply)
        model.clearReview(id: first.id); #expect(model.restoreReview?.id == replacement.id && model.canApply)
        await model.drainReads()
        let discarded = await f.peer.discards()
        #expect(Set(discarded.map(\.reviewID)) == Set([cancelled.id, first.id]))
        #expect(!discarded.contains { $0.reviewID == replacement.id } && f.commands.isEmpty)
        await f.finish()
    } catch {
        await cancelledGate.release(); await replacementGate.release(); await preparing?.value; await f.finish(); throw error
    }
}
