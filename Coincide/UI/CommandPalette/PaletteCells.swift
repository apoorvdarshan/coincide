import AppKit
import CoincideKit

/// A palette result: icon, title with the matched letters in bold, optional subtitle, and a
/// shortcut or age on the right.
final class PaletteItemCell: NSTableCellView {
    private let icon = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let subtitleField = NSTextField(labelWithString: "")
    private let trailingField = NSTextField(labelWithString: "")
    private var title = ""
    private var ranges: [NSRange] = []
    private var tint: NSColor?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        icon.imageScaling = .scaleProportionallyDown
        titleField.lineBreakMode = .byTruncatingTail
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        subtitleField.font = .systemFont(ofSize: 11)
        subtitleField.lineBreakMode = .byTruncatingTail
        subtitleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        trailingField.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        trailingField.alignment = .right
        trailingField.setContentCompressionResistancePriority(.required, for: .horizontal)
        trailingField.setContentHuggingPriority(.required, for: .horizontal)
        imageView = icon
        textField = titleField

        let text = NSStackView(views: [titleField, subtitleField])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        for view: NSView in [icon, text, trailingField] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 20),
            icon.heightAnchor.constraint(equalToConstant: 18),
            text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
            text.trailingAnchor.constraint(lessThanOrEqualTo: trailingField.leadingAnchor, constant: -12),
            trailingField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            trailingField.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ item: PaletteItem, ranges: [NSRange]) {
        title = item.title
        self.ranges = ranges
        tint = item.iconTint
        icon.image = item.icon
        subtitleField.stringValue = item.subtitle ?? ""
        subtitleField.isHidden = (item.subtitle ?? "").isEmpty
        trailingField.stringValue = item.trailing ?? ""
        var label = item.title
        if let subtitle = item.subtitle, !subtitle.isEmpty { label += ", " + subtitle }
        setAccessibilityLabel(label)
        applyColors()
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { applyColors() }
    }

    private func applyColors() {
        let selected = backgroundStyle == .emphasized
        let primary: NSColor = selected ? .alternateSelectedControlTextColor : .labelColor
        let secondary: NSColor = selected ? .alternateSelectedControlTextColor.withAlphaComponent(0.8) : .secondaryLabelColor
        let attributed = NSMutableAttributedString(
            string: title, attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: primary])
        let length = (title as NSString).length
        for range in ranges where NSMaxRange(range) <= length {
            attributed.addAttribute(.font, value: NSFont.systemFont(ofSize: 13, weight: .bold), range: range)
        }
        titleField.attributedStringValue = attributed
        subtitleField.textColor = secondary
        trailingField.textColor = selected ? secondary : .tertiaryLabelColor
        icon.contentTintColor = selected ? primary : (tint ?? .secondaryLabelColor)
    }
}

/// A group title such as "Actions" or "Recent Threads".
final class PaletteHeaderCell: NSTableCellView {
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        textField = label
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ title: String) {
        label.stringValue = title
        setAccessibilityLabel(title)
    }
}

/// Draws the highlighted result as a rounded accent capsule, always in its focused look,
/// because the search field keeps keyboard focus.
final class PaletteRowView: NSTableRowView {
    override var isEmphasized: Bool {
        get { true }
        set {}
    }

    override func drawSelection(in dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 6, dy: 1)
        NSColor.selectedContentBackgroundColor.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
    }
}

/// Selects the row under the pointer as it moves, as in T3's palette.
final class PaletteTableView: NSTableView {
    var onHover: ((Int) -> Void)?
    private var trackingArea: NSTrackingArea?
    private var lastMouseLocation: NSPoint?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        // Scrolling under a still pointer also sends moves; only follow real movement.
        let location = event.locationInWindow
        defer { lastMouseLocation = location }
        guard let last = lastMouseLocation, last != location else { return }
        let row = row(at: convert(location, from: nil))
        if row >= 0 { onHover?(row) }
    }
}
