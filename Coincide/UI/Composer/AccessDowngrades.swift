import Foundation
import CoincideKit

/// Ends agent sessions that may still run with full access once their thread switches to Ask for approval.
///
/// Providers apply a thread's access mode when a message is sent, so a session launched with full access
/// kept it until the next message, and turns an agent started by itself in the meantime (Claude Code
/// answering a finished background task, Grok's task wakes) ran without asking while the composer said
/// Ask for approval. As T3 Code does when a thread's runtime mode changes, idle sessions end at once; the
/// thread keeps their ids, so the next message resumes them under approval. A session whose turn is
/// running ends once that turn does, and a turn it starts by itself after the switch is stopped.
final class AccessDowngrades {
    static let shared = AccessDowngrades(store: .shared, runner: .shared)

    private let store: AppStore
    private let runner: ThreadRunner
    private var token: ObservationToken?
    /// Each thread's access mode as last seen.
    private var modes: [UUID: AccessMode] = [:]
    /// Per thread, providers whose sessions may still have full access, each with the running turn it
    /// is left to finish.
    private var pending: [UUID: [ProviderKind: UUID]] = [:]

    init(store: AppStore, runner: ThreadRunner) {
        self.store = store
        self.runner = runner
    }

    /// Starts watching threads; later calls do nothing.
    func start() {
        guard token == nil else { return }
        for (id, thread) in store.threads { modes[id] = thread.accessMode }
        token = store.observe { [weak self] change in self?.handle(change) }
    }

    private func handle(_ change: StoreChange) {
        switch change {
        case .thread(let id):
            guard let mode = store.thread(id)?.accessMode else { return }
            let previous = modes.updateValue(mode, forKey: id)
            if mode == .fullAccess {
                pending[id] = nil
            } else if previous != .approval {
                // A thread not seen before counts as switched: its sessions may have been launched with full access.
                let switchedAt = Date()
                // Store changes can arrive from inside a session's own event handling; never end one there.
                DispatchQueue.main.async { [weak self] in self?.downgrade(id, switchedAt: switchedAt) }
            }
        case .runState(let id):
            guard pending[id] != nil else { return }
            DispatchQueue.main.async { [weak self] in self?.settle(id) }
        case .threadList, .projects:
            for (id, thread) in store.threads where modes[id] == nil { modes[id] = thread.accessMode }
            modes = modes.filter { store.thread($0.key) != nil }
            pending = pending.filter { store.thread($0.key) != nil }
        default:
            break
        }
    }

    /// Ends the thread's idle sessions, and marks the one running a turn to end with it.
    private func downgrade(_ threadID: UUID, switchedAt: Date) {
        guard store.thread(threadID)?.accessMode == .approval else { return }
        let running = runner.turn(threadID)
        for provider in runner.liveProviders(threadID) where provider != running?.provider {
            pending[threadID]?[provider] = nil
            runner.shutdown(threadID: threadID, provider: provider)
        }
        if pending[threadID]?.isEmpty == true { pending[threadID] = nil }
        // The running turn's session may still be starting, so it need not be among the live ones yet.
        guard let turn = running else { return }
        // Recorded first: stopping the turn below can end it, and its session, right away.
        pending[threadID, default: [:]][turn.provider] = turn.userItemID
        if turn.isAgentInitiated, turn.startedAt >= switchedAt {
            // The agent started this turn by itself after the switch, still with full access.
            runner.stop(threadID: threadID)
        }
    }

    /// Once a turn changed: ends the sessions whose turns are over.
    private func settle(_ threadID: UUID) {
        guard let providers = pending[threadID] else { return }
        guard store.thread(threadID)?.accessMode == .approval else {
            pending[threadID] = nil
            return
        }
        let turn = runner.turn(threadID)
        var remaining: [ProviderKind: UUID] = [:]
        var finished: [ProviderKind] = []
        var stopsTurn = false
        for (provider, awaited) in providers {
            guard let turn, turn.provider == provider else {
                finished.append(provider)
                continue
            }
            if turn.userItemID == awaited {
                remaining[provider] = awaited
            } else if turn.isAgentInitiated {
                // The session that kept full access started a turn by itself before it could be ended.
                remaining[provider] = turn.userItemID
                stopsTurn = true
            }
            // A message sent since then gave the session the approval mode, as every send does.
        }
        // Recorded first: ending a session or stopping a turn can report back right away.
        pending[threadID] = remaining.isEmpty ? nil : remaining
        for provider in finished { runner.shutdown(threadID: threadID, provider: provider) }
        if stopsTurn { runner.stop(threadID: threadID) }
    }
}
