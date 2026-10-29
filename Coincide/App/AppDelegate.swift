import AppKit
import CoincideKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var mainWindow: MainWindowController?
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
        // Keep window state across quits even with "Close windows when quitting an app" on, so the window reopens on
        // the desktop it was on (a restart for an update included).
        UserDefaults.standard.set(true, forKey: "NSQuitAlwaysKeepsWindows")
        // Before any window reads a transcript: threads whose agents kept running in the host are picked up again.
        AgentHostController.shared.startAtLaunch()
        let controller = MainWindowController()
        mainWindow = controller
        let menu = MainMenu(windowController: controller)
        mainMenu = menu
        NSApp.mainMenu = menu.build(appDelegate: self)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !Self.isHostingTests else { return }
        ThemeController.shared.start()
        AppearanceController.shared.start()
        SettingsWindowController.shared.startHandlingRequests()
        UsageStatusItem.shared.start()
        ThreadActivity.shared.start()
        AgentTurns.shared.start()
        NotificationController.shared.start()
        ProjectScripts.shared.start()
        ThreadSnooze.shared.start()
        PreviewSessions.shared.connectToApp { [weak self] in self?.mainWindow }
        PreviewSessions.shared.start()
        // Settings › Usage may read sites the user turned on with their sign-in in the shared browser profile.
        BrowserUsageBridge.connect()
        AppUpdates.shared.start()
        // ⌘W deletes the open thread in the main window; elsewhere it still closes the window.
        CloseShortcut.start { [weak self] in self?.mainWindow?.window }
        // Hold ⌘Q to quit (Settings › General). Quitting any other way is never held up.
        QuitShortcut.shared.start { [weak self] in self?.mainWindow?.window }
        // Off unless the user turned on Settings › General › Remote.
        RemoteServer.shared.startIfEnabled()
        // Chats are always listed, so the first one can be started from the sidebar.
        AppStore.shared.ensureChatsProject()
        mainWindow?.showWindow(nil)
        Task {
            await ProviderRegistry.shared.refresh()
            // Once, on the default agent or the first one set up, now that the registry knows which are.
            BotActions.addStartersIfNeeded()
            ScheduledTasks.shared.start()
        }
        #if DEBUG
        DebugAutomation.startIfRequested()
        #endif
    }

    /// Asks first while agents work or terminal commands run, as Terminal does for running processes.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !Self.isHostingTests else { return .terminateNow }
        // Agents in the background agent host keep working after Coincide quits.
        let agents = ThreadRunner.shared.runningInAppThreadIDs.count
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
        let alert = ThemedAlert()
        alert.messageText = String(localized: "Quit Coincide?")
        alert.informativeText = reasons.joined(separator: " ")
        alert.addButton(withTitle: String(localized: "Quit"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard !Self.isHostingTests else { return }
        ScheduledTasks.shared.stop()
        RemoteServer.shared.stop()
        PreviewSessions.shared.stop()
        ThreadRunner.shared.shutdownAll()
        AgentHostController.shared.prepareToQuit()
        AppStore.shared.flush()
        ThreadRunner.shared.usageHistory.flush()
        if mainWindow?.window?.isVisible == true { mainWindow?.saveLayout() }
        UIState.shared.flush()
        AppUpdates.shared.authorizeCleanQuit()
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

    @objc func checkForUpdates(_ sender: Any?) {
        AppEvents.showSettings(section: .about)
        AppUpdates.shared.check()
    }

    @objc func showSettings(_ sender: Any?) {
        SettingsWindowController.shared.show()
    }
}
