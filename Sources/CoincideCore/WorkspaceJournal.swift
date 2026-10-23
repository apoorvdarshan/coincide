import Foundation

/// Versioned, provider-neutral mutations. Metadata events exclude transcript history.
public enum WorkspaceEvent: Codable, Sendable, Equatable {
    case imported(WorkspaceSnapshot)
    case projectUpserted(WorkspaceProject)
    case projectRemoved(UUID)
    case projectsOrdered([UUID])
    case acpAgentsReplaced([ACPAgentConfiguration])
    case sidebarPreferencesChanged(SidebarPreferences?)
    case conversationHistoryOperationsReplaced([ConversationHistoryOperation]?)
    case pullRequestCreationsReplaced([PullRequestCreationOperation]?)
    case pullRequestCheckoutsReplaced([PullRequestCheckoutOperation]?)
    case promptSteeringsReplaced([PromptSteeringOperation]?)
    case checkpointRestoreOperationsReplaced([RunCheckpointRestoreOperation]?)
    case contextTransfersReplaced([ContextTransfer]?)
    case delegatedTasksReplaced([DelegatedTask]?)
    case delegatedTaskCohortsReplaced([DelegatedTaskCohort]?)
    case delegatedTaskTransfersReplaced([DelegatedTaskResultTransfer]?)
    case threadMetadataUpserted(CodingThread)
    case threadRemoved(UUID)
    case threadsOrdered([UUID])
    case messageUpserted(threadID: UUID, index: Int, message: ChatMessage)
    case messageTextAppended(threadID: UUID, index: Int, messageID: String, text: String)
    case messagesTruncated(threadID: UUID, count: Int)

