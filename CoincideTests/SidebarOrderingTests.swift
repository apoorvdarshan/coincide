import Foundation
import Testing

@testable import Coincide
@testable import CoincideKit

/// The sidebar's sort orders, the Pinned section's order, collapsed sections and the automatic "Show more" cut.
@MainActor
struct SidebarOrderingTests {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func thread(
        _ title: String, created: TimeInterval, updated: TimeInterval, pinned: Bool = false, project: UUID = UUID()
    ) -> ThreadSummary {
        var thread = ChatThread(
            projectID: project, title: title, selection: ModelSelection(provider: .claude, modelID: "default"),
            isPinned: pinned, createdAt: base.addingTimeInterval(created))
        thread.updatedAt = base.addingTimeInterval(updated)
        return ThreadSummary(thread)
    }

    @Test func projectsSortManuallyByActivityOrByNameWithChatsAlwaysLast() {
        let chats = Project(name: "Chats", path: "/tmp/chats", isChats: true)
        let zed = Project(name: "zed", path: "/tmp/zed", createdAt: base)
        let app = Project(name: "App", path: "/tmp/app", createdAt: base.addingTimeInterval(10))
        let docs10 = Project(name: "docs10", path: "/tmp/docs10", createdAt: base.addingTimeInterval(20))
        let docs9 = Project(name: "docs9", path: "/tmp/docs9", createdAt: base.addingTimeInterval(30))
        // Chats in the middle, as an older projects file might hold it.
        let projects = [zed, chats, app, docs10, docs9]
        let names = { (sort: ProjectSort, activity: [UUID: Date]) in
            SidebarOrdering.sortedProjects(projects, by: sort, lastActivity: activity).map(\.name)
        }
        #expect(names(.manual, [:]) == ["zed", "App", "docs10", "docs9", "Chats"])
        // Case-insensitive, with numbers in numeric order.
        #expect(names(.name, [:]) == ["App", "docs9", "docs10", "zed", "Chats"])
        // Projects without threads count from when they were added; the busiest chat doesn't lift Chats.
        let activity = [zed.id: base.addingTimeInterval(100), app.id: base.addingTimeInterval(50), chats.id: base.addingTimeInterval(500)]
        #expect(names(.recentActivity, activity) == ["zed", "App", "docs9", "docs10", "Chats"])
    }

    @Test func lastActivityIsEachProjectsNewestThread() {
        let project = UUID()
        let other = UUID()
        let threads = [
            thread("a", created: 0, updated: 5, project: project), thread("b", created: 0, updated: 9, project: project),
            thread("c", created: 0, updated: 2, project: other),
        ]
        let activity = SidebarOrdering.lastActivity(of: threads)
        #expect(activity == [project: base.addingTimeInterval(9), other: base.addingTimeInterval(2)])
    }

    @Test func threadsSortByActivityCreationOrNameWithPinnedOnesFirst() {
        let old = thread("beta", created: 0, updated: 30)
        let new = thread("Alpha", created: 20, updated: 10)
        let middle = thread("gamma 10", created: 10, updated: 20)
        let middle2 = thread("gamma 9", created: 5, updated: 5)
        let pinned = thread("zulu", created: -10, updated: -10, pinned: true)
        let threads = [old, new, middle, middle2, pinned]
        let titles = { (sort: ThreadSort) in SidebarOrdering.sortedThreads(threads, by: sort).map(\.title) }
        #expect(titles(.recentActivity) == ["zulu", "beta", "gamma 10", "Alpha", "gamma 9"])
        #expect(titles(.created) == ["zulu", "Alpha", "gamma 10", "gamma 9", "beta"])
        #expect(titles(.name) == ["zulu", "Alpha", "beta", "gamma 9", "gamma 10"])
    }

    @Test func equalThreadsKeepAStableOrder() {
        let threads = (0..<6).map { _ in thread("Same", created: 0, updated: 0) }
        let once = SidebarOrdering.sortedThreads(threads, by: .name).map(\.id)
        #expect(SidebarOrdering.sortedThreads(threads.reversed(), by: .name).map(\.id) == once)
    }

    @Test func newlyPinnedThreadsJoinPinnedOnTopAndUnpinnedOnesLeave() {
        let kept = thread("kept", created: 0, updated: 0, pinned: true)
        let earlier = thread("earlier", created: 0, updated: 5, pinned: true)
        let fresh = thread("fresh", created: 0, updated: 1, pinned: true)
        let fresher = thread("fresher", created: 0, updated: 2, pinned: true)
        let saved = [earlier.id, UUID(), kept.id, earlier.id].map(\.uuidString) + ["not an id"]
        let order = SidebarOrdering.pinnedOrder(saved: saved, pinned: [kept, fresh, earlier, fresher])
        // New pins on top (most recently active first), then the saved order without the unpinned id or the repeat.
        #expect(order == [fresher.id, fresh.id, earlier.id, kept.id])
        #expect(SidebarOrdering.pinnedOrder(saved: order.map(\.uuidString), pinned: [kept, earlier]) == [earlier.id, kept.id])
    }

