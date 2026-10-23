import CoincideCore
import Foundation
import Observation

/// One palette row. Items run an action or open a nested view (T3 submenu).
struct PaletteItem: Identifiable {
    enum Kind {
        case action(@MainActor () -> Void)
        case submenu(PaletteView)
    }
    let id: String
    let title: String
    var subtitle: String? = nil
    /// Trailing secondary text, such as a relative timestamp.
    var detail: String? = nil
    var symbol = "command"
    let searchTerms: [String]
    /// Thread recency, used as a ranking tie-break and a first-term boost.
    var searchRecency: Double? = nil
    var shortcut: KeybindingCommand? = nil
    var isSecondary = false
    var isDisabled = false
    var isChecked = false
    /// A snippet from a matching message, shown under a thread result.
    var snippet: String? = nil
    let kind: Kind
    var isSubmenu: Bool { if case .submenu = kind { true } else { false } }
}

struct PaletteGroup: Identifiable {
    let id: String
    let title: String
    let items: [PaletteItem]
}

struct PaletteView {
    let id: String
    let title: String
    let groups: [PaletteGroup]
    var initialQuery: String? = nil
}

/// Port of T3 `CommandPalette.logic` ranking, filtering and the submenu stack.
enum CommandPaletteSearch {
    static let recentThreadLimit = 12
    static let messageSearchMinimum = 2

    /// T3 `normalizeSearchText`: NFKD, marks removed, lowercase, whitespace collapsed.
    static func normalize(_ value: String) -> String {
        let folded = value.decomposedStringWithCompatibilityMapping.unicodeScalars
            .filter { !CharacterSet.nonBaseCharacters.contains($0) }
        return String(String.UnicodeScalarView(folded)).lowercased()
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Exact 3, prefix 2, contains 1, every token present 0; nil when a token is missing.
    static func rankField(_ field: String, query: String, tokens: [String]) -> Int? {
        let field = normalize(field)
        guard !field.isEmpty, tokens.allSatisfy(field.contains) else { return nil }
        if field == query { return 3 }
        if field.hasPrefix(query) { return 2 }
        return field.contains(query) ? 1 : 0
    }

    /// Earlier search terms rank higher; a recency-ranked item's first term ranks as a group.
    static func rankItem(_ item: PaletteItem, query: String, tokens: [String]) -> Int {
        let terms = item.searchTerms.filter { !$0.isEmpty }
        for (index, term) in terms.enumerated() {
            guard let rank = rankField(term, query: query, tokens: tokens) else { continue }
            if index == 0, item.searchRecency != nil { return 1_000 + (rank == 3 ? 1 : 0) }
            return 1_000 - index * 100 + rank
        }
        return 0
    }

    /// T3 `filterCommandPaletteGroups`. `>` limits results to actions; an empty
    /// root query shows actions and recent threads; any query hides recent threads
    /// and searches projects, settings and all threads instead.
    static func filter(_ groups: [PaletteGroup], query: String, inSubmenu: Bool, projects: [PaletteItem] = [],
                       settings: [PaletteItem] = [], threads: [PaletteItem] = []) -> [PaletteGroup] {
        let actionsOnly = query.hasPrefix(">")
        let normalized = normalize(actionsOnly ? String(query.dropFirst()) : query)
        if normalized.isEmpty { return actionsOnly ? groups.filter { $0.id == "actions" } : groups }
        let tokens = normalized.split(separator: " ").map(String.init)
        var searchable = actionsOnly ? groups.filter { $0.id == "actions" } : inSubmenu ? groups : groups.filter { $0.id != "recent-threads" }
        if !inSubmenu, !actionsOnly {
            if !projects.isEmpty { searchable.append(.init(id: "projects-search", title: String(localized: "Projects"), items: projects)) }
            if !settings.isEmpty { searchable.append(.init(id: "settings-search", title: String(localized: "Settings"), items: settings)) }
            if !threads.isEmpty { searchable.append(.init(id: "threads-search", title: String(localized: "Threads"), items: threads)) }
        }
        return searchable.compactMap { group in
            let ranked = group.items.enumerated().compactMap { index, item -> (PaletteItem, Int, Int)? in
                let haystack = normalize(item.searchTerms.joined(separator: " "))
                guard tokens.allSatisfy(haystack.contains) else { return nil }
                return (item, index, rankItem(item, query: normalized, tokens: tokens))
            }.sorted { left, right in
                if left.0.isSecondary != right.0.isSecondary { return !left.0.isSecondary }
                if left.2 != right.2 { return left.2 > right.2 }
                if (left.0.searchRecency ?? 0) != (right.0.searchRecency ?? 0) { return (left.0.searchRecency ?? 0) > (right.0.searchRecency ?? 0) }
                return left.1 < right.1
            }.map(\.0)
            return ranked.isEmpty ? nil : .init(id: group.id, title: group.title, items: ranked)
        }
    }

    /// A bounded excerpt around the first case- and diacritic-insensitive match.
    static func snippet(in text: String, query: String, radius: Int = 40) -> String? {
        guard let range = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) else { return nil }
        let start = text.index(range.lowerBound, offsetBy: -radius, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: radius, limitedBy: text.endIndex) ?? text.endIndex
        let excerpt = text[start..<end].split(whereSeparator: { $0.isNewline }).joined(separator: " ")
        return (start > text.startIndex ? "…" : "") + excerpt + (end < text.endIndex ? "…" : "")
    }
}

