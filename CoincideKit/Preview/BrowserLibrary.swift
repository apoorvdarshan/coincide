import Foundation

public nonisolated struct BrowserHistoryItem: Codable, Hashable, Sendable {
    public var url: String
    public var title: String
    public var visitCount: Int
    public var lastVisit: Date

    public init(url: String, title: String, visitCount: Int = 1, lastVisit: Date = Date()) {
        self.url = url
        self.title = title
        self.visitCount = visitCount
        self.lastVisit = lastVisit
    }
}

public nonisolated struct BrowserBookmark: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var url: String
    public var title: String
    /// Where an imported bookmark came from, such as "Chrome › Bookmarks Bar"; nil for one made in Coincide.
    public var folder: String?

    public init(id: UUID = UUID(), url: String, title: String, folder: String? = nil) {
        self.id = id
        self.url = url
        self.title = title
        self.folder = folder
    }
}

/// The browser's history and bookmarks, shared by every thread, in `browser-library.json` (readable only by the user).
/// Only http(s) addresses are kept. History is bounded; the oldest, least visited entries go first.
@MainActor
public final class BrowserLibrary {
    public static let didChange = Notification.Name("coincide.browserLibraryChanged")
    public static let historyLimit = 10_000
    public static let bookmarkLimit = 5_000

    private struct Contents: Codable {
        var history: [BrowserHistoryItem] = []
        var bookmarks: [BrowserBookmark] = []
    }

    public private(set) var history: [BrowserHistoryItem] = []
    public private(set) var bookmarks: [BrowserBookmark] = []
    private var index: [String: Int] = [:]
    private let url: URL
    private var saveScheduled = false

    public init(directory: URL) {
        url = directory.appendingPathComponent("browser-library.json")
        if let data = try? Data(contentsOf: url), let contents = try? JSONDecoder().decode(Contents.self, from: data) {
            history = contents.history
            bookmarks = contents.bookmarks
        }
        reindex()
    }

    // MARK: History

    public func recordVisit(url: URL, title: String?, at date: Date = Date()) {
        guard let address = Self.address(url) else { return }
        if let position = index[address] {
            history[position].visitCount += 1
            history[position].lastVisit = date
            if let title, !title.isEmpty { history[position].title = String(title.prefix(500)) }
        } else {
            history.append(BrowserHistoryItem(url: address, title: String((title ?? "").prefix(500)), lastVisit: date))
            index[address] = history.count - 1
        }
        trimHistory()
        changed()
    }

    /// Adds imported history, keeping the larger visit count and the later visit for addresses already known.
    /// Returns how many items were added or updated.
    @discardableResult
    public func mergeHistory(_ items: [BrowserHistoryItem]) -> Int {
        var count = 0
        for item in items {
            guard let parsed = URL(string: item.url), let address = Self.address(parsed) else { continue }
            if let position = index[address] {
                history[position].visitCount = max(history[position].visitCount, item.visitCount)
                history[position].lastVisit = max(history[position].lastVisit, item.lastVisit)
                if history[position].title.isEmpty { history[position].title = String(item.title.prefix(500)) }
            } else {
                history.append(BrowserHistoryItem(url: address, title: String(item.title.prefix(500)),
                    visitCount: max(1, item.visitCount), lastVisit: item.lastVisit))
                index[address] = history.count - 1
            }
            count += 1
        }
        trimHistory()
        changed()
        return count
    }

    public func clearHistory() {
        history.removeAll()
        reindex()
        changed()
    }

    private func trimHistory() {
        guard history.count > Self.historyLimit else { return }
        history.sort { $0.lastVisit > $1.lastVisit }
        history.removeLast(history.count - Self.historyLimit)
        reindex()
    }

    // MARK: Bookmarks

    public func isBookmarked(_ url: URL) -> Bool {
        guard let address = Self.address(url) else { return false }
        return bookmarks.contains { $0.url == address }
    }

    @discardableResult
    public func addBookmark(url: URL, title: String, folder: String? = nil) -> Bool {
        guard let address = Self.address(url), !bookmarks.contains(where: { $0.url == address }),
            bookmarks.count < Self.bookmarkLimit
        else { return false }
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        bookmarks.append(BrowserBookmark(url: address, title: String((name.isEmpty ? address : name).prefix(500)), folder: folder))
        changed()
        return true
    }

