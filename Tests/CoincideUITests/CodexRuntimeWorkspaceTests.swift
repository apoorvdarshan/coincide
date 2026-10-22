import Foundation
import Testing
@testable import Coincide
@testable import CoincideCore

private actor NativeCodexRuntimeMetadata {
    enum Kind: Sendable, Equatable { case account, models, defaults }
    struct Read: Sendable { let id: UUID; let kind: Kind; let configuration: CodexRuntimeConfiguration }
    private(set) var reads: [Read] = []
    private(set) var closing: Set<UUID> = []
    private var holdLegacy = false
    private var heldIDs: Set<UUID> = []
    private var readsReleased = false, closesReleased = false
    private var readWaiters: [CheckedContinuation<Void, Never>] = []
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []
    var heldReads: Int { heldIDs.count }
    var heldCloses: Int { closing.intersection(heldIDs).count }
    func holdLegacyReads() { holdLegacy = true }
    func enter(_ id: UUID, kind: Kind, configuration: CodexRuntimeConfiguration) async {
        reads.append(.init(id: id, kind: kind, configuration: configuration))
        if holdLegacy, configuration == .init(), kind != .defaults {
            heldIDs.insert(id)
            // Deliberately ignore cancellation: a late provider response is not
            // allowed to republish metadata from the previous runtime binding.
            if !readsReleased { await withCheckedContinuation { readWaiters.append($0) } }
        }
    }
    func close(_ id: UUID) async {
        closing.insert(id)
        if heldIDs.contains(id), !closesReleased { await withCheckedContinuation { closeWaiters.append($0) } }
    }
    func releaseReads() {
        readsReleased = true; let owned = readWaiters; readWaiters = []; owned.forEach { $0.resume() }
    }
    func releaseCloses() {
        closesReleased = true; let owned = closeWaiters; closeWaiters = []; owned.forEach { $0.resume() }
    }
    func releaseAll() { releaseReads(); releaseCloses() }
    static func label(_ configuration: CodexRuntimeConfiguration) -> String {
        configuration.homeDirectory.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Existing CLI"
    }
    static func models(_ configuration: CodexRuntimeConfiguration) -> [ProviderModel] {
        let label = label(configuration), effort = configuration.homeDirectory == nil ? "low" : "high"
        return [.init(id: "shared-wire-model", name: label,
                      reasoningEfforts: [.init(id: effort, description: label + " effort")], defaultReasoningEffort: effort)]
    }
    static func account(_ configuration: CodexRuntimeConfiguration) -> CodexAccountSnapshot {
        let label = label(configuration)
        return .init(identity: .init(kind: .chatgpt, requiresOpenAIAuth: true,
                                    email: "fixture@example.invalid", planType: "fixture", accountID: label),
                     usage: .available(.init(buckets: [.init(id: label, primary: .init(usedPercent: 25))], accountID: label)),
                     checkedAt: Date(timeIntervalSince1970: 1_800_000_000))
    }
}
private actor NativeCodexRuntimeMetadataPeer: ProviderSession {
    nonisolated let events = AsyncStream<ProviderEvent> { $0.finish() }
    let id = UUID()
    let configuration: CodexRuntimeConfiguration
    let workspacePath: String
    let metadata: NativeCodexRuntimeMetadata
    private var closed = false
    init(configuration: CodexRuntimeConfiguration, workspacePath: String, metadata: NativeCodexRuntimeMetadata) {
        self.configuration = configuration; self.workspacePath = workspacePath; self.metadata = metadata
    }
    func models() async -> [ProviderModel] {
        await metadata.enter(id, kind: .models, configuration: configuration)
        return NativeCodexRuntimeMetadata.models(configuration)
    }
    func codexAccountSnapshot() async -> CodexAccountSnapshot {
        await metadata.enter(id, kind: .account, configuration: configuration)
        return NativeCodexRuntimeMetadata.account(configuration)
    }
    func codexDefaultModelSelection() async throws -> CodexDefaultModelSelection {
        await metadata.enter(id, kind: .defaults, configuration: configuration)
        return try .init(workspacePath: workspacePath, model: "shared-wire-model", reasoningEffort: "low",
                         catalogModel: NativeCodexRuntimeMetadata.models(configuration).first)
    }
    func send(text: String, thread: CodingThread) throws { throw CoincideError("A runtime settings metadata check cannot submit a prompt.") }
    func interrupt() {}
    func respond(_ request: ApprovalRequest, allow: Bool) {}
    func answer(_ request: ApprovalRequest, answers: [String: String]) {}
    func close() async { guard !closed else { return }; closed = true; await metadata.close(id) }
}
private actor NativeCodexCapturedRuntime: ProviderSession {
    struct Input: Equatable, Sendable { let text: String; let configuration: ProviderConfiguration; let runID: UUID? }
    nonisolated let events: AsyncStream<ProviderEvent>
    private let continuation: AsyncStream<ProviderEvent>.Continuation
    private var runID: UUID?
    private(set) var inputs: [Input] = []
    private(set) var closes = 0
    init() { let pair = AsyncStream<ProviderEvent>.makeStream(); events = pair.stream; continuation = pair.continuation }
    func models() throws -> [ProviderModel] { throw CoincideError("Catalog reads must not use the active provider stream.") }
    func send(text: String, thread: CodingThread) {
        runID = thread.activeRun?.id
        inputs.append(.init(text: text, configuration: .init(thread: thread), runID: runID))
        emit(.thread("captured-codex-runtime-thread")); emit(.turn("captured-codex-turn-\(inputs.count)"))
    }
    func finish() { emit(.completed(.idle)); runID = nil }
    func interrupt() { emit(.completed(.interrupted)); runID = nil }
    func respond(_ request: ApprovalRequest, allow: Bool) {}
    func answer(_ request: ApprovalRequest, answers: [String: String]) {}
    func close() { closes += 1; continuation.finish() }
    private func emit(_ event: ProviderEvent) { if let runID { continuation.yield(.context(runID: runID, event: event)) } }
}
@MainActor private struct NativeCodexRuntimeWorkspace {
    let root: URL
    let database: URL
    let projectID: UUID
    let threadIDs: [UUID]
    let metadata: NativeCodexRuntimeMetadata
    let runtime: NativeCodexCapturedRuntime
    let installation: CodexInstallation
    let engine: WorkspaceEngine
    let store: WorkspaceStore
    static func make(configurations: [CodexRuntimeConfiguration?] = [nil]) async throws -> Self {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-codex-workspace-" + UUID().uuidString)
            .standardizedFileURL.resolvingSymlinksInPath()
        let checkout = root.appendingPathComponent("Checkout", isDirectory: true)
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        let project = WorkspaceProject(path: checkout.path), database = root.appendingPathComponent("workspace.sqlite")
        let threads = configurations.map { configuration in
            var thread = CodingThread(project: project, model: "shared-wire-model")
            thread.checkpointPolicy = .disabled; thread.codexRuntimeConfiguration = configuration
            return thread
        }
        var snapshot = WorkspaceSnapshot(); snapshot.projects = [project]; snapshot.threads = threads
        try await WorkspaceDatabase(url: database).save(snapshot, event: "native.codex.runtime.fixture")
        let metadata = NativeCodexRuntimeMetadata(), runtime = NativeCodexCapturedRuntime()
        let engine = try WorkspaceEngine(url: database, providerFactory: { requested in
            if requested.activeRun != nil { return runtime }
            return NativeCodexRuntimeMetadataPeer(configuration: requested.codexRuntimeConfiguration ?? .init(),
                                                  workspacePath: requested.workspacePath, metadata: metadata)
        }, identityResolver: { _ in nil })
        let installation = CodexInstallation(rootURL: root.appendingPathComponent("Tools/Codex"), release: nil,
            downloader: { _, _, _ in Issue.record("Workspace runtime settings must not download a binary."); throw CoincideError("Unexpected download") },
            inspector: { _, _ in Issue.record("Workspace runtime settings must not launch a CLI."); throw CoincideError("Unexpected inspection") },
            localResolver: { _ in nil })
        let store = WorkspaceStore(engine: engine, codexInstallation: installation); await store.load()
        store.selectedThreadID = threads[0].id; store.selectedProjectID = project.id
        return .init(root: root, database: database, projectID: project.id, threadIDs: threads.map(\.id),
                     metadata: metadata, runtime: runtime, installation: installation, engine: engine, store: store)
    }
    func cleanup() async {
        await metadata.releaseAll(); await store.shutdown(); await installation.shutdown()
        try? FileManager.default.removeItem(at: root)
    }
    func selectNewRuntime(home: String = "HomeTwo") {
        store.codexRuntime.selection = .custom; store.codexRuntime.executable = root.appendingPathComponent("bin/codex-custom").path
        store.codexRuntime.homeDirectory = root.appendingPathComponent(home).path
    }
}
@MainActor private func waitCodexWorkspace(file: StaticString = #fileID, line: UInt = #line,
                                          _ condition: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while try await !condition() {
        guard ContinuousClock.now < deadline else { throw CoincideError("The native Codex runtime boundary timed out at \(file):\(line).") }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@MainActor @Test(.timeLimit(.minutes(1)))
func nativeCodexRuntimeApplyDrainsOldAccountAndCatalogAndFencesNoncancellableLateReplies() async throws {
    let f = try await NativeCodexRuntimeWorkspace.make(), id = f.threadIDs[0]
    do {
        await f.store.refreshModels(provider: .codex); await f.store.refreshCodexAccount()
        #expect(f.store.models(for: try #require(f.store.thread(id))).first?.name == "Existing CLI")
        #expect(f.store.codexAccount.snapshot?.identity.accountID == "Existing CLI")
        await f.metadata.holdLegacyReads()
        let catalog = Task { await f.store.refreshModels(provider: .codex) }
        let account = Task { await f.store.refreshCodexAccount() }
        try await waitCodexWorkspace { await f.metadata.heldReads == 2 }
        f.selectNewRuntime()
        let applying = Task { await f.store.codexRuntime.applySelection() }
        try await waitCodexWorkspace { await f.metadata.heldCloses == 2 }
        #expect(f.store.codexRuntime.isApplying && f.store.codexRuntime.configuration == .init())
        let heldSource = try #require(f.store.thread(id))
        #expect(f.store.codexAccount.snapshot == nil && f.store.models(for: heldSource).isEmpty)
        let readCount = await f.metadata.reads.count
        var freshAccountFinished = false, freshCatalogFinished = false, freshDefaultResult: Bool?
        let freshAccount = Task { await f.store.refreshCodexAccount(); freshAccountFinished = true }
        let freshCatalog = Task { await f.store.refreshModels(provider: .codex); freshCatalogFinished = true }
        let freshDefaults = Task { freshDefaultResult = await f.store.useCodexDefaultModel(id).value }
        try await waitCodexWorkspace { freshAccountFinished && freshCatalogFinished && freshDefaultResult != nil }
        await freshAccount.value; await freshCatalog.value; await freshDefaults.value
        #expect(freshDefaultResult == false)
        #expect(await f.metadata.reads.count == readCount,
                "Fresh account/catalog/default actions cannot start another old-runtime read while Apply is draining its captured owners.")
        #expect(f.store.thread(id)?.model == heldSource.model && f.store.codexAccount.snapshot == nil)
        f.store.setDraft("Keep this latest draft while old processes drain", id: id); f.store.togglePin(id)
        try await waitCodexWorkspace { f.store.thread(id)?.isPinned == true }
        await f.metadata.releaseReads()
        // Both old responses can now return, but their native close boundaries
        // are still held. The new setting cannot claim to have finished yet.
        for _ in 0..<5 { await Task.yield() }
        #expect(f.store.codexRuntime.isApplying && f.store.codexAccount.snapshot == nil)
        await f.metadata.releaseCloses(); await catalog.value; await account.value; await applying.value
        #expect(f.store.codexRuntime.configuration.homeDirectory == f.root.appendingPathComponent("HomeTwo").path)
        #expect(f.store.codexAccount.snapshot == nil && f.store.codexAccount.errorMessage == nil)
        #expect(f.store.models(for: try #require(f.store.thread(id))).isEmpty)
        #expect(f.store.thread(id)?.draft == "Keep this latest draft while old processes drain" && f.store.thread(id)?.isPinned == true)
        #expect(f.store.thread(id)?.codexRuntimeConfiguration == nil)
        f.store.selectedThreadID = nil
        await f.store.refreshCodexAccount(); await f.store.refreshModels(provider: .codex)
        #expect(f.store.codexAccount.snapshot?.identity.accountID == "HomeTwo")
        #expect(f.store.providerModels[.codex]?.first?.name == "HomeTwo")
        f.store.selectedThreadID = id
        #expect(f.store.models(for: try #require(f.store.thread(id))).isEmpty,
                "A neutral catalog for the new global home must not leak into a legacy conversation's old home.")
        #expect(f.store.errorMessage == nil && f.store.codexRuntime.errorMessage == nil)
        #expect(await f.runtime.inputs.isEmpty)
    } catch { await f.cleanup(); throw error }
    await f.cleanup()
}

