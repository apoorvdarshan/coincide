import Foundation

/// A thread's open tabs as remembered across relaunches: their addresses in order and which one is selected. A tab
/// that never loaded a page is kept as an empty address. Only http(s) addresses are kept, at most
/// `PreviewCommand.tabLimit` tabs.
public nonisolated struct BrowserTabsState: Codable, Hashable, Sendable {
    public private(set) var urls: [String]
    public private(set) var selected: Int

    public init(urls: [String], selected: Int) {
        let kept = urls.prefix(PreviewCommand.tabLimit).map { address -> String in
            guard !address.isEmpty, let url = URL(string: address), let clean = BrowserLibrary.address(url) else { return "" }
            return clean
        }
        self.urls = kept.isEmpty ? [""] : Array(kept)
        self.selected = min(max(selected, 0), self.urls.count - 1)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(urls: (try? container.decode([String].self, forKey: .urls)) ?? [],
            selected: (try? container.decode(Int.self, forKey: .selected)) ?? 0)
    }

    private enum CodingKeys: String, CodingKey { case urls, selected }
}

/// Picks which loaded background tabs to unload so no more than `budget` web views stay alive: least recently used
/// first, never an active tab.
public nonisolated enum TabUnloading {
    public struct Candidate: Hashable, Sendable {
        public let id: String
        public let isActive: Bool
        public let lastUsed: Date
        public init(id: String, isActive: Bool, lastUsed: Date) {
            self.id = id
            self.isActive = isActive
            self.lastUsed = lastUsed
        }
    }

    public static let budget = 12

    public static func tabsToUnload(_ loaded: [Candidate], budget: Int = budget) -> [String] {
        guard loaded.count > budget else { return [] }
        let background = loaded.filter { !$0.isActive }.sorted { $0.lastUsed < $1.lastUsed }
        return background.prefix(loaded.count - budget).map(\.id)
    }
}
