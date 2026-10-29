import AppKit
import SwiftUI
import Testing

@testable import Coincide

/// The menu bar item's dropdown: it must show on whatever display and Space the user clicked it, over full-screen apps,
/// without activating Coincide. Nothing here puts a window on screen or adds a real status item: panels are never
/// ordered in (the environment's `present` is a fake) and the item's window is a borderless one that is never shown.
@MainActor
struct StatusItemPanelTests {
    /// A built-in display with a 33pt menu bar at the origin, and a larger one to its right with a 25pt menu bar.
    private let main = StatusItemPanel.Screen(
        frame: NSRect(x: 0, y: 0, width: 1512, height: 982), visibleFrame: NSRect(x: 0, y: 0, width: 1512, height: 949))
    private let secondary = StatusItemPanel.Screen(
        frame: NSRect(x: 1512, y: 0, width: 2560, height: 1440), visibleFrame: NSRect(x: 1512, y: 0, width: 2560, height: 1415))

    @Test func thePanelJoinsEverySpaceOverFullScreenAppsWithoutActivating() {
        let panel = StatusItemPanel()
        #expect(panel.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        #expect(panel.collectionBehavior.contains(.transient))
        #expect(panel.collectionBehavior.contains(.ignoresCycle))
        #expect(!panel.collectionBehavior.contains(.moveToActiveSpace))
        // Where menus open: above full-screen windows and the menu bar.
        #expect(panel.level == .popUpMenu)
        #expect(panel.level.rawValue > NSWindow.Level.statusBar.rawValue)
        // Taking the keyboard does not activate Coincide, and it stays up while Coincide is not active.
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(!panel.hidesOnDeactivate)
        #expect(panel.canBecomeKey)
        #expect(!panel.canBecomeMain)
        #expect(!panel.becomesKeyOnlyIfNeeded)
        #expect(!panel.isVisible)
    }

