import Foundation

/// Full native transcript stays on the host. Passing an admission through the
/// Engine does not put its configuration/transcript payload on reducer stacks.
public struct AgentSessionImportAdmission: Codable, Sendable, Equatable {
    private struct Payload: Codable, Sendable, Equatable {
        let review: AgentSessionImportReview
        let configuration: ProviderConfiguration
        let projectIncarnation: UUID
        let nativeHomePath: String
    }
    private var storage: [Payload]
    public var review: AgentSessionImportReview { storage[0].review }
    public var configuration: ProviderConfiguration { storage[0].configuration }
    public var projectIncarnation: UUID { storage[0].projectIncarnation }
    public var nativeHomePath: String { storage[0].nativeHomePath }
    public init(review: AgentSessionImportReview, configuration: ProviderConfiguration, projectIncarnation: UUID) {
        storage = [.init(review: review, configuration: configuration, projectIncarnation: projectIncarnation,
            nativeHomePath: URL(fileURLWithPath: review.profile.transcriptsRoot).standardizedFileURL.resolvingSymlinksInPath().path)]
    }
    public init(from decoder: any Decoder) throws { storage = [try Payload(from: decoder)] }
    public func encode(to encoder: any Encoder) throws { try storage[0].encode(to: encoder) }
}

/// Sticky provenance survives archiving/deletion and protects an imported
/// conversation even when a user later puts its visible fields back unchanged.
public struct AgentSessionImportRecord: Codable, Sendable, Equatable, Identifiable {
    private struct Payload: Codable, Sendable, Equatable {
        let threadID: UUID, providerInstanceID: UUID
        let provider: AgentSessionSource, nativeSessionID: String, nativeHomePath: String
        let projectID: UUID, workspacePath: String, reviewID: UUID, reviewDigest: String
        let sources: [AgentSessionImportSource], lastCommandID: UUID, originalContentFingerprint: String
        var modified: Bool, tombstoned: Bool
    }
    private var storage: [Payload]
    public var id: UUID { threadID }
    public var threadID: UUID { storage[0].threadID }
    public var providerInstanceID: UUID { storage[0].providerInstanceID }
    public var provider: AgentSessionSource { storage[0].provider }
    public var nativeSessionID: String { storage[0].nativeSessionID }
    public var nativeHomePath: String { storage[0].nativeHomePath }
    public var projectID: UUID { storage[0].projectID }
    public var workspacePath: String { storage[0].workspacePath }
    public var reviewID: UUID { storage[0].reviewID }
    public var reviewDigest: String { storage[0].reviewDigest }
    public var sources: [AgentSessionImportSource] { storage[0].sources }
    public var lastCommandID: UUID { storage[0].lastCommandID }
    public var originalContentFingerprint: String { storage[0].originalContentFingerprint }
    public var modified: Bool { storage[0].modified }
    public var tombstoned: Bool { storage[0].tombstoned }
    init(admission: AgentSessionImportAdmission, thread: CodingThread, commandID: UUID, previousSources: [AgentSessionImportSource] = []) throws {
        let current = admission.review.sources
        let sources = previousSources.filter { old in !current.contains(where: { $0.providerInstanceID == old.providerInstanceID && $0.filePath.utf8.elementsEqual(old.filePath.utf8) }) } + current
        storage = [.init(threadID: thread.id, providerInstanceID: admission.review.transcript.providerInstanceID,
            provider: admission.review.transcript.source, nativeSessionID: admission.review.transcript.providerSessionID,
            nativeHomePath: admission.nativeHomePath, projectID: thread.projectID, workspacePath: thread.workspacePath,
            reviewID: admission.review.id, reviewDigest: admission.review.digest, sources: sources,
            lastCommandID: commandID, originalContentFingerprint: try AgentSessionImportProtocol.digest(thread), modified: false, tombstoned: false)]
    }
    mutating func markModified() { storage[0].modified = true }
    mutating func markTombstoned() { storage[0].modified = true; storage[0].tombstoned = true }
    public init(from decoder: any Decoder) throws { storage = [try Payload(from: decoder)] }
    public func encode(to encoder: any Encoder) throws { try storage[0].encode(to: encoder) }
}

