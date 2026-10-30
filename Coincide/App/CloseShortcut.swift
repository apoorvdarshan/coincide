import AppKit
import CoincideKit

/// ⌘W in Coincide's other windows. In the main window ⌘W is Thread › Archive Thread (`KeyCommand.archiveThread`) and
/// File › Close Window is ⌘⇧W, so without this ⌘W in Settings, Instructions or a sheet would reach Archive Thread. When
/// the key window is not the main window, ⌘W closes it: a window with a close button closes, and a sheet, alert or
/// panel without one is dismissed as Escape dismisses it. In the main window ⌘W goes on to the menu bar, where it does
/// nothing when no thread is open.
enum CloseShortcut {
    static let shortcut = KeyShortcut("mod+w")!
    private static var monitor: Any?

    /// Starts watching key presses. `mainWindow` gives the main window at the time of a press.
    static func start(mainWindow: @escaping () -> NSWindow?) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event, keyWindow: NSApp.keyWindow, mainWindow: mainWindow()) ? nil : event
        }
    }

    /// Closes `keyWindow` for a ⌘W press when it is not the main window. Returns whether it took the press.
    @discardableResult
    static func handle(_ event: NSEvent, keyWindow: NSWindow?, mainWindow: NSWindow?) -> Bool {
        guard let window = window(toCloseFor: event, keyWindow: keyWindow, mainWindow: mainWindow) else { return false }
        close(window, timestamp: event.timestamp)
        // Taken even when nothing closed, so the press never falls through to Archive Thread.
        return true
    }

    /// The window a key press closes: the key window for ⌘W, unless it is the main window, where ⌘W is left to the
    /// menu bar.
    static func window(toCloseFor event: NSEvent, keyWindow: NSWindow?, mainWindow: NSWindow?) -> NSWindow? {
        guard event.type == .keyDown, KeyShortcut(event: event) == shortcut, let keyWindow, keyWindow !== mainWindow else {
            return nil
        }
        return keyWindow
    }

    private static func close(_ window: NSWindow, timestamp: TimeInterval) {
        if window.styleMask.contains(.closable), window.sheetParent == nil {
            window.performClose(nil)
            return
        }
        // A sheet or a panel without a close button: as Escape, which presses its Cancel button or cancels it.
        if let escape = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: timestamp, windowNumber: window.windowNumber,
            context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53),
            window.performKeyEquivalent(with: escape)
        {
            return
        }
        if NSApp.sendAction(#selector(NSResponder.cancelOperation(_:)), to: nil, from: window) { return }
        NSSound.beep()
    }
}
