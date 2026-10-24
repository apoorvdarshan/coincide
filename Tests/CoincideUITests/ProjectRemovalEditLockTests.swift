import Foundation
import CoincideCore
import Testing
@testable import Coincide

private actor EditLockProvider: ProviderSession {
    nonisolated let events: AsyncStream<ProviderEvent>
    private let sink: AsyncStream<ProviderEvent>.Continuation
    private var closeWaiter: CheckedContinuation<Void, Never>?
    private var released = false
    private(set) var closeStarted = false
    private(set) var closeFinished = false
    init() { let pair = AsyncStream<ProviderEvent>.makeStream(); events = pair.stream; sink = pair.continuation }
    func models() -> [ProviderModel] { [] }
    func send(text: String, thread: CodingThread) {
        guard let runID = thread.activeRun?.id else { return }
        sink.yield(.context(runID: runID, event: .thread("edit-lock-fixture")))
        sink.yield(.context(runID: runID, event: .turn(UUID().uuidString)))
    }
    func interrupt() { }
    func respond(_ request: ApprovalRequest, allow: Bool) { }
    func answer(_ request: ApprovalRequest, answers: [String: String]) { }
    func close() async {
        guard !closeStarted else { return }
        closeStarted = true; sink.finish()
        if !released { await withCheckedContinuation { closeWaiter = $0 } }
        closeFinished = true
    }
    func releaseClose() { released = true; let saved = closeWaiter; closeWaiter = nil; saved?.resume() }
}

@MainActor private func waitRemovalEditLock(_ condition: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while try await !condition() {
        guard ContinuousClock.now < deadline else { throw CoincideError("Project removal edit lock did not settle") }
        try await Task.sleep(for: .milliseconds(10))
    }
}

@MainActor @Test(.timeLimit(.minutes(1)))
func removalLocksCheckoutAndSharedEditorsThroughCleanupRejectsStaleNavigationAndUnlocksRejectedConfirmation() async throws {
    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-removal-edit-lock-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    let root = scratch.resolvingSymlinksInPath(); defer { try? FileManager.default.removeItem(at: root) }
    let checkout = root.appendingPathComponent("remove"), shared = root.appendingPathComponent("shared-worktree")
    let surviving = root.appendingPathComponent("surviving"), staleFolder = root.appendingPathComponent("stale-confirmation")
    for folder in [checkout, shared, surviving, staleFolder] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
    let checkoutFile = checkout.appendingPathComponent("owned.txt"), sharedFile = shared.appendingPathComponent("shared.txt")
    let survivorFile = surviving.appendingPathComponent("survivor.txt")
    let bytes = Data("Existing bytes must survive editor locking and project removal.\n".utf8)
    for file in [checkoutFile, sharedFile, survivorFile] { try bytes.write(to: file) }
    let project = WorkspaceProject(path: checkout.path), survivor = WorkspaceProject(path: surviving.path), stale = WorkspaceProject(path: staleFolder.path)
    var active = CodingThread(project: project); active.workspacePath = shared.path
    var survivingThread = CodingThread(project: survivor); survivingThread.workspacePath = shared.path
    let provider = EditLockProvider()
    let engine = try WorkspaceEngine(url: root.appendingPathComponent("workspace.sqlite"), providerFactory: { _ in provider })
    _ = try await engine.load()
    for project in [project, survivor, stale] { try await engine.dispatch(.addProject(project)) }
    try await engine.dispatch(.createThread(active)); try await engine.dispatch(.createThread(survivingThread))
    var editorHandoffs: [ExternalEditorLaunchPlan] = []
    let store = WorkspaceStore(engine: engine, managedProjectsRoot: root.appendingPathComponent("Projects"),
        externalEditorDiscovery: { [] }, externalEditorHandoff: { plan in
            editorHandoffs.append(plan); return Task { }
        })
    await store.load()
    var removal: Task<Void, any Error>?
    do {
        try await engine.dispatch(.submit(threadID: active.id, text: "Keep the provider alive until removal"))
        try await waitRemovalEditLock { store.thread(active.id)?.activeRun?.nativeTurnID != nil }
        let request = try #require(store.projectRemovalRequest(project.id))
        #expect(store.canEditWorkspace(checkout.path) && store.canEditWorkspace(shared.path) && store.canEditWorkspace(surviving.path))
        removal = Task { try await store.removeProject(request) }
        try await waitRemovalEditLock {
            let closing = await provider.closeStarted
            return closing && !store.snapshot.projects.contains { $0.id == project.id }
        }
        // The shared path still has a live owner. Its lock must therefore come from the
        // in-flight removal rather than merely rejecting workspaces absent from the snapshot.
        #expect(store.thread(survivingThread.id)?.workspacePath == shared.path)
        for _ in 0..<4 {
            #expect(!store.canEditWorkspace(checkout.path) && !store.canEditWorkspace(shared.path))
            #expect(store.canEditWorkspace(surviving.path) && store.canEditWorkspace(staleFolder.path))
            await Task.yield()
        }
        #expect(await provider.closeFinished == false)
        store.fileNavigation = nil
        store.openFile(survivorFile, line: 1, workspacePath: surviving.path)
        try await waitRemovalEditLock { editorHandoffs.count == 1 }
        #expect(editorHandoffs == [.defaultApplication(survivorFile)] && store.fileNavigation == nil)

        let staleRequest = try #require(store.projectRemovalRequest(stale.id))
        let appeared = CodingThread(project: stale)
        try await engine.dispatch(.createThread(appeared))
        try await waitRemovalEditLock { store.thread(appeared.id) != nil }
        do {
            try await store.removeProject(staleRequest)
            Issue.record("A stale confirmation silently included a newly created conversation.")
        } catch let error as WorkspaceCommandError { #expect(!error.message.isEmpty) }
        #expect(store.canEditWorkspace(staleFolder.path) && store.snapshot.projects.contains { $0.id == stale.id })
        #expect(!store.canEditWorkspace(shared.path))

        await provider.releaseClose()
        try await removal?.value
        #expect(await provider.closeFinished)
        #expect(store.canEditWorkspace(shared.path) && store.canEditWorkspace(staleFolder.path))
        store.fileNavigation = nil
        store.openFile(checkoutFile, line: 1, workspacePath: checkout.path)
        #expect(store.fileNavigation == nil && editorHandoffs.count == 1)
        store.openFile(sharedFile, line: 2, workspacePath: shared.path)
        try await waitRemovalEditLock { editorHandoffs.count == 2 }
        #expect(editorHandoffs == [.defaultApplication(survivorFile), .defaultApplication(sharedFile)] && store.fileNavigation == nil)
        #expect(store.errorMessage == nil)
        for file in [checkoutFile, sharedFile, survivorFile] { #expect(try Data(contentsOf: file) == bytes) }
        await store.shutdown()
    } catch {
        await provider.releaseClose(); _ = await removal?.result; await store.shutdown(); throw error
    }
}
