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

    struct Values: Codable {
        var windowFrame: String?
        var selectedThreadID: UUID?
        /// The thread list's width. (Widths saved under earlier keys, `sidebarWidth` and `threadListWidth`, are
        /// dropped so everyone starts from the current default.)
        var listWidth: Double?
        var isSidebarCollapsed = false
        var inspectorWidth: Double?
        var isInspectorOpen = false
        var terminalHeight: Double?
        var isTerminalOpen = false
        /// Bundle identifier of the app the toolbar's "Open in" button uses.
        var preferredOpenTarget: String?
        var showsArchivedThreads = false
        /// List snoozed threads too, marked with when they wake.
        var showsSnoozedThreads = false
        /// The project script run last in each project (ids as strings), which the toolbar runs with one click.
        var lastScripts: [String: String] = [:]
        /// Threads per project before the sidebar shows "Show more"; 0 shows all.
        var sidebarThreadLimit = 6
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
            terminalHeight = value(.terminalHeight, defaults.terminalHeight)
            isTerminalOpen = value(.isTerminalOpen, defaults.isTerminalOpen)
            preferredOpenTarget = value(.preferredOpenTarget, defaults.preferredOpenTarget)
            showsArchivedThreads = value(.showsArchivedThreads, defaults.showsArchivedThreads)
            showsSnoozedThreads = value(.showsSnoozedThreads, defaults.showsSnoozedThreads)
            lastScripts = value(.lastScripts, defaults.lastScripts)
            sidebarThreadLimit = value(.sidebarThreadLimit, defaults.sidebarThreadLimit)
            unseen = value(.unseen, defaults.unseen)
            agentTurns = value(.agentTurns, defaults.agentTurns)
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
