import AppKit
import CoincideKit

/// "Hold ⌘Q to quit" (`AppSettings.holdToQuit`): takes ⌘Q before the menu bar does and quits only once it is held or
/// pressed twice (`QuitShortcutGuard`), showing a hint near the top of the main window meanwhile. Only the key press is
/// held up: Coincide › Quit Coincide clicked with the mouse, the Dock's Quit, logging out, restarting and AppleScript's
/// `quit` all go straight to `NSApp.terminate`, and the "agents still working" confirmation still follows.
final class QuitShortcut {
    static let shared = QuitShortcut()
    static let shortcut = KeyShortcut("mod+q")!

    private var decision = QuitShortcutGuard()
    private var monitor: Any?
    private var timer: Timer?
    /// The key that started the hold, so its release is seen whatever the keyboard layout.
    private var heldKeyCode: UInt16?
    private var hud: QuitHintHUD?
    private var mainWindow: () -> NSWindow? = { nil }
    private let store: AppStore

    init(store: AppStore = .shared) {
        self.store = store
    }

    func start(mainWindow: @escaping () -> NSWindow?) {
        guard monitor == nil else { return }
        self.mainWindow = mainWindow
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            return self.handle(event) ? nil : event
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.apply(self?.decision.cancel() ?? .none) }
        }
    }

    /// Whether the event was ⌘Q, or its release, and was taken here.
    private func handle(_ event: NSEvent) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        switch event.type {
        case .keyDown:
            guard store.settings.holdToQuit, KeyShortcut(event: event) == Self.shortcut else { return false }
            if !event.isARepeat { heldKeyCode = event.keyCode }
            apply(decision.keyDown(at: now, isRepeat: event.isARepeat))
            return true
        case .keyUp:
            guard event.keyCode == heldKeyCode else { return false }
            heldKeyCode = nil
            apply(decision.keyUp(at: now))
            return false
        case .flagsChanged:
            if heldKeyCode != nil, !event.modifierFlags.contains(.command) {
                heldKeyCode = nil
                apply(decision.keyUp(at: now))
            }
            return false
        default:
            return false
        }
    }

    private func apply(_ action: QuitShortcutGuard.Action) {
        switch action {
        case .none:
            break
        case .showHint:
            showHint()
        case .hideHint:
            hideHint()
        case .quit:
            hideHint()
            heldKeyCode = nil
            // Asks first while agents work (`AppDelegate.applicationShouldTerminate`).
            NSApp.terminate(nil)
        }
        updateProgress()
    }

    private func showHint() {
        let hud = hud ?? QuitHintHUD()
        self.hud = hud
        hud.show(over: mainWindow())
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func hideHint() {
        timer?.invalidate()
        timer = nil
        hud?.hide()
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        // Command let go without a release event reaching the app, as when it went up over another app's window.
        if decision.isHolding, !NSEvent.modifierFlags.contains(.command) {
            heldKeyCode = nil
            apply(decision.keyUp(at: now))
        }
        apply(decision.tick(at: now))
    }

    private func updateProgress() {
        hud?.progress = decision.holdProgress(at: ProcessInfo.processInfo.systemUptime)
    }
}

/// The small hint ⌘Q shows: "Hold ⌘Q to quit" over a bar that fills while it is held. It floats near the top center of
/// the main window, or of the screen when the window is hidden, and never takes clicks or focus.
final class QuitHintHUD {
    let panel: NSPanel
    private let bar = ThemedProgressBar(fraction: 0, color: Theme.accent)
    /// Whether it is showing or fading in, as opposed to hidden or fading out.
    private(set) var isShown = false

    var progress: Double = 0 {
        didSet { bar.fraction = CGFloat(progress) }
    }

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 64), styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = true
        panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]

        let label = NSTextField(labelWithString: String(localized: "Hold ⌘Q to quit"))
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = Theme.ink
        label.alignment = .center
        let stack = NSStackView(views: [label, bar])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 18, bottom: 14, right: 18)
        NSLayoutConstraint.activate([
            bar.widthAnchor.constraint(equalTo: label.widthAnchor),
            label.widthAnchor.constraint(greaterThanOrEqualToConstant: 160),
        ])
        let surface = FlatSurfaceView(style: .floating)
        surface.cornerRadius = 12
        surface.contentView = stack
        panel.contentView = surface
        panel.setContentSize(stack.fittingSize)
        panel.setAccessibilityElement(true)
        panel.setAccessibilityLabel(label.stringValue)
    }

    func show(over window: NSWindow?) {
        bar.color = Theme.accent
        let size = panel.frame.size
        let origin: NSPoint
        if let window, window.isVisible, !window.isMiniaturized {
            // Below the title bar and toolbar, centered on the window.
            let top = window.contentLayoutRect.maxY + window.frame.minY
            origin = NSPoint(x: window.frame.midX - size.width / 2, y: top - size.height - 16)
        } else {
            let screen = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero
            origin = NSPoint(x: screen.midX - size.width / 2, y: screen.maxY - size.height - 40)
        }
        panel.setFrameOrigin(origin)
        guard !isShown else { return }
        isShown = true
        if !panel.isVisible { panel.alphaValue = 0 }
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }
        NSAccessibility.post(
            element: panel, notification: .announcementRequested,
            userInfo: [.announcement: String(localized: "Hold ⌘Q to quit"), .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    func hide() {
        guard isShown else { return }
        isShown = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                // Unless it was shown again while fading out.
                guard let self, !self.isShown else { return }
                self.panel.orderOut(nil)
            }
        }
    }
}
