import Foundation
import Testing
@testable import Coincide
@testable import CoincideCore

private actor NativeAntigravityCatalogGate {
    private(set) var entered = 0
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func read() async {
        entered += 1
        if !released { await withCheckedContinuation { waiters.append($0) } }
    }
    func release() { released = true; let owned = waiters; waiters = []; owned.forEach { $0.resume() } }
}
private actor NativeAntigravityCatalogPeer: ProviderSession {
    nonisolated let events = AsyncStream<ProviderEvent> { $0.finish() }
    let gate: NativeAntigravityCatalogGate
    let model: ProviderModel
    init(gate: NativeAntigravityCatalogGate, model: ProviderModel) { self.gate = gate; self.model = model }
    func models() async -> [ProviderModel] { await gate.read(); return [model] }
    func send(text: String, thread: CodingThread) throws { throw CoincideError("Catalog fixtures must not submit a provider turn.") }
    func interrupt() {}
    func respond(_ request: ApprovalRequest, allow: Bool) {}
    func answer(_ request: ApprovalRequest, answers: [String: String]) {}
    func close() {}
}
@MainActor private func waitAntigravityStore(file: StaticString = #fileID, line: UInt = #line,
                                           _ predicate: () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while !(await predicate()) {
        guard ContinuousClock.now < deadline else { throw CoincideError("Antigravity Store boundary timed out at \(file):\(line).") }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@Test @MainActor func nativeChoosingAntigravityIsUnavailableWithoutChangingSavedAccountOrDiscardingDraft() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-antigravity-provider-" + UUID().uuidString)
        .standardizedFileURL.resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let configuration = AntigravityConfiguration(executable: "/fixture/agy_acp_server.par", harnessPath: "/fixture/localharness_external",
        authMethod: .agentPlatform, gcpProject: "native-project", gcpLocation: "us-central1", authGeneration: UUID(), model: "saved-native-model")
    try AntigravityAccountRegistry.save(.init(configuration: configuration, accessState: .verified),
                                      rootURL: root.appendingPathComponent("AntigravitySettings"))
    let project = WorkspaceProject(path: root.path), database = root.appendingPathComponent("workspace.sqlite")
    var thread = CodingThread(project: project); thread.draft = "Unsent draft 工作 🌍"; thread.isPinned = true
    var snapshot = WorkspaceSnapshot(); snapshot.projects = [project]; snapshot.threads = [thread]
    try await WorkspaceDatabase(url: database).save(snapshot, event: "antigravity.native.provider.fixture")
    let engine = try WorkspaceEngine(url: database,
        providerFactory: { _ in throw CoincideError("Changing a provider must not start a native process.") }, identityResolver: { _ in nil })
    let store = WorkspaceStore(engine: engine); await store.load()
    do {
        #expect(store.antigravityAccount.configuration == configuration)
        store.setProvider(.antigravity, id: thread.id)
        let current = try #require(store.thread(thread.id))
        #expect(current.provider == thread.provider && current.model == thread.model && current.antigravityConfiguration == nil)
        #expect(store.errorMessage?.contains("Codex and Claude only") == true)
        #expect(store.antigravityAccount.configuration == configuration)
        #expect(current.draft == thread.draft && current.isPinned && current.messages.isEmpty && current.activeRun == nil)
        #expect(try await WorkspaceDatabase(url: database).effects().isEmpty)
        #expect(await engine.current().error == nil)
    } catch { await store.shutdown(); try? FileManager.default.removeItem(at: root); throw error }
    await store.shutdown(); try FileManager.default.removeItem(at: root)
}

@Test @MainActor func nativeAntigravityModelRefreshIsUnavailableAndPreservesLegacyRuntimeChanges() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-antigravity-catalog-" + UUID().uuidString)
        .standardizedFileURL.resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let original = AntigravityConfiguration(executable: "/fixture/original-server", authGeneration: UUID())
    let replacement = AntigravityConfiguration(executable: "/fixture/replacement-server", authGeneration: UUID())
    try AntigravityAccountRegistry.save(.init(configuration: original, accessState: .verified), rootURL: root.appendingPathComponent("AntigravitySettings"))
    let project = WorkspaceProject(path: root.path), database = root.appendingPathComponent("workspace.sqlite")
    var thread = CodingThread(project: project); thread.provider = .antigravity; thread.antigravityConfiguration = original
    thread.draft = "Keep this unsent draft"
    var snapshot = WorkspaceSnapshot(); snapshot.projects = [project]; snapshot.threads = [thread]
    try await WorkspaceDatabase(url: database).save(snapshot, event: "antigravity.native.catalog.fixture")
    let gate = NativeAntigravityCatalogGate()
    let engine = try WorkspaceEngine(url: database, providerFactory: { request in
        #expect(request.activeRun == nil && request.provider == .antigravity)
        let old = request.antigravityConfiguration?.runtimeIdentity == original.runtimeIdentity
        return NativeAntigravityCatalogPeer(gate: gate, model: .init(id: old ? "stale-model" : "current-model", name: old ? "Old account" : "Current account"))
    }, identityResolver: { _ in nil })
    let store = WorkspaceStore(engine: engine); await store.load()
    do {
        await store.refreshModels(provider: .antigravity)
        #expect(await gate.entered == 0)
        #expect(store.modelCatalogErrors[.antigravity]?.contains("Codex and Claude only") == true)
        #expect(store.thread(thread.id)?.antigravityConfiguration == original)
        let receipt = try await engine.dispatch(.editThread(thread.id, .antigravityConfiguration(replacement)))
        #expect(receipt.rejection == nil)
        try await waitAntigravityStore { store.thread(thread.id)?.antigravityConfiguration == replacement }
        #expect(store.models(for: try #require(store.thread(thread.id))).isEmpty)
        #expect(store.thread(thread.id)?.draft == thread.draft)
        await store.refreshModels(provider: .antigravity)
        #expect(store.models(for: try #require(store.thread(thread.id))).isEmpty)
        #expect(await gate.entered == 0)
        #expect(store.thread(thread.id)?.antigravityConfiguration == replacement)
        #expect(store.modelCatalogErrors[.antigravity]?.contains("Codex and Claude only") == true)
        #expect(try await WorkspaceDatabase(url: database).effects().isEmpty)
        #expect(await engine.current().error == nil)
    } catch { await gate.release(); await store.shutdown(); try? FileManager.default.removeItem(at: root); throw error }
    await store.shutdown(); try FileManager.default.removeItem(at: root)
}
