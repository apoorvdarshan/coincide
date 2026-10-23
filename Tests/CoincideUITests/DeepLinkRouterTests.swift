import AppKit
@testable import CoincideCore
import Testing
@testable import Coincide

@MainActor private final class DraftChoices {
    var pending: [DeepLinkRouter.DraftChoice]
    var asked: [String] = []
    init(_ pending: [DeepLinkRouter.DraftChoice]) { self.pending = pending }
    func next(_ title: String) -> DeepLinkRouter.DraftChoice { asked.append(title); return pending.isEmpty ? .cancel : pending.removeFirst() }
}

private func git(_ arguments: [String], in directory: URL) async throws {
    let result = await BoundedProcess.run(executable: "/usr/bin/git", arguments: arguments, environment: ["PATH": "/usr/bin:/bin", "HOME": directory.path],
                                          directory: directory.path, timeout: .seconds(30), outputLimit: 65_536, mergeStandardError: true)
    guard result.status == 0 else { throw CoincideError("git \(arguments.joined(separator: " ")) failed: \(String(decoding: result.output, as: UTF8.self))") }
}

@MainActor @Test(.timeLimit(.minutes(1)))
func deepLinksOpenDraftsWithoutSendingAndConfirmBeforeChangingExistingDrafts() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-deep-links-" + UUID().uuidString)
    let alpha = root.appendingPathComponent("Alpha"), widget = root.appendingPathComponent("Widget"), gamma = root.appendingPathComponent("Gamma Folder")
    for folder in [alpha, widget, gamma] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
    defer { try? FileManager.default.removeItem(at: root) }
    try await git(["init", "-q"], in: widget)
    try await git(["remote", "add", "origin", "https://github.com/acme/widget.git"], in: widget)
    let alphaProject = WorkspaceProject(path: alpha.path)
    var widgetProject = WorkspaceProject(path: widget.path)
    widgetProject.repositoryIdentity = try RepositoryIdentity(remote: #require(RepositoryIdentity.normalizedRemote("https://github.com/acme/widget.git")),
                                                              remoteName: "origin", rootPath: widgetProject.path, projectRelativePath: "")
    var existing = CodingThread(project: alphaProject); existing.title = "Existing conversation"; existing.draft = "My unsent notes"
    var initial = WorkspaceSnapshot(); initial.projects = [alphaProject, widgetProject]; initial.threads = [existing]
    let database = root.appendingPathComponent("workspace.sqlite")
    _ = try await WorkspaceDatabase(url: database).commit(initial, event: "fixture.deep-links", commandID: UUID())
    let store = WorkspaceStore(databaseURL: database)
    await store.load()
    do {
        store.selectedProjectID = alphaProject.id; store.selectedThreadID = existing.id
        let banners = InAppBannerCenter(schedulesExpiry: false, announces: false)
        let choices = DraftChoices([.cancel, .append, .replace])
        let router = DeepLinkRouter(store: store, banners: banners, confirmDraftReplacement: { choices.next($0) }, providerAvailable: { _ in false })

        let opened = await router.open(URL(string: "coincide://new?prompt=Fix%20the%20build%E2%80%8B&repo=Acme/Widget&provider=codex&model=gpt-5.5")!)
        guard case .openedDraft(let id) = opened else { Issue.record("Expected a new draft, got \(opened)"); await store.shutdown(); return }
        let thread = try #require(store.thread(id))
        #expect(thread.projectID == widgetProject.id && thread.draft == "Fix the build" && store.selectedThreadID == id)
        #expect(thread.messages.isEmpty && thread.queuedTurns.isEmpty && thread.activeRun == nil && !thread.isBusy, "A link never sends or queues its prompt.")
        #expect(banners.banners.contains { $0.title == "Hidden characters removed" } && banners.banners.contains { $0.title == "Using your default agent" })

        let link = try #require(PromptLink.threadURL(id: existing.id, prompt: "Please review"))
        #expect(await router.open(link) == .cancelled)
        #expect(store.thread(existing.id)?.draft == "My unsent notes" && store.selectedThreadID == existing.id)
        #expect(await router.open(link) == .selectedThread(existing.id))
        #expect(store.thread(existing.id)?.draft == "My unsent notes\n\nPlease review")
        #expect(await router.open(link) == .selectedThread(existing.id))
        #expect(store.thread(existing.id)?.draft == "Please review" && choices.asked == Array(repeating: "Existing conversation", count: 3))
        #expect(await router.open(link) == .selectedThread(existing.id) && choices.asked.count == 3, "The same text needs no confirmation.")

        let folderLink = try #require(PromptLink.openFolderURL(path: gamma.path))
        let folder = await router.open(folderLink)
        guard case .openedDraft(let folderThread) = folder else { Issue.record("Expected a folder conversation, got \(folder)"); await store.shutdown(); return }
        let added = try #require(store.snapshot.projects.first { $0.path == WorkspaceProject(path: gamma.path).path })
        #expect(store.thread(folderThread)?.projectID == added.id && store.thread(folderThread)?.draft == "")
        #expect(await router.open(folderLink) == .selectedThread(folderThread), "Reopening a folder reuses its empty conversation.")
        #expect(store.snapshot.threads.filter { $0.projectID == added.id }.count == 1)

        let missing = await router.open(URL(string: "coincide://threads/\(UUID().uuidString)?prompt=x")!)
        guard case .rejected = missing else { Issue.record("Unknown conversations are rejected."); await store.shutdown(); return }
        guard case .rejected = await router.open(URL(string: "coincide://new?prompt=" + String(repeating: "a", count: 8_001))!) else {
            Issue.record("Overlong prompts are rejected."); await store.shutdown(); return
        }
        #expect(banners.banners.contains { $0.title == "Link not opened" && $0.kind == .error })
        await store.shutdown()
    } catch { await store.shutdown(); throw error }
}

