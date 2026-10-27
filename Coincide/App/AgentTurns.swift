import AppKit
import CoincideKit

/// Which notices opened turns an agent started on its own (`ThreadRunner.TurnState.isAgentInitiated`),
/// such as Claude Code answering a background task that finished.
///
/// The runner knows such a turn only while it runs. The transcript needs it afterwards too, to fold the
/// turn's work under a "Worked for…" header of its own instead of the previous message's, so the notices
/// are kept in `UIState` once seen running.
final class AgentTurns {
    static let shared = AgentTurns(store: .shared, runner: .shared)

    private let store: AppStore
    private let runner: ThreadRunner
    private var token: ObservationToken?

    init(store: AppStore, runner: ThreadRunner) {
        self.store = store
        self.runner = runner
    }

    func start() {
        token = store.observe { [weak self] change in self?.handle(change) }
        pruneDeletedThreads()
    }

    /// The notices that open agent-started turns in the thread, the running one included.
    func anchors(in threadID: UUID) -> Set<UUID> {
        var ids = Set((UIState.shared.values.agentTurns[threadID.uuidString] ?? []).compactMap(UUID.init(uuidString:)))
        if let turn = runner.turn(threadID), turn.isAgentInitiated { ids.insert(turn.userItemID) }
        return ids
    }

    /// The note of the agent-started turn running in the thread, such as "Claude Code continued on its own."
    func runningNote(in threadID: UUID) -> String? {
        guard let turn = runner.turn(threadID), turn.isAgentInitiated else { return nil }
        return store.item(turn.userItemID, in: threadID)?.text.nonBlank
    }

    // MARK: Store changes

    private func handle(_ change: StoreChange) {
        switch change {
        case .runState(let threadID):
            guard let turn = runner.turn(threadID), turn.isAgentInitiated else { return }
            record(turn.userItemID, in: threadID)
        case .items(let threadID, let changed, let appended) where changed.isEmpty && !appended:
            // Rewinding cut the transcript; forget notices that went with it.
            prune(threadID)
        case .threadList, .projects:
            pruneDeletedThreads()
        default:
            break
        }
    }

    private func record(_ itemID: UUID, in threadID: UUID) {
        let key = threadID.uuidString
        guard !(UIState.shared.values.agentTurns[key] ?? []).contains(itemID.uuidString) else { return }
        UIState.shared.update { $0.agentTurns[key, default: []].append(itemID.uuidString) }
    }

    private func prune(_ threadID: UUID) {
        let key = threadID.uuidString
        guard let ids = UIState.shared.values.agentTurns[key] else { return }
        let items = Set(store.thread(threadID)?.items.map(\.id.uuidString) ?? [])
        let kept = ids.filter(items.contains)
        guard kept.count != ids.count else { return }
        UIState.shared.update { $0.agentTurns[key] = kept.isEmpty ? nil : kept }
    }

    private func pruneDeletedThreads() {
        let stale = UIState.shared.values.agentTurns.keys.filter { key in
            UUID(uuidString: key).map { store.thread($0) == nil } ?? true
        }
        guard !stale.isEmpty else { return }
        UIState.shared.update { values in
            for key in stale { values.agentTurns[key] = nil }
        }
    }
}
