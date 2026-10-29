import AppKit
import CoincideKit
import Testing

@testable import Coincide

/// The menu bar, which Keyboard settings reads its shortcut list from, built offscreen for a main window
/// controller that never gets a window.
@Suite(.serialized)
struct MainMenuTests {
    private let windowController: MainWindowController
    private let menu: NSMenu
    /// Kept alive for the menu's items.
    private let mainMenu: MainMenu
    private let appDelegate: AppDelegate

    init() {
        windowController = MainWindowController(window: nil)
        mainMenu = MainMenu(windowController: windowController)
        appDelegate = AppDelegate()
        menu = mainMenu.build(appDelegate: appDelegate)
    }

    /// Every item with its path of menu titles, top-level menus included.
    private func items(in menu: NSMenu, path: [String] = []) -> [(item: NSMenuItem, path: [String])] {
        menu.items.flatMap { item -> [(item: NSMenuItem, path: [String])] in
            let here = path + [item.title]
            guard let submenu = item.submenu else { return [(item, here)] }
            return items(in: submenu, path: here)
        }
    }

    /// A shortcut as the Keyboard settings pane and the palette show it: modifiers in Apple's order, then the key.
    private func shortcut(_ item: NSMenuItem) -> String {
        guard !item.keyEquivalent.isEmpty else { return "" }
        var modifiers = item.keyEquivalentModifierMask
        var key = item.keyEquivalent
        if key.count == 1, let first = key.first, first.isUppercase {
            modifiers.insert(.shift)
            key = key.lowercased()
        }
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + key.uppercased()
    }

    @Test func theMenuBarHasTheStandardMenusInOrder() {
        #expect(menu.items.map { $0.submenu?.title } == ["Coincide", "File", "Edit", "View", "Thread", "Window", "Help"])
    }

    @Test func noTwoCommandsShareAShortcut() {
        var seen: [String: String] = [:]
        for (item, path) in items(in: menu) where !item.keyEquivalent.isEmpty && !item.isAlternate {
            let key = shortcut(item)
            let title = path.joined(separator: " › ")
            if let other = seen[key] {
                Issue.record("\(key) is used by both \(other) and \(title)")
            }
            seen[key] = title
        }
        #expect(seen.count > 30)
    }

    @Test func coincideCommandsGoToTheWindowAndStandardOnesAlongTheResponderChain() {
        var commands = 0
        for (item, path) in items(in: menu) where item.action != nil {
            guard let action = item.action else { continue }
            if let target = item.target {
                let toWindow = target === windowController
                let toApp = target === appDelegate
                if toWindow {
                    commands += 1
                    let responds = windowController.responds(to: action)
                    #expect(responds, "\(path) → \(NSStringFromSelector(action))")
                } else {
                    let responds = appDelegate.responds(to: action)
                    #expect(toApp, "\(path)")
                    #expect(responds)
                }
            } else {
                // Standard commands are handled by whatever has focus, the app or the window.
                let handled = NSApplication.instancesRespond(to: action) || NSWindow.instancesRespond(to: action)
                    || NSTextView.instancesRespond(to: action) || NSResponder.instancesRespond(to: action)
                #expect(handled, "\(path) → \(NSStringFromSelector(action))")
            }
        }
        #expect(commands > 20)
    }

