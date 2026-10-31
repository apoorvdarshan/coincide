import AppKit
import QuartzCore

/// Where the agent cursor goes on the user's displays. Pure maths, so it can be checked without any window.
///
/// Cua Driver reports positions in global screen points with the origin at the top left of the main display and y
/// growing down (Core Graphics). AppKit places screens with the origin at the bottom left of the primary screen and y
/// growing up. Displays above or left of the main one have negative coordinates in the first space.
enum AgentCursorGeometry {
    /// The cursor's drawn size; the hot spot is its top-left tip.
    static let size = CGSize(width: 22, height: 28)

    static func appKitPoint(fromTopLeft point: CGPoint, primaryHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryHeight - point.y)
    }

    /// The screen containing `point`, else the nearest one, so a point just past an edge still shows.
    static func screenIndex(containing point: CGPoint, in frames: [CGRect]) -> Int? {
        if let index = frames.firstIndex(where: { $0.contains(point) }) { return index }
        return frames.indices.min { distance(from: point, to: frames[$0]) < distance(from: point, to: frames[$1]) }
    }

    /// The point clamped into its screen, so the tip never sits where no display can show it.
    static func clamped(_ point: CGPoint, in frames: [CGRect]) -> CGPoint {
        guard let index = screenIndex(containing: point, in: frames) else { return point }
        let frame = frames[index]
        return CGPoint(x: min(max(point.x, frame.minX), frame.maxX - 1), y: min(max(point.y, frame.minY + 1), frame.maxY))
    }

    /// The cursor's rectangle in AppKit coordinates for a tip at `point` (it hangs below and right of the tip).
    static func cursorRect(tip point: CGPoint) -> CGRect {
        CGRect(x: point.x, y: point.y - size.height, width: size.width, height: size.height)
    }

    /// Every screen the cursor overlaps, so a cursor crossing an edge is drawn on both sides without a jump.
    static func screensShowing(tip point: CGPoint, in frames: [CGRect]) -> [Int] {
        let rect = cursorRect(tip: point)
        return frames.indices.filter { frames[$0].intersects(rect) }
    }

    /// The tip in a screen's own window coordinates.
    static func local(_ point: CGPoint, in frame: CGRect) -> CGPoint {
        CGPoint(x: point.x - frame.minX, y: point.y - frame.minY)
    }

    /// An eased point along a glide; `progress` runs from 0 to 1.
    static func glide(from start: CGPoint, to end: CGPoint, progress: Double) -> CGPoint {
        let t = min(max(progress, 0), 1)
        let eased = t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
        return CGPoint(x: start.x + (end.x - start.x) * eased, y: start.y + (end.y - start.y) * eased)
    }

    private static func distance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return dx * dx + dy * dy
    }
}

/// Shows where agents act, for Computer Use.
@MainActor
protocol AgentCursorPresenting: AnyObject {
    /// Glides the cursor to `point` (global top-left screen points), with a pulse when the action pressed there.
    func move(to point: CGPoint, pressed: Bool)
    func hide()
}

/// The agent cursor, drawn by Coincide on whichever display the agent acts on.
///
/// One transparent, click-through window per screen, made on first use and rebuilt when displays change; each draws
/// at its own screen's scale. Windows never become key, stay out of screen sharing and the window cycle, and are
/// closed after the cursor hides, so nothing runs while agents aren't acting.
@MainActor
final class AgentCursorOverlay: AgentCursorPresenting {
    private final class ScreenWindow {
        let window: NSWindow
        let frame: CGRect
        let cursor = CAShapeLayer()
        let pulse = CAShapeLayer()

        init(screen: NSScreen) {
            frame = screen.frame
            window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: true)
            window.setFrame(screen.frame, display: false)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.ignoresMouseEvents = true
            window.isReleasedWhenClosed = false
            window.level = .statusBar
            window.sharingType = .none
            window.animationBehavior = .none
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            let view = NSView(frame: CGRect(origin: .zero, size: screen.frame.size))
            view.wantsLayer = true
            window.contentView = view
            let scale = screen.backingScaleFactor
            let accent = NSColor.controlAccentColor.cgColor
            cursor.path = Self.arrow()
            cursor.fillColor = accent
            cursor.strokeColor = NSColor.white.cgColor
            cursor.lineWidth = 1.5
            cursor.lineJoin = .round
            cursor.shadowOpacity = 0.35
            cursor.shadowRadius = 2
            cursor.shadowOffset = CGSize(width: 0, height: -1)
            cursor.bounds = CGRect(origin: .zero, size: AgentCursorGeometry.size)
            cursor.anchorPoint = CGPoint(x: 0, y: 1)
            cursor.contentsScale = scale
            cursor.isHidden = true
            pulse.path = CGPath(ellipseIn: CGRect(x: -14, y: -14, width: 28, height: 28), transform: nil)
            pulse.fillColor = nil
            pulse.strokeColor = accent
            pulse.lineWidth = 2
            pulse.opacity = 0
            pulse.contentsScale = scale
            view.layer?.addSublayer(pulse)
            view.layer?.addSublayer(cursor)
        }

