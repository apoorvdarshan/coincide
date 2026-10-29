import Foundation

/// A thread moved to another project, with what it had in the old one, so the move can be undone.
public struct ThreadMove: Sendable, Equatable {
    public let threadID: UUID
    public let from: UUID
    public let to: UUID
    let sessions: [ProviderKind: ProviderSessionRef]
    let accountSessions: [String: ProviderSessionRef]?
    let branch: String?
    /// The transcript's length at the move: a longer one means turns ran in the new folder since.
    let itemCount: Int
}

extension AppStore {
    /// Whether the thread can move to the project. A thread in its own git worktree belongs to its project's
    /// repository, so it stays.
    public func canMoveThread(_ id: UUID, to projectID: UUID) -> Bool {
        guard let thread = summary(id), thread.projectID != projectID, project(projectID) != nil else { return false }
        return thread.worktreePath == nil
    }

    /// Moves a thread, with its transcript, to another project, whose folder its next turn runs in.
    ///
    /// The agents' native sessions were started in the old folder and know its files, so they are dropped: the next
    /// turn starts a new session in the new folder, which gets the conversation as a recap (`Handoff`), as after a
    /// switch to another agent. The branch shown for the thread was the old folder's and goes too. The caller ends
    /// the live sessions first (`ThreadRunner.shutdown(threadID:)`) and moves only threads that aren't running.
    @discardableResult
    public func moveThread(_ id: UUID, to projectID: UUID) -> ThreadMove? {
        guard canMoveThread(id, to: projectID), let thread = thread(id) else { return nil }
        let move = ThreadMove(
            threadID: id, from: thread.projectID, to: projectID, sessions: thread.sessions,
            accountSessions: thread.accountSessions, branch: thread.branch, itemCount: thread.items.count)
        updateThread(id) { thread in
            thread.projectID = projectID
            thread.sessions = [:]
            thread.accountSessions = nil
            thread.branch = nil
        }
        notify(.threadList)
        return move
    }

    /// Moves the thread back where it was. When no turn ran since the move, its old sessions and branch come back
    /// too, so the next turn resumes where it left off; otherwise the next turn starts afresh with a recap there as
    /// well. Returns whether the thread moved.
    @discardableResult
    public func undoMove(_ move: ThreadMove) -> Bool {
        guard let thread = summary(move.threadID), thread.projectID == move.to, canMoveThread(move.threadID, to: move.from)
        else { return false }
        let untouched = thread.itemCount == move.itemCount
        updateThread(move.threadID) { thread in
            thread.projectID = move.from
            thread.sessions = untouched ? move.sessions : [:]
            thread.accountSessions = untouched ? move.accountSessions : nil
            thread.branch = untouched ? move.branch : nil
        }
        notify(.threadList)
        return true
    }
}
