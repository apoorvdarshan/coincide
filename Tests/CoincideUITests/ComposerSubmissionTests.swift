import CoincideCore
import Foundation
import Testing
@testable import Coincide

@MainActor @Test(.timeLimit(.minutes(1)), arguments: ["O", "Keep this draft while selecting an isolated restore worktree"])
func nativeComposerSavedSendActionSubmitsTheLatestCompleteDraftBeforeDebounce(previousDraft: String) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-composer-submission-" + UUID().uuidString)
        .standardizedFileURL.resolvingSymlinksInPath()
    let checkout = root.appendingPathComponent("Private checkout")
    try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
    var activeStore: WorkspaceStore?
    do {
        let database = root.appendingPathComponent("workspace.sqlite")
        let project = WorkspaceProject(path: checkout.path)
        var thread = CodingThread(project: project, model: "Preserved composer model")
        thread.provider = .codex; thread.checkpointPolicy = .disabled
        thread.draft = previousDraft
        var snapshot = WorkspaceSnapshot(); snapshot.projects = [project]; snapshot.threads = [thread]
        try await WorkspaceDatabase(url: database).save(snapshot, event: "composer.fixture")
        let provider = NativeSetupProvider()
        let engine = try WorkspaceEngine(url: database, providerFactory: { _ in provider }, identityResolver: { _ in nil })
        let store = WorkspaceStore(engine: engine, codexInstallation: fixtureCodexInstallation(root: root)); activeStore = store; await store.load()
        let view = ChatView(store: store, threadID: thread.id)
        let savedSendAction = view.submitCurrentDraft
        #expect(store.thread(thread.id)?.draft == previousDraft)

        let completePrompt = "Offline history prompt 1 — the complete latest message 😀"
        // No suspension or rendering opportunity separates the binding update
        // from this previously captured action, and the 350ms save has not run.
        store.setDraft(completePrompt, id: thread.id)
        let submission = savedSendAction()
        #expect(await submission.value)
        try await waitNativeSetup { await provider.calls.count == 1 }
        let calls = await provider.calls
        #expect(calls == [.init(prompt: completePrompt, path: project.path, model: thread.model, permission: thread.permission)])
        let accepted = await engine.current().snapshot
        let userMessages = accepted.threads[0].messages.filter { $0.role == .user }
        #expect(userMessages.count == 1 && userMessages.first?.text == completePrompt)
        #expect(userMessages.first?.text != previousDraft)
        #expect(accepted.threads[0].queuedTurns.isEmpty)

        await provider.finish()
        try await waitNativeSetup {
            let current = await engine.current().snapshot.threads[0]
            return current.activeRun == nil && current.runHistory?.last?.status == .completed
        }
        let retained = try await WorkspaceDatabase(url: database).load().threads[0]
        #expect(retained.messages.filter { $0.role == .user }.map(\.text) == [completePrompt])
        #expect(retained.runHistory?.count == 1 && retained.runHistory?.first?.checkpoints == nil)
        #expect(retained.draft.isEmpty && store.thread(thread.id)?.draft.isEmpty == true)
        #expect(await provider.calls.count == 1)
        await store.shutdown(); activeStore = nil
        try FileManager.default.removeItem(at: root)
    } catch {
        await activeStore?.shutdown()
        try? FileManager.default.removeItem(at: root)
        throw error
    }
}
