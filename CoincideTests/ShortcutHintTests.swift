import AppKit
import CoincideKit
import Testing

@testable import Coincide

/// Tooltips and hints that name a menu command's shortcut follow the user's keybindings, read from a controller over
/// a store and a menu of its own.
struct ShortcutHintTests {
    private let folder = TemporaryDirectory("shortcut-hints")
    private let store: AppStore
    private let controller: KeyBindingsController
    private let menu = NSMenu()
    private let stopItem = NSMenuItem(title: "Stop", action: nil, keyEquivalent: "")

    init() {
        store = AppStore(directory: folder.url)
        controller = KeyBindingsController(store: store)
        stopItem.identifier = .keyCommand(.stopTurn)
        menu.addItem(stopItem)
        controller.attach(to: menu)
    }

    private func set(_ command: KeyCommand, _ value: String) {
        store.updateSettings { $0.shortcutOverrides[command.rawValue] = value }
    }

    @Test func toolTipsNameTheCurrentShortcutOrNone() {
        #expect(controller.toolTip("Stop", for: .stopTurn) == "Stop (⌘.)")
        #expect(controller.toolTip("Reasoning effort", for: .reasoningEffort) == "Reasoning effort (⇧⌘E)")
        set(.stopTurn, "ctrl+alt+s")
        #expect(controller.toolTip("Stop", for: .stopTurn) == "Stop (⌃⌥S)")
        // Without a shortcut the tooltip names none.
        set(.stopTurn, "")
        #expect(controller.toolTip("Stop", for: .stopTurn) == "Stop")
        #expect(controller.toolTip("Delete", for: .deleteThread) == "Delete")
        #expect(controller.toolTip("Rename", for: .renameThread) == "Rename (⌘R)")
        // Nor when another command runs on its keys instead.
        set(.toggleTerminal, "mod+shift+e")
        #expect(controller.toolTip("Hide Terminal", for: .toggleTerminal) == "Hide Terminal (⇧⌘E)")
        #expect(controller.toolTip("Reasoning effort", for: .reasoningEffort) == "Reasoning effort")
    }

    /// ⌘R goes to Rename from anywhere in the main window: neither the composer nor a focused terminal keeps it.
    @Test func commandRIsLeftToRename() {
        let commandR = KeyShortcut("mod+r")!
        #expect(!KeyBindingsController.reservedShortcuts(fixed: []).contains { $0.shortcut == commandR })
        #expect(controller.displayString(for: .renameThread) == "⌘R")
    }

    @Test func theComposerSendKeysLeaveOutAKeyAMenuItemHas() {
        let returnKey = KeyShortcut("enter")!
        let commandReturn = KeyShortcut("mod+enter")!
        let shiftCommandReturn = KeyShortcut("mod+shift+enter")!
        #expect(!controller.menuBarHas(returnKey) && !controller.menuBarHas(commandReturn))
        func keys(sendOnReturn: Bool) -> ComposerSendKeys {
            ComposerSendKeys(sendOnReturn: sendOnReturn) { controller.menuBarHas($0) }
        }
        #expect(keys(sendOnReturn: true).alternate == commandReturn)

        // The menu bar sees keys first, so a command given ⌘↩ takes it from the composer.
        set(.newThread, "mod+enter")
        #expect(controller.menuBarHas(commandReturn))
        #expect(keys(sendOnReturn: true).alternate == nil)
        #expect(keys(sendOnReturn: false).send == nil)
        #expect(keys(sendOnReturn: false).alternate == shiftCommandReturn)
        #expect(
            keys(sendOnReturn: true).sendToolTip(running: true, canSteer: true, behavior: .steer)
                == "Steer: send into the current turn (↩). ⌘-click queues it for after the turn.")

        // A fixed menu item's key counts too.
        menu.addItem(NSMenuItem(title: "Fixed", action: nil, keyEquivalent: "\r"))
        menu.items.last?.keyEquivalentModifierMask = [.command, .shift]
        controller.attach(to: menu)
        #expect(controller.menuBarHas(shiftCommandReturn))
        #expect(keys(sendOnReturn: true).steerQueued == nil)
        #expect(!controller.menuBarHas(returnKey))
    }

    @Test func aChangeIsAnnouncedAfterTheMenuHasItsNewShortcut() async {
        await confirmation { announced in
            let observer = NotificationCenter.default.addObserver(
                forName: KeyBindingsController.didChangeNotification, object: controller, queue: nil
            ) { _ in announced() }
            set(.stopTurn, "ctrl+alt+s")
            NotificationCenter.default.removeObserver(observer)
        }
        #expect(stopItem.keyEquivalent == "s" && stopItem.keyEquivalentModifierMask == [.control, .option])
        // Other settings changes leave the shortcuts, and say nothing.
        await confirmation(expectedCount: 0) { announced in
            let observer = NotificationCenter.default.addObserver(
                forName: KeyBindingsController.didChangeNotification, object: controller, queue: nil
            ) { _ in announced() }
            store.updateSettings { $0.sendOnReturn.toggle() }
            NotificationCenter.default.removeObserver(observer)
        }
    }

    @Test func threadNumbersShowWhileTheModifiersOfTheJumpShortcutsAreHeld() {
        #expect(controller.showsThreadJumpHints(for: .command))
        // Other flags, such as Caps Lock, don't count; other modifier keys do.
        #expect(controller.showsThreadJumpHints(for: [.command, .capsLock]))
        #expect(!controller.showsThreadJumpHints(for: [.command, .shift]))
        #expect(!controller.showsThreadJumpHints(for: .control))
        #expect(!controller.showsThreadJumpHints(for: []))
        #expect(controller.displayString(for: .jumpToThread1) == "⌘1")

        for index in 1...9 { set(KeyCommand.jumpToThread(index)!, "ctrl+\(index)") }
        #expect(controller.showsThreadJumpHints(for: .control))
        #expect(!controller.showsThreadJumpHints(for: .command))
        #expect(controller.displayString(for: .jumpToThread9) == "⌃9")

        // A thread whose command has no shortcut shows no number; once none has one, holding keys shows nothing.
        set(.jumpToThread3, "")
        #expect(controller.displayString(for: .jumpToThread3) == nil)
        for index in 1...9 { set(KeyCommand.jumpToThread(index)!, "") }
        #expect(controller.threadJumpModifiers.isEmpty)
        #expect(!controller.showsThreadJumpHints(for: .control) && !controller.showsThreadJumpHints(for: .command))
    }
}