@MainActor @Test(.timeLimit(.minutes(1)))
func nativeCodexRuntimeChoiceAffectsNewConversationsWithoutRetargetingActiveOrQueuedInputs() async throws {
    let f = try await NativeCodexRuntimeWorkspace.make(), id = f.threadIDs[0]
    do {
        _ = try await f.engine.dispatch(.submit(threadID: id, text: "Original CLI-home input"))
        try await waitCodexWorkspace { f.store.thread(id)?.activeRun?.nativeTurnID != nil }
        _ = try await f.engine.dispatch(.submit(threadID: id, text: "Already captured queued input"))
        try await waitCodexWorkspace { f.store.thread(id)?.queuedTurns.count == 1 }
        let before = try #require(f.store.thread(id)), queued = try #require(before.queuedTurns.first)
        f.store.setDraft("Source draft stays with its original CLI home", id: id)
        f.selectNewRuntime(); await f.store.codexRuntime.applySelection()
        let chosen = f.store.codexRuntime.configuration
        #expect(chosen.selection == .custom && chosen.homeDirectory != nil)
        let source = try #require(f.store.thread(id))
        #expect(source.codexRuntimeConfiguration == before.codexRuntimeConfiguration)
        #expect(source.activeRun?.configuration == before.activeRun?.configuration && source.queuedTurns.first == queued)
        #expect(await f.runtime.closes == 0, "Selecting a future runtime must not close the active conversation's owned stream.")
        f.store.newThread(projectID: f.projectID)
        try await waitCodexWorkspace { f.store.snapshot.threads.count == 2 && f.store.selectedThreadID != id }
        let created = try #require(f.store.selectedThread)
        #expect(created.codexRuntimeConfiguration == chosen && created.draft.isEmpty && created.messages.isEmpty)
        #expect(created.activeRun == nil && created.queuedTurns.isEmpty)
        #expect(f.store.thread(id)?.draft == "Source draft stays with its original CLI home")
        await f.runtime.finish()
        try await waitCodexWorkspace { await f.runtime.inputs.count == 2 }
        let delivered = try #require(await f.runtime.inputs.last)
        #expect(delivered.text == queued.text && delivered.configuration == queued.configuration && delivered.runID == queued.id)
        #expect(delivered.configuration.codexRuntimeBinding == .init() && f.store.selectedThreadID == created.id)
        await f.runtime.finish()
        try await waitCodexWorkspace { f.store.thread(id)?.activeRun == nil && f.store.thread(id)?.queuedTurns.isEmpty == true }
        #expect(f.store.thread(id)?.runHistory?.map { $0.configuration.codexRuntimeBinding } == [.init(), .init()])
        #expect(f.store.thread(created.id)?.codexRuntimeConfiguration == chosen)
        #expect(f.store.errorMessage == nil)
        try WorkspaceJournal.validate(f.store.snapshot)
    } catch { await f.cleanup(); throw error }
    await f.cleanup()
}

