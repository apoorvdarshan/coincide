import AppKit
import CoincideCore
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
