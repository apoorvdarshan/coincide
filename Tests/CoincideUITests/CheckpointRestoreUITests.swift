import AppKit
import CSQLite
import SwiftUI
import Testing
@testable import Coincide
@testable import CoincideCore

private actor NativeRestorePeer {
    let path: URL
    private var pending: CheckedContinuation<GitCheckpointRestoreReceipt, any Error>?
    private var review: GitCheckpointRestoreReview?
    private(set) var starts = 0
    private(set) var inspections = 0
    init(path: URL) { self.path = path }
    func review(target: GitCheckpointReceipt, id: UUID) throws -> GitCheckpointRestoreReview {
        try .init(id: id, targetReceipt: target, currentPlan: target.plan, manifestDigest: String(repeating: "e", count: 64),
                  affectedPaths: ["notes.txt", "new.txt"], previewPatch: "--- a/notes.txt\n+++ b/notes.txt\n@@ -1 +1 @@\n-current\n+saved\n", previewTruncated: true)
    }
    func restore(_ review: GitCheckpointRestoreReview) async throws -> GitCheckpointRestoreReceipt {
        starts += 1; self.review = review
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { pending = $0 }
        } onCancel: { Task { await self.cancel() } }
    }
    func finish(uncertain: Bool = false) throws {
        let pending = try #require(pending), review = try #require(review)
        self.pending = nil
        try Data("saved\n".utf8).write(to: path.appendingPathComponent("notes.txt"))
        try FileManager.default.removeItem(at: path.appendingPathComponent("new.txt"))
        if uncertain { pending.resume(throwing: GitCheckpointRestoreError(.interrupted, mayHaveMutated: true)) }
        else { pending.resume(returning: try .init(review: review, stateDigest: String(repeating: "f", count: 64))) }
    }
    func inspect() -> GitCheckpointRestoreInspection { inspections += 1; return .interrupted }
    func cancel() { pending?.resume(throwing: CancellationError()); pending = nil }
}

private struct NativeRestoreSession: RunCheckpointSession {
    let peer: NativeRestorePeer
    func prepare(id: UUID) async throws -> GitCheckpointPlan { throw GitCheckpointError(.commandFailed) }
    func capture(_ plan: GitCheckpointPlan) async throws -> GitCheckpointReceipt { throw GitCheckpointError(.commandFailed) }
    func inspect(_ plan: GitCheckpointPlan) async throws -> GitCheckpointInspection { .missing }
    func finalizeScratch(_ receipt: GitCheckpointReceipt) async throws -> GitCheckpointScratchResult { .removed }
    func diff(from: GitCheckpointReceipt, to: GitCheckpointReceipt, paths: [String]?, ignoreWhitespace: Bool, maxBytes: Int) async throws -> GitCheckpointDiff { .init(patch: "", truncated: false) }
    func reviewRestore(target: GitCheckpointReceipt, id: UUID) async throws -> GitCheckpointRestoreReview { try await peer.review(target: target, id: id) }
    func restore(review: GitCheckpointRestoreReview) async throws -> GitCheckpointRestoreReceipt { try await peer.restore(review) }
    func inspectRestore(review: GitCheckpointRestoreReview) async throws -> GitCheckpointRestoreInspection { await peer.inspect() }
}

/// Deliberately returns a held, already-read document even after cancellation.
/// The editor must reject it by ownership, rather than trusting cancellation.
private actor NativeRestoreDocumentGate {
    let service: WorkspaceFileService
    private var holdNext = false
    private var pending: CheckedContinuation<Void, Never>?
    private(set) var heldReads = 0
    private(set) var cancellationObserved = false
    init(service: WorkspaceFileService) { self.service = service }
    func arm() { holdNext = true; cancellationObserved = false }
    func read(_ path: String) async throws -> WorkspaceTextDocument {
        let hold = holdNext; holdNext = false
        let value = try await service.readFile(relativePath: path)
        guard hold else { return value }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { pending = $0; heldReads += 1 }
            return value
        } onCancel: { Task { await self.cancelled() } }
    }
    private func cancelled() { cancellationObserved = true }
    func release() { let continuation = pending; pending = nil; continuation?.resume() }
}

