import Foundation

/// Versioned, provider-neutral mutations. Metadata events exclude transcript history.
public enum WorkspaceEvent: Codable, Sendable, Equatable {
    case imported(WorkspaceSnapshot)
    case projectUpserted(WorkspaceProject)
    case projectRemoved(UUID)
    case projectsOrdered([UUID])
    case threadMetadataUpserted(CodingThread)
    case threadRemoved(UUID)
    case threadsOrdered([UUID])
    case messageUpserted(threadID: UUID, index: Int, message: ChatMessage)
    case messageTextAppended(threadID: UUID, index: Int, messageID: String, text: String)
    case messagesTruncated(threadID: UUID, count: Int)

    public func apply(to snapshot: inout WorkspaceSnapshot) throws {
        switch self {
        case .imported(let value): try WorkspaceJournal.validate(value); snapshot = value
        case .projectUpserted(let project):
            if let i = snapshot.projects.firstIndex(where: { $0.id == project.id }) { snapshot.projects[i] = project }
            else { snapshot.projects.append(project) }
        case .projectRemoved(let id): snapshot.projects.removeAll { $0.id == id }
        case .projectsOrdered(let ids):
            guard ids.count == snapshot.projects.count, Set(ids) == Set(snapshot.projects.map(\.id)) else { throw invalidEvent() }
            let values = Dictionary(uniqueKeysWithValues: snapshot.projects.map { ($0.id, $0) })
            snapshot.projects = ids.compactMap { values[$0] }
        case .threadMetadataUpserted(var thread):
            guard thread.messages.isEmpty else { throw invalidEvent() }
            if let i = snapshot.threads.firstIndex(where: { $0.id == thread.id }) {
                thread.messages = snapshot.threads[i].messages; snapshot.threads[i] = thread
            } else { snapshot.threads.append(thread) }
        case .threadRemoved(let id): snapshot.threads.removeAll { $0.id == id }
        case .threadsOrdered(let ids):
            guard ids.count == snapshot.threads.count, Set(ids) == Set(snapshot.threads.map(\.id)) else { throw invalidEvent() }
            let values = Dictionary(uniqueKeysWithValues: snapshot.threads.map { ($0.id, $0) })
            snapshot.threads = ids.compactMap { values[$0] }
        case .messageUpserted(let id, let index, let message):
            guard let i = snapshot.threads.firstIndex(where: { $0.id == id }), index >= 0, index <= snapshot.threads[i].messages.count else { throw invalidEvent() }
            if index == snapshot.threads[i].messages.count { snapshot.threads[i].messages.append(message) }
            else { snapshot.threads[i].messages[index] = message }
        case .messageTextAppended(let id, let index, let messageID, let text):
            guard let i = snapshot.threads.firstIndex(where: { $0.id == id }), snapshot.threads[i].messages.indices.contains(index),
                  snapshot.threads[i].messages[index].id == messageID else { throw invalidEvent() }
            snapshot.threads[i].messages[index].text += text
        case .messagesTruncated(let id, let count):
            guard let i = snapshot.threads.firstIndex(where: { $0.id == id }), count >= 0, count <= snapshot.threads[i].messages.count else { throw invalidEvent() }
            snapshot.threads[i].messages.removeLast(snapshot.threads[i].messages.count - count)
        }
        guard snapshot.schemaVersion == 1 else { throw CoincideError("This workspace needs a newer version of Coincide.") }
    }
    private func invalidEvent() -> CoincideError { CoincideError("The workspace journal contains an invalid mutation.") }
}

public struct WorkspaceJournalRecord: Codable, Sendable, Equatable {
    public var version: Int = 1
    public var sequence: Int64
    public var commandID: UUID
    public var event: WorkspaceEvent
}

public struct WorkspaceCommandReceipt: Codable, Sendable, Equatable {
    public var commandID: UUID
    public var sequence: Int64
    public var eventCount: Int
    public var acceptedAt: Date
}

public struct WorkspaceRevision: Sendable, Equatable {
    public var snapshot: WorkspaceSnapshot
    public var sequence: Int64
}

public enum WorkspaceJournal {
    public static func validate(_ snapshot: WorkspaceSnapshot) throws {
        let projects = Set(snapshot.projects.map(\.id)), threads = Set(snapshot.threads.map(\.id))
        guard snapshot.schemaVersion == 1, projects.count == snapshot.projects.count, threads.count == snapshot.threads.count,
              snapshot.threads.allSatisfy({ projects.contains($0.projectID) && Set($0.messages.map(\.id)).count == $0.messages.count }) else {
            throw CoincideError("The workspace has invalid or duplicate project, thread, or message identities.")
        }
    }

    public static func changes(from previous: WorkspaceSnapshot, to next: WorkspaceSnapshot) throws -> [WorkspaceEvent] {
        try validate(previous); try validate(next)
        var events: [WorkspaceEvent] = []
        let oldProjects = Dictionary(uniqueKeysWithValues: previous.projects.map { ($0.id, $0) })
        let newProjects = Set(next.projects.map(\.id))
        for project in previous.projects where !newProjects.contains(project.id) { events.append(.projectRemoved(project.id)) }
        for project in next.projects where oldProjects[project.id] != project { events.append(.projectUpserted(project)) }
        if previous.projects.map(\.id) != next.projects.map(\.id) { events.append(.projectsOrdered(next.projects.map(\.id))) }
        let oldThreads = Dictionary(uniqueKeysWithValues: previous.threads.map { ($0.id, $0) })
        let newThreads = Set(next.threads.map(\.id))
        for thread in previous.threads where !newThreads.contains(thread.id) { events.append(.threadRemoved(thread.id)) }
        for thread in next.threads {
            var metadata = thread; metadata.messages = []
            var oldMetadata = oldThreads[thread.id]; oldMetadata?.messages = []
            if metadata != oldMetadata { events.append(.threadMetadataUpserted(metadata)) }
            let oldMessages = oldThreads[thread.id]?.messages ?? []
            if thread.messages.count < oldMessages.count { events.append(.messagesTruncated(threadID: thread.id, count: thread.messages.count)) }
            for (index, message) in thread.messages.enumerated() {
                if index < oldMessages.count {
                    let old = oldMessages[index]
                    if old == message { continue }
                    if old.id == message.id, old.role == message.role, old.createdAt == message.createdAt, message.text.utf8.starts(with: old.text.utf8) {
                        let tail = String(decoding: message.text.utf8.dropFirst(old.text.utf8.count), as: UTF8.self)
                        events.append(.messageTextAppended(threadID: thread.id, index: index, messageID: message.id, text: tail))
                        continue
                    }
                }
                events.append(.messageUpserted(threadID: thread.id, index: index, message: message))
            }
        }
        if previous.threads.map(\.id) != next.threads.map(\.id) { events.append(.threadsOrdered(next.threads.map(\.id))) }
        return events
    }
}
