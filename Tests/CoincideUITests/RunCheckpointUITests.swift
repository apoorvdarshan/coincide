import AppKit
import SwiftUI
import Testing
@testable import Coincide
@testable import CoincideCore

private actor NativeCheckpointProvider: ProviderSession {
    nonisolated let events: AsyncStream<ProviderEvent>
    private let sink: AsyncStream<ProviderEvent>.Continuation
    private var runID: UUID?
    private(set) var prompts: [String] = []
    init() { let pair = AsyncStream<ProviderEvent>.makeStream(); events = pair.stream; sink = pair.continuation }
    func models() -> [ProviderModel] { [] }
    func send(text: String, thread: CodingThread) { runID = thread.activeRun?.id; prompts.append(text) }
    func finish() { if let runID { sink.yield(.context(runID: runID, event: .completed(.idle))) } }
    func interrupt() { if let runID { sink.yield(.context(runID: runID, event: .completed(.interrupted))) } }
    func respond(_ request: ApprovalRequest, allow: Bool) { }
    func answer(_ request: ApprovalRequest, answers: [String: String]) { }
    func close() { sink.finish() }
}

private actor NativeCheckpointCapture {
    private var waiting: [UUID: CheckedContinuation<GitCheckpointReceipt, any Error>] = [:]
    private var plans: [UUID: GitCheckpointPlan] = [:]
    private(set) var captureIDs: [UUID] = []
    private(set) var diffLimit: Int?
    func prepare(id: UUID, root: URL) throws -> GitCheckpointPlan {
        let identity = GitWorktreeNodeIdentity(device: 1, inode: 42)
        let plan = try GitCheckpointPlan(id: id, workspacePath: root.path, repositoryPath: root.path,
            gitDirectoryPath: root.path + "/.git", commonDirectoryPath: root.path + "/.git",
            workspaceIdentity: identity, repositoryIdentity: identity, gitDirectoryIdentity: identity,
            commonDirectoryIdentity: identity, objectDirectoryIdentity: identity,
            headCommit: String(repeating: "a", count: 40), configurationDigest: String(repeating: "b", count: 64), indexRevision: nil)
        plans[id] = plan; return plan
    }
    func capture(_ plan: GitCheckpointPlan) async throws -> GitCheckpointReceipt {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                captureIDs.append(plan.id); waiting[plan.id] = continuation
            }
        } onCancel: { Task { await self.cancel(plan.id) } }
    }
    func complete(_ id: UUID, failure: Bool = false) throws {
        let continuation = waiting.removeValue(forKey: id)
        if failure { continuation?.resume(throwing: GitCheckpointError(.commandFailed)) }
        else {
            let plan = try #require(plans[id])
            let receipt = try GitCheckpointReceipt(plan: plan, commit: String(repeating: "c", count: 40), tree: String(repeating: "d", count: 40))
            continuation?.resume(returning: receipt)
        }
    }
    func cancel(_ id: UUID) { waiting.removeValue(forKey: id)?.resume(throwing: CancellationError()) }
    func cancelAll() { for id in Array(waiting.keys) { cancel(id) } }
    func diff(maxBytes: Int) -> GitCheckpointDiff {
        diffLimit = maxBytes
        return .init(patch: "diff --git a/notes.txt b/notes.txt\n--- a/notes.txt\n+++ b/notes.txt\n@@ -1 +1 @@\n-before\n+after\n", truncated: true)
    }
}

private struct NativeCheckpointSession: RunCheckpointSession {
    let root: URL
    let capturePeer: NativeCheckpointCapture
    func prepare(id: UUID) async throws -> GitCheckpointPlan { try await capturePeer.prepare(id: id, root: root) }
    func capture(_ plan: GitCheckpointPlan) async throws -> GitCheckpointReceipt { try await capturePeer.capture(plan) }
    func inspect(_ plan: GitCheckpointPlan) async throws -> GitCheckpointInspection { .missing }
    func finalizeScratch(_ receipt: GitCheckpointReceipt) async throws -> GitCheckpointScratchResult { .removed }
    func diff(from: GitCheckpointReceipt, to: GitCheckpointReceipt, paths: [String]?, ignoreWhitespace: Bool,
              maxBytes: Int) async throws -> GitCheckpointDiff { await capturePeer.diff(maxBytes: maxBytes) }
}

