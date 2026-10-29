import AppKit
import CoincideKit

/// Draws a bot's avatar: a soft body in its color, a light sheen, two eyes with a glint and, at sizes where they
/// read, rosy cheeks. Shapes are laid out on a 100-point grid, top down, and scaled to the rect. The colors are
/// the same in light and dark themes: mid-tones that stand out on either.
enum BotAvatarArt {
    /// The body color of a tint.
    static func color(_ tint: BotAvatar.Tint) -> NSColor {
        switch tint {
        case .sunflower: rgb(0xF5C542)
        case .tangerine: rgb(0xF7A24B)
        case .coral: rgb(0xF2786A)
        case .rose: rgb(0xEE7FAA)
        case .lilac: rgb(0xA98AEF)
        case .sky: rgb(0x63AEF2)
        case .mint: rgb(0x4FCBA2)
        case .sage: rgb(0x93B874)
        }
    }

    static func name(of shape: BotAvatar.Shape) -> String {
        switch shape {
        case .blob: String(localized: "Blob")
        case .pebble: String(localized: "Pebble")
        case .cloud: String(localized: "Cloud")
        case .drop: String(localized: "Drop")
        case .star: String(localized: "Star")
        case .bean: String(localized: "Bean")
        case .bun: String(localized: "Bun")
        case .sprout: String(localized: "Sprout")
        }
    }

    static func name(of tint: BotAvatar.Tint) -> String {
        switch tint {
        case .sunflower: String(localized: "Sunflower")
        case .tangerine: String(localized: "Tangerine")
        case .coral: String(localized: "Coral")
        case .rose: String(localized: "Rose")
        case .lilac: String(localized: "Lilac")
        case .sky: String(localized: "Sky")
        case .mint: String(localized: "Mint")
        case .sage: String(localized: "Sage")
        }
    }

    private static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    private static let eyeColor = rgb(0x1E2230)
    private static let blushColor = rgb(0xFF5F87).withAlphaComponent(0.32)

    /// Draws the avatar into `rect` of the current graphics context, which must be flipped (y grows downward).
    /// `openness` is how far the eyes are open, 1 fully and near 0 mid-blink.
    static func draw(_ avatar: BotAvatar, in rect: CGRect, openness: CGFloat = 1) {
        guard let context = NSGraphicsContext.current?.cgContext, rect.width > 0, rect.height > 0 else { return }
        let scale = min(rect.width, rect.height) / 100
        // Small avatars (sidebar rows, text) get bigger eyes and no glint, so they still read as faces.
        let side = min(rect.width, rect.height)
        let blushes = side >= 18
        let glints = side >= 34
        context.saveGState()
        context.translateBy(x: rect.midX - 50 * scale, y: rect.midY - 50 * scale)
        context.scaleBy(x: scale, y: scale)

        let body = bodyPath(avatar.shape)
        let base = color(avatar.tint)
        if avatar.shape == .sprout { drawSprout(context, base: base) }
        context.addPath(body)
        context.setFillColor(base.cgColor)
        context.fillPath()
        // A sheen from the top left, so the body looks soft rather than flat.
        context.saveGState()
        context.addPath(body)
        context.clip()
        let sheen = CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
            colors: [NSColor.white.withAlphaComponent(0.38).cgColor, NSColor.white.withAlphaComponent(0).cgColor] as CFArray,
            locations: [0, 1])
        if let sheen {
            context.drawRadialGradient(
                sheen, startCenter: CGPoint(x: 34, y: 26), startRadius: 0, endCenter: CGPoint(x: 34, y: 26), endRadius: 52,
                options: [])
        }
        context.restoreGState()
        // A faint edge, so pale bodies hold their shape on light backgrounds.
        context.addPath(body)
        context.setStrokeColor(NSColor.black.withAlphaComponent(0.14).cgColor)
        context.setLineWidth(max(1.2, 1 / scale))
        context.strokePath()