extension WorkspaceDecision {
    /// Engine has already revalidated the exact leased review, provider profile,
    /// project incarnation, physical home and source files before reduction.
    @inline(never)
    mutating func acceptAgentSessionImport(_ admission: AgentSessionImportAdmission, id commandID: UUID, now: Date) throws {
        let review = admission.review, transcript = review.transcript, configuration = admission.configuration
        guard let project = snapshot.projects.first(where: { $0.id == review.projectID }),
              project.path.utf8.elementsEqual(review.expectedWorkspaceRoot.utf8), project.clone?.isReady ?? true,
              transcript.workspacePath.utf8.elementsEqual(review.expectedWorkspaceRoot.utf8),
              configuration.workspacePath.utf8.elementsEqual(review.expectedWorkspaceRoot.utf8),
              configuration.provider == transcript.source.provider, review.profile.source == transcript.source,
              transcript.providerInstanceID == review.profile.id,
              try AppMCPAdmission.instanceID(configuration: configuration) == review.profile.id,
              AgentSessionImportOwnership.sameSession(configuration.nativeThreadID, transcript.providerSessionID),
              !transcript.messages.isEmpty, transcript.messages.count <= AgentSessionImportProtocol.maximumMessages,
              transcript.messages.allSatisfy({ ($0.role == .user || $0.role == .assistant) && $0.createdAt.timeIntervalSince1970.isFinite }),
              transcript.createdAt.timeIntervalSince1970.isFinite, transcript.updatedAt.timeIntervalSince1970.isFinite,
              !transcript.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              AgentSessionImportOwnership.validPath(admission.nativeHomePath), !review.sources.isEmpty,
              review.sources.allSatisfy({ $0.provider == transcript.source && $0.providerInstanceID == review.profile.id && AgentSessionImportOwnership.sameSession($0.providerSessionID, transcript.providerSessionID) }),
              try AgentSessionImportOwnership.matchesProfile(configuration, review.profile) else { throw Self.importRefusal() }
        let threadID = AgentSessionImportProtocol.threadID(providerInstanceID: transcript.providerInstanceID, providerSessionID: transcript.providerSessionID)
        let records = snapshot.agentSessionImports ?? [], prior = records.first { $0.threadID == threadID }
        if let prior {
            guard !prior.modified, !prior.tombstoned, prior.projectID == project.id,
                  prior.workspacePath.utf8.elementsEqual(project.path.utf8), prior.provider == transcript.source,
                  prior.providerInstanceID == transcript.providerInstanceID,
                  prior.nativeHomePath.utf8.elementsEqual(admission.nativeHomePath.utf8),
                  AgentSessionImportOwnership.sameSession(prior.nativeSessionID, transcript.providerSessionID),
                  let current = snapshot.threads.first(where: { $0.id == threadID }), !current.isArchived,
                  try AgentSessionImportProtocol.digest(current) == prior.originalContentFingerprint else { throw Self.importRefusal() }
        } else {
            guard !snapshot.threads.contains(where: { $0.id == threadID }),
                  !snapshot.projects.contains(where: { $0.id == threadID }),
                  !snapshot.pullRequestCheckoutReservedIDs.contains(threadID), !snapshot.promptSteeringReservedIDs.contains(threadID),
                  !snapshot.conversationHistoryMaintenanceReservedIDs.contains(threadID),
                  !(snapshot.conversationHistoryOperations ?? []).contains(where: { $0.review.targetThreadID == threadID }) else { throw Self.importRefusal() }
        }
        guard !records.contains(where: { $0.threadID != threadID && AgentSessionImportOwnership.matches($0, admission: admission) }),
              !AgentSessionImportOwnership.isOwned(snapshot, admission: admission, excludingThreadID: prior == nil ? nil : threadID),
              !snapshot.isPullRequestCreationLocked(path: project.path), !snapshot.isPullRequestCheckoutLocked(path: project.path),
              !snapshot.isCheckpointRestoreLocked(path: project.path),
              !snapshot.isClaudeHistoryScopeLocked(configuration: configuration, nativeThreadID: configuration.nativeThreadID) else { throw Self.importRefusal() }
        if let current = snapshot.threads.first(where: { $0.id == threadID }) {
            guard !current.isBusy, current.runtimeID == nil, current.runtimeRequests.isEmpty, current.queuedTurns.isEmpty,
                  snapshot.workspaceReady(for: current), !snapshot.isConversationHistoryLocked(threadID: threadID),
                  !snapshot.hasUnresolvedContextDelivery(threadID: threadID) else { throw Self.importRefusal() }
        }
        var thread = CodingThread(project: project)
        thread.id = threadID; thread.applyContextConfiguration(configuration)
        thread.title = transcript.title; thread.createdAt = transcript.createdAt; thread.updatedAt = transcript.updatedAt
        thread.messages = transcript.messages.enumerated().map { index, row in
            var message = ChatMessage(id: "agent-session-import:" + threadID.uuidString + ":" + String(index), role: row.role, text: row.text)
            message.createdAt = row.createdAt; return message
        }
        // Imported history is observed text, never an attributed native run or a
        // history/checkpoint proof. No setup hook is discovered or executed.
        thread.state = .idle; thread.queuePaused = true
        thread.settlement = .init(id: TaskOrchestration.derivedID(threadID, "agent-session-import:settled"), settledAt: transcript.updatedAt)
        let record = try AgentSessionImportRecord(admission: admission, thread: thread, commandID: commandID, previousSources: prior?.sources ?? [])
        var nextRecords = records.filter { $0.threadID != threadID }; nextRecords.append(record)
        guard nextRecords.count <= 20_000, try AgentSessionImportProtocol.payload(nextRecords).count <= 128 * 1_024 * 1_024 else { throw AgentSessionImportError.limit }
        if let index = snapshot.threads.firstIndex(where: { $0.id == threadID }) { snapshot.threads[index] = thread }
        else { snapshot.threads.insert(thread, at: 0) }
        snapshot.agentSessionImports = nextRecords
    }
    private static func importRefusal() -> WorkspaceCommandError { .init("This native session is already owned, its project changed, or the imported conversation has been edited. Scan again and preserve the existing conversation.") }
}

