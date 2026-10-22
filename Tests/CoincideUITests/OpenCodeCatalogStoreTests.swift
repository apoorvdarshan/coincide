import Foundation
import Testing
@testable import Coincide
@testable import CoincideCore

@Test func nativeOpenCodeRunHistoryUsesCapturedWireFieldsWithoutCatalogOrMenuHashes() {
    var thread = CodingThread(project: WorkspaceProject(path: "/tmp/native-opencode-history-display"))
    let wire = OpenCodeModelSelection(providerID: "provider/native", id: "model/native", variant: "deep")
    thread.provider = .opencode; thread.model = wire.catalogID; thread.openCodeConfiguration = .init(model: wire, agentID: "plan")
    let captured = ProviderConfiguration(thread: thread)
    thread.openCodeConfiguration = thread.openCodeConfiguration?.selecting(agentID: "build")
    let display = RunHistoryPresentation.model(captured)
    #expect(display.contains("provider/native / model/native") && display.contains("deep") && display.contains("plan"))
    #expect(!display.contains(wire.catalogID) && !display.contains("build"))
    #expect(RunHistoryPresentation.provider(captured) == "OpenCode")
}

@MainActor @Test(.timeLimit(.minutes(1)))
func nativeOpenCodeStaleMenuResolvesCatalogAtCommandHeadAndKeepsAcceptedSelection() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-native-opencode-store-" + UUID().uuidString)
        .standardizedFileURL.resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let project = WorkspaceProject(path: root.path), wire = OpenCodeModelSelection(providerID: "provider/native", id: "model/native")
    var thread = CodingThread(project: project, model: wire.catalogID)
    thread.provider = .opencode; thread.openCodeConfiguration = .init(model: wire); thread.checkpointPolicy = .disabled
    var snapshot = WorkspaceSnapshot(); snapshot.projects = [project]; snapshot.threads = [thread]
    let url = root.appendingPathComponent("workspace.sqlite")
    try await WorkspaceDatabase(url: url).save(snapshot, event: "opencode.store.fixture")
    let engine = try WorkspaceEngine(url: url, providerFactory: { _ in throw CoincideError("Editing a native menu must not start a provider.") }, identityResolver: { _ in nil })
    let store = WorkspaceStore(engine: engine); await store.load()
    do {
        let identity = OpenCodeServerIdentity(generation: .v2, version: try OpenCodeVersion("2.1.2"), processIdentifier: 1)
        let oldModel = OpenCodeModelDescriptor(selection: wire, name: "Native model", variants: ["deep", "balanced"], enabled: true, input: ["text"], output: ["text"], tools: true)
        let agent = OpenCodeAgentDescriptor(id: "plan", name: "Plan", description: nil, mode: .primary, hidden: false)
        store.openCodeCatalogs[thread.id] = .init(server: identity, directory: root.path, models: [oldModel], agents: [agent], defaults: [wire])
        let advertised = try #require(store.models(for: thread).first)
        #expect(await store.setOpenCodeVariant("deep", model: advertised, threadID: thread.id).value)
        let accepted = try #require(store.thread(thread.id)?.openCodeConfiguration)
        let pending = store.setOpenCodeVariant("deep", model: advertised, threadID: thread.id)
        let agentPending = store.setOpenCodeAgent("plan", threadID: thread.id)
        // Both commands are waiting on the MainActor/command tail. Replace the
        // same-ID catalog before preparation, as a concurrent refresh can do.
        let replacement = OpenCodeModelDescriptor(selection: wire, name: "Updated native model", variants: ["balanced"], enabled: true, input: ["text"], output: ["text"], tools: true)
        store.openCodeCatalogs[thread.id] = .init(server: identity, directory: root.path, models: [replacement], agents: [], defaults: [wire])
        let variantAccepted = await pending.value, agentAccepted = await agentPending.value
        #expect(!variantAccepted && !agentAccepted)
        #expect(store.thread(thread.id)?.openCodeConfiguration == accepted)
        #expect(store.errorMessage != nil)
        #expect(await store.setOpenCodeVariant(nil, model: advertised, threadID: thread.id).value)
        #expect(store.thread(thread.id)?.openCodeConfiguration?.model == wire)
        #expect(store.thread(thread.id)?.openCodeConfiguration?.agentID == "build")
        #expect(store.models(for: .opencode).first?.name == "Updated native model")
        try WorkspaceJournal.validate(store.snapshot)
        #expect(try await WorkspaceDatabase(url: url).effects().isEmpty)
    } catch {
        await store.shutdown(); try? FileManager.default.removeItem(at: root); throw error
    }
    await store.shutdown(); try FileManager.default.removeItem(at: root)
}
