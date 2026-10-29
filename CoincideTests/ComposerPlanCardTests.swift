import AppKit
import CoincideKit
import Foundation
import Testing

@testable import Coincide

/// The "Plan ready" card above the composer: how tall it gets, which threads keep it collapsed, and the composer
/// showing, collapsing and hiding it.
struct ComposerPlanCardLayoutTests {
    private typealias Layout = ComposerPlanCardLayout

    @Test func theCardTakesAtMost260PointsOrFortyPercentOfTheConversation() {
        // A tall window: the fixed cap wins.
        #expect(Layout.maximumCardHeight(availableHeight: 1200, otherComposerHeight: 140) == 260)
        // A medium one: 40% of 500 is less than 260.
        #expect(Layout.maximumCardHeight(availableHeight: 500, otherComposerHeight: 140) == 200)
        #expect(Layout.maximumCardHeight(availableHeight: 501, otherComposerHeight: 140) == 200)
    }

    @Test func theCardNeverPushesTheComposerOutOfTheWindow() {
        // A tall input leaves the card only what the conversation can spare: 600 - 380 - 120.
        #expect(Layout.maximumCardHeight(availableHeight: 600, otherComposerHeight: 380) == 100)
        // With no room at all the limit is zero, not negative.
        #expect(Layout.maximumCardHeight(availableHeight: 300, otherComposerHeight: 400) == 0)
    }

    @Test func anExpandedCardFitsThePlanUpToItsLimitAndScrollsPastIt() {
        let chrome: CGFloat = 46
        func body(_ content: CGFloat, limit: CGFloat = 260) -> CGFloat {
            Layout.bodyHeight(
                contentHeight: content, previewHeight: 70, isCollapsed: false, maximumCardHeight: limit,
                chromeHeight: chrome, minimumHeight: 17)
        }
        #expect(body(120) == 120)
        #expect(body(214) == 214)
        #expect(body(900) == 214)
        #expect(body(900, limit: 150) == 104)
        // Fractional heights round up, so the last line is never clipped.
        #expect(body(120.2) == 121)
    }

    @Test func aCollapsedCardPreviewsItsFirstLines() {
        func body(_ content: CGFloat, limit: CGFloat = 260) -> CGFloat {
            Layout.bodyHeight(
                contentHeight: content, previewHeight: 70, isCollapsed: true, maximumCardHeight: limit,
                chromeHeight: 46, minimumHeight: 17)
        }
        #expect(body(900) == 70)
        // A plan shorter than the preview shows whole.
        #expect(body(40) == 40)
        // A short window still shows a line, even past its limit.
        #expect(body(900, limit: 50) == 17)
    }

    @Test func onlyAPlanLongerThanItsPreviewCollapses() {
        #expect(Layout.canCollapse(contentHeight: 300, previewHeight: 70))
        #expect(!Layout.canCollapse(contentHeight: 70, previewHeight: 70))
        #expect(!Layout.canCollapse(contentHeight: 70.5, previewHeight: 70))
    }

    @Test func thePreviewEndsAtTheBottomOfItsLastLine() {
        #expect(Layout.previewHeight(lineBottoms: [17, 34, 51.5, 68, 85]) == 68)
        #expect(Layout.previewHeight(lineBottoms: [17, 34.2], lines: 4) == 35)
        #expect(Layout.previewHeight(lineBottoms: []) == 0)
        #expect(Layout.previewHeight(lineBottoms: [17], lines: 0) == 0)
    }
}

struct ComposerPlanCardMemoryTests {
    private static func defaults() -> (UserDefaults, String) {
        let suite = "CoincideTests.planCard.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    @Test func collapsingIsRememberedPerThread() {
        let (defaults, suite) = Self.defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = UUID()
        let second = UUID()
        let memory = ComposerPlanCardMemory(defaults: defaults)
        #expect(!memory.isCollapsed(first))
        memory.setCollapsed(true, for: first)
        #expect(memory.isCollapsed(first))
        #expect(!memory.isCollapsed(second))

        // Another composer, as after relaunching, reads the same choice.
        let reopened = ComposerPlanCardMemory(defaults: defaults)
        #expect(reopened.isCollapsed(first))
        reopened.setCollapsed(false, for: first)
        #expect(!memory.isCollapsed(first))
        #expect(defaults.object(forKey: ComposerPlanCardMemory.key) == nil)
    }

    @Test func onlyTheMostRecentThreadsAreKept() {
        let (defaults, suite) = Self.defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let memory = ComposerPlanCardMemory(defaults: defaults)
        let ids = (0...ComposerPlanCardMemory.limit).map { _ in UUID() }
        for id in ids { memory.setCollapsed(true, for: id) }
        #expect(!memory.isCollapsed(ids[0]))
        #expect(memory.isCollapsed(ids[1]))
        #expect(memory.isCollapsed(ids[ids.count - 1]))
        // Collapsing again moves a thread to the front instead of listing it twice.
        memory.setCollapsed(true, for: ids[1])
        #expect(defaults.stringArray(forKey: ComposerPlanCardMemory.key)?.count == ComposerPlanCardMemory.limit)
        #expect(defaults.stringArray(forKey: ComposerPlanCardMemory.key)?.first == ids[1].uuidString)
    }
}