        let eyes = eyeLayout(avatar.shape)
        if blushes {
            context.setFillColor(blushColor.cgColor)
            for x in [eyes.left.x - 9, eyes.right.x + 9] {
                context.fillEllipse(in: CGRect(x: x - 5, y: eyes.left.y + 8, width: 10, height: 5))
            }
        }
        let open = max(0.1, min(1, openness))
        let eyeWidth: CGFloat = glints ? 8 : blushes ? 10 : 12
        let eyeHeight = (glints ? 11 : blushes ? 14 : 16) * open
        context.setFillColor(eyeColor.cgColor)
        for center in [eyes.left, eyes.right] {
            let eye = CGRect(x: center.x - eyeWidth / 2, y: center.y - eyeHeight / 2, width: eyeWidth, height: eyeHeight)
            context.addPath(CGPath(roundedRect: eye, cornerWidth: eyeWidth / 2, cornerHeight: min(eyeHeight, eyeWidth) / 2, transform: nil))
            context.fillPath()
            if glints, open > 0.6 {
                context.setFillColor(NSColor.white.withAlphaComponent(0.9).cgColor)
                context.fillEllipse(in: CGRect(x: center.x - 2.6, y: center.y - 4.4, width: 3.2, height: 3.2))
                context.setFillColor(eyeColor.cgColor)
            }
        }
        context.restoreGState()
    }

    /// The avatar as an image, for menus and text.
    static func image(_ avatar: BotAvatar, size: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            draw(avatar, in: rect)
            return true
        }
        image.accessibilityDescription = String(localized: "Bot avatar")
        return image
    }

    /// Where the eyes sit on each body, on the 100-point grid.
    private static func eyeLayout(_ shape: BotAvatar.Shape) -> (left: CGPoint, right: CGPoint) {
        let y: CGFloat
        var spread: CGFloat = 11
        switch shape {
        case .blob: y = 50
        case .pebble: y = 54
        case .cloud: y = 60
        case .drop: y = 64
        case .star: y = 56; spread = 9
        case .bean: y = 56
        case .bun: y = 60
        case .sprout: y = 60
        }
        return (CGPoint(x: 50 - spread, y: y), CGPoint(x: 50 + spread, y: y))
    }

    private static func bodyPath(_ shape: BotAvatar.Shape) -> CGPath {
        let path = CGMutablePath()
        func curve(_ c1x: CGFloat, _ c1y: CGFloat, _ c2x: CGFloat, _ c2y: CGFloat, _ x: CGFloat, _ y: CGFloat) {
            path.addCurve(to: CGPoint(x: x, y: y), control1: CGPoint(x: c1x, y: c1y), control2: CGPoint(x: c2x, y: c2y))
        }
        switch shape {
        case .blob:
            path.move(to: CGPoint(x: 50, y: 8))
            curve(77, 6, 94, 27, 93, 52)
            curve(92, 78, 73, 94, 49, 93)
            curve(24, 92, 7, 76, 8, 51)
            curve(9, 27, 24, 10, 50, 8)
        case .pebble:
            path.move(to: CGPoint(x: 50, y: 18))
            curve(80, 17, 96, 35, 95, 57)
            curve(94, 79, 76, 88, 50, 88)
            curve(23, 88, 5, 78, 5, 57)
            curve(5, 35, 21, 19, 50, 18)
        case .cloud:
            path.move(to: CGPoint(x: 22, y: 86))
            curve(10, 86, 4, 76, 6, 66)
            curve(8, 56, 16, 50, 25, 51)
            curve(25, 35, 37, 23, 52, 24)
            curve(65, 25, 74, 33, 77, 44)
            curve(89, 43, 97, 53, 96, 65)
            curve(95, 78, 87, 86, 76, 86)
        case .drop:
            path.move(to: CGPoint(x: 50, y: 5))
            curve(58, 22, 88, 44, 88, 64)
            curve(88, 84, 70, 95, 50, 95)
            curve(30, 95, 12, 84, 12, 64)
            curve(12, 44, 42, 22, 50, 5)
        case .star:
            // A chubby five-point star with every corner rounded off.
            let center = CGPoint(x: 50, y: 55)
            let points = (0..<10).map { index -> CGPoint in
                let radius: CGFloat = index.isMultiple(of: 2) ? 48 : 30
                let angle = -CGFloat.pi / 2 + CGFloat(index) * .pi / 5
                return CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
            }
            func middle(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
            path.move(to: middle(points[9], points[0]))
            for index in 0..<10 {
                path.addQuadCurve(to: middle(points[index], points[(index + 1) % 10]), control: points[index])
            }
        case .bean:
            // Round, with a soft dip at the top.
            path.move(to: CGPoint(x: 50, y: 24))
            curve(60, 12, 92, 12, 93, 48)
            curve(94, 78, 74, 92, 50, 92)
            curve(26, 92, 6, 78, 7, 48)
            curve(8, 12, 40, 12, 50, 24)
        case .bun:
            path.move(to: CGPoint(x: 9, y: 78))
            curve(9, 40, 28, 18, 50, 18)
            curve(72, 18, 91, 40, 91, 78)
            curve(91, 86, 85, 90, 77, 90)
            path.addLine(to: CGPoint(x: 23, y: 90))
            curve(15, 90, 9, 86, 9, 78)
        case .sprout:
            path.addEllipse(in: CGRect(x: 14, y: 24, width: 72, height: 70))
        }
        path.closeSubpath()
        return path
    }

    /// The sprout's stem and leaf, drawn behind its body in a deeper shade of it.
    private static func drawSprout(_ context: CGContext, base: NSColor) {
        let leaf = (base.blended(withFraction: 0.35, of: .black) ?? base).cgColor
        context.setStrokeColor(leaf)
        context.setLineWidth(4)
        context.setLineCap(.round)
        context.move(to: CGPoint(x: 50, y: 28))
        context.addQuadCurve(to: CGPoint(x: 52, y: 12), control: CGPoint(x: 49, y: 20))
        context.strokePath()
        let blade = CGMutablePath()
        blade.move(to: CGPoint(x: 52, y: 13))
        blade.addCurve(to: CGPoint(x: 76, y: 6), control1: CGPoint(x: 56, y: 3), control2: CGPoint(x: 70, y: 1))
        blade.addCurve(to: CGPoint(x: 52, y: 13), control1: CGPoint(x: 72, y: 15), control2: CGPoint(x: 60, y: 18))
        blade.closeSubpath()
        context.addPath(blade)
        context.setFillColor(leaf)
        context.fillPath()
    }
}