@MainActor @Test(.timeLimit(.minutes(1)))
func nativeCodexSameModelIDCatalogsStayScopedToEachConversationRuntimeAndHome() async throws {
    let first = CodexRuntimeConfiguration(selection: .custom, executable: "/fixture/codex", homeDirectory: "/fixture/HomeOne")
    let second = CodexRuntimeConfiguration(selection: .custom, executable: "/fixture/codex", homeDirectory: "/fixture/HomeTwo")
    let f = try await NativeCodexRuntimeWorkspace.make(configurations: [first, second])
    do {
        f.store.providerModels[.codex] = [.init(id: "shared-wire-model", name: "Unrelated global catalog")]
        let firstID = f.threadIDs[0], secondID = f.threadIDs[1]
        #expect(f.store.models(for: try #require(f.store.thread(firstID))).isEmpty)
        await f.store.refreshModels(provider: .codex)
        #expect(f.store.codexReasoningModel(threadID: firstID)?.name == "HomeOne")
        f.store.selectedThreadID = secondID
        #expect(f.store.models(for: .codex).isEmpty && f.store.codexReasoningModel(threadID: secondID) == nil)
        await f.store.refreshModels(provider: .codex)
        #expect(f.store.codexReasoningModel(threadID: secondID)?.name == "HomeTwo")
        f.store.selectedThreadID = firstID
        #expect(f.store.models(for: .codex).first?.name == "HomeOne")
        #expect(f.store.models(for: try #require(f.store.thread(secondID))).first?.name == "HomeTwo")
        #expect(f.store.thread(firstID)?.codexRuntimeConfiguration == first && f.store.thread(secondID)?.codexRuntimeConfiguration == second)
        #expect(await f.metadata.reads.map(\.configuration) == [first, second])
        #expect(await f.runtime.inputs.isEmpty && f.store.errorMessage == nil)
    } catch { await f.cleanup(); throw error }
    await f.cleanup()
}
