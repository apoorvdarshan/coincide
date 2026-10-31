import AppKit
import CoincideKit

/// The bot editor's Personality section: a chip for no personality, one for each preset and one for Custom; under
/// them the chosen preset's description and a sample greeting in its voice (written, not generated), or for Custom the
/// user's own description, which can start from a preset's text. Lays its chips out in rows that fit `width`.
final class BotPersonalitySection: NSStackView, NSTextViewDelegate {
    /// What the chips choose between.
    enum Choice: Hashable {
        case none
        case preset(String)
        case custom
    }

    /// Called whenever the personality changes.
    var onChange: (() -> Void)?
    /// The personality as chosen, with the description the user wrote; nil for none. Empty while Custom has no text
    /// yet (`result` reads that as none).
    private(set) var personality: BotPersonality?
    /// Whether the user picked a personality here. Until then a new character brings its own (`suggest`).
    private(set) var userPicked = false
    private(set) var chips: [PersonalityChip] = []
    let customText = PlaceholderTextView()
    let summary = NSTextField(wrappingLabelWithString: "")
    private let greeting = NSTextField(wrappingLabelWithString: "")
    private let previewRow = NSStackView()
    private let startButton = ComposerControlButton()
    private let customBox = NSStackView()

    init(personality: BotPersonality?, width: CGFloat) {
        self.personality = personality
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 6

        chips = [PersonalityChip(choice: .none, target: self, action: #selector(pick(_:)))]
            + BotPersonalityPreset.all.map { PersonalityChip(choice: .preset($0.id), target: self, action: #selector(pick(_:))) }
            + [PersonalityChip(choice: .custom, target: self, action: #selector(pick(_:)))]
        // A name too long for a row (in some language) is cut short, its full name in the tooltip's place.
        for chip in chips { chip.widthAnchor.constraint(lessThanOrEqualToConstant: width).isActive = true }
        let rows = Self.rows(of: chips.map(\.intrinsicContentSize.width), width: width, spacing: 6).map { range in
            let row = NSStackView(views: Array(chips[range]))
            row.spacing = 6
            return row as NSView
        }
        let grid = NSStackView(views: rows)
        grid.orientation = .vertical
        grid.alignment = .leading
        grid.spacing = 6

        summary.font = .systemFont(ofSize: 11)
        summary.textColor = .secondaryLabelColor
        // The greeting in New York, the serif of the agents' replies.
        let previewLabel = NSTextField(labelWithString: String(localized: "Preview"))
        previewLabel.font = .systemFont(ofSize: 11, weight: .medium)
        previewLabel.textColor = .secondaryLabelColor
        previewLabel.setContentHuggingPriority(.required, for: .horizontal)
        greeting.font = Theme.serifFont(ofSize: 13)
        greeting.textColor = Theme.ink
        greeting.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for view in [previewLabel, greeting] { previewRow.addArrangedSubview(view) }
        previewRow.alignment = .firstBaseline
        previewRow.spacing = 8

        customText.string = personality?.custom ?? ""
        customText.delegate = self
        customText.isRichText = false
        customText.allowsUndo = true
        customText.font = .systemFont(ofSize: 13)
        customText.backgroundColor = Theme.raisedFill
        customText.textColor = Theme.ink
        customText.insertionPointColor = Theme.ink
        customText.textContainerInset = NSSize(width: 8, height: 8)
        customText.isVerticallyResizable = true
        customText.isHorizontallyResizable = false
        customText.autoresizingMask = [.width]
        customText.textContainer?.widthTracksTextView = true
        customText.setAccessibilityLabel(String(localized: "Custom personality"))
        customText.placeholder = String(localized: "Describe the personality…")
        customText.setAccessibilityPlaceholderValue(customText.placeholder)
        let customScroll = NSScrollView()
        customScroll.documentView = customText
        customScroll.hasVerticalScroller = true
        customScroll.borderType = .noBorder
        customScroll.drawsBackground = false
        customScroll.wantsLayer = true
        customScroll.layer?.cornerRadius = 7
        customScroll.layer?.cornerCurve = .continuous
        customScroll.layer?.borderWidth = 1
        customScroll.layer?.borderColor = Theme.surfaceBorder.cgColor
        customScroll.heightAnchor.constraint(equalToConstant: 84).isActive = true

        startButton.configure(title: String(localized: "Start from Preset"), symbolName: "text.badge.plus", chevron: true)
        startButton.setAccessibilityLabel(String(localized: "Start from Preset"))
        startButton.menuProvider = { [weak self] in self?.presetMenu() }
        let limit = NSTextField(labelWithString: String(
            localized: "Up to \(BotPersonalityPreset.customLimit.formatted()) characters."))
        limit.font = .systemFont(ofSize: 11)
        limit.textColor = .secondaryLabelColor
        let customRow = NSStackView(views: [startButton, NSView(), limit])
        customRow.spacing = 8
        for view in [customScroll, customRow] { customBox.addArrangedSubview(view) }
        customBox.orientation = .vertical
        customBox.alignment = .leading
        customBox.spacing = 6
        for child in [customScroll, customRow] {
            child.widthAnchor.constraint(equalTo: customBox.widthAnchor).isActive = true
        }

        for view in [grid, summary, previewRow, customBox] as [NSView] { addArrangedSubview(view) }
        setCustomSpacing(10, after: grid)
        for child in [summary, previewRow, customBox] as [NSView] {
            child.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        }
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The chip that's chosen. A preset this version doesn't have (a newer version's) chooses none of them.
    var choice: Choice {
        guard let personality else { return .none }
        return personality.presetID.map(Choice.preset) ?? .custom
    }

    /// The personality to save: nil for none, and for Custom without a description.
    var result: BotPersonality? {
        guard var personality else { return nil }
        personality.custom = personality.customText
        return personality.isEmpty ? nil : personality
    }

    /// A new character brings its own personality while the user hasn't picked one here, and the bot has none or the
    /// previous character's, as a character brings its name.
    func suggest(for character: BotAvatar.Shape, replacing previous: BotAvatar.Shape) {
        guard !userPicked, personality == nil || personality?.presetID == previous.defaultPersonality?.presetID else { return }
        set(character.defaultPersonality.map { BotPersonality(presetID: $0.presetID, custom: customText.string) })
    }

    @objc func pick(_ sender: PersonalityChip) {
        userPicked = true
        switch sender.choice {
        case .none: set(nil)
        case .preset(let id): set(BotPersonality(presetID: id, custom: customText.string))
        case .custom:
            set(BotPersonality(custom: customText.string))
            window?.makeFirstResponder(customText)
        }
    }

    /// Replaces the description with a preset's text, for the user to make their own. Undoable, like typing.
    func start(from preset: BotPersonalityPreset) {
        userPicked = true
        if choice != .custom { set(BotPersonality(custom: customText.string)) }
        let whole = NSRange(location: 0, length: (customText.string as NSString).length)
        if customText.shouldChangeText(in: whole, replacementString: preset.prompt) {
            customText.replaceCharacters(in: whole, with: preset.prompt)
            customText.didChangeText()
        }
        window?.makeFirstResponder(customText)
    }

    private func set(_ new: BotPersonality?) {
        personality = new
        refresh()
        onChange?()
    }

    private func refresh() {
        let choice = choice
        for chip in chips { chip.isChosen = chip.choice == choice }
        let preset = personality?.preset
        switch choice {
        case .none:
            summary.stringValue = String(localized: "No personality of its own: it talks as its instructions say.")
        case .preset:
            summary.stringValue = preset?.summary ?? ""
        case .custom:
            summary.stringValue = ""
        }
        summary.isHidden = summary.stringValue.isEmpty
        greeting.stringValue = preset?.greeting ?? ""
        previewRow.isHidden = preset == nil
        previewRow.setAccessibilityElement(true)
        previewRow.setAccessibilityLabel(String(localized: "Preview: \(greeting.stringValue)"))
        customBox.isHidden = choice != .custom
    }

    private func presetMenu() -> NSMenu {
        let menu = NSMenu()
        for preset in BotPersonalityPreset.all {
            let item = menu.addItem(withTitle: preset.name, action: #selector(startFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = preset.id
            item.image = Theme.symbol(preset.symbol)
            item.subtitle = preset.summary
        }
        return menu
    }

    @objc private func startFromMenu(_ sender: NSMenuItem) {
        guard let preset = BotPersonalityPreset.preset(id: sender.representedObject as? String) else { return }
        start(from: preset)
    }

    func textDidChange(_ notification: Notification) {
        personality?.custom = customText.string
        onChange?()
    }

    /// Keeps the description within `BotPersonalityPreset.customLimit`: typing past it stops, and a paste keeps what
    /// fits.
    func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString text: String?) -> Bool {
        guard let text else { return true }
        let current = textView.string as NSString
        let kept = current.replacingCharacters(in: range, with: "")
        guard kept.count + text.count > BotPersonalityPreset.customLimit else { return true }
        let room = BotPersonalityPreset.customLimit - kept.count
        if room > 0 {
            textView.replaceCharacters(in: range, with: String(text.prefix(room)))
            textView.didChangeText()
        }
        return false
    }

    /// Splits items of these widths into rows no wider than `width`, in order: the ranges of each row's items.
    static func rows(of widths: [CGFloat], width: CGFloat, spacing: CGFloat) -> [Range<Int>] {
        var rows: [Range<Int>] = []
        var start = 0
        var used: CGFloat = 0
        for (index, itemWidth) in widths.enumerated() {
            let needed = index == start ? itemWidth : used + spacing + itemWidth
            if index > start, needed > width {
                rows.append(start..<index)
                start = index
                used = itemWidth
            } else {
                used = needed
            }
        }
        if start < widths.count { rows.append(start..<widths.count) }
        return rows
    }
}

/// One chip in the Personality section: a symbol and a name, its description on hover. Drawn like the editor's other
/// choices: outlined at rest, a raised fill on hover, and the chosen one ringed in the theme's accent.
final class PersonalityChip: NSButton {
    let choice: BotPersonalitySection.Choice
    var isChosen = false {
        didSet {
            needsDisplay = true
            setAccessibilityValue(isChosen ? String(localized: "Selected") : nil)
        }
    }
    private let symbolName: String
    private var isHovered = false
    private static let font = NSFont.systemFont(ofSize: 12, weight: .medium)

    init(choice: BotPersonalitySection.Choice, target: AnyObject, action: Selector) {
        self.choice = choice
        let summary: String
        switch choice {
        case .none:
            symbolName = "circle.slash"
            summary = String(localized: "No personality of its own: it talks as its instructions say.")
        case .preset(let id):
            let preset = BotPersonalityPreset.preset(id: id)
            symbolName = preset?.symbol ?? "sparkles"
            summary = preset?.summary ?? ""
        case .custom:
            symbolName = "pencil.line"
            summary = String(localized: "Describe a personality in your own words.")
        }
        super.init(frame: .zero)
        self.target = target
        self.action = action
        isBordered = false
        setButtonType(.momentaryChange)
        title = Self.name(of: choice)
        toolTip = summary
        setAccessibilityLabel(title)
        setAccessibilityHelp(summary)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 26).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    static func name(of choice: BotPersonalitySection.Choice) -> String {
        switch choice {
        case .none: String(localized: "None", comment: "No bot personality")
        case .preset(let id): BotPersonalityPreset.preset(id: id)?.name ?? id
        case .custom: String(localized: "Custom", comment: "A bot personality the user wrote")
        }
    }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        let text = (title as NSString).size(withAttributes: [.font: Self.font])
        return NSSize(width: ceil(text.width) + 10 + 14 + 5 + 11, height: 26)
    }

    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let inset: CGFloat = isChosen ? 1 : 0.5
        let tile = NSBezierPath(roundedRect: bounds.insetBy(dx: inset, dy: inset), xRadius: 8, yRadius: 8)
        if isChosen || isHovered {
            Theme.raisedFill.setFill()
            tile.fill()
        }
        if isChosen {
            Theme.accent.setStroke()
            tile.lineWidth = 2
        } else {
            Theme.surfaceBorder.setStroke()
            tile.lineWidth = 1
        }
        tile.stroke()
        let ink = isChosen || isHovered ? Theme.ink : NSColor.secondaryLabelColor
        if let symbol = Theme.symbol(symbolName, size: 11, weight: .medium) {
            let size = symbol.size
            let rect = NSRect(x: 10 + (14 - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
            let tinted = NSImage(size: size, flipped: false) { drawn in
                symbol.draw(in: drawn)
                ink.set()
                drawn.fill(using: .sourceIn)
                return true
            }
            tinted.draw(in: rect)
        }
        let attributes: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: isChosen ? Theme.ink : ink]
        let text = (title as NSString).size(withAttributes: attributes)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        var truncating = attributes
        truncating[.paragraphStyle] = paragraph
        let origin = NSPoint(x: 10 + 14 + 5, y: (bounds.height - text.height) / 2)
        (title as NSString).draw(
            with: NSRect(origin: origin, size: NSSize(width: max(0, bounds.width - origin.x - 11), height: text.height)),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: truncating)
    }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
    }

    override var focusRingMaskBounds: NSRect { bounds }
}