@MainActor private final class DeepLinkConfirmationGate {
    private(set) var entered = false
    private var reply: CheckedContinuation<DeepLinkRouter.DraftChoice, Never>?
    func confirm(_ title: String) async -> DeepLinkRouter.DraftChoice {
        entered = true
        return await withCheckedContinuation { reply = $0 }
    }
    func release(_ choice: DeepLinkRouter.DraftChoice = .replace) { reply?.resume(returning: choice); reply = nil }
}

@MainActor private struct DeepLinkOwnershipFixture {
    let root: URL, project: WorkspaceProject, thread: CodingThread
    let engine: WorkspaceEngine, store: WorkspaceStore, banners: InAppBannerCenter
    static func make() async throws -> Self {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-deep-link-cas-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let project = WorkspaceProject(path: root.path), database = root.appendingPathComponent("workspace.sqlite")
        var thread = CodingThread(project: project); thread.draft = "Original café unsent  "; thread.checkpointPolicy = .disabled
        thread.draftAttachments = [.init(id: UUID(), name: "Kept.txt", mimeType: "text/plain", byteCount: 5,
            digest: String(repeating: "a", count: 64), fileExtension: "txt")]
        var initial = WorkspaceSnapshot(); initial.projects = [project]; initial.threads = [thread]
        try await WorkspaceDatabase(url: database).save(initial, event: "fixture.deep-link-ownership")
        let engine = try WorkspaceEngine(url: database, providerFactory: { _ in
            throw CoincideError("Deep links cannot launch a provider in this fixture.")
        }, identityResolver: { _ in nil })
        let store = WorkspaceStore(engine: engine); await store.load()
        return .init(root: root, project: project, thread: thread, engine: engine, store: store,
            banners: InAppBannerCenter(schedulesExpiry: false, announces: false))
    }
    func cleanup() async { await store.shutdown(); try? FileManager.default.removeItem(at: root) }
}

enum DeepLinkConcurrentChange: CaseIterable, Sendable { case unicodeDraft, attachments, checkout, recreated, cancelled }

