import Foundation
import CoincideKit

/// How the sidebar orders projects.
enum ProjectSort: String, Codable, CaseIterable {
    /// The order the user dragged them into.
    case manual
    /// The project with the latest thread activity first.
    case recentActivity
    case name

    var title: String {
        switch self {
        case .manual: String(localized: "Manual")
        case .recentActivity: String(localized: "Recent Activity")
        case .name: String(localized: "Name")
        }
    }
}

/// How the sidebar orders bots.
enum BotSort: String, Codable, CaseIterable {
    /// The order the user dragged them into, kept in `bots.json`.
    case manual
    /// The bot with the latest conversation activity first.
    case recentActivity
    case name

    var title: String {
        switch self {
        case .manual: String(localized: "Manual")
        case .recentActivity: String(localized: "Recent Activity")
        case .name: String(localized: "Name")
        }
    }
}

/// How the sidebar orders the threads of a project, or of Chats.
enum ThreadSort: String, Codable, CaseIterable {
    case recentActivity
    /// Newest first.
    case created
    case name

    var title: String {
        switch self {
        case .recentActivity: String(localized: "Recent Activity")
        case .created: String(localized: "Date Created")
        case .name: String(localized: "Name")
        }
    }
}

/// The sidebar's top-level sections, which the user can drag into any order. A new kind of section joins
/// `defaultOrder`; people who already reordered theirs find it at the end.
enum SidebarSection: String, CaseIterable {
    case bots
    case pinned
    case projects
    case chats

    /// The order before the user changes it.
    static let defaultOrder: [SidebarSection] = [.bots, .pinned, .projects, .chats]
}

/// The sidebar's row sizes, shared by the outline and the automatic "Show more" cut.
enum SidebarMetrics {
    /// A project's or a thread's row.
    static let rowHeight: CGFloat = 28
    /// A section's header: room above it to set it apart from the section before.
    static let sectionHeaderHeight: CGFloat = 36
    /// The first section's header, which has only the search row above it.
    static let firstSectionHeaderHeight: CGFloat = 30
}

/// The sidebar's ordering rules, kept apart from the outline so they can be tested on their own.
enum SidebarOrdering {
    /// The sections in the saved order (raw values, so a section of a newer version survives in the file), then any
    /// not saved yet in their default order.
    static func sectionOrder(saved: [String]) -> [SidebarSection] {
        var order: [SidebarSection] = []
        for section in saved.compactMap(SidebarSection.init(rawValue:)) where !order.contains(section) {
            order.append(section)
        }
        return order + SidebarSection.defaultOrder.filter { !order.contains($0) }
    }

    /// What to save after the user moved `section` before `target` (to the end without one). Sections this version
    /// doesn't know keep their place at the end.
    static func savedSectionOrder(saved: [String], moving section: SidebarSection, before target: SidebarSection?) -> [String] {
        let order = sectionOrder(saved: saved)
        let index = target.flatMap { order.firstIndex(of: $0) } ?? order.count
        let unknown = saved.filter { SidebarSection(rawValue: $0) == nil }
        return reordered(order, moving: [section], to: index).map(\.rawValue) + unknown
    }

    /// The collapsed sections among the saved raw values; ones this version doesn't know are ignored.
    static func collapsedSections(saved: [String]) -> Set<SidebarSection> {
        Set(saved.compactMap(SidebarSection.init(rawValue:)))
    }

    /// What to save after `section` was collapsed or expanded. Sections this version doesn't know keep their state.
    static func savedCollapsedSections(saved: [String], setting section: SidebarSection, collapsed: Bool) -> [String] {
        let others = saved.filter { $0 != section.rawValue }
        return collapsed ? others + [section.rawValue] : others
    }

    /// Bots in `sort` order. Ties keep the manual order.
    static func sortedBots(_ bots: [Bot], by sort: BotSort, lastActivity: [UUID: Date]) -> [Bot] {
        switch sort {
        case .manual:
            return bots
        case .recentActivity:
            // A bot without conversations counts from when it was made.
            return bots.enumerated().sorted { lhs, rhs in
                let left = lastActivity[lhs.element.id] ?? lhs.element.createdAt
                let right = lastActivity[rhs.element.id] ?? rhs.element.createdAt
                return left != right ? left > right : lhs.offset < rhs.offset
            }.map(\.element)
        case .name:
            return bots.enumerated().sorted { lhs, rhs in
                let order = lhs.element.displayName.localizedStandardCompare(rhs.element.displayName)
                return order != .orderedSame ? order == .orderedAscending : lhs.offset < rhs.offset
            }.map(\.element)
        }
    }

