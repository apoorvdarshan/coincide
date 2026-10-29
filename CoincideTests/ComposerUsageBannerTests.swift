import AppKit
import CoincideKit
import Testing

@testable import Coincide

/// The usage warning over the composer: the message on the leading side, its actions grouped at the trailing edge with
/// the dismiss button last, at every width the composer takes and in long languages; the text follows the Used/Remaining
/// setting. Set `COINCIDE_BANNER_PNG_DIR` (`TEST_RUNNER_COINCIDE_BANNER_PNG_DIR` through xcodebuild) to also write the
/// banner over a composer as PNGs, in light and dark and a few themes. Nothing is put on screen: the window stays
/// transparent, far offscreen and never ordered in.
@MainActor @Suite(.serialized) struct ComposerUsageBannerTests {
    nonisolated static let now = Date(timeIntervalSince1970: 1_800_000_000)
    /// 97% of the weekly window used, resetting in 1d 8h, as in the report.
    nonisolated static let weekly = UsageLimitWindow(
        id: "weekly", kind: .weekly, label: "Weekly", usedPercent: 97, resetsAt: now.addingTimeInterval(32 * 3_600 + 59),
        durationMinutes: 7 * 24 * 60)

    /// The banner as the composer stacks it: 12 points in from each side of a composer `width` wide.
    @MainActor final class Harness {
        let banner = ComposerUsageBanner()
        let window: NSWindow
        let root = SolidBackgroundView(color: Theme.contentBackground)
        private let width: NSLayoutConstraint

        init(width bannerWidth: CGFloat) {
            let composer = FlatSurfaceView(style: .composer)
            composer.cornerRadius = 22
            let column = NSStackView(views: [banner, composer])
            column.orientation = .vertical
            column.alignment = .centerX
            column.spacing = 6
            column.edgeInsets = NSEdgeInsets(top: 12, left: 0, bottom: 12, right: 0)
            column.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(column)
            width = root.widthAnchor.constraint(equalToConstant: bannerWidth + 48)
            NSLayoutConstraint.activate([
                column.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
                column.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
                column.topAnchor.constraint(equalTo: root.topAnchor),
                column.bottomAnchor.constraint(equalTo: root.bottomAnchor),
                banner.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -24),
                composer.widthAnchor.constraint(equalTo: column.widthAnchor),
                composer.heightAnchor.constraint(equalToConstant: 64),
                width,
            ])
            window = NSWindow(
                contentRect: NSRect(x: -20_000, y: -20_000, width: bannerWidth + 48, height: 200), styleMask: [.borderless],
                backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            window.alphaValue = 0
            window.contentView = root
        }

        func resize(to bannerWidth: CGFloat) {
            width.constant = bannerWidth + 48
            settle()
        }

        /// Lays the banner out and fits the window to it.
        func settle() {
            for _ in 0..<2 {
                root.layoutSubtreeIfNeeded()
                window.setContentSize(NSSize(width: width.constant, height: root.fittingSize.height))
                root.layoutSubtreeIfNeeded()
            }
        }

        func frame(of view: NSView) -> NSRect { view.convert(view.bounds, to: banner) }
    }

    /// From narrower than any chat through the narrowest chat's banner (348 points) to a full-screen composer.
    nonisolated static let widths: [CGFloat] = [240, 300, 348, 420, 560, 680, 796, 1_200]
    /// The narrowest banner a chat shows: the narrowest chat (420 points) less the composer's and the banner's insets.
    static let narrowestChat: CGFloat = 348

    /// German, with the longest action titles the banner shows.
    static func germanize(_ banner: ComposerUsageBanner, scheduled: Bool) {
        banner.message.stringValue =
            "97 % deines Limits (Claude Code wöchentlich) sind verbraucht. Es wird in 1 T 8 Std. zurückgesetzt."
            + (scheduled ? " Dieser Thread wird um 14:30 fortgesetzt." : "")
        banner.resumeButton.title = scheduled ? "Automatisches Fortsetzen abbrechen" : "Beim Zurücksetzen fortsetzen"
    }

    static var lineHeight: CGFloat { ceil(Theme.lineHeight(of: .systemFont(ofSize: 12))) }

    // MARK: Layout

