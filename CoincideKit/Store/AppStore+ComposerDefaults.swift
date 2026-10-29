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
}
