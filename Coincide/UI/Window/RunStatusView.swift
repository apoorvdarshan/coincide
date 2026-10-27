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
        stopButton.isBordered = false
        stopButton.contentTintColor = .secondaryLabelColor
        stopButton.target = self
        stopButton.action = #selector(stopClicked)
        stopButton.toolTip = String(localized: "Stop (⌘.)")
        stopButton.setAccessibilityLabel(String(localized: "Stop"))
        let stack = NSStackView(views: [spinner, icon, label, stopButton])
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 28),
            spinner.widthAnchor.constraint(equalToConstant: 14),
            spinner.heightAnchor.constraint(equalToConstant: 14),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

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
            icon.isHidden = true
            stopButton.isHidden = true
            label.stringValue = ""
        case .starting:
            spinner.startAnimation(nil)
            icon.isHidden = true
            stopButton.isHidden = false
            label.textColor = .secondaryLabelColor
            label.stringValue = String(localized: "Connecting…")
        case .running(_, let note):
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
            icon.image = Theme.symbol("exclamationmark.shield.fill", size: 13)
            icon.contentTintColor = .systemOrange
            icon.isHidden = false
            stopButton.isHidden = false
            label.textColor = .systemOrange
            label.stringValue = count > 1 ? String(localized: "\(count) approvals needed") : String(localized: "Needs approval")
        }
        setAccessibilityLabel(label.stringValue)
    }

    private func refreshElapsed() {
        guard case .running(let since, let note) = state else { return }
        label.stringValue = String(localized: "Working \(Formatting.elapsed(since: since))")
        setAccessibilityLabel(note.map { "\(label.stringValue), \($0)" } ?? label.stringValue)
    }

    @objc private func stopClicked() {
        onStop?()
    }
}