@MainActor private struct NativeCheckpointFixture {
    let root: URL, database: URL
    let threadID: UUID
    let store: WorkspaceStore
    let capturePeer: NativeCheckpointCapture
    let provider: NativeCheckpointProvider
    static func make() async throws -> Self {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-native-checkpoints-" + UUID().uuidString)
            .resolvingSymlinksInPath()
        let source = root.appendingPathComponent("Synthetic checkout")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        do {
            let project = WorkspaceProject(path: source.path)
            let thread = CodingThread(project: project)
            var snapshot = WorkspaceSnapshot(); snapshot.projects = [project]; snapshot.threads = [thread]
            let database = root.appendingPathComponent("workspace.sqlite")
            _ = try await WorkspaceDatabase(url: database).commit(snapshot, event: "fixture", commandID: UUID())
            let capturePeer = NativeCheckpointCapture(), provider = NativeCheckpointProvider()
            let engine = try WorkspaceEngine(url: database, providerFactory: { _ in provider }, identityResolver: { _ in nil },
                checkpointFactory: { NativeCheckpointSession(root: $0, capturePeer: capturePeer) })
            let store = WorkspaceStore(engine: engine, codexInstallation: fixtureCodexInstallation(root: root)); await store.load()
            return .init(root: root, database: database, threadID: thread.id, store: store, capturePeer: capturePeer, provider: provider)
        } catch { try? FileManager.default.removeItem(at: root); throw error }
    }
    func cleanup() async { await capturePeer.cancelAll(); await store.shutdown(); try? FileManager.default.removeItem(at: root) }
    func current() throws -> CodingThread { try #require(store.thread(threadID)) }
    func record(_ id: UUID? = nil) throws -> ThreadRunRecord {
        let records = try current().runHistory ?? []
        return try #require(id.flatMap { id in records.first { $0.id == id } } ?? records.last)
    }
    func waitCapture(_ id: UUID) async throws {
        try await waitNativeCheckpoint { await capturePeer.captureIDs.contains(id) }
    }
}

@MainActor private func waitNativeCheckpoint(_ condition: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while try await !condition() {
        guard ContinuousClock.now < deadline else { throw CoincideError("The native checkpoint fixture did not reach its gate.") }
        try await Task.sleep(for: .milliseconds(10))
    }
}

@MainActor @Test(.timeLimit(.minutes(1)))
func nativeCheckpointPolicyCaptureRetryAndBoundedDiffPreserveQueuedInputAndUnsentDraftAcrossReopen() async throws {
    let f = try await NativeCheckpointFixture.make(), store = f.store, id = f.threadID
    do {
        #expect(try f.current().checkpointPolicy == nil && f.current().effectiveCheckpointPolicy == .automatic)
        store.setDraft("First accepted message", id: id)
        #expect(await store.submit("First accepted message", threadID: id).value)
        let run = try f.record(), baseline = try #require(run.checkpoints?.baseline)
        try await f.waitCapture(baseline.id)
        #expect(RunCheckpointPresentation.preparingBaseline(in: try f.current()))
        #expect(await f.provider.prompts.isEmpty)
        store.setCheckpointPolicy(.disabled, id: id)
        #expect(await store.submit("Queued with snapshots disabled", threadID: id).value)
        store.setDraft("Unsent changes while the snapshot is held", id: id)
        try await f.capturePeer.complete(baseline.id)
        try await waitNativeCheckpoint { await f.provider.prompts == ["First accepted message"] }
        #expect(!RunCheckpointPresentation.preparingBaseline(in: try f.current()))
        await f.provider.finish()
        try await waitNativeCheckpoint { try f.current().heldPostRunCheckpoint?.attempt.phase == .capturing }
        let failedAttempt = try #require(f.current().heldPostRunCheckpoint?.attempt)
        try await f.waitCapture(failedAttempt.id)
        #expect(RunCheckpointPresentation.banner(in: try f.current())?.canResolve == false)
        try await f.capturePeer.complete(failedAttempt.id, failure: true)
        try await waitNativeCheckpoint { try f.current().heldPostRunCheckpoint?.attempt.phase == .failed }
        #expect(RunCheckpointPresentation.banner(in: try f.current())?.canResolve == true)
        #expect(await f.provider.prompts.count == 1)
        try await store.retryPostRunCheckpoint(threadID: id, runID: run.id, expectedAttemptID: failedAttempt.id)
        let retried = try #require(f.current().heldPostRunCheckpoint?.attempt)
        #expect(retried.id != failedAttempt.id && retried.isLaterObservation)
        #expect(try f.record(run.id).checkpoints?.previousPostRunAttempts.map(\.id) == [failedAttempt.id])
        await #expect(throws: CancellationError.self) {
            try await store.continueAfterPostRunCheckpoint(threadID: id, runID: run.id, expectedAttemptID: failedAttempt.id)
        }
        try await f.waitCapture(retried.id); try await f.capturePeer.complete(retried.id)
        try await waitNativeCheckpoint { await f.provider.prompts.count == 2 }
        #expect(try f.record().checkpoints == nil, "Accepted queued input keeps its captured disabled policy.")
        let diff = try await store.runCheckpointDiff(threadID: id, runID: run.id, maxBytes: Int.max)
        #expect(diff.truncated && diff.patch.contains("+after"))
        #expect(await f.capturePeer.diffLimit == 262_144)
        #expect(store.selectedThreadID == id && store.errorMessage == nil)
        #expect(try f.current().draft == "Unsent changes while the snapshot is held")
        await f.provider.finish()
        try await waitNativeCheckpoint { try f.current().isBusy == false }
        await store.shutdown()
        let provider = NativeCheckpointProvider()
        let engine = try WorkspaceEngine(url: f.database, providerFactory: { _ in provider }, identityResolver: { _ in nil },
            checkpointFactory: { NativeCheckpointSession(root: $0, capturePeer: f.capturePeer) })
        let reopened = WorkspaceStore(engine: engine, codexInstallation: fixtureCodexInstallation(root: f.root)); await reopened.load()
        #expect(reopened.thread(id)?.effectiveCheckpointPolicy == .disabled)
        #expect(reopened.thread(id)?.draft == "Unsent changes while the snapshot is held")
        #expect(reopened.selectedThreadID == id)
        #expect(reopened.thread(id)?.runHistory?.first?.checkpoints?.postRun?.isLaterObservation == true)
        #expect(await provider.prompts.isEmpty)
        await reopened.shutdown()
    } catch { await f.cleanup(); throw error }
    await f.cleanup()
}

