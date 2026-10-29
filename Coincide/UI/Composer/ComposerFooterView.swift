import AppKit

/// The composer's bottom row: agent and model, effort, speed, access, what sending does while the agent works
/// (Queue, Steer or Interrupt) and Build/Plan on the leading side;
/// attach, the usage and context meters and send/stop on the trailing side. Labels collapse to symbols,
/// least important first, when the composer is too narrow for them.
final class ComposerFooterView: NSView {
    let modelButton = ComposerControlButton()
    let effortButton = ComposerControlButton()
    let speedButton = ComposerControlButton()
    let accessButton = ComposerControlButton()
    let followUpButton = ComposerControlButton()
    let modeButton = ComposerControlButton()
    let attachButton = ComposerControlButton()
    let usageMeter = ComposerUsageMeter()
    let contextMeter = ComposerContextMeter()
    let stopButton = ComposerSendButton()
    let sendButton = ComposerSendButton()
    let implementButton = ThemedButton(title: String(localized: "Implement"), style: .primary, target: nil, action: nil)

    private let leadingControls = NSStackView()
    private let trailingControls = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        leadingControls.orientation = .horizontal
        leadingControls.spacing = 2
        trailingControls.orientation = .horizontal
        trailingControls.spacing = 6
        for view in [modelButton, effortButton, speedButton, accessButton, followUpButton, modeButton] {
            leadingControls.addArrangedSubview(view)
        }
        for view in [attachButton, usageMeter, contextMeter, stopButton, implementButton, sendButton] {
            trailingControls.addArrangedSubview(view)
        }
        trailingControls.setCustomSpacing(2, after: attachButton)
        trailingControls.setCustomSpacing(2, after: usageMeter)
        usageMeter.isHidden = true

        modelButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        (modelButton.cell as? NSButtonCell)?.lineBreakMode = .byTruncatingTail
        stopButton.mode = .stop
        stopButton.isHidden = true
        implementButton.bezelStyle = .push
        implementButton.controlSize = .small
        implementButton.borderShape = .capsule
        implementButton.tintProminence = .primary
        implementButton.isHidden = true
        attachButton.configure(title: "", symbolName: "paperclip", chevron: false)
        attachButton.toolTip = String(localized: "Attach images or files")
        attachButton.setAccessibilityLabel(String(localized: "Attach images or files"))

        for stack in [leadingControls, trailingControls] {
            stack.translatesAutoresizingMaskIntoConstraints = false
            addSubview(stack)
        }
        leadingControls.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        trailingControls.setContentCompressionResistancePriority(.required, for: .horizontal)
        trailingControls.setContentHuggingPriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 30),
            leadingControls.leadingAnchor.constraint(equalTo: leadingAnchor),
            leadingControls.centerYAnchor.constraint(equalTo: centerYAnchor),
            trailingControls.trailingAnchor.constraint(equalTo: trailingAnchor),
            trailingControls.centerYAnchor.constraint(equalTo: centerYAnchor),
            leadingControls.trailingAnchor.constraint(lessThanOrEqualTo: trailingControls.leadingAnchor, constant: -8),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        compactLabelsToFit()
        super.layout()
    }

    /// Collapses Build/Plan, then the follow-up behavior, then access, then speed, then effort, then the model name to
    /// their symbols until the controls fit.
    private func compactLabelsToFit() {
        let available = bounds.width - trailingControls.fittingSize.width - 8
        let buttons = [modelButton, effortButton, speedButton, accessButton, followUpButton, modeButton].filter { !$0.isHidden }
        var width = buttons.reduce(0) { $0 + $1.width(compact: false) } + CGFloat(max(buttons.count - 1, 0)) * leadingControls.spacing
        var compacted = Set<ObjectIdentifier>()
        for button in [modeButton, followUpButton, accessButton, speedButton, effortButton, modelButton] where !button.isHidden {
            if width <= available { break }
            width -= button.width(compact: false) - button.width(compact: true)
            compacted.insert(ObjectIdentifier(button))
        }
        for button in buttons { button.isCompact = compacted.contains(ObjectIdentifier(button)) }
    }
}