    @Test(arguments: widths)
    func theDismissButtonSitsAtTheTrailingEdgeAfterTheActions(width: CGFloat) throws {
        for german in [false, true] {
            for resume in [nil, ComposerUsageBanner.ResumeOffer.available, .scheduled(Self.now.addingTimeInterval(3_600))] {
                let harness = Harness(width: width)
                let banner = harness.banner
                banner.show(Self.weekly, provider: .claude, now: Self.now, resume: resume)
                if german {
                    if case .scheduled = resume { Self.germanize(banner, scheduled: true) } else { Self.germanize(banner, scheduled: false) }
                }
                harness.settle()
                checkLayout(harness, name: "\(Int(width)) \(german ? "de" : "en") \(String(describing: resume))")
            }
        }
    }

    private func checkLayout(_ harness: Harness, name: String) {
        let banner = harness.banner
        let bounds = banner.bounds
        #expect(abs(bounds.width - (harness.root.bounds.width - 48)) < 0.5, "\(name): banner width")
        let dismiss = harness.frame(of: banner.dismissButton)
        let message = harness.frame(of: banner.message)
        let buttons = [banner.resumeButton, banner.detailsButton].filter { !$0.isHidden }
        let actions = buttons.map { harness.frame(of: $0) }

        // The dismiss button: the last thing on the trailing edge, at its own size, on the message's line.
        #expect(abs(dismiss.maxX - (bounds.maxX - 6)) < 0.5, "\(name): × is not at the trailing edge (\(dismiss), \(bounds))")
        #expect(dismiss.width == ComposerBannerButton.height && dismiss.height == ComposerBannerButton.height, "\(name): × size \(dismiss)")
        #expect(bounds.contains(dismiss), "\(name): × outside the banner")
        #expect(abs(dismiss.midY - message.midY) < 1, "\(name): × is not on the message's line")

        // Every action inside the banner, on the message's line, left of the × and clear of each other and the message.
        // From the narrowest chat's banner up, each is at its full size; only narrower ones may cut a title short.
        for (button, frame) in zip(buttons, actions) {
            if bounds.width >= Self.narrowestChat {
                #expect(frame.width + 0.5 >= button.intrinsicContentSize.width, "\(name): “\(button.title)” is clipped")
            }
            #expect(bounds.contains(frame), "\(name): “\(button.title)” is outside the banner \(frame)")
            #expect(abs(frame.midY - dismiss.midY) < 1, "\(name): “\(button.title)” and the × are not on one line")
            #expect(frame.maxX <= dismiss.minX + 0.5, "\(name): “\(button.title)” is right of the ×")
            #expect(!frame.insetBy(dx: 0.5, dy: 0.5).intersects(message), "\(name): “\(button.title)” overlaps the message")
            #expect(!frame.insetBy(dx: 0.5, dy: 0.5).intersects(dismiss), "\(name): “\(button.title)” overlaps the ×")
        }
        // Grouped against the ×, in order (the resume offer, then Details, then the ×), with nothing floating between.
        let ordered = actions.sorted { $0.minX < $1.minX }
        #expect(ordered == actions, "\(name): actions out of order")
        for (left, right) in zip(ordered, ordered.dropFirst()) {
            #expect(right.minX - left.maxX <= 4, "\(name): a gap between the actions")
        }
        if let last = ordered.last {
            #expect(dismiss.minX - last.maxX <= 4, "\(name): the actions float away from the ×")
            #expect(message.maxX <= ordered[0].minX, "\(name): message runs under the actions")
            // The message takes all the room the actions leave.
            #expect(ordered[0].minX - message.maxX <= 12, "\(name): a gap between the message and the actions")
        }
        // The message: one line, inside the banner, left of the actions, with the meter under it.
        #expect(message.height <= Self.lineHeight + 3, "\(name): message taller than one line (\(message.height))")
        #expect(message.height >= Self.lineHeight - 1, "\(name): message collapsed")
        #expect(message.maxX <= dismiss.minX, "\(name): message runs under the ×")
        #expect(bounds.contains(message), "\(name): message outside the banner")
        let meter = harness.frame(of: banner.meter)
        #expect(!meter.intersects(message), "\(name): meter overlaps the message")
        #expect(banner.isFlipped ? meter.minY >= message.maxY : meter.maxY <= message.minY, "\(name): meter not under the message")
        // The bar starts where the text does: the field's alignment rectangle, inside its frame.
        let text = banner.message.alignmentRect(forFrame: message)
        #expect(abs(meter.minX - text.minX) < 0.5, "\(name): meter not under the message's start (\(meter), \(text))")
        #expect(meter.width <= ComposerUsageBanner.maximumMeterWidth + 0.5 && meter.width > 0, "\(name): meter width \(meter.width)")
        // From the narrowest chat's banner up, the message keeps room to read; the resume offer gives up its title first.
        if bounds.width >= Self.narrowestChat {
            #expect(message.width + 0.5 >= ComposerUsageBanner.minimumMessageWidth, "\(name): message squeezed to \(message.width)")
        }
        #expect(banner.resumeButton.isCompact == banner.needsCompactResume(width: bounds.width), "\(name): resume offer")
        #expect(bounds.contains(meter), "\(name): meter outside the banner")
    }

