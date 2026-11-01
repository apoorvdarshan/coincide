import AppKit
@testable import CoincideKit
import Testing
@testable import Coincide

@MainActor
struct AppUpdatesTests {
    @Test func dailyChecksAreOnByDefaultCanBeTurnedOffAndMissingReleaseDoesNotClaimCurrentVersion() async throws {
        let folder = TemporaryDirectory("app-updates-state")
        let store = AppStore(directory: folder.url)
        let root = folder.url
        let updates = AppUpdates(store: store, bundleURL: root, root: folder.url.appendingPathComponent("updates")) { _, _ in
            let file = root.appendingPathComponent(UUID().uuidString)
            try Data("{}".utf8).write(to: file)
            return (file, 404)
        }
        #expect(store.settings.checksForAppUpdates)
        store.updateSettings { $0.checksForAppUpdates = false }
        updates.automaticCheck()
        #expect(updates.state == .idle && store.settings.lastAppUpdateCheck == nil)
        store.updateSettings { $0.checksForAppUpdates = true }
        updates.automaticCheck()
        for _ in 0..<200 where updates.busy { try await Task.sleep(for: .milliseconds(5)) }
        #expect(updates.state == .unpublished)
        #expect(!updates.canInstall)
        #expect(store.settings.lastAppUpdateCheck != nil)
        let checked = store.settings.lastAppUpdateCheck
        updates.automaticCheck()
        #expect(store.settings.lastAppUpdateCheck == checked)
        updates.installOnQuit()
        updates.authorizeCleanQuit()
        #expect(!FileManager.default.fileExists(atPath: folder.url.appendingPathComponent("updates").path))
    }

    @Test func failedCheckDoesNotPretendTheAppIsCurrent() async throws {
        let folder = TemporaryDirectory("app-updates-failed")
        let root = folder.url
        let updates = AppUpdates(store: AppStore(directory: folder.url), bundleURL: root, root: folder.url.appendingPathComponent("updates")) { _, _ in
            let file = root.appendingPathComponent(UUID().uuidString)
            try Data("{}".utf8).write(to: file)
            return (file, 429)
        }
        updates.check()
        for _ in 0..<200 where updates.busy { try await Task.sleep(for: .milliseconds(5)) }
        guard case .failed = updates.state else { Issue.record("An HTTP error must stay an error"); return }
        #expect(updates.release == nil)
    }

    @Test func delayedTerminationOfCancelledHelperCannotClearTheSuccessor() {
        let folder = TemporaryDirectory("app-updates-helper-lifetime")
        let updates = AppUpdates(store: AppStore(directory: folder.url), bundleURL: folder.url)
        let release = AppUpdateRelease(version: "0.2.0", url: AppUpdateRelease.feed, sha256: String(repeating: "a", count: 64), size: 1)
        let old = Process(), successor = Process()
        updates.armHelper(old, plan: AppUpdatePlan(release: release, target: folder.url, processID: 123))
        updates.cancelInstallation()
        #expect(old.terminationHandler == nil)
        #expect(updates.state == .ready)
        updates.armHelper(successor, plan: AppUpdatePlan(release: release, target: folder.url, processID: 123))
        // Model a main-actor callback already queued before cancellation detached the old handler.
        updates.helperTerminated(old)
        #expect(updates.state == .armed)
        updates.helperTerminated(successor)
        guard case .failed = updates.state else { Issue.record("The current helper's exit must be reported"); return }
    }
}
