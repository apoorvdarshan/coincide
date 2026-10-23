import Foundation

public enum ThreadNotificationMode: String, CaseIterable, Sendable, Identifiable {
    case off, notifications, sound, notificationsAndSound
    public var id: String { rawValue }
    public var showsNotifications: Bool { self == .notifications || self == .notificationsAndSound }
    public var playsSound: Bool { self == .sound || self == .notificationsAndSound }
    public var title: String {
        switch self {
        case .off: String(localized: "Off")
        case .notifications: String(localized: "Notifications only")
        case .sound: String(localized: "Sound only")
        case .notificationsAndSound: String(localized: "Notifications with sound")
        }
    }
}

public struct ThreadAttentionNotification: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, Hashable { case completed, approval, input, failed }
    public let threadID: UUID
    public let runID: UUID?
    public let kind: Kind
    public let threadTitle: String
    public let requestID: JSONValue?
    public let occurrenceID: UUID
    public init(threadID: UUID, runID: UUID?, kind: Kind, threadTitle: String, requestID: JSONValue? = nil, occurrenceID: UUID = UUID()) {
        self.threadID = threadID; self.runID = runID; self.kind = kind
        self.threadTitle = threadTitle; self.requestID = requestID; self.occurrenceID = occurrenceID
    }
    public var id: String { "coincide.thread." + threadID.uuidString.lowercased() }
    public var title: String {
        switch kind {
        case .completed: String(localized: "Thread completed")
        case .approval: String(localized: "Approval needed")
        case .input: String(localized: "Input needed")
        case .failed: String(localized: "Thread failed")
        }
    }
}

/// Observe transitions, including while notifications are disabled. Opening a
/// database, importing history or unarchiving a thread must not replay old alerts.
public struct ThreadAttentionNotificationTracker: Sendable {
    private struct Observation: Sendable {
        var attention: ThreadAttentionNotification.Kind?
        var runID: UUID?
        var status: ThreadRunStatus?
        var completion: UUID?
        var requestID: JSONValue?
    }
    private var previous: [UUID: Observation] = [:]
    // Only alert metadata is retained; no transcript, tool input or full snapshot.
    private var current: [UUID: ThreadAttentionNotification] = [:]
    public init() {}

    /// Queued native delivery can suspend while the next projection arrives.
    /// Recheck after each await so resolved or replaced requests cannot alert.
    public func eventIsCurrent(_ event: ThreadAttentionNotification) -> Bool {
        current[event.threadID] == event
    }

    public mutating func observe(_ snapshot: WorkspaceSnapshot, baseline: Bool = false) -> [ThreadAttentionNotification] {
        var next: [UUID: Observation] = [:]
        var current: [UUID: ThreadAttentionNotification] = [:]
        var result: [ThreadAttentionNotification] = []
        for thread in snapshot.threads where !thread.isArchived {
            let prior = previous[thread.id]
            let latest = thread.runHistory?.last(where: { $0.removedByHistoryOperationID == nil })
            let runID = thread.activeRun?.id ?? latest?.id
            let stopping = thread.activeRun?.stopRequested == true || latest?.stopRequested == true
            let request = thread.runtimeRequests.first(where: { !$0.responding })?.request
            let title = String(String.UnicodeScalarView(thread.title.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(160)))
            let attention: ThreadAttentionNotification.Kind?
            if stopping { attention = nil }
            else if let request { attention = request.isQuestion ? .input : .approval }
            else if thread.state == .failed && latest?.status == .failed && prior?.runID == runID
                && prior?.status?.isTerminal == false { attention = .failed }
            else { attention = nil }
            let completed = latest?.status == .completed && latest?.endedAt != nil && !stopping
                && prior?.runID == latest?.id && prior?.status?.isTerminal == false
            let completion = completed ? latest?.id : prior?.completion
            next[thread.id] = .init(attention: attention, runID: runID, status: latest?.status, completion: completion, requestID: request?.id)
            let currentKind: ThreadAttentionNotification.Kind?
            if stopping { currentKind = nil }
            else if let request { currentKind = request.isQuestion ? .input : .approval }
            else if thread.state == .failed && latest?.status == .failed { currentKind = .failed }
            else if thread.activeRun == nil && latest?.status == .completed && latest?.endedAt != nil { currentKind = .completed }
            else { currentKind = nil }
            if let currentKind {
                let priorCurrent = self.current[thread.id]
                var event = ThreadAttentionNotification(threadID: thread.id, runID: runID, kind: currentKind,
                    threadTitle: title, requestID: request?.id, occurrenceID: priorCurrent?.occurrenceID ?? UUID())
                if let priorCurrent, priorCurrent != event {
                    event = .init(threadID: thread.id, runID: runID, kind: currentKind, threadTitle: title, requestID: request?.id)
                }
                current[thread.id] = event
            }
            guard !baseline, let prior else { continue }
            let kind: ThreadAttentionNotification.Kind?
            if let attention, attention != prior.attention || runID != prior.runID || request?.id != prior.requestID { kind = attention }
            else if let completion, completion != prior.completion { kind = .completed }
            else { kind = nil }
            if let kind, let event = current[thread.id], event.kind == kind { result.append(event) }
        }
        previous = next
        self.current = current
        return result
    }
}