        /// The classic pointer, tip at the top left of its bounds (y up, as layers draw on macOS).
        private static func arrow() -> CGPath {
            let h = AgentCursorGeometry.size.height
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 1, y: h - 1))
            path.addLine(to: CGPoint(x: 1, y: h - 22))
            path.addLine(to: CGPoint(x: 6.5, y: h - 17))
            path.addLine(to: CGPoint(x: 10, y: h - 25))
            path.addLine(to: CGPoint(x: 13.5, y: h - 23.5))
            path.addLine(to: CGPoint(x: 10, y: h - 15.5))
            path.addLine(to: CGPoint(x: 17, y: h - 15.5))
            path.closeSubpath()
            return path
        }
    }

    static let glideDuration: TimeInterval = 0.3
    /// Hidden this long after the last action; agents often think for a while between steps.
    static let idleHide: TimeInterval = 10

    private var windows: [ScreenWindow] = []
    private var current: CGPoint?
    private var glide: Timer?
    private var idle: Timer?
    private var screensObserver: NSObjectProtocol?

    init() {}

    isolated deinit {
        glide?.invalidate()
        idle?.invalidate()
        if let screensObserver { NotificationCenter.default.removeObserver(screensObserver) }
        for screen in windows { screen.window.close() }
    }

    func move(to topLeft: CGPoint, pressed: Bool) {
        // Tests never put windows on the user's screen; they check `AgentCursorGeometry` instead.
        guard !AppDelegate.isHostingTests, let primary = NSScreen.screens.first else { return }
        if windows.isEmpty { buildWindows() }
        let frames = windows.map(\.frame)
        let target = AgentCursorGeometry.clamped(
            AgentCursorGeometry.appKitPoint(fromTopLeft: topLeft, primaryHeight: primary.frame.height), in: frames)
        let start = current ?? target
        glide?.invalidate()
        if start == target || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            place(target)
            if pressed { self.pulse(at: target) }
        } else {
            let began = Date()
            // deinit invalidates the timer, so a released overlay never keeps it firing.
            glide = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let progress = Date().timeIntervalSince(began) / Self.glideDuration
                    self.place(AgentCursorGeometry.glide(from: start, to: target, progress: progress))
                    guard progress >= 1 else { return }
                    self.glide?.invalidate()
                    self.glide = nil
                    if pressed { self.pulse(at: target) }
                }
            }
        }
        idle?.invalidate()
        idle = Timer.scheduledTimer(withTimeInterval: Self.idleHide, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
    }

    func hide() {
        glide?.invalidate()
        glide = nil
        idle?.invalidate()
        idle = nil
        current = nil
        for screen in windows { screen.window.close() }
        windows.removeAll()
    }

    private func buildWindows() {
        windows = NSScreen.screens.map(ScreenWindow.init)
        if screensObserver == nil {
            screensObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, !self.windows.isEmpty else { return }
                    let point = self.current
                    for screen in self.windows { screen.window.close() }
                    self.windows = NSScreen.screens.map(ScreenWindow.init)
                    if let point { self.place(AgentCursorGeometry.clamped(point, in: self.windows.map(\.frame))) }
                }
            }
        }
    }

    private func place(_ point: CGPoint) {
        current = point
        let showing = Set(AgentCursorGeometry.screensShowing(tip: point, in: windows.map(\.frame)))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, screen) in windows.enumerated() {
            guard showing.contains(index) else {
                screen.cursor.isHidden = true
                continue
            }
            screen.cursor.position = AgentCursorGeometry.local(point, in: screen.frame)
            screen.cursor.isHidden = false
            if !screen.window.isVisible { screen.window.orderFrontRegardless() }
        }
        CATransaction.commit()
    }

    private func pulse(at point: CGPoint) {
        guard let index = AgentCursorGeometry.screenIndex(containing: point, in: windows.map(\.frame)) else { return }
        let screen = windows[index]
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        screen.pulse.position = AgentCursorGeometry.local(point, in: screen.frame)
        CATransaction.commit()
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.3
        scale.toValue = 1.4
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.7
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = 0.35
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        screen.pulse.add(group, forKey: "pulse")
    }
}
