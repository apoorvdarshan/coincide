import AppKit
import SwiftUI
import Testing
@testable import Coincide
@testable import CoincideCore

@MainActor @Test(.timeLimit(.minutes(1)))
func nativeProviderMenuRetainsSelectedModelAndEffortInItsActualButtonAndRefreshesTheCatalogName() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-provider-native-" + UUID().uuidString)
    let store = WorkspaceStore(databaseURL: root.appendingPathComponent("workspace.sqlite"))
    defer { try? FileManager.default.removeItem(at: root) }
    let model = ProviderModel(id: "future-native-model", name: "Offline Future", reasoningEfforts: [
        .init(id: "deep", description: "Offline reasoning")], defaultReasoningEffort: "deep")
    store.providerModels[.codex] = [model]
    let project = WorkspaceProject(path: root.path)
    var thread = CodingThread(project: project, model: model.id)
    thread.reasoningEffort = "deep"
    var runningConfiguration = ProviderConfiguration(thread: thread)
    runningConfiguration.model = "original-running-model"; runningConfiguration.reasoningEffort = "high"
    thread.activeRun = .init(id: UUID(), configuration: runningConfiguration, startedAt: .now)
    store.snapshot.projects = [project]; store.snapshot.threads = [thread]
    let capturedFuture = ProviderConfiguration(thread: thread), capturedRun = thread.activeRun
    let original = "Offline Future deep"
    let updated = "Offline Future Refreshed deep"
    let menu = ProviderMenu(store: store, thread: thread)
    let hosting = NSHostingView(rootView: menu)
    let window = NSWindow(contentRect: .init(x: -10_000, y: -10_000, width: 480, height: 100),
        styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = hosting
    defer { window.close() }
    do {
        // Offscreen hosting does not publish SwiftUI's accessibility tree, so
        // check the label text that feeds it and the fitted hit target.
        #expect(menu.summary == original,
            "The model button must show the future model and effort while a different captured configuration is running.")
        hosting.layoutSubtreeIfNeeded()
        #expect(hosting.fittingSize.width > 0 && hosting.fittingSize.width <= 282 && hosting.fittingSize.height <= 100)

        var refreshed = model; refreshed.name = "Offline Future Refreshed"
        store.providerModels[.codex] = [refreshed]
        #expect(ProviderMenu(store: store, thread: thread).summary == updated)
        hosting.layoutSubtreeIfNeeded()
        #expect(hosting.fittingSize.width > 0 && hosting.fittingSize.width <= 282 && hosting.fittingSize.height <= 100)
        let unchanged = try #require(store.snapshot.threads.first { $0.id == thread.id })
        #expect(ProviderConfiguration(thread: unchanged) == capturedFuture,
            "Refreshing display metadata must not rewrite future execution settings.")
        #expect(unchanged.activeRun == capturedRun,
            "The active run must retain its separately captured model and effort.")
        await store.shutdown()
    } catch { await store.shutdown(); throw error }
}
