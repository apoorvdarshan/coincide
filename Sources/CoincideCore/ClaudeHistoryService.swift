import Foundation

/// Transient bytes are never serialized. Only publication may enter the durable
/// operation, before the first external file write.
public struct ClaudeHistoryForkPlan: Sendable {
    public let review: ClaudeHistoryReviewEvidence
    public let publication: ClaudeTranscriptPublication
    fileprivate let transcriptPlan: ClaudeTranscriptForkPlan
}

public enum ClaudeHistoryForkInspection: Sendable, Equatable {
    case notStarted
    case incomplete
    case ready(ClaudeHistoryResult)
}

/// Native history I/O only. The Engine owns quietness, source locks, actor drain
/// and durable admission. This service never launches Claude, scans another
/// account/project, sends a prompt, deletes a transcript, or retries a write.
public struct ClaudeHistoryService: Sendable {
    public let configuration: ClaudeRuntimeConfiguration
    private let store: ClaudeTranscriptStore

    public init(configuration: ClaudeRuntimeConfiguration) throws {
        try configuration.validate()
        self.configuration = configuration
        store = try .init(configurationDirectory: URL(fileURLWithPath: configuration.configurationDirectory),
                          workspace: URL(fileURLWithPath: configuration.workspacePath),
                          projectDirectoryName: configuration.projectDirectoryName)
        guard store.workspacePath == configuration.workspacePath else { throw ClaudeHistoryValidation.invalid() }
    }

    public func snapshot(sessionID: String, selection: ClaudeResumeSelection? = nil) throws -> ClaudeHistorySnapshot {
        try ClaudeRuntimeValidation.uuid(sessionID)
        if let selection {
            try selection.validate(runtime: configuration)
            guard selection.nativeSessionID == sessionID else { throw ClaudeHistoryValidation.invalid() }
            if selection.kind == .freshSession {
                // Empty is evidence of this exclusively reserved session, never
                // a fallback for unreadable or already-created native context.
                do {
                    _ = try store.read(sessionID: sessionID)
                    throw ClaudeTranscriptStoreError(.sourceChanged)
                } catch let error as ClaudeTranscriptStoreError where error.kind == .notFound {
                    return try .init(reference: .init(provider: .claude, nativeThreadID: sessionID), runtimeIdentity: configuration.runtimeIdentity,
                                     sourceLocation: nil, sourceRevision: nil, records: [], selectedMessages: [], selectedChainIDs: [], selection: selection)
                }
            }
        }
        return try snapshot(try store.read(sessionID: sessionID), selection: selection)
    }

    public func prepareFork(review: ClaudeHistoryReviewEvidence, targetSessionID: String) throws -> ClaudeHistoryForkPlan {
        try requireCurrent(review)
        guard review.kind == .forkAfterRun, case .throughMessage(let cursor) = review.boundary else { throw ClaudeHistoryValidation.invalid() }
        let raw = try store.read(sessionID: review.source.reference.nativeThreadID)
        guard raw.location == review.source.sourceLocation, raw.revision == review.source.sourceRevision else { throw ClaudeTranscriptStoreError(.sourceChanged) }
        let transcriptPlan = try store.prepareFork(source: raw, upToMessageID: cursor, targetSessionID: targetSessionID)
        try review.validatePublication(transcriptPlan.publication)
        return .init(review: review, publication: transcriptPlan.publication, transcriptPlan: transcriptPlan)
    }

    /// The callback must return only after the exact reservation is journaled.
    /// A failed/lost callback cannot publish; a post-create failure is preserved
    /// by the transcript store and can only be inspected with that reservation.
    public func publishFork(_ plan: ClaudeHistoryForkPlan,
                            reservation: @Sendable (ClaudeTranscriptPublication) async throws -> Void) async throws -> ClaudeHistoryResult {
        try requireCurrent(plan.review)
        try plan.review.validatePublication(plan.publication)
        guard plan.publication == plan.transcriptPlan.publication else { throw ClaudeHistoryValidation.invalid() }
        try Task.checkCancellation()
        try await reservation(plan.publication)
        try Task.checkCancellation()
        try requireCurrent(plan.review)
        _ = try store.publish(plan.transcriptPlan)
        switch try inspectFork(review: plan.review, publication: plan.publication) {
        case .ready(let result): return result
        case .notStarted, .incomplete: throw ClaudeTranscriptStoreError(.publicationUncertain)
        }
    }

