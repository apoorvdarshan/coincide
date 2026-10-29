import AppKit
import CoincideKit

/// How tall the plan card above the composer may be. Pure, so the clamping can be tested without a window.
nonisolated enum ComposerPlanCardLayout {
    /// The tallest the card gets, however large the window.
    static let maximumHeight: CGFloat = 260
    /// The card takes at most this share of the conversation's height.
    static let heightFraction: CGFloat = 0.4
    /// What the conversation keeps above the composer, so the card never squeezes it out or pushes the composer off.
    static let transcriptReserve: CGFloat = 120
    /// Lines a collapsed card previews.
    static let previewLines = 4

    /// The card's height limit in a conversation `availableHeight` tall, where the rest of the composer (its input,
    /// footer, other banners and margins) takes `otherComposerHeight`.
    static func maximumCardHeight(availableHeight: CGFloat, otherComposerHeight: CGFloat) -> CGFloat {
        let room = availableHeight - otherComposerHeight - transcriptReserve
        return max(0, min(maximumHeight, (availableHeight * heightFraction).rounded(.down), room))
    }

    /// The height of the card's scrolling plan text. Expanded it fits the whole plan up to the limit and scrolls past
    /// it; collapsed it previews the first lines (`previewHeight`). It never drops below `minimumHeight` (a line), so
    /// the card stays usable in a short window.
    static func bodyHeight(
        contentHeight: CGFloat, previewHeight: CGFloat, isCollapsed: Bool, maximumCardHeight: CGFloat,
        chromeHeight: CGFloat, minimumHeight: CGFloat
    ) -> CGFloat {
        let wanted = isCollapsed ? min(contentHeight, previewHeight) : contentHeight
        let limit = max(minimumHeight, maximumCardHeight - chromeHeight)
        return max(0, min(wanted, limit)).rounded(.up)
    }

    /// Collapsing only offers something when the plan runs longer than its preview.
    static func canCollapse(contentHeight: CGFloat, previewHeight: CGFloat) -> Bool {
        contentHeight > previewHeight + 1
    }

    /// The height of the first `lines` lines, from the bottoms of the laid-out line fragments in order.
    static func previewHeight(lineBottoms: [CGFloat], lines: Int = previewLines) -> CGFloat {
        guard lines > 0, !lineBottoms.isEmpty else { return 0 }
        return lineBottoms[min(lines, lineBottoms.count) - 1].rounded(.up)
    }
}

/// Which threads show their plan card collapsed to a preview. Kept per thread on this Mac, most recent first, and
/// capped so threads deleted long ago don't pile up.
final class ComposerPlanCardMemory {
    static let shared = ComposerPlanCardMemory(defaults: .standard)
    static let key = "composerCollapsedPlanThreads"
    static let limit = 200

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    private var collapsed: [String] { defaults.stringArray(forKey: Self.key) ?? [] }

    func isCollapsed(_ threadID: UUID) -> Bool {
        collapsed.contains(threadID.uuidString)
    }

    func setCollapsed(_ isCollapsed: Bool, for threadID: UUID) {
        var ids = collapsed.filter { $0 != threadID.uuidString }
        if isCollapsed { ids.insert(threadID.uuidString, at: 0) }
        ids = Array(ids.prefix(Self.limit))
        if ids.isEmpty { defaults.removeObject(forKey: Self.key) } else { defaults.set(ids, forKey: Self.key) }
    }
}

/// Shown in plan mode once the agent has proposed a plan: the plan itself as the transcript renders it, scrolling
/// inside the card when it runs long, with a header to collapse it to a preview, open it in the transcript, copy it
/// or hide it. The send button meanwhile offers to implement the plan, and typing refines it instead.
final class ComposerPlanCard: ComposerBanner {
    /// The user collapsed (true) or expanded the card.
    var onToggleCollapsed: ((Bool) -> Void)?
    var onOpenInTranscript: (() -> Void)?
    var onDismiss: (() -> Void)?
    /// A link in the plan was clicked; true when it was handled.
    var onOpenLink: ((Any) -> Bool)?
    /// The card changed height because of something the user did, so the composer can animate the change.
    var onHeightChange: (() -> Void)?

