@testable import CoincideCore
import Foundation
import Testing
@testable import Coincide

private actor ClaudeProfileCatalogReads {
    private(set) var runtimes: [ClaudeRuntimeConfiguration] = []
    private(set) var launches: [ProviderConfiguration] = []
    private(set) var closes = 0
    private(set) var held = false
    private var holdNext = false
    private var replies: [CheckedContinuation<Void, Never>] = []
    func holdNextRead() { holdNext = true }
    func record(_ configuration: ProviderConfiguration) async {
        launches.append(configuration)
        if let runtime = configuration.claudeRuntimeConfiguration { runtimes.append(runtime) }
        if holdNext {
            holdNext = false; held = true
            await withCheckedContinuation { replies.append($0) }
            held = false
        }
    }
    func releaseReply() {
        holdNext = false
        let owned = replies; replies = []; owned.forEach { $0.resume() }
    }
    func closed() { closes += 1 }
}
private actor ClaudeProfileCatalogPeer: ProviderSession {
    nonisolated let events = AsyncStream<ProviderEvent> { $0.finish() }
    let configuration: ProviderConfiguration
    let reads: ClaudeProfileCatalogReads
    init(configuration: ProviderConfiguration, reads: ClaudeProfileCatalogReads) { self.configuration = configuration; self.reads = reads }
    func models() async -> [ProviderModel] {
        await reads.record(configuration)
        let name = configuration.claudeRuntimeConfiguration.map { URL(fileURLWithPath: $0.configurationDirectory).lastPathComponent } ?? "Legacy CLI"
        return [.init(id: "same-model", name: name)]
    }
    func send(text: String, thread: CodingThread) { Issue.record("Profile selection and catalog reads cannot submit a prompt") }
    func interrupt() {}
    func respond(_ request: ApprovalRequest, allow: Bool) {}
    func answer(_ request: ApprovalRequest, answers: [String: String]) {}
    func close() async { await reads.closed() }
}

@MainActor private struct ClaudeProfileWorkspaceFixture {
    let root: URL, project: WorkspaceProject, threadID: UUID
    let reads: ClaudeProfileCatalogReads
    let store: WorkspaceStore
    static func make(legacyClaude: Bool = false) async throws -> Self {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-claude-profile-ui-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let project = WorkspaceProject(path: root.path), database = root.appendingPathComponent("workspace.sqlite")
        var thread = CodingThread(project: project); thread.checkpointPolicy = .disabled; thread.draft = "Keep existing draft"
        if legacyClaude {
            thread.provider = .claude; thread.providerThreadID = UUID().uuidString
            thread.messages = [.init(role: .user, text: "Original legacy input"), .init(role: .assistant, text: "Original legacy response")]
            var historical = ThreadRunRecord(run: .init(id: UUID(), configuration: .init(thread: thread), startedAt: .now.addingTimeInterval(-60)), origin: .legacy)
            historical.status = .completed; historical.endedAt = .now.addingTimeInterval(-30)
            historical.endReason = .providerCompleted
            thread.runHistory = [historical]
        }
        var snapshot = WorkspaceSnapshot(); snapshot.projects = [project]; snapshot.threads = [thread]
        try await WorkspaceDatabase(url: database).save(snapshot, event: "claude.profile.ui.fixture")
        let reads = ClaudeProfileCatalogReads()
        let engine = try WorkspaceEngine(url: database, providerFactory: { requested in
            guard requested.provider == .claude else { throw CoincideError("Expected Claude metadata discovery") }
            return ClaudeProfileCatalogPeer(configuration: .init(thread: requested), reads: reads)
        }, identityResolver: { _ in nil })
        let store = WorkspaceStore(engine: engine); await store.load()
        return .init(root: root, project: project, threadID: thread.id, reads: reads, store: store)
    }
    func select(home: String, window: String) async {
        store.claudeRuntime.executable = "/usr/bin/true"
        store.claudeRuntime.configurationDirectory = root.appendingPathComponent(home).path
        store.claudeRuntime.autoCompactWindowText = window
        await store.claudeRuntime.applySelection()
    }
    func cleanup() async { await store.shutdown(); try? FileManager.default.removeItem(at: root) }
}