    /// The latest activity among each bot's conversations, as its row shows: archived ones are left out.
    static func lastBotActivity(of threads: some Sequence<ThreadSummary>) -> [UUID: Date] {
        threads.reduce(into: [:]) { latest, thread in
            guard let bot = thread.botID, !thread.isArchived else { return }
            latest[bot] = max(latest[bot] ?? .distantPast, thread.updatedAt)
        }
    }

    /// Projects in `sort` order. Chats stay last whatever the order.
    static func sortedProjects(_ projects: [Project], by sort: ProjectSort, lastActivity: [UUID: Date]) -> [Project] {
        let (chats, others) = (projects.filter(\.isChats), projects.filter { !$0.isChats })
        let sorted: [Project]
        switch sort {
        case .manual:
            sorted = others
        case .recentActivity:
            // A project without threads counts from when it was added.
            sorted = others.enumerated().sorted { lhs, rhs in
                let left = lastActivity[lhs.element.id] ?? lhs.element.createdAt
                let right = lastActivity[rhs.element.id] ?? rhs.element.createdAt
                return left != right ? left > right : lhs.offset < rhs.offset
            }.map(\.element)
        case .name:
            sorted = others.enumerated().sorted { lhs, rhs in
                let order = lhs.element.name.localizedStandardCompare(rhs.element.name)
                return order != .orderedSame ? order == .orderedAscending : lhs.offset < rhs.offset
            }.map(\.element)
        }
        return sorted + chats
    }

    /// The latest activity among each project's threads, archived ones included.
    static func lastActivity(of threads: some Sequence<ThreadSummary>) -> [UUID: Date] {
        threads.reduce(into: [:]) { latest, thread in
            latest[thread.projectID] = max(latest[thread.projectID] ?? .distantPast, thread.updatedAt)
        }
    }

    /// Threads in `sort` order, pinned ones first. Ties fall back to the most recent activity, then the id, so the
    /// order never flickers between rebuilds.
    static func sortedThreads(_ threads: [ThreadSummary], by sort: ThreadSort) -> [ThreadSummary] {
        threads.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
            switch sort {
            case .recentActivity:
                break
            case .created:
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
            case .name:
                let order = lhs.title.localizedStandardCompare(rhs.title)
                if order != .orderedSame { return order == .orderedAscending }
            }
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    /// The Pinned section's order: `saved` without threads no longer pinned, and threads pinned since (or before the
    /// order was kept) on top, most recently active first.
    static func pinnedOrder(saved: [String], pinned: [ThreadSummary]) -> [UUID] {
        let pinnedIDs = Set(pinned.map(\.id))
        var seen = Set<UUID>()
        let kept = saved.compactMap(UUID.init(uuidString:)).filter { pinnedIDs.contains($0) && seen.insert($0).inserted }
        let added = sortedThreads(pinned.filter { !seen.contains($0.id) }, by: .recentActivity).map(\.id)
        return added + kept
    }

    /// `order` with `moved` placed before the item now at `index` (or at the end), keeping their relative order.
    static func reordered<ID: Hashable>(_ order: [ID], moving moved: [ID], to index: Int) -> [ID] {
        let movedSet = Set(moved)
        let before = order.prefix(max(0, min(index, order.count))).filter { !movedSet.contains($0) }.count
        var rest = order.filter { !movedSet.contains($0) }
        rest.insert(contentsOf: order.filter(movedSet.contains), at: min(before, rest.count))
        return rest
    }

    /// The fewest threads a list shows before "Show more" when the cut follows the sidebar's height.
    static let minimumAutomaticLimit = 10

    /// Threads a list shows before "Show more" when the cut follows the sidebar: a little more than fill its visible
    /// height, in steps of five so small changes to the window's size don't move the cut.
    static func automaticThreadLimit(visibleHeight: CGFloat, rowHeight: CGFloat = SidebarMetrics.rowHeight) -> Int {
        guard visibleHeight.isFinite, visibleHeight > 0, rowHeight > 0 else { return minimumAutomaticLimit * 2 }
        let rows = Int((visibleHeight * 1.25 / rowHeight).rounded(.down))
        return max(minimumAutomaticLimit, rows / 5 * 5)
    }
}
