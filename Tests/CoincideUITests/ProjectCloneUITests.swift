import AppKit
import CoincideCore
import SwiftUI
import Testing
@testable import Coincide

private actor NativeClonePeer: ProjectCloneSession {
    private var waiter: CheckedContinuation<Void, any Error>?
    private var progress: (@Sendable (GitCloneProgress) async -> Void)?
    private var completed = false
    private var cancelled = false
    private(set) var starts = 0

    func run(onProgress: @escaping @Sendable (GitCloneProgress) async -> Void) async throws {
        starts += 1; progress = onProgress
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if cancelled { continuation.resume(throwing: CancellationError()) }
                else { waiter = continuation }
            }
        } onCancel: { Task { await self.cancel() } }
    }
    func isCompleted() -> Bool { completed }
    func report(_ value: GitCloneProgress) async { await progress?(value) }
    func succeed() { completed = true; let saved = waiter; waiter = nil; saved?.resume() }
    func fail() { let saved = waiter; waiter = nil; saved?.resume(throwing: CoincideError("The fixture remote is unavailable.")) }
    private func cancel() { cancelled = true; let saved = waiter; waiter = nil; saved?.resume(throwing: CancellationError()) }
}

private actor NativeCloneProvider: ProviderSession {
    nonisolated let events: AsyncStream<ProviderEvent>
    private let sink: AsyncStream<ProviderEvent>.Continuation
    private var runID: UUID?
    private(set) var prompts: [String] = []
    init() { let pair = AsyncStream<ProviderEvent>.makeStream(); events = pair.stream; sink = pair.continuation }
    func models() -> [ProviderModel] { [] }
    func send(text: String, thread: CodingThread) {
        runID = thread.activeRun?.id; prompts.append(text)
        emit(.thread("native-clone-\(thread.id)")); emit(.turn(UUID().uuidString))
    }
    func finish() { emit(.completed(.idle)) }
    func interrupt() { emit(.completed(.interrupted)) }
    func respond(_ request: ApprovalRequest, allow: Bool) { }
    func answer(_ request: ApprovalRequest, answers: [String: String]) { }
    func close() { sink.finish() }
    private func emit(_ event: ProviderEvent) {
        if let runID { sink.yield(.context(runID: runID, event: event)) } else { sink.yield(event) }
    }
}

private final class NativeCloneHarness: @unchecked Sendable {
    private let lock = NSLock()
    private var peers: [UUID: NativeClonePeer] = [:]
    let provider = NativeCloneProvider()
    func peer(_ id: UUID) -> NativeClonePeer {
        lock.lock(); defer { lock.unlock() }
        if let value = peers[id] { return value }
        let value = NativeClonePeer(); peers[id] = value; return value
    }
}

@MainActor private func waitCloneUI(_ predicate: () async throws -> Bool, line: UInt = #line) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while try await !predicate() {
        guard ContinuousClock.now < deadline else { throw CoincideError("The native clone UI did not settle at test line \(line).") }
        try await Task.sleep(for: .milliseconds(10))
    }
}

