import AppKit

/// Double-clicking the window's top strip does what System Settings › Desktop & Dock asks (zoom by default, or
/// minimize). The content runs under the transparent title bar, so most of that strip is the thread list and the
/// conversation rather than the title bar, and AppKit only handles double-clicks that land on the title bar itself.
/// This handles the whole strip and swallows the click, so AppKit never zooms a second time.
enum TitlebarDoubleClick {
    enum Action: Equatable { case zoom, minimize, none }

    /// The user's choice: `AppleActionOnDoubleClick` ("Maximize", "Minimize", "None"; "Fill" on newer systems), or
    /// the older `AppleMiniaturizeOnDoubleClick`. Zoom when neither is set, as macOS does.
    static func action(
        setting: String? = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick"),
        miniaturizes: Bool = UserDefaults.standard.bool(forKey: "AppleMiniaturizeOnDoubleClick")
    ) -> Action {
        switch setting {
        case "Minimize": .minimize
        case "None": .none
        case .some: .zoom
        case nil: miniaturizes ? .minimize : .zoom
        }
    }

    /// Whether a double-click at `point` (window coordinates) is on the top strip and on nothing that takes clicks
    /// of its own, such as the window buttons, toolbar buttons or a field.
    static func handles(_ point: NSPoint, in window: NSWindow) -> Bool {
        guard !window.styleMask.contains(.fullScreen), point.y >= window.contentLayoutRect.maxY,
            let frame = window.contentView?.superview, let hit = frame.hitTest(frame.convert(point, from: nil))
        else { return false }
        var view: NSView? = hit
        while let current = view {
            if current is NSControl || current is NSText || current is NSTableView { return false }
            view = current.superview
        }
        return true
    }

    /// Starts watching `window`'s double-clicks. Called once.
    static func install(on window: NSWindow) {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak window] event in
            guard let window, event.window === window, event.clickCount == 2,
                handles(event.locationInWindow, in: window)
            else { return event }
            switch action() {
            case .zoom: window.zoom(nil)
            case .minimize: window.miniaturize(nil)
            case .none: return event
            }
            return nil
        }
    }

    private static var monitor: Any?
}