@Test @MainActor func claudeRuntimeWorkspaceProfileSelectionCapturesFutureConversationWithoutRetargetingExistingOne() async throws {
    let f = try await ClaudeProfileWorkspaceFixture.make()
    do {
        await f.select(home: "HomeOne", window: "200000")
        #expect(f.store.claudeRuntime.isLoaded && f.store.claudeRuntime.errorMessage == nil)
        f.store.setProvider(.claude, id: f.threadID)
        try await waitNativeSetup { f.store.thread(f.threadID)?.provider == .claude }
        let original = try #require(f.store.thread(f.threadID)?.claudeRuntimeConfiguration)
        #expect(original.launchSettings?.autoCompactWindow == 200_000)
        #expect(original.instanceID == f.store.claudeRuntime.profile.instanceID)
        await f.select(home: "HomeTwo", window: "300000")
        #expect(f.store.thread(f.threadID)?.claudeRuntimeConfiguration == original)
        #expect(f.store.thread(f.threadID)?.draft == "Keep existing draft")
        f.store.newThread(projectID: f.project.id)
        try await waitNativeSetup { f.store.selectedThreadID != f.threadID && f.store.snapshot.threads.count == 2 }
        let newID = try #require(f.store.selectedThreadID)
        f.store.setProvider(.claude, id: newID)
        try await waitNativeSetup { f.store.thread(newID)?.provider == .claude }
        let fresh = try #require(f.store.thread(newID)?.claudeRuntimeConfiguration)
        #expect(fresh.instanceID != original.instanceID && fresh.configurationDirectory.hasSuffix("/HomeTwo"))
        #expect(fresh.launchSettings?.autoCompactWindow == 300_000)
        #expect(f.store.thread(newID)?.messages.isEmpty == true && f.store.thread(newID)?.activeRun == nil)
        #expect(await f.reads.runtimes.isEmpty)
    } catch { await f.cleanup(); throw error }
    await f.cleanup()
}

@Test @MainActor func claudeRuntimeWorkspaceCatalogsUseSelectedProfileAndCorruptReloadCannotFallBackToDefault() async throws {
    let f = try await ClaudeProfileWorkspaceFixture.make()
    do {
        await f.select(home: "HomeOne", window: "200000")
        f.store.selectedThreadID = nil
        await f.store.refreshModels(provider: .claude)
        #expect(f.store.models(for: .claude).first?.name == "HomeOne")
        let first = try #require(await f.reads.runtimes.first)
        #expect(first.launchSettings?.autoCompactWindow == 200_000)
        await f.select(home: "HomeTwo", window: "300000")
        #expect(f.store.models(for: .claude).isEmpty)
        await f.store.refreshModels(provider: .claude)
        #expect(f.store.models(for: .claude).first?.name == "HomeTwo")
        #expect(await f.reads.closes == 2)
        let file = f.root.appendingPathComponent("ClaudeSettings/profile.json")
        try Data("Damaged settings remain available for recovery".utf8).write(to: file)
        await f.store.claudeRuntime.load()
        #expect(!f.store.claudeRuntime.isLoaded)
        #expect(f.store.models(for: .claude).isEmpty)
        let readsBefore = await f.reads.runtimes.count
        await f.store.refreshModels(provider: .claude)
        #expect(await f.reads.runtimes.count == readsBefore)
        #expect(f.store.models(for: .claude).isEmpty)
        f.store.setProvider(.claude, id: f.threadID)
        #expect(f.store.thread(f.threadID)?.provider == .codex)
        #expect(f.store.thread(f.threadID)?.claudeRuntimeConfiguration == nil)
        #expect(try String(contentsOf: file, encoding: .utf8) == "Damaged settings remain available for recovery")
    } catch { await f.cleanup(); throw error }
    await f.cleanup()
}

