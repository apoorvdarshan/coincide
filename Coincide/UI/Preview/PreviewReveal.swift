import AppKit
import CoincideKit

extension MainWindowController {
    /// Brings `threadID`'s browser forward when that thread is the one open in the window, so an agent never switches
    /// the user away from what they're looking at. True when the user can now see it.
    func revealPreview(for threadID: UUID) -> Bool {
        guard selectedThreadID == threadID else { return false }
        showWindow(nil)
        splitController.showPreviewPanel()
        return NSApp.isActive && window?.isVisible == true
    }
}

extension PreviewSessions {
    /// Connects the browsers to the window and notifications. Called once at launch.
    func connectToApp(_ mainWindow: @escaping () -> MainWindowController?) {
        reveal = { threadID in mainWindow()?.revealPreview(for: threadID) ?? false }
        notifyUser = { threadID, message in NotificationController.shared.browserNeedsUser(threadID, message: message) }
    }
}
