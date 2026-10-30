import Foundation

/// What the inspector does when the window opens another thread. Each thread keeps its own inspector: open or closed,
/// and on which panel (`UIState.Values.threadPanels`). A column open for the whole window showed every thread the panel
/// one thread had opened, an empty New Tab for each thread that had never used its browser, say. What a panel shows
/// inside (which turn's diff, the pull request list) stays as it is.
enum InspectorFollow {
    enum Change: Equatable {
        /// Leave the inspector as it is.
        case none
        /// Show this panel, opening the inspector if it is closed.
        case show(UIState.InspectorPanel)
        case close
    }

    /// The change for opening a thread whose inspector last showed `saved` (nil: closed, or never opened), while the
    /// window's inspector `isOpen` on `panel`. `available` is the panels the inspector has now: a thread left on a
    /// terminal that has since moved below the chat finds its inspector closed. An agent using a thread's browser out of
    /// sight saves nothing, so the browser doesn't open with the thread.
    static func change(
        isOpen: Bool, panel: UIState.InspectorPanel, saved: UIState.InspectorPanel?, available: [UIState.InspectorPanel]
    ) -> Change {
        guard let saved, available.contains(saved) else { return isOpen ? .close : .none }
        return isOpen && panel == saved ? .none : .show(saved)
    }
}
