import AppKit
import CoincideKit

/// Shown beside the microphone while dictating: a level meter in the theme's accent, the time so far and a cancel
/// button (Escape). While the engine gets ready it says so, with the download's progress; once listening stops it
/// says the transcript is on its way.
final class ComposerDictationIndicator: NSView {
    let cancelButton = ComposerControlButton()
    private let meter = DictationLevelMeter()
    private let label = NSTextField(labelWithString: "")
    private let stack = NSStackView()
    private var clock: Timer?
    private var since: Date?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        cancelButton.configure(title: "", symbolName: "xmark", chevron: false)
        cancelButton.toolTip = String(localized: "Cancel dictation (Esc)")
        cancelButton.setAccessibilityLabel(String(localized: "Cancel dictation"))
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.alignment = .centerY
        for view in [meter, label, cancelButton] as [NSView] { stack.addArrangedSubview(view) }
        stack.setCustomSpacing(2, after: label)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            meter.widthAnchor.constraint(equalToConstant: DictationLevelMeter.width),
            meter.heightAnchor.constraint(equalToConstant: 16),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(String(localized: "Dictation"))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ state: DictationController.State) {
        clock?.invalidate()
        clock = nil
        switch state {
        case .idle:
            since = nil
            meter.reset()
        case .preparing(let progress):
            meter.isHidden = true
            label.stringValue =
                progress.map { String(localized: "Downloading speech model… \(Int(($0 * 100).rounded()))%") }
                ?? String(localized: "Getting ready…")
        case .listening(let start):
            meter.isHidden = false
            since = start
            updateClock()
            clock = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateClock() }
            }
            NSAccessibility.post(
                element: self, notification: .announcementRequested,
                userInfo: [.announcement: String(localized: "Listening"), .priority: NSAccessibilityPriorityLevel.high.rawValue])
        case .transcribing:
            meter.isHidden = true
            label.stringValue = String(localized: "Transcribing…")
        }
        setAccessibilityValue(label.stringValue)
    }

    func setLevel(_ level: Float) { meter.push(level) }

    private func updateClock() {
        guard let since else { return }
        let seconds = Int(Date().timeIntervalSince(since))
        label.stringValue = String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// Bars that rise with the microphone's level, newest on the right, in the theme's accent. With Reduce Motion they don't
/// scroll: one steady bar shows the level.
final class DictationLevelMeter: NSView {
    static let width: CGFloat = 34
    private static let count = 7
    private var levels = [Float](repeating: 0, count: DictationLevelMeter.count)

    override var isFlipped: Bool { true }

    func push(_ level: Float) {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            levels = [Float](repeating: 0, count: Self.count)
            levels[Self.count - 1] = level
        } else {
            levels.removeFirst()
            levels.append(level)
        }
        needsDisplay = true
    }

    func reset() {
        levels = [Float](repeating: 0, count: Self.count)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        Theme.accent.setFill()
        if reduceMotion {
            let level = CGFloat(levels.last ?? 0)
            let track = NSRect(x: 0, y: bounds.midY - 2, width: bounds.width, height: 4)
            Theme.accent.withAlphaComponent(0.25).setFill()
            NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2).fill()
            Theme.accent.setFill()
            NSBezierPath(roundedRect: NSRect(x: 0, y: track.minY, width: max(4, track.width * level), height: 4), xRadius: 2, yRadius: 2)
                .fill()
            return
        }
        let gap: CGFloat = 2
        let barWidth = (bounds.width - gap * CGFloat(Self.count - 1)) / CGFloat(Self.count)
        for (index, level) in levels.enumerated() {
            let height = max(3, bounds.height * CGFloat(level))
            let rect = NSRect(
                x: CGFloat(index) * (barWidth + gap), y: (bounds.height - height) / 2, width: barWidth, height: height)
            NSBezierPath(roundedRect: rect, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
        }
    }

    override func isAccessibilityElement() -> Bool { false }
}