struct ComposerPlanCardTests {
    private static let longPlan = """
        # Fix the plan card

        1. Render the plan as Markdown in a card above the composer.
        2. Let the card collapse to a preview and remember that per thread.
        3. Add Open in Transcript and Copy to its header.
        4. Keep Implement, and ⌘↩ with an empty composer.
        5. Animate the height and keep the composer on screen.
        6. Localize the new strings.
        7. Test the height clamping.
        8. Render it offscreen to check the look.
        """

    @Test func aProposedPlanShowsInACardThatCollapsesPerThreadAndHides() throws {
        let folder = TemporaryDirectory("composer-plan-card")
        let suite = "CoincideTests.planCard.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let memory = ComposerPlanCardMemory(defaults: defaults)
        let store = AppStore(directory: folder.url)
        let project = store.addProject(at: folder.url)
        let id = store.createThread(in: project.id).id
        store.updateThread(id) { $0.interactionMode = .plan }
        store.append(TranscriptItem(kind: .user, text: "Plan the card"), to: id)
        let planID = store.append(TranscriptItem(kind: .plan, text: Self.longPlan), to: id)
        let registry = ProviderRegistry(store: store, providers: [])
        let runner = ThreadRunner(store: store, registry: registry)
        let composer = ComposerViewController(store: store, registry: registry, runner: runner, planCardMemory: memory)
        // At the bottom of a conversation, as the chat places it: the composer takes the height it needs.
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 760, height: 700))
        let view = composer.view
        view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        var revealed: [UUID] = []
        composer.onRevealItem = { revealed.append($0) }
        composer.threadID = id
        Self.layOut(host)

        let card = composer.planCard
        #expect(!card.isHidden)
        #expect(card.plan == Self.longPlan)
        #expect(!card.isCollapsed)
        #expect(!composer.footer.implementButton.isHidden)
        #expect(card.accessibilityLabel() == "Plan ready, Fix the plan card")
        #expect(card.canCollapse)
        let expandedHeight = card.frame.height
        #expect(expandedHeight > 120)
        #expect(expandedHeight <= ComposerPlanCardLayout.maximumHeight)

        try #require(Self.button("Collapse Plan", in: card)).performClick(nil)
        Self.layOut(host)
        #expect(card.isCollapsed)
        #expect(memory.isCollapsed(id))
        #expect(card.frame.height < expandedHeight)
        #expect(Self.button("Expand Plan", in: card) != nil)

        try #require(Self.button("Open in Transcript", in: card)).performClick(nil)
        #expect(revealed == [planID])

        // Another thread starts expanded; coming back finds this one still collapsed.
        let other = store.createThread(in: project.id).id
        composer.threadID = other
        #expect(card.isHidden)
        composer.threadID = id
        #expect(!card.isHidden)
        #expect(card.isCollapsed)

        // Hiding the card keeps Implement on offer.
        try #require(Self.button("Hide Plan", in: card)).performClick(nil)
        #expect(card.isHidden)
        #expect(!composer.footer.implementButton.isHidden)

        // A refined plan shows again.
        store.append(TranscriptItem(kind: .user, text: "Shorter, please"), to: id)
        store.append(TranscriptItem(kind: .plan, text: "# Shorter plan\n\nJust do it."), to: id)
        // A settling turn refreshes the composer; a thread change does the same here, with no runner involved.
        store.updateThread(id) { _ in }
        #expect(!card.isHidden)
        #expect(card.plan == "# Shorter plan\n\nJust do it.")
    }

    @Test func noCardOutsidePlanMode() {
        let folder = TemporaryDirectory("composer-plan-card-build")
        let store = AppStore(directory: folder.url)
        let project = store.addProject(at: folder.url)
        let id = store.createThread(in: project.id).id
        store.append(TranscriptItem(kind: .user, text: "Plan the card"), to: id)
        store.append(TranscriptItem(kind: .plan, text: Self.longPlan), to: id)
        let registry = ProviderRegistry(store: store, providers: [])
        let runner = ThreadRunner(store: store, registry: registry)
        let composer = ComposerViewController(store: store, registry: registry, runner: runner)
        _ = composer.view
        composer.threadID = id
        #expect(composer.planCard.isHidden)
        #expect(composer.footer.implementButton.isHidden)
    }

    /// Lays the view tree out. Outside a window on screen, AppKit doesn't pass a new size down on its own.
    private static func layOut(_ view: NSView) {
        func mark(_ view: NSView) {
            view.needsLayout = true
            view.subviews.forEach(mark)
        }
        for _ in 0..<3 {
            mark(view)
            view.layoutSubtreeIfNeeded()
        }
    }

    private static func button(_ label: String, in root: NSView) -> NSButton? {
        if let button = root as? NSButton, button.accessibilityLabel() == label, !button.isHidden { return button }
        return root.subviews.lazy.compactMap { button(label, in: $0) }.first
    }
}
