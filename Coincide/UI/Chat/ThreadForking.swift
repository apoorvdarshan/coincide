import AppKit
import CoincideKit

/// T3's fork, from a turn in the conversation ("Fork from this response") or from the sidebar ("Fork
/// Thread"): a new thread in the same project with the conversation so far (see `ThreadFork`), opened at once.
enum ThreadForking {
    private static var store: AppStore { .shared }
    private static var runner: ThreadRunner { .shared }

    /// Whether the thread can be forked through the turn holding `itemID`, or through its latest settled turn.
    /// Without a turn running, a whole thread can be forked when it has any items, which its summary tells
    /// without reading the transcript (the sidebar asks this of every row).
    static func canFork(_ threadID: UUID, through itemID: UUID? = nil) -> Bool {
        guard let summary = store.summary(threadID) else { return false }
        if itemID == nil, !runner.isRunning(threadID) { return summary.itemCount > 0 }
        guard let thread = store.thread(threadID) else { return false }
        return ThreadFork.canFork(
            thread, through: itemID, runningTurnID: runner.turn(threadID)?.userItemID,
            turnOpeners: AgentTurns.shared.anchors(in: threadID))
    }

    /// Forks the thread through the turn holding `itemID` (its latest settled turn when nil) and opens the
    /// fork with the caret in its composer. Returns the fork's id.
    @discardableResult
    static func fork(_ threadID: UUID, through itemID: UUID? = nil) -> UUID? {
        let openers = AgentTurns.shared.anchors(in: threadID)
        guard
            let plan = store.forkThread(
                threadID, through: itemID, runningTurnID: runner.turn(threadID)?.userItemID, turnOpeners: openers)
        else {
            NSSound.beep()
            return nil
        }
        let forkID = plan.thread.id
        // The copies of notices that opened turns an agent started itself open turns in the fork too.
        let copiedOpeners = openers.compactMap { plan.itemIDs[$0]?.uuidString }
        if !copiedOpeners.isEmpty { UIState.shared.update { $0.agentTurns[forkID.uuidString] = copiedOpeners } }
        let projectID = plan.thread.projectID
        if store.project(projectID)?.isExpanded == false { store.updateProject(projectID) { $0.isExpanded = true } }
        AppEvents.openThread(forkID)
        DispatchQueue.main.async { AppEvents.post(.coincideFocusComposer) }
        return forkID
    }

    /// "Forked from “Title”", for tooltips. The parent's current title, or its title when it was forked
    /// once it is gone.
    static func forkedFromDescription(_ threadID: UUID) -> String? {
        guard let lineage = store.lineage(of: threadID) else { return nil }
        let title = store.summary(lineage.parentThreadID)?.title ?? lineage.parentTitle
        return String(localized: "Forked from “\(title)”")
    }
}
