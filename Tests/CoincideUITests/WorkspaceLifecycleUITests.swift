import AppKit
import CoincideCore
import Foundation
import SwiftUI
import Testing
@testable import Coincide

@MainActor private struct LifecycleUIFixture {
    let root: URL, database: URL
    let project: WorkspaceProject
    let threadID: UUID
    let provider: NativeSetupProvider
    let engine: WorkspaceEngine
    let store: WorkspaceStore
    static func make() async throws -> Self {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-lifecycle-ui-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let project = WorkspaceProject(path: root.path), database = root.appendingPathComponent("workspace.sqlite")
        let agent = ACPAgentConfiguration(name: "Lifecycle fixture", executable: "/usr/bin/true")
        var thread = CodingThread(project: project)
        thread.provider = .acp; thread.acpAgent = agent; thread.checkpointPolicy = .disabled
        thread.createdAt = Date().addingTimeInterval(-10 * 86_400); thread.updatedAt = thread.createdAt
        thread.draft = "Keep my unsent draft 😀"
        var snapshot = WorkspaceSnapshot(); snapshot.projects = [project]; snapshot.threads = [thread]; snapshot.acpAgents = [agent]
        try await WorkspaceDatabase(url: database).save(snapshot, event: "lifecycle.ui.fixture")
        let provider = NativeSetupProvider()
        let engine = try WorkspaceEngine(url: database, providerFactory: { _ in provider }, identityResolver: { _ in nil })
        let store = WorkspaceStore(engine: engine); await store.load()
        return .init(root: root, database: database, project: project, threadID: thread.id, provider: provider, engine: engine, store: store)
    }
    func cleanup() async { await store.shutdown(); try? FileManager.default.removeItem(at: root) }
}

@Test @MainActor func workspaceLifecycleNativeSnoozeRetainsRunningInputAndDraftButRefusesAuthoredQueue() async throws {
    let f = try await LifecycleUIFixture.make(), until = Date().addingTimeInterval(3_600)
    do {
        _ = try await f.engine.dispatch(.submit(threadID: f.threadID, text: "Already running"))
        try await waitNativeSetup { f.store.thread(f.threadID)?.activeRun?.nativeTurnID != nil }
        let run = try #require(f.store.thread(f.threadID)?.activeRun)
        #expect(f.store.canSnooze(try #require(f.store.thread(f.threadID))))
        f.store.setDraft("A newer unsent draft survives snoozing", id: f.threadID)
        try await f.store.snoozeThread(f.threadID, until: until)
        #expect(f.store.thread(f.threadID)?.workspaceLifecycle?.snoozedUntil == until)
        #expect(f.store.thread(f.threadID)?.draft == "A newer unsent draft survives snoozing")
        #expect(f.store.thread(f.threadID)?.activeRun?.id == run.id)
        #expect(await f.provider.calls.count == 1)
        _ = try await f.engine.dispatch(.submit(threadID: f.threadID, text: "Queued explicit input"))
        try await waitNativeSetup { f.store.thread(f.threadID)?.queuedTurns.count == 1 }
        #expect(!f.store.canSnooze(try #require(f.store.thread(f.threadID))))
        await #expect(throws: (any Error).self) { try await f.store.snoozeThread(f.threadID, until: until.addingTimeInterval(60)) }
        #expect(f.store.thread(f.threadID)?.queuedTurns.first?.text == "Queued explicit input")
        #expect(f.store.thread(f.threadID)?.activeRun?.id == run.id)
    } catch { await f.cleanup(); throw error }
    await f.cleanup()
}

@Test @MainActor func workspaceLifecycleNativeQueuedPolicyFieldsAndSnoozeSurviveReopeningWithoutSending() async throws {
    let f = try await LifecycleUIFixture.make(), until = Date().addingTimeInterval(3_600)
    do {
        f.store.setAutoSettlementAfterDays(9)
        f.store.setAutoSettlementOnMerge(false)
        f.store.setAutoSettlementKeepsPullRequests(true)
        try await f.store.snoozeThread(f.threadID, until: until)
        #expect(f.store.workspaceLifecyclePolicy == .init(afterDays: 9, onMerge: false, keepPullRequests: true))
        f.store.setAutoSettlement(f.threadID, enabled: false)
        try await waitNativeSetup { f.store.thread(f.threadID)?.workspaceLifecycle?.autoSettleDisabledAt != nil }
        await f.store.shutdown()
        let engine = try WorkspaceEngine(url: f.database, providerFactory: { _ in Issue.record("Restoring lifecycle settings cannot start a provider"); return f.provider }, identityResolver: { _ in nil })
        let reopened = WorkspaceStore(engine: engine); await reopened.load()
        #expect(reopened.workspaceLifecyclePolicy == .init(afterDays: 9, onMerge: false, keepPullRequests: true))
        #expect(reopened.thread(f.threadID)?.workspaceLifecycle?.snoozedUntil == until)
        #expect(reopened.thread(f.threadID)?.draft == "Keep my unsent draft 😀")
        #expect(reopened.thread(f.threadID)?.settlement == nil)
        #expect(await f.provider.calls.isEmpty)
        reopened.wakeThread(f.threadID)
        try await waitNativeSetup { reopened.thread(f.threadID)?.workspaceLifecycle?.snoozedUntil == nil }
        #expect(reopened.thread(f.threadID)?.workspaceLifecycle?.lastSnoozeWakeAt != nil)
        #expect(reopened.thread(f.threadID)?.workspaceLifecycle?.autoSettleDisabledAt != nil)
        await reopened.shutdown()
    } catch { await f.cleanup(); throw error }
    await f.cleanup()
}

@Test @MainActor func workspaceLifecycleNativeSettingsAndSnoozeFitOffscreenInBothAppearances() async throws {
    let f = try await LifecycleUIFixture.make()
    do {
        _ = NSApplication.shared
        let presentation = ThreadSnoozePresentation(try #require(f.store.thread(f.threadID)))
        for scheme in [ColorScheme.light, .dark] {
            let settings = NSHostingController(rootView: Form { WorkspaceLifecycleSettingsSection(store: f.store) }
                .formStyle(.grouped).environment(\.colorScheme, scheme).frame(width: 360, height: 560))
            let snooze = NSHostingController(rootView: ThreadSnoozeSheet(presentation: presentation, snooze: { _ in Issue.record("Offscreen layout cannot snooze") }, dismiss: { })
                .environment(\.colorScheme, scheme))
            let settingsSize = settings.sizeThatFits(in: .init(width: 360, height: 560))
            let sheetSize = snooze.sizeThatFits(in: .init(width: 440, height: 620))
            for (host, size, limit) in [(settings as NSViewController, settingsSize, CGSize(width: 360, height: 560)),
                                      (snooze as NSViewController, sheetSize, CGSize(width: 440, height: 620))] {
                #expect(size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0)
                #expect(size.width <= limit.width && size.height <= limit.height)
                host.view.frame = .init(origin: .zero, size: size)
                host.view.layoutSubtreeIfNeeded()
                #expect(host.view.window == nil)
            }
            #expect(sheetSize.width <= 440 && sheetSize.height <= 620 && sheetSize.height > 200)
        }
        #expect(await f.provider.calls.isEmpty)
    } catch { await f.cleanup(); throw error }
    await f.cleanup()
}
