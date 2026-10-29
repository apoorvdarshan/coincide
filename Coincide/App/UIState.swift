import AppKit
import CoincideKit

/// Interface state that belongs to this Mac rather than to the user's projects: window layout, the
/// open thread, the preferred "Open in" app, which threads finished while the user looked away, and
/// which turns agents started on their own.
/// Stored beside the store's data, so `COINCIDE_DATA_DIR` keeps test runs apart from real use.
final class UIState {
    static let shared = UIState(directory: AppStore.shared.directory)

    /// A turn result the user has not looked at yet.
    enum Unseen: String, Codable {
        case completed
        case failed
    }

    /// What the inspector column at the window's right shows.
    enum InspectorPanel: String, Codable {
        case diff
        case pullRequests
        case preview
    }

    struct Values: Codable {
        var windowFrame: String?
        var selectedThreadID: UUID?
        /// The thread list's width. (Widths saved under earlier keys, `sidebarWidth` and `threadListWidth`, are
        /// dropped so everyone starts from the current default.)
        var listWidth: Double?
        var isSidebarCollapsed = false
        var inspectorWidth: Double?
        var isInspectorOpen = false
        var inspectorPanel = InspectorPanel.diff
        var diffLayout: DiffLayout = .unified
        /// Last page for each thread; browser storage and agent capabilities are never persisted.
        var previewAddresses: [String: String] = [:]
        var terminalHeight: Double?
        var isTerminalOpen = false
        /// Bundle identifier of the app the toolbar's "Open in" button uses.
        var preferredOpenTarget: String?
        var showsArchivedThreads = false
        /// List snoozed threads too, marked with when they wake.
        var showsSnoozedThreads = false
        var showsSettledThreads = false
        /// A settled conversation returns when new activity is newer than this timestamp.
        var settledThreads: [String: Date] = [:]
        /// The project script run last in each project (ids as strings), which the toolbar runs with one click.
        var lastScripts: [String: String] = [:]
        /// Threads per project before the sidebar shows "Show more": nil fits the list to the sidebar's height
        /// (`SidebarOrdering.automaticThreadLimit`), 0 shows all. A limit saved under the earlier key,
        /// `sidebarThreadLimit`, carries over unless it was that version's default, 6, which few chose.
        var sidebarThreadsPerProject: Int?
        var projectSort = ProjectSort.manual
        var threadSort = ThreadSort.recentActivity
        /// How Chats, the project-free threads, are sorted.
        var chatSort = ThreadSort.recentActivity
        var botSort = BotSort.recentActivity
        /// Whether the user picked the bot sort. Files from before it defaulted to recent activity saved the old
        /// default, manual, which only counts when chosen.
        var choseBotSort = false
        /// The Pinned section's order (thread ids), most recently pinned first. Threads pinned elsewhere (or before
        /// this order was kept) join at the top as the sidebar notices them.
        var pinnedThreads: [String] = []
        /// The sidebar's sections in the order the user dragged them into (`SidebarSection` raw values); empty until
        /// they do, so new sections take their default place (`SidebarOrdering.sectionOrder`).
        var sidebarSections: [String] = []
        /// Sidebar sections the user collapsed to their header (`SidebarSection` raw values). Files from before
        /// sections could collapse have none, so every section starts expanded.
        var collapsedSections: [String] = []
        /// Keyed by thread id.
        var unseen: [String: Unseen] = [:]
        /// Ids of the notices that opened turns an agent started on its own, keyed by thread id (see `AgentTurns`).
        var agentTurns: [String: [String]] = [:]

        init() {}

        init(from decoder: Decoder) throws {
            let defaults = Values()
            let container = try decoder.container(keyedBy: CodingKeys.self)
            func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
                (try? container.decodeIfPresent(T.self, forKey: key)) ?? fallback
            }
            windowFrame = value(.windowFrame, defaults.windowFrame)
            selectedThreadID = value(.selectedThreadID, defaults.selectedThreadID)
            listWidth = value(.listWidth, defaults.listWidth)
            isSidebarCollapsed = value(.isSidebarCollapsed, defaults.isSidebarCollapsed)
            inspectorWidth = value(.inspectorWidth, defaults.inspectorWidth)
            isInspectorOpen = value(.isInspectorOpen, defaults.isInspectorOpen)
            inspectorPanel = value(.inspectorPanel, defaults.inspectorPanel)
            diffLayout = value(.diffLayout, defaults.diffLayout)
            previewAddresses = value(.previewAddresses, defaults.previewAddresses)
            terminalHeight = value(.terminalHeight, defaults.terminalHeight)
            isTerminalOpen = value(.isTerminalOpen, defaults.isTerminalOpen)
            preferredOpenTarget = value(.preferredOpenTarget, defaults.preferredOpenTarget)
            showsArchivedThreads = value(.showsArchivedThreads, defaults.showsArchivedThreads)
            showsSnoozedThreads = value(.showsSnoozedThreads, defaults.showsSnoozedThreads)
            showsSettledThreads = value(.showsSettledThreads, defaults.showsSettledThreads)
            settledThreads = value(.settledThreads, defaults.settledThreads)
            lastScripts = value(.lastScripts, defaults.lastScripts)
            if container.contains(.sidebarThreadsPerProject) {
                sidebarThreadsPerProject = value(.sidebarThreadsPerProject, defaults.sidebarThreadsPerProject)
            } else {
                let legacy = try? decoder.container(keyedBy: LegacyKeys.self).decodeIfPresent(Int.self, forKey: .sidebarThreadLimit)
                sidebarThreadsPerProject = legacy.flatMap { $0 == 6 || $0 < 0 ? nil : $0 }
            }
            projectSort = value(.projectSort, defaults.projectSort)
            threadSort = value(.threadSort, defaults.threadSort)
            chatSort = value(.chatSort, defaults.chatSort)
            choseBotSort = value(.choseBotSort, defaults.choseBotSort)
            botSort = choseBotSort ? value(.botSort, defaults.botSort) : defaults.botSort
            pinnedThreads = value(.pinnedThreads, defaults.pinnedThreads)
            sidebarSections = value(.sidebarSections, defaults.sidebarSections)
            collapsedSections = value(.collapsedSections, defaults.collapsedSections)
            unseen = value(.unseen, defaults.unseen)
            agentTurns = value(.agentTurns, defaults.agentTurns)
        }

        private enum LegacyKeys: String, CodingKey {
            case sidebarThreadLimit
        }
    }

    private(set) var values: Values
    private let url: URL
    private var saveScheduled = false

    init(directory: URL) {
        url = directory.appendingPathComponent("ui-state.json")
        if let data = try? Data(contentsOf: url), let decoded = try? JSONDecoder().decode(Values.self, from: data) {
            values = decoded
        } else {
            values = Values()
        }
    }

    func update(_ mutate: (inout Values) -> Void) {
        mutate(&values)
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.saveScheduled else { return }
            self.flush()
        }
    }

    /// Writes pending changes now. Called before quitting.
    func flush() {
        saveScheduled = false
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(values).write(to: url, options: .atomic)
        } catch {
            NSLog("Coincide: failed to save interface state: \(error)")
        }
    }
}