    @Test func theBannerKeepsOneHeightAtEveryWidth() {
        var heights: Set<CGFloat> = []
        for width in Self.widths {
            let harness = Harness(width: width)
            harness.banner.show(Self.weekly, provider: .claude, now: Self.now, resume: .scheduled(Self.now.addingTimeInterval(3_600)))
            harness.settle()
            heights.insert(harness.banner.bounds.height.rounded())
        }
        #expect(heights.count == 1, "heights \(heights)")
        #expect((heights.first ?? 0) <= 44)
    }

    @Test func resizingKeepsTheDismissButtonAtTheTrailingEdge() {
        // The old banner's wrapping label kept the narrower width after a resize, leaving its × mid-bar on a wide window.
        let harness = Harness(width: Self.narrowestChat)
        harness.banner.show(Self.weekly, provider: .claude, now: Self.now, resume: .available)
        harness.settle()
        for width in [1_200, 348, 796, 420, 1_200] as [CGFloat] {
            harness.resize(to: width)
            let dismiss = harness.frame(of: harness.banner.dismissButton)
            let details = harness.frame(of: harness.banner.detailsButton)
            let resume = harness.frame(of: harness.banner.resumeButton)
            #expect(abs(dismiss.maxX - (width - 6)) < 0.5, "\(width): × at \(dismiss)")
            #expect(dismiss.minX - details.maxX <= 4 && details.minX - resume.maxX <= 4, "\(width): actions not grouped")
            checkLayout(harness, name: "resized to \(Int(width))")
        }
    }

    @Test func theResumeOfferShowsAsASymbolWhereRoomIsShort() {
        let scheduled = ComposerUsageBanner.ResumeOffer.scheduled(Self.now.addingTimeInterval(3_600))
        let harness = Harness(width: 1_200)
        harness.banner.show(Self.weekly, provider: .claude, now: Self.now, resume: scheduled)
        harness.settle()
        let resume = harness.banner.resumeButton
        #expect(!resume.isCompact)
        #expect(resume.toolTip == nil)
        #expect(abs(harness.frame(of: resume).width - resume.titledWidth) < 0.5)

        // English "Cancel Auto-Resume" at the narrowest chat's banner: the title would leave the message too little.
        harness.resize(to: Self.narrowestChat)
        #expect(resume.isCompact)
        #expect(harness.frame(of: resume).width == ComposerBannerButton.height)
        // Still named for VoiceOver and the pointer, and Details keeps its title.
        #expect(resume.title == "Cancel Auto-Resume")
        #expect(resume.toolTip == "Cancel Auto-Resume")
        #expect(!harness.banner.detailsButton.isCompact)
        #expect(abs(harness.frame(of: harness.banner.detailsButton).width - harness.banner.detailsButton.titledWidth) < 0.5)

        // "Resume at Reset" keeps its own tooltip as a symbol, and widening brings the title back.
        harness.banner.show(Self.weekly, provider: .claude, now: Self.now, resume: .available)
        harness.settle()
        #expect(resume.isCompact)
        #expect(resume.toolTip == "Continue this thread on its own once the limit resets.")
        harness.resize(to: 796)
        #expect(!resume.isCompact)
        #expect(abs(harness.frame(of: resume).width - resume.titledWidth) < 0.5)
    }

