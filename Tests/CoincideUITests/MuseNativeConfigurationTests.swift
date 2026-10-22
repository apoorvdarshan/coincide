import Foundation
import Testing
@testable import Coincide
@testable import CoincideCore

@Test @MainActor func nativeMuseReasoningRejectsStaleChoicesWithoutPoisoningTheWorkspaceOrStartingAProvider() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-muse-native-config-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let project = WorkspaceProject(path: root.path), selection = MuseModelSelection(modelID: "native-model")
    var thread = CodingThread(project: project); thread.provider = .muse
    thread.museConfiguration = .init(model: selection); thread.model = selection.catalogID
    var snapshot = WorkspaceSnapshot(); snapshot.projects = [project]; snapshot.threads = [thread]
    let url = root.appendingPathComponent("workspace.sqlite")
    try await WorkspaceDatabase(url: url).save(snapshot, event: "muse.native.fixture")
    let engine = try WorkspaceEngine(url: url, providerFactory: { _ in throw CoincideError("Choosing Muse reasoning must not start a provider.") }, identityResolver: { _ in nil })
    let store = WorkspaceStore(engine: engine); await store.load()
    do {
        let options = ["low", "high", "max"].map { ProviderReasoningEffortOption(id: $0, description: $0) }
        let row = ProviderModel(id: selection.catalogID, name: "Original", reasoningEfforts: options, defaultReasoningEffort: "low",
            museSelection: selection, museReasoningEfforts: options, museDefaultReasoningEffort: "low")
        store.museModels[thread.id] = [row]
        #expect(await store.setMuseReasoning("high", model: row, threadID: thread.id).value)
        let before = store.thread(thread.id)?.museConfiguration
        let pending = store.setMuseReasoning("max", model: row, threadID: thread.id)
        let current = Array(options.prefix(2))
        store.museModels[thread.id] = [.init(id: row.id, name: "Refreshed", reasoningEfforts: current, defaultReasoningEffort: "low",
            museSelection: selection, museReasoningEfforts: current, museDefaultReasoningEffort: "low")]
        #expect(!(await pending.value))
        #expect(store.thread(thread.id)?.museConfiguration == before)
        #expect(await engine.current().error == nil)
        #expect(await store.setMuseReasoning(nil, model: row, threadID: thread.id).value)
        #expect(store.thread(thread.id)?.museConfiguration?.reasoningEffort == nil)
        #expect(store.models(for: store.thread(thread.id)!).first?.name == "Refreshed")
        #expect(try await WorkspaceDatabase(url: url).effects().isEmpty)
    } catch { await store.shutdown(); try? FileManager.default.removeItem(at: root); throw error }
    await store.shutdown(); try FileManager.default.removeItem(at: root)
}

@Test func nativeMuseRunHistoryUsesCapturedNativeSettingsWithoutOpaqueMenuKeys() {
    var thread = CodingThread(project: .init(path: "/tmp/muse-run-history"))
    let selected = MuseModelSelection(modelID: "muse-native/model")
    thread.provider = .muse; thread.model = selected.catalogID
    thread.museConfiguration = .init(model: selected, reasoningEffort: "high")
    let captured = ProviderConfiguration(thread: thread)
    thread.museConfiguration = .init(model: .init(modelID: "future-model"), reasoningEffort: "low")
    let display = RunHistoryPresentation.model(captured)
    #expect(display.contains("muse-native/model") && display.contains("high"))
    #expect(!display.contains(selected.catalogID) && !display.contains("future-model"))
    #expect(RunHistoryPresentation.provider(captured) == "Muse" && captured.permissionSummary == "Ask")
}