    @Test func reorderingPinnedThreadsPlacesThemBeforeTheDropTarget() {
        let ids = (0..<5).map { _ in UUID() }
        // Drag the last two before the second.
        #expect(SidebarOrdering.reordered(ids, moving: [ids[3], ids[4]], to: 1) == [ids[0], ids[3], ids[4], ids[1], ids[2]])
        // Drag the first to the end, or onto its own place.
        #expect(SidebarOrdering.reordered(ids, moving: [ids[0]], to: 5) == [ids[1], ids[2], ids[3], ids[4], ids[0]])
        #expect(SidebarOrdering.reordered(ids, moving: [ids[2]], to: 2) == ids)
        #expect(SidebarOrdering.reordered(ids, moving: [ids[2]], to: 3) == ids)
        // Out of range drops land at the ends.
        #expect(SidebarOrdering.reordered(ids, moving: [ids[4]], to: -3) == [ids[4]] + ids.prefix(4))
        #expect(SidebarOrdering.reordered(ids, moving: [ids[0]], to: 99) == Array(ids.dropFirst()) + [ids[0]])
    }

    @Test func sectionsFollowTheSavedOrderWithMissingOnesAddedInTheirDefaultOrder() {
        #expect(SidebarSection.defaultOrder == [.bots, .pinned, .projects, .chats])
        #expect(Set(SidebarSection.defaultOrder) == Set(SidebarSection.allCases))
        // Nothing saved: the default, Bots first and Chats last.
        #expect(SidebarOrdering.sectionOrder(saved: []) == [.bots, .pinned, .projects, .chats])
        #expect(SidebarOrdering.sectionOrder(saved: ["chats", "pinned", "projects"]) == [.chats, .pinned, .projects, .bots])
        // A section saved by a newer version is skipped, repeats count once, and sections not saved yet (one this
        // version added since the user reordered, say) follow in their default order.
        #expect(SidebarOrdering.sectionOrder(saved: ["agents", "chats", "chats"]) == [.chats, .bots, .pinned, .projects])
    }