    @Test func aLongMessageTruncatesOnOneLine() {
        let harness = Harness(width: Self.narrowestChat)
        harness.banner.show(Self.weekly, provider: .claude, now: Self.now, resume: .scheduled(Self.now.addingTimeInterval(3_600)))
        harness.settle()
        let message = harness.banner.message
        let text = message.stringValue
        let frame = harness.frame(of: message)
        // Too long for the room, so the field cuts it short with an ellipsis rather than wrapping.
        #expect(message.attributedStringValue.size().width > frame.width)
        #expect(message.lineBreakMode == .byTruncatingTail)
        #expect(message.maximumNumberOfLines == 1)
        #expect(frame.height <= Self.lineHeight + 3)
        // All of it is still there for the pointer and VoiceOver.
        #expect(message.toolTip == text)
        #expect(harness.banner.accessibilityLabel() == text)

        // A very long translation stays on one line too, and never pushes the actions out.
        message.stringValue = String(repeating: "Ein sehr langer Satz über Nutzungslimits. ", count: 12)
        harness.settle()
        #expect(harness.frame(of: message).height <= Self.lineHeight + 3)
        checkLayout(harness, name: "long message")
    }

    // MARK: Text and display mode

    @Test func theTextFollowsTheUsedOrRemainingSetting() {
        let banner = ComposerUsageBanner()
        banner.show(Self.weekly, provider: .claude, mode: .used, now: Self.now)
        #expect(banner.message.stringValue == "97% of your Claude Code weekly limit is used. It resets in 1d 8h.")
        #expect(abs(banner.meter.fraction - 0.97) < 0.001)
        #expect(banner.meter.accessibilityValueDescription() == "97% used")

        banner.show(Self.weekly, provider: .claude, mode: .remaining, now: Self.now)
        #expect(banner.message.stringValue == "3% of your Claude Code weekly limit is left. It resets in 1d 8h.")
        #expect(abs(banner.meter.fraction - 0.03) < 0.001)
        #expect(banner.meter.accessibilityValueDescription() == "3% left")
        #expect(banner.accessibilityLabel() == banner.message.stringValue)

        // A reached limit reads the same either way.
        let reached = UsageLimitWindow(id: "s", kind: .session, label: "Session", usedPercent: 100, resetsAt: Self.now.addingTimeInterval(90 * 60))
        banner.show(reached, provider: .claude, mode: .remaining, now: Self.now)
        #expect(banner.message.stringValue == "Claude Code usage limit reached. The session limit resets in 1h 30m.")
        #expect(banner.meter.fraction == 0)
    }

    @Test func aScheduledResumeSaysWhenTheThreadContinues() {
        let banner = ComposerUsageBanner()
        let at = Self.now.addingTimeInterval(3_600)
        banner.show(Self.weekly, provider: .claude, now: Self.now, resume: .scheduled(at))
        #expect(!banner.resumeButton.isHidden)
        #expect(banner.resumeButton.title == "Cancel Auto-Resume")
        #expect(banner.message.stringValue.hasSuffix("This thread continues at \(at.formatted(date: .omitted, time: .shortened))."))
        banner.show(Self.weekly, provider: .claude, now: Self.now, resume: .available)
        #expect(banner.resumeButton.title == "Resume at Reset")
        banner.show(Self.weekly, provider: .claude, now: Self.now)
        #expect(banner.resumeButton.isHidden)
    }

    // MARK: Actions

    @Test func theButtonsReportTheirActionsAndNameThemselves() {
        let banner = ComposerUsageBanner()
        banner.show(Self.weekly, provider: .claude, now: Self.now, resume: .available)
        var calls: [String] = []
        banner.onDismiss = { calls.append("dismiss") }
        banner.onShowDetails = { calls.append("details") }
        banner.onToggleResume = { calls.append("resume") }
        banner.detailsButton.performClick(nil)
        banner.resumeButton.performClick(nil)
        banner.dismissButton.performClick(nil)
        #expect(calls == ["details", "resume", "dismiss"])

        #expect(banner.dismissButton.accessibilityLabel() == "Dismiss")
        #expect(banner.detailsButton.accessibilityLabel() == "Details")
        #expect(banner.resumeButton.accessibilityLabel() == "Resume at Reset")
        #expect(banner.detailsButton.toolTip?.isEmpty == false)
        #expect(banner.dismissButton.accessibilityRole() == .button)
        #expect(banner.detailsButton.accessibilityRole() == .button)
    }

