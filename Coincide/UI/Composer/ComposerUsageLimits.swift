import AppKit
import CoincideKit

/// The selected agent's subscription limits in the composer footer, ported from T3 Code's usage limits: one thin
/// bar per window (session over weekly) showing what is left. Clicking it lists every window with its reset time.
final class ComposerUsageMeter: NSButton {
    private var provider: ProviderKind = .claude
    private var limits: UsageLimits?
    private var bars: [CALayer] = []
    private var tracks: [CALayer] = []
    private weak var details: ThemedPopupViewHost?

    /// Windows drawn in the footer: the two most important.
    private var shownWindows: [UsageLimitWindow] { Array(limits?.windows.prefix(2) ?? []) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        title = ""
        wantsLayer = true
        target = self
        action = #selector(showDetails)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize { NSSize(width: 30, height: 26) }

    func update(provider: ProviderKind, limits: UsageLimits) {
        self.provider = provider
        self.limits = limits
        let now = Date()
        let summary = String(localized: "\(provider.displayName) usage limits. \(limits.summary(at: now))")
        toolTip = summary
        setAccessibilityLabel(summary)
        rebuildLayers()
        details?.setContent(ComposerUsageDetails.view(provider: provider, limits: limits, now: now))
    }

    /// Opens the list of windows, as `/usage-limits` does.
    @objc func showDetails() {
        guard let limits, window != nil else { return }
        let details = ThemedPopupViewHost(ComposerUsageDetails.view(provider: provider, limits: limits, now: Date()))
        ThemedPopup.show(details, from: self)
        self.details = details
    }

    private func rebuildLayers() {
        for layer in bars + tracks { layer.removeFromSuperlayer() }
        bars = []
        tracks = []
        for _ in shownWindows {
            let track = CALayer()
            let bar = CALayer()
            for shape in [track, bar] {
                shape.cornerRadius = 1.5
                layer?.addSublayer(shape)
            }
            tracks.append(track)
            bars.append(bar)
        }
        needsLayout = true
        updateColors()
    }

    override func layout() {
        super.layout()
        let windows = shownWindows
        let height: CGFloat = 3
        let gap: CGFloat = 3
        let total = CGFloat(windows.count) * height + CGFloat(max(windows.count - 1, 0)) * gap
        let width = bounds.width - 6
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Session above weekly, whichever way the view's y axis points.
        for (index, window) in windows.enumerated() where index < bars.count {
            let offset = CGFloat(index) * (height + gap)
            let y = isFlipped ? (bounds.height - total) / 2 + offset : (bounds.height + total) / 2 - height - offset
            tracks[index].frame = CGRect(x: 3, y: y, width: width, height: height)
            bars[index].frame = CGRect(x: 3, y: y, width: max(0, width * CGFloat(window.remainingPercent) / 100), height: height)
        }
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        let windows = shownWindows
        effectiveAppearance.performAsCurrentDrawingAppearance {
            for (index, window) in windows.enumerated() where index < bars.count {
                tracks[index].backgroundColor = NSColor.tertiaryLabelColor.withAlphaComponent(0.35).cgColor
                bars[index].backgroundColor = ComposerUsageDetails.color(for: window, provider: provider).cgColor
            }
        }
    }
}

/// The popup listing a provider's usage windows.
enum ComposerUsageDetails {
    static func color(for window: UsageLimitWindow, provider: ProviderKind) -> NSColor {
        if window.isExhausted || window.usedPercent >= 95 { return .systemRed }
        if window.isNearLimit { return .systemOrange }
        return Theme.color(for: provider)
    }

    static func view(provider: ProviderKind, limits: UsageLimits, now: Date) -> NSView {
        let title = NSTextField(labelWithString: String(localized: "\(provider.displayName) usage limits"))
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        let checked = NSTextField(
            labelWithString: String(
                localized: "Updated \(limits.checkedAt.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))"))
        checked.font = .systemFont(ofSize: 11)
        checked.textColor = .tertiaryLabelColor
        let header = NSStackView(views: [title, NSView(), checked])
        header.orientation = .horizontal
        var rows: [NSView] = [header]
        for window in limits.windows { rows.append(row(window, provider: provider, now: now)) }
        if limits.windows.isEmpty {
            rows.append(note(String(localized: "No limits reported.")))
        }
        if let warning = limits.warning {
            let text = note(UsageLimits.warningText(for: warning, provider: provider, at: now))
            text.textColor = warning.blocksWork ? .systemRed : .systemOrange
            rows.append(text)
        }
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        for row in rows { row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true }
        stack.widthAnchor.constraint(equalToConstant: 290).isActive = true
        return stack
    }

