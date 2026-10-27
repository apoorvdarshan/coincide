import AppKit
import CoincideKit

// STUB: replaced by the real projects / threads sidebar.
final class SidebarViewController: NSViewController {
    var onSelectThread: ((UUID?) -> Void)?

    func select(threadID: UUID?) {}

    override func loadView() {
        view = NSView()
    }
}
