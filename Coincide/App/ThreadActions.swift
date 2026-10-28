import AppKit
import CoincideKit

/// Thread and project commands shared by the sidebar, the main menu and the command palette.
/// Confirmations appear as sheets on the given window.
enum ThreadActions {
    private static var store: AppStore { .shared }

    // MARK: Threads

    /// Starts a chat: a thread without a project, in Coincide's own folder.
    @discardableResult
    static func newChat() -> UUID? {
        newThread(in: store.ensureChatsProject().id)
    }

    /// Opens a new thread in the project, reusing an untouched one there instead of piling up empty threads.
    /// With `source`, the new thread starts in the same worktree and branch.
    @discardableResult
    static func newThread(in projectID: UUID, basedOn source: ThreadSummary? = nil) -> UUID? {
        newThread(in: projectID, worktreePath: source?.worktreePath, branch: source?.branch, setsFolder: source != nil)
    }

    /// Opens a new thread in the worktree at `worktreePath` on `branch`, such as one checked out for a pull request.
    @discardableResult
    static func newThread(in projectID: UUID, worktreePath: String, branch: String?) -> UUID? {
        newThread(in: projectID, worktreePath: worktreePath, branch: branch, setsFolder: true)
    }

    /// An empty thread in the same folder is reused rather than adding another. With `setsFolder` the thread runs in
    /// `worktreePath` (the project folder when nil) on `branch`.
    private static func newThread(in projectID: UUID, worktreePath: String?, branch: String?, setsFolder: Bool) -> UUID? {
        guard store.project(projectID) != nil else { return nil }
        let id: UUID
        if let empty = store.threads(in: projectID).first(where: { isUntouched($0, in: worktreePath) }) {
            id = empty.id
        } else {
            let selection = ProviderRegistry.shared.usableSelection(preferring: store.settings.defaultSelection)
            id = store.createThread(in: projectID, selection: selection).id
        }
        if setsFolder, let thread = store.summary(id), thread.worktreePath != worktreePath || thread.branch != branch {
            store.updateThread(id) { thread in
                thread.worktreePath = worktreePath
                thread.branch = branch
            }
        }
        if store.project(projectID)?.isExpanded == false {
            store.updateProject(projectID) { $0.isExpanded = true }
        }
        AppEvents.openThread(id)
        DispatchQueue.main.async { AppEvents.post(.coincideFocusComposer) }
        return id
    }

    private static func isUntouched(_ thread: ThreadSummary, in worktreePath: String?) -> Bool {
        thread.itemCount == 0 && !thread.hasDraft && !thread.isArchived
            && (thread.snoozedUntil ?? .distantPast) <= Date() && thread.worktreePath == worktreePath
    }

    static func rename(_ threadID: UUID, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, store.summary(threadID)?.title != trimmed else { return }
        store.updateThread(threadID) { $0.title = trimmed }
    }

    static func togglePin(_ threadID: UUID) {
        store.updateThread(threadID) { $0.isPinned.toggle() }
    }

    /// Archiving a running thread is not allowed, as in T3; stop it first.
    static func canArchive(_ threadID: UUID) -> Bool {
        store.summary(threadID)?.isArchived == true || !ThreadRunner.shared.isRunning(threadID)
    }

    static func toggleArchived(_ threadID: UUID) {
        guard canArchive(threadID) else { return }
        store.updateThread(threadID) { $0.isArchived.toggle() }
    }

    static func markUnread(_ threadID: UUID) {
        ThreadActivity.shared.markUnread(threadID)
    }

    /// Deletes the thread, asking first unless the user turned that off. A command still running in one of
    /// its terminals is stopped too, so that is always asked about.
    static func delete(_ threadID: UUID, in window: NSWindow?) {
        guard let thread = store.summary(threadID) else { return }
        let perform = {
            ThreadRunner.shared.shutdown(threadID: threadID)
            store.deleteThread(threadID)
        }
        let busy = busyTerminals(in: [threadID])
        guard store.settings.confirmBeforeDeletingThreads || !busy.isEmpty else {
            perform()
            return
        }
        let alert = ThemedAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Delete “\(thread.title)”?")
        var text =
            ThreadRunner.shared.isRunning(threadID)
            ? String(localized: "The agent working in it is stopped and the conversation is deleted. Files on disk are not changed.")
            : String(localized: "This permanently deletes the conversation. Files on disk are not changed.")
        if busy.count == 1 {
            text += "\n\n" + String(localized: "“\(busy[0].title)” is still running in its terminal. Deleting the thread stops it.")
        } else if busy.count > 1 {
            let names = ListFormatter.localizedString(byJoining: busy.map { "“\($0.title)”" })
            text += "\n\n" + String(localized: "\(names) are still running in its terminals. Deleting the thread stops them.")
        }
        alert.informativeText = text
        alert.addButton(withTitle: String(localized: "Delete")).hasDestructiveAction = true
        alert.addButton(withTitle: String(localized: "Cancel"))
        // "Don't ask again" never covers stopping a running command.
        alert.showsSuppressionButton = busy.isEmpty
        alert.suppressionButton?.title = String(localized: "Don’t ask again")
        present(alert, in: window) { confirmed in
            guard confirmed else { return }
            if alert.suppressionButton?.state == .on {
                store.updateSettings { $0.confirmBeforeDeletingThreads = false }
            }
            perform()
        }
    }

    // MARK: Projects