@MainActor @Test(.timeLimit(.minutes(1)))
func nativeCheckpointFailureStillStartsProviderAndExplicitContinueReleasesOnlyCurrentHold() async throws {
    let f = try await NativeCheckpointFixture.make(), store = f.store, id = f.threadID
    do {
        #expect(await store.submit("Baseline failure is visible", threadID: id).value)
        let run = try f.record(), baseline = try #require(run.checkpoints?.baseline)
        try await f.waitCapture(baseline.id); try await f.capturePeer.complete(baseline.id, failure: true)
        try await waitNativeCheckpoint { await f.provider.prompts.count == 1 }
        #expect(RunCheckpointPresentation.banner(in: try f.current())?.title == "Before-run snapshot unavailable")
        #expect(RunCheckpointPresentation.banner(in: try f.current())?.canResolve == false)
        store.setCheckpointPolicy(.disabled, id: id)
        #expect(await store.submit("Wait for explicit continue", threadID: id).value)
        store.setDraft("Keep this draft", id: id)
        await f.provider.finish()
        try await waitNativeCheckpoint { try f.current().heldPostRunCheckpoint?.attempt.phase == .capturing }
        let held = try #require(f.current().heldPostRunCheckpoint?.attempt)
        try await f.waitCapture(held.id); try await f.capturePeer.complete(held.id, failure: true)
        try await waitNativeCheckpoint { try f.current().heldPostRunCheckpoint?.attempt.phase == .failed }
        try await store.continueAfterPostRunCheckpoint(threadID: id, runID: run.id, expectedAttemptID: held.id)
        try await waitNativeCheckpoint { await f.provider.prompts.count == 2 }
        #expect(try f.record(run.id).checkpoints?.postRun?.phase == .skipped)
        #expect(try f.current().heldPostRunCheckpoint == nil && f.current().draft == "Keep this draft")
        #expect(store.selectedThreadID == id && store.errorMessage == nil)
        await #expect(throws: CancellationError.self) {
            try await store.retryPostRunCheckpoint(threadID: id, runID: run.id, expectedAttemptID: held.id)
        }
        await #expect(throws: CancellationError.self) { _ = try await store.runCheckpointDiff(threadID: id, runID: run.id) }
        await f.provider.finish()
    } catch { await f.cleanup(); throw error }
    await f.cleanup()
}

