import AppKit
import CoincideKit

/// A replacement pair shares a table row, so vertical scrolling and line heights cannot drift.
/// Both cells use the same horizontal text offset while their gutters stay at the visible edges.
final class DiffSplitLineView: DiffRowContentView {
    let before = DiffLineView(frame: .zero)
    let after = DiffLineView(frame: .zero)
    private let divider = NSBox()

    required init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        before.side = .before
        after.side = .after
        addSubview(before)
        addSubview(after)
        divider.boxType = .separator
        addSubview(divider)
    }

    func configure(
        pair: SplitDiffLine, lines: [DiffLine], file: Int, hunk: Int,
        presentation: DiffPresentation, metrics: DiffMetrics
    ) {
        for (view, index) in [(before, pair.before), (after, pair.after)] {
            let line = index.flatMap { lines.indices.contains($0) ? lines[$0] : nil }
            let key = index.map { DiffPresentation.LineKey(file: file, hunk: hunk, line: $0) }
            view.configure(line: line, highlight: key.flatMap { presentation.highlights[$0] }, metrics: metrics)
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let half = pinnedWidth / 2
        before.frame = NSRect(x: pinnedX, y: 0, width: half, height: bounds.height)
        after.frame = NSRect(x: pinnedX + half, y: 0, width: half, height: bounds.height)
        before.horizontalOffset = pinnedX
        after.horizontalOffset = pinnedX
        divider.frame = NSRect(x: pinnedX + half, y: 0, width: 1, height: bounds.height)
    }
}

/// Fixed headings identify the two sides even when a long diff is scrolled between hunks.
final class DiffSideLabels: NSView {
    private let before = NSTextField(labelWithString: String(localized: "Before Change"))
    private let after = NSTextField(labelWithString: String(localized: "After Change"))

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        clipsToBounds = true
        for label in [before, after] {
            label.font = .systemFont(ofSize: Theme.fontSize - 2, weight: .medium)
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
        }
        NSLayoutConstraint.activate([
            before.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            before.trailingAnchor.constraint(lessThanOrEqualTo: centerXAnchor, constant: -8),
            before.centerYAnchor.constraint(equalTo: centerYAnchor),
            after.leadingAnchor.constraint(equalTo: centerXAnchor, constant: 10),
            after.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            after.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        dirtyRect.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.midX, y: 0, width: 1, height: bounds.height).fill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }
}
