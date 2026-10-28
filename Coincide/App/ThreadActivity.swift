import AppKit
import CoincideKit

extension Notification.Name {
    /// A thread's pending approvals, questions or unseen result changed. userInfo["threadID"]: UUID
    static let coincideThreadActivityChanged = Notification.Name("coincide.threadActivityChanged")
}

/// What each thread needs from the user: approvals and questions waiting for an answer, and turns that ended while
/// the user was looking elsewhere. Feeds the sidebar badges, the toolbar status and the Dock badge.
final class ThreadActivity {
    static let shared = ThreadActivity(store: .shared)

    private let store: AppStore
    /// Approval item ids still waiting, per thread.
    private var pending: [UUID: Set<UUID>] = [:]
    /// Question item ids still waiting, kept separate from approvals so the Dock badge remains unchanged.
    private var pendingQuestions: [UUID: Set<UUID>] = [:]
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

    func pendingQuestionCount(_ threadID: UUID) -> Int { pendingQuestions[threadID]?.count ?? 0 }

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
        case .items(let threadID, let changedIDs, _):
            if changedIDs.isEmpty {
                recount(threadID)
            } else {
                recheck(changedIDs, in: threadID)
            }
        case .threadList, .projects:
            pruneDeletedThreads()
        default:
            break
        }
    }

    private func recheck(_ ids: [UUID], in threadID: UUID) {
        // The store has already loaded this transcript to append or edit it. Queries below never read it.
        let items = store.thread(threadID)?.items ?? []
        var approvals = pending[threadID] ?? []
        var questions = pendingQuestions[threadID] ?? []
        for id in ids {
            approvals.remove(id)
            questions.remove(id)
            // Appended and streaming items sit near the end, so search backwards.
            guard let item = items.last(where: { $0.id == id }), item.status == .waiting else { continue }
            if item.kind == .approval { approvals.insert(id) }
            if item.kind == .question { questions.insert(id) }
        }
        setPending(approvals: approvals, questions: questions, for: threadID)
    }

    private func recount(_ threadID: UUID) {
        var approvals = Set<UUID>()
        var questions = Set<UUID>()
        for item in store.thread(threadID)?.items ?? [] where item.status == .waiting {
            if item.kind == .approval { approvals.insert(item.id) }
            if item.kind == .question { questions.insert(item.id) }
        }
        setPending(approvals: approvals, questions: questions, for: threadID)
    }

    private func setPending(approvals: Set<UUID>, questions: Set<UUID>, for threadID: UUID) {
        guard (pending[threadID] ?? []) != approvals || (pendingQuestions[threadID] ?? []) != questions else { return }
        pending[threadID] = approvals.isEmpty ? nil : approvals
        pendingQuestions[threadID] = questions.isEmpty ? nil : questions
        changed(threadID)
    }

    private func pruneDeletedThreads() {
        for id in Set(pending.keys).union(pendingQuestions.keys) where !store.hasThread(id) {
            pending[id] = nil
            pendingQuestions[id] = nil
            changed(id)
        }
        let stale = UIState.shared.values.unseen.keys.filter { key in
            UUID(uuidString: key).map { !store.hasThread($0) } ?? true
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
