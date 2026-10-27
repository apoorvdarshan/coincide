import Foundation

/// Where a thread runs: the project's own checkout or a worktree of its own.
///
/// Before a thread's first message the user picks T3 Code's "New worktree" mode: a worktree is
/// created on a temporary branch right away (so the first turn runs in it), and the branch is
/// renamed after what the first message asks for. Worktrees made for threads that never sent a
/// message are removed again when the user switches back or deletes the thread.
@MainActor
public final class WorktreeService {
    public static let shared = WorktreeService(store: .shared, git: .shared)

    private struct UnusedWorktree {
        var path: String
        var branch: String?
    }

    private let store: AppStore
    private let git: GitService
    private var observation: ObservationToken?
    private var preparing: Set<UUID> = []
    /// Worktrees made here for threads that have not sent a message yet.
    private var unused: [UUID: UnusedWorktree] = [:]
    /// The branch each new worktree started from, by thread.
    private var bases: [UUID: String] = [:]
    /// Threads whose temporary branch has been (or is being) named.
    private var named: Set<UUID> = []

    public init(store: AppStore, git: GitService) {
        self.store = store
        self.git = git
        observation = store.observe { [weak self] change in
            switch change {
            case .items(let threadID, _, true): self?.nameBranchAfterFirstMessage(threadID)
            case .threadList: self?.discardWorktreesOfDeletedThreads()
            default: break
            }
        }
    }

    private var prefix: String { store.settings.worktreeBranchPrefix }

    /// True while a worktree is being created or removed for the thread.
    public func isPreparing(_ threadID: UUID) -> Bool { preparing.contains(threadID) }

    /// The branch the thread's new worktree started from, when it was made in this session.
    public func baseBranch(for threadID: UUID) -> String? { bases[threadID] }

    /// The base a new worktree starts from by default: the repository's default branch, else the
    /// checked-out branch.
    public func defaultBaseBranch(in branches: GitBranchList) -> String? {
        if let name = branches.defaultBranch {
            if branches.local.contains(where: { $0.name == name }) { return name }
            if let remote = branches.remote.first(where: { $0.isDefault }) { return remote.name }
        }
        return branches.currentBranch
    }

    /// Moves a thread that has no messages into a new worktree started from `baseBranch`
    /// (the default base when nil). A worktree made here for it earlier and never used is replaced.
    public func useNewWorktree(threadID: UUID, baseBranch: String?) async throws {
        guard let thread = store.thread(threadID), !thread.hasUserMessages, let project = store.project(thread.projectID),
            !preparing.contains(threadID)
        else { return }
        setPreparing(threadID, true)
        defer { setPreparing(threadID, false) }

        if let previous = unused.removeValue(forKey: threadID), !isInUse(previous.path, besides: threadID) {
            await git.discardUnusedWorktree(URL(fileURLWithPath: previous.path), branch: previous.branch, prefix: prefix)
        }
        var base = baseBranch
        if base == nil, let branches = try? await git.branches(project.url) { base = defaultBaseBranch(in: branches) }
        let worktree = try await git.createThreadWorktree(projectPath: project.url, baseBranch: base, prefix: prefix)

        // A message sent meanwhile already runs in the project folder; leave the thread there.
        guard let current = store.thread(threadID), !current.hasUserMessages else {
            await git.discardUnusedWorktree(URL(fileURLWithPath: worktree.path), branch: worktree.branch, prefix: prefix)
            return
        }
        unused[threadID] = UnusedWorktree(path: worktree.path, branch: worktree.branch)
        bases[threadID] = base
        named.remove(threadID)
        store.updateThread(threadID) { thread in
            thread.worktreePath = worktree.path
            thread.branch = worktree.branch
        }
    }

