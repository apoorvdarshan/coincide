import AppKit
import CoincideKit

// STUB: replaced by the real app delegate (menus, windows, notifications, lifecycle).
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindow: MainWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppearanceController.shared.start()
        let controller = MainWindowController()
        mainWindow = controller
        controller.showWindow(nil)
        controller.window?.center()
        Task { await ProviderRegistry.shared.refresh() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        ThreadRunner.shared.shutdownAll()
        AppStore.shared.flush()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
