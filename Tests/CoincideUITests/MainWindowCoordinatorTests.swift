import AppKit
import CoincideCore
import Foundation
import Testing
@testable import Coincide

@MainActor @Test func mainWindowPresentationSurvivesMissingViewsAndDeferredCommandsRegistrationWithoutDuplicateRequests() async {
    let probe = MainWindowPresentationProbe()
    let coordinator = MainWindowCoordinator(restoreExisting: { probe.restorations += 1; return probe.existing })
    coordinator.presentIfNeeded(); coordinator.presentIfNeeded()
    #expect(probe.presentations == 0)
    let first = coordinator.installOpenAction { probe.presentations += 1 }
    let second = coordinator.installOpenAction { probe.presentations += 1 }
    await first?.value; await second?.value
    #expect(probe.presentations == 1)
    coordinator.presentIfNeeded(); coordinator.presentIfNeeded()
    #expect(probe.presentations == 1)
    probe.existing = true
    coordinator.presentIfNeeded()
    #expect(probe.presentations == 1 && probe.restorations >= 3)
    // A later explicit reopen after the last window closed is a new intent.
    probe.existing = false
    coordinator.presentIfNeeded()
    #expect(probe.presentations == 2)
    probe.existing = true
    coordinator.newWindow()
    #expect(probe.presentations == 3)
}

@MainActor @Test func mainWindowCommandsReplaceTheirRelayWithoutRetainingAnObsoleteAction() async {
    let probe = MainWindowPresentationProbe()
    let coordinator = MainWindowCoordinator(restoreExisting: { false })
    await coordinator.installOpenAction { probe.first += 1 }?.value
    await coordinator.installOpenAction { probe.latest += 1 }?.value
    coordinator.newWindow()
    #expect(probe.first == 0 && probe.latest == 1)
}

@MainActor @Test func mainWindowDelegateLoadsAndQueuesEveryOpenedProjectBeforeAnyContentViewExists() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-main-window-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: root) }
    let calls = MainWindowProviderCounter()
    let engine = try WorkspaceEngine(url: root.appendingPathComponent("workspace.sqlite"), providerFactory: { _ in
        calls.increment(); throw CoincideError("The window lifecycle must not create a provider.")
    }, identityResolver: { _ in nil })
    let store = WorkspaceStore(engine: engine)
    let coordinator = MainWindowCoordinator(restoreExisting: { false }), delegate = AppDelegate()
    let opened = [root.appendingPathComponent("One"), root.appendingPathComponent("Two")]
    for path in opened { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false) }
    delegate.application(NSApplication.shared, open: opened)
    delegate.attach(store, mainWindows: coordinator)
    await delegate.waitForStartup()
    let probe = MainWindowPresentationProbe()
    await coordinator.installOpenAction { probe.presentations += 1 }?.value
    do {
        let deadline = ContinuousClock.now + .seconds(3)
        while Set(store.snapshot.projects.map(\.path)) != Set(opened.map { $0.standardizedFileURL.path }) {
            guard ContinuousClock.now < deadline else { throw CoincideError("Window-independent launch did not preserve both explicit project requests.") }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!store.isLoading && store.errorMessage == nil && probe.presentations == 1 && calls.value == 0)
        #expect(store.snapshot.threads.isEmpty)
        let update = await engine.current()
        #expect(update.error == nil)
        await store.shutdown()
    } catch { await store.shutdown(); throw error }
}

@MainActor private final class MainWindowPresentationProbe {
    var existing = false
    var presentations = 0
    var restorations = 0
    var first = 0
    var latest = 0
}

private final class MainWindowProviderCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}