    public func apply(to snapshot: inout WorkspaceSnapshot) throws {
        switch self {
        case .delegatedTaskTransfersReplaced(let values): snapshot.delegatedTaskTransfers = values
        case .delegatedTasksReplaced(let values): snapshot.delegatedTasks = values
        case .delegatedTaskCohortsReplaced(let values): snapshot.delegatedTaskCohorts = values
        case .contextTransfersReplaced(let values): snapshot.contextTransfers = values
        case .conversationHistoryOperationsReplaced(let operations): snapshot.conversationHistoryOperations = operations
        case .pullRequestCreationsReplaced(let operations): snapshot.pullRequestCreations = operations
        case .pullRequestCheckoutsReplaced(let operations): snapshot.pullRequestCheckouts = operations
        case .promptSteeringsReplaced(let operations): snapshot.promptSteerings = operations
        case .checkpointRestoreOperationsReplaced(let operations): snapshot.checkpointRestoreOperations = operations
        case .sidebarPreferencesChanged(let preferences): snapshot.sidebarPreferences = preferences
        case .acpAgentsReplaced(let agents): snapshot.acpAgents = agents
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
    public var rejection: String?
}

public struct WorkspaceRevision: Sendable, Equatable {
    public var snapshot: WorkspaceSnapshot
    public var sequence: Int64
}

public enum WorkspaceJournal {
    public static func validate(_ snapshot: WorkspaceSnapshot) throws {
        let projects = Set(snapshot.projects.map(\.id)), threads = Set(snapshot.threads.map(\.id))
        guard snapshot.schemaVersion == 1, projects.count == snapshot.projects.count, threads.count == snapshot.threads.count,
              snapshot.threads.allSatisfy({ thread in
                  projects.contains(thread.projectID) && Set(thread.messages.map(\.id)).count == thread.messages.count &&
                  Set(thread.messages.compactMap { $0.providerEntity?.key }).count == thread.messages.filter { $0.providerEntity != nil }.count &&
                  Set(thread.queuedTurns.map(\.id)).count == thread.queuedTurns.count &&
                  !thread.queuedTurns.contains { $0.id == thread.activeRun?.id }
              }) else {
            throw CoincideError("The workspace has invalid or duplicate project, thread, or message identities.")
        }
        try snapshot.validateDelegatedTasks()
        try snapshot.validatePromptSteerings()
        try snapshot.validateContextTransfers()
        try snapshot.validatePullRequestCheckouts()
        try snapshot.validatePullRequestCreations()
        try snapshot.validateConversationHistory()
        try snapshot.validateConversationHistoryFilesLedger()
        try snapshot.validateCheckpointRestores()
        var cloneIDs: Set<UUID> = []
        for project in snapshot.projects {
            try validateRepositoryIdentity(project.repositoryIdentity, project: project)
            guard let clone = project.clone else { continue }
            try clone.validate(project: project)
            for plan in clone.previousPlans + [clone.plan] {
                guard cloneIDs.insert(plan.id).inserted else { throw CoincideError("Clone attempts must have unique identities.") }
            }
        }
        var preparationIDs: Set<UUID> = []
        var scriptIDs: Set<UUID> = []
        var checkpointIDs: Set<UUID> = []
        let settlementIDs = Set(snapshot.threads.compactMap { $0.settlement?.id })
        guard settlementIDs.count == snapshot.threads.filter({ $0.settlement != nil }).count, settlementIDs.isDisjoint(with: cloneIDs) else { throw CoincideError("Settlement generations must have unique identities.") }
        for thread in snapshot.threads {
            try CodexReasoningValidation.thread(thread)
            try thread.validateRunHistory()
            for record in thread.runHistory ?? [] {
                guard let checkpoints = record.checkpoints else { continue }
                let attempts = [checkpoints.baseline] + checkpoints.previousPostRunAttempts + (checkpoints.postRun.map { [$0] } ?? [])
                for attempt in attempts {
                    guard checkpointIDs.insert(attempt.id).inserted, !cloneIDs.contains(attempt.id), !settlementIDs.contains(attempt.id) else { throw CoincideError("Run checkpoints must have unique identities.") }
                }
            }
            if let preparation = thread.workspacePreparation {
                try preparation.validate(thread: thread)
                for id in preparation.previousAttempts.map({ $0.request.id }) + [preparation.id] {
                    guard preparationIDs.insert(id).inserted, !cloneIDs.contains(id), !scriptIDs.contains(id), !settlementIDs.contains(id) else { throw CoincideError("Workspace preparation attempts must have unique identities.") }
                }
                for setup in preparation.previousAttempts.compactMap(\.setup) + (preparation.setup.map { [$0] } ?? []) {
                    for id in setup.previousPlans.map(\.id) + [setup.id] {
                        guard scriptIDs.insert(id).inserted, !cloneIDs.contains(id), !preparationIDs.contains(id), !settlementIDs.contains(id) else { throw CoincideError("Project setup attempts must have unique identities.") }
                    }
                }
            }
            if let settlement = thread.settlement {
                try settlement.validate(thread: thread)
                if let run = settlement.script {
                    for id in run.previousPlans.map(\.id) + [run.id] {
                        guard scriptIDs.insert(id).inserted, !cloneIDs.contains(id), !preparationIDs.contains(id), !settlementIDs.contains(id) else { throw CoincideError("Project script attempts must have unique identities.") }
                    }
                    if let plan = run.plan {
                        guard plan.projectRoot == snapshot.projects.first(where: { $0.id == thread.projectID })?.path,
                              plan.projectRootIdentity != plan.workspaceIdentity else { throw CoincideError("A settle script cannot run in the shared project checkout.") }
                    }
                }
            }
            guard snapshot.workspaceReady(for: thread) || !thread.isBusy else { throw CoincideError("A conversation cannot run before its repository is ready.") }
            if let agent = thread.acpAgent { try agent.validate() }
            if thread.provider == .acp, thread.acpAgent == nil { throw CoincideError("This conversation has no ACP agent configuration.") }
            try AttachmentLimits.validate(thread.draftAttachments)
            for queued in thread.queuedTurns { try AttachmentLimits.validate(queued.attachments ?? []); try CodexReasoningValidation.configuration(queued.configuration) }
            for message in thread.messages { try AttachmentLimits.validate(message.attachments ?? []) }
        }
        guard checkpointIDs.isDisjoint(with: preparationIDs), checkpointIDs.isDisjoint(with: scriptIDs) else { throw CoincideError("Run checkpoint ownership overlaps another operation.") }
        guard Set(snapshot.acpAgents.map(\.id)).count == snapshot.acpAgents.count else { throw CoincideError("Agent configurations must have unique identities.") }
        for agent in snapshot.acpAgents { try agent.validate() }
        try snapshot.sidebarPreferences?.validate(projectIDs: projects)
        let preferences = snapshot.effectiveSidebarPreferences, groups = snapshot.projectGroups
        let physicalKeys = Set(snapshot.projects.compactMap { snapshot.physicalProjectKey(for: $0.id) })
        guard preferences.selectedThreadID.map({ threads.contains($0) }) ?? true,
              Set(preferences.groupingOverrides.keys).isSubset(of: physicalKeys),
              Set(preferences.groupExpandedByKey.keys).isSubset(of: Set(groups.map(\.key))),
              preferences.activeProjectByGroup.allSatisfy({ key, id in
                  groups.contains { $0.key == key && $0.memberProjectIDs.contains(id) } && snapshot.projects.contains { $0.id == id && ($0.clone == nil || $0.clone?.isReady == true) }
              }) else { throw CoincideError("Project grouping preferences refer to a checkout or group that no longer exists.") }
    }

    static func validateRepositoryIdentity(_ identity: RepositoryIdentity?, project: WorkspaceProject) throws {
        guard let identity else { return }
        try identity.validate()
        let path = URL(fileURLWithPath: project.path).standardizedFileURL.path
        let relative = path == identity.rootPath ? "" : (path.hasPrefix(identity.rootPath + "/") ? String(path.dropFirst(identity.rootPath.count + 1)) : nil)
        guard identity.projectRelativePath == relative, project.clone == nil || project.clone?.isReady == true else {
            throw CoincideError("Repository metadata does not belong to this checkout.")
        }
    }

    public static func changes(from previous: WorkspaceSnapshot, to next: WorkspaceSnapshot) throws -> [WorkspaceEvent] {
        try validate(previous); try validate(next)
        var events: [WorkspaceEvent] = []
        if previous.delegatedTaskTransfers != next.delegatedTaskTransfers { events.append(.delegatedTaskTransfersReplaced(next.delegatedTaskTransfers)) }
        if previous.delegatedTasks != next.delegatedTasks { events.append(.delegatedTasksReplaced(next.delegatedTasks)) }
        if previous.delegatedTaskCohorts != next.delegatedTaskCohorts { events.append(.delegatedTaskCohortsReplaced(next.delegatedTaskCohorts)) }
        if previous.contextTransfers != next.contextTransfers { events.append(.contextTransfersReplaced(next.contextTransfers)) }
        if previous.conversationHistoryOperations != next.conversationHistoryOperations { events.append(.conversationHistoryOperationsReplaced(next.conversationHistoryOperations)) }
        if previous.pullRequestCreations != next.pullRequestCreations { events.append(.pullRequestCreationsReplaced(next.pullRequestCreations)) }
        if previous.pullRequestCheckouts != next.pullRequestCheckouts { events.append(.pullRequestCheckoutsReplaced(next.pullRequestCheckouts)) }
        if previous.promptSteerings != next.promptSteerings { events.append(.promptSteeringsReplaced(next.promptSteerings)) }
        if previous.checkpointRestoreOperations != next.checkpointRestoreOperations { events.append(.checkpointRestoreOperationsReplaced(next.checkpointRestoreOperations)) }
        if previous.sidebarPreferences != next.sidebarPreferences { events.append(.sidebarPreferencesChanged(next.sidebarPreferences)) }
        if previous.acpAgents != next.acpAgents { events.append(.acpAgentsReplaced(next.acpAgents)) }
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
                    if old.id == message.id, old.role == message.role, old.createdAt == message.createdAt, old.attachments == message.attachments, old.providerEntity == message.providerEntity, old.submissionError == message.submissionError, old.runReference == message.runReference, old.removedByHistoryOperationID == message.removedByHistoryOperationID, message.text.utf8.starts(with: old.text.utf8) {
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
