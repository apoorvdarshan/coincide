import CoincideKit
import CoincideRemoteKit
import Foundation

/// The strip under the Mac's composer (`BranchToolbarView`), for Coincide Remote: where a thread works and on which
/// branch, and the same changes its menus offer. Before the first message the thread can stay in the project's folder,
/// move to a new worktree (started from a branch picked here) or return to a previous one; in the project's folder it
/// can switch or create branches; otherwise the branch is read only. Nothing changes while a turn runs.
extension RemoteStoreAdapter {
    func checkout(_ threadID: UUID) async throws -> RemoteCheckout {
        guard let thread = store.summary(threadID) else { throw RemoteError(.notFound, String(localized: "That thread no longer exists.")) }
        guard let cwd = store.workingDirectory(for: threadID), thread.botID == nil,
            store.project(thread.projectID)?.isChats != true
        else { return RemoteCheckout(workspace: .local) }
        let status = (try? await GitService.shared.status(cwd)) ?? .notRepository
        guard status.isRepository else { return RemoteCheckout(workspace: .local) }
        let started = thread.hasUserMessages
        let busy = worktrees.isPreparing(threadID) || runner.isRunning(threadID)
        let base = started ? nil : worktrees.baseBranch(for: threadID)
        let workspace: RemoteCheckout.Workspace = thread.worktreePath == nil ? .local : base != nil ? .newWorktree : .worktree
        let canPick = !busy && (base != nil || thread.worktreePath == nil)
        var branches: [RemoteBranch] = []
        if canPick, let list = try? await GitService.shared.branches(branchFolder(thread, base: base, cwd: cwd)) {
            branches = list.branches.prefix(RemoteCheckout.maxBranches).map { branch in
                RemoteBranch(
                    name: branch.name, isCurrent: branch.isCurrent, isRemote: branch.isRemote,
                    isCheckedOutElsewhere: branch.worktreePath != nil && !branch.isCurrent)
            }
        }
        let previous = started ? nil : worktrees.previousWorktree(for: threadID)
        return RemoteCheckout(
            workspace: workspace, canChangeWorkspace: !started && !busy, hasPreviousWorktree: previous != nil,
            previousWorktreeBranch: previous?.branch, branch: status.branch ?? thread.branch, baseBranch: base,
            canPickBranch: canPick, canCreateBranch: canPick && base == nil, branches: branches, isBusy: busy)
    }

    func changeCheckout(_ threadID: UUID, _ action: RemoteCheckoutAction) async throws -> RemoteCheckout {
        guard let thread = store.summary(threadID), let cwd = store.workingDirectory(for: threadID) else {
            throw RemoteError(.notFound, String(localized: "That thread no longer exists."))
        }
        guard !runner.isRunning(threadID), !worktrees.isPreparing(threadID) else {
            throw RemoteError(.notAllowed, String(localized: "Wait for the turn to finish before changing the checkout."))
        }
        let started = thread.hasUserMessages
        let base = started ? nil : worktrees.baseBranch(for: threadID)
        let beforeFirstMessage = RemoteError(.notAllowed, String(localized: "A thread moves to another folder only before its first message."))
        switch action {
        case .useLocal:
            guard !started else { throw beforeFirstMessage }
            await worktrees.useProjectCheckout(threadID: threadID)
        case .useNewWorktree:
            guard !started else { throw beforeFirstMessage }
            if base == nil { try await worktrees.useNewWorktree(threadID: threadID, baseBranch: nil) }
        case .usePreviousWorktree:
            guard !started, let previous = worktrees.previousWorktree(for: threadID) else { throw beforeFirstMessage }
            await worktrees.useExistingWorktree(threadID: threadID, path: previous.path, branch: previous.branch)
        case .pickBranch(let name):
            guard base != nil || thread.worktreePath == nil else {
                throw RemoteError(.notAllowed, String(localized: "This thread’s branch can’t be changed here."))
            }
            // Only a branch git listed for this folder: the phone's text never becomes a git argument of its own.
            let list = try await GitService.shared.branches(branchFolder(thread, base: base, cwd: cwd))
            guard let branch = list.branches.first(where: { $0.name == name }) else {
                throw RemoteError(.notFound, String(localized: "There’s no branch named “\(name)” here."))
            }
            if base != nil {
                try await worktrees.useNewWorktree(threadID: threadID, baseBranch: branch.name)
            } else if let path = branch.worktreePath, !branch.isCurrent {
                // Git checks a branch out in one folder at a time; before the first message the thread can move there.
                guard !started else {
                    throw RemoteError(
                        .notAllowed, String(localized: "“\(branch.name)” is checked out in another worktree. Git can check a branch out in only one folder at a time."))
                }
                await worktrees.useExistingWorktree(threadID: threadID, path: path, branch: branch.name)
            } else {
                let checkedOut = try await GitService.shared.checkout(branch.name, in: cwd)
                store.updateThread(threadID) { $0.branch = checkedOut }
            }
        case .createBranch(let name):
            guard thread.worktreePath == nil, base == nil else {
                throw RemoteError(.notAllowed, String(localized: "New branches are made in the project’s own folder."))
            }
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard Self.isAcceptableBranchName(trimmed) else {
                throw RemoteError(.badRequest, String(localized: "That isn’t a branch name git accepts."))
            }
            let created = try await GitService.shared.createBranch(trimmed, in: cwd)
            store.updateThread(threadID) { $0.branch = created }
        }
        return try await checkout(threadID)
    }

    /// A new worktree's base comes from the project's branches, not the worktree's.
    private func branchFolder(_ thread: ThreadSummary, base: String?, cwd: URL) -> URL {
        base != nil ? store.project(thread.projectID)?.url ?? cwd : cwd
    }

    /// A name git's own rules allow (`git check-ref-format`), checked before it reaches git.
    nonisolated static func isAcceptableBranchName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 200, !name.hasPrefix("-"), !name.hasPrefix("/"), !name.hasSuffix("/"),
            !name.hasSuffix("."), !name.hasSuffix(".lock"), !name.contains(".."), !name.contains("//"), !name.contains("@{"),
            name != "@"
        else { return false }
        let forbidden = CharacterSet(charactersIn: " ~^:?*[\\").union(.controlCharacters).union(.whitespacesAndNewlines)
        return name.unicodeScalars.allSatisfy { !forbidden.contains($0) }
    }
}