    /// Lets the user pick project folders.
    static func addProject(in window: NSWindow?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Add Project")
        panel.message = String(localized: "Choose a folder to work on with your coding agents.")
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK else { return }
            addProjects(panel.urls)
        }
        if let window {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(panel.runModal())
        }
    }

    /// Adds folders as projects, then opens the first: its latest thread when it was already added, else a new thread.
    static func addProjects(_ urls: [URL]) {
        let folders = urls.filter { url in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
        guard let first = folders.first else { return }
        let existing = Set(store.projects.map(\.path))
        let projects = folders.map { store.addProject(at: $0) }
        guard let project = projects.first else { return }
        if existing.contains(first.standardizedFileURL.path),
            let latest = store.threads(in: project.id).max(by: { $0.updatedAt < $1.updatedAt })
        {
            if !project.isExpanded { store.updateProject(project.id) { $0.isExpanded = true } }
            AppEvents.openThread(latest.id)
        } else {
            newThread(in: project.id)
        }
    }

    static func rename(project projectID: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, store.project(projectID)?.name != trimmed else { return }
        store.updateProject(projectID) { $0.name = trimmed }
    }

    /// Points a project whose folder was moved or renamed at its new place.
    static func locateProject(_ projectID: UUID, in window: NSWindow?) {
        guard let project = store.project(projectID) else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Choose")
        panel.message = String(localized: "Where is “\(project.name)” now?")
        panel.directoryURL = project.url.deletingLastPathComponent()
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url?.standardizedFileURL else { return }
            guard !store.projects.contains(where: { $0.id != projectID && $0.path == url.path }) else {
                NSSound.beep()
                return
            }
            store.relocateProject(projectID, to: url)
            RelocatedSessions.end(in: projectID)
        }
        if let window {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(panel.runModal())
        }
    }

    static func removeProject(_ projectID: UUID, in window: NSWindow?) {
        guard let project = store.project(projectID) else { return }
        let threads = store.threads(in: projectID, includeArchived: true)
        let alert = ThemedAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Remove “\(project.name)”?")
        var text =
            threads.isEmpty
            ? String(localized: "The folder and its files are not changed.")
            : String(localized: "Its \(threads.count) threads will be deleted. The folder and its files are not changed.")
        // Deleting its threads stops their terminals' shells.
        let busy = busyTerminals(in: threads.map(\.id))
        if busy.count == 1 {
            text += "\n\n" + String(localized: "“\(busy[0].title)” is still running in a terminal. Removing the project stops it.")
        } else if busy.count > 1 {
            let names = ListFormatter.localizedString(byJoining: busy.map { "“\($0.title)”" })
            text += "\n\n" + String(localized: "\(names) are still running in terminals. Removing the project stops them.")
        }
        alert.informativeText = text
        alert.addButton(withTitle: String(localized: "Remove")).hasDestructiveAction = true
        alert.addButton(withTitle: String(localized: "Cancel"))
        present(alert, in: window) { confirmed in
            guard confirmed else { return }
            for thread in threads { ThreadRunner.shared.shutdown(threadID: thread.id) }
            store.removeProject(projectID)
        }
    }

    // MARK: Files

    static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// The folder a thread works in: its worktree, else its project folder.
    static func folder(for threadID: UUID) -> URL? { store.workingDirectory(for: threadID) }

    // MARK: Helpers

    /// Terminals of the threads running a command that deleting the threads would stop.
    private static func busyTerminals(in threadIDs: [UUID]) -> [TerminalSession] {
        // `terminals(for:)` adds an empty entry for a thread without terminals; one for a deleted thread is
        // dropped with it.
        let manager = TerminalSessionManager.shared
        return threadIDs.flatMap { manager.terminals(for: $0).sessions.filter(\.isBusy) }
    }

    private static func present(_ alert: ThemedAlert, in window: NSWindow?, completion: @escaping (Bool) -> Void) {
        if let window, window.isVisible {
            alert.beginSheetModal(for: window) { completion($0 == .alertFirstButtonReturn) }
        } else {
            completion(alert.runModal() == .alertFirstButtonReturn)
        }
    }
}

/// Ends the agent sessions still running in a project's old folder after it was located somewhere else
/// (`AppStore.relocateProject`), so each thread's next turn resumes its native sessions in the new folder.
/// A turn that is running is left to finish; its sessions end when it does, before a queued message goes out.
/// Threads in their own worktree do not run in the project folder and keep their sessions.
enum RelocatedSessions {
    /// Threads whose sessions end when their running turn does.
    private static var waiting: Set<UUID> = []
    private static var observer: NSObjectProtocol?

    static func end(in projectID: UUID) {
        let runner = ThreadRunner.shared
        for thread in AppStore.shared.threads(in: projectID, includeArchived: true) where thread.worktreePath == nil {
            if runner.isRunning(thread.id) {
                waiting.insert(thread.id)
            } else {
                runner.shutdown(threadID: thread.id)
            }
        }
        guard !waiting.isEmpty, observer == nil else { return }
        // Posted on the main thread as the turn ends, before the runner sends the next queued message.
        observer = NotificationCenter.default.addObserver(
            forName: ThreadRunner.turnFinishedNotification, object: nil, queue: nil
        ) { note in
            guard let threadID = note.userInfo?["threadID"] as? UUID else { return }
            MainActor.assumeIsolated { turnFinished(threadID) }
        }
    }

    private static func turnFinished(_ threadID: UUID) {
        guard waiting.remove(threadID) != nil else { return }
        // Only the sessions: the runner is still finishing the turn and keeps the thread's queued messages.
        let runner = ThreadRunner.shared
        for provider in runner.liveProviders(threadID) { runner.shutdown(threadID: threadID, provider: provider) }
        if waiting.isEmpty, let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
    }
}