extension WorkspaceSnapshot {
    /// Run once at the Engine commit gate, after all command reductions. The
    /// sticky bit detects a real edit before a later command can revert it.
    mutating func reconcileAgentSessionImports(previous: WorkspaceSnapshot) throws {
        guard var records = agentSessionImports else { return }
        for index in records.indices {
            let record = records[index]
            guard let old = previous.agentSessionImports?.first(where: { $0.threadID == record.threadID }),
                  old.lastCommandID == record.lastCommandID else { continue }
            if old.modified { records[index].markModified() }
            if old.tombstoned { records[index].markTombstoned() }
            guard let thread = threads.first(where: { $0.id == record.threadID }), projects.contains(where: { $0.id == record.projectID }) else {
                records[index].markTombstoned(); continue
            }
            if thread.isArchived { records[index].markTombstoned() }
            if try AgentSessionImportProtocol.digest(thread) != record.originalContentFingerprint { records[index].markModified() }
        }
        agentSessionImports = records
    }
    func validateAgentSessionImports() throws {
        let records = agentSessionImports ?? []
        guard records.count <= 20_000, Set(records.map(\.threadID)).count == records.count,
              try AgentSessionImportProtocol.payload(records).count <= 128 * 1_024 * 1_024 else { throw AgentSessionImportError.invalidRequest }
        var namespaces: Set<String> = []
        for record in records {
            guard record.threadID == AgentSessionImportProtocol.threadID(providerInstanceID: record.providerInstanceID, providerSessionID: record.nativeSessionID),
                  AgentSessionImportOwnership.validPath(record.nativeHomePath), AgentSessionImportOwnership.validPath(record.workspacePath),
                  !record.nativeSessionID.isEmpty, record.nativeSessionID.utf8.count <= 4_096, !record.nativeSessionID.contains("\0"),
                  AgentSessionImportOwnership.isDigest(record.reviewDigest), AgentSessionImportOwnership.isDigest(record.originalContentFingerprint),
                  !record.sources.isEmpty, record.sources.count <= 10_000,
                  record.sources.allSatisfy({ source in
                      source.provider == record.provider && source.providerInstanceID == record.providerInstanceID &&
                      AgentSessionImportOwnership.sameSession(source.providerSessionID, record.nativeSessionID) &&
                      AgentSessionImportOwnership.validPath(source.filePath) && AgentSessionImportOwnership.isDigest(source.digest) && source.size <= UInt64(AgentSessionImportProtocol.maximumTranscriptBytes)
                  }), namespaces.insert(AgentSessionImportOwnership.key(provider: record.provider, home: record.nativeHomePath, native: record.nativeSessionID)).inserted else { throw AgentSessionImportError.invalidRequest }
            if !record.tombstoned {
                guard let thread = threads.first(where: { $0.id == record.threadID }), thread.projectID == record.projectID,
                      projects.contains(where: { $0.id == record.projectID }) else { throw AgentSessionImportError.invalidRequest }
                if !record.modified { guard try AgentSessionImportProtocol.digest(thread) == record.originalContentFingerprint else { throw AgentSessionImportError.invalidRequest } }
            }
        }
    }
}