@Test(.timeLimit(.minutes(1))) @MainActor
func claudeRuntimeWorkspaceLateNeutralReplyCannotPublishAfterCorruptReloadButCapturedConversationStillRefreshes() async throws {
    let f = try await ClaudeProfileWorkspaceFixture.make()
    var refreshing: Task<Void, Never>?
    do {
        await f.select(home: "CapturedHome", window: "200000")
        f.store.setProvider(.claude, id: f.threadID)
        try await waitNativeSetup { f.store.thread(f.threadID)?.provider == .claude }
        let captured = try #require(f.store.thread(f.threadID)?.claudeRuntimeConfiguration)
        await f.select(home: "FutureHome", window: "300000")
        f.store.selectedThreadID = nil
        #expect(f.store.providerModels[.claude] == nil)
        await f.reads.holdNextRead()
        let read = Task { await f.store.refreshModels(provider: .claude) }
        refreshing = read
        try await waitNativeSetup { await f.reads.held }
        #expect(await f.reads.closes == 0)
        let inFlight = try #require(await f.reads.runtimes.first)
        #expect(inFlight.configurationDirectory.hasSuffix("/FutureHome") && inFlight.launchSettings?.autoCompactWindow == 300_000)

        let file = f.root.appendingPathComponent("ClaudeSettings/profile.json")
        let damaged = "Preserve the damaged profile during an in-flight catalog read"
        try Data(damaged.utf8).write(to: file)
        await f.store.claudeRuntime.load()
        #expect(!f.store.claudeRuntime.isLoaded && f.store.models(for: .claude).isEmpty)
        await f.reads.releaseReply(); await read.value; refreshing = nil
        #expect(await f.reads.closes == 1, "Rejected publication must still join the exact metadata session's close.")
        #expect(f.store.providerModels[.claude] == nil, "The late neutral reply must not repopulate even a hidden cache.")
        #expect(f.store.models(for: .claude).isEmpty)

        // A damaged future-default preference cannot disable a conversation
        // which already owns an exact, previously accepted runtime capture.
        f.store.selectedThreadID = f.threadID
        await f.store.refreshModels(provider: .claude)
        #expect(f.store.models(for: .claude).first?.name == "CapturedHome")
        let all = await f.reads.runtimes
        #expect(all.count == 2 && all.last == captured)
        #expect(await f.reads.closes == 2)
        #expect(f.store.thread(f.threadID)?.claudeRuntimeConfiguration == captured)
        #expect(f.store.thread(f.threadID)?.draft == "Keep existing draft")
        #expect(try String(contentsOf: file, encoding: .utf8) == damaged)
    } catch {
        await f.reads.releaseReply(); await refreshing?.value
        await f.cleanup(); throw error
    }
    await f.cleanup()
}

@Test @MainActor func claudeRuntimeWorkspaceLegacyConversationCatalogIgnoresFutureProfileAndNeverResumesItsStoredNativeID() async throws {
    let f = try await ClaudeProfileWorkspaceFixture.make(legacyClaude: true)
    do {
        let original = try #require(f.store.thread(f.threadID))
        #expect(original.claudeRuntimeConfiguration == nil && original.providerThreadID != nil && original.runHistory?.isEmpty == false)
        await f.select(home: "FutureHome", window: "300000")
        f.store.selectedThreadID = nil
        await f.store.refreshModels(provider: .claude)
        #expect(f.store.models(for: .claude).first?.name == "FutureHome")
        f.store.selectedThreadID = f.threadID
        #expect(f.store.models(for: .claude).isEmpty, "A neutral future-profile catalog cannot populate a legacy conversation.")
        await f.store.refreshModels(provider: .claude)
        #expect(f.store.models(for: .claude).first?.name == "Legacy CLI")
        let launches = await f.reads.launches
        #expect(launches.count == 2)
        let legacyLaunch = try #require(launches.last)
        #expect(legacyLaunch.claudeRuntimeConfiguration == nil && legacyLaunch.claudeLaunchSelection == nil)
        #expect(legacyLaunch.nativeThreadID == nil, "Read-only metadata uses a fresh process and must not resume native conversation history.")
        #expect(await f.reads.runtimes.count == 1)
        #expect(await f.reads.closes == 2)
        await f.select(home: "LaterFutureHome", window: "400000")
        #expect(f.store.models(for: .claude).first?.name == "Legacy CLI")
        let retained = try #require(f.store.thread(f.threadID))
        #expect(retained == original, "Catalog refreshes and future-profile changes cannot rewrite the legacy native ID, history, or current draft.")
        #expect(retained.providerThreadID == original.providerThreadID && retained.draft == "Keep existing draft")
        #expect(retained.claudeRuntimeConfiguration == nil)
    } catch { await f.cleanup(); throw error }
    await f.cleanup()
}
