import AppKit
import CoincideKit

/// A small window with one of Coincide's own terminals that runs an agent's sign-in for an added account, with the
/// account's home in its environment so the login lands there instead of the agent's usual home. The account is
/// checked again when the window closes.
final class AccountSignInWindowController: NSWindowController, NSWindowDelegate {
    /// Open sign-in windows, kept alive until they close.
    private static var open: [AccountSignInWindowController] = []

    private let session: TerminalSession
    private let onClose: () -> Void

    /// Runs `command` in a new terminal whose shell gets `environment` on top of the login shell's.
    static func show(title: String, command: String, environment: [String: String], onClose: @escaping () -> Void) {
        let controller = AccountSignInWindowController(title: title, environment: environment, onClose: onClose)
        open.append(controller)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        controller.session.start()
        controller.session.run(command)
    }

    private init(title: String, environment: [String: String], onClose: @escaping () -> Void) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        session = TerminalSession(number: 1, directory: home, missingDirectory: nil, environment: environment)
        self.onClose = onClose
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 420), styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        window.title = title
        window.backgroundColor = Theme.contentBackground
        window.minSize = NSSize(width: 420, height: 240)
        window.isReleasedWhenClosed = false
        window.contentView = session.paneView
        window.center()
        super.init(window: window)
        window.delegate = self
        session.onExit = { [weak self] keepOpen in
            if !keepOpen { self?.window?.performClose(nil) }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func windowWillClose(_ notification: Notification) {
        session.close()
        onClose()
        Self.open.removeAll { $0 === self }
    }
}