    @Test func movingASectionSavesTheWholeOrderAndKeepsSectionsOfNewerVersions() {
        #expect(
            SidebarOrdering.savedSectionOrder(saved: [], moving: .chats, before: .pinned) == ["bots", "chats", "pinned", "projects"])
        #expect(
            SidebarOrdering.savedSectionOrder(saved: [], moving: .bots, before: nil) == ["pinned", "projects", "chats", "bots"])
        #expect(
            SidebarOrdering.savedSectionOrder(saved: [], moving: .projects, before: .projects) == ["bots", "pinned", "projects", "chats"])
        #expect(
            SidebarOrdering.savedSectionOrder(saved: ["agents", "projects", "pinned", "chats", "bots"], moving: .chats, before: .projects)
                == ["chats", "projects", "pinned", "bots", "agents"])
    }

    private func bot(_ name: String, created: TimeInterval) -> Bot {
        Bot(
            name: name, avatar: BotAvatar(shape: .pebble, tint: .sage), persona: "",
            selection: ModelSelection(provider: .claude, modelID: "default"), createdAt: base.addingTimeInterval(created))
    }

    @Test func botsSortManuallyByActivityOrByName() {
        let zed = bot("zed", created: 0)
        let app = bot("App", created: 10)
        let helper10 = bot("helper10", created: 20)
        let helper9 = bot("helper9", created: 30)
        // An unnamed bot sorts by the name it shows.
        let unnamed = bot("  ", created: 40)
        let bots = [zed, app, helper10, helper9, unnamed]
        let names = { (sort: BotSort, activity: [UUID: Date]) in
            SidebarOrdering.sortedBots(bots, by: sort, lastActivity: activity).map(\.displayName)
        }
        #expect(BotSort.allCases == [.manual, .recentActivity, .name])
        #expect(names(.manual, [:]) == ["zed", "App", "helper10", "helper9", "Bot"])
        // Case-insensitive, with numbers in numeric order.
        #expect(names(.name, [:]) == ["App", "Bot", "helper9", "helper10", "zed"])
        // Bots without conversations count from when they were made.
        let activity = [zed.id: base.addingTimeInterval(100), app.id: base.addingTimeInterval(35)]
        #expect(names(.recentActivity, activity) == ["zed", "Bot", "App", "helper9", "helper10"])
        // Equal activity keeps the manual order.
        let tied = [zed.id: base.addingTimeInterval(100), app.id: base.addingTimeInterval(100)]
        #expect(names(.recentActivity, tied).prefix(2) == ["zed", "App"])
    }

    @Test func aBotsLastActivityIsItsNewestUnarchivedConversation() {
        let first = UUID()
        let second = UUID()
        func conversation(_ bot: UUID?, updated: TimeInterval, archived: Bool = false) -> ThreadSummary {
            var thread = ChatThread(
                projectID: AppStore.botsProjectID, title: "c", selection: ModelSelection(provider: .claude, modelID: "default"),
                botID: bot, createdAt: base)
            thread.updatedAt = base.addingTimeInterval(updated)
            thread.isArchived = archived
            return ThreadSummary(thread)
        }
        let threads = [
            conversation(first, updated: 5), conversation(first, updated: 9), conversation(first, updated: 50, archived: true),
            conversation(second, updated: 2), conversation(nil, updated: 99),
        ]
        #expect(SidebarOrdering.lastBotActivity(of: threads) == [first: base.addingTimeInterval(9), second: base.addingTimeInterval(2)])
    }

    @Test func collapsingASectionSavesItAndKeepsSectionsOfNewerVersions() {
        #expect(SidebarOrdering.collapsedSections(saved: []).isEmpty)
        #expect(SidebarOrdering.collapsedSections(saved: ["bots", "agents", "chats", "bots"]) == [.bots, .chats])
        let collapsed = SidebarOrdering.savedCollapsedSections(saved: ["agents"], setting: .pinned, collapsed: true)
        #expect(collapsed == ["agents", "pinned"])
        // Collapsing twice saves it once; expanding removes it and leaves the rest.
        #expect(SidebarOrdering.savedCollapsedSections(saved: collapsed, setting: .pinned, collapsed: true) == collapsed)
        #expect(SidebarOrdering.savedCollapsedSections(saved: collapsed, setting: .pinned, collapsed: false) == ["agents"])
        #expect(SidebarOrdering.savedCollapsedSections(saved: ["agents"], setting: .chats, collapsed: false) == ["agents"])
    }

    @Test func collapsedSectionsAndTheBotSortSurviveRelaunchAndOlderFilesExpandEverything() throws {
        let folder = TemporaryDirectory("sidebar-collapsed-state")
        let state = UIState(directory: folder.url)
        #expect(state.values.collapsedSections.isEmpty && state.values.botSort == .manual)
        state.update { values in
            values.collapsedSections = ["projects", "bots"]
            values.botSort = .name
        }
        state.flush()
        let reopened = UIState(directory: folder.url).values
        #expect(reopened.collapsedSections == ["projects", "bots"] && reopened.botSort == .name)
        // A file from before sections could collapse, or with values this version can't read, falls back.
        let older = try JSONDecoder().decode(UIState.Values.self, from: Data(#"{"projectSort":"name"}"#.utf8))
        #expect(older.collapsedSections.isEmpty && older.botSort == .manual && older.projectSort == .name)
        let future = try JSONDecoder().decode(
            UIState.Values.self, from: Data(#"{"collapsedSections":"bots","botSort":"mood"}"#.utf8))
        #expect(future.collapsedSections.isEmpty && future.botSort == .manual)
    }

    @Test func theAutomaticCutShowsALittleMoreThanTheSidebarHolds() {
        // The cut counts the rows of projects and threads, whose height taller headers leave alone.
        #expect(SidebarMetrics.rowHeight == 28)
        // 800 points of 28-point rows hold 28; a quarter more is 35.
        #expect(SidebarOrdering.automaticThreadLimit(visibleHeight: 800) == 35)
        // Steps of five: a few points more or less leave the cut alone.
        #expect(SidebarOrdering.automaticThreadLimit(visibleHeight: 790) == 35)
        #expect(SidebarOrdering.automaticThreadLimit(visibleHeight: 1_400) == 60)
        // Never fewer than the minimum, even in a short window, and a sensible cut before the first layout.
        #expect(SidebarOrdering.automaticThreadLimit(visibleHeight: 120) == SidebarOrdering.minimumAutomaticLimit)
        #expect(SidebarOrdering.automaticThreadLimit(visibleHeight: 0) == SidebarOrdering.minimumAutomaticLimit * 2)
        #expect(SidebarOrdering.automaticThreadLimit(visibleHeight: .infinity) == SidebarOrdering.minimumAutomaticLimit * 2)
        // Far more than the old fixed six in an ordinary window.
        #expect(SidebarOrdering.automaticThreadLimit(visibleHeight: 600) > 6)
    }
}
