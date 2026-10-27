import AppKit
import CoincideKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindow: MainWindowController?
    private var mainMenu: MainMenu?

    /// Whether the app hosts the unit tests (CoincideTests). It then stays in the background: no windows,
    /// no menu bar, no Dock icon, never active, and nothing started, so a test run never takes over the screen.
    static let isHostingTests =
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil || NSClassFromString("XCTestCase") != nil

    override init() {
        super.init()
        // As early as possible, before the app finishes launching and would be activated.
        if Self.isHostingTests { NSApplication.shared.setActivationPolicy(.prohibited) }
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        if Self.isHostingTests {
            // Again, in case launching restored the policy the app's Info.plist asks for.
            NSApp.setActivationPolicy(.prohibited)
            return
        }
        let controller = MainWindowController()
        mainWindow = controller
        let menu = MainMenu(windowController: controller)
        mainMenu = menu
        NSApp.mainMenu = menu.build(appDelegate: self)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !Self.isHostingTests else { return }
        AppearanceController.shared.start()
        SettingsWindowController.shared.startHandlingRequests()
        ThreadActivity.shared.start()
        AgentTurns.shared.start()
        NotificationController.shared.start()
        mainWindow?.showWindow(nil)
        Task { await ProviderRegistry.shared.refresh() }
        #if DEBUG
        DebugAutomation.startIfRequested()
        #endif
    }

    /// Asks first while agents work or terminal commands run, as Terminal does for running processes.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !Self.isHostingTests else { return .terminateNow }
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
        guard !Self.isHostingTests else { return }
        ThreadRunner.shared.shutdownAll()
        AppStore.shared.flush()
        if mainWindow?.window?.isVisible == true { mainWindow?.saveLayout() }
        UIState.shared.flush()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !Self.isHostingTests else { return false }
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
