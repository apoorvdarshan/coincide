import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Coincide
@testable import CoincideCore

private func modelControlsClaudeRow() -> ProviderModel {
    .init(id: "native-alias", name: "Native Claude Model", reasoningEfforts: [.init(id: "high", description: "Native advertised effort"), .init(id: "max", description: "Native advertised maximum")],
        defaultReasoningEffort: "high", claudeCapabilities: .init(resolvedModel: "canonical-native-model", supportsFastMode: true,
            supportsThinking: true, contextWindows: ["200k", "1m"]))
}
private func modelControlsCodexRow() -> ProviderModel {
    .init(id: "native-codex", name: "Native Codex Model", codexServiceTiers: [
        .init(id: "priority", name: "Priority", description: "Native advertised tier"),
        .init(id: "ultrafast", name: "Ultrafast", description: "Native advertised tier")])
}

@Test @MainActor func nativeProviderModelControlsHonorActualRowsResolvedAliasesAndOwnedConnectionAvailability() throws {
    let row = modelControlsClaudeRow(), project = WorkspaceProject(path: "/private/offline-menu")
    var claude = CodingThread(project: project, model: "canonical-native-model"); claude.provider = .claude
    let available = ProviderModelControlsPresentation(thread: claude, models: [row])
    #expect(available.model?.id == "native-alias" && available.supportsClaudeFastMode && available.supportsClaudeThinking)
    #expect(available.claudeContextWindows == ["200k", "1m"])
    let missing = ProviderModelControlsPresentation(thread: claude, models: [])
    #expect(!missing.supportsClaudeFastMode && !missing.supportsClaudeThinking && missing.claudeContextWindows.isEmpty)
    var legacy = row; legacy.claudeCapabilities = nil; legacy.id = claude.model
    let noCapabilities = ProviderModelControlsPresentation(thread: claude, models: [legacy])
    #expect(!noCapabilities.supportsClaudeFastMode && !noCapabilities.supportsClaudeThinking && noCapabilities.claudeContextWindows.isEmpty)
    #expect(claude.model == "canonical-native-model")
    var codex = CodingThread(project: project, model: "native-codex")
    codex.agentConfiguration = try CodexServiceTier.setting("priority", in: nil)
    let regular = ProviderModelControlsPresentation(thread: codex, models: [modelControlsCodexRow()])
    #expect(regular.codexTiers.map(\.id) == ["priority", "ultrafast"] && !regular.codexNeedsReset)
    codex.codexRuntimeConfiguration = .init(homeDirectory: "/private/owned-home", authenticationMode: .ownedChatGPT)
    let owned = ProviderModelControlsPresentation(thread: codex, models: [modelControlsCodexRow()])
    #expect(owned.codexTiers.isEmpty && owned.codexNeedsReset)
    codex.codexRuntimeConfiguration = nil
    #expect(ProviderModelControlsPresentation(thread: codex, models: []).codexNeedsReset)
}

@Test @MainActor func nativeProviderModelControlsSeparateRequestedFastFromReportedCooldownAndOfferTruthfulReset() throws {
    let row = modelControlsClaudeRow()
    var thread = CodingThread(project: .init(path: "/private/offline-menu"), model: row.id); thread.provider = .claude
    thread.agentConfiguration = try ClaudeModelControl.setting(.init(effort: "max", fastMode: true, thinking: false, contextWindow: "1m"), in: nil)
    thread.providerMetadata = .object(["claudeModelControl": .object(["fastModeState": .string("cooldown"), "fastModeDisabledReason": .string("network_error")])])
    let controls = ProviderModelControlsPresentation(thread: thread, models: [row])
    #expect(controls.summaryComponents.contains("Fast requested: On"))
    #expect(controls.summaryComponents.contains("Fast effective: Cooldown (Network error)"))
    #expect(controls.summaryComponents.contains("Effort requested: Maximum"))
    #expect(controls.summaryComponents.contains("Context requested: 1M"))
    #expect(controls.claudeWarning == nil)
    thread.providerMetadata = nil
    #expect(ProviderModelControlsPresentation(thread: thread, models: [row]).claudeEffectiveFastSummary == nil)
    thread.agentConfiguration = [ClaudeModelControl.configurationKey: .object(["untrusted": .string("not-a-control")])]
    let invalid = ProviderModelControlsPresentation(thread: thread, models: [row])
    #expect(invalid.claudeOptions == nil && invalid.claudeWarning != nil)
    var codex = CodingThread(project: .init(path: "/private/offline-menu"), model: "native-codex")
    codex.agentConfiguration = try CodexServiceTier.setting("default", in: nil)
    #expect(ProviderModelControlsPresentation(thread: codex, models: [modelControlsCodexRow()]).summaryComponents == ["Service tier requested: Standard"])
    codex.agentConfiguration = try CodexServiceTier.setting("removed-native-tier", in: nil)
    #expect(ProviderModelControlsPresentation(thread: codex, models: [modelControlsCodexRow()]).codexNeedsReset)
}

@Test(.timeLimit(.minutes(1))) @MainActor func nativeProviderModelControlsMenuFitsOffscreenLightDarkHeadersAndDoesNotMutateCapturedTurns() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-model-controls-ui-" + UUID().uuidString)
    let store = WorkspaceStore(databaseURL: root.appendingPathComponent("workspace.sqlite"))
    defer { try? FileManager.default.removeItem(at: root) }
    let project = WorkspaceProject(path: root.path)
    do {
        for provider in [ProviderKind.claude, .codex] {
            let row = provider == .claude ? modelControlsClaudeRow() : modelControlsCodexRow()
            var thread = CodingThread(project: project, model: row.id); thread.provider = provider
            thread.draft = "Preserve current literal draft e\u{301}\n "; thread.messages = [.init(role: .user, text: "Already started")]
            if provider == .claude {
                thread.agentConfiguration = try ClaudeModelControl.setting(.init(effort: "max", fastMode: true), in: nil)
                thread.providerMetadata = .object(["claudeModelControl": .object(["fastModeState": .string("off"), "fastModeDisabledReason": .string("preference")])])
                store.providerModels[.claude] = [row]
            } else {
                thread.agentConfiguration = try CodexServiceTier.setting("ultrafast", in: nil)
                store.codexModels[thread.id] = [row]
            }
            var running = ProviderConfiguration(thread: thread); running.model = "different-captured-active-model"
            thread.activeRun = .init(id: UUID(), configuration: running, startedAt: .now)
            store.snapshot.projects = [project]; store.snapshot.threads = [thread]
            let before = thread
            for scheme in [ColorScheme.light, .dark] {
                for width in [CGFloat(160), 480] {
                    let controller = NSHostingController(rootView: ProviderMenu(store: store, thread: thread).environment(\.colorScheme, scheme))
                    let size = controller.sizeThatFits(in: .init(width: width, height: 100))
                    #expect(size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0 && size.width <= width + 1 && size.height <= 100)
                    controller.view.frame = .init(origin: .zero, size: size); controller.view.layoutSubtreeIfNeeded()
                    #expect(controller.view.window == nil)
                }
            }
            #expect(store.snapshot.threads.first == before)
            #expect(store.snapshot.threads.first?.activeRun?.configuration.model == "different-captured-active-model")
            #expect(store.snapshot.threads.first?.draft.utf8.elementsEqual("Preserve current literal draft e\u{301}\n ".utf8) == true)
        }
        await store.shutdown()
    } catch { await store.shutdown(); throw error }
}
