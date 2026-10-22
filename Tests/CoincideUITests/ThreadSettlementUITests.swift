import AppKit
import CoincideCore
import Foundation
import SwiftUI
import Testing
@testable import Coincide

@MainActor @Test(.timeLimit(.minutes(1)))
func nativeSettlementOwnsBackgroundJobsAndNewMessagesResumeOnlyAfterDrainWithCapturedFIFO() async throws {
    let command = #"""
    /bin/sh -c 'trap "" HUP TERM; while :; do printf running > settle-alive.txt; /bin/sleep 0.05; done' &
    while [ ! -f settle-alive.txt ]; do /bin/sleep 0.01; done
    printf '%s\n' "$PWD" "$T3CODE_PROJECT_ROOT" "$T3CODE_WORKTREE_PATH" > settle-context.txt
    printf once >> settle-executions
    printf 'SETTLE_NATIVE_OK😀\n'
    exit 0
    """#
    let fixture = try await NativeSetupFixture.make(command: "printf forbidden > setup-must-not-run", settleCommand: command)
    let store = fixture.store, id = fixture.thread.id
    var firstReader: Task<Void, Never>?, secondReader: Task<Void, Never>?
    do {
        await store.prepareWorktree(for: id, selection: .createBranch(name: "native-settlement", baseRef: "HEAD"))
        try await waitNativeSetup { store.thread(id)?.workspacePreparation?.isReady == true }
        let checkout = URL(fileURLWithPath: try #require(store.thread(id)).workspacePath)
        let alive = checkout.appendingPathComponent("settle-alive.txt")
        try await store.settleThread(id)
        try await waitNativeSetup { store.thread(id)?.settlement?.script?.canApprove == true }
        let generation = try #require(store.thread(id)?.settlement)
        let run = try #require(generation.script), plan = try #require(run.plan)
        #expect(plan.scriptIndex == 3 && plan.script.command == command)
        #expect(!store.snapshot.providerReady(for: try #require(store.thread(id))))
        #expect(store.workspaceReady(for: try #require(store.thread(id))))
        #expect(store.thread(id)?.draft == "Keep the unsent setup discussion")
        #expect(!FileManager.default.fileExists(atPath: alive.path))
        try await store.settleThread(id)
        #expect(store.thread(id)?.settlement?.id == generation.id)
        let firstOutput = NativeSetupOutput(), secondOutput = NativeSetupOutput()
        let streamA = try await store.projectScriptOutput(threadID: id, runID: run.id)
        let streamB = try await store.projectScriptOutput(threadID: id, runID: run.id)
        firstReader = Task { for await value in streamA { await firstOutput.receive(value) } }
        secondReader = Task { for await value in streamB { await secondOutput.receive(value) } }
        try await store.approveProjectScript(threadID: id, runID: run.id, expectedPlan: plan)
        try await waitNativeSetup { store.thread(id)?.settlement?.script?.commandExit == .exited(0) }
        #expect(store.thread(id)?.settlement?.phase == .settled)
        #expect(!store.snapshot.providerReady(for: try #require(store.thread(id))))
        #expect(await fixture.provider.calls.isEmpty)
        try await waitNativeSetup {
            let a = await firstOutput.latest, b = await secondOutput.latest
            return a?.text.contains("SETTLE_NATIVE_OK😀") == true && b?.text.contains("SETTLE_NATIVE_OK😀") == true
        }
        firstReader?.cancel(); _ = await firstReader?.value
        try FileManager.default.removeItem(at: alive)
        try await waitNativeSetup { FileManager.default.fileExists(atPath: alive.path) }
        #expect(await secondOutput.latest?.isClosed == false)
        #expect(try String(contentsOf: checkout.appendingPathComponent("settle-context.txt"), encoding: .utf8) ==
                [checkout.path, fixture.source.path, checkout.path].joined(separator: "\n") + "\n")
        #expect(!FileManager.default.fileExists(atPath: checkout.appendingPathComponent("setup-must-not-run").path))
        #expect(!FileManager.default.fileExists(atPath: checkout.appendingPathComponent("later-settle-must-not-run").path))
        #expect(await store.submit("Resume with first prompt", threadID: id).value)
        #expect(await fixture.provider.calls.isEmpty, "Accepted input must wait for the TERM-ignoring settle job to drain.")
        store.setModel("second-resume-model", id: id); store.setPermission(.fullAccess, id: id)
        #expect(await store.submit("Second resumed prompt", threadID: id).value)
        store.setDraft("Unsent after automatic resume", id: id)
        try await waitNativeSetup { await fixture.provider.calls.count == 1 }
        try await waitNativeSetup { await secondOutput.latest?.isClosed == true }
        #expect(store.thread(id)?.settlement == nil)
        try? FileManager.default.removeItem(at: alive)
        try await Task.sleep(for: .milliseconds(250))
        #expect(!FileManager.default.fileExists(atPath: alive.path))
        #expect(await fixture.provider.calls.first == .init(prompt: "Resume with first prompt", path: checkout.path, model: "first-model", permission: .supervised))
        await fixture.provider.finish()
        try await waitNativeSetup { await fixture.provider.calls.count == 2 }
        #expect(await fixture.provider.calls.last == .init(prompt: "Second resumed prompt", path: checkout.path, model: "second-resume-model", permission: .fullAccess))
        await fixture.provider.finish()
        try await waitNativeSetup { store.thread(id)?.isBusy == false }
        #expect(store.thread(id)?.settlement == nil, "Provider idle must not settle a conversation.")
        #expect(store.thread(id)?.draft == "Unsent after automatic resume")
        try await store.settleThread(id)
        try await waitNativeSetup { store.thread(id)?.settlement?.script?.canApprove == true }
        let fresh = try #require(store.thread(id)?.settlement)
        #expect(fresh.id != generation.id && fresh.script?.id != run.id)
        try await store.resumeThread(id, generationID: fresh.id)
        try await waitNativeSetup { store.thread(id)?.settlement == nil }
        #expect(try String(contentsOf: checkout.appendingPathComponent("settle-executions"), encoding: .utf8) == "once")
        try fixture.checkSource()
    } catch {
        firstReader?.cancel(); secondReader?.cancel(); await fixture.cleanup()
        _ = await firstReader?.value; _ = await secondReader?.value; throw error
    }
    firstReader?.cancel(); secondReader?.cancel(); await fixture.cleanup()
    _ = await firstReader?.value; _ = await secondReader?.value
}

@MainActor @Test(.timeLimit(.minutes(1)))
func nativeSettlementChangedCommandNeedsFreshReviewAndRestartDoesNotExecuteIt() async throws {
    let fixture = try await NativeSetupFixture.make(command: "exit 0", settleCommand: "printf forbidden > settle-must-not-run")
    let store = fixture.store, id = fixture.thread.id
    do {
        await store.prepareWorktree(for: id, selection: .createBranch(name: "settle-review-change", baseRef: "HEAD"))
        try await waitNativeSetup { store.thread(id)?.workspacePreparation?.isReady == true }
        try await store.settleThread(id)
        try await waitNativeSetup { store.thread(id)?.settlement?.script?.canApprove == true }
        let generation = try #require(store.thread(id)?.settlement), original = try #require(generation.script)
        let plan = try #require(original.plan), checkout = URL(fileURLWithPath: try #require(store.thread(id)).workspacePath)
        let revised = try ProjectConfiguration(scripts: [.init(name: "Revised settle", command: "printf revised > settle-must-not-run", runOnSettle: true)])
        try JSONEncoder().encode(revised).write(to: checkout.appendingPathComponent("t3.json"), options: .atomic)
        try await store.approveProjectScript(threadID: id, runID: original.id, expectedPlan: plan)
        try await waitNativeSetup { store.thread(id)?.settlement?.script?.phase == .failed }
        #expect(!FileManager.default.fileExists(atPath: checkout.appendingPathComponent("settle-must-not-run").path))
        try await store.retryProjectScript(threadID: id, runID: original.id)
        try await waitNativeSetup { store.thread(id)?.settlement?.script?.canApprove == true }
        let fresh = try #require(store.thread(id)?.settlement?.script)
        #expect(fresh.id != original.id && fresh.plan?.script.name == "Revised settle")
        await #expect(throws: CancellationError.self) { try await store.approveProjectScript(threadID: id, runID: original.id, expectedPlan: plan) }
        await store.shutdown()
        let provider = NativeSetupProvider()
        let engine = try NativeSetupFixture.makeEngine(database: fixture.database, helper: fixture.helper, home: fixture.root, provider: provider)
        let reopened = WorkspaceStore(engine: engine); await reopened.load()
        do {
            #expect(reopened.thread(id)?.settlement?.id == generation.id)
            #expect(reopened.thread(id)?.settlement?.script?.id == fresh.id)
            #expect(reopened.thread(id)?.settlement?.script?.canApprove == true)
            #expect(reopened.thread(id)?.draft == "Keep the unsent setup discussion")
            #expect(await provider.calls.isEmpty)
            try await reopened.resumeThread(id, generationID: generation.id)
            try await waitNativeSetup { reopened.thread(id)?.settlement == nil }
            #expect(!FileManager.default.fileExists(atPath: checkout.appendingPathComponent("settle-must-not-run").path))
            try fixture.checkSource()
        } catch { await reopened.shutdown(); throw error }
        await reopened.shutdown()
    } catch { await fixture.cleanup(); throw error }
    await fixture.cleanup()
}

@MainActor @Test(.timeLimit(.minutes(1)))
func nativeSettlementOnMainCheckoutSkipsScriptAndExplicitResumePreservesDraft() async throws {
    let fixture = try await NativeSetupFixture.make(command: "exit 0", settleCommand: "printf forbidden > main-must-not-run")
    let store = fixture.store, id = fixture.thread.id
    do {
        #expect(store.canSettle(try #require(store.thread(id))))
        try await store.settleThread(id)
        try await waitNativeSetup {
            guard let settled = store.thread(id)?.settlement else { return false }
            return settled.script == nil || settled.script?.phase == .skipped
        }
        let generation = try #require(store.thread(id)?.settlement)
        #expect(!store.snapshot.providerReady(for: try #require(store.thread(id))))
        #expect(!FileManager.default.fileExists(atPath: fixture.source.appendingPathComponent("main-must-not-run").path))
        try await store.resumeThread(id, generationID: generation.id)
        try await waitNativeSetup { store.thread(id)?.settlement == nil }
        #expect(store.thread(id)?.draft == "Keep the unsent setup discussion")
        #expect(await fixture.provider.calls.isEmpty)
        await #expect(throws: CancellationError.self) { try await store.resumeThread(id, generationID: generation.id) }
        try fixture.checkSource()
    } catch { await fixture.cleanup(); throw error }
    await fixture.cleanup()
}

@MainActor @Test(.timeLimit(.minutes(1)))
func nativeSettlementConfirmationReviewAndBannerFitSmallDisplaysInBothAppearances() async throws {
    let fixture = try await NativeSetupFixture.make(command: "exit 0", settleCommand: "printf 'Reviewed settle command 😀\\n'; exit 7")
    do {
        await fixture.store.prepareWorktree(for: fixture.thread.id, selection: .createBranch(name: "settle-layout", baseRef: "HEAD"))
        try await waitNativeSetup { fixture.store.thread(fixture.thread.id)?.workspacePreparation?.isReady == true }
        _ = NSApplication.shared
        let confirmation = AnyView(SettleConversationSheet(store: fixture.store, threadID: fixture.thread.id, close: { }))
        for scheme in [ColorScheme.light, .dark] {
            let view = confirmation.environment(\.colorScheme, scheme)
            let size = NSHostingController(rootView: view).sizeThatFits(in: CGSize(width: 480, height: 620))
            #expect(size.width <= 480 && size.height <= 620 && size.height > 200)
            try await captureNativeScriptPreview(view, name: "settlement-confirmation", width: 480, height: size.height, scheme: scheme)
        }
        try await fixture.store.settleThread(fixture.thread.id)
        try await waitNativeSetup { fixture.store.thread(fixture.thread.id)?.settlement?.script?.canApprove == true }
        let settlement = try #require(fixture.store.thread(fixture.thread.id)?.settlement), plan = try #require(settlement.script?.plan)
        for scheme in [ColorScheme.light, .dark] {
            let view = AnyView(WorkspaceSetupReviewSheet(store: fixture.store, threadID: fixture.thread.id, plan: plan, close: { }, role: .settle))
                .environment(\.colorScheme, scheme)
            let size = NSHostingController(rootView: view).sizeThatFits(in: CGSize(width: 500, height: 620))
            #expect(size.width <= 500 && size.height <= 620 && size.height > 200)
            try await captureNativeScriptPreview(view, name: "settlement-review", width: 500, height: size.height, scheme: scheme)
            let banner = NSHostingController(rootView: ThreadSettlementBanner(store: fixture.store, threadID: fixture.thread.id, settlement: settlement).environment(\.colorScheme, scheme))
            #expect(banner.sizeThatFits(in: CGSize(width: 320, height: 600)).width <= 320)
        }
        #expect(await fixture.provider.calls.isEmpty)
    } catch { await fixture.cleanup(); throw error }
    await fixture.cleanup()
}
