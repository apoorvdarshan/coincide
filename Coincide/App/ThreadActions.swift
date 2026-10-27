import AppKit
import CoincideKit

/// Thread and project commands shared by the sidebar, the main menu and the command palette.
/// Confirmations appear as sheets on the given window.
enum ThreadActions {
    private static var store: AppStore { .shared }

    // MARK: Threads

    /// Opens a new thread in the project, reusing an untouched one there instead of piling up empty threads.
    /// With `source`, the new thread starts in the same worktree and branch.
    @discardableResult
    static func newThread(in projectID: UUID, basedOn source: ChatThread? = nil) -> UUID? {
        guard store.project(projectID) != nil else { return nil }
        let id: UUID
        if let empty = store.threads(in: projectID).first(where: { isUntouched($0, matching: source) }) {
            id = empty.id
        } else {
            let selection = ProviderRegistry.shared.usableSelection(preferring: store.settings.defaultSelection)
            id = store.createThread(in: projectID, selection: selection).id
        }
        if let source, let thread = store.thread(id),
            thread.worktreePath != source.worktreePath || thread.branch != source.branch
        {
            store.updateThread(id) { thread in
                thread.worktreePath = source.worktreePath
                thread.branch = source.branch
            }
        }
        if store.project(projectID)?.isExpanded == false {
            store.updateProject(projectID) { $0.isExpanded = true }
        }
        AppEvents.openThread(id)
        DispatchQueue.main.async { AppEvents.post(.coincideFocusComposer) }
        return id
    }

    private static func isUntouched(_ thread: ChatThread, matching source: ChatThread?) -> Bool {
        thread.items.isEmpty && (thread.draft ?? "").isEmpty && !thread.isArchived
            && thread.worktreePath == source?.worktreePath
    }

    static func rename(_ threadID: UUID, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, store.thread(threadID)?.title != trimmed else { return }
        store.updateThread(threadID) { $0.title = trimmed }
    }

    static func togglePin(_ threadID: UUID) {
        store.updateThread(threadID) { $0.isPinned.toggle() }
    }

    /// Archiving a running thread is not allowed, as in T3; stop it first.
    static func canArchive(_ threadID: UUID) -> Bool {
        store.thread(threadID)?.isArchived == true || !ThreadRunner.shared.isRunning(threadID)
    }

    static func toggleArchived(_ threadID: UUID) {
        guard canArchive(threadID) else { return }
        store.updateThread(threadID) { $0.isArchived.toggle() }
    }

    static func markUnread(_ threadID: UUID) {
        ThreadActivity.shared.markUnread(threadID)
    }

    /// Deletes the thread, asking first unless the user turned that off.
    static func delete(_ threadID: UUID, in window: NSWindow?) {
        guard let thread = store.thread(threadID) else { return }
        let perform = {
            ThreadRunner.shared.shutdown(threadID: threadID)
            store.deleteThread(threadID)
        }
        guard store.settings.confirmBeforeDeletingThreads else {
            perform()
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Delete “\(thread.title)”?")
        alert.informativeText = String(localized: "This permanently deletes the conversation. Files on disk are not changed.")
        alert.addButton(withTitle: String(localized: "Delete")).hasDestructiveAction = true
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.showsSuppressionButton = true
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

    static func removeProject(_ projectID: UUID, in window: NSWindow?) {
        guard let project = store.project(projectID) else { return }
        let threads = store.threads(in: projectID, includeArchived: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Remove “\(project.name)”?")
        alert.informativeText =
            threads.isEmpty
            ? String(localized: "The folder and its files are not changed.")
            : String(localized: "Its \(threads.count) threads will be deleted. The folder and its files are not changed.")
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

    static func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// The folder a thread works in: its worktree, else its project folder.
    static func folder(for threadID: UUID) -> URL? { store.workingDirectory(for: threadID) }

    // MARK: Helpers

    private static func present(_ alert: NSAlert, in window: NSWindow?, completion: @escaping (Bool) -> Void) {
        if let window, window.isVisible {
            alert.beginSheetModal(for: window) { completion($0 == .alertFirstButtonReturn) }
        } else {
            completion(alert.runModal() == .alertFirstButtonReturn)
        }
    }
}
