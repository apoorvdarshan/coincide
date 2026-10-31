import AppKit
import CoincideKit

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

    init(avatar: BotAvatar = BotAvatar(character: .alien), size: CGFloat? = nil) {
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
