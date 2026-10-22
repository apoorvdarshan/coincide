import AppKit
import SwiftUI
import Testing
@testable import Coincide
@testable import CoincideCore

@MainActor private func providerMenuButtons(in view: NSView) -> [NSButton] {
    (view as? NSButton).map { [$0] } ?? view.subviews.flatMap { providerMenuButtons(in: $0) }
}

@MainActor private func providerMenuEventually(_ predicate: @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !predicate() {
        guard ContinuousClock.now < deadline else { throw CoincideError("The native provider menu title did not update.") }
        try await Task.sleep(for: .milliseconds(10))
    }
}

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
    let original = "Codex · Offline Future · Reasoning: deep"
    let updated = "Codex · Offline Future Refreshed · Reasoning: deep"
    let hosting = NSHostingView(rootView: ProviderMenu(store: store, thread: thread))
    let window = NSWindow(contentRect: .init(x: -10_000, y: -10_000, width: 480, height: 100),
        styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = hosting
    defer { window.close() }
    do {
        hosting.layoutSubtreeIfNeeded()
        try await providerMenuEventually {
            hosting.layoutSubtreeIfNeeded()
            return providerMenuButtons(in: hosting).contains { $0.title == original }
        }
        let button = try #require(providerMenuButtons(in: hosting).first { $0.title == original },
            "The native menu title must show the future model and effort while a different captured configuration is running.")
        #expect(button.frame.width <= 300 && button.frame.height > 0)
        // SwiftUI's semantic accessibility wrapper is verified by the hosted UI
        // test; the backing AppKit button does not expose those overrides here.

        var refreshed = model; refreshed.name = "Offline Future Refreshed"
        store.providerModels[.codex] = [refreshed]
        try await providerMenuEventually {
            hosting.layoutSubtreeIfNeeded()
            return providerMenuButtons(in: hosting).contains { $0.title == updated }
        }
        let refreshedButton = try #require(providerMenuButtons(in: hosting).first { $0.title == updated })
        #expect(refreshedButton.frame.width <= 300 && refreshedButton.frame.height > 0)
        let unchanged = try #require(store.snapshot.threads.first { $0.id == thread.id })
        #expect(ProviderConfiguration(thread: unchanged) == capturedFuture,
            "Refreshing display metadata must not rewrite future execution settings.")
        #expect(unchanged.activeRun == capturedRun,
            "The active run must retain its separately captured model and effort.")
        await store.shutdown()
    } catch { await store.shutdown(); throw error }
}
