import AppKit
import CoincideKit

// MARK: - Fork divider

/// T3's fork divider: a hairline with a capsule in the middle naming the related thread, which opens it.
/// In a fork it follows the copied history ("Forked from conversation"); in the thread it was forked from,
/// it follows the turn the fork copied through ("Conversation fork").
final class TranscriptForkCell: TranscriptCell {
    private static let pillHeight: CGFloat = 22

    private let pill = TranscriptForkPill()
    private var marker: TranscriptForkMarker?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        pill.target = self
        pill.action = #selector(open)
        pill.onHoverChange = { [weak self] in self?.needsDisplay = true }
        addSubview(pill)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func configure(_ row: TranscriptRow, host: TranscriptHost) {
        super.configure(row, host: host)
        guard case .fork(let marker) = row.kind else { return }
        self.marker = marker
        let label = Self.label(marker)
        pill.configure(label: label, detail: marker.title, isEnabled: marker.isAvailable)
        let action = Self.actionLabel(marker)
        pill.toolTip = marker.isAvailable ? action : String(localized: "This thread is no longer available")
        pill.setAccessibilityLabel("\(label), \(marker.title)")
        pill.setAccessibilityHelp(marker.isAvailable ? action : nil)
        needsLayout = true
        needsDisplay = true
    }

    static func label(_ marker: TranscriptForkMarker) -> String {
        switch marker.direction {
        case .forkedFrom: String(localized: "Forked from conversation")
        case .forkedTo: String(localized: "Conversation fork")
        }
    }

    static func actionLabel(_ marker: TranscriptForkMarker) -> String {
        switch marker.direction {
        case .forkedFrom: String(localized: "Open source conversation")
        case .forkedTo: String(localized: "Open fork")
        }
    }

    override class func height(for row: TranscriptRow, width: CGFloat, host: TranscriptHost) -> CGFloat {
        pillHeight + 4 + TranscriptMetrics.messageSpacing - 4
    }

    override var copyText: String? {
        marker.map { "\(Self.label($0)) · \($0.title)" }
    }

    override func layout() {
        super.layout()
        let column = TranscriptMetrics.column(width: bounds.width)
        pill.sizeToFit()
        let width = min(max(0, column.width - 80), ceil(pill.frame.width) + 20)
        pill.frame = NSRect(x: column.x + (column.width - width) / 2, y: 2, width: width, height: Self.pillHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        let column = TranscriptMetrics.column(width: bounds.width)
        let frame = pill.frame
        NSColor.separatorColor.setFill()
        let y = frame.midY.rounded(.down)
        NSRect(x: column.x, y: y, width: max(0, frame.minX - 8 - column.x), height: 1).fill()
        let right = frame.maxX + 8
        NSRect(x: right, y: y, width: max(0, column.x + column.width - right), height: 1).fill()
        // Only a divider that opens its thread looks like a button, as in T3.
        guard marker?.isAvailable == true else { return }
        let capsule = NSBezierPath(roundedRect: frame.insetBy(dx: 0.5, dy: 0.5), xRadius: frame.height / 2, yRadius: frame.height / 2)
        if pill.isHovered {
            NSColor.labelColor.withAlphaComponent(0.06).setFill()
            capsule.fill()
        }
        NSColor.separatorColor.setStroke()
        capsule.lineWidth = 1
        capsule.stroke()
    }

    @objc private func open() {
        guard let marker, marker.isAvailable else { return }
        host?.openThread(marker.threadID)
    }
}

/// The divider's capsule: a borderless button with the fork symbol, the label and the related thread's title
/// (dimmed after a dot, truncated when long). The cell draws its outline and hover state.
final class TranscriptForkPill: NSButton {
    var onHoverChange: (() -> Void)?
    private(set) var isHovered = false {
        didSet { if isHovered != oldValue { onHoverChange?() } }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        bezelStyle = .accessoryBarAction
        imagePosition = .imageLeading
        imageHugsTitle = true
        image = Theme.symbol("arrow.triangle.branch", size: 10, weight: .medium)
        contentTintColor = .secondaryLabelColor
        (cell as? NSButtonCell)?.lineBreakMode = .byTruncatingTail
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(label: String, detail: String, isEnabled: Bool) {
        let size = Theme.fontSize - 2
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        paragraph.alignment = .center
        let title = NSMutableAttributedString(
            string: label,
            attributes: [
                .font: NSFont.systemFont(ofSize: size, weight: .medium), .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: paragraph,
            ])
        if !detail.isEmpty {
            title.append(
                NSAttributedString(
                    string: " · \(detail)",
                    attributes: [
                        .font: NSFont.systemFont(ofSize: size), .foregroundColor: NSColor.tertiaryLabelColor,
                        .paragraphStyle: paragraph,
                    ]))
        }
        attributedTitle = title
        self.isEnabled = isEnabled
        if !isEnabled { isHovered = false }
        window?.invalidateCursorRects(for: self)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = isEnabled
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
    }

    override func resetCursorRects() {
        if isEnabled { addCursorRect(bounds, cursor: .pointingHand) }
    }
}
