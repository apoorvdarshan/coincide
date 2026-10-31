import CoincideKit
import CoincideRemoteKit
import Foundation

/// The Mac's scheduled tasks for Coincide Remote, through the calls its Scheduled Tasks window makes: list, create,
/// edit, pause or resume, run now and delete. Each run still starts on the Mac, in a new thread of the task's project.
extension RemoteStoreAdapter {
    func scheduledTasks() -> RemoteScheduledTasks {
        RemoteScheduledTasks(
            tasks: schedules.schedules.tasks.map(remoteTask), error: schedules.schedules.loadError ?? schedules.lastError)
    }

    private func remoteTask(_ task: ScheduledTask) -> RemoteScheduledTask {
        let isRunning = task.activeThreadID != nil || schedules.hasActiveWork(task)
        let state: RemoteScheduledTask.State =
            if isRunning { .running } else if task.isPaused { task.lastOutcome == .failed ? .failed : .paused } else {
                switch task.lastOutcome {
                case .failed: .failed
                case .interrupted: .interrupted
                case .missed: .missed
                case .completed where task.nextRunAt == nil: .completed
                default: .scheduled
                }
            }
        let recurrence = task.recurrence
        return RemoteScheduledTask(
            id: task.id, name: task.name, projectID: task.projectID, prompt: task.prompt,
            recurrence: RemoteTaskRecurrence(
                kind: RemoteTaskRecurrence.Kind(rawValue: recurrence.kind.rawValue) ?? .unknown, timeZoneID: recurrence.timeZoneID,
                date: recurrence.date, hour: recurrence.hour, minute: recurrence.minute, weekday: recurrence.weekday),
            isPaused: task.isPaused, state: state,
            stateText: SchedulePresentation.status(task, isRunning: isRunning)?.label ?? String(localized: "Scheduled"),
            scheduleText: recurrence.summary, nextRunAt: task.nextRunAt, lastRunAt: task.lastRunAt, lastMessage: task.lastMessage,
            lastThreadID: task.lastThreadID.flatMap { store.summary($0) == nil ? nil : $0 },
            canRunNow: !isRunning && store.project(task.projectID) != nil && !task.isAwaitingApproval && task.pauseReason == nil,
            threadID: task.threadID, botID: task.threadID.flatMap { store.summary($0)?.botID },
            needsApproval: task.isAwaitingApproval ? true : nil, createdByAgent: task.createdByAgent)
    }

    /// Creates or edits a task as the Mac's editor saves it; a run in progress keeps going.
    func saveScheduledTask(_ draft: RemoteScheduledTaskDraft) throws -> RemoteScheduledTasks {
        let existing = draft.id.flatMap { id in schedules.schedules.tasks.first { $0.id == id } }
        // A thread schedule stays with its thread, a chat's or a bot's included; a project task needs a project.
        let threadID = existing.map(\.threadID) ?? draft.threadID
        if existing == nil, let threadID, store.summary(threadID) == nil {
            throw RemoteError(.notFound, String(localized: "That thread no longer exists."))
        }
        let projectID = existing?.projectID ?? threadID.flatMap { store.summary($0)?.projectID } ?? draft.projectID
        guard let project = store.project(threadID != nil ? projectID : draft.projectID),
            threadID != nil || (!project.isChats && !project.isBots)
        else {
            throw RemoteError(.notFound, String(localized: "The scheduled task's project is no longer available."))
        }
        if draft.id != nil, existing == nil {
            throw RemoteError(.notFound, String(localized: "That scheduled task no longer exists."))
        }
        let recurrence: TaskRecurrence
        if let sent = draft.recurrence {
            guard let kind = TaskRecurrence.Kind(rawValue: sent.kind.rawValue) else {
                throw RemoteError(.badRequest, String(localized: "This Mac doesn’t know that schedule."))
            }
            // The phone sends the fields every kind shares; a kind's own (its days, interval or cron expression) stay as
            // the Mac has them.
            var merged = existing?.recurrence.kind == kind ? existing!.recurrence : TaskRecurrence(kind: kind)
            merged.timeZoneID = sent.timeZoneID; merged.date = sent.date; merged.hour = sent.hour
            merged.minute = sent.minute; merged.weekday = sent.weekday
            recurrence = merged
        } else if let existing {
            recurrence = existing.recurrence
        } else {
            throw RemoteError(.badRequest, String(localized: "Choose when the task runs."))
        }
        var task =
            existing
            ?? ScheduledTask(
                name: draft.name, projectID: project.id, prompt: draft.prompt, recurrence: recurrence, isPaused: draft.isPaused,
                threadID: threadID)
        task.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        task.projectID = project.id
        task.prompt = draft.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        task.recurrence = recurrence
        task.isPaused = draft.isPaused
        do {
            try schedules.scheduler.save(task)
        } catch {
            throw RemoteError(.badRequest, error.localizedDescription)
        }
        return scheduledTasks()
    }

    func perform(_ command: RemoteScheduledTaskCommand) throws -> RemoteScheduledTasks {
        guard let task = schedules.schedules.tasks.first(where: { $0.id == command.taskID }) else {
            throw RemoteError(.notFound, String(localized: "That scheduled task no longer exists."))
        }
        do {
            switch command.action {
            case .pause: try schedules.scheduler.setPaused(task.id, true)
            case .resume: try schedules.scheduler.setPaused(task.id, false)
            case .runNow:
                guard task.activeThreadID == nil, !schedules.hasActiveWork(task) else { throw ScheduleError.alreadyRunning }
                try schedules.scheduler.runNow(task.id)
            case .delete: try schedules.delete(task.id)
            case .unknown: throw RemoteError(.unsupported, String(localized: "This Mac doesn’t know that action."))
            }
        } catch let error as RemoteError {
            throw error
        } catch {
            throw RemoteError(.notAllowed, error.localizedDescription)
        }
        return scheduledTasks()
    }
}
