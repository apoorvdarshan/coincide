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
        let open = PickerTextButton(title: String(localized: "Open Usage"), symbol: "chart.bar") {
            UsageNavigation.show(provider: provider)
        }
        open.toolTip = String(localized: "Tokens, costs and every account’s limits in Settings › Usage")
        rows.append(open)
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

/// Warns when the selected agent's plan is near or at one of its limits, with when it resets. It sits on the same quiet
/// surface as the composer's other banners: only the gauge and a thin bar of how much of the window is used (or left)
/// carry the warning color. The message keeps to one line and cuts long text short with an ellipsis (its tooltip and
/// accessibility label have all of it); the actions are grouped at the trailing edge with the dismiss button last.
///
/// The views are placed with their own constraints rather than a stack, so nothing can be stretched to fill the row: the
/// old stack could widen the dismiss button instead of the message, drawing its × in the middle of the banner. Where
/// the resume offer's title would leave the message narrower than `minimumMessageWidth`, the offer shows as a symbol.
final class ComposerUsageBanner: ComposerBanner {
    /// What the banner offers for a thread its agent stopped working on at the limit (T3 Code's "Resume at reset").
    enum ResumeOffer: Equatable {
        case available
        case scheduled(Date)
    }

    var onDismiss: (() -> Void)?
    var onShowDetails: (() -> Void)?
    var onToggleResume: (() -> Void)?

    /// The message gets at least this much room before the resume offer gives up its title for a symbol.
    static let minimumMessageWidth: CGFloat = 120
    /// The bar under the message stops at this width on a wide composer, so it reads as a meter rather than a rule.
    static let maximumMeterWidth: CGFloat = 240

    let message = ComposerBanner.label()
    let meter = ThemedProgressBar(fraction: 0, color: Theme.warning)
    let resumeButton = ComposerBannerButton(title: "")
    let detailsButton = ComposerBannerButton(title: String(localized: "Details"))
    let dismissButton = ComposerBannerButton(symbol: "xmark", label: String(localized: "Dismiss"))

    private let body = NSView()
    private let iconView = ComposerBanner.icon("gauge.with.needle", color: Theme.warning)
    private let actions = NSStackView()
    /// The resume offer's own tooltip, if it has one; while it shows as a symbol, its title stands in.
    private var resumeToolTip: String?

    /// Insets of the banner's contents, and the gaps between them.
    private enum Metrics {
        static let top: CGFloat = 9
        static let bottom: CGFloat = 9
        static let leading: CGFloat = 12
        static let trailing: CGFloat = 6
        static let iconGap: CGFloat = 9
        static let meterGap: CGFloat = 5
        static let meterHeight: CGFloat = 3
        /// Between the message and the first action.
        static let actionsGap: CGFloat = 8
        /// Between the actions, and between the last one and the ×: their padding already spaces their titles.
        static let buttonGap: CGFloat = 2
        static let iconWidth: CGFloat = 16
    }

    init() {
        super.init(tint: Theme.questionTint)
        message.textColor = Theme.ink
        message.maximumNumberOfLines = 1
        message.usesSingleLineMode = true
        message.cell?.truncatesLastVisibleLine = true
        message.setContentHuggingPriority(.defaultLow, for: .horizontal)

        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = Metrics.buttonGap
        actions.detachesHiddenViews = true
        actions.setHuggingPriority(.required, for: .horizontal)
        actions.setHuggingPriority(.required, for: .vertical)

        resumeButton.target = self
        resumeButton.action = #selector(toggleResume)
        resumeButton.isHidden = true
        detailsButton.target = self
        detailsButton.action = #selector(showDetails)
        detailsButton.toolTip = String(localized: "Show every usage limit and when it resets")
        dismissButton.target = self
        dismissButton.action = #selector(dismiss)
        dismissButton.toolTip = String(localized: "Dismiss")
        for view in [resumeButton, detailsButton] { actions.addArrangedSubview(view) }

        for view in [iconView, message, meter, actions, dismissButton] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            body.addSubview(view)
        }
        content.edgeInsets = NSEdgeInsetsZero
        content.addArrangedSubview(body)

