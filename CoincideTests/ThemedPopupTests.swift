import AppKit
import Testing

@testable import Coincide
@testable import CoincideKit

/// Themed popups opening and closing as menus do. Nothing here reaches the screen: the popup's environment is a fake
/// that never orders a panel in, and the controls sit in a borderless window offscreen that is never shown.
@MainActor
struct ThemedPopupTests {
    /// Records what popups ask of the system.
    private final class FakeEnvironment {
        var presented: [ThemedPopupPanel] = []
        var dismissed: [ThemedPopupPanel] = []
        var watched: [ThemedPopup] = []
        var watching = 0
        var swallowedMouseUps = 0
        var screens: [StatusItemPanel.Screen] = []

        var environment: ThemedPopup.Environment {
            ThemedPopup.Environment(
                present: { [unowned self] panel, _ in presented.append(panel) },
                dismiss: { [unowned self] panel, _ in dismissed.append(panel) },
                watchClicks: { [unowned self] popup in
                    watched.append(popup)
                    watching += 1
                    return { [unowned self] in watching -= 1 }
                },
                swallowNextMouseUp: { [unowned self] in swallowedMouseUps += 1 },
                screens: { [unowned self] in screens })
        }
    }

    private static func offscreenWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: -20000, y: -20000, width: 400, height: 200), styleMask: [.borderless], backing: .buffered,
            defer: false)
        window.alphaValue = 0
        window.isReleasedWhenClosed = false
        return window
    }

    private static func menu() -> NSMenu {
        let menu = NSMenu()
        for title in ["Max", "Ultracode", "Ultrathink"] { menu.addItem(withTitle: title, action: nil, keyEquivalent: "") }
        return menu
    }

    private static func mouseDown(at point: NSPoint, in window: NSWindow, number: Int) throws -> NSEvent {
        try #require(
            NSEvent.mouseEvent(
                with: .leftMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: number, clickCount: 1, pressure: 1))
    }

    private static func middle(of view: NSView) -> NSPoint {
        view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
    }

    /// The reported bug: a second click on the composer's effort control closed its menu and opened it again.
    @Test func aSecondClickOnTheControlClosesItsMenuWithoutReopening() throws {
        let fake = FakeEnvironment()
        ThemedPopup.environment = fake.environment
        defer { ThemedPopup.environment = .live }
        let window = Self.offscreenWindow()
        let button = ComposerControlButton(frame: NSRect(x: 20, y: 20, width: 120, height: 26))
        button.configure(title: "Max", symbolName: "brain", chevron: true)
        button.menuProvider = { Self.menu() }
        window.contentView?.addSubview(button)

        button.mouseDown(with: try Self.mouseDown(at: Self.middle(of: button), in: window, number: 1))
        #expect(fake.presented.count == 1)
        #expect(button.isMenuOpen)
        let popup = try #require(fake.watched.first)
        #expect(fake.watching == 1)

        // The second click reaches the popup's monitor before its window: it closes the menu and goes no further, so
        // the control never sees it and nothing opens again.
        let second = try Self.mouseDown(at: Self.middle(of: button), in: window, number: 2)
        #expect(popup.clickedBeforeDispatch(second) == nil)
        #expect(fake.dismissed.count == 1)
        #expect(fake.presented.count == 1)
        #expect(fake.swallowedMouseUps == 1)
        #expect(fake.watching == 0)
        // Its open highlight clears with it.
        #expect(!button.isMenuOpen)

        // A third click opens it again.
        button.mouseDown(with: try Self.mouseDown(at: Self.middle(of: button), in: window, number: 3))
        #expect(fake.presented.count == 2)
        #expect(button.isMenuOpen)
        fake.watched.last?.close()
        #expect(!button.isMenuOpen)
        #expect(fake.watching == 0)
    }

    @Test func aClickAwayFromTheControlIsLeftToItsWindow() throws {
        let fake = FakeEnvironment()
        ThemedPopup.environment = fake.environment
        defer { ThemedPopup.environment = .live }
        let window = Self.offscreenWindow()
        let button = ComposerControlButton(frame: NSRect(x: 20, y: 20, width: 120, height: 26))
        button.menuProvider = { Self.menu() }
        let other = ComposerControlButton(frame: NSRect(x: 200, y: 20, width: 120, height: 26))
        other.menuProvider = { Self.menu() }
        window.contentView?.addSubview(button)
        window.contentView?.addSubview(other)
        button.performClick(nil)
        let popup = try #require(fake.watched.first)

        // On another control or on nothing: the click goes on, and the popup closes when its window takes the keyboard.
        for point in [Self.middle(of: other), NSPoint(x: 380, y: 180)] {
            let click = try Self.mouseDown(at: point, in: window, number: 1)
            #expect(popup.clickedBeforeDispatch(click) === click)
        }
        #expect(fake.dismissed.isEmpty)
        #expect(fake.swallowedMouseUps == 0)
        #expect(button.isMenuOpen)
        popup.close()
    }

    @Test func aControlHiddenUnderAnotherViewLetsTheClickThrough() throws {
        let fake = FakeEnvironment()
        ThemedPopup.environment = fake.environment
        defer { ThemedPopup.environment = .live }
        let window = Self.offscreenWindow()
        let button = ComposerControlButton(frame: NSRect(x: 20, y: 20, width: 120, height: 26))
        button.menuProvider = { Self.menu() }
        window.contentView?.addSubview(button)
        button.performClick(nil)
        let popup = try #require(fake.watched.first)
        // A view now covers the control, so a click there is the cover's.
        let cover = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        window.contentView?.addSubview(cover)
        let click = try Self.mouseDown(at: Self.middle(of: button), in: window, number: 1)
        #expect(popup.clickedBeforeDispatch(click) === click)
        #expect(fake.dismissed.isEmpty)
        popup.close()
    }

    @Test func aContextMenuWatchesNoControl() throws {
        let fake = FakeEnvironment()
        ThemedPopup.environment = fake.environment
        defer { ThemedPopup.environment = .live }
        let window = Self.offscreenWindow()
        let popup = try #require(ThemedPopup.show(ThemedMenuViewController(menu: Self.menu()), at: NSPoint(x: -19900, y: -19900), in: window))
        #expect(fake.presented.count == 1)
        #expect(fake.watched.isEmpty)
        popup.close()
        #expect(fake.dismissed.count == 1)
    }

    /// A control whose popup cannot open (it is in no window) is not left highlighted as if it were open.
    @Test func aPopupThatCannotOpenLeavesNoHighlight() {
        let fake = FakeEnvironment()
        ThemedPopup.environment = fake.environment
        defer { ThemedPopup.environment = .live }
        let button = ComposerControlButton(frame: NSRect(x: 0, y: 0, width: 120, height: 26))
        button.menuProvider = { Self.menu() }
        button.performClick(nil)
        #expect(fake.presented.isEmpty)
        #expect(!button.isMenuOpen)
    }

    @Test func aPullDownButtonIsHighlightedOnlyWhileItsMenuIsOpen() throws {
        let fake = FakeEnvironment()
        ThemedPopup.environment = fake.environment
        defer { ThemedPopup.environment = .live }
        let window = Self.offscreenWindow()
        let popUp = ThemedPopUpButton(frame: NSRect(x: 20, y: 20, width: 160, height: 26), pullsDown: true)
        popUp.menu = Self.menu()
        window.contentView?.addSubview(popUp)
        popUp.performClick(nil)
        #expect(popUp.cell?.isHighlighted == true)
        let popup = try #require(fake.watched.first)
        #expect(popup.clickedBeforeDispatch(try Self.mouseDown(at: Self.middle(of: popUp), in: window, number: 1)) == nil)
        #expect(popUp.cell?.isHighlighted == false)
        #expect(fake.presented.count == 1)

        // Out of a window it cannot open, and stays unhighlighted.
        popUp.removeFromSuperview()
        popUp.performClick(nil)
        #expect(popUp.cell?.isHighlighted == false)
        #expect(fake.presented.count == 1)
    }

    /// Escape reaches the panel itself when nothing in it has the keyboard, as in the usage and context details.
    @Test func escapeClosesAPopupOfDetails() throws {
        let fake = FakeEnvironment()
        ThemedPopup.environment = fake.environment
        defer { ThemedPopup.environment = .live }
        let window = Self.offscreenWindow()
        let anchor = NSView(frame: NSRect(x: 20, y: 20, width: 30, height: 26))
        window.contentView?.addSubview(anchor)
        var closed = 0
        ThemedPopup.show(ThemedPopupViewHost(NSTextField(labelWithString: "Details")), from: anchor) { closed += 1 }
        let panel = try #require(fake.presented.first)
        let escape = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "\u{1b}",
                charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        panel.keyDown(with: escape)
        #expect(closed == 1)
        #expect(fake.dismissed.first === panel)
    }

    @Test func escapeInTheDiffCommentFieldCancels() {
        let draft = MessageContext.DiffComment(path: "a.txt", lineStart: 1, lineEnd: 1, isBeforeChange: false, diff: "@@ -1 +1 @@\n-a\n+b", comment: "")
        let editor = DiffCommentEditor(draft: draft)
        var closed = 0
        var added = 0
        editor.close = { closed += 1 }
        editor.onAdd = { _ in added += 1 }
        #expect(editor.textView(NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        #expect(closed == 1)
        #expect(added == 0)
        // Other commands are the text view's.
        #expect(!editor.textView(NSTextView(), doCommandBy: #selector(NSResponder.moveLeft(_:))))
    }

    /// A window across two displays: the popup goes on the display of the control, not the one holding most of the
    /// window.
    @Test func itOpensOnTheDisplayOfTheControl() {
        let main = StatusItemPanel.Screen(
            frame: NSRect(x: 0, y: 0, width: 1512, height: 982), visibleFrame: NSRect(x: 0, y: 0, width: 1512, height: 949))
        let right = StatusItemPanel.Screen(
            frame: NSRect(x: 1512, y: 0, width: 2560, height: 1440), visibleFrame: NSRect(x: 1512, y: 0, width: 2560, height: 1415))
        #expect(ThemedPopup.screen(for: NSRect(x: 1600, y: 300, width: 120, height: 26), screens: [main, right]) == right)
        #expect(ThemedPopup.screen(for: NSRect(x: 1300, y: 300, width: 120, height: 26), screens: [main, right]) == main)
        // A context menu's point on the top edge of a display.
        #expect(ThemedPopup.screen(for: NSRect(x: 2000, y: 1440, width: 0, height: 0), screens: [main, right]) == right)
        #expect(ThemedPopup.screen(for: NSRect(x: -5000, y: 300, width: 10, height: 10), screens: [main, right]) == nil)
        // Placed on that display, it stays inside it.
        let frame = ThemedPopup.frame(
            size: NSSize(width: 300, height: 400), anchor: NSRect(x: 1520, y: 1380, width: 120, height: 26), screen: right.visibleFrame,
            preferAbove: true)
        #expect(right.visibleFrame.contains(frame))
    }
}