    @Test func threadNumbersAreHiddenShortcutsOneToNine() {
        let jumps = items(in: menu).map(\.item).filter { $0.action == #selector(MainWindowController.jumpToThread(_:)) }
        #expect(jumps.map(\.tag) == Array(1...9))
        #expect(jumps.map(\.keyEquivalent) == (1...9).map(String.init))
        #expect(jumps.allSatisfy { $0.isHidden && $0.allowsKeyEquivalentWhenHidden })
    }

    @Test func commandEqualsIncreasesTheFontSizeWithoutShift() throws {
        let increase = items(in: menu).map(\.item).filter { $0.action == #selector(MainWindowController.increaseFontSize(_:)) }
        #expect(increase.map(\.keyEquivalent) == ["+", "="])
        #expect(increase.map(\.isHidden) == [false, true])
        #expect(try #require(increase.last).allowsKeyEquivalentWhenHidden)
    }

    @Test func shortcutsTheMenusShow() {
        let byTitle = Dictionary(items(in: menu).filter { !$0.item.isHidden }.map { ($0.path.joined(separator: " › "), shortcut($0.item)) }) { first, _ in first }
        let expected = [
            "File › New Thread": "⌘N", "File › Add Project…": "⇧⌘O", "File › Open in Editor": "⌘O", "View › Show Terminal": "⌘J",
            "View › Show Diff": "⌘D", "View › Hide Sidebar": "⌘B", "View › Command Palette…": "⌘K", "Thread › Stop": "⌘.",
            "Thread › Pin Thread": "⇧⌘P", "Thread › Choose Agent and Model…": "⇧⌘M", "Thread › Reasoning Effort…": "⇧⌘E",
            "Thread › Access…": "⇧⌘A", "Thread › Previous Thread": "⇧⌘[", "Thread › Next Thread": "⇧⌘]",
            "Coincide › Settings…": "⌘,", "Edit › Find › Search Threads": "⌥⌘F", "Edit › Find › Find…": "⌘F",
            "Edit › Add Selection to Composer": "⌘L",
        ]
        for (title, keys) in expected {
            #expect(byTitle[title] == keys, "\(title)")
        }
        // Plan mode keeps Shift-Tab for the composer.
        #expect(byTitle["Thread › Plan Mode"] == "")
    }

    @Test func theCommandPaletteShowsTheSameShortcutsAsTheMenus() throws {
        // The palette's panel commands need the window's split view, loaded offscreen.
        _ = windowController.splitController.view
        let (core, more) = PaletteCatalog(windowController: windowController).actions()
        let menuShortcuts = Set(items(in: menu).filter { !$0.item.keyEquivalent.isEmpty }.map { shortcut($0.item) })
        let shown = (core + more).compactMap(\.trailing)
        #expect(shown.contains("⌘J") && shown.contains("⌘D") && shown.contains("⌘B"))
        for trailing in shown {
            #expect(menuShortcuts.contains(trailing), "The palette shows \(trailing), which no menu item has")
        }
        #expect(NSApp.windows.filter(\.isVisible).isEmpty)
    }
}

/// Interface state kept beside the store's data.
struct UIStateTests {
    @Test func aFreshStateHasDefaults() {
        let folder = TemporaryDirectory("ui")
        let state = UIState(directory: folder.url)
        #expect(state.values.sidebarThreadsPerProject == nil)
        #expect(state.values.projectSort == .manual && state.values.threadSort == .recentActivity)
        #expect(state.values.chatSort == .recentActivity && state.values.pinnedThreads.isEmpty)
        #expect(state.values.sidebarSections.isEmpty)
        #expect(!state.values.isTerminalOpen)
        #expect(state.values.unseen.isEmpty)
    }

    @Test func valuesSurviveAFlushAndReload() throws {
        let folder = TemporaryDirectory("ui")
        let state = UIState(directory: folder.url)
        let thread = UUID()
        state.update { values in
            values.isTerminalOpen = true
            values.preferredOpenTarget = "dev.zed.Zed"
            values.unseen[thread.uuidString] = .failed
            values.agentTurns[thread.uuidString] = ["a", "b"]
        }
        state.flush()
        let reloaded = UIState(directory: folder.url)
        #expect(reloaded.values.isTerminalOpen)
        #expect(reloaded.values.preferredOpenTarget == "dev.zed.Zed")
        #expect(reloaded.values.unseen[thread.uuidString] == .failed)
        #expect(reloaded.values.agentTurns[thread.uuidString] == ["a", "b"])
    }

    @Test func aFieldThisVersionCannotReadFallsBackAloneAndUnknownOnesAreIgnored() throws {
        let folder = TemporaryDirectory("ui")
        let json = """
            {"isTerminalOpen": "yes", "sidebarThreadLimit": 12, "isSidebarCollapsed": true,
             "unseen": {"a": "completed", "b": "hologram"}, "futureSetting": 3}
            """
        try Data(json.utf8).write(to: folder.url.appendingPathComponent("ui-state.json"))
        let state = UIState(directory: folder.url)
        #expect(!state.values.isTerminalOpen)
        #expect(state.values.sidebarThreadsPerProject == 12)
        #expect(state.values.isSidebarCollapsed)
        // One unreadable entry costs the whole map, not the file.
        #expect(state.values.unseen.isEmpty)
    }

    @Test func anUnreadableFileStartsFresh() throws {
        let folder = TemporaryDirectory("ui")
        try Data("{ not json".utf8).write(to: folder.url.appendingPathComponent("ui-state.json"))
        #expect(UIState(directory: folder.url).values.sidebarThreadsPerProject == nil)
    }

    /// The old fixed cut of six, which nearly everyone kept, gives way to fitting the sidebar; other choices stay.
    @Test func anEarlierThreadLimitCarriesOverUnlessItWasTheOldDefault() throws {
        for (stored, expected) in [(6, nil), (3, 3), (0, 0), (20, 20)] as [(Int, Int?)] {
            let folder = TemporaryDirectory("ui")
            try Data(#"{"sidebarThreadLimit": \#(stored)}"#.utf8).write(to: folder.url.appendingPathComponent("ui-state.json"))
            let state = UIState(directory: folder.url)
            #expect(state.values.sidebarThreadsPerProject == expected, "stored \(stored)")
            // Written back under the new key, a choice of six now stays six.
            state.update { $0.sidebarThreadsPerProject = 6 }
            state.flush()
            #expect(UIState(directory: folder.url).values.sidebarThreadsPerProject == 6)
        }
    }

    @Test func sortsSectionOrderAndThePinnedOrderSurviveAReload() {
        let folder = TemporaryDirectory("ui")
        let state = UIState(directory: folder.url)
        let pinned = [UUID().uuidString, UUID().uuidString]
        state.update { values in
            values.projectSort = .name
            values.threadSort = .created
            values.chatSort = .name
            values.pinnedThreads = pinned
            values.sidebarSections = ["chats", "agents", "projects"]
        }
        state.flush()
        let reloaded = UIState(directory: folder.url).values
        #expect(reloaded.projectSort == .name && reloaded.threadSort == .created && reloaded.chatSort == .name)
        #expect(reloaded.pinnedThreads == pinned)
        // Kept as saved, a section from a newer version included; the sidebar skips what it doesn't know.
        #expect(reloaded.sidebarSections == ["chats", "agents", "projects"])
        #expect(SidebarOrdering.sectionOrder(saved: reloaded.sidebarSections) == [.chats, .projects, .bots, .pinned])
        #expect(reloaded.sidebarThreadsPerProject == nil)
    }
}