    /// The tallest the whole card may be (`ComposerPlanCardLayout.maximumCardHeight`), set by the composer.
    var maximumHeight: CGFloat = ComposerPlanCardLayout.maximumHeight {
        didSet { if maximumHeight != oldValue { updateBodyHeight() } }
    }

    private(set) var isCollapsed = false
    /// Whether the plan is long enough to collapse, so the toggle shows.
    private(set) var canCollapse = false
    private(set) var plan = ""

    private let toggleButton = TranscriptIconButton(symbol: "arrow.down.right.and.arrow.up.left", label: "", action: nil, target: nil)
    private let openButton = TranscriptIconButton(
        symbol: "arrow.up.right.square", label: String(localized: "Open in Transcript"), action: nil, target: nil)
    private let copyButton = TranscriptIconButton(symbol: "doc.on.doc", label: String(localized: "Copy Plan"), action: nil, target: nil)
    private let dismissButton = TranscriptIconButton(symbol: "xmark", label: String(localized: "Hide Plan"), action: nil, target: nil)
    private let scrollView = NSScrollView()
    private let textView = ChatTextView()
    private var bodyHeight: NSLayoutConstraint?
    private var style: ChatMarkdownStyle?
    private var measuredWidth: CGFloat = 0
    private var contentHeight: CGFloat = 0
    private var previewHeight: CGFloat = 0

    private static let insets = NSEdgeInsets(top: 8, left: 14, bottom: 10, right: 8)
    private static let headerHeight: CGFloat = 22
    private static let headerSpacing: CGFloat = 6
    /// Space the card takes besides its text: insets, header and the gap below it.
    static var chromeHeight: CGFloat { insets.top + headerHeight + headerSpacing + insets.bottom }
    private static var horizontalInsets: CGFloat { insets.left + insets.right }

    init() {
        super.init()
        content.edgeInsets = Self.insets
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = Self.headerSpacing

        let heading = ComposerBanner.label(String(localized: "Plan ready"), weight: .semibold, color: .secondaryLabelColor)
        heading.setContentCompressionResistancePriority(.required, for: .horizontal)
        heading.setContentHuggingPriority(.required, for: .horizontal)
        for (button, action) in [
            (toggleButton, #selector(toggleCollapsed)), (openButton, #selector(openInTranscript)),
            (copyButton, #selector(copyPlan)), (dismissButton, #selector(dismiss)),
        ] {
            button.target = self
            button.action = action
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
            button.widthAnchor.constraint(equalToConstant: 22).isActive = true
        }
        let header = NSStackView(views: [
            ComposerBanner.icon("checklist", color: Theme.ink), heading, NSView(), toggleButton, openButton,
            copyButton, dismissButton,
        ])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 6
        header.setCustomSpacing(2, after: toggleButton)
        header.setCustomSpacing(2, after: openButton)
        header.setCustomSpacing(2, after: copyButton)
        header.detachesHiddenViews = true
        header.heightAnchor.constraint(equalToConstant: Self.headerHeight).isActive = true

        textView.setAccessibilityLabel(String(localized: "Plan"))
        // Links open as they do in the transcript, which resolves file paths against the thread's folder.
        textView.onOpenLink = { [weak self] link in self?.onOpenLink?(link) ?? false }
        scrollView.documentView = textView
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.verticalScrollElasticity = .none
        let height = scrollView.heightAnchor.constraint(equalToConstant: 0)
        height.isActive = true
        bodyHeight = height

        content.addArrangedSubview(header)
        content.addArrangedSubview(scrollView)
        // The text lines up with the header; the overlay scroller draws over its trailing edge while it scrolls.
        NSLayoutConstraint.activate([
            header.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -Self.horizontalInsets),
            scrollView.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -Self.horizontalInsets),
        ])
        updateToggle()
    }

