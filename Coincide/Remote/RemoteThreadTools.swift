import CoincideKit
import CoincideRemoteKit
import Foundation

/// What Coincide Remote does to a conversation and its composer, through the calls the Mac's transcript and composer
/// make: forking, "Edit from Here" (rewinding, with or without putting files back) and the usage-limit banner.
extension RemoteStoreAdapter {
    // MARK: Fork

    /// Forks the thread, whole or through the turn holding the item, as "Fork Thread" and "Fork from Here" do, without
    /// opening the fork in the Mac's window. Returns the fork's id.
    func forkThread(_ request: RemoteForkRequest) throws -> UUID {
        _ = try requireThread(request.threadID)
        guard ThreadForking.canFork(request.threadID, through: request.itemID, store: store, runner: runner),
            let fork = ThreadForking.fork(request.threadID, through: request.itemID, opens: false, store: store, runner: runner)
        else {
            throw RemoteError(.notAllowed, String(localized: "There’s nothing to fork yet. Wait for the turn to finish."))
        }
        return fork
    }

    // MARK: Edit from here

    /// One of the user's messages, which "Edit from Here" rewinds to.
    private func userMessage(_ itemID: UUID, in threadID: UUID) throws -> TranscriptItem {
        _ = try requireThread(threadID)
        guard let item = store.item(itemID, in: threadID), item.kind == .user else {
            throw RemoteError(.notFound, String(localized: "That message is no longer in the conversation."))
        }
        return item
    }

    func rewindOptions(_ reference: RemoteItemReference) throws -> RemoteRewindOptions {
        _ = try userMessage(reference.itemID, in: reference.threadID)
        return RemoteRewindOptions(
            canRevertFiles: services.canRestore(reference.threadID, reference.itemID), isRunning: runner.isRunning(reference.threadID))
    }

    /// Rewinds the conversation to before the message, as the Mac's "Edit from Here", putting files back first when
    /// asked; the message comes back for the phone's composer. Refused while a turn runs.
    func rewind(_ request: RemoteRewindRequest) async throws -> RemoteRewind {
        let threadID = request.threadID
        let item = try userMessage(request.itemID, in: threadID)
        let stopFirst = RemoteError(.notAllowed, String(localized: "Stop the agent before editing an earlier message."))
        guard !runner.isRunning(threadID) else { throw stopFirst }
        if request.revertsFiles {
            do {
                try await services.restore(threadID, item.id)
            } catch let error as RemoteError {
                throw error
            } catch {
                throw RemoteError(.failed, error.localizedDescription)
            }
            // An agent may have started a turn of its own while the files were put back.
            guard !runner.isRunning(threadID) else { throw stopFirst }
            _ = try userMessage(item.id, in: threadID)
        }
        store.truncate(threadID, from: item.id)
        return RemoteRewind(text: item.text, attachments: (item.attachments ?? []).map { ($0 as NSString).lastPathComponent })
    }

    // MARK: Usage-limit banner

    /// The banner the Mac's composer shows for the thread's agent: a limit window nearly or wholly used that the user
    /// hasn't dismissed, worded as on the Mac, with "Resume at Reset" when the limit stops a conversation that isn't
    /// running.
    func composerNotice(_ threadID: UUID, now: Date = Date()) throws -> RemoteComposerNotice {
        let summary = try requireThread(threadID)
        let selection = summary.selection
        guard let reported = runner.usageLimits(for: selection.provider, account: selection.accountID), !reported.windows.isEmpty,
            let warning = reported.current(at: now).warning
        else { return RemoteComposerNotice() }
        let key = UsageLimits.warningKey(for: warning, provider: selection.provider, account: selection.accountID)
        guard !store.isWarningDismissed(key) else { return RemoteComposerNotice() }
        let mode = store.settings.usageDisplayMode
        var text = UsageLimits.warningText(for: warning, provider: selection.provider, mode: mode, at: now)
        var canResume = false
        var resumesAt: Date?
        if summary.hasUserMessages, !runner.isRunning(threadID) {
            if let date = runner.scheduledResumes[threadID] {
                resumesAt = date
                text += " " + String(localized: "This thread continues at \(date.formatted(date: .omitted, time: .shortened)).")
            } else {
                canResume = runner.blockingLimitReset(for: selection.provider, account: selection.accountID, now: now) != nil
            }
        }
        return RemoteComposerNotice(
            usageWarning: RemoteUsageWarning(
                key: key, text: text, fraction: warning.barFill(mode), canResumeAtReset: canResume, resumesAt: resumesAt))
    }

    func perform(_ command: RemoteUsageWarningCommand) throws -> RemoteComposerNotice {
        let summary = try requireThread(command.threadID)
        switch command.action {
        case .dismiss:
            store.dismissWarning(command.key)
        case .resumeAtReset:
            guard !runner.isRunning(command.threadID),
                let reset = runner.blockingLimitReset(for: summary.selection.provider, account: summary.selection.accountID)
            else { throw RemoteError(.notAllowed, String(localized: "The limit doesn’t stop this thread now.")) }
            runner.resumeAtReset(command.threadID, at: reset)
        case .cancelResume:
            runner.cancelResume(command.threadID)
        case .unknown:
            throw RemoteError(.unsupported, String(localized: "This Mac doesn’t know that action."))
        }
        return try composerNotice(command.threadID)
    }
}
