import Foundation

/// Browser-style thread history for `navigation.back` / `navigation.forward`.
/// Visiting a new thread clears forward history; navigation skips threads that
/// are gone or hidden, and history-driven selection does not record a new visit.
struct ThreadNavigationHistory: Equatable {
    static let limit = 50
    private(set) var back: [UUID] = []
    private(set) var forward: [UUID] = []
    private(set) var current: UUID?

    mutating func visit(_ id: UUID?) {
        guard id != current else { return }
        if let current, back.last != current { back.append(current) }
        if back.count > Self.limit { back.removeFirst(back.count - Self.limit) }
        if id != nil { forward.removeAll() }
        current = id
    }

    func canGoBack(isValid: (UUID) -> Bool) -> Bool { back.contains { $0 != current && isValid($0) } }
    func canGoForward(isValid: (UUID) -> Bool) -> Bool { forward.contains { $0 != current && isValid($0) } }

    /// Moves to the newest valid earlier thread, dropping stale entries on the way.
    mutating func goBack(isValid: (UUID) -> Bool) -> UUID? {
        while let candidate = back.popLast() {
            guard candidate != current, isValid(candidate) else { continue }
            if let current, forward.last != current { forward.append(current) }
            if forward.count > Self.limit { forward.removeFirst(forward.count - Self.limit) }
            current = candidate
            return candidate
        }
        return nil
    }
    mutating func goForward(isValid: (UUID) -> Bool) -> UUID? {
        while let candidate = forward.popLast() {
            guard candidate != current, isValid(candidate) else { continue }
            if let current, back.last != current { back.append(current) }
            current = candidate
            return candidate
        }
        return nil
    }
}

/// T3 `closedViewStore` for the native inspector: a per-window LIFO of closed
/// inspector views. Terminals are excluded, as in T3.
struct ClosedViewEntry: Equatable {
    let threadID: UUID
    let workspacePath: String
    let tab: InspectorTab
    var filePath: String? = nil
    var line: Int? = nil
}

enum ReopenOwnerState: Equatable {
    /// The thread, project or workspace no longer exists.
    case missing
    /// The owner exists but its workspace cannot be opened yet; keep the entry.
    case notReady
    case ready(alreadyOpen: Bool)
}

struct ClosedViewHistory: Equatable {
    static let limit = 20
    private(set) var entries: [ClosedViewEntry] = []

    mutating func record(_ entry: ClosedViewEntry) {
        entries.removeAll { $0 == entry }
        entries.append(entry)
        if entries.count > Self.limit { entries.removeFirst(entries.count - Self.limit) }
    }

    /// T3 `planNextReopen`, newest first: drop missing or already-open entries,
    /// stop at one that is not ready yet, and restore the first available one.
    static func plan(_ entries: [ClosedViewEntry], owner: (ClosedViewEntry) -> ReopenOwnerState) -> (drop: [ClosedViewEntry], restore: ClosedViewEntry?) {
        var drop: [ClosedViewEntry] = []
        for entry in entries.reversed() {
            switch owner(entry) {
            case .missing, .ready(alreadyOpen: true): drop.append(entry)
            case .notReady: return (drop, nil)
            case .ready(alreadyOpen: false): return (drop, entry)
            }
        }
        return (drop, nil)
    }

    /// Applies a plan: removes dropped entries and the restored one.
    mutating func takeNext(owner: (ClosedViewEntry) -> ReopenOwnerState) -> ClosedViewEntry? {
        let plan = Self.plan(entries, owner: owner)
        entries.removeAll { entry in plan.drop.contains(entry) || entry == plan.restore }
        return plan.restore
    }
    var isEmpty: Bool { entries.isEmpty }
}

enum InspectorTab: String, CaseIterable, Sendable {
    case changes = "Changes", files = "Files"
}

/// A one-shot request for the window's inspector: select a tab, optionally a
/// file search mode, and focus its search field.
struct InspectorRequest: Equatable {
    let id = UUID()
    let tab: InspectorTab
    var searchMode: WorkspaceFileSearchMode? = nil
    var focusSearch = false
}
