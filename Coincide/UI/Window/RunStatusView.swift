import AppKit
import CoincideKit

/// The toolbar's run status for the open thread: "Connecting…", "Working 0:42" with a stop
/// button, or "Needs approval". Hidden while the thread is idle.
final class RunStatusView: NSView {
    enum State: Equatable {
        case idle
        case starting
        /// `note` says why the agent works when it started the turn itself, such as
        /// "Claude Code continued on its own."
        case running(since: Date, note: String?)
        case approval(count: Int)
    }

    /// The space between the scripts' pill and this one, which are drawn independently, including in toolbars the user
    /// has already customized and saved.
    static let pillSpacing: CGFloat = 8
    /// The part of `pillSpacing` this item leaves transparent inside itself: what the toolbar's own spacing doesn't
    /// give. macOS 27.2 places toolbar items flush, so all of it; 27.0 pads every item's view by 4 points a side, so
    /// none, and the narrowest window still has room for the status.
    private(set) var leadingGap: CGFloat = RunStatusView.pillSpacing
    private var leadingConstraint: NSLayoutConstraint?
    private let pill = NSView()
    private let spinner = NSProgressIndicator()
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let stopButton: NSButton
    private var timer: Timer?
    private(set) var state: State = .idle
    var onStop: (() -> Void)?
    /// Called when the view switches between idle and active, so the toolbar can hide its item.
    var onVisibilityChange: ((Bool) -> Void)?

    override init(frame frameRect: NSRect) {
        stopButton = NSButton(
            image: Theme.symbol("stop.fill", size: 10, weight: .semibold) ?? NSImage(), target: nil, action: nil)
        super.init(frame: frameRect)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        stopButton.isBordered = false
        stopButton.contentTintColor = .secondaryLabelColor
        stopButton.target = self
        stopButton.action = #selector(stopClicked)
        stopButton.setAccessibilityLabel(String(localized: "Stop"))
        keyBindingsChanged()
        NotificationCenter.default.addObserver(
            self, selector: #selector(keyBindingsChanged), name: KeyBindingsController.didChangeNotification, object: nil)
        let stack = NSStackView(views: [spinner, icon, label, stopButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.detachesHiddenViews = true
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.wantsLayer = true
        pill.layer?.cornerRadius = 14
        pill.layer?.cornerCurve = .continuous
        addSubview(pill)
        pill.addSubview(stack)
        let leading = pill.leadingAnchor.constraint(equalTo: leadingAnchor, constant: leadingGap)
        leadingConstraint = leading
        NSLayoutConstraint.activate([
            leading,
            pill.trailingAnchor.constraint(equalTo: trailingAnchor),
            pill.topAnchor.constraint(equalTo: topAnchor),
            pill.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: pill.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: pill.trailingAnchor),
            stack.topAnchor.constraint(equalTo: pill.topAnchor),
            stack.bottomAnchor.constraint(equalTo: pill.bottomAnchor),
            heightAnchor.constraint(equalToConstant: 28),
            spinner.widthAnchor.constraint(equalToConstant: 14),
            spinner.heightAnchor.constraint(equalToConstant: 14),
            icon.widthAnchor.constraint(equalToConstant: 14),
            icon.heightAnchor.constraint(equalToConstant: 14),
            stopButton.widthAnchor.constraint(equalToConstant: 24),
            stopButton.heightAnchor.constraint(equalToConstant: 24),
        ])
        wantsLayer = true
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        apply()
    }

    /// A flat pill in the theme, in place of the toolbar's glass.
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        pill.layer?.backgroundColor = Theme.raisedFill.cgColor
        pill.layer?.borderColor = Theme.surfaceBorder.cgColor
        pill.layer?.borderWidth = 1
    }

    /// NSToolbar needs an explicit preferred width. A plain NSView otherwise keeps the tiny width
    /// established while idle, clipping the label and stop button when work starts.
    override var intrinsicContentSize: NSSize {
        let widths: [CGFloat] = [spinner.isHidden ? nil : 14, icon.isHidden ? nil : 14,
            ceil(label.intrinsicContentSize.width), stopButton.isHidden ? nil : 24].compactMap { $0 }
        return NSSize(width: leadingGap + 20 + widths.reduce(0, +) + CGFloat(max(0, widths.count - 1)) * 6, height: 28)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The toolbar insets this view by its padding inside the item's container, and the item before it by as much, so
    /// the toolbar's spacing between the two is twice this view's origin there.
    override func layout() {
        super.layout()
        guard superview != nil else { return }
        let gap = max(0, Self.pillSpacing - 2 * max(0, frame.minX))
        guard gap != leadingGap else { return }
        leadingGap = gap
        leadingConstraint?.constant = gap
        invalidateIntrinsicContentSize()
    }

    /// The stop button's tooltip names Stop's shortcut, which the user can change.
    @objc private func keyBindingsChanged() {
        stopButton.toolTip = KeyBindingsController.shared.toolTip(String(localized: "Stop"), for: .stopTurn)
    }

    func update(_ state: State) {
        guard state != self.state else { return }
        let wasIdle = self.state == .idle
        self.state = state
        apply()
        if wasIdle != (state == .idle) { onVisibilityChange?(state != .idle) }
    }

    private func apply() {
        timer?.invalidate()
        timer = nil
        toolTip = nil
        switch state {
        case .idle:
            spinner.stopAnimation(nil)
            spinner.isHidden = true
            icon.isHidden = true
            stopButton.isHidden = true
            label.stringValue = ""
        case .starting:
            spinner.isHidden = false
            spinner.startAnimation(nil)
            icon.isHidden = true
            stopButton.isHidden = false
            label.textColor = .secondaryLabelColor
            label.stringValue = String(localized: "Connecting…")
        case .running(_, let note):
            spinner.isHidden = false
            spinner.startAnimation(nil)
            icon.isHidden = true
            stopButton.isHidden = false
            label.textColor = .secondaryLabelColor
            toolTip = note
            refreshElapsed()
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshElapsed() }
            }
        case .approval(let count):
            spinner.stopAnimation(nil)
            spinner.isHidden = true
            icon.image = Theme.symbol("exclamationmark.shield.fill", size: 13)
            icon.contentTintColor = .systemOrange
            icon.isHidden = false
            stopButton.isHidden = false
            label.textColor = .systemOrange
            label.stringValue = count > 1 ? String(localized: "\(count) approvals needed") : String(localized: "Needs approval")
        }
        invalidateIntrinsicContentSize()
        setAccessibilityLabel(label.stringValue)
    }

    private func refreshElapsed() {
        guard case .running(let since, let note) = state else { return }
        let previousWidth = ceil(label.intrinsicContentSize.width)
        label.stringValue = String(localized: "Working \(Formatting.elapsed(since: since))")
        if ceil(label.intrinsicContentSize.width) != previousWidth { invalidateIntrinsicContentSize() }
        setAccessibilityLabel(note.map { "\(label.stringValue), \($0)" } ?? label.stringValue)
    }

    @objc private func stopClicked() {
        onStop?()
    }
}
