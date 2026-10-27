import AppKit
import CoincideKit

// STUB: replaced by the real main window (sidebar | chat + terminal | diff inspector).
final class MainWindowController: NSWindowController {
    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered,
            defer: false)
        window.title = "Coincide"
        window.contentViewController = ChatViewController()
        self.init(window: window)
    }
}