        let meterWidth = meter.widthAnchor.constraint(equalToConstant: Self.maximumMeterWidth)
        meterWidth.priority = .init(200)
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: Metrics.leading),
            iconView.widthAnchor.constraint(equalToConstant: Metrics.iconWidth),
            iconView.centerYAnchor.constraint(equalTo: message.centerYAnchor),
            message.topAnchor.constraint(equalTo: body.topAnchor, constant: Metrics.top),
            message.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: Metrics.iconGap),
            message.trailingAnchor.constraint(equalTo: actions.leadingAnchor, constant: -Metrics.actionsGap),
            // On a banner too narrow for everything, the action titles get cut short before the message turns inside out.
            message.widthAnchor.constraint(greaterThanOrEqualToConstant: 0),
            meter.topAnchor.constraint(equalTo: message.bottomAnchor, constant: Metrics.meterGap),
            meter.leadingAnchor.constraint(equalTo: message.leadingAnchor),
            meter.heightAnchor.constraint(equalToConstant: Metrics.meterHeight),
            meter.widthAnchor.constraint(lessThanOrEqualToConstant: Self.maximumMeterWidth),
            meter.widthAnchor.constraint(lessThanOrEqualTo: message.widthAnchor),
            meterWidth,
            body.bottomAnchor.constraint(equalTo: meter.bottomAnchor, constant: Metrics.bottom),
            // The actions and the × line up on the message, whatever the bar under it adds.
            actions.trailingAnchor.constraint(equalTo: dismissButton.leadingAnchor, constant: -Metrics.buttonGap),
            actions.centerYAnchor.constraint(equalTo: message.centerYAnchor),
            dismissButton.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -Metrics.trailing),
            dismissButton.centerYAnchor.constraint(equalTo: message.centerYAnchor),
            dismissButton.widthAnchor.constraint(equalToConstant: ComposerBannerButton.height),
            dismissButton.heightAnchor.constraint(equalToConstant: ComposerBannerButton.height),
            dismissButton.topAnchor.constraint(greaterThanOrEqualTo: body.topAnchor, constant: 2),
        ])
    }

    func show(
        _ window: UsageLimitWindow, provider: ProviderKind, mode: UsageDisplayMode = .used, now: Date,
        resume: ResumeOffer? = nil
    ) {
        let color = ComposerUsageDetails.color(for: window, provider: provider)
        iconView.contentTintColor = color
        meter.color = color
        meter.fraction = CGFloat(window.barFill(mode))
        meter.setAccessibilityLabel(window.label)
        meter.setAccessibilityValueDescription(UsageFormat.shown(window, mode: mode))
        var text = UsageLimits.warningText(for: window, provider: provider, mode: mode, at: now)
        switch resume {
        case .available?:
            resumeButton.title = String(localized: "Resume at Reset")
            resumeButton.compactSymbol = "clock.arrow.circlepath"
            resumeToolTip = String(localized: "Continue this thread on its own once the limit resets.")
        case .scheduled(let date)?:
            resumeButton.title = String(localized: "Cancel Auto-Resume")
            resumeButton.compactSymbol = "clock.badge.xmark"
            resumeToolTip = nil
            text += " " + String(localized: "This thread continues at \(date.formatted(date: .omitted, time: .shortened)).")
        case nil:
            break
        }
        resumeButton.isHidden = resume == nil
        message.stringValue = text
        // The whole text, for when one line cuts it short.
        message.toolTip = text
        setAccessibilityLabel(text)
        needsLayout = true
    }

    /// Whether the resume offer shows as a symbol at `width`: with its title, the message would get narrower than
    /// `minimumMessageWidth`.
    func needsCompactResume(width: CGFloat) -> Bool {
        guard !resumeButton.isHidden else { return false }
        let leading = Metrics.leading + Metrics.iconWidth + Metrics.iconGap + Metrics.actionsGap
        let trailing = resumeButton.titledWidth + Metrics.buttonGap + detailsButton.titledWidth + Metrics.buttonGap
            + ComposerBannerButton.height + Metrics.trailing
        return width - leading - trailing < Self.minimumMessageWidth
    }

    override func layout() {
        resumeButton.isCompact = needsCompactResume(width: bounds.width)
        resumeButton.toolTip = resumeToolTip ?? (resumeButton.isCompact ? resumeButton.title : nil)
        super.layout()
    }

    @objc private func toggleResume() { onToggleResume?() }

    @objc private func showDetails() { onShowDetails?() }

    @objc private func dismiss() { onDismiss?() }
}