@MainActor private struct NativeRestoreFixture {
    let root: URL, checkout: URL, database: URL
    let store: WorkspaceStore
    let peer: NativeRestorePeer
    let threadID: UUID, runID: UUID, baselineID: UUID, priorID: UUID
    static func make() async throws -> Self {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-native-restore-" + UUID().uuidString).resolvingSymlinksInPath()
        let projectRoot = root.appendingPathComponent("Project"), checkout = root.appendingPathComponent("Isolated checkout")
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        do {
            try Data("current\n".utf8).write(to: checkout.appendingPathComponent("notes.txt"))
            try Data("new unsaved on disk\n".utf8).write(to: checkout.appendingPathComponent("new.txt"))
            let project = WorkspaceProject(path: projectRoot.path)
            var thread = CodingThread(project: project, model: "current-model")
            thread.workspacePath = checkout.path; thread.draft = "Keep this current draft"; thread.permission = .auto
            func attempt(later: Bool = false) throws -> ThreadRunCheckpointAttempt {
                var attempt = ThreadRunCheckpointAttempt(workspacePath: checkout.path, phase: .ready, isLaterObservation: later)
                let node = GitWorktreeNodeIdentity(device: 1, inode: 42)
                let plan = try GitCheckpointPlan(id: attempt.id, workspacePath: checkout.path, repositoryPath: checkout.path,
                    gitDirectoryPath: checkout.path + "/.git", commonDirectoryPath: checkout.path + "/.git",
                    workspaceIdentity: node, repositoryIdentity: node, gitDirectoryIdentity: node, commonDirectoryIdentity: node,
                    objectDirectoryIdentity: node, headCommit: String(repeating: "a", count: 40), configurationDigest: String(repeating: "b", count: 64), indexRevision: nil)
                attempt.plan = plan; attempt.receipt = try .init(plan: plan, commit: String(repeating: "c", count: 40), tree: String(repeating: "d", count: 40))
                return attempt
            }
            let baseline = try attempt(), prior = try attempt(later: true)
            var checkpoints = ThreadRunCheckpoints(baseline: baseline, providerReleased: true)
            checkpoints.previousPostRunAttempts = [prior]
            checkpoints.postRun = .init(workspacePath: checkout.path, phase: .failed)
            checkpoints.postRun?.error = ThreadRunCheckpointAttempt.failureMessage
            let run = ActiveRun(id: UUID(), configuration: .init(thread: thread), startedAt: Date(), nativeTurnID: nil)
            var record = ThreadRunRecord(run: run, origin: .user, userMessageID: "original")
            record.status = .completed; record.endedAt = Date(); record.endReason = .providerCompleted; record.checkpoints = checkpoints
            thread.messages = [.init(id: "original", role: .user, text: "Recorded input")]; thread.runHistory = [record]
            thread.queuePaused = true
            var snapshot = WorkspaceSnapshot(); snapshot.projects = [project]; snapshot.threads = [thread]
            let database = root.appendingPathComponent("workspace.sqlite")
            _ = try await WorkspaceDatabase(url: database).commit(snapshot, event: "native-restore-fixture", commandID: UUID())
            let peer = NativeRestorePeer(path: checkout)
            let store = try makeStore(database: database, peer: peer); await store.load()
            return .init(root: root, checkout: checkout, database: database, store: store, peer: peer,
                         threadID: thread.id, runID: run.id, baselineID: baseline.id, priorID: prior.id)
        } catch { try? FileManager.default.removeItem(at: root); throw error }
    }
    static func makeStore(database: URL, peer: NativeRestorePeer) throws -> WorkspaceStore {
        WorkspaceStore(engine: try .init(url: database, providerFactory: { _ in throw CoincideError("No provider may be started by file restoration.") },
            identityResolver: { _ in nil }, checkpointFactory: { _ in NativeRestoreSession(peer: peer) }))
    }
    func review(prior: Bool = false) async throws -> RunCheckpointRestoreReview {
        try await store.reviewCheckpointRestore(threadID: threadID, runID: runID, stage: prior ? .postRun : .baseline, expectedAttemptID: prior ? priorID : baselineID)
    }
    func cleanup() async { await peer.cancel(); await store.shutdown(); try? FileManager.default.removeItem(at: root) }
}