@MainActor @Test(.timeLimit(.minutes(1))) func nativeCloneOpensImmediatelyHoldsComposerInputAndRetainsItAcrossCancelRetryAndReopen() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-clone-ui-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let database = root.appendingPathComponent("workspace.sqlite"), harness = NativeCloneHarness()
    let engine = try WorkspaceEngine(url: database, providerFactory: { _ in harness.provider }, cloneFactory: { harness.peer($0.id) })
    let store = WorkspaceStore(engine: engine)
    await store.load()
    do {
        store.addProject(at: root); try await waitCloneUI { store.snapshot.projects.count == 1 && store.selectedProjectID != nil }
        let oldProject = try #require(store.selectedProjectID)
        store.showArchived = true
        try await store.cloneRepository(source: "https://example.invalid/native.git", destination: root.appendingPathComponent("checkout"))
        let project = try #require(store.selectedProject), thread = try #require(store.selectedThread)
        let attempt = try #require(project.clone?.id), first = harness.peer(attempt)
        try await waitCloneUI { await first.starts == 1 }
        #expect(project.id != oldProject && store.selectedProjectID == project.id && thread.projectID == project.id && !store.showArchived)
        #expect(!store.workspaceReady(for: thread) && !FileManager.default.fileExists(atPath: thread.workspacePath))
        #expect(store.visibleThreads.map(\.id).contains(thread.id))
        await store.createWorktree(for: thread.id, branch: "must-wait")
        #expect(store.errorMessage?.contains("cloning") == true && !store.isPreparingWorkspace(thread.id))
        store.errorMessage = nil

        let agent = ACPAgentConfiguration(name: "Synthetic Provider", executable: "/usr/bin/true")
        try await store.saveACPAgent(agent)
        store.setACPAgent(agent, id: thread.id)
        try await waitCloneUI { store.thread(thread.id)?.acpAgent == agent }
        store.setDraft("Run when the checkout is ready", id: thread.id)
        #expect(await store.submit("Run when the checkout is ready", threadID: thread.id).value)
        store.setDraft("Keep this unsent composer draft", id: thread.id)
        #expect(store.thread(thread.id)?.draft == "Keep this unsent composer draft")
        #expect(store.thread(thread.id)?.queuedTurns.map(\.text) == ["Run when the checkout is ready"])
        #expect(store.thread(thread.id)?.messages.isEmpty == true && store.thread(thread.id)?.activeRun == nil)
        #expect(await harness.provider.prompts.isEmpty)
        await first.report(.init(stage: .receiving, percent: 42, detail: "Fixture progress", stalled: true))
        try await waitCloneUI { store.selectedProject?.clone?.progress.percent == 42 }
        #expect(store.selectedProject?.clone?.progress.stalled == true)

        store.cancelProjectClone(project.id)
        try await waitCloneUI { store.selectedProject?.clone?.phase == .cancelled }
        #expect(store.selectedProject?.clone?.canRetry == true && !store.workspaceReady(for: thread))
        #expect(store.thread(thread.id)?.queuePaused == true && store.thread(thread.id)?.queuedTurns.count == 1)
        store.retryProjectClone(project.id); store.retryProjectClone(project.id)
        try await waitCloneUI { store.selectedProject?.clone?.id != attempt && store.selectedProject?.clone?.phase == .running }
        let retryID = try #require(store.selectedProject?.clone?.id), retry = harness.peer(retryID)
        try await waitCloneUI { await retry.starts == 1 }
        #expect(store.selectedProject?.clone?.previousPlans.map(\.id) == [attempt])
        #expect(store.errorMessage == nil && store.thread(thread.id)?.messages.isEmpty == true)
        // Cancel deliberately pauses queued messages. The native Resume Queue action can
        // arm them again while cloning continues, without starting an agent prematurely.
        #expect(store.thread(thread.id)?.queuePaused == true)
        store.resumeQueue(thread.id)
        try await waitCloneUI { store.thread(thread.id)?.queuePaused == false }
        #expect(await harness.provider.prompts.isEmpty)
        await retry.succeed()
        try await waitCloneUI { await harness.provider.prompts.count == 1 }
        try await waitCloneUI { store.selectedProject?.clone?.isReady == true }
        let readyThread = try #require(store.selectedThread)
        #expect(store.workspaceReady(for: readyThread))
        #expect(await harness.provider.prompts == ["Run when the checkout is ready"])
        await harness.provider.finish()
        try await waitCloneUI { store.thread(thread.id)?.state == .idle && store.thread(thread.id)?.queuedTurns.isEmpty == true }
        #expect(store.thread(thread.id)?.draft == "Keep this unsent composer draft" && store.errorMessage == nil)
        await store.shutdown()

        let reopened = WorkspaceStore(databaseURL: database)
        await reopened.load()
        #expect(reopened.selectedThreadID == thread.id && reopened.selectedProject?.id == project.id)
        #expect(reopened.thread(thread.id)?.draft == "Keep this unsent composer draft")
        #expect(reopened.thread(thread.id)?.messages.filter { $0.role == .user }.map(\.text) == ["Run when the checkout is ready"])
        #expect(reopened.selectedProject?.clone?.isReady == true && !reopened.isLoading && !reopened.showArchived)
        await reopened.shutdown()
    } catch { await store.shutdown(); throw error }
}

@MainActor @Test(.timeLimit(.minutes(1))) func nativeCloneRunsRealLocalGitAndRejectsCredentialSourcesBeforeAddingAProject() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-clone-ui-local-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source repository"), destination = root.appendingPathComponent("cloned project")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    let git = GitService(root: source)
    try await git.initialize(branch: "main")
    for (key, value) in [("user.name", "Coincide Test"), ("user.email", "test@example.invalid"), ("commit.gpgSign", "false"), ("core.hooksPath", root.appendingPathComponent("no-hooks").path)] {
        #expect(try await CommandRunner.run("git", ["-C", source.path, "config", key, value]).status == 0)
    }
    try "Local native clone\n".write(to: source.appendingPathComponent("hello.txt"), atomically: true, encoding: .utf8)
    try await git.stage(["hello.txt"]); try await git.commit(message: "Local clone fixture")
    let store = WorkspaceStore(databaseURL: root.appendingPathComponent("workspace.sqlite"))
    await store.load()
    do {
        do {
            try await store.cloneRepository(source: "https://private-user:private-password@example.invalid/repository?token=private-token", destination: destination)
            Issue.record("Credential-bearing repository source was accepted.")
        } catch {
            for secret in ["private-user", "private-password", "private-token"] { #expect(!error.localizedDescription.contains(secret)) }
        }
        #expect(store.snapshot.projects.isEmpty && store.snapshot.threads.isEmpty && store.selectedThreadID == nil)
        try await store.cloneRepository(source: source.path, destination: destination)
        let id = try #require(store.selectedThreadID)
        try await waitCloneUI { store.selectedProject?.clone?.isReady == true }
        let selected = try #require(store.selectedThread)
        #expect(selected.id == id && selected.workspacePath == destination.resolvingSymlinksInPath().path && store.workspaceReady(for: selected))
        #expect(try String(contentsOf: destination.appendingPathComponent("hello.txt"), encoding: .utf8) == "Local native clone\n")
        #expect(try await GitService(root: destination).status().branch == "main")
        #expect(store.errorMessage == nil && store.selectedProject?.clone?.phase == .completed)
        await store.shutdown()
    } catch { await store.shutdown(); throw error }
}

