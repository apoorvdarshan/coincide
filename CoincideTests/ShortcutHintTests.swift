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
        #expect(controller.toolTip("Rename", for: .renameThread) == "Rename")
        // Nor when another command runs on its keys instead.
        set(.toggleTerminal, "mod+shift+e")
        #expect(controller.toolTip("Hide Terminal", for: .toggleTerminal) == "Hide Terminal (⇧⌘E)")
        #expect(controller.toolTip("Reasoning effort", for: .reasoningEffort) == "Reasoning effort")
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
