import CryptoKit
import Darwin
import Foundation

public enum ScheduledTaskSchedule: Codable, Sendable, Equatable {
    case interval(everyMilliseconds: Int64)
    /// Uses the host's local timezone, like the pinned T3 service. Empty means every day.
    case fixedTime(timeOfDay: String, weekdays: [Int])
    case webhook(ScheduledTaskWebhookConfiguration)
    public func validate(writing: Bool = true) throws {
        switch self {
        case .interval(let value): guard value >= (writing ? 60_000 : 1), value <= 31_536_000_000 else { throw ScheduledTaskError.invalidSchedule }
        case .fixedTime(let text, let days):
            guard Self.time(text) != nil, days.count <= 7, days.allSatisfy({ (0...6).contains($0) }) else { throw ScheduledTaskError.invalidSchedule }
        case .webhook(let value): try value.validate()
        }
    }
    private static func time(_ text: String) -> (Int, Int)? {
        guard text.range(of: #"^([01]?\d|2[0-3]):([0-5]\d)$"#, options: .regularExpression) != nil else { return nil }
        let parts = text.split(separator: ":").compactMap { Int($0) }; return parts.count == 2 ? (parts[0], parts[1]) : nil
    }
    public func next(after date: Date, timeZone: TimeZone = .current) -> Date? {
        switch self {
        case .interval(let value): return date.addingTimeInterval(Double(max(60_000, value)) / 1000)
        case .webhook: return nil
        case .fixedTime(let text, let weekdays):
            guard let (hour, minute) = Self.time(text) else { return nil }
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
            var cursor = date
            for _ in 0..<8 {
                guard let next = calendar.nextDate(after: cursor, matching: DateComponents(hour: hour, minute: minute, second: 0), matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward) else { return nil }
                if weekdays.isEmpty || weekdays.contains(calendar.component(.weekday, from: next) - 1) { return next }
                cursor = next
            }
            return nil
        }
    }
    public func isEquivalent(to other: Self) -> Bool {
        switch (self, other) {
        case (.interval(let a), .interval(let b)): return a == b
        case (.webhook, .webhook): return true
        case (.fixedTime(let a, let ad), .fixedTime(let b, let bd)):
            guard let at = Self.time(a), let bt = Self.time(b) else { return false }
            let left = ad.isEmpty ? Set(0...6) : Set(ad), right = bd.isEmpty ? Set(0...6) : Set(bd)
            return at.0 == bt.0 && at.1 == bt.1 && left == right
        default: return false
        }
    }
    public func isMissed(due: Date, now: Date) -> Bool {
        if case .fixedTime = self { return now.timeIntervalSince(due) > 600 }
        return false
    }
}
public enum ScheduledTaskWorkspace: Codable, Sendable, Equatable {
    case sourceCheckout, projectRoot, newWorktree(baseRef: String, submodules: ProjectWorktreeSubmoduleMode)
}
public struct ScheduledTaskDirectory: Codable, Sendable, Equatable {
    let path: Data
    let physicalPath: String
    let device: UInt64
    let inode: UInt64
    static func capture(_ path: String) throws -> Self {
        guard path.hasPrefix("/"), !path.contains("\0") else { throw ScheduledTaskError.sourceChanged }
        guard let resolved = realpath(path, nil) else { throw ScheduledTaskError.sourceChanged }
        let physical = String(cString: resolved); free(resolved)
        let fd = Darwin.open(physical, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ScheduledTaskError.sourceChanged }; defer { Darwin.close(fd) }
        var value = stat(); guard fstat(fd, &value) == 0, value.st_ino != 0 else { throw ScheduledTaskError.sourceChanged }
        return .init(path: Data(path.utf8), physicalPath: physical, device: UInt64(truncatingIfNeeded: value.st_dev), inode: UInt64(value.st_ino))
    }
}
public struct ScheduledTaskSource: Codable, Sendable, Equatable {
    public let threadID: UUID
    public let threadCreatedAt: Date
    public let projectID: UUID
    public let projectCreatedAt: Date?
    public let projectPath: String
    public let configuration: ProviderConfiguration
    public let preparationID: UUID?
    public let checkpointPolicy: RunCheckpointPolicy
    let projectDirectory: ScheduledTaskDirectory
    let workspaceDirectory: ScheduledTaskDirectory
    static func normalized(_ value: ProviderConfiguration) -> ProviderConfiguration {
        var value = value; value.nativeThreadID = nil; value.claudeLaunchSelection = nil; return value
    }
    public init(thread: CodingThread, project: WorkspaceProject) throws {
        guard thread.projectID == project.id else { throw ScheduledTaskError.sourceChanged }
        threadID = thread.id; threadCreatedAt = thread.createdAt; projectID = project.id; projectCreatedAt = project.createdAt
        projectPath = project.path; configuration = Self.normalized(.init(thread: thread)); preparationID = thread.workspacePreparation?.id; checkpointPolicy = thread.effectiveCheckpointPolicy
        projectDirectory = try .capture(project.path); workspaceDirectory = try .capture(thread.workspacePath)
    }
    public func validate(in snapshot: WorkspaceSnapshot) throws {
        guard let project = snapshot.projects.first(where: { $0.id == projectID }), let thread = snapshot.threads.first(where: { $0.id == threadID }),
              project.createdAt == projectCreatedAt, project.path.utf8.elementsEqual(projectPath.utf8), thread.createdAt == threadCreatedAt,
              thread.projectID == projectID, thread.workspacePreparation?.id == preparationID, thread.effectiveCheckpointPolicy == checkpointPolicy,
              Self.normalized(.init(thread: thread)).matchesModelControlCapture(configuration),
              snapshot.workspaceReady(for: thread), !thread.isArchived,
              try ScheduledTaskDirectory.capture(project.path) == projectDirectory,
              try ScheduledTaskDirectory.capture(thread.workspacePath) == workspaceDirectory else { throw ScheduledTaskError.sourceChanged }
    }
}
public enum ScheduledTaskDestination: String, Codable, Sendable { case freshThread, existingThread }

public struct ScheduledTaskDefinition: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public var revision: UUID
    public var title: String
    public var prompt: String
    public var enabled: Bool
    public var schedule: ScheduledTaskSchedule
    public var source: ScheduledTaskSource
    public var workspace: ScheduledTaskWorkspace
    public var destination: ScheduledTaskDestination?
    public var createdAt: Date
    public var updatedAt: Date
    public var nextRunAt: Date?
    public var error: String?
    public init(id: UUID = UUID(), title: String, prompt: String, enabled: Bool = false, schedule: ScheduledTaskSchedule,
                source: ScheduledTaskSource, workspace: ScheduledTaskWorkspace = .sourceCheckout, destination: ScheduledTaskDestination = .freshThread, now: Date = Date()) throws {
        self.id = id; revision = UUID(); self.title = title; self.prompt = prompt; self.enabled = enabled; self.schedule = schedule
        self.source = source; self.workspace = workspace; self.destination = destination; createdAt = now; updatedAt = now; nextRunAt = enabled ? schedule.next(after: now) : nil; error = nil
        try validate()
    }
    public func validate(writing: Bool = true) throws {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.utf8.count <= 1024,
              !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, prompt.utf16.count <= 120_000,
              prompt.utf8.count <= 512 * 1024, !prompt.contains("\0") else { throw ScheduledTaskError.invalidDefinition }
        try schedule.validate(writing: writing)
        if destination == .existingThread, workspace != .sourceCheckout { throw ScheduledTaskError.unsupported }
        if case .newWorktree(let base, _) = workspace {
            do {
                try GitWorktreeRequest(sourcePath: source.projectPath, destinationRoot: "/private/coincide-validation", selection: .createBranch(name: "scheduled-validation", baseRef: base)).validate()
            } catch { throw ScheduledTaskError.invalidDefinition }
        }
    }
}
public struct ScheduledTaskOccurrence: Codable, Sendable, Equatable, Identifiable {
    public enum Trigger: String, Codable, Sendable { case scheduled, manual, webhook }
    public enum Phase: String, Codable, Sendable { case waiting, accepted, succeeded, failed, uncertain, missed, coalesced }
    public let id: UUID
    public let taskID: UUID
    public let taskRevision: UUID
    public let trigger: Trigger
    public let dueAt: Date
    public let observedAt: Date
    public let threadID: UUID?
    public var phase: Phase
    public var error: String?
    public var acknowledgedAt: Date?
    public let delivery: ScheduledTaskWebhookDelivery?
    public var selectedDeliveryDigest: String? = nil
}
public struct ScheduledTaskLedger: Codable, Sendable, Equatable {
    public var tasks: [ScheduledTaskDefinition] = []
    public var occurrences: [ScheduledTaskOccurrence] = []
    public var webhookPending: [ScheduledTaskWebhookPending] = []
    public var webhookReplay: [ScheduledTaskWebhookReplay] = []
    public var webhookListenerPort: UInt16?
    public init() {}
    private enum CodingKeys: String, CodingKey { case tasks, occurrences, webhookPending, webhookReplay, webhookListenerPort }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        tasks = try values.decodeIfPresent([ScheduledTaskDefinition].self, forKey: .tasks) ?? []
        occurrences = try values.decodeIfPresent([ScheduledTaskOccurrence].self, forKey: .occurrences) ?? []
        webhookPending = try values.decodeIfPresent([ScheduledTaskWebhookPending].self, forKey: .webhookPending) ?? []
        webhookReplay = try values.decodeIfPresent([ScheduledTaskWebhookReplay].self, forKey: .webhookReplay) ?? []
        webhookListenerPort = try values.decodeIfPresent(UInt16.self, forKey: .webhookListenerPort)
    }
    func validate() throws {
        guard tasks.count <= 100, occurrences.count <= 1000, webhookPending.count <= 200, webhookReplay.count <= 10_000, Set(tasks.map(\.id)).count == tasks.count,
              Set(occurrences.map(\.id)).count == occurrences.count else { throw ScheduledTaskError.capacity }
        for task in tasks { try task.validate(writing: false) }
        let encoder = JSONEncoder(); guard try encoder.encode(self).count <= 16 * 1024 * 1024 else { throw ScheduledTaskError.capacity }
    }
    mutating func recover(threads: [CodingThread]) {
        for i in occurrences.indices where occurrences[i].phase == .accepted {
            if let thread = threads.first(where: { $0.id == occurrences[i].threadID }),
               let run = thread.runHistory?.first(where: { $0.id == occurrences[i].id }), run.endedAt != nil, run.status == .completed {
                occurrences[i].phase = .succeeded; continue
            }
            occurrences[i].phase = .uncertain; occurrences[i].error = ScheduledTaskError.uncertain.localizedDescription
            if let t = tasks.firstIndex(where: { $0.id == occurrences[i].taskID }) { tasks[t].enabled = false; tasks[t].nextRunAt = nil }
        }
    }
}
public enum ScheduledTaskError: String, Error, LocalizedError, Sendable {
    case duplicateWebhook, invalidSchedule, invalidDefinition, sourceChanged, staleRevision, capacity, uncertain, unavailable, unauthorized, invalidWebhook, unsupported
    public var errorDescription: String? {
        switch self {
        case .duplicateWebhook: "This webhook delivery was already admitted."
        case .invalidSchedule: "Use an interval of at least one minute, or a valid local time and weekdays."
        case .invalidDefinition: "Enter a title and a bounded prompt for the scheduled task."
        case .sourceChanged: "The saved project, checkout or provider settings changed. Review and save this task again."
        case .staleRevision: "This scheduled task changed. Reload before editing or running it."
        case .capacity: "Scheduled task storage is full. Delete resolved history or unused definitions before continuing."
        case .uncertain: "The input may have been accepted before the app closed. Inspect its original thread; it will not be sent again."
        case .unavailable: "The scheduler is unavailable."
        case .unauthorized: "The webhook authentication was refused."
        case .invalidWebhook: "The webhook request is invalid or exceeds its limit."
        case .unsupported: "This scheduling option is not supported."
        }
    }
}
public struct ScheduledTaskFire: Codable, Sendable, Equatable {
    public let taskID: UUID
    public let revision: UUID
    public let trigger: ScheduledTaskOccurrence.Trigger
    public let dueAt: Date
    public let observedAt: Date
    public let managedRoot: String
    public let prompt: String?
    public let delivery: ScheduledTaskWebhookDelivery?
}
public indirect enum ScheduledTaskMutation: Codable, Sendable, Equatable {
    case listener(port: UInt16?)
    case mcp(ScheduledTaskMCPCommand)
    case enqueueWebhook(ScheduledTaskWebhookPending)
    case save(ScheduledTaskDefinition, expectedRevision: UUID?)
    case enabled(id: UUID, revision: UUID, enabled: Bool, now: Date)
    case delete(id: UUID, revision: UUID)
    case fire(ScheduledTaskFire)
    case missed(id: UUID, revision: UUID, dueAt: Date, now: Date)
    case failure(id: UUID, revision: UUID, occurrenceID: UUID, trigger: ScheduledTaskOccurrence.Trigger, dueAt: Date, now: Date)
    case observe(id: UUID, phase: ScheduledTaskOccurrence.Phase)
    case acknowledge(id: UUID, now: Date)
    case pruneResolvedHistory
}