@MainActor @Test(.timeLimit(.minutes(1))) func nativeCloneFailurePreservesTheThreadAndShowsRetryableStateWithOffscreenPreviews() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-clone-ui-error-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let harness = NativeCloneHarness()
    let engine = try WorkspaceEngine(url: root.appendingPathComponent("workspace.sqlite"), providerFactory: { _ in harness.provider }, cloneFactory: { harness.peer($0.id) })
    let store = WorkspaceStore(engine: engine)
    await store.load()
    do {
        try await store.cloneRepository(source: "https://example.invalid/native.git", destination: root.appendingPathComponent("checkout"))
        let threadID = try #require(store.selectedThreadID), attempt = try #require(store.selectedProject?.clone?.id)
        let peer = harness.peer(attempt)
        try await waitCloneUI { await peer.starts == 1 }
        store.setDraft("Keep writing while the clone fails", id: threadID)
        await peer.fail()
        try await waitCloneUI { store.selectedProject?.clone?.phase == .failed }
        #expect(store.selectedThreadID == threadID && store.thread(threadID)?.draft == "Keep writing while the clone fails")
        let project = try #require(store.selectedProject), clone = try #require(project.clone)
        #expect(clone.canRetry && !clone.isReady && !clone.isRunning && clone.error?.contains("fixture remote") == true)
        #expect(ProjectClonePresentation.title(clone) == String(localized: "Couldn’t clone repository"))
        if ProcessInfo.processInfo.environment["COINCIDE_RENDER_CLONE"] == "1" { try await captureNativeCloneUI(store, project: project) }
        await store.shutdown()
    } catch { await store.shutdown(); throw error }
}

@MainActor private func captureNativeCloneUI(_ store: WorkspaceStore, project: WorkspaceProject) async throws {
    _ = NSApplication.shared
    let phases: [ProjectClonePhase] = [.queued, .running, .running, .failed, .cancelled, .interrupted]
    let samples: [WorkspaceProject] = try phases.enumerated().map { index, phase in
        var value = WorkspaceProject(path: project.path), state = try #require(project.clone)
        state.phase = phase; state.error = phase == .failed ? "The remote is unavailable. Your queued messages and draft are preserved." : nil
        state.progress = .init(stage: .receiving, percent: phase == .running ? 42 : nil, stalled: index == 1)
        state.cancelRequested = index == 2; value.clone = state; return value
    }
    for scheme in [ColorScheme.light, .dark] {
        try await captureCloneView(CloneRepositorySheet(store: store), scheme: scheme, size: .init(width: 530, height: 360), name: "sheet")
        let banners = VStack(alignment: .leading, spacing: 18) {
            Text("Repository preparation").font(.title2.weight(.semibold))
            ForEach(samples) { sample in ProjectCloneBanner(project: sample, cancel: { }, retry: { }) }
            Spacer(minLength: 0)
        }.padding(24)
        try await captureCloneView(banners, scheme: scheme, size: .init(width: 700, height: 820), name: "banners")
    }
}

@MainActor private func captureCloneView<Content: View>(_ content: Content, scheme: ColorScheme, size: NSSize, name: String) async throws {
    let hosting = NSHostingView(rootView: content.environment(\.colorScheme, scheme).frame(width: size.width, height: size.height)
        .background(scheme == .light ? Color.white : Color(white: 0.12)))
    let window = NSWindow(contentRect: .init(origin: .init(x: -10_000, y: -10_000), size: size), styleMask: .borderless, backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua); hosting.appearance = window.appearance
    window.isReleasedWhenClosed = false; window.contentView = hosting
    defer { window.close() }
    hosting.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(180)); hosting.layoutSubtreeIfNeeded()
    let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
    hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-clone-\(name)-\(scheme == .light ? "light" : "dark").png")
    try #require(bitmap.representation(using: .png, properties: [:])).write(to: path)
    print("Native clone preview: \(path.path)")
}