@Test(.timeLimit(.minutes(1)), arguments: DeepLinkConcurrentChange.allCases) @MainActor
func deepLinkAwaitedConfirmationRefusesChangedDraftAttachmentsCheckoutAndConversationBirth(change: DeepLinkConcurrentChange) async throws {
    let f = try await DeepLinkOwnershipFixture.make(), gate = DeepLinkConfirmationGate()
    do {
        let router = DeepLinkRouter(store: f.store, banners: f.banners, confirmDraftReplacement: { await gate.confirm($0) }, providerAvailable: { _ in false })
        let url = try #require(PromptLink.threadURL(id: f.thread.id, prompt: "Incoming link prompt"))
        let opening = Task { await router.open(url) }
        try await waitNativeSetup { gate.entered }
        switch change {
        case .unicodeDraft:
            let newer = "Original cafe\u{301} unsent  "
            #expect(newer == f.thread.draft && !newer.utf8.elementsEqual(f.thread.draft.utf8))
            f.store.setDraft(newer, id: f.thread.id)
        case .attachments:
            let added = ChatAttachment(id: UUID(), name: "Newer.txt", mimeType: "text/plain", byteCount: 6,
                digest: String(repeating: "b", count: 64), fileExtension: "txt")
            _ = try await f.engine.dispatch(.addAttachments(threadID: f.thread.id, attachments: [added]))
            try await waitNativeSetup { f.store.thread(f.thread.id)?.draftAttachments.count == 2 }
        case .checkout:
            let checkout = f.root.appendingPathComponent("Other Checkout")
            try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
            _ = try await f.engine.dispatch(.editThread(f.thread.id, .workspacePath(checkout.path)))
            try await waitNativeSetup { f.store.thread(f.thread.id)?.workspacePath == checkout.path }
        case .recreated:
            _ = try await f.engine.dispatch(.removeProject(projectID: f.project.id, expectedThreadIDs: [f.thread.id]))
            var replacement = f.thread; replacement.createdAt = f.thread.createdAt.addingTimeInterval(1)
            _ = try await f.engine.dispatch(.addProjectWithThread(project: f.project, thread: replacement))
            try await waitNativeSetup { f.store.thread(f.thread.id)?.createdAt == replacement.createdAt }
        case .cancelled: opening.cancel()
        }
        let before = try #require(f.store.composerDraftSnapshot(f.thread.id))
        gate.release(.append)
        let outcome = await opening.value
        if change == .cancelled { #expect(outcome == .cancelled) }
        else { guard case .rejected = outcome else { Issue.record("A stale confirmed link must be refused"); await f.cleanup(); return } }
        let after = try #require(f.store.composerDraftSnapshot(f.thread.id))
        #expect(after.matches(before), "The latest literal text, attachment references and checkout stay unchanged.")
        let thread = try #require(f.store.thread(f.thread.id))
        #expect(thread.messages.isEmpty && thread.queuedTurns.isEmpty && thread.activeRun == nil)
        await f.cleanup()
    } catch { gate.release(.cancel); await f.cleanup(); throw error }
}

@Test(.timeLimit(.minutes(1))) @MainActor
func deepLinkConfirmedAppendUsesCurrentOverlayAndKeepsAttachmentsWithoutSending() async throws {
    let f = try await DeepLinkOwnershipFixture.make()
    do {
        let literal = "Latest e\u{301} overlay  \n"
        f.store.setDraft(literal, id: f.thread.id)
        let choices = DraftChoices([.append])
        let router = DeepLinkRouter(store: f.store, banners: f.banners, confirmDraftReplacement: { choices.next($0) }, providerAvailable: { _ in false })
        let url = try #require(PromptLink.threadURL(id: f.thread.id, prompt: "Incoming"))
        let outcome = await router.open(url)
        #expect(outcome == .selectedThread(f.thread.id))
        let current = try #require(f.store.thread(f.thread.id))
        #expect(current.draft.utf8.elementsEqual((literal + "\nIncoming").utf8))
        #expect(current.draftAttachments == f.thread.draftAttachments && current.messages.isEmpty && current.queuedTurns.isEmpty && current.activeRun == nil)
        #expect(choices.asked.count == 1)
        await f.cleanup()
    } catch { await f.cleanup(); throw error }
}

@Test(.timeLimit(.minutes(1))) @MainActor
func deepLinkFolderNeverReusesAnAttachmentOnlyDraftOrDifferentWorktree() async throws {
    let f = try await DeepLinkOwnershipFixture.make()
    do {
        _ = try await f.engine.dispatch(.editThread(f.thread.id, .draft("")))
        let checkout = f.root.appendingPathComponent("Linked Checkout")
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        var worktree = CodingThread(project: f.project); worktree.workspacePath = checkout.path
        _ = try await f.engine.dispatch(.createThread(worktree))
        try await waitNativeSetup { f.store.thread(worktree.id) != nil && f.store.thread(f.thread.id)?.draft.isEmpty == true }
        let router = DeepLinkRouter(store: f.store, banners: f.banners, providerAvailable: { _ in false })
        let url = try #require(PromptLink.openFolderURL(path: f.project.path))
        let outcome = await router.open(url)
        guard case .openedDraft(let id) = outcome else { Issue.record("An attachment-only draft and another worktree cannot be reused"); await f.cleanup(); return }
        #expect(id != f.thread.id && id != worktree.id)
        let created = try #require(f.store.thread(id))
        #expect(created.workspacePath.utf8.elementsEqual(f.project.path.utf8) && created.draft.isEmpty && created.draftAttachments.isEmpty)
        #expect(f.store.thread(f.thread.id)?.draftAttachments == f.thread.draftAttachments)
        #expect(f.store.thread(worktree.id)?.workspacePath == checkout.path)
        let reused = await router.open(url)
        #expect(reused == .selectedThread(id))
        await f.cleanup()
    } catch { await f.cleanup(); throw error }
}
