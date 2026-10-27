import AppKit
import CoincideKit

extension Notification.Name {
    /// A thread's pending approvals or unseen result changed. userInfo["threadID"]: UUID
    static let coincideThreadActivityChanged = Notification.Name("coincide.threadActivityChanged")
}

/// What each thread needs from the user: approvals waiting for an answer, and turns that ended while
/// the user was looking elsewhere. Feeds the sidebar badges, the toolbar status and the Dock badge.
final class ThreadActivity {
    static let shared = ThreadActivity(store: .shared)

    private let store: AppStore
    /// Approval item ids still waiting, per thread.
    private var pending: [UUID: Set<UUID>] = [:]
    private var token: ObservationToken?

    /// The thread shown in the main window. Its results count as seen while Coincide is active.
    var visibleThreadID: UUID? {
        didSet { markVisibleThreadSeen() }
    }

    init(store: AppStore) {
        self.store = store
    }

    func start() {
        token = store.observe { [weak self] change in self?.handle(change) }
        NotificationCenter.default.addObserver(
            self, selector: #selector(applicationDidBecomeActive), name: NSApplication.didBecomeActiveNotification,
            object: nil)
        pruneDeletedThreads()
    }

    // MARK: Queries

    func pendingApprovalCount(_ threadID: UUID) -> Int { pending[threadID]?.count ?? 0 }

    var totalPendingApprovals: Int { pending.values.reduce(0) { $0 + $1.count } }

    func unseen(_ threadID: UUID) -> UIState.Unseen? { UIState.shared.values.unseen[threadID.uuidString] }

    // MARK: Updates

    func turnFinished(_ threadID: UUID, outcome: TurnOutcome) {
        let result: UIState.Unseen
        switch outcome {
        case .completed: result = .completed
        case .failed: result = .failed
        case .interrupted: return
        }
        if threadID == visibleThreadID && NSApp.isActive { return }
        setUnseen(result, for: threadID)
    }

    /// "Mark as Unread": shows the thread as having a result to look at.
    func markUnread(_ threadID: UUID) {
        setUnseen(unseen(threadID) ?? .completed, for: threadID)
    }

    func markSeen(_ threadID: UUID) {
        guard unseen(threadID) != nil else { return }
        UIState.shared.update { $0.unseen[threadID.uuidString] = nil }
        changed(threadID)
    }

    private func setUnseen(_ value: UIState.Unseen, for threadID: UUID) {
        guard unseen(threadID) != value else { return }
        UIState.shared.update { $0.unseen[threadID.uuidString] = value }
        changed(threadID)
    }

    private func markVisibleThreadSeen() {
        guard let id = visibleThreadID, NSApp.isActive else { return }
        markSeen(id)
    }

    @objc private func applicationDidBecomeActive() {
        markVisibleThreadSeen()
    }

    // MARK: Store changes

    private func handle(_ change: StoreChange) {
        switch change {
        case .items(let threadID, let changedIDs, let appended):
            if appended {
                trackAppended(changedIDs, in: threadID)
            } else if changedIDs.isEmpty {
                recount(threadID)
            } else if let waiting = pending[threadID], !waiting.isDisjoint(with: changedIDs) {
                recheck(waiting.intersection(changedIDs), in: threadID)
            }
        case .threadList, .projects:
            pruneDeletedThreads()
        default:
            break
        }
    }

    private func trackAppended(_ ids: [UUID], in threadID: UUID) {
        guard let items = store.thread(threadID)?.items else { return }
        var added = false
        for id in ids {
            // Appended items sit at the end, so search backwards.
            guard let item = items.last(where: { $0.id == id }), item.kind == .approval, item.status == .waiting else {
                continue
            }
            pending[threadID, default: []].insert(id)
            added = true
        }
        if added { changed(threadID) }
    }

    private func recheck(_ ids: Set<UUID>, in threadID: UUID) {
        let items = store.thread(threadID)?.items ?? []
        var waiting = pending[threadID] ?? []
        for id in ids {
            let item = items.last { $0.id == id }
            if item?.status != .waiting { waiting.remove(id) }
        }
        setPending(waiting, for: threadID)
    }

    private func recount(_ threadID: UUID) {
        let ids = store.thread(threadID)?.items.filter { $0.kind == .approval && $0.status == .waiting }.map(\.id) ?? []
        setPending(Set(ids), for: threadID)
    }

    private func setPending(_ ids: Set<UUID>, for threadID: UUID) {
        let before = pending[threadID] ?? []
        guard before != ids else { return }
        pending[threadID] = ids.isEmpty ? nil : ids
        changed(threadID)
    }

    private func pruneDeletedThreads() {
        for id in pending.keys where store.thread(id) == nil {
            pending[id] = nil
            changed(id)
        }
        let stale = UIState.shared.values.unseen.keys.filter { key in
            UUID(uuidString: key).map { store.thread($0) == nil } ?? true
        }
        if !stale.isEmpty {
            UIState.shared.update { values in
                for key in stale { values.unseen[key] = nil }
            }
        }
    }

    private func changed(_ threadID: UUID) {
        let total = totalPendingApprovals
        NSApp.dockTile.badgeLabel = total > 0 ? total.formatted() : nil
        NotificationCenter.default.post(name: .coincideThreadActivityChanged, object: nil, userInfo: ["threadID": threadID])
    }
}
