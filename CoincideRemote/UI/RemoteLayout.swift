import CoreGraphics

/// Layout decisions that depend only on sizes, kept apart from the views so they can be tested on the Mac
/// (`CoincideTests/RemoteLayoutTests.swift` compiles this file too). Every decision reads the window's size class and
/// width, never the device: an iPad window in Split View, a Slide Over panel and a Duo folding or unfolding all land on
/// the same rules.
nonisolated enum RemoteLayout {
    /// The list column beside an open thread, as wide as the Mac's sidebar.
    static let listColumn: (minimum: CGFloat, ideal: CGFloat, maximum: CGFloat) = (300, 340, 400)
    /// The narrowest a thread reads well beside the list: a message, the approval buttons and the composer's controls.
    static let minimumThreadWidth: CGFloat = 420

    /// Whether the list and the open thread sit side by side: in a regular-width window with room for both (an iPad, a
    /// wide iPad window). The unfolded Duo (regular, but 669 points wide) and every compact window push the thread over
    /// the list instead, so neither column is squeezed.
    static func showsSideBySide(width: CGFloat, isRegular: Bool) -> Bool {
        isRegular && width >= listColumn.minimum + minimumThreadWidth
    }

    /// A control in the composer's footer: its width with its label, and its narrowest form (its symbol alone).
    struct Chip: Equatable {
        var full: CGFloat
        var compact: CGFloat
    }

    /// Where a menu goes: its line (0 is the line with send) and its frame within the footer.
    struct Placement: Equatable {
        var line: Int
        var frame: CGRect
        var isCompact: Bool
    }

    struct Footer: Equatable {
        var chips: [Placement]
        /// The pinned controls (steer or queue) and then the fixed ones (attach, send or stop), at the end of line 0.
        var pinned: [Placement]
        var fixed: CGRect
        var size: CGSize
    }

    /// Lays out the composer's footer as on the Mac: the menus (model, effort, speed, access, mode) from the leading
    /// edge, and at the trailing end the controls that must never scroll away or sit under a menu: steer or queue while
    /// the agent works (`pinned`), then attach and send or stop (`fixed`).
    ///
    /// When the menus don't all fit with their labels, the pinned controls show their symbols (send shows steer or queue
    /// too), then the menus drop to their symbols from the last one back; menus that still don't fit continue on another
    /// line (a narrow window at a large text size).
    static func footer(
        width: CGFloat, chips: [Chip], pinned: [Chip] = [], fixed: CGFloat, height: CGFloat, spacing: CGFloat = 2
    ) -> Footer {
        func total(_ widths: [CGFloat]) -> CGFloat {
            widths.reduce(0, +) + spacing * CGFloat(max(0, widths.count - 1))
        }
        func trailing(compact: Bool) -> CGFloat {
            fixed + pinned.reduce(0) { $0 + (compact ? $1.compact : $1.full) + spacing }
        }
        let compactPins = total(chips.map(\.full)) > width - trailing(compact: false) - spacing
        let trailingWidth = min(width, trailing(compact: compactPins))
        let firstLine = max(0, width - trailingWidth - spacing)

        // Labels for as many leading menus as fit, symbols for the rest.
        var compactFrom = chips.count
        while compactFrom > 0,
            total(chips.enumerated().map { $0.offset < compactFrom ? $0.element.full : $0.element.compact }) > firstLine
        {
            compactFrom -= 1
        }
        var placements: [Placement] = []
        var line = 0
        var x: CGFloat = 0
        for (index, chip) in chips.enumerated() {
            let isCompact = index >= compactFrom
            let chipWidth = isCompact ? chip.compact : chip.full
            let room = line == 0 ? firstLine : width
            if x + chipWidth > room, x > 0 || line == 0 {
                line += 1
                x = 0
            }
            placements.append(
                Placement(
                    line: line, frame: CGRect(x: x, y: CGFloat(line) * height, width: min(chipWidth, width), height: height),
                    isCompact: isCompact))
            x += chipWidth + spacing
        }

        var pins: [Placement] = []
        var pinX = width - trailingWidth
        for pin in pinned {
            let pinWidth = compactPins ? pin.compact : pin.full
            pins.append(Placement(line: 0, frame: CGRect(x: max(0, pinX), y: 0, width: pinWidth, height: height), isCompact: compactPins))
            pinX += pinWidth + spacing
        }
        let fixedFrame = CGRect(x: max(0, width - fixed), y: 0, width: min(fixed, width), height: height)
        return Footer(chips: placements, pinned: pins, fixed: fixedFrame, size: CGSize(width: width, height: CGFloat(line + 1) * height))
    }
}
