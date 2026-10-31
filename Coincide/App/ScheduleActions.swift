import AppKit
import CoincideKit

/// What the user does to schedules, from the thread's clock popup, the Scheduled panel, menus and approval cards.
enum ScheduleActions {
    private static var service: ScheduledTasks { .shared }
    private static var store: AppStore { .shared }

    /// The window sheets open over: the main window.
    private static var window: NSWindow? {
        (NSApp.delegate as? AppDelegate)?.mainWindow?.window ?? NSApp.keyWindow
    }

    /// A new schedule that sends `prompt` into the thread, opening the editor. `onSaved` runs once it is saved.
    static func newSchedule(inThread threadID: UUID, prompt: String = "", in window: NSWindow? = nil, onSaved: (() -> Void)? = nil) {
        guard let thread = store.summary(threadID) else { return }
        var task = ScheduledTask(
            name: "", projectID: thread.projectID, prompt: prompt, recurrence: TaskRecurrence(), threadID: threadID)
        task.name = String(prompt.split(separator: "\n").first?.prefix(60) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        present(ScheduledTaskEditor(task: task, isNew: true), in: window, onSaved: onSaved)
    }

    /// A new project task, which starts a new thread for each run.
    static func newProjectTask(projectID: UUID? = nil, in window: NSWindow? = nil) {
        let projects = store.projects.filter { $0.id != AppStore.botsProjectID }
        guard let project = projectID ?? projects.first?.id else { return }
        let task = ScheduledTask(name: "", projectID: project, prompt: "", recurrence: TaskRecurrence())
        present(ScheduledTaskEditor(task: task, isNew: true), in: window)
    }

    static func edit(_ id: UUID, in window: NSWindow? = nil) {
        guard var task = service.schedules.task(id) else { return }
        if let proposal = task.proposal {
            // What's waiting for approval is what the user edits and, by saving, allows.
            task.name = proposal.name; task.prompt = proposal.prompt; task.recurrence = proposal.recurrence
        }
        present(ScheduledTaskEditor(task: task, isNew: false), in: window)
    }

    /// The editor for a schedule an agent asked for, from its approval card's Edit button.
    static func editProposal(_ task: ScheduledTask) {
        present(ScheduledTaskEditor(task: task, isNew: false), in: nil)
    }

    private static func present(_ editor: ScheduledTaskEditor, in window: NSWindow?, onSaved: (() -> Void)? = nil) {
        editor.onSave = { task in
            try service.save(task)
            onSaved?()
        }
        guard let window = window ?? Self.window else { return }
        let host = window.contentViewController
        if window.attachedSheet != nil { return }
        host?.presentAsSheet(editor)
    }

    static func togglePause(_ id: UUID, in window: NSWindow? = nil) {
        guard let task = service.schedules.task(id) else { return }
        perform(in: window) { try service.scheduler.setPaused(id, !task.isPaused) }
    }

    static func runNow(_ id: UUID, in window: NSWindow? = nil) {
        perform(in: window) { try service.scheduler.runNow(id) }
    }

    static func confirmDelete(_ id: UUID, in window: NSWindow? = nil) {
        guard let task = service.schedules.task(id), let window = window ?? Self.window else { return }
        let alert = ThemedAlert()
        alert.messageText = String(localized: "Delete scheduled task “\(task.name)”?")
        alert.informativeText =
            task.threadID == nil
            ? String(localized: "Existing threads are kept. A running thread continues until you stop it.")
            : String(localized: "The thread and the messages it already sent are kept. A running turn continues until you stop it.")
        alert.addButton(withTitle: String(localized: "Delete")); alert.addButton(withTitle: String(localized: "Cancel"))
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            perform(in: window) { try service.delete(id) }
        }
    }

    /// Opens what a schedule's row stands for: its thread, or the thread of a project task's last run.
    static func open(_ task: ScheduledTask) {
        if let id = task.threadID ?? task.lastThreadID, store.summary(id) != nil {
            AppEvents.openThread(id)
        } else {
            edit(task.id)
        }
    }

    private static func perform(in window: NSWindow?, _ body: () throws -> Void) {
        do { try body() } catch {
            guard let window = window ?? Self.window else { return }
            let alert = ThemedAlert()
            alert.messageText = String(localized: "Couldn’t change the schedule")
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: String(localized: "OK"))
            alert.beginSheetModal(for: window) { _ in }
        }
    }
}
