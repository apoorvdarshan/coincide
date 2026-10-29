import AppKit

/// The window a menu bar item drops down, as the system's own menu bar extras do: right under the item that was
/// clicked, on that display and the Space the user is on, over other apps' full-screen windows too. It takes the
/// keyboard without activating Coincide, so opening it never switches Spaces or brings the main window forward.
///
/// An `NSPopover` cannot do this for a regular (Dock) app: its window is an ordinary one of an app that is not active,
/// so macOS keeps it to the Spaces Coincide is on, and it never showed over a full-screen app or in the current Space of
/// another display.
final class StatusItemPanel: NSPanel {
    /// Above full-screen windows and the menu bar, where menus open.
    static let windowLevel: NSWindow.Level = .popUpMenu
    /// On every Space, including other apps' full-screen ones, and left out of Mission Control and window cycling.
    static let spaces: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]

    var onCancel: (() -> Void)?
    var onResignKey: (() -> Void)?

    init() {
        // Non-activating: becoming key does not activate the app, so the menu takes the keyboard where it is.
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        // Before the level: making it a floating panel sets the level to floating.
        isFloatingPanel = true
        level = Self.windowLevel
        collectionBehavior = Self.spaces
        // Coincide is usually not the active app while this shows; it must not hide for that.
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        isExcludedFromWindowsMenu = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        isMovable = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    /// Escape reaches the window itself when no control in it has the keyboard.
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() } else { super.keyDown(with: event) }
    }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }

    // MARK: Placement

    /// A display's whole frame and the part of it windows may use, in screen coordinates.
    struct Screen: Equatable {
        var frame: NSRect
        var visibleFrame: NSRect

        init(frame: NSRect, visibleFrame: NSRect) {
            self.frame = frame
            self.visibleFrame = visibleFrame
        }

        init(_ screen: NSScreen) {
            self.init(frame: screen.frame, visibleFrame: screen.visibleFrame)
        }

        /// The menu bar's height on this display, or `fallback` while it is hidden (a full-screen Space).
        func menuBarHeight(fallback: CGFloat) -> CGFloat {
            let height = frame.maxY - visibleFrame.maxY
            return height > 0 ? height : fallback
        }
    }

    /// The item to open under and the display it is on. `button` is the item's frame on screen, read at the click;
    /// `mouse` is where a mouse click happened (nil when the keyboard or VoiceOver pressed it). The item's frame wins,
    /// unless the click was in the menu bar away from it (a frame from another display's menu bar, or a stale one): the
    /// menu then opens under the click, on the display that was clicked.
    static func anchor(
        button: NSRect?, mouse: NSPoint?, screens: [Screen], menuBarThickness: CGFloat
    ) -> (rect: NSRect, screen: Screen)? {
        func screen(containing point: NSPoint) -> Screen? {
            screens.first { $0.frame.contains(point) }
        }
        let buttonScreen = button.flatMap { screen(containing: NSPoint(x: $0.midX, y: $0.midY)) }
        if let mouse, let mouseScreen = screen(containing: mouse) {
            let barHeight = mouseScreen.menuBarHeight(fallback: menuBarThickness)
            let inMenuBar = mouse.y >= mouseScreen.frame.maxY - barHeight - 2
            let onButton = button.map { $0.insetBy(dx: -8, dy: -8).contains(mouse) } ?? false
            if inMenuBar, !onButton {
                let width = button?.width ?? 1
                let rect = NSRect(x: mouse.x - width / 2, y: mouseScreen.frame.maxY - barHeight, width: width, height: barHeight)
                return (rect, mouseScreen)
            }
        }
        guard let button, let screen = buttonScreen ?? mouse.flatMap(screen(containing:)) ?? screens.first else { return nil }
        return (button, screen)
    }

    /// Where the panel goes: its top just under `anchor`, its leading edge lined up with the item's as a menu's is, and
    /// all of it on `screen`.
    static func frame(size: NSSize, anchor: NSRect, screen: Screen) -> NSRect {
        let gap: CGFloat = 4
        let bounds = screen.frame
        var origin = NSPoint(x: anchor.minX, y: anchor.minY - gap - size.height)
        origin.x = min(max(origin.x, bounds.minX + 4), bounds.maxX - size.width - 4)
        origin.y = max(origin.y, screen.visibleFrame.minY)
        return NSRect(origin: origin, size: size)
    }
}

/// Shows a view under a menu bar item in a `StatusItemPanel`, and closes it as a menu closes: on a click anywhere else,
/// Escape, another app activating or a Space change. Opening never activates Coincide.
@MainActor
final class StatusItemDropdown: NSObject {
    /// What the dropdown asks of the system, replaceable in tests so nothing appears on screen.
    struct Environment {
        var screens: () -> [StatusItemPanel.Screen]
        var menuBarThickness: () -> CGFloat
        /// Puts the panel on screen and gives it the keyboard. The panel is non-activating, so this does not activate
        /// the app.
        var present: (StatusItemPanel) -> Void
        var dismiss: (StatusItemPanel) -> Void
        /// Starts watching clicks and app and Space changes; returns what stops it.
        var watch: (StatusItemDropdown) -> () -> Void