private enum AgentSessionImportOwnership {
    static func validPath(_ path: String) -> Bool { path.hasPrefix("/") && path != "/" && path.utf8.count <= 16_384 && !path.contains("\0") && URL(fileURLWithPath: path).standardizedFileURL.path.utf8.elementsEqual(path.utf8) }
    static func isDigest(_ value: String) -> Bool { value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
    static func sameSession(_ lhs: String?, _ rhs: String) -> Bool {
        guard let lhs else { return false }; if let a = UUID(uuidString: lhs), let b = UUID(uuidString: rhs) { return a == b }; return lhs.utf8.elementsEqual(rhs.utf8)
    }
    static func key(provider: AgentSessionSource, home: String, native: String) -> String {
        provider.rawValue + ":" + Data(home.utf8).base64EncodedString() + ":" + (UUID(uuidString: native)?.uuidString ?? Data(native.utf8).base64EncodedString())
    }
    static func matches(_ record: AgentSessionImportRecord, admission: AgentSessionImportAdmission) -> Bool {
        record.provider == admission.review.transcript.source && sameSession(record.nativeSessionID, admission.review.transcript.providerSessionID) &&
            (record.providerInstanceID == admission.review.profile.id || record.nativeHomePath.utf8.elementsEqual(admission.nativeHomePath.utf8))
    }
    static func matchesProfile(_ configuration: ProviderConfiguration, _ profile: AgentSessionProfile) throws -> Bool {
        switch profile.source {
        case .codex:
            try configuration.codexRuntimeConfiguration?.validate()
            return try AgentSessionImportProtocol.payload(configuration.codexRuntimeConfiguration) == AgentSessionImportProtocol.payload(profile.configuration.codexRuntimeConfiguration)
        case .claudeAgent:
            try configuration.validateClaudeConfiguration()
            guard let original = profile.configuration.claudeRuntimeConfiguration, let actual = configuration.claudeRuntimeConfiguration else { return false }
            let expected = try original.replacingWorkspace(configuration.workspacePath, physicalPath: configuration.workspacePath)
            return try AgentSessionImportProtocol.payload(actual) == AgentSessionImportProtocol.payload(expected) && configuration.claudeLaunchSelection == nil
        }
    }
    static func isOwned(_ snapshot: WorkspaceSnapshot, admission: AgentSessionImportAdmission, excludingThreadID: UUID?) -> Bool {
        let profile = admission.review.profile, native = admission.review.transcript.providerSessionID
        func owned(_ configuration: ProviderConfiguration, _ nativeID: String?) -> Bool {
            guard configuration.provider == profile.source.provider, sameSession(nativeID ?? configuration.nativeThreadID, native) else { return false }
            if (try? AppMCPAdmission.instanceID(configuration: configuration)) == profile.id { return true }
            // An uncaptured/default Codex launch did not record its actual
            // home. A different instance cannot prove native isolation, and
            // today's ambient HOME cannot establish that past launch's scope.
            if configuration.provider == .codex, configuration.codexRuntimeConfiguration?.homeDirectory == nil { return true }
            let home = configuration.provider == .claude ? configuration.claudeRuntimeConfiguration?.configurationDirectory : configuration.codexRuntimeConfiguration?.homeDirectory
            return home.map { URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path.utf8.elementsEqual(admission.nativeHomePath.utf8) } ?? false
        }
        for thread in snapshot.threads where thread.id != excludingThreadID {
            if owned(.init(thread: thread), thread.providerThreadID) { return true }
            if let run = thread.activeRun, owned(run.configuration, run.configuration.nativeThreadID) { return true }
            if thread.queuedTurns.contains(where: { owned($0.configuration, $0.configuration.nativeThreadID) }) { return true }
            if (thread.runHistory ?? []).contains(where: { owned($0.configuration, $0.providerThreadID) }) { return true }
            if (thread.contextProviderBindings ?? []).contains(where: { owned($0.configuration, $0.configuration.nativeThreadID) }) { return true }
        }
        for operation in snapshot.conversationHistoryOperations ?? [] {
            if operation.review.sourceThreadID == excludingThreadID || operation.review.targetThreadID == excludingThreadID { continue }
            if owned(operation.review.sourceConfiguration, operation.review.sourceReference.nativeThreadID) ||
                owned(operation.review.targetConfiguration, operation.result?.reference.nativeThreadID) { return true }
            if let publication = operation.claudeForkPublication, owned(operation.review.targetConfiguration, publication.target.sessionID) { return true }
        }
        for transfer in snapshot.contextTransfers ?? [] {
            if transfer.sourceThreadID == excludingThreadID || transfer.targetThreadID == excludingThreadID { continue }
            if owned(transfer.review.sourceConfiguration, transfer.review.sourceConfiguration.nativeThreadID) ||
                owned(transfer.review.targetConfiguration, transfer.delivery?.nativeResult?.reference.nativeThreadID) { return true }
            if let publication = transfer.delivery?.claudePublication, owned(transfer.review.targetConfiguration, publication.target.sessionID) { return true }
        }
        return false
    }
}