    @Test func itOpensUnderAnItemOnASecondaryDisplay() throws {
        let button = NSRect(x: 3200, y: 1415, width: 40, height: 25)
        let anchor = try #require(
            StatusItemPanel.anchor(button: button, mouse: NSPoint(x: 3215, y: 1427), screens: [main, secondary], menuBarThickness: 24))
        #expect(anchor.screen == secondary)
        #expect(anchor.rect == button)
        let frame = StatusItemPanel.frame(size: NSSize(width: 340, height: 500), anchor: anchor.rect, screen: anchor.screen)
        #expect(frame.minX == button.minX)
        #expect(frame.maxY == button.minY - 4)
        #expect(secondary.frame.contains(frame))
    }

    @Test func itStaysOnTheDisplayNearItsEdges() {
        // An item at the far right of the secondary display: the panel moves left to stay on it.
        let right = NSRect(x: 4040, y: 1415, width: 30, height: 25)
        let frame = StatusItemPanel.frame(size: NSSize(width: 340, height: 500), anchor: right, screen: secondary)
        #expect(frame.maxX == secondary.frame.maxX - 4)
        #expect(secondary.frame.contains(frame))
        // A display to the left of the main one, at negative coordinates.
        let left = StatusItemPanel.Screen(
            frame: NSRect(x: -1920, y: 0, width: 1920, height: 1080), visibleFrame: NSRect(x: -1920, y: 0, width: 1920, height: 1055))
        let item = NSRect(x: -1930, y: 1055, width: 30, height: 25)
        let leftFrame = StatusItemPanel.frame(size: NSSize(width: 340, height: 500), anchor: item, screen: left)
        #expect(leftFrame.minX == -1916)
        #expect(left.frame.contains(leftFrame))
        // Taller than the room below: it stops at the bottom of the display.
        let tall = StatusItemPanel.frame(size: NSSize(width: 340, height: 2000), anchor: right, screen: secondary)
        #expect(tall.minY == secondary.visibleFrame.minY)
    }

    @Test func aClickAwayFromAStaleFrameOpensUnderTheClick() throws {
        // The item's frame says the main display, but the click was in the secondary display's menu bar.
        let stale = NSRect(x: 1400, y: 949, width: 40, height: 33)
        let anchor = try #require(
            StatusItemPanel.anchor(button: stale, mouse: NSPoint(x: 2600, y: 1430), screens: [main, secondary], menuBarThickness: 24))
        #expect(anchor.screen == secondary)
        #expect(anchor.rect.midX == 2600)
        #expect(anchor.rect.minY == secondary.visibleFrame.maxY)
        #expect(anchor.rect.width == stale.width)
    }

    @Test func aKeyboardPressUsesTheItemsOwnDisplay() throws {
        // VoiceOver or the keyboard pressed it: the pointer may be anywhere, so it is not used.
        let button = NSRect(x: 3200, y: 1415, width: 40, height: 25)
        let anchor = try #require(StatusItemPanel.anchor(button: button, mouse: nil, screens: [main, secondary], menuBarThickness: 24))
        #expect(anchor.screen == secondary)
        #expect(anchor.rect == button)
        // A pointer elsewhere on a display (not in its menu bar) does not move it either.
        let away = try #require(
            StatusItemPanel.anchor(button: button, mouse: NSPoint(x: 500, y: 400), screens: [main, secondary], menuBarThickness: 24))
        #expect(away.screen == secondary)
        #expect(away.rect == button)
    }

    @Test func onAFullScreenSpaceTheHiddenMenuBarUsesTheSystemThickness() throws {
        // A full-screen Space hides the menu bar, so the visible frame reaches the top of the display.
        let fullScreen = StatusItemPanel.Screen(frame: secondary.frame, visibleFrame: secondary.frame)
        #expect(fullScreen.menuBarHeight(fallback: 24) == 24)
        #expect(secondary.menuBarHeight(fallback: 24) == 25)
        let anchor = try #require(
            StatusItemPanel.anchor(button: nil, mouse: NSPoint(x: 2600, y: 1435), screens: [main, fullScreen], menuBarThickness: 24))
        #expect(anchor.screen == fullScreen)
        #expect(anchor.rect.minY == fullScreen.frame.maxY - 24)
    }

    /// The whole open and close with a fake environment, and an item in a window that is never shown.
    @Test func openingPresentsWithoutActivatingAndClosingTearsDown() throws {
        var presented: [StatusItemPanel] = []
        var dismissed: [StatusItemPanel] = []
        var watching = 0
        let environment = StatusItemDropdown.Environment(
            screens: { [main, secondary] },
            menuBarThickness: { 24 },
            present: { presented.append($0) },
            dismiss: { dismissed.append($0) },
            watch: { _ in
                watching += 1
                return { watching -= 1 }
            })
        let dropdown = StatusItemDropdown(environment: environment)
        // The status bar's window on the secondary display, never ordered in.
        let barWindow = NSWindow(
            contentRect: NSRect(x: 3000, y: 1415, width: 200, height: 25), styleMask: [.borderless], backing: .buffered, defer: true)
        let button = NSView(frame: NSRect(x: 100, y: 0, width: 40, height: 25))
        barWindow.contentView?.addSubview(button)
        let controller = NSHostingController(rootView: Text("Usage").frame(width: 200, height: 120))
        controller.preferredContentSize = NSSize(width: 200, height: 120)
        let wasActive = NSApp.isActive
        var closed = 0

        dropdown.show(controller, under: button, mouse: nil, onClose: { closed += 1 })

        let panel = try #require(presented.first)
        #expect(presented.count == 1)
        #expect(dropdown.isShown)
        #expect(watching == 1)
        // Presented by the fake only, so it is not on screen, and opening did not activate Coincide.
        #expect(!panel.isVisible)
        #expect(NSApp.isActive == wasActive)
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        // Under the item, on the secondary display.
        #expect(panel.frame.minX == 3100)
        #expect(panel.frame.maxY == 1411)
        #expect(panel.frame.size == NSSize(width: 200, height: 120))
        #expect(secondary.frame.contains(panel.frame))
        // Clicks in it or on the item keep it open; clicks in another of Coincide's windows close it.
        #expect(dropdown.keepsOpen(forClickIn: panel))
        #expect(dropdown.keepsOpen(forClickIn: barWindow))
        let other = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
        #expect(!dropdown.keepsOpen(forClickIn: other))
        #expect(!dropdown.keepsOpen(forClickIn: nil))

        // It grows downward, its top staying under the item.
        controller.preferredContentSize = NSSize(width: 200, height: 300)
        #expect(panel.frame.maxY == 1411)
        #expect(panel.frame.height == 300)

        // Escape closes it.
        let escape = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "\u{1b}",
                charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        panel.keyDown(with: escape)
        #expect(!dropdown.isShown)
        #expect(dismissed.count == 1 && dismissed.first === panel)
        #expect(watching == 0)
        #expect(closed == 1)
        // Closing again does nothing.
        dropdown.close()
        #expect(dismissed.count == 1)
        #expect(closed == 1)
    }

    @Test func aPickersPopupOverThePanelMatchesIt() {
        let panel = StatusItemPanel()
        let popup = ThemedPopupPanel(over: panel)
        #expect(popup.styleMask.contains(.nonactivatingPanel))
        #expect(popup.level == panel.level)
        #expect(popup.collectionBehavior == panel.collectionBehavior)
        #expect(!popup.hidesOnDeactivate)
        // Over an ordinary window it stays as it was.
        let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        let ordinary = ThemedPopupPanel(over: window)
        #expect(!ordinary.styleMask.contains(.nonactivatingPanel))
        #expect(ordinary.level == .normal)
        #expect(ordinary.hidesOnDeactivate)
    }
}