    /// Shows `plan`, rendering it again only when it or the text style changed. A new plan starts at its top. The plan's
    /// own heading shows in the text, so `title` only names the card for VoiceOver.
    func show(plan: String, title: String?, isCollapsed: Bool) {
        let style = TranscriptText.style(.plan)
        let changed = plan != self.plan || style != self.style
        self.isCollapsed = isCollapsed
        setAccessibilityLabel([String(localized: "Plan ready"), title].compactMap { $0 }.joined(separator: ", "))
        if changed {
            let isNewPlan = plan != self.plan
            self.plan = plan
            self.style = style
            textView.setText(ChatMarkdownRenderer.render(plan, style: style).string)
            measuredWidth = 0
            measure()
            if isNewPlan { scrollView.contentView.scroll(to: .zero) }
        }
        updateBodyHeight()
    }

    /// A new width lays the plan out again, in the layout pass this starts.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if textWidth > 0, textWidth != measuredWidth { needsLayout = true }
    }

    override func layout() {
        super.layout()
        let width = textWidth
        guard width > 0, width != measuredWidth else { return }
        measure()
        updateBodyHeight()
    }

    /// The width the plan is laid out at, from the card's own width: the scroll view inside gets its frame only after
    /// the card's layout runs. Its scroller overlays the text, so the text takes the scroll view's full width.
    private var textWidth: CGFloat {
        max(0, bounds.width - Self.horizontalInsets)
    }

    /// Lays the plan out at the scroll view's width: its full height and the height of its first lines.
    private func measure() {
        let width = textWidth
        guard width > 0, let layoutManager = textView.layoutManager, let container = textView.textContainer else {
            contentHeight = 0
            previewHeight = 0
            return
        }
        measuredWidth = width
        textView.frame.size.width = width
        container.size = NSSize(width: width, height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: container)
        var bottoms: [CGFloat] = []
        let glyphs = layoutManager.glyphRange(for: container)
        layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { _, used, _, _, stop in
            bottoms.append(used.maxY)
            if bottoms.count >= ComposerPlanCardLayout.previewLines { stop.pointee = true }
        }
        contentHeight = ceil(layoutManager.usedRect(for: container).height)
        previewHeight = ComposerPlanCardLayout.previewHeight(lineBottoms: bottoms)
        textView.frame.size.height = contentHeight
        canCollapse = ComposerPlanCardLayout.canCollapse(contentHeight: contentHeight, previewHeight: previewHeight)
        updateToggle()
    }

    private func updateBodyHeight() {
        guard let bodyHeight else { return }
        let line = Theme.lineHeight(of: .systemFont(ofSize: Theme.fontSize))
        let height = ComposerPlanCardLayout.bodyHeight(
            contentHeight: contentHeight, previewHeight: previewHeight, isCollapsed: isCollapsed && canCollapse,
            maximumCardHeight: maximumHeight, chromeHeight: Self.chromeHeight, minimumHeight: line)
        if bodyHeight.constant != height { bodyHeight.constant = height }
        scrollView.verticalScrollElasticity = contentHeight > height + 1 ? .automatic : .none
    }

    private func updateToggle() {
        toggleButton.isHidden = !canCollapse
        let collapsed = isCollapsed && canCollapse
        toggleButton.setSymbol(collapsed ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left")
        let label = collapsed ? String(localized: "Expand Plan") : String(localized: "Collapse Plan")
        toggleButton.toolTip = label
        toggleButton.setAccessibilityLabel(label)
    }

    @objc private func toggleCollapsed() {
        isCollapsed.toggle()
        updateToggle()
        updateBodyHeight()
        onToggleCollapsed?(isCollapsed)
        onHeightChange?()
    }

    @objc private func openInTranscript() {
        onOpenInTranscript?()
    }

    @objc private func copyPlan() {
        NSPasteboard.general.setText(plan)
        copyButton.flashConfirmation()
        NSAccessibility.post(
            element: copyButton, notification: .announcementRequested,
            userInfo: [.announcement: String(localized: "Copied"), .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }

    @objc private func dismiss() {
        onDismiss?()
    }
}