    private static func row(_ window: UsageLimitWindow, provider: ProviderKind, now: Date) -> NSView {
        let name = NSTextField(labelWithString: window.label)
        name.font = .systemFont(ofSize: 11)
        name.textColor = .secondaryLabelColor
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let left = NSTextField(labelWithString: String(localized: "\(window.remainingPercent)% left"))
        left.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        let top = NSStackView(views: [name, NSView(), left])
        top.orientation = .horizontal

        let bar = UsageLimitBar(window: window, color: color(for: window, provider: provider), now: now)

        var details: [String] = []
        if let resetsAt = window.resetsAt, let reset = window.resetDescription(at: now) {
            let time = resetsAt.formatted(
                date: Calendar.current.isDate(resetsAt, inSameDayAs: now) ? .omitted : .abbreviated, time: .shortened)
            details.append(String(localized: "Resets \(time)"))
            details.append(reset)
        }
        switch window.pace(at: now) {
        case .ahead?: details.append(String(localized: "Ahead of pace"))
        case .onPace?: details.append(String(localized: "On pace"))
        case .under?: details.append(String(localized: "Under pace"))
        case nil: break
        }
        var views: [NSView] = [top, bar]
        if !details.isEmpty { views.append(note(details.joined(separator: " · "))) }
        let column = NSStackView(views: views)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 4
        for view in views { view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
        column.setAccessibilityElement(true)
        column.setAccessibilityRole(.group)
        column.setAccessibilityLabel(
            ([String(localized: "\(window.label): \(window.remainingPercent)% left")] + details).joined(separator: ", "))
        if window.pace(at: now) != nil {
            column.toolTip = String(localized: "The mark shows where even spending across the window would be.")
        }
        return column
    }

    private static func note(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .tertiaryLabelColor
        return label
    }
}

/// A window's bar: what is left, with a mark where even spending would be (T3's pace tick).
final class UsageLimitBar: NSView {
    private let remaining: CGFloat
    /// Share of the window still to come, the even-spending mark; nil without a known window length.
    private let timeLeft: CGFloat?
    private let color: NSColor

    init(window: UsageLimitWindow, color: NSColor, now: Date) {
        remaining = CGFloat(window.remainingPercent) / 100
        timeLeft = window.elapsedShare(at: now).map { CGFloat(1 - $0) }
        self.color = color
        super.init(frame: .zero)
        heightAnchor.constraint(equalToConstant: 8).isActive = true
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        let track = NSRect(x: 0, y: (bounds.height - 5) / 2, width: bounds.width, height: 5)
        NSColor.tertiaryLabelColor.withAlphaComponent(0.3).setFill()
        NSBezierPath(roundedRect: track, xRadius: 2.5, yRadius: 2.5).fill()
        if remaining > 0 {
            color.setFill()
            var fill = track
            fill.size.width = max(track.height, track.width * remaining)
            NSBezierPath(roundedRect: fill, xRadius: 2.5, yRadius: 2.5).fill()
        }
        if let timeLeft {
            let x = min(max(1.5, bounds.width * timeLeft), bounds.width - 1.5)
            NSColor.labelColor.setFill()
            NSBezierPath(roundedRect: NSRect(x: x - 1, y: 0, width: 2, height: bounds.height), xRadius: 1, yRadius: 1).fill()
        }
    }
}

/// Warns when the selected agent's plan is near or at one of its limits, with when it resets.
final class ComposerUsageBanner: ComposerBanner {
    /// What the banner offers for a thread its agent stopped working on at the limit (T3 Code's "Resume at reset").
    enum ResumeOffer: Equatable {
        case available
        case scheduled(Date)
    }

    var onDismiss: (() -> Void)?
    var onShowDetails: (() -> Void)?
    var onToggleResume: (() -> Void)?

    private let resumeButton = ThemedButton(title: "", style: .secondary, target: nil, action: nil)

    private let iconView = ComposerBanner.icon("gauge.with.needle", color: .systemOrange)
    private let message = NSTextField(wrappingLabelWithString: "")

    init() {
        super.init(tint: Theme.approvalTint)
        message.font = .systemFont(ofSize: 12)
        message.maximumNumberOfLines = 2
        message.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let details = ThemedButton(title: String(localized: "Details"), target: self, action: #selector(showDetails))
        details.bezelStyle = .push
        details.controlSize = .small
        details.setContentCompressionResistancePriority(.required, for: .horizontal)
        let dismiss = NSButton(
            image: NSImage(systemSymbolName: "xmark", accessibilityDescription: String(localized: "Dismiss")) ?? NSImage(),
            target: self, action: #selector(dismiss))
        dismiss.isBordered = false
        dismiss.contentTintColor = .secondaryLabelColor
        dismiss.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        dismiss.toolTip = String(localized: "Dismiss")
        dismiss.setContentCompressionResistancePriority(.required, for: .horizontal)
        resumeButton.target = self
        resumeButton.action = #selector(toggleResume)
        resumeButton.controlSize = .small
        resumeButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        content.alignment = .centerY
        for view in [iconView, message, resumeButton, details, dismiss] as [NSView] { content.addArrangedSubview(view) }
    }

    func show(_ window: UsageLimitWindow, provider: ProviderKind, now: Date, resume: ResumeOffer? = nil) {
        iconView.contentTintColor = window.blocksWork ? .systemRed : .systemOrange
        var text = UsageLimits.warningText(for: window, provider: provider, at: now)
        switch resume {
        case .available?:
            resumeButton.title = String(localized: "Resume at Reset")
            resumeButton.toolTip = String(localized: "Continue this thread on its own once the limit resets.")
        case .scheduled(let date)?:
            resumeButton.title = String(localized: "Cancel Auto-Resume")
            resumeButton.toolTip = nil
            text += " " + String(localized: "This thread continues at \(date.formatted(date: .omitted, time: .shortened)).")
        case nil:
            break
        }
        resumeButton.isHidden = resume == nil
        message.stringValue = text
        setAccessibilityLabel(message.stringValue)
    }

    @objc private func toggleResume() { onToggleResume?() }

    @objc private func showDetails() { onShowDetails?() }

    @objc private func dismiss() { onDismiss?() }
}