@MainActor @Test func nativeCheckpointDiffAndHistoryFitSmallSheetsInBothAppearances() async throws {
    _ = NSApplication.shared
    let fixture = try await NativeCheckpointFixture.make()
    do {
        var thread = try fixture.current()
        let run = ActiveRun(id: UUID(), configuration: .init(thread: thread), startedAt: Date(), stopRequested: false, nativeTurnID: nil)
        var record = ThreadRunRecord(run: run, origin: .user)
        record.status = .completed
        var checkpoints = ThreadRunCheckpoints(baseline: .init(workspacePath: thread.workspacePath, phase: .failed), providerReleased: true)
        checkpoints.postRun = .init(workspacePath: thread.workspacePath, phase: .interrupted, isLaterObservation: true)
        record.checkpoints = checkpoints; thread.runHistory = [record]
        fixture.store.snapshot.threads = [thread]
        let diff = GitCheckpointDiff(patch: "diff --git a/notes.txt b/notes.txt\n--- a/notes.txt\n+++ b/notes.txt\n@@ -1 +1 @@\n-before\n+after\n", truncated: true)
        for scheme in [ColorScheme.light, .dark] {
            for width in [CGFloat(320), 680] {
                let views: [(String, AnyView)] = [
                    ("banner", AnyView(RunCheckpointBanner(store: fixture.store, threadID: thread.id))),
                    ("history", AnyView(RunHistoryContent(thread: thread, showWorkspaceChanges: { _ in }))),
                    ("diff", AnyView(RunCheckpointDiffContent(workspacePath: thread.workspacePath, diff: diff, error: nil, loading: false, close: { }))),
                    ("unavailable", AnyView(RunCheckpointDiffContent(workspacePath: thread.workspacePath, diff: nil, error: "Saved observations changed.", loading: false, close: { })))
                ]
                for (name, view) in views {
                    let content = view.environment(\.colorScheme, scheme)
                    let controller = NSHostingController(rootView: content)
                    let size = controller.sizeThatFits(in: CGSize(width: width, height: 600))
                    #expect(size.width <= width + 1 && size.height <= 640)
                    try await captureNativeCheckpoint(content, name: name, width: width, height: max(320, size.height), scheme: scheme)
                }
            }
        }
    } catch { await fixture.cleanup(); throw error }
    await fixture.cleanup()
}

@MainActor private func captureNativeCheckpoint<Content: View>(_ content: Content, name: String, width: CGFloat,
                                                              height: CGFloat, scheme: ColorScheme) async throws {
    guard ProcessInfo.processInfo.environment["COINCIDE_RENDER_CHECKPOINTS"] == "1" else { return }
    let appearance = try #require(NSAppearance(named: scheme == .light ? .aqua : .darkAqua))
    let view = content.background(Color(nsColor: .windowBackgroundColor)).frame(width: width, height: height)
    let hosting = NSHostingView(rootView: view)
    let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: width, height: height),
                          styleMask: .borderless, backing: .buffered, defer: false)
    window.appearance = appearance; hosting.appearance = appearance; window.isReleasedWhenClosed = false; window.contentView = hosting
    defer { window.close() }
    hosting.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(100)); hosting.layoutSubtreeIfNeeded()
    let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
    appearance.performAsCurrentDrawingAppearance { hosting.cacheDisplay(in: hosting.bounds, to: bitmap) }
    let data = try #require(bitmap.representation(using: .png, properties: [:]))
    let color = scheme == .light ? "light" : "dark"
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-checkpoint-\(name)-\(Int(width))-\(color).png")
    try data.write(to: path); print("Checkpoint preview: \(path.path)")
}