    /// Adds imported bookmarks that aren't bookmarked yet. Returns how many were added.
    @discardableResult
    public func mergeBookmarks(_ items: [BrowserBookmark]) -> Int {
        var known = Set(bookmarks.map(\.url))
        var added = 0
        for item in items where bookmarks.count < Self.bookmarkLimit {
            guard let parsed = URL(string: item.url), let address = Self.address(parsed), known.insert(address).inserted else { continue }
            bookmarks.append(BrowserBookmark(url: address, title: String((item.title.isEmpty ? address : item.title).prefix(500)),
                folder: item.folder.map { String($0.prefix(200)) }))
            added += 1
        }
        if added > 0 { changed() }
        return added
    }

    public func removeBookmark(url: URL) {
        guard let address = Self.address(url) else { return }
        removeBookmarks { $0.url == address }
    }

    public func removeBookmarks(where predicate: (BrowserBookmark) -> Bool) {
        let before = bookmarks.count
        bookmarks.removeAll(where: predicate)
        if bookmarks.count != before { changed() }
    }

    // MARK: Suggestions

    /// Addresses for what the user typed in the address bar: bookmarks first, then history by how often and how
    /// recently it was visited. Matches the address without its scheme and `www.`, or a word in the title.
    public func suggestions(for text: String, limit: Int = 8) -> [BrowserHistoryItem] {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return [] }
        let bare = Self.stripped(query)
        func matches(_ address: String, _ title: String) -> Bool {
            Self.stripped(address.lowercased()).hasPrefix(bare) || title.lowercased().contains(query)
        }
        var seen = Set<String>()
        var result: [BrowserHistoryItem] = []
        for bookmark in bookmarks where matches(bookmark.url, bookmark.title) && seen.insert(bookmark.url).inserted {
            let visited = index[bookmark.url].map { history[$0] }
            result.append(visited ?? BrowserHistoryItem(url: bookmark.url, title: bookmark.title, visitCount: 0, lastVisit: .distantPast))
        }
        let now = Date()
        let ranked = history.filter { matches($0.url, $0.title) && !seen.contains($0.url) }.sorted { score($0, now) > score($1, now) }
        result.append(contentsOf: ranked.prefix(limit))
        return Array(result.prefix(limit))
    }

    /// What to complete inline as the user types `text`: the rest of the best history or bookmark address that
    /// starts with it, keeping what the user typed (so `git` completes to `github.com/…`).
    public func inlineCompletion(for text: String) -> String? {
        let typed = text.trimmingCharacters(in: .whitespaces)
        guard typed.count >= 2, !typed.contains(" ") else { return nil }
        let lower = typed.lowercased()
        let candidates = suggestions(for: typed, limit: 20).map(\.url)
        for address in candidates {
            for form in Self.displayForms(of: address) where form.lowercased().hasPrefix(lower) && form.count > typed.count {
                return typed + form.dropFirst(typed.count)
            }
        }
        return nil
    }

    private func score(_ item: BrowserHistoryItem, _ now: Date) -> Double {
        let days = max(0, now.timeIntervalSince(item.lastVisit) / 86_400)
        return Double(item.visitCount) / (1 + days / 7)
    }

    // MARK: Storage

    /// The address kept for `url`: http(s) only, without a fragment or credentials.
    public static func address(_ url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host?.isEmpty == false,
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        components.fragment = nil
        components.user = nil
        components.password = nil
        guard let string = components.string, string.utf8.count <= 4096 else { return nil }
        return string
    }

    private static func stripped(_ text: String) -> String {
        var value = text
        for prefix in ["https://", "http://"] where value.hasPrefix(prefix) { value.removeFirst(prefix.count) }
        if value.hasPrefix("www.") { value.removeFirst(4) }
        return value
    }

    /// The ways a user might start typing an address: in full, without its scheme, and without `www.`.
    private static func displayForms(of address: String) -> [String] {
        var forms = [address]
        var bare = address
        for prefix in ["https://", "http://"] where bare.hasPrefix(prefix) { bare.removeFirst(prefix.count) }
        forms.append(bare)
        if bare.hasPrefix("www.") { forms.append(String(bare.dropFirst(4))) }
        return forms.reversed()
    }

    private func reindex() {
        index = [:]
        for (position, item) in history.enumerated() { index[item.url] = position }
    }

    private func changed() {
        NotificationCenter.default.post(name: Self.didChange, object: self)
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            MainActor.assumeIsolated { self?.flush() }
        }
    }

    /// Writes pending changes now. Called before quitting and by tests.
    public func flush() {
        saveScheduled = false
        do {
            let data = try JSONEncoder().encode(Contents(history: history, bookmarks: bookmarks))
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            NSLog("Coincide: failed to save browser history: \(error.localizedDescription)")
        }
    }
}
