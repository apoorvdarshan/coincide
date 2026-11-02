import CoincideRemoteKit
import Foundation

/// The Mac's thread, project, schedule and git tools. Each asks a Mac that may be too old to know it, which then says
/// so as a notice (`performNewer`).
extension RemoteClient {
    // MARK: Threads

    /// Forks a thread, whole or through the turn holding `itemID`; the fork's id.
    func forkThread(_ threadID: UUID, through itemID: UUID? = nil) async -> UUID? {
        guard case .thread(let id)? = await performNewer(.forkThread(RemoteForkRequest(threadID: threadID, itemID: itemID))) else {
            return nil
        }
        await refreshWorkspace()
        return id
    }

    func rewindOptions(_ threadID: UUID, itemID: UUID) async -> RemoteRewindOptions? {
        if DemoData.isEnabled { return RemoteRewindOptions(canRevertFiles: true) }
        guard case .rewindOptions(let options)? = await performNewer(.rewindOptions(RemoteItemReference(threadID: threadID, itemID: itemID)))
        else { return nil }
        return options
    }

    /// Rewinds the conversation to before the message and puts it back in the composer, as on the Mac.
    func rewind(_ threadID: UUID, to itemID: UUID, revertingFiles: Bool) async -> Bool {
        let request = RemoteRewindRequest(threadID: threadID, itemID: itemID, revertsFiles: revertingFiles)
        guard case .rewind(let message)? = await performNewer(.rewind(request)) else { return false }
        var draft = drafts[threadID] ?? ComposerDraft()
        draft.text = message.text
        drafts[threadID] = draft
        if !message.attachments.isEmpty {
            notice = String(localized: "The message is back in the composer. Its pictures stay on your Mac; attach them again to send them.")
        }
        return true
    }

    /// The banner over the thread's composer; nil from a Mac too old to say, which shows none.
    func composerNotice(_ threadID: UUID) async -> RemoteComposerNotice? {
        if DemoData.isEnabled { return DemoData.composerNotice }
        guard isConnected, case .composerNotice(let notice)? = try? await request(.composerNotice(threadID: threadID), timeout: .seconds(15))
        else { return nil }
        return notice
    }

    func usageWarning(_ action: RemoteUsageWarningCommand.Action, key: String, in threadID: UUID) async -> RemoteComposerNotice? {
        let command = RemoteUsageWarningCommand(threadID: threadID, key: key, action: action)
        guard case .composerNotice(let notice)? = await performNewer(.usageWarningAction(command)) else { return nil }
        return notice
    }

    // MARK: Sidebar and projects

    /// Sorts and cuts the sidebar on the Mac and here; the workspace that follows carries the change.
    func setSidebarOptions(_ options: RemoteSidebarOptions) async {
        workspace.sidebar = options
        guard await performNewer(.setSidebarOptions(options)) != nil else { return }
        await refreshWorkspace()
    }

    func projectDefaults(_ projectID: UUID) async -> RemoteProjectDefaults? {
        guard case .projectDefaults(let defaults)? = await performNewer(.projectDefaults(projectID: projectID)) else { return nil }
        return defaults
    }

    func saveProjectDefaults(_ defaults: RemoteProjectDefaults) async -> RemoteProjectDefaults? {
        guard case .projectDefaults(let saved)? = await performNewer(.saveProjectDefaults(defaults)) else { return nil }
        return saved
    }

    func removeProject(_ projectID: UUID) async {
        guard await performNewer(.removeProject(projectID: projectID)) != nil else { return }
        await refreshWorkspace()
    }

    // MARK: Scheduled tasks

    /// The Mac's scheduled tasks; nil from a Mac too old to have them (`unsupported` is true then).
    func scheduledTasks() async throws -> RemoteScheduledTasks {
        if DemoData.isEnabled { return DemoData.scheduledTasks }
        guard case .scheduledTasks(let tasks) = try await request(.scheduledTasks) else {
            throw RemoteError(.failed, String(localized: "The Mac didn’t send its scheduled tasks."))
        }
        return tasks
    }

    func saveScheduledTask(_ draft: RemoteScheduledTaskDraft) async -> RemoteScheduledTasks? {
        guard case .scheduledTasks(let tasks)? = await performNewer(.saveScheduledTask(draft)) else { return nil }
        return tasks
    }

    func scheduledTask(_ taskID: UUID, _ action: RemoteScheduledTaskCommand.Action) async -> RemoteScheduledTasks? {
        let command = RemoteScheduledTaskCommand(taskID: taskID, action: action)
        guard case .scheduledTasks(let tasks)? = await performNewer(.scheduledTaskAction(command)) else { return nil }
        if action == .runNow { await refreshWorkspace() }
        return tasks
    }

    // MARK: Git

    /// The thread's folder as git sees it; nil from a Mac too old to say, which hides the git actions.
    func gitState(_ threadID: UUID) async -> RemoteGitState? {
        if DemoData.isEnabled { return DemoData.gitState }
        guard isConnected, case .gitState(let state)? = try? await request(.gitState(threadID: threadID), timeout: .seconds(30))
        else { return nil }
        return state
    }

    /// Runs a git action on the Mac, which may take a few minutes when the agent writes the message; what it did, or
    /// nil with the Mac's reason as a notice.
    func gitAction(_ request: RemoteGitActionRequest) async -> RemoteGitActionResult? {
        do {
            guard case .gitAction(let result) = try await self.request(.gitAction(request), timeout: .seconds(600)) else { return nil }
            await refreshWorkspace()
            return result
        } catch let error as RemoteError where error.code == .unsupported {
            notice = String(localized: "Update Coincide on your Mac to do this from here.")
        } catch {
            notice = (error as? RemoteError)?.message ?? error.localizedDescription
        }
        return nil
    }

    func pullRequests(_ query: RemotePullRequestQuery) async throws -> RemotePullRequestList {
        if DemoData.isEnabled { return DemoData.pullRequests }
        guard case .pullRequests(let list) = try await request(.pullRequests(query), timeout: .seconds(60)) else {
            throw RemoteError(.failed, String(localized: "The Mac didn’t send the pull requests."))
        }
        return list
    }

    func pullRequest(_ reference: RemotePullRequestReference) async throws -> RemotePullRequestDetail {
        if DemoData.isEnabled { return DemoData.pullRequestDetail }
        guard case .pullRequest(let detail) = try await request(.pullRequest(reference), timeout: .seconds(60)) else {
            throw RemoteError(.failed, String(localized: "The Mac didn’t send the pull request."))
        }
        return detail
    }

    /// Merges, reviews, marks ready or checks out a pull request: the updated pull request, or the checkout's thread.
    func pullRequestAction(_ command: RemotePullRequestCommand) async -> RemoteResult? {
        do {
            let result = try await request(.pullRequestAction(command), timeout: .seconds(300))
            if case .thread = result { await refreshWorkspace() }
            return result
        } catch let error as RemoteError where error.code == .unsupported {
            notice = String(localized: "Update Coincide on your Mac to do this from here.")
        } catch {
            notice = (error as? RemoteError)?.message ?? error.localizedDescription
        }
        return nil
    }
}