    @Test func aDismissedWarningStaysDismissedInEitherModeUntilItGetsWorse() {
        // The composer keeps dismissed warnings by key: the key ignores the display mode and changes once the window
        // reaches its limit or resets.
        let key = UsageLimits.warningKey(for: Self.weekly, provider: .claude)
        var later = Self.weekly
        later.usedPercent = 99
        #expect(UsageLimits.warningKey(for: later, provider: .claude) == key)
        var reached = Self.weekly
        reached.usedPercent = 100
        #expect(UsageLimits.warningKey(for: reached, provider: .claude) != key)
        var reset = Self.weekly
        reset.resetsAt = Self.now.addingTimeInterval(8 * 86_400)
        #expect(UsageLimits.warningKey(for: reset, provider: .claude) != key)
    }

    // MARK: Rendered banners

    @Test func rendersInLightAndDarkAndSeveralThemes() throws {
        guard let folder = ProcessInfo.processInfo.environment["COINCIDE_BANNER_PNG_DIR"], !folder.isEmpty else { return }
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let saved = ThemeSelection.shared.theme(for: NSAppearance(named: .darkAqua)!).id
        let savedLight = ThemeSelection.shared.theme(for: NSAppearance(named: .aqua)!).id
        defer { ThemeSelection.shared.set(dark: saved, light: savedLight) }
        let reached = UsageLimitWindow(id: "s", kind: .session, label: "Session", usedPercent: 100, resetsAt: Self.now.addingTimeInterval(90 * 60))
        let cases: [(String, CGFloat, UsageLimitWindow, UsageDisplayMode, ComposerUsageBanner.ResumeOffer?, Bool)] = [
            ("near-796", 796, Self.weekly, .used, nil, false),
            ("near-remaining-796", 796, Self.weekly, .remaining, nil, false),
            ("near-560", 560, Self.weekly, .used, nil, false),
            ("near-348", 348, Self.weekly, .used, nil, false),
            ("near-de-348", 348, Self.weekly, .used, nil, true),
            ("reached-resume-796", 796, reached, .used, .available, false),
            ("reached-resume-480", 480, reached, .used, .available, false),
            ("reached-resume-de-560", 560, reached, .used, .available, true),
            ("reached-scheduled-300", 300, reached, .used, .scheduled(Self.now.addingTimeInterval(5_400)), false),
            ("near-1200", 1_200, Self.weekly, .used, nil, false),
        ]
        let themes = [("carbon", "carbon-light"), ("midnight", "paper"), ("forest", "sepia")]
        for (dark, light) in themes {
            ThemeSelection.shared.set(dark: dark, light: light)
            for (name, width, window, mode, resume, german) in cases {
                if dark != "carbon", !name.hasPrefix("near-796"), !name.hasPrefix("reached-resume-796") { continue }
                let harness = Harness(width: width)
                harness.banner.show(window, provider: .claude, mode: mode, now: Self.now, resume: resume)
                if german { Self.germanize(harness.banner, scheduled: false) }
                for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                    harness.window.appearance = NSAppearance(named: appearance)
                    harness.root.color = Theme.contentBackground
                    harness.settle()
                    let root = harness.root
                    for view in Self.subviews(of: root) { view.needsDisplay = true }
                    root.displayIfNeeded()
                    let rep = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
                    root.effectiveAppearance.performAsCurrentDrawingAppearance { root.cacheDisplay(in: root.bounds, to: rep) }
                    let theme = suffix == "light" ? light : dark
                    try #require(rep.representation(using: .png, properties: [:])).write(
                        to: URL(fileURLWithPath: folder).appendingPathComponent("\(name)-\(theme)-\(suffix).png"))
                }
            }
        }
    }

    private static func subviews(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + subviews(of: $0) }
    }
}
