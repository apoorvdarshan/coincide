import AppKit
import CoincideKit
import Testing

@testable import Coincide

/// The app hosting these tests stays out of the user's way and away from their data.
struct AppHostTests {
    @Test func theHostAppKnowsItRunsTests() {
        #expect(AppDelegate.isHostingTests)
    }

    @Test func theHostAppNeverComesForwardOrShowsAWindow() {
        #expect(NSApp.activationPolicy() == .prohibited)
        #expect(!NSApp.isActive)
        #expect(NSWorkspace.shared.frontmostApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier)
        #expect(NSRunningApplication.current.activationPolicy == .prohibited)
        #expect(NSApp.windows.filter(\.isVisible).isEmpty)
        // The launch guard returns before the main window and the menu bar are built.
        #expect(NSApp.mainMenu == nil)
    }

    @Test func theHostAppKeepsDockReopenFromShowingAWindow() throws {
        let delegate = try #require(NSApp.delegate as? AppDelegate)
        #expect(!delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false))
        #expect(delegate.applicationShouldTerminate(NSApp) == .terminateNow)
        #expect(NSApp.windows.filter(\.isVisible).isEmpty)
    }

    @Test func sharedStoresUseAScratchFolder() throws {
        // The folder the test environment chose, or the one the run was started with.
        let chosen = try #require(ProcessInfo.processInfo.environment["COINCIDE_DATA_DIR"])
        let store = AppStore.shared.directory.resolvingSymlinksInPath().path
        #expect(store == URL(fileURLWithPath: chosen).resolvingSymlinksInPath().path)
        let support = try #require(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
        #expect(!store.hasPrefix(support.resolvingSymlinksInPath().path))
    }
}
