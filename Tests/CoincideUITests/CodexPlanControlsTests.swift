import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Coincide
@testable import CoincideCore

@Test(.timeLimit(.minutes(1))) @MainActor
func codexPlanMenuAndFreshImplementationCardFitOffscreenWithoutImplicitActionsAndKeepExactPlanBytes() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-codex-plan-view-" + UUID().uuidString)
    let store = WorkspaceStore(databaseURL: root.appendingPathComponent("workspace.sqlite"))
    defer { try? FileManager.default.removeItem(at: root) }
    let project = WorkspaceProject(path: root.path), row = ProviderModel(id: "native-wire-model", name: "Native captured Codex model", codexInteractionModes: [.default, .plan])
    var thread = CodingThread(project: project, model: row.id)
    thread.agentModeID = "plan"; thread.permission = .auto; thread.draft = "Keep current literal e\u{301}\n "
    store.snapshot.projects = [project]; store.snapshot.threads = [thread]; store.codexModels[thread.id] = [row]
    let plan = "# Exact cafe\u{301} plan\r\n\r\n1. Implement carefully.\r\n", before = thread
    var calls: [String] = []
    let card = PlanCardView(plan: plan, expanded: .constant(true), canImplement: false, canImplementInNewConversation: true,
        implement: { _ in Issue.record("The disabled same-conversation action must remain inert"); return true },
        implementInNewConversation: { literal in calls.append(literal); return true })
    for scheme in [ColorScheme.light, .dark] {
        for width in [CGFloat(240), 640] {
            let menu = NSHostingController(rootView: ProviderMenu(store: store, thread: thread).environment(\.colorScheme, scheme))
            let menuSize = menu.sizeThatFits(in: .init(width: width, height: 4_000))
            #expect(menuSize.width.isFinite && menuSize.width <= width + 1 && menuSize.height > 0)
            let rendered = NSHostingController(rootView: card.environment(\.colorScheme, scheme))
            let size = rendered.sizeThatFits(in: .init(width: width, height: 4_000))
            #expect(size.width.isFinite && size.width <= width + 1 && size.height > 0 && size.height < 1_500)
        }
    }
    #expect(calls.isEmpty && store.snapshot.threads[0] == before)
    let same = await card.requestImplementation()
    #expect(!same && calls.isEmpty)
    let accepted = await card.requestImplementationInNewConversation()
    #expect(accepted && calls.count == 1 && calls[0].utf8.elementsEqual(plan.utf8))
    #expect(store.snapshot.threads[0] == before)
    let disabled = PlanCardView(plan: plan, expanded: .constant(false), canImplementInNewConversation: false,
        implementInNewConversation: { _ in Issue.record("A disabled fresh implementation cannot invoke its owner"); return true })
    let refused = await disabled.requestImplementationInNewConversation()
    #expect(!refused)
    await store.shutdown()
}

private actor ModeMenuPeer: ProviderSession {
    nonisolated let events: AsyncStream<ProviderEvent>
    private let sink: AsyncStream<ProviderEvent>.Continuation
    init() { let pair = AsyncStream<ProviderEvent>.makeStream(); events = pair.stream; sink = pair.continuation }
    func models() -> [ProviderModel] { [] }
    func send(text: String, thread: CodingThread) { Issue.record("Changing a captured mode cannot start a turn") }
    func interrupt() {}
    func respond(_ request: ApprovalRequest, allow: Bool) {}
    func answer(_ request: ApprovalRequest, answers: [String: String]) {}
    func close() { sink.finish() }
}

@Test(.timeLimit(.minutes(1))) @MainActor
func codexPlanStoreRefusesRetainedModeSelectionAfterSameAdvertisedModelEffortChanges() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-codex-mode-cas-" + UUID().uuidString).resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: root) }
    let row = ProviderModel(id: "native-wire-model", name: "Native model", reasoningEfforts: [.init(id: "low", description: "Low"), .init(id: "high", description: "High")],
        defaultReasoningEffort: "low", codexInteractionModes: [.default, .plan])
    let project = WorkspaceProject(path: root.path)
    var thread = CodingThread(project: project, model: row.id)
    thread.reasoningEffort = "high"; thread.draft = "Keep current literal draft e\u{301}\n "; thread.checkpointPolicy = .disabled
    var snapshot = WorkspaceSnapshot(); snapshot.projects = [project]; snapshot.threads = [thread]
    let database = root.appendingPathComponent("workspace.sqlite"), peer = ModeMenuPeer()
    try await WorkspaceDatabase(url: database).save(snapshot, event: "fixture.mode-menu-cas")
    let engine = try WorkspaceEngine(url: database, providerFactory: { _ in peer }, identityResolver: { _ in nil })
    let store = WorkspaceStore(engine: engine)
    do {
        await store.load()
        store.codexModels[thread.id] = [row]
        let selection = CodexModeSelection(thread: thread, mode: .plan, model: row)
        _ = try await engine.dispatch(.editThread(thread.id, .codexReasoning(model: row, effort: "low")))
        let updated = await engine.current()
        store.snapshot = updated.snapshot
        store.codexModels[thread.id] = [row]
        store.setCodexInteractionMode(selection)
        let deadline = ContinuousClock.now + .seconds(3)
        while store.errorMessage == nil {
            guard ContinuousClock.now < deadline else { throw CoincideError("The retained mode menu did not refuse its stale capture.") }
            try await Task.sleep(for: .milliseconds(5))
        }
        let current = await engine.current()
        let saved = try #require(current.snapshot.threads.first { $0.id == thread.id })
        #expect(saved.agentModeID == nil && saved.reasoningEffort == "low" && saved.permission == thread.permission)
        #expect(saved.draft.utf8.elementsEqual(thread.draft.utf8) && saved.activeRun == nil && saved.queuedTurns.isEmpty)
    } catch { await store.shutdown(); throw error }
    await store.shutdown()
}
