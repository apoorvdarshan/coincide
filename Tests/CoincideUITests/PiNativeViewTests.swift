import AppKit
@testable import CoincideCore
import Foundation
import SwiftUI
import Testing
@testable import Coincide

@Test func nativePiRunHistoryShowsCapturedNativeValuesInsteadOfOpaqueMenuKeys() {
    let selected = PiModelSelection(provider: "provider/native", modelID: "model/native")
    var thread = CodingThread(project: .init(path: "/tmp/pi-history-ui"))
    thread.provider = .pi; thread.piConfiguration = .init(model: selected, thinkingLevel: "max"); thread.model = selected.catalogID
    let captured = ProviderConfiguration(thread: thread)
    let display = RunHistoryPresentation.model(captured)
    #expect(display.contains("provider/native / model/native") && display.contains("max") && !display.contains(selected.catalogID))
    #expect(RunHistoryPresentation.provider(captured) == "Pi")
    #expect(captured.permissionSummary == "Ask")
}

@Test @MainActor func nativePiThinkingSelectionResolvesCurrentCatalogAtCommandHead() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-pi-native-ui-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let project = WorkspaceProject(path: root.path), selected = PiModelSelection(provider: "native-provider", modelID: "native-model")
    var thread = CodingThread(project: project); thread.provider = .pi; thread.piConfiguration = .init(model: selected); thread.model = selected.catalogID
    var snapshot = WorkspaceSnapshot(); snapshot.projects = [project]; snapshot.threads = [thread]
    let url = root.appendingPathComponent("pi.sqlite")
    try await WorkspaceDatabase(url: url).save(snapshot, event: "pi.ui.fixture")
    let engine = try WorkspaceEngine(url: url, providerFactory: { _ in throw CoincideError("Editing a Pi model must not start a provider.") }, identityResolver: { _ in nil })
    let store = WorkspaceStore(engine: engine); await store.load()
    do {
        let model = ProviderModel(id: selected.catalogID, name: "Original model", piSelection: selected, piThinkingLevels: ["off", "high", "max"])
        store.piModels[thread.id] = [model]
        #expect(await store.setPiThinking("high", model: model, threadID: thread.id).value)
        let accepted = store.thread(thread.id)?.piConfiguration
        let pending = store.setPiThinking("max", model: model, threadID: thread.id)
        store.piModels[thread.id] = [.init(id: model.id, name: "Refreshed model", piSelection: selected, piThinkingLevels: ["off", "high"])]
        #expect(!(await pending.value))
        #expect(store.thread(thread.id)?.piConfiguration == accepted)
        #expect(await engine.current().error == nil)
        #expect(await store.setPiThinking(nil, model: model, threadID: thread.id).value)
        #expect(store.thread(thread.id)?.piConfiguration?.thinkingLevel == nil)
        #expect(store.models(for: store.thread(thread.id)!).first?.name == "Refreshed model")
        #expect(try await WorkspaceDatabase(url: url).effects().isEmpty)
    } catch { await store.shutdown(); try? FileManager.default.removeItem(at: root); throw error }
    await store.shutdown(); try FileManager.default.removeItem(at: root)
}

@Test @MainActor func nativePiDialogRenderingPreservesPrefillAndNeverApprovesOrSubmitsOnAppearance() throws {
    var decisions = 0, answers = 0, choices = 0
    let longMessage = String(repeating: "Review the actual native request 工作 🌍. ", count: 80)
    for method in ["confirm", "select", "input", "editor"] {
        let request = ApprovalRequest(id: .string("local-\(method)"), method: "pi/extension", params: .object([
            "method": .string(method), "title": .string("Native \(method)"), "message": .string(longMessage),
            "options": .array([.string("A/B"), .string("A B")]), "prefill": .string("Keep exact\n editor 工作 🌍 ")
        ]))
        #expect(request.piExtension?.prefill == "Keep exact\n editor 工作 🌍 ")
        let view = ApprovalView(request: request, onDecision: { _ in decisions += 1 }, onAnswer: { _ in answers += 1 }, onOption: { _ in choices += 1 })
        let host = NSHostingView(rootView: view.frame(width: 320))
        host.frame = .init(x: 0, y: 0, width: 320, height: 500); host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.width <= 321 && host.fittingSize.height < 720)
    }
    #expect(decisions == 0 && answers == 0 && choices == 0)
}
