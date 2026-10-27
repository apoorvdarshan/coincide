import AppKit
import CoincideKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindow: MainWindowController?
    private var mainMenu: MainMenu?

    func applicationWillFinishLaunching(_ notification: Notification) {
        let controller = MainWindowController()
        mainWindow = controller
        let menu = MainMenu(windowController: controller)
        mainMenu = menu
        NSApp.mainMenu = menu.build(appDelegate: self)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppearanceController.shared.start()
        SettingsWindowController.shared.startHandlingRequests()
        ThreadActivity.shared.start()
        NotificationController.shared.start()
        mainWindow?.showWindow(nil)
        Task { await ProviderRegistry.shared.refresh() }
        #if DEBUG
        DebugAutomation.startIfRequested()
        #endif
    }

    /// Asks first while agents work or terminal commands run, as Terminal does for running processes.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let agents = ThreadRunner.shared.runningThreadIDs.count
        let jobs = TerminalSessionManager.shared.busySessionCount
        guard agents > 0 || jobs > 0 else { return .terminateNow }
        var reasons: [String] = []
        if agents == 1 {
            reasons.append(String(localized: "An agent is still working."))
        } else if agents > 1 {
            reasons.append(String(localized: "\(agents) agents are still working."))
        }
        if jobs == 1 {
            reasons.append(String(localized: "A command is still running in a terminal."))
        } else if jobs > 1 {
            reasons.append(String(localized: "\(jobs) commands are still running in terminals."))
        }
        reasons.append(String(localized: "Quitting stops them."))
        let alert = NSAlert()
        alert.messageText = String(localized: "Quit Coincide?")
        alert.informativeText = reasons.joined(separator: " ")
        alert.addButton(withTitle: String(localized: "Quit"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        ThreadRunner.shared.shutdownAll()
        AppStore.shared.flush()
        if mainWindow?.window?.isVisible == true { mainWindow?.saveLayout() }
        UIState.shared.flush()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { mainWindow?.showWindow(nil) }
        return true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let newThread = NSMenuItem(
            title: String(localized: "New Thread"), action: #selector(MainWindowController.newThread(_:)), keyEquivalent: "")
        newThread.target = mainWindow
        menu.addItem(newThread)
        let recent = AppStore.shared.recentThreads.prefix(5)
        if !recent.isEmpty { menu.addItem(.separator()) }
        for thread in recent {
            let item = NSMenuItem(title: thread.title, action: #selector(openRecentThread(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = thread.id
            menu.addItem(item)
        }
        return menu
    }

    @objc private func openRecentThread(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        NSApp.activate()
        AppEvents.openThread(id)
    }

    @objc func showSettings(_ sender: Any?) {
        SettingsWindowController.shared.show()
    }
}