/// A bot's avatar as a view, the same at every size: sidebar rows, the window title, the transcript and the editor.
/// While `isAnimating` (its bot is working) the eyes blink now and then, unless the user asked to reduce motion.
final class BotAvatarView: NSView {
    var avatar: BotAvatar {
        didSet { if avatar != oldValue { needsDisplay = true } }
    }

    var isAnimating = false {
        didSet { if isAnimating != oldValue { updateBlinking() } }
    }

    private var openness: CGFloat = 1 {
        didSet { needsDisplay = true }
    }
    private var blinkTimer: Timer?

    init(avatar: BotAvatar = BotAvatar(shape: .blob, tint: .sky), size: CGFloat? = nil) {
        self.avatar = avatar
        super.init(frame: NSRect(x: 0, y: 0, width: size ?? 24, height: size ?? 24))
        if let size {
            translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: size), heightAnchor.constraint(equalToConstant: size)])
        }
        setAccessibilityElement(false)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(motionPreferenceChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    isolated deinit {
        blinkTimer?.invalidate()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let side = min(bounds.width, bounds.height)
        BotAvatarArt.draw(avatar, in: CGRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side), openness: openness)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateBlinking()
    }

    @objc private func motionPreferenceChanged() { updateBlinking() }

    private func updateBlinking() {
        let blinks = isAnimating && window != nil && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard blinks != (blinkTimer != nil) else { return }
        blinkTimer?.invalidate()
        blinkTimer = nil
        openness = 1
        guard blinks else { return }
        scheduleBlink()
    }

    /// Blinks every few seconds, at slightly uneven intervals so several bots never blink in step.
    private func scheduleBlink() {
        blinkTimer = Timer.scheduledTimer(withTimeInterval: .random(in: 2.2...4.2), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.blinkTimer != nil else { return }
                self.openness = 0.12
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.13) { [weak self] in
                    guard let self, self.blinkTimer != nil else { return }
                    self.openness = 1
                    self.scheduleBlink()
                }
            }
        }
    }
}
