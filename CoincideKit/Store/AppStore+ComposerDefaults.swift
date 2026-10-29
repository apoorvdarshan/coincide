import Foundation

extension AppStore {
    /// Makes the thread's agent, account, model, effort, speed and access the default for new threads, once the user
    /// picks one of them in its composer. It is the same default Settings › General shows, so the last choice made in
    /// either place wins.
    ///
    /// Only the default moves: the thread keeps what it had, other existing threads keep theirs, and a project's own
    /// thread defaults still win for new threads there (`newThreadDefaults(in:)`). Changes the app makes on its own,
    /// such as a handoff falling back to another model, a restored draft, an imported session or a scheduled run,
    /// don't call this.
    public func rememberComposerChoice(of threadID: UUID) {
        guard let thread = summary(threadID) else { return }
        guard settings.defaultSelection != thread.selection || settings.defaultAccessMode != thread.accessMode else { return }
        updateSettings { settings in
            settings.defaultSelection = thread.selection
            settings.defaultAccessMode = thread.accessMode
        }
    }

    /// What a message sent while the thread's agent works does: the thread's own choice, or for a thread made before
    /// threads kept one, what the app-wide setting was then.
    public func followUpBehavior(of thread: ChatThread) -> FollowUpBehavior {
        thread.followUpBehavior ?? settings.existingThreadsFollowUpBehavior
    }

    /// The user's pick in a thread's composer: the thread keeps it, and it becomes the default for new threads, as
    /// `rememberComposerChoice` does for the model and access. Other existing threads keep theirs.
    public func setFollowUpBehavior(_ behavior: FollowUpBehavior, for threadID: UUID) {
        guard let thread = thread(threadID) else { return }
        if thread.followUpBehavior != behavior { updateThread(threadID) { $0.followUpBehavior = behavior } }
        if settings.followUpBehavior != behavior { updateSettings { $0.followUpBehavior = behavior } }
    }
}
