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

    /// How many threads a project lists before "Show more", nil for all, from the Mac's "Threads per Project": nil fits
    /// the list to the window (`fitting` on the phone), 0 shows all, any other count is kept.
    static func threadLimit(threadsPerProject: Int?, fitting: Int) -> Int? {
        switch threadsPerProject {
        case nil: fitting
        case let count? where count <= 0: nil
        case let count?: count
        }
    }

    /// The tallest a picture in the transcript gets, so a screenshot never takes over the screen.
    static let pictureMaximumHeight: CGFloat = 240
    /// The shapes a lone picture keeps, width over height; a panorama or a long screenshot is cropped to these.
    static let pictureAspects: ClosedRange<CGFloat> = 0.5...2.4
    /// The widest tile when several pictures share a message, as the Mac's message thumbnails (104 points there).
    static let pictureTileMaximumWidth: CGFloat = 160
    static let pictureSpacing: CGFloat = 8

    struct PictureGrid: Equatable {
        var frames: [CGRect]
        var size: CGSize
    }

    /// Lays out a message's pictures within `width`, the room their message has (inside the user's bubble, or the
    /// reply's column). One picture keeps its shape, as large as fits under `maxHeight`. Several sit two to a row in 4:3
    /// tiles, as the Mac lays out a message's thumbnails. `aspects` are each picture's width over its height, nil while
    /// it loads (drawn 4:3 until then).
    static func pictureGrid(
        aspects: [CGFloat?], width: CGFloat, maxHeight: CGFloat = pictureMaximumHeight, spacing: CGFloat = pictureSpacing
    ) -> PictureGrid {
        let width = max(0, width.isFinite ? width : 0)
        guard !aspects.isEmpty, width > 0 else { return PictureGrid(frames: aspects.map { _ in .zero }, size: .zero) }
        if aspects.count == 1 {
            let raw = aspects[0].flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 4 / 3
            let aspect = min(max(raw, pictureAspects.lowerBound), pictureAspects.upperBound)
            // As wide as the message when that keeps it under the cap; otherwise as tall as the cap allows.
            let size =
                width / aspect <= maxHeight
                ? CGSize(width: width, height: min(maxHeight, (width / aspect).rounded()))
                : CGSize(width: min(width, (maxHeight * aspect).rounded(.down)), height: maxHeight)
            return PictureGrid(frames: [CGRect(origin: .zero, size: size)], size: size)
        }
        let tile = max(0, min(pictureTileMaximumWidth, ((width - spacing) / 2).rounded(.down)))
        let tileHeight = (tile * 0.75).rounded()
        let frames = aspects.indices.map { index in
            CGRect(
                x: CGFloat(index % 2) * (tile + spacing), y: CGFloat(index / 2) * (tileHeight + spacing), width: tile,
                height: tileHeight)
        }
        let rows = CGFloat((aspects.count + 1) / 2)
        return PictureGrid(frames: frames, size: CGSize(width: tile * 2 + spacing, height: rows * tileHeight + (rows - 1) * spacing))
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

    /// The narrowest footer that keeps every control on one line: each menu and pinned control as its symbol, and the
    /// fixed controls at their size.
    static func footerMinimumWidth(chips: [Chip], pinned: [Chip] = [], fixed: CGFloat, spacing: CGFloat = 2) -> CGFloat {
        let menus = chips.reduce(0) { $0 + $1.compact } + spacing * CGFloat(max(0, chips.count - 1))
        let trailing = fixed + pinned.reduce(0) { $0 + $1.compact + spacing }
        return menus + (chips.isEmpty ? 0 : spacing) + trailing
    }

    /// Lays out the composer's footer as on the Mac: the menus (model, effort, speed, access, mode) from the leading
    /// edge, and at the trailing end the controls that must never scroll away or sit under a menu: steer or queue while
    /// the agent works (`pinned`), then attach and send or stop (`fixed`).
    ///
    /// When the menus don't all fit with their labels, the pinned controls show their symbols (send shows steer or queue
    /// too), then the menus drop to their symbols from the last one back; menus that still don't fit continue on another
    /// line (a narrow window at a large text size).
    ///
    /// `inset` is room kept before the first menu, so its symbol lines up with the message above it; the menus give it up
    /// when that's what keeps them all on one line.
    static func footer(
        width: CGFloat, chips: [Chip], pinned: [Chip] = [], fixed: CGFloat, height: CGFloat, spacing: CGFloat = 2,
        inset: CGFloat = 0
    ) -> Footer {
        func total(_ widths: [CGFloat]) -> CGFloat {
            widths.reduce(0, +) + spacing * CGFloat(max(0, widths.count - 1))
        }
        func trailing(compact: Bool) -> CGFloat {
            fixed + pinned.reduce(0) { $0 + (compact ? $1.compact : $1.full) + spacing }
        }
        let lead =
            inset > 0 && footerMinimumWidth(chips: chips, pinned: pinned, fixed: fixed, spacing: spacing) + inset <= width
            ? inset : 0
        let compactPins = total(chips.map(\.full)) > width - lead - trailing(compact: false) - spacing
        let trailingWidth = min(width, trailing(compact: compactPins))
        let firstLine = max(0, width - lead - trailingWidth - spacing)

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
            let room = line == 0 ? firstLine : width - lead
            if x + chipWidth > room, x > 0 || line == 0 {
                line += 1
                x = 0
            }
            placements.append(
                Placement(
                    line: line,
                    frame: CGRect(x: lead + x, y: CGFloat(line) * height, width: min(chipWidth, width - lead), height: height),
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
