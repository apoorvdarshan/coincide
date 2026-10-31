import AppKit

/// Says briefly what an appshot did. Tests replace it, so nothing shows on screen.
@MainActor
protocol AppshotHUDPresenting: AnyObject {
    /// Shows `message` on the display around `frame` (window-server coordinates: points from the top left of the main
    /// display), or the main display when nil. An `alert` (no appshot was taken) also plays the alert sound.
    func show(_ message: String, symbol: String, alert: Bool, around frame: CGRect?)
}

/// A small dark panel in the lower part of the display, like the system's volume and brightness HUDs: it takes no
/// clicks, never becomes key, and fades unless Reduce Motion is on. VoiceOver reads the message out.
final class AppshotHUD: AppshotHUDPresenting {
    private static let duration: Duration = .milliseconds(1400)
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    func show(_ message: String, symbol: String, alert: Bool, around frame: CGRect?) {
        hideTask?.cancel()
        if alert { NSSound.beep() }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.contentView = content(message, symbol: symbol)
        let size = panel.contentView?.fittingSize ?? NSSize(width: 240, height: 48)
        let screen = Self.screen(around: frame)
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        panel.setFrame(
            NSRect(x: visible.midX - size.width / 2, y: visible.minY + visible.height * 0.18, width: size.width, height: size.height),
            display: false)
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        panel.alphaValue = reduceMotion ? 1 : 0
        panel.orderFrontRegardless()
        if !reduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                panel.animator().alphaValue = 1
            }
        }
        NSAccessibility.post(
            element: NSApp as Any, notification: .announcementRequested,
            userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        hideTask = Task { [weak self, weak panel] in
            try? await Task.sleep(for: Self.duration)
            guard !Task.isCancelled, let self, let panel else { return }
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                panel.orderOut(nil)
                return
            }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                panel.animator().alphaValue = 0
            } completionHandler: {
                MainActor.assumeIsolated {
                    if self.hideTask?.isCancelled == false, panel.alphaValue == 0 { panel.orderOut(nil) }
                }
            }
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 48), styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        return panel
    }

    private func content(_ message: String, symbol: String) -> NSView {
        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 14
        background.layer?.cornerCurve = .continuous
        background.layer?.masksToBounds = true

        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 17, weight: .medium)
        icon.contentTintColor = .labelColor
        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 2
        label.preferredMaxLayoutWidth = 360
        let stack = NSStackView(views: [icon, label])
        stack.orientation = .horizontal
        stack.spacing = 9
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        return background
    }

    /// The display showing most of `frame`, which is in window-server coordinates (y down from the main display's top).
    private static func screen(around frame: CGRect?) -> NSScreen? {
        guard let frame, let main = NSScreen.screens.first else { return NSScreen.main }
        let flipped = NSRect(x: frame.minX, y: main.frame.maxY - frame.maxY, width: frame.width, height: frame.height)
        return NSScreen.screens.max { a, b in
            a.frame.intersection(flipped).width * a.frame.intersection(flipped).height
                < b.frame.intersection(flipped).width * b.frame.intersection(flipped).height
        } ?? NSScreen.main
    }
}