    public func inspectFork(review: ClaudeHistoryReviewEvidence, publication: ClaudeTranscriptPublication) throws -> ClaudeHistoryForkInspection {
        try requireCurrent(review); try review.validatePublication(publication)
        switch try store.inspect(publication) {
        case .notStarted: return .notStarted
        case .incomplete: return .incomplete
        case .ready(let raw):
            let observed = try snapshot(raw, selection: nil)
            guard let cursor = publication.headMessageID else { throw ClaudeHistoryValidation.invalid() }
            let inherited = try ClaudeInheritedHead(runtimeIdentity: configuration.runtimeIdentity,
                                                    nativeSessionID: publication.target.sessionID, cursor: cursor)
            let result = ClaudeHistoryResult.fork(snapshot: observed, publication: publication, inheritedHead: inherited)
            try review.validateResult(result)
            // A read-only proof cannot silently outlive a changing source.
            try requireCurrent(review)
            return .ready(result)
        }
    }

    public func prepareRewind(review: ClaudeHistoryReviewEvidence, selectionID: UUID) throws -> ClaudeHistoryResult {
        try requireCurrent(review)
        guard review.kind == .rewindBeforeRun else { throw ClaudeHistoryValidation.invalid() }
        let selection: ClaudeResumeSelection
        switch review.boundary {
        case .throughMessage(let cursor):
            guard let location = review.source.sourceLocation, let revision = review.source.sourceRevision,
                  let opening = review.inputs.first(where: { $0.runID == review.runID })?.openingInputID else { throw ClaudeHistoryValidation.invalid() }
            selection = try .init(id: selectionID, nativeSessionID: review.source.reference.nativeThreadID, cursor: cursor,
                                  discardedInputID: opening, kind: .resumeAt, reviewedLocation: location, reviewedRevision: revision)
        case .freshSession(let id):
            // The fresh UUID is a reviewed reservation. Do not replace it with
            // another UUID or use an existing native file after acceptance.
            do {
                _ = try store.read(sessionID: id)
                throw ClaudeTranscriptStoreError(.collision)
            } catch let error as ClaudeTranscriptStoreError where error.kind == .notFound { }
            selection = try .init(id: selectionID, nativeSessionID: id, kind: .freshSession)
        }
        let result = ClaudeHistoryResult.contextSelected(source: review.source, selection: selection)
        try review.validateResult(result); try requireCurrent(review)
        return result
    }

    private func requireCurrent(_ review: ClaudeHistoryReviewEvidence) throws {
        try review.validate()
        guard review.source.runtimeIdentity == configuration.runtimeIdentity,
              try snapshot(sessionID: review.source.reference.nativeThreadID, selection: review.source.selection) == review.source else {
            throw ClaudeTranscriptStoreError(.sourceChanged)
        }
    }

    private func snapshot(_ raw: ClaudeTranscriptSnapshot, selection: ClaudeResumeSelection?) throws -> ClaudeHistorySnapshot {
        let chain: [JSONValue], messages: [JSONValue]
        if let selection {
            guard selection.kind == .resumeAt, selection.reviewedLocation == raw.location,
                  selection.reviewedRevision == raw.revision, let cursor = selection.cursor else { throw ClaudeTranscriptStoreError(.sourceChanged) }
            let selected = try raw.transcript.selected(upToMessageID: cursor)
            chain = selected.selectedChainRecords; messages = selected.selectedMessages
        } else {
            chain = raw.transcript.selectedChainRecords; messages = raw.transcript.selectedMessages
        }
        return try .init(reference: .init(provider: .claude, nativeThreadID: raw.location.sessionID),
                         runtimeIdentity: configuration.runtimeIdentity, sourceLocation: raw.location, sourceRevision: raw.revision,
                         records: raw.transcript.records.map { try .init($0) },
                         selectedMessages: messages.map { try .init($0, projected: true) },
                         selectedChainIDs: chain.compactMap { $0["uuid"].string }, selection: selection)
    }
}