        static let live = Environment(
            screens: { NSScreen.screens.map { StatusItemPanel.Screen($0) } },
            menuBarThickness: { NSStatusBar.system.thickness },
            present: { $0.makeKeyAndOrderFront(nil) },
            dismiss: { $0.orderOut(nil) },
            watch: { $0.startWatching() }
        )
    }

    private let environment: Environment
    private(set) var panel: StatusItemPanel?
    private var content: NSViewController?
    private var sizeObservation: NSKeyValueObservation?
    private var stopWatching: (() -> Void)?
    private weak var buttonWindow: NSWindow?
    private var onClose: (() -> Void)?

    init(environment: Environment = .live) {
        self.environment = environment
    }

    var isShown: Bool { panel != nil }

    /// Opens `content` under `button`. `mouse` is where the click that pressed it happened, if a mouse did.
    func show(_ content: NSViewController, under button: NSView, mouse: NSPoint?, onClose: (() -> Void)? = nil) {
        close()
        guard let window = button.window else { return }
        let buttonRect = window.convertToScreen(button.convert(button.bounds, to: nil))
        guard
            let anchor = StatusItemPanel.anchor(
                button: buttonRect, mouse: mouse, screens: environment.screens(), menuBarThickness: environment.menuBarThickness())
        else { return }
        buttonWindow = window
        self.onClose = onClose
        let panel = StatusItemPanel()
        let surface = FlatSurfaceView(style: .floating)
        surface.cornerRadius = 12
        surface.contentView = content.view
        panel.contentView = surface
        panel.setAccessibilityLabel(content.title)
        panel.onCancel = { [weak self] in self?.close() }
        panel.onResignKey = { [weak self] in self?.resignedKey() }
        self.panel = panel
        self.content = content
        let size = Self.size(of: content)
        panel.setFrame(StatusItemPanel.frame(size: size, anchor: anchor.rect, screen: anchor.screen), display: false)
        // Keeps the top edge under the item as the content grows or shrinks, as the list of accounts changes.
        sizeObservation = content.observe(\.preferredContentSize, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.resize() }
        }
        environment.present(panel)
        stopWatching = environment.watch(self)
    }

    func close() {
        guard let panel else { return }
        self.panel = nil
        sizeObservation = nil
        stopWatching?()
        stopWatching = nil
        // Popups opened from it (the pickers' lists) close with it.
        for child in panel.childWindows ?? [] { child.cancelOperation(nil) }
        environment.dismiss(panel)
        content = nil
        let onClose = onClose
        self.onClose = nil
        onClose?()
    }

    private static func size(of content: NSViewController) -> NSSize {
        let preferred = content.preferredContentSize
        if preferred.width > 0, preferred.height > 0 { return preferred }
        return content.view.fittingSize
    }

    private func resize() {
        guard let panel, let content else { return }
        let size = Self.size(of: content)
        guard size != panel.frame.size else { return }
        var frame = panel.frame
        frame.origin.y = frame.maxY - size.height
        frame.size = size
        if let screen = environment.screens().first(where: { $0.frame.intersects(panel.frame) }) {
            frame.origin.y = max(frame.origin.y, screen.visibleFrame.minY)
        }
        panel.setFrame(frame, display: true)
        panel.invalidateShadow()
    }

    /// Losing the keyboard closes it, unless the keyboard went to a popup opened from it (a picker's list).
    private func resignedKey() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let panel = self.panel, !panel.isKeyWindow else { return }
            if (panel.childWindows ?? []).contains(where: \.isKeyWindow) { return }
            self.close()
        }
    }

    /// Whether a click in one of Coincide's own windows leaves the dropdown open: in it, in a popup opened from it, or
    /// on the item itself (which toggles it).
    func keepsOpen(forClickIn window: NSWindow?) -> Bool {
        guard let window, let panel else { return false }
        if window === panel || window === buttonWindow { return true }
        var parent = window.parent
        while let current = parent {
            if current === panel { return true }
            parent = current.parent
        }
        return false
    }

    fileprivate func startWatching() -> () -> Void {
        let mouseDown: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        // Clicks in other apps, the desktop and other menu bar items.
        let global = NSEvent.addGlobalMonitorForEvents(matching: mouseDown) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
        // Clicks in Coincide's other windows.
        let local = NSEvent.addLocalMonitorForEvents(matching: mouseDown) { [weak self] event in
            MainActor.assumeIsolated {
                if let self, !self.keepsOpen(forClickIn: event.window) { self.close() }
            }
            return event
        }
        let center = NSWorkspace.shared.notificationCenter
        let activation = center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) {
            [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            MainActor.assumeIsolated { self?.close() }
        }
        let space = center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) {
            [weak self] _ in MainActor.assumeIsolated { self?.close() }
        }
        return {
            for monitor in [global, local].compactMap({ $0 }) { NSEvent.removeMonitor(monitor) }
            center.removeObserver(activation)
            center.removeObserver(space)
        }
    }
}