/// Query and view stack (T3 `reduceCommandPaletteSearchState`). Pushing a view
/// starts its own query; going back restores the parent's query.
struct CommandPaletteSearchState {
    private(set) var query = ""
    private(set) var views: [(view: PaletteView, parentQuery: String)] = []
    var current: PaletteView? { views.last?.view }
    mutating func setQuery(_ value: String) { query = value }
    mutating func push(_ view: PaletteView) { views.append((view, query)); query = view.initialQuery ?? "" }
    @discardableResult mutating func back() -> Bool {
        guard let parent = views.popLast() else { return false }
        query = parent.parentQuery; return true
    }
    mutating func reset(query: String = "") { self.query = query; views.removeAll() }
}

/// The open palette for one window: its search state, highlight and item sources.
@MainActor @Observable
final class CommandPaletteModel {
    private(set) var search = CommandPaletteSearchState()
    var highlightedID: String?
    /// Increments when the text field should regain focus.
    private(set) var focusGeneration = 0
    @ObservationIgnored private let source: @MainActor (String) -> CommandPaletteSources
    @ObservationIgnored private let dismiss: @MainActor (Bool) -> Void

    init(source: @escaping @MainActor (String) -> CommandPaletteSources, dismiss: @escaping @MainActor (Bool) -> Void) {
        self.source = source; self.dismiss = dismiss
    }

    var query: String {
        get { search.query }
        set { search.setQuery(newValue); highlightedID = nil }
    }
    var placeholder: String { search.current == nil ? String(localized: "Search commands, projects and threads…") : String(localized: "Search…") }
    var breadcrumb: String? { search.current?.title }

    var groups: [PaletteGroup] {
        let sources = source(search.query)
        if let view = search.current {
            return CommandPaletteSearch.filter(view.groups, query: search.query, inSubmenu: true)
        }
        return CommandPaletteSearch.filter(sources.root, query: search.query, inSubmenu: false,
                                           projects: sources.projects, settings: sources.settings, threads: sources.threads)
    }
    /// Enabled items in display order; the first nine take ⌘1–⌘9.
    var selectableItems: [PaletteItem] { groups.flatMap(\.items).filter { !$0.isDisabled } }
    var highlighted: PaletteItem? {
        let items = selectableItems
        return items.first { $0.id == highlightedID } ?? items.first
    }

    func move(_ offset: Int) {
        let items = selectableItems
        guard !items.isEmpty else { return }
        let current = items.firstIndex { $0.id == highlighted?.id } ?? 0
        highlightedID = items[min(max(0, current + offset), items.count - 1)].id
    }
    func activateHighlighted() { if let highlighted { activate(highlighted) } }
    /// One-based number selection, as with ⌘1–⌘9.
    @discardableResult func activate(number: Int) -> Bool {
        let items = selectableItems
        guard (1...9).contains(number), items.indices.contains(number - 1) else { return false }
        activate(items[number - 1]); return true
    }
    func activate(_ item: PaletteItem) {
        guard !item.isDisabled else { return }
        switch item.kind {
        case .submenu(let view): search.push(view); highlightedID = nil; focusGeneration += 1
        case .action(let run): dismiss(true); run()
        }
    }
    /// Delete on an empty query, or Escape inside a submenu, returns to the parent view.
    @discardableResult func back() -> Bool {
        guard search.back() else { return false }
        highlightedID = nil; focusGeneration += 1; return true
    }
    func open(view: PaletteView) { search.reset(); search.push(view); highlightedID = nil; focusGeneration += 1 }
    /// ⌘K while open from another surface restarts at the root.
    func reset() { search.reset(); highlightedID = nil; focusGeneration += 1 }
    func close() { dismiss(true) }
}

struct CommandPaletteSources {
    var root: [PaletteGroup] = []
    var projects: [PaletteItem] = []
    var settings: [PaletteItem] = []
    var threads: [PaletteItem] = []
}