@MainActor private func waitNativeRestore(file: StaticString = #fileID, line: UInt = #line, _ condition: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while try await !condition() {
        guard ContinuousClock.now < deadline else { Issue.record("Native restoration did not reach the expected boundary.", sourceLocation: .init(fileID: String(describing: file), filePath: String(describing: file), line: Int(line), column: 1)); throw CancellationError() }
        try await Task.sleep(for: .milliseconds(10))
    }
}

@MainActor @Test(.timeLimit(.minutes(1)), arguments: [false, true])
func nativeRestoreBridgesAcceptanceLocksEveryWindowAndRefreshesCleanFilesWithoutChangingConversation(deletedDocument: Bool) async throws {
    let f = try await NativeRestoreFixture.make(), store = f.store
    var writer: OpaquePointer?, locked = false
    func releaseWriter() { if locked { sqlite3_exec(writer, "ROLLBACK", nil, nil, nil); locked = false } }
    defer { releaseWriter(); if let writer { sqlite3_close(writer) } }
    do {
        let browser = try store.fileBrowser(path: f.checkout.path)
        #expect(await browser.open(deletedDocument ? "new.txt" : "notes.txt"))
        let source = try #require(store.thread(f.threadID)), review = try await f.review()
        #expect(sqlite3_open(f.database.path, &writer) == SQLITE_OK)
        sqlite3_busy_timeout(writer, 5_000)
        #expect(sqlite3_exec(writer, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK); locked = true
        let begin = Task { try await store.beginCheckpointRestore(review) }
        try await waitNativeRestore { !store.canEditWorkspace(f.checkout.path) }
        #expect(store.snapshot.checkpointRestoreOperation(review.id) == nil, "The App bridge locks files before SQLite accepts durable intent.")
        #expect(!store.canEditWorkspace(f.checkout.appendingPathComponent("nested").path))
        #expect(!browser.canWrite && !store.canOpenTerminal(for: source))
        store.setDraft("Latest draft while files are locked", id: source.id)
        #expect(await store.submit("Must not send or clear the draft", threadID: source.id).value == false)
        #expect(store.thread(source.id)?.draft == "Latest draft while files are locked")
        releaseWriter(); try await begin.value
        try await waitNativeRestore { await f.peer.starts == 1 }
        #expect(store.isCheckpointRestoreLocked(threadID: source.id))
        let git = store.gitInspector(path: f.checkout.path); git.stage(["notes.txt"])
        #expect(git.operationName == nil, "A previously open Git sheet cannot mutate during restoration.")
        try await f.peer.finish()
        try await waitNativeRestore {
            store.snapshot.checkpointRestoreOperation(review.id)?.phase == .applied &&
                (deletedDocument ? browser.document == nil : browser.contents == "saved\n")
        }
        let current = try #require(store.thread(source.id))
        #expect(current.messages == source.messages && current.runHistory == source.runHistory)
        #expect(current.model == source.model && current.permission == source.permission && current.providerThreadID == source.providerThreadID)
        #expect(current.draft == "Latest draft while files are locked" && current.queuePaused)
        #expect(store.canEditWorkspace(f.checkout.path))
        #expect(browser.canWrite == !deletedDocument)
        if deletedDocument { #expect(browser.contents.isEmpty && browser.operationError != nil) }
        #expect(!FileManager.default.fileExists(atPath: f.checkout.appendingPathComponent("new.txt").path))
        #expect(await f.peer.starts == 1)
    } catch { releaseWriter(); await f.cleanup(); throw error }
    await f.cleanup()
}

@MainActor @Test(.timeLimit(.minutes(1)))
func nativeRestoreBlocksDirtyEditorsAndOtherWindowTerminalsThenRetainsUnknownOutcomeAcrossRestartUntilExplicitKeep() async throws {
    let f = try await NativeRestoreFixture.make(), store = f.store
    let terminals = TerminalWorkspaceStore(executable: "/bin/sh", loginShell: false); store.registerTerminals(terminals)
    do {
        let browser = try store.fileBrowser(path: f.checkout.path)
        #expect(await browser.open("notes.txt")); browser.setContents("Unsaved editor input")
        #expect(store.checkpointRestoreUnavailableReason(threadID: f.threadID, runID: f.runID, stage: .baseline, expectedAttemptID: f.baselineID)?.contains("unsaved") == true)
        await #expect(throws: CancellationError.self) { try await f.review() }
        #expect(await browser.open("notes.txt", discardChanges: true))
        try terminals.add(for: #require(store.thread(f.threadID)))
        #expect(store.checkpointRestoreUnavailableReason(threadID: f.threadID, runID: f.runID, stage: .baseline, expectedAttemptID: f.baselineID)?.contains("terminals") == true)
        for session in terminals.removeAll() { await session.waitForClose() }
        let review = try await f.review(prior: true)
        #expect(review.attemptID == f.priorID && review.checkpoint.isLaterObservation)
        try await store.beginCheckpointRestore(review)
        try await waitNativeRestore { await f.peer.starts == 1 }
        try await f.peer.finish(uncertain: true)
        try await waitNativeRestore { store.snapshot.checkpointRestoreOperation(review.id)?.phase == .unconfirmed }
        #expect(!browser.canWrite && !store.canEditWorkspace(f.checkout.path))
        await store.shutdown()
        let reopened = try NativeRestoreFixture.makeStore(database: f.database, peer: f.peer); await reopened.load()
        do {
            #expect(reopened.isCheckpointRestoreLocked(threadID: f.threadID))
            #expect(await f.peer.starts == 1, "Restart never repeats a potentially partial file restore.")
            try await reopened.inspectCheckpointRestore(review.id)
            #expect(reopened.isCheckpointRestoreLocked(threadID: f.threadID))
            #expect(await f.peer.inspections == 1)
            #expect(await f.peer.starts == 1)
            let currentBrowser = try? reopened.fileBrowser(path: f.checkout.path)
            #expect(currentBrowser == nil)
            try await reopened.acknowledgeCheckpointRestore(review.id)
            #expect(!reopened.isCheckpointRestoreLocked(threadID: f.threadID))
            #expect(reopened.snapshot.checkpointRestoreOperation(review.id)?.acknowledgedAt != nil)
            #expect(reopened.thread(f.threadID)?.draft == "Keep this current draft")
            #expect(await f.peer.starts == 1)
            await reopened.shutdown()
        } catch { await reopened.shutdown(); throw error }
    } catch { for session in terminals.removeAll() { await session.waitForClose() }; await f.cleanup(); throw error }
    await f.cleanup()
}

@MainActor @Test(.timeLimit(.minutes(1)))
func nativeRestoreCacheStaysReadOnlyUntilFreshReadAndRejectsAnOlderCancelledRead() async throws {
    let f = try await NativeRestoreFixture.make()
    let service = try f.store.fileService(path: f.checkout.path), gate = NativeRestoreDocumentGate(service: service)
    let browser = FileBrowserStore(workspace: f.store, path: f.checkout.path, service: service, documentLoader: { try await gate.read($0) })
    do {
        #expect(await browser.open("notes.txt"))
        try Data("restored bytes\n".utf8).write(to: f.checkout.appendingPathComponent("notes.txt"))
        browser.suspendForWorkspaceMutation(); await gate.arm()
        let refresh = Task { await browser.refreshAfterWorkspaceMutation() }
        try await waitNativeRestore { await gate.heldReads == 1 }
        #expect(browser.contents == "current\n" && !browser.canWrite)
        browser.setContents("Typing must not make old bytes editable")
        #expect(browser.contents == "current\n" && !browser.isDirty)
        await gate.release(); await refresh.value
        #expect(browser.contents == "restored bytes\n" && browser.canWrite)

        browser.suspendForWorkspaceMutation(); await gate.arm()
        let olderRefresh = Task { await browser.refreshAfterWorkspaceMutation() }
        try await waitNativeRestore { await gate.heldReads == 2 }
        try Data("newer selected bytes\n".utf8).write(to: f.checkout.appendingPathComponent("notes.txt"))
        let newerRead = Task { await browser.open("notes.txt") }
        try await waitNativeRestore { await gate.cancellationObserved }
        await gate.release(); await olderRefresh.value
        #expect(await newerRead.value)
        #expect(browser.contents == "newer selected bytes\n" && browser.canWrite && !browser.isDirty)
        await browser.shutdown()
    } catch { await gate.release(); await browser.shutdown(); await f.cleanup(); throw error }
    await f.cleanup()
}

@MainActor @Test
func nativeRestoreReviewFitsSmallSheetsAndExposesReadyBaselineWithoutSuccessfulPost() async throws {
    _ = NSApplication.shared
    let f = try await NativeRestoreFixture.make()
    do {
        let review = try await f.review(), thread = try #require(f.store.thread(f.threadID)), record = try #require(thread.runHistory?.first)
        #expect(RunCheckpointRestorePresentation.targets(record).map(\.id) == [f.baselineID])
        #expect(!RunCheckpointPresentation.canShowDiff(try #require(record.checkpoints)))
        for scheme in [ColorScheme.light, .dark] {
            for width in [CGFloat(320), 680] {
                let operation = RunCheckpointRestoreOperation(review: review, phase: .unconfirmed, error: RunCheckpointRestoreOperation.unconfirmedMessage)
                let views: [(String, AnyView)] = [
                    ("review", AnyView(RunCheckpointRestoreContent(review: review, stage: .baseline, loading: false, accepting: false, error: nil, operation: nil, confirm: {}, close: {}) { EmptyView() })),
                    ("unconfirmed", AnyView(RunCheckpointRestoreOperationView(store: f.store, operation: operation)))
                ]
                for (name, view) in views {
                    let content = view.environment(\.colorScheme, scheme)
                    let controller = NSHostingController(rootView: content)
                    let size = controller.sizeThatFits(in: CGSize(width: width, height: 740))
                    #expect(size.width <= width + 1 && size.height <= 740)
                    try await captureNativeRestore(content, name: name, width: width, height: max(220, size.height), scheme: scheme)
                }
            }
        }
    } catch { await f.cleanup(); throw error }
    await f.cleanup()
}

@MainActor private func captureNativeRestore<Content: View>(_ content: Content, name: String, width: CGFloat, height: CGFloat, scheme: ColorScheme) async throws {
    guard ProcessInfo.processInfo.environment["COINCIDE_RENDER_RESTORE"] == "1" else { return }
    let appearance = try #require(NSAppearance(named: scheme == .light ? .aqua : .darkAqua))
    let hosting = NSHostingView(rootView: content.background(Color(nsColor: .windowBackgroundColor)).frame(width: width, height: height))
    let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: width, height: height), styleMask: .borderless, backing: .buffered, defer: false)
    window.appearance = appearance; hosting.appearance = appearance; window.isReleasedWhenClosed = false; window.contentView = hosting
    defer { window.close() }
    hosting.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(100)); hosting.layoutSubtreeIfNeeded()
    let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
    appearance.performAsCurrentDrawingAppearance { hosting.cacheDisplay(in: hosting.bounds, to: bitmap) }
    let data = try #require(bitmap.representation(using: .png, properties: [:]))
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-restore-\(name)-\(Int(width))-\(scheme == .light ? "light" : "dark").png")
    try data.write(to: path); print("Restore preview: \(path.path)")
}