    /// Moves a thread that has no messages back to the project folder, removing the worktree
    /// made here for it when it was never used.
    public func useProjectCheckout(threadID: UUID) async {
        guard let thread = store.thread(threadID), !thread.hasUserMessages, thread.worktreePath != nil,
            !preparing.contains(threadID)
        else { return }
        setPreparing(threadID, true)
        defer { setPreparing(threadID, false) }
        if let previous = unused.removeValue(forKey: threadID), previous.path == thread.worktreePath,
            !isInUse(previous.path, besides: threadID)
        {
            await git.discardUnusedWorktree(URL(fileURLWithPath: previous.path), branch: previous.branch, prefix: prefix)
        }
        bases[threadID] = nil
        store.updateThread(threadID) { thread in
            thread.worktreePath = nil
            thread.branch = nil
        }
    }

    /// Moves a thread that has no messages into an existing worktree, such as one another thread used.
    public func useExistingWorktree(threadID: UUID, path: String, branch: String?) async {
        guard let thread = store.thread(threadID), !thread.hasUserMessages, !preparing.contains(threadID) else { return }
        if let previous = unused.removeValue(forKey: threadID), previous.path != path,
            !isInUse(previous.path, besides: threadID)
        {
            setPreparing(threadID, true)
            await git.discardUnusedWorktree(URL(fileURLWithPath: previous.path), branch: previous.branch, prefix: prefix)
            setPreparing(threadID, false)
        }
        bases[threadID] = nil
        store.updateThread(threadID) { thread in
            thread.worktreePath = path
            thread.branch = branch
        }
    }

    /// The worktree another thread of the same project used most recently, if it still exists.
    public func previousWorktree(for threadID: UUID) -> (path: String, branch: String?)? {
        guard let thread = store.thread(threadID) else { return nil }
        let candidate = store.threads(in: thread.projectID)
            .filter { $0.id != threadID && $0.worktreePath != nil && $0.worktreePath != thread.worktreePath }
            .max { $0.updatedAt < $1.updatedAt }
        guard let candidate, let path = candidate.worktreePath, FileManager.default.fileExists(atPath: path) else {
            return nil
        }
        return (path, candidate.branch)
    }

    // MARK: Observation

    /// Whether a thread other than `threadID` is in the worktree at `path`. Such a worktree is never
    /// discarded, even when the thread it was made for never used it.
    private func isInUse(_ path: String, besides threadID: UUID?) -> Bool {
        store.threads.values.contains { $0.id != threadID && $0.worktreePath == path }
    }

    private func setPreparing(_ threadID: UUID, _ value: Bool) {
        if value { preparing.insert(threadID) } else { preparing.remove(threadID) }
        store.notify(.thread(threadID))
    }

    /// Renames a temporary worktree branch once the thread's first message is in.
    private func nameBranchAfterFirstMessage(_ threadID: UUID) {
        guard !named.contains(threadID), let thread = store.thread(threadID), let path = thread.worktreePath,
            let message = thread.items.first(where: { $0.kind == .user })?.text
        else { return }
        named.insert(threadID)
        // A message in the worktree makes it used, whichever thread it was made for.
        unused = unused.filter { $0.value.path != path }
        let prefix = prefix
        guard let branch = thread.branch, BranchNames.isTemporaryWorktreeBranch(branch, prefix: prefix) else { return }
        Task {
            guard
                let renamed = try? await git.nameWorktreeBranch(
                    branch, in: URL(fileURLWithPath: path), message: message, prefix: prefix)
            else { return }
            // Threads sharing the worktree follow the rename.
            for other in store.threads.values where other.worktreePath == path && other.branch == branch {
                store.updateThread(other.id) { $0.branch = renamed }
            }
        }
    }

    private func discardWorktreesOfDeletedThreads() {
        let deleted = unused.filter { store.thread($0.key) == nil }
        guard !deleted.isEmpty else { return }
        for threadID in deleted.keys {
            unused[threadID] = nil
            bases[threadID] = nil
        }
        let prefix = prefix
        Task {
            // Checked just before each removal, since another thread may be in the worktree.
            for worktree in deleted.values where !isInUse(worktree.path, besides: nil) {
                await git.discardUnusedWorktree(URL(fileURLWithPath: worktree.path), branch: worktree.branch, prefix: prefix)
            }
        }
    }
}
