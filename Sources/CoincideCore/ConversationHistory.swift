import CryptoKit
import Foundation

public enum ConversationHistoryKind: String, Codable, Sendable { case forkAfterRun, rewindBeforeRun }
public enum ConversationHistoryPhase: String, Codable, Sendable { case accepted, dispatching, applied, failed, unconfirmed }
public enum ConversationHistoryReconciliation: Codable, Sendable, Equatable {
    case applied(ProviderConversationSnapshot)
    case unchanged
    case openCodeV2Unchanged(OpenCodeV2HistorySnapshot)
    case openCodeV1NotAdopted(OpenCodeV1HistorySnapshot)
    case claudeForkNotStarted(ClaudeHistorySnapshot)
    case piOriginalKept(PiHistorySnapshot)
}

/// A reviewed local/provider history boundary. Creating this value never performs
/// provider work; the engine persists it before the corresponding outbox effect.
public struct ConversationHistoryReview: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let kind: ConversationHistoryKind
    public let reviewedAt: Date
    public let sourceThreadID: UUID
    public let projectID: UUID
    public let runID: UUID
    public let sourceIncarnation: UUID
    public let sourceConfiguration: ProviderConfiguration
    public let targetConfiguration: ProviderConfiguration
    public let sourceReference: ProviderConversationReference
    public let reviewedHeadTurnID: String?
    public let boundary: ProviderHistoryBoundary
    public let expectedResultHeadTurnID: String?
    public let prefix: [ChatMessage]
    public let removedRunIDs: [UUID]
    public let removedMessageIDs: [String]
    public let sourceFingerprint: String
    public let targetThreadID: UUID?
    public let suggestedTitle: String
    public let files: ConversationHistoryFilesReview?
    public let recallPromptOnSuccess: Bool?
    public let openCodeV2: OpenCodeV2HistoryReviewEvidence?
    public let openCodeV1: OpenCodeV1HistoryReviewEvidence?
    public let claude: ClaudeHistoryReviewEvidence?
    public let pi: PiHistoryReviewEvidence?
    public init(id: UUID = UUID(), kind: ConversationHistoryKind, reviewedAt: Date = Date(), sourceThreadID: UUID,
                projectID: UUID, runID: UUID, sourceIncarnation: UUID, sourceConfiguration: ProviderConfiguration,
                targetConfiguration: ProviderConfiguration, sourceReference: ProviderConversationReference,
                reviewedHeadTurnID: String?, boundary: ProviderHistoryBoundary, expectedResultHeadTurnID: String?,
                prefix: [ChatMessage], removedRunIDs: [UUID], removedMessageIDs: [String], sourceFingerprint: String,
                targetThreadID: UUID?, suggestedTitle: String, files: ConversationHistoryFilesReview? = nil, recallPromptOnSuccess: Bool? = nil,
                openCodeV2: OpenCodeV2HistoryReviewEvidence? = nil,
                openCodeV1: OpenCodeV1HistoryReviewEvidence? = nil, claude: ClaudeHistoryReviewEvidence? = nil,
                pi: PiHistoryReviewEvidence? = nil) throws {
        self.id = id; self.kind = kind; self.reviewedAt = reviewedAt; self.sourceThreadID = sourceThreadID
        self.projectID = projectID; self.runID = runID; self.sourceIncarnation = sourceIncarnation
        self.sourceConfiguration = sourceConfiguration; self.targetConfiguration = targetConfiguration
        self.sourceReference = sourceReference; self.reviewedHeadTurnID = reviewedHeadTurnID; self.boundary = boundary
        self.expectedResultHeadTurnID = expectedResultHeadTurnID; self.prefix = prefix; self.removedRunIDs = removedRunIDs
        self.removedMessageIDs = removedMessageIDs; self.sourceFingerprint = sourceFingerprint
        self.targetThreadID = targetThreadID; self.suggestedTitle = suggestedTitle
        self.files = files; self.recallPromptOnSuccess = recallPromptOnSuccess
        self.openCodeV2 = openCodeV2
        self.openCodeV1 = openCodeV1
        self.claude = claude
        self.pi = pi
        try validate()
    }
    public func validate() throws {
        try sourceReference.validate(); try boundary.validate()
        try sourceConfiguration.validateClaudeConfiguration(); try targetConfiguration.validateClaudeConfiguration()
        if let reviewedHeadTurnID { try ProviderHistoryValidation.id(reviewedHeadTurnID) }
        if let expectedResultHeadTurnID { try ProviderHistoryValidation.id(expectedResultHeadTurnID) }
        try ProviderHistoryValidation.path(sourceConfiguration.workspacePath); try ProviderHistoryValidation.path(targetConfiguration.workspacePath)
        guard reviewedAt.timeIntervalSince1970.isFinite,
              sourceConfiguration.provider == sourceReference.provider, targetConfiguration.provider == sourceReference.provider,
              sourceConfiguration.nativeThreadID == sourceReference.nativeThreadID,
              sourceConfiguration.workspacePath == targetConfiguration.workspacePath,
              sourceConfiguration.codexRuntimeBinding == targetConfiguration.codexRuntimeBinding,
              sourceFingerprint.utf8.count == 64, sourceFingerprint.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              Set(prefix.map(\.id)).count == prefix.count, prefix.allSatisfy({ $0.removedByHistoryOperationID == nil }),
              Set(removedRunIDs).count == removedRunIDs.count, Set(removedMessageIDs).count == removedMessageIDs.count,
              !suggestedTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, suggestedTitle.utf8.count <= 4_096,
              !suggestedTitle.contains("\0"), try JSONEncoder().encode(prefix).count <= 4_194_304 else {
            throw CoincideError("This conversation history review is invalid or exceeds its bounded transcript limit.")
        }
        guard [openCodeV1 != nil, openCodeV2 != nil, claude != nil, pi != nil].filter({ $0 }).count <= 1 else { throw CoincideError("A history review cannot combine native provider evidence.") }
        if let pi {
            try pi.validate()
            guard sourceReference.provider == .pi, reviewedHeadTurnID == nil, expectedResultHeadTurnID == nil,
                  pi.operationID == id, pi.source.reference == sourceReference,
                  pi.source.matchesBinding(sourceConfiguration), pi.source.matchesBinding(targetConfiguration),
                  pi.runID == runID, pi.kind == kind, boundary == pi.boundary.providerBoundary else {
                throw CoincideError("The Pi history review has inconsistent native entry ownership.")
            }
        } else if let claude {
            try claude.validate()
            guard sourceReference.provider == .claude, reviewedHeadTurnID == nil, expectedResultHeadTurnID == nil,
                  claude.source.reference == sourceReference, claude.source.matchesBinding(sourceConfiguration),
                  claude.source.matchesBinding(targetConfiguration), claude.runID == runID, claude.kind == kind,
                  boundary == claude.boundary.providerBoundary else {
                throw CoincideError("The Claude history review has inconsistent native input ownership.")
            }
        } else if let openCodeV1 {
            try openCodeV1.validate()
            guard sourceReference.provider == .opencode, reviewedHeadTurnID == nil, expectedResultHeadTurnID == nil,
                  openCodeV1.source.reference == sourceReference, openCodeV1.source.workspacePath == sourceConfiguration.workspacePath,
                  openCodeV1.source.runtimeIdentity == sourceConfiguration.openCodeConfiguration?.runtimeIdentity,
                  openCodeV1.source.runtimeIdentity == targetConfiguration.openCodeConfiguration?.runtimeIdentity,
                  sourceConfiguration.openCodeConfiguration?.generation == .v1,
                  openCodeV1.boundary == boundary,
                  openCodeV1.inputs.contains(where: { $0.runID == runID && $0.openingMessageID == openCodeV1.selectedOpeningMessageID }) else {
                throw CoincideError("The OpenCode history review has inconsistent native message ownership.")
            }
        } else if let openCodeV2 {
            try openCodeV2.validate()
            guard sourceReference.provider == .opencode, reviewedHeadTurnID == nil, expectedResultHeadTurnID == nil,
                  openCodeV2.source.reference == sourceReference, openCodeV2.source.workspacePath == sourceConfiguration.workspacePath,
                  openCodeV2.source.runtimeIdentity == sourceConfiguration.openCodeConfiguration?.runtimeIdentity,
                  openCodeV2.source.runtimeIdentity == targetConfiguration.openCodeConfiguration?.runtimeIdentity,
                  sourceConfiguration.openCodeConfiguration?.generation == .v2,
                  openCodeV2.boundary == boundary,
                  openCodeV2.inputs.contains(where: { $0.runID == runID && $0.openingMessageID == openCodeV2.selectedOpeningMessageID }) else {
                throw CoincideError("The OpenCode history review has inconsistent native message ownership.")
            }
        } else {
            guard sourceReference.provider == .codex, reviewedHeadTurnID != nil else {
                throw CoincideError("This conversation has no supported reviewed history evidence.")
            }
        }
        switch kind {
        case .forkAfterRun:
            guard targetThreadID != nil, targetThreadID != sourceThreadID, targetThreadID != id,
                  removedRunIDs.isEmpty, removedMessageIDs.isEmpty else { throw CoincideError("The fork review has inconsistent ownership or turn boundaries.") }
            if pi != nil {
                switch boundary { case .head, .beforePiUserEntry: break; default: throw ProviderHistoryError(.boundaryUnavailable) }
            } else if claude != nil {
                guard case .throughClaudeMessage = boundary else { throw ProviderHistoryError(.boundaryUnavailable) }
            } else if openCodeV2 != nil || openCodeV1 != nil {
                switch boundary { case .beforeMessage, .head: break; default: throw CoincideError("The OpenCode fork has no exact message cut.") }
            } else {
                guard case .throughTurn(let turn) = boundary, expectedResultHeadTurnID == turn else { throw CoincideError("The fork review has inconsistent ownership or turn boundaries.") }
            }
        case .rewindBeforeRun:
            guard targetThreadID == nil, removedRunIDs.contains(runID), !removedMessageIDs.isEmpty else { throw CoincideError("The rewind review has no exact retained transcript suffix.") }
            if pi != nil {
                switch boundary { case .head, .beforePiUserEntry, .freshPiSession: break; default: throw ProviderHistoryError(.boundaryUnavailable) }
            } else if claude != nil {
                switch boundary { case .throughClaudeMessage, .freshClaudeSession: break; default: throw ProviderHistoryError(.boundaryUnavailable) }
            } else if let openCodeV1 {
                guard boundary == .beforeMessage(openCodeV1.selectedOpeningMessageID) else { throw CoincideError("The OpenCode rewind does not precede its selected input.") }
            } else if let openCodeV2 {
                guard boundary == .beforeMessage(openCodeV2.selectedOpeningMessageID) else { throw CoincideError("The OpenCode rewind does not precede its selected input.") }
            } else {
                guard case .beforeTurn = boundary else { throw CoincideError("The conversation history action does not match its reviewed boundary.") }
            }
        }
        guard kind == .rewindBeforeRun || (files == nil && recallPromptOnSuccess != true) else { throw CoincideError("Only a rewind can restore files or recall its opening input.") }
        if let files {
            try files.validate()
            guard files.id != id, files.target.selectedRunID == runID,
                  files.gitReview.currentPlan.workspacePath == sourceConfiguration.workspacePath else { throw CoincideError("The rewind file review belongs to another boundary or workspace.") }
        }
    }
    public func validateResult(_ result: ProviderConversationSnapshot) throws {
        try result.validate()
        let referenceMatches: Bool
        if pi != nil {
            referenceMatches = result.pi?.source.reference == sourceReference
        } else if case .freshClaudeSession(let nativeID) = boundary, kind == .rewindBeforeRun {
            referenceMatches = result.reference.nativeThreadID == nativeID && result.reference != sourceReference
        } else { referenceMatches = kind == .forkAfterRun || openCodeV1 != nil ? result.reference != sourceReference : result.reference == sourceReference }
        guard referenceMatches, result.reference.provider == sourceReference.provider,
              result.workspacePath == targetConfiguration.workspacePath else {
            throw CoincideError("The conversation history result does not match its reviewed provider boundary.")
        }
        if let pi {
            guard result.historyMode == .entryTree, result.headTurnID == nil, let evidence = result.pi,
                  evidence.snapshot.matchesBinding(targetConfiguration) else {
                throw CoincideError("Pi did not return its reviewed native entry-tree evidence.")
            }
            try pi.validateResult(evidence)
        } else if let claude {
            guard result.historyMode == .nativeTranscript, result.headTurnID == nil,
                  result.openCodeV1 == nil, result.openCodeV2 == nil, let evidence = result.claude else {
                throw CoincideError("Claude did not return its reviewed native history evidence.")
            }
            try claude.validateResult(evidence)
            if kind == .rewindBeforeRun, evidence.selection?.id != id { throw ProviderHistoryError(.invalidResponse) }
        } else if let openCodeV1 {
            guard result.historyMode == .messageOrdered, result.headTurnID == nil, result.openCodeV2 == nil,
                  let evidence = result.openCodeV1 else { throw CoincideError("OpenCode did not return its reviewed native message evidence.") }
            try openCodeV1.validateResult(evidence, kind: kind)
        } else if let openCodeV2 {
            guard result.historyMode == .messageOrdered, result.headTurnID == nil, result.openCodeV1 == nil, let evidence = result.openCodeV2 else {
                throw CoincideError("OpenCode did not return its reviewed native message evidence.")
            }
            try openCodeV2.validateResult(evidence, kind: kind)
        } else {
            guard result.historyMode == .paginated, result.openCodeV2 == nil, result.openCodeV1 == nil, result.claude == nil, result.pi == nil, result.headTurnID == expectedResultHeadTurnID else {
                throw CoincideError("The conversation history result does not match its reviewed provider boundary.")
            }
        }
    }
}

public enum ConversationHistoryMaintenancePhase: String, Codable, Sendable {
    case accepted, dispatching, applied, failed, unconfirmed
    public var isWorking: Bool { self == .accepted || self == .dispatching }
}

/// An explicit clear of one reviewed native revert, never a replay of the rewind.
public struct ConversationHistoryMaintenanceAttempt: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let expected: OpenCodeV2HistorySnapshot
    public let sourceIncarnation: UUID
    public var phase: ConversationHistoryMaintenancePhase
    public var result: OpenCodeV2HistorySnapshot?
    public var updatedAt: Date
    public var error: String?
    public static let failureMessage = "The pending provider revert was not cleared. Inspect its current state before trying a new action."
    public static let unconfirmedMessage = "Clearing the pending provider revert could not be confirmed. It was not repeated; conversation work stays paused."
    public init(id: UUID = UUID(), expected: OpenCodeV2HistorySnapshot, sourceIncarnation: UUID, phase: ConversationHistoryMaintenancePhase = .accepted,
                result: OpenCodeV2HistorySnapshot? = nil, updatedAt: Date = Date(), error: String? = nil) {
        self.id = id; self.expected = expected; self.sourceIncarnation = sourceIncarnation
        self.phase = phase; self.result = result; self.updatedAt = updatedAt; self.error = error
    }
    public func validate() throws {
        try expected.validate()
        guard expected.stage != nil, updatedAt.timeIntervalSince1970.isFinite,
              (phase == .applied) == (result != nil) else { throw CoincideError("The provider maintenance attempt has inconsistent evidence.") }
        switch phase {
        case .accepted, .dispatching, .applied:
            guard error == nil else { throw CoincideError("Provider maintenance contains a premature failure.") }
        case .failed:
            guard error == Self.failureMessage else { throw CoincideError("Provider maintenance lost its failure explanation.") }
        case .unconfirmed:
            guard error == Self.unconfirmedMessage else { throw CoincideError("Provider maintenance lost its uncertainty warning.") }
        }
        if let result {
            try result.validate()
            guard result.reference == expected.reference, result.runtimeIdentity == expected.runtimeIdentity,
                  result.workspacePath == expected.workspacePath, result.stage == nil, result.fork == expected.fork,
                  let receipt = result.maintenance, receipt.priorInventoryDigest == expected.inventoryDigest,
                  result.messages.count == expected.messages.count + 1,
                  Array(result.messages.dropLast()) == expected.messages,
                  result.messages.last?.id == receipt.idleMessageID, result.messages.last?.kind == .idle,
                  result.messages.allSatisfy(\.isSettled) else {
                throw CoincideError("The provider maintenance result belongs to another session or retains a revert.")
            }
        }
    }
}

public struct ConversationHistoryOperation: Codable, Sendable, Equatable, Identifiable {
    public let review: ConversationHistoryReview
    public var phase: ConversationHistoryPhase
    public var updatedAt: Date
    public var targetTitle: String?
    public var result: ProviderConversationSnapshot?
    public var error: String?
    public var recalledAt: Date?
    public var files: ConversationHistoryFilesState?
    public var recallDismissedAt: Date?
    public var maintenance: ConversationHistoryMaintenanceAttempt?
    public var previousMaintenanceAttempts: [ConversationHistoryMaintenanceAttempt]?
    public var openCodeV1Candidate: OpenCodeV1HistoryCandidate?
    public var claudeForkPublication: ClaudeTranscriptPublication?
    public var piCandidates: [PiHistoryCandidate]?
    public var piControls: PiHistoryControlState?
    public var scratchFork: ScratchHistoryForkGrant?
    public var id: UUID { review.id }
    public init(review: ConversationHistoryReview, phase: ConversationHistoryPhase = .accepted, updatedAt: Date? = nil,
                targetTitle: String? = nil, result: ProviderConversationSnapshot? = nil, error: String? = nil, recalledAt: Date? = nil,
                files: ConversationHistoryFilesState? = nil, recallDismissedAt: Date? = nil,
                maintenance: ConversationHistoryMaintenanceAttempt? = nil,
                previousMaintenanceAttempts: [ConversationHistoryMaintenanceAttempt]? = nil,
                openCodeV1Candidate: OpenCodeV1HistoryCandidate? = nil, claudeForkPublication: ClaudeTranscriptPublication? = nil,
                piCandidates: [PiHistoryCandidate]? = nil, piControls: PiHistoryControlState? = nil,
                scratchFork: ScratchHistoryForkGrant? = nil) {
        self.review = review; self.phase = phase; self.updatedAt = updatedAt ?? review.reviewedAt
        self.targetTitle = targetTitle; self.result = result; self.error = error; self.recalledAt = recalledAt
        self.files = files ?? review.files.map { .init(review: $0, updatedAt: updatedAt ?? review.reviewedAt) }
        self.recallDismissedAt = recallDismissedAt
        self.maintenance = maintenance; self.previousMaintenanceAttempts = previousMaintenanceAttempts
        self.openCodeV1Candidate = openCodeV1Candidate
        self.claudeForkPublication = claudeForkPublication
        self.piCandidates = piCandidates; self.piControls = piControls; self.scratchFork = scratchFork
    }
    public static let failureMessage = "The conversation history action was not completed. No provider work was replayed."
    public static let unconfirmedMessage = "The provider history outcome could not be confirmed. Inspect it before continuing; the action was not repeated."
    public static let unchangedMessage = "Provider history is unchanged. Review again before retrying."
    public static let openCodeV1NotAdoptedMessage = "The original OpenCode conversation was kept. A separate native conversation may remain; no history action was repeated or native conversation deleted."
    public static let piNotAdoptedMessage = "The original Pi conversation was kept. Separate native files may remain, including an unrecorded result if Pi's reply was lost. No history action was repeated or native file deleted."
    public var isPending: Bool { phase == .accepted || phase == .dispatching }
    public var reservesOpenCodeV1Candidate: Bool {
        openCodeV1Candidate != nil && (isPending || phase == .unconfirmed || (phase == .applied && locksSource))
    }
    public var reservesClaudeFork: Bool {
        claudeForkPublication != nil && (isPending || phase == .unconfirmed || (phase == .applied && locksSource))
    }
    public var isWorking: Bool { isPending || files?.isWorking == true || maintenance?.phase.isWorking == true }
    public var allExternalWorkSucceeded: Bool { phase == .applied && (files == nil || files?.phase == .applied) }
    public var needsPromptRecall: Bool { review.recallPromptOnSuccess == true && allExternalWorkSucceeded && recalledAt == nil && recallDismissedAt == nil }
    public var locksFiles: Bool {
        guard let files else { return false }
        if isPending || phase == .unconfirmed { return true }
        return phase == .applied && files.phase != .applied && files.acknowledgedAt == nil
    }
    public var locksSource: Bool { isPending || (phase == .unconfirmed && (review.kind == .rewindBeforeRun || review.claude != nil || review.pi != nil)) || locksFiles || needsPromptRecall }
    public func validate() throws {
        try review.validate()
        try scratchFork?.validate(review: review)
        if let candidates = piCandidates {
            guard let evidence = review.pi, phase != .accepted, !candidates.isEmpty, candidates.count <= 3 else { throw ProviderHistoryError(.invalidResponse) }
            var previous: [PiHistoryCandidate] = []
            for candidate in candidates { try evidence.validateCandidate(candidate, previous: previous); previous.append(candidate) }
            if let result { guard result.pi?.candidates == candidates else { throw ProviderHistoryError(.invalidResponse) } }
        }
        if let controls = piControls {
            guard review.pi != nil, phase == .dispatching else { throw ProviderHistoryError(.invalidResponse) }
            try controls.validate()
        }
        if phase == .applied, let result = result?.pi, result.source != result.snapshot, result.candidates != (piCandidates ?? []) {
            throw ProviderHistoryError(.invalidResponse)
        }
        if let publication = claudeForkPublication {
            guard let evidence = review.claude, review.kind == .forkAfterRun, phase != .accepted else { throw ProviderHistoryError(.invalidResponse) }
            try evidence.validatePublication(publication)
            if let result { guard result.claude?.publication == publication else { throw ProviderHistoryError(.invalidResponse) } }
        }
        if phase == .applied, review.claude != nil, review.kind == .forkAfterRun, claudeForkPublication == nil {
            throw CoincideError("Applied Claude forks require their durably reserved exact native destination.")
        }
        if let candidate = openCodeV1Candidate {
            guard let evidence = review.openCodeV1, phase != .accepted else { throw CoincideError("The native history candidate has no dispatched owner.") }
            try evidence.validateCandidate(candidate)
            if let result, result.reference != candidate.reference { throw CoincideError("The history result does not match its recorded native candidate.") }
        }
        if phase == .applied, review.openCodeV1 != nil, openCodeV1Candidate == nil {
            throw CoincideError("Applied OpenCode history requires its durably recorded native candidate.")
        }
        let attempts = (previousMaintenanceAttempts ?? []) + (maintenance.map { [$0] } ?? [])
        guard (previousMaintenanceAttempts?.count ?? 0) <= 16, previousMaintenanceAttempts?.isEmpty != true,
              Set(attempts.map(\.id)).count == attempts.count,
              !(previousMaintenanceAttempts ?? []).contains(where: { $0.phase.isWorking }),
              attempts.isEmpty || (review.openCodeV2 != nil && review.kind == .rewindBeforeRun && !isPending),
              maintenance?.phase.isWorking != true || phase == .unconfirmed else {
            throw CoincideError("Provider maintenance lost its history owner or retained attempts.")
        }
        for attempt in attempts {
            try attempt.validate()
            try review.openCodeV2?.validatesClear(attempt.expected)
            guard attempt.id != review.id, attempt.id != review.sourceThreadID, attempt.id != review.projectID,
                  attempt.id != review.targetThreadID, attempt.id != review.files?.id,
                  attempt.expected.reference == review.sourceReference,
                  attempt.expected.runtimeIdentity == review.openCodeV2?.source.runtimeIdentity,
                  attempt.expected.workspacePath == review.sourceConfiguration.workspacePath,
                  case .beforeMessage(let cut) = review.boundary, attempt.expected.stage?.messageID == cut,
                  attempt.expected.stage?.isHistoryOnly == true else {
                throw CoincideError("Provider maintenance does not match its exact reviewed revert.")
            }
        }
        guard files?.review == review.files, recallDismissedAt.map({ $0.timeIntervalSince1970.isFinite && allExternalWorkSucceeded && review.recallPromptOnSuccess == true && recalledAt == nil }) ?? true,
              recalledAt == nil || allExternalWorkSucceeded else { throw CoincideError("The combined rewind's file or recall evidence is inconsistent.") }
        try files?.validate(providerPhase: phase)
        guard updatedAt.timeIntervalSince1970.isFinite,
              error == nil || [Self.failureMessage, Self.unconfirmedMessage, Self.unchangedMessage].contains(error!) ||
                (review.openCodeV1 != nil && phase == .failed && error == Self.openCodeV1NotAdoptedMessage) ||
                (review.pi != nil && phase == .failed && error == Self.piNotAdoptedMessage),
              (phase == .applied) == (result != nil), recalledAt == nil || (phase == .applied && review.kind == .rewindBeforeRun && recalledAt!.timeIntervalSince1970.isFinite),
              targetTitle.map({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf8.count <= 4_096 && !$0.contains("\0") }) ?? true else { throw CoincideError("The conversation history operation has inconsistent state.") }
        if let result { try review.validateResult(result) }
    }
    public mutating func recoverMaintenanceAfterProcessRestart(now: Date = Date()) {
        guard var attempt = maintenance, attempt.phase.isWorking else { return }
        attempt.phase = attempt.phase == .accepted ? .failed : .unconfirmed
        attempt.error = attempt.phase == .failed ? ConversationHistoryMaintenanceAttempt.failureMessage : ConversationHistoryMaintenanceAttempt.unconfirmedMessage
        attempt.updatedAt = now; maintenance = attempt; updatedAt = now
    }
}

extension CodingThread {
    public var visibleMessages: [ChatMessage] { messages.filter { $0.removedByHistoryOperationID == nil } }
    public var activeHistoryRuns: [ThreadRunRecord] { (runHistory ?? []).filter { $0.removedByHistoryOperationID == nil } }
}

extension WorkspaceSnapshot {
    public func conversationHistoryOperation(_ id: UUID) -> ConversationHistoryOperation? { conversationHistoryOperations?.first { $0.id == id } }
    public var conversationHistoryMaintenanceReservedIDs: Set<UUID> {
        Set((conversationHistoryOperations ?? []).flatMap { operation in
            (operation.previousMaintenanceAttempts ?? []).map(\.id) + (operation.maintenance.map { [$0.id] } ?? [])
        })
    }
    public func isConversationHistoryLocked(threadID: UUID, excludingOperationID: UUID? = nil) -> Bool {
        let thread = threads.first { $0.id == threadID }
        return (conversationHistoryOperations ?? []).contains { operation in
            guard operation.id != excludingOperationID else { return false }
            if operation.locksSource, operation.review.sourceThreadID == threadID { return true }
            if let thread, operation.review.pi != nil {
                return (operation.locksSource && hasPiHistoryCapture(thread, nativeSessionFile: operation.review.sourceReference.nativeThreadID)) ||
                    (operation.piCandidates ?? []).contains { candidate in
                        guard let path = candidate.nativeSessionFile else { return false }
                        return (operation.phase != .applied || operation.locksSource || path != operation.result?.reference.nativeThreadID) && hasPiHistoryCapture(thread, nativeSessionFile: path)
                    }
            }
            if let thread, let source = operation.review.claude?.source {
                if operation.locksSource, case .freshClaudeSession(let reserved) = operation.review.boundary,
                   hasClaudeHistoryCapture(thread, runtimeIdentity: source.runtimeIdentity, nativeThreadID: reserved) { return true }
                return (operation.locksSource && hasClaudeHistoryCapture(thread, runtimeIdentity: source.runtimeIdentity, nativeThreadID: source.reference.nativeThreadID)) ||
                    (operation.reservesClaudeFork && operation.claudeForkPublication.map {
                        hasClaudeHistoryCapture(thread, runtimeIdentity: source.runtimeIdentity, nativeThreadID: $0.target.sessionID)
                    } == true) || (operation.locksSource && operation.result?.claude?.selection.map {
                        hasClaudeHistoryCapture(thread, runtimeIdentity: source.runtimeIdentity, nativeThreadID: $0.nativeSessionID)
                    } == true)
            }
            guard let thread, let identity = operation.review.openCodeV1?.source.runtimeIdentity ?? operation.review.openCodeV2?.source.runtimeIdentity else { return false }
            return (operation.locksSource && hasOpenCodeHistoryCapture(thread, runtimeIdentity: identity, nativeThreadID: operation.review.sourceReference.nativeThreadID)) ||
                (operation.reservesOpenCodeV1Candidate && operation.openCodeV1Candidate.map {
                    hasOpenCodeHistoryCapture(thread, runtimeIdentity: identity, nativeThreadID: $0.reference.nativeThreadID)
                } == true)
        }
    }
    /// Physical transcript namespaces do not become independent when another
    /// launcher spelling or registered cwd alias addresses the same native file.
    public func isClaudeHistoryScopeLocked(configuration: ProviderConfiguration, nativeThreadID: String?,
                                           excludingOperationID: UUID? = nil) -> Bool {
        guard configuration.provider == .claude, let runtime = configuration.claudeRuntimeConfiguration,
              let id = nativeThreadID ?? configuration.nativeThreadID, let nativeUUID = UUID(uuidString: id) else { return false }
        return (conversationHistoryOperations ?? []).contains { operation in
            guard operation.id != excludingOperationID, let source = operation.review.claude?.source,
                  source.runtimeIdentity.configurationDirectory == runtime.configurationDirectory else { return false }
            if operation.locksSource, case .freshClaudeSession(let reserved) = operation.review.boundary, UUID(uuidString: reserved) == nativeUUID { return true }
            return (operation.locksSource && UUID(uuidString: source.reference.nativeThreadID) == nativeUUID) ||
                (operation.reservesClaudeFork && UUID(uuidString: operation.claudeForkPublication?.target.sessionID ?? "") == nativeUUID) ||
                (operation.locksSource && UUID(uuidString: operation.result?.claude?.selection?.nativeSessionID ?? "") == nativeUUID)
        }
    }
    fileprivate func hasClaudeHistoryCapture(_ thread: CodingThread, runtimeIdentity: ClaudeRuntimeIdentity, nativeThreadID: String) -> Bool {
        func matches(_ configuration: ProviderConfiguration, id: String?) -> Bool {
            guard let expected = UUID(uuidString: nativeThreadID), let actual = UUID(uuidString: id ?? configuration.nativeThreadID ?? "") else { return false }
            return configuration.provider == .claude && configuration.claudeRuntimeConfiguration?.configurationDirectory == runtimeIdentity.configurationDirectory && actual == expected
        }
        if matches(.init(thread: thread), id: thread.providerThreadID) { return true }
        if let run = thread.activeRun, matches(run.configuration, id: run.configuration.nativeThreadID ?? thread.runHistory?.first(where: { $0.id == run.id })?.providerThreadID) { return true }
        return thread.queuedTurns.contains { matches($0.configuration, id: $0.configuration.nativeThreadID) }
    }
    public func isClaudeHistorySelectionCurrent(operationID: UUID) -> Bool {
        guard let operation = conversationHistoryOperation(operationID), operation.phase == .applied,
              let selection = operation.result?.claude?.selection,
              let thread = threads.first(where: { $0.id == operation.review.sourceThreadID }) else { return false }
        return thread.claudeResumeSelection == selection && thread.providerThreadID == selection.nativeSessionID
    }
    public func isClaudeResumeSelectionPending(operationID: UUID) -> Bool { isClaudeHistorySelectionCurrent(operationID: operationID) }
    public func claudeResumeSelectionNeedsInspection(threadID: UUID) -> Bool {
        guard let thread = threads.first(where: { $0.id == threadID }), thread.provider == .claude,
              !thread.isBusy, let selection = thread.claudeResumeSelection, let consumer = thread.claudeResumeConsumerRunID,
              let record = thread.runHistory?.first(where: { $0.id == consumer }), record.status.isTerminal,
              record.configuration.claudeLaunchSelection == selection,
              record.configuration.claudeRuntimeConfiguration == thread.claudeRuntimeConfiguration else { return false }
        return isClaudeResumeSelectionPending(operationID: selection.id)
    }
    public func canInspectConversationHistory(operationID: UUID) -> Bool {
        guard let operation = conversationHistoryOperation(operationID), operation.phase == .unconfirmed,
              operation.maintenance?.phase.isWorking != true,
              operation.review.kind == .rewindBeforeRun || operation.review.pi != nil || (operation.review.claude != nil && operation.claudeForkPublication != nil),
              canReviewConversationHistory(threadID: operation.review.sourceThreadID, excludingOperationID: operationID) else { return false }
        return (try? historySourceFingerprint(threadID: operation.review.sourceThreadID)) == operation.review.sourceFingerprint
    }
    /// A staged native revert belongs to the provider session, even when another
    /// local conversation or an immutable queued input refers to that session.
    public func isOpenCodeV2HistoryScopeLocked(configuration: ProviderConfiguration, nativeThreadID: String?,
                                               excludingOperationID: UUID? = nil) -> Bool {
        guard configuration.openCodeConfiguration?.generation == .v2 else { return false }
        return isOpenCodeHistoryScopeLocked(configuration: configuration, nativeThreadID: nativeThreadID, excludingOperationID: excludingOperationID)
    }
    public func isOpenCodeHistoryScopeLocked(configuration: ProviderConfiguration, nativeThreadID: String?,
                                             excludingOperationID: UUID? = nil) -> Bool {
        guard configuration.provider == .opencode, let runtime = configuration.openCodeConfiguration,
              let nativeThreadID = nativeThreadID ?? configuration.nativeThreadID else { return false }
        return (conversationHistoryOperations ?? []).contains { operation in
            operation.id != excludingOperationID &&
                (operation.review.openCodeV1?.source.runtimeIdentity ?? operation.review.openCodeV2?.source.runtimeIdentity) == runtime.runtimeIdentity &&
                ((operation.locksSource && operation.review.sourceReference.nativeThreadID == nativeThreadID) ||
                 (operation.reservesOpenCodeV1Candidate && operation.openCodeV1Candidate?.reference.nativeThreadID == nativeThreadID))
        }
    }
    fileprivate func hasOpenCodeHistoryCapture(_ thread: CodingThread, runtimeIdentity: OpenCodeRuntimeIdentity,
                                            nativeThreadID: String) -> Bool {
        func matches(_ configuration: ProviderConfiguration, nativeID: String?) -> Bool {
            configuration.provider == .opencode &&
                configuration.openCodeConfiguration?.runtimeIdentity == runtimeIdentity &&
                (nativeID ?? configuration.nativeThreadID) == nativeThreadID
        }
        if matches(.init(thread: thread), nativeID: thread.providerThreadID) { return true }
        if let run = thread.activeRun,
           matches(run.configuration, nativeID: run.configuration.nativeThreadID ?? thread.runHistory?.first(where: { $0.id == run.id })?.providerThreadID) { return true }
        return thread.queuedTurns.contains { matches($0.configuration, nativeID: $0.configuration.nativeThreadID) }
    }
    public func canReviewConversationHistory(threadID: UUID, excludingOperationID: UUID? = nil) -> Bool {
        guard !hasUnresolvedContextDelivery(threadID: threadID) else { return false }
        guard let thread = threads.first(where: { $0.id == threadID }), !thread.isArchived, !thread.isBusy,
              thread.queuedTurns.isEmpty, thread.runtimeRequests.isEmpty, thread.heldPostRunCheckpoint == nil,
              thread.claudeResumeConsumerRunID == nil, thread.piFreshSessionIntent == nil, thread.piFreshConsumerRunID == nil,
              thread.settlement == nil, !(promptSteerings ?? []).contains(where: { $0.threadID == threadID && $0.isWorking }), workspaceReady(for: thread), !isPullRequestCheckoutLocked(threadID: threadID), !isPullRequestCreationLocked(threadID: threadID), !isCheckpointRestoreLocked(threadID: threadID, excludingOperationID: excludingOperationID),
              !isConversationHistoryLocked(threadID: threadID, excludingOperationID: excludingOperationID) else { return false }
        return thread.workspacePreparation?.setup.map { [.succeeded, .skipped].contains($0.phase) } ?? true
    }
    public func historySourceFingerprint(threadID: UUID) throws -> String {
        guard let thread = threads.first(where: { $0.id == threadID }) else { throw WorkspaceCommandError("This conversation no longer exists.") }
        struct SteeringProof: Encodable {
            let id: UUID, runID: UUID
            let messageID: String
            let phase: PromptSteeringPhase
            let receipt: ProviderSteeringReceipt?
        }
        struct Source: Encodable {
            let id: UUID, projectID: UUID
            let configuration: ProviderConfiguration
            let messages: [ChatMessage]
            let steering: [SteeringProof]?
            let records: [ThreadRunRecord]
            let checkpointPolicy: RunCheckpointPolicy?
            let activeRun: ActiveRun?
            let queuedTurns: [QueuedTurn]
            let runtimeRequests: [RuntimeRequest]
            let preparation: ThreadWorkspacePreparation?
            let settlement: ThreadSettlement?
            let archived: Bool, queuePaused: Bool
            let claudeSelection: ClaudeResumeSelection?
            let claudeConsumer: UUID?
            let claudeInheritedHead: ClaudeInheritedHead?
            let piFreshIntent: PiFreshSessionIntent?
            let piFreshConsumer: UUID?
            let piResolutions: [PiFreshContextResolution]?
        }
        let records = thread.activeHistoryRuns.map { value in var value = value; value.checkpoints = nil; value.providerUsage = nil; return value }
        let steering = (promptSteerings ?? []).filter { $0.threadID == thread.id }.map { SteeringProof(id: $0.id, runID: $0.runID, messageID: $0.messageID, phase: $0.phase, receipt: $0.receipt) }
        let source = Source(id: thread.id, projectID: thread.projectID, configuration: .init(thread: thread), messages: thread.visibleMessages, steering: steering.isEmpty ? nil : steering,
            records: records, checkpointPolicy: thread.checkpointPolicy, activeRun: thread.activeRun,
            queuedTurns: thread.queuedTurns, runtimeRequests: thread.runtimeRequests,
            preparation: thread.workspacePreparation, settlement: thread.settlement, archived: thread.isArchived, queuePaused: thread.queuePaused,
            claudeSelection: thread.claudeResumeSelection, claudeConsumer: thread.claudeResumeConsumerRunID, claudeInheritedHead: thread.claudeInheritedHead, piFreshIntent: thread.piFreshSessionIntent,
            piFreshConsumer: thread.piFreshConsumerRunID, piResolutions: thread.piFreshContextResolutions)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(source)).map { String(format: "%02x", $0) }.joined()
    }
    public func conversationHistoryUnavailableReason(threadID: UUID, runID: UUID, kind: ConversationHistoryKind) -> String? {
        guard canReviewConversationHistory(threadID: threadID), let thread = threads.first(where: { $0.id == threadID }) else {
            return "Finish current work, queued messages, questions and workspace preparation before changing conversation history."
        }
        guard let run = thread.activeHistoryRuns.first(where: { $0.id == runID }), run.status.isTerminal,
              run.messageAttributionVersion == 1, run.configuration.provider == thread.provider,
              run.configuration.workspacePath == thread.workspacePath, thread.provider == .claude || thread.provider == .pi || !run.turnIDs.isEmpty,
              thread.provider == .pi || (thread.provider == .opencode && thread.openCodeConfiguration?.generation == .v1) || run.providerThreadID == thread.providerThreadID,
              run.providerThreadID != nil, thread.providerThreadID != nil else { return "This run has no verified boundary in the current provider conversation and checkout." }
        switch thread.provider {
        case .codex: break
        case .claude:
            guard let runtime = thread.claudeRuntimeConfiguration, let evidence = run.claude,
                  evidence.runtimeIdentity == runtime.runtimeIdentity, evidence.nativeSessionID == thread.providerThreadID,
                  evidence.terminalStatus == run.status,
                  kind != .forkAfterRun || evidence.finalRootAssistantMessageID != nil else {
                return "This run has no prospectively recorded root Claude input and assistant boundary in this exact runtime."
            }
        case .pi:
            guard let runtime = thread.piConfiguration?.runtimeIdentity, runtime.runtime != nil,
                  let evidence = run.pi, evidence.runtimeIdentity == runtime, evidence.terminalStatus == run.status,
                  evidence.captureStatus == .proven || (kind == .rewindBeforeRun && evidence.captureStatus == .noNativeChange) else {
                return "This run has no prospectively recorded native Pi input boundary in this exact runtime."
            }
        case .opencode:
            guard let current = thread.openCodeConfiguration,
                  run.configuration.openCodeConfiguration?.runtimeIdentity == current.runtimeIdentity else {
                return "This run has no verified boundary in the current OpenCode conversation and checkout."
            }
        default: return "This provider does not expose a supported native conversation history boundary."
        }
        if kind == .forkAfterRun, run.status != .completed { return "Native forks require a completed run with a verified provider turn." }
        do {
            let prefix = try thread.transcriptPrefix(runID: runID, boundary: kind == .forkAfterRun ? .afterRun : .beforeRun)
            guard thread.provider == .claude || thread.provider == .pi || !hasUnverifiedSteering(in: prefix) else { return "This retained transcript includes steering whose native delivery is unconfirmed. Rewind before its run instead." }
        }
        catch { return "This run has no verified local transcript boundary." }
        return nil
    }

    /// Release native-source validation temporaries before checkpoint validation
    /// descends through the retained run ledger.
    @inline(never)
    func validateConversationHistorySource(_ review: ConversationHistoryReview, excludingOperationID: UUID? = nil) throws {
        try validateConversationHistoryNativeSource(review, excludingOperationID: excludingOperationID)
        try validateConversationHistoryFilesReview(review, excludingOperationID: excludingOperationID)
    }

    @inline(never)
    private func validateConversationHistoryNativeSource(_ review: ConversationHistoryReview, excludingOperationID: UUID?) throws {
        try review.validate()
        guard canReviewConversationHistory(threadID: review.sourceThreadID, excludingOperationID: excludingOperationID),
              let thread = threads.first(where: { $0.id == review.sourceThreadID && $0.projectID == review.projectID }),
              ProviderConfiguration(thread: thread) == review.sourceConfiguration,
              try historySourceFingerprint(threadID: thread.id) == review.sourceFingerprint,
              let run = thread.activeHistoryRuns.first(where: { $0.id == review.runID }), run.status.isTerminal,
              run.messageAttributionVersion == 1, run.configuration == review.targetConfiguration,
              run.configuration.workspacePath == thread.workspacePath,
              run.configuration.provider == thread.provider,
              review.pi != nil || review.openCodeV1 != nil || run.providerThreadID == review.sourceReference.nativeThreadID,
              thread.providerThreadID == review.sourceReference.nativeThreadID,
              review.pi != nil || review.claude != nil || !run.turnIDs.isEmpty else { throw WorkspaceCommandError("This conversation or its reviewed history changed. Review the current run again.") }
        let rawPrefix = try thread.transcriptPrefix(runID: run.id, boundary: review.kind == .forkAfterRun ? .afterRun : .beforeRun)
        let prefix: [ChatMessage]
        if let evidence = review.pi {
            prefix = try verifiedPiHistoryPrefix(rawPrefix, evidence: evidence, threadID: thread.id, fork: review.kind == .forkAfterRun)
        } else if let evidence = review.claude {
            prefix = try verifiedClaudeHistoryPrefix(rawPrefix, evidence: evidence, threadID: thread.id, fork: review.kind == .forkAfterRun)
        } else {
            guard !hasUnverifiedSteering(in: rawPrefix) else { throw WorkspaceCommandError("This native history prefix includes unconfirmed steering delivery.") }
            prefix = review.kind == .forkAfterRun ? try verifiedForkPrefix(rawPrefix) : rawPrefix
        }
        guard prefix == review.prefix else { throw WorkspaceCommandError("The reviewed transcript prefix changed. Review it again.") }
        if let evidence = review.pi {
            guard thread.piFreshSessionIntent == nil, thread.piFreshConsumerRunID == nil,
                  !threads.contains(where: { $0.id != thread.id && hasPiHistoryCapture($0, nativeSessionFile: review.sourceReference.nativeThreadID) }) else {
                throw WorkspaceCommandError("Another conversation owns this exact Pi native file. Finish that work before changing its history.")
            }
            try evidence.validateLedger(snapshot: self, thread: thread)
        } else if let evidence = review.claude {
            guard thread.claudeResumeConsumerRunID == nil,
                  !threads.contains(where: { $0.id != thread.id && hasClaudeHistoryCapture($0, runtimeIdentity: evidence.source.runtimeIdentity,
                                                                                       nativeThreadID: review.sourceReference.nativeThreadID) }) else {
                throw WorkspaceCommandError("Another conversation owns this exact Claude transcript. Finish that work before changing native context.")
            }
            let expected = try ClaudeHistoryReviewEvidence.make(source: evidence.source, snapshot: self, thread: thread, runID: run.id, kind: review.kind)
            guard evidence.sameLogicalBoundary(as: expected) else { throw ProviderHistoryError(.boundaryUnavailable) }
            if case .freshSession(let reserved) = evidence.boundary {
                guard !threads.contains(where: { hasClaudeHistoryCapture($0, runtimeIdentity: evidence.source.runtimeIdentity, nativeThreadID: reserved) }),
                      !(conversationHistoryOperations ?? []).contains(where: { prior in
                          guard prior.id != excludingOperationID, let old = prior.review.claude?.source,
                                old.runtimeIdentity.configurationDirectory == evidence.source.runtimeIdentity.configurationDirectory else { return false }
                          let id = UUID(uuidString: reserved)
                          return UUID(uuidString: old.reference.nativeThreadID) == id ||
                              UUID(uuidString: prior.claudeForkPublication?.target.sessionID ?? "") == id ||
                              UUID(uuidString: prior.result?.reference.nativeThreadID ?? "") == id
                      }) else { throw WorkspaceCommandError("The fresh Claude session reservation is already in use.") }
            }
        } else if let identity = review.openCodeV1?.source.runtimeIdentity ?? review.openCodeV2?.source.runtimeIdentity {
            let candidateID = excludingOperationID.flatMap { conversationHistoryOperation($0)?.openCodeV1Candidate?.reference.nativeThreadID }
            guard !threads.contains(where: { other in
                other.id != thread.id && (hasOpenCodeHistoryCapture(other, runtimeIdentity: identity, nativeThreadID: review.sourceReference.nativeThreadID) ||
                    candidateID.map { hasOpenCodeHistoryCapture(other, runtimeIdentity: identity, nativeThreadID: $0) } == true)
            }) else { throw WorkspaceCommandError("Another conversation owns this native OpenCode session. Use a separate native session before changing its history.") }
            if let evidence = review.openCodeV1 {
                let expected = try OpenCodeV1HistoryReviewEvidence.make(source: evidence.source, snapshot: self, thread: thread, runID: run.id, kind: review.kind)
                guard evidence == expected else { throw ProviderHistoryError(.boundaryUnavailable) }
            } else if let evidence = review.openCodeV2 {
                try validateOpenCodeV2HistoryInputs(evidence, thread: thread, selectedRunID: run.id, kind: review.kind)
            }
        } else {
            guard thread.provider == .codex else { throw ProviderHistoryError(.unsupported) }
        }
        switch review.kind {
        case .forkAfterRun:
            guard run.status == .completed else { throw WorkspaceCommandError("The fork no longer matches the completed provider run.") }
            if review.openCodeV2 == nil && review.openCodeV1 == nil && review.claude == nil && review.pi == nil {
                guard review.boundary == .throughTurn(run.turnIDs.last!), review.expectedResultHeadTurnID == run.turnIDs.last else { throw WorkspaceCommandError("The fork no longer matches the completed provider run.") }
            }
        case .rewindBeforeRun:
            guard let start = thread.activeHistoryRuns.firstIndex(where: { $0.id == run.id }),
                  review.pi != nil || review.openCodeV2 != nil || review.openCodeV1 != nil || review.claude != nil || review.boundary == .beforeTurn(run.turnIDs.first!) else { throw WorkspaceCommandError("The rewind no longer matches the selected provider run.") }
            let removedRuns = thread.activeHistoryRuns.dropFirst(start).map(\.id)
            let prefixIDs = Set(prefix.map(\.id))
            let removedMessages = thread.visibleMessages.filter { !prefixIDs.contains($0.id) }.map(\.id)
            guard review.removedRunIDs == removedRuns, review.removedMessageIDs == removedMessages else { throw WorkspaceCommandError("The conversation suffix changed. Review the rewind again.") }
        }
    }

    private func validateOpenCodeV2HistoryInputs(_ evidence: OpenCodeV2HistoryReviewEvidence, thread: CodingThread,
                                               selectedRunID: UUID, kind: ConversationHistoryKind) throws {
        let expected = try OpenCodeV2HistoryReviewEvidence.make(source: evidence.source, snapshot: self, thread: thread,
                                                              runID: selectedRunID, kind: kind)
        guard expected == evidence else { throw ProviderHistoryError(.boundaryUnavailable) }
    }

    public func verifiedClaudeHistoryPrefix(_ prefix: [ChatMessage], evidence: ClaudeHistoryReviewEvidence,
                                            threadID: UUID, fork: Bool) throws -> [ChatMessage] {
        try evidence.validate()
        let inputs = Set(evidence.inputs.flatMap(\.inputIDs))
        let inherited = threads.first(where: { $0.id == threadID })?.forkedFromHistoryOperationID.flatMap(conversationHistoryOperation)
        for row in prefix {
            guard let id = row.promptSteeringID, let steering = promptSteering(id) else { continue }
            if steering.phase == .failed { continue }
            if row.runReference?.threadID != threadID, let inherited, inherited.phase == .applied,
               inherited.review.claude != nil, inherited.review.prefix.contains(where: { $0.id == row.id && $0.runReference == row.runReference }) { continue }
            let nativeID = try ClaudeInputIdentity.steering(messageID: row.id)
            guard (steering.phase == .delivered || steering.phase == .unconfirmed), inputs.contains(nativeID),
                  evidence.source.selectedMessages.contains(where: { $0.id == nativeID && $0.isUserInput }) else {
                throw WorkspaceCommandError("The retained steering input has no exact native Claude transcript proof.")
            }
        }
        return fork ? prefix.filter { $0.promptSteeringID.flatMap(promptSteering)?.phase != .failed } : prefix
    }

    func validateConversationHistory() throws {
        let operations = conversationHistoryOperations ?? []
        guard Set(operations.map(\.id)).count == operations.count,
              Set(operations.compactMap { $0.review.targetThreadID }).count == operations.filter({ $0.review.targetThreadID != nil }).count else { throw CoincideError("Conversation history actions must have unique operation and target identities.") }
        let maintenanceIDs = operations.flatMap { ($0.previousMaintenanceAttempts ?? []).map(\.id) + ($0.maintenance.map { [$0.id] } ?? []) }
        var reserved = Set(projects.map(\.id) + threads.map(\.id) + operations.map(\.id) + operations.compactMap(\.review.targetThreadID) + operations.compactMap { $0.review.files?.id })
        reserved.formUnion(promptSteeringReservedIDs); reserved.formUnion(pullRequestCheckoutReservedIDs)
        reserved.formUnion((pullRequestCreations ?? []).flatMap { [$0.id, $0.effectID] })
        reserved.formUnion((checkpointRestoreOperations ?? []).map(\.id))
        for project in projects { if let clone = project.clone { reserved.formUnion((clone.previousPlans + [clone.plan]).map(\.id)) } }
        // Each loop body runs in its own frame: unoptimized builds otherwise keep
        // every iteration's dynamic stack allocations until this function returns.
        for thread in threads { Self.reserveHistoryIdentities(of: thread, in: &reserved) }
        guard Set(maintenanceIDs).count == maintenanceIDs.count, reserved.isDisjoint(with: maintenanceIDs) else {
            throw CoincideError("Provider maintenance identities must be uniquely reserved.")
        }
        for operation in operations { try validateHistoryOwnership(of: operation) }
        try OpenCodeV1HistoryReviewEvidence.validateAdoptionLedger(in: self)
        try validatePiFreshContexts()
        let byID = Dictionary(uniqueKeysWithValues: operations.map { ($0.id, $0) })
        for thread in threads { try validateHistoryLineage(of: thread, byID: byID) }
        // Resolved audit survives removal. Existing sources must retain every marked
        // row; subsequent rewinds never physically delete or reassign old markers.
        for operation in operations where operation.phase == .applied && operation.review.kind == .rewindBeforeRun {
            try validateRewindAudit(of: operation)
        }
    }

    private static func reserveHistoryIdentities(of thread: CodingThread, in reserved: inout Set<UUID>) {
        reserved.formUnion(thread.queuedTurns.map(\.id)); if let run = thread.activeRun { reserved.insert(run.id) }
        if let preparation = thread.workspacePreparation {
            reserved.formUnion([preparation.id] + preparation.previousAttempts.map { $0.request.id })
            for script in preparation.previousAttempts.compactMap(\.setup) + (preparation.setup.map { [$0] } ?? []) {
                reserved.formUnion([script.id] + script.previousPlans.map(\.id))
            }
        }
        if let settlement = thread.settlement { reserved.insert(settlement.id) }
        for (_, script) in thread.projectScripts { reserved.formUnion([script.id] + script.previousPlans.map(\.id)) }
        for record in thread.runHistory ?? [] {
            reserved.insert(record.id)
            if let checkpoints = record.checkpoints {
                reserved.formUnion(([checkpoints.baseline] + checkpoints.previousPostRunAttempts + (checkpoints.postRun.map { [$0] } ?? [])).map(\.id))
            }
        }
    }

    private func validateHistoryOwnership(of operation: ConversationHistoryOperation) throws {
        try operation.validate()
        if operation.locksSource {
            guard threads.contains(where: { $0.id == operation.review.sourceThreadID && $0.projectID == operation.review.projectID }) else { throw CoincideError("A pending history action lost its source conversation.") }
        }
        if let targetID = operation.review.targetThreadID, let target = threads.first(where: { $0.id == targetID }) {
            guard operation.phase == .applied, target.forkedFromHistoryOperationID == operation.id else { throw CoincideError("A fork target is already owned by another conversation.") }
            if let grant = operation.scratchFork {
                guard target.scratchWorkspace == grant.allocation.receipt,
                      target.createdAt == grant.allocation.receipt.createdAt else { throw ScratchWorkspaceError() }
            }
        }
    }

    private func validateHistoryLineage(of thread: CodingThread, byID: [UUID: ConversationHistoryOperation]) throws {
        if let selection = thread.claudeResumeSelection {
            guard thread.provider == .claude, let operation = byID[selection.id], operation.phase == .applied,
                  operation.review.sourceThreadID == thread.id, operation.review.kind == .rewindBeforeRun,
                  operation.result?.claude?.selection == selection,
                  operation.review.claude?.source.matchesBinding(.init(thread: thread)) == true,
                  thread.providerThreadID == selection.nativeSessionID else { throw CoincideError("The pending Claude context selection lost its applied history owner.") }
            if let consumer = thread.claudeResumeConsumerRunID {
                guard let run = thread.runHistory?.first(where: { $0.id == consumer }),
                      run.configuration.claudeLaunchSelection == selection,
                      run.configuration.claudeRuntimeConfiguration == thread.claudeRuntimeConfiguration else {
                    throw CoincideError("The pending Claude context consumer lost its exact captured selection.")
                }
            }
        } else if thread.claudeResumeConsumerRunID != nil { throw CoincideError("A Claude context consumer has no pending selection.") }
        if let inherited = thread.claudeInheritedHead {
            let nativeHistoryOwner = thread.forkedFromHistoryOperationID.flatMap { byID[$0] }.map {
                $0.phase == .applied && $0.result?.claude?.inheritedHead == inherited
            } ?? false
            let contextOwner = try hasVerifiedContextClaudeFork(thread: thread, inherited: inherited)
            guard nativeHistoryOwner || contextOwner,
                  thread.claudeRuntimeConfiguration?.runtimeIdentity == inherited.runtimeIdentity,
                  thread.providerThreadID == inherited.nativeSessionID else { throw CoincideError("The inherited Claude head lost its verified native fork lineage.") }
        }
        if let fork = thread.forkedFromHistoryOperationID {
            guard let operation = byID[fork], operation.phase == .applied, operation.review.kind == .forkAfterRun,
                  operation.review.targetThreadID == thread.id, operation.review.projectID == thread.projectID,
                  operation.review.prefix.allSatisfy({ original in thread.messages.contains(where: { $0.id == original.id && $0.runReference == original.runReference }) }) else { throw CoincideError("The forked conversation has no matching applied lineage.") }
            if let inherited = operation.result?.claude?.inheritedHead {
                guard thread.claudeInheritedHead == inherited else { throw CoincideError("The forked Claude conversation lost its verified inherited context.") }
            }
        }
        for run in thread.runHistory ?? [] {
            guard let marker = run.removedByHistoryOperationID else { continue }
            guard let operation = byID[marker], operation.phase == .applied, operation.review.kind == .rewindBeforeRun,
                  operation.review.sourceThreadID == thread.id, operation.review.removedRunIDs.contains(run.id) else { throw CoincideError("A removed run has no matching applied rewind.") }
        }
        for message in thread.messages {
            if let marker = message.removedByHistoryOperationID {
                guard let operation = byID[marker], operation.phase == .applied, operation.review.kind == .rewindBeforeRun,
                      operation.review.sourceThreadID == thread.id, operation.review.removedMessageIDs.contains(message.id) else { throw CoincideError("A removed message has no matching applied rewind.") }
            }
            if let reference = message.runReference, reference.threadID != thread.id {
                guard let fork = thread.forkedFromHistoryOperationID, let operation = byID[fork], operation.phase == .applied,
                      operation.review.kind == .forkAfterRun, operation.review.targetThreadID == thread.id,
                      operation.review.prefix.contains(where: { $0.id == message.id && $0.runReference == reference }) else { throw CoincideError("An inherited message has no matching applied fork provenance.") }
            }
        }
    }

    private func validateRewindAudit(of operation: ConversationHistoryOperation) throws {
        guard let source = threads.first(where: { $0.id == operation.review.sourceThreadID }) else { return }
        guard operation.review.removedRunIDs.allSatisfy({ id in source.runHistory?.contains(where: { $0.id == id && $0.removedByHistoryOperationID == operation.id }) == true }),
              operation.review.removedMessageIDs.allSatisfy({ id in source.messages.contains(where: { $0.id == id && $0.removedByHistoryOperationID == operation.id }) }) else { throw CoincideError("The rewind audit lost retained transcript or run evidence.") }
    }
}

extension WorkspaceDecision {
    func validateConversationHistoryLocks(_ command: WorkspaceCommand) throws {
        let created: CodingThread?
        switch command {
        case .createThread(let thread), .addProjectWithThread(_, let thread), .startProjectClone(_, let thread): created = thread
        default: created = nil
        }
        if let created, snapshot.conversationHistoryMaintenanceReservedIDs.contains(created.id) ||
            (snapshot.conversationHistoryOperations ?? []).contains(where: { $0.id == created.id || $0.review.targetThreadID == created.id || $0.review.files?.id == created.id }) {
            throw WorkspaceCommandError("This conversation identity is reserved by a history action. Create a fresh conversation instead.")
        }
        if let created, snapshot.isOpenCodeHistoryScopeLocked(configuration: .init(thread: created), nativeThreadID: created.providerThreadID) ||
            snapshot.isClaudeHistoryScopeLocked(configuration: .init(thread: created), nativeThreadID: created.providerThreadID) ||
            snapshot.isPiHistoryScopeLocked(configuration: .init(thread: created), nativeThreadID: created.providerThreadID) {
            throw WorkspaceCommandError("This native provider session is held by a pending history action. Create a separate native session instead.")
        }
        let locked = Set(snapshot.threads.filter { snapshot.isConversationHistoryLocked(threadID: $0.id) }.map(\.id))
        guard !locked.isEmpty else { return }
        let targets: Set<UUID>
        switch command {
        case .editThread(let id, let edit):
            switch edit { case .draft, .pinned, .title: return; default: targets = [id] }
        case .removeProject(let projectID, _): targets = Set(snapshot.threads.filter { $0.projectID == projectID }.map(\.id))
        case .removeProjectGroup(_, let projects, _): targets = Set(snapshot.threads.filter { thread in projects.contains { $0.id == thread.projectID } }.map(\.id))
        case .submit(let id, _), .submitCapturedClaude(let id, _, _), .submitCapturedPi(let id, _, _), .interrupt(let id), .respond(let id, _, _), .resumeQueue(let id),
             .removeQueued(let id, _), .editQueued(let id, _), .settleThread(let id, _, _), .resumeThread(let id, _),
             .cancelWorktreePreparation(let id), .approveProjectScript(let id, _, _), .stopProjectScript(let id, _),
             .skipProjectScript(let id, _), .retryProjectScript(let id, _), .retryPostRunCheckpoint(let id, _, _),
             .continueAfterPostRunCheckpoint(let id, _, _): targets = [id]
        case .removeACPAgent(let agentID): targets = Set(snapshot.threads.filter { $0.acpAgent?.id == agentID }.map(\.id))
        default: return
        }
        guard locked.isDisjoint(with: targets) else { throw WorkspaceCommandError("Finish or inspect the pending conversation history action before changing this conversation.") }
    }

    mutating func acceptConversationHistory(_ review: ConversationHistoryReview, title: String?, scratchFork: ScratchHistoryForkGrant? = nil, commandID: UUID, now: Date) throws {
        let checkoutIDs = snapshot.pullRequestCheckoutReservedIDs.union(snapshot.promptSteeringReservedIDs).union(snapshot.conversationHistoryMaintenanceReservedIDs)
        guard !([review.id] + (review.targetThreadID.map { [$0] } ?? []) + (review.files.map { [$0.id] } ?? [])).contains(where: { checkoutIDs.contains($0) }) else { throw WorkspaceCommandError("This history identity is reserved by a pull request checkout.") }
        guard snapshot.conversationHistoryOperation(review.id) == nil,
              !snapshot.threads.contains(where: { $0.id == review.id }),
              !(snapshot.checkpointRestoreOperations ?? []).contains(where: { $0.id == review.id || $0.id == review.targetThreadID }),
              !(snapshot.conversationHistoryOperations ?? []).contains(where: { $0.review.files?.id == review.id || ($0.review.files?.id != nil && $0.review.files?.id == review.targetThreadID) }),
              review.targetThreadID.map({ target in !snapshot.threads.contains { $0.id == target } && !(snapshot.conversationHistoryOperations ?? []).contains { $0.review.targetThreadID == target || $0.id == target } }) ?? true else {
            throw WorkspaceCommandError("This conversation history action or target identity is already in use. Review again.")
        }
        try snapshot.validateConversationHistorySource(review)
        if review.recallPromptOnSuccess == true {
            guard let source = snapshot.threads.first(where: { $0.id == review.sourceThreadID }),
                  let record = source.runHistory?.first(where: { $0.id == review.runID }), record.origin == .user,
                  let opening = source.messages.first(where: { $0.id == record.userMessageID && $0.role == .user && $0.runReference == .init(threadID: source.id, runID: record.id) }) else {
                throw WorkspaceCommandError("The original input is unavailable for automatic draft recall.")
            }
            var attachments = source.draftAttachments, ids = Set(source.draftAttachments.map(\.id))
            for attachment in opening.attachments ?? [] where ids.insert(attachment.id).inserted { attachments.append(attachment) }
            do { try AttachmentLimits.validate(attachments) }
            catch { throw WorkspaceCommandError("The recalled attachments exceed the draft limit. Remove some attachments before rewinding.") }
        }
        if let source = snapshot.threads.first(where: { $0.id == review.sourceThreadID }), source.scratchWorkspace != nil, review.kind == .forkAfterRun {
            guard let scratchFork, scratchFork.source == source.scratchWorkspace,
                  scratchFork.allocation.receipt.commandID == commandID else { throw ScratchWorkspaceError() }
            try scratchFork.validate(review: review)
        } else if scratchFork != nil { throw ScratchWorkspaceError() }
        let operation = ConversationHistoryOperation(review: review, updatedAt: now, targetTitle: title, scratchFork: scratchFork)
        do { try operation.validate() } catch { throw WorkspaceCommandError("Choose a valid conversation title and reviewed history boundary.") }
        if snapshot.conversationHistoryOperations == nil { snapshot.conversationHistoryOperations = [] }
        let original = snapshot
        snapshot.conversationHistoryOperations!.append(operation)
        do { try snapshot.validateConversationHistoryFilesLedger(); try snapshot.validateCheckpointRestores() }
        catch { snapshot = original; throw WorkspaceCommandError("This history action uses an identity already reserved by another workspace action.") }
        effects.append(.init(id: review.id, request: .conversationHistory(threadID: review.sourceThreadID, operationID: review.id)))
    }

    mutating func dispatchConversationHistory(threadID: UUID, operationID: UUID, incarnation: UUID, now: Date) throws {
        guard let i = snapshot.conversationHistoryOperations?.firstIndex(where: { $0.id == operationID }),
              let operation = snapshot.conversationHistoryOperations?[i], operation.phase == .accepted,
              operation.review.sourceThreadID == threadID, operation.review.sourceIncarnation == incarnation else { return }
        try snapshot.validateConversationHistorySource(operation.review, excludingOperationID: operationID)
        snapshot.conversationHistoryOperations?[i].phase = .dispatching
        snapshot.conversationHistoryOperations?[i].updatedAt = now
    }

    mutating func acceptConversationHistoryMaintenance(operationID: UUID, attempt: ConversationHistoryMaintenanceAttempt, now: Date) throws {
        guard let i = snapshot.conversationHistoryOperations?.firstIndex(where: { $0.id == operationID }),
              var operation = snapshot.conversationHistoryOperations?[i], operation.phase == .unconfirmed,
              operation.review.kind == .rewindBeforeRun, let evidence = operation.review.openCodeV2,
              operation.maintenance?.phase.isWorking != true, operation.maintenance?.phase != .applied, attempt.phase == .accepted,
              (operation.previousMaintenanceAttempts?.count ?? 0) < 16 else {
            throw WorkspaceCommandError("Inspect the current pending OpenCode revert before clearing it.")
        }
        try snapshot.validateConversationHistorySource(operation.review, excludingOperationID: operationID)
        try attempt.validate(); try evidence.validatesClear(attempt.expected)
        if let previous = operation.maintenance {
            if operation.previousMaintenanceAttempts == nil { operation.previousMaintenanceAttempts = [] }
            operation.previousMaintenanceAttempts?.append(previous)
        }
        operation.maintenance = attempt; operation.updatedAt = now
        let original = snapshot
        snapshot.conversationHistoryOperations?[i] = operation
        do { try snapshot.validateConversationHistory() }
        catch { snapshot = original; throw error }
        effects.append(.init(id: attempt.id, request: .conversationHistoryMaintenance(threadID: operation.review.sourceThreadID, operationID: operationID, attemptID: attempt.id)))
    }

    mutating func recordOpenCodeV1HistoryCandidate(operationID: UUID, candidate: OpenCodeV1HistoryCandidate,
                                                 incarnation: UUID, now: Date) throws {
        guard let index = snapshot.conversationHistoryOperations?.firstIndex(where: { $0.id == operationID }),
              var operation = snapshot.conversationHistoryOperations?[index], operation.phase == .dispatching,
              operation.review.sourceIncarnation == incarnation, let evidence = operation.review.openCodeV1 else {
            throw WorkspaceCommandError("The native history action no longer owns candidate publication.")
        }
        try evidence.validateCandidate(candidate)
        if let previous = operation.openCodeV1Candidate {
            guard previous == candidate else { throw WorkspaceCommandError("The history action already recorded a different native candidate.") }
            return
        }
        try snapshot.validateConversationHistorySource(operation.review, excludingOperationID: operationID)
        let previouslyOwned = (snapshot.conversationHistoryOperations ?? []).contains { previous in
            guard previous.id != operationID, let source = previous.review.openCodeV1?.source,
                  source.runtimeIdentity == candidate.runtimeIdentity, source.workspacePath == candidate.workspacePath else { return false }
            if previous.openCodeV1Candidate?.reference == candidate.reference { return true }
            return previous.phase == .applied && (source.reference == candidate.reference || previous.result?.reference == candidate.reference)
        }
        guard !snapshot.threads.contains(where: {
            snapshot.hasOpenCodeHistoryCapture($0, runtimeIdentity: candidate.runtimeIdentity, nativeThreadID: candidate.reference.nativeThreadID)
        }), !previouslyOwned, !snapshot.isOpenCodeHistoryScopeLocked(configuration: operation.review.sourceConfiguration,
                                                  nativeThreadID: candidate.reference.nativeThreadID, excludingOperationID: operationID) else {
            throw WorkspaceCommandError("The native candidate is already owned by another conversation.")
        }
        operation.openCodeV1Candidate = candidate; operation.updatedAt = now
        try operation.validate()
        snapshot.conversationHistoryOperations?[index] = operation
    }

    mutating func recordClaudeHistoryForkPublication(operationID: UUID, publication: ClaudeTranscriptPublication,
                                                     incarnation: UUID, now: Date) throws {
        guard let index = snapshot.conversationHistoryOperations?.firstIndex(where: { $0.id == operationID }),
              var operation = snapshot.conversationHistoryOperations?[index], operation.phase == .dispatching,
              operation.review.sourceIncarnation == incarnation, let evidence = operation.review.claude,
              operation.review.kind == .forkAfterRun else { throw WorkspaceCommandError("The Claude fork no longer owns its exact publication reservation.") }
        try evidence.validatePublication(publication)
        if let previous = operation.claudeForkPublication {
            guard previous == publication else { throw WorkspaceCommandError("The native Claude fork already reserved a different destination.") }
            return
        }
        try snapshot.validateConversationHistorySource(operation.review, excludingOperationID: operationID)
        let previouslyReserved = (snapshot.conversationHistoryOperations ?? []).contains { previous in
            guard previous.id != operationID, let source = previous.review.claude?.source,
                  source.runtimeIdentity.configurationDirectory == evidence.source.runtimeIdentity.configurationDirectory else { return false }
            let target = UUID(uuidString: publication.target.sessionID)
            return UUID(uuidString: previous.claudeForkPublication?.target.sessionID ?? "") == target ||
                (previous.phase == .applied && (UUID(uuidString: source.reference.nativeThreadID) == target || UUID(uuidString: previous.result?.reference.nativeThreadID ?? "") == target))
        }
        guard !previouslyReserved, !snapshot.threads.contains(where: {
            snapshot.hasClaudeHistoryCapture($0, runtimeIdentity: evidence.source.runtimeIdentity, nativeThreadID: publication.target.sessionID)
        }), !snapshot.isClaudeHistoryScopeLocked(configuration: operation.review.sourceConfiguration,
                                                nativeThreadID: publication.target.sessionID, excludingOperationID: operationID) else {
            throw WorkspaceCommandError("The reserved Claude native session is already owned by another history or conversation.")
        }
        operation.claudeForkPublication = publication; operation.updatedAt = now
        try operation.validate(); snapshot.conversationHistoryOperations?[index] = operation
    }

    mutating func dispatchConversationHistoryMaintenance(threadID: UUID, operationID: UUID, attemptID: UUID,
                                                        incarnation: UUID, now: Date) throws {
        guard let i = snapshot.conversationHistoryOperations?.firstIndex(where: { $0.id == operationID }),
              let operation = snapshot.conversationHistoryOperations?[i], operation.phase == .unconfirmed,
              operation.review.sourceThreadID == threadID, operation.maintenance?.sourceIncarnation == incarnation,
              operation.maintenance?.id == attemptID, operation.maintenance?.phase == .accepted else { return }
        try snapshot.validateConversationHistorySource(operation.review, excludingOperationID: operationID)
        snapshot.conversationHistoryOperations?[i].maintenance?.phase = .dispatching
        snapshot.conversationHistoryOperations?[i].maintenance?.updatedAt = now
        snapshot.conversationHistoryOperations?[i].updatedAt = now
    }

    mutating func finishConversationHistoryMaintenance(_ request: WorkspaceEffectRequest, result: EffectResult,
                                                      incarnation: UUID, now: Date) {
        guard case .conversationHistoryMaintenance(let threadID, let operationID, let attemptID) = request,
              let i = snapshot.conversationHistoryOperations?.firstIndex(where: { $0.id == operationID }),
              var operation = snapshot.conversationHistoryOperations?[i], operation.phase == .unconfirmed,
              operation.review.sourceThreadID == threadID,
              var attempt = operation.maintenance, attempt.id == attemptID, attempt.sourceIncarnation == incarnation, attempt.phase.isWorking else { return }
        switch result {
        case .conversationHistoryMaintenanceConfirmed(let observed):
            guard attempt.phase == .dispatching else { return }
            attempt.phase = .applied; attempt.result = observed; attempt.error = nil
            do { try attempt.validate() }
            catch { attempt.phase = .unconfirmed; attempt.result = nil; attempt.error = ConversationHistoryMaintenanceAttempt.unconfirmedMessage }
        case .failed:
            attempt.phase = .failed; attempt.error = ConversationHistoryMaintenanceAttempt.failureMessage
        case .cancelled, .stopped, .conversationHistoryUnconfirmed:
            attempt.phase = attempt.phase == .accepted ? .failed : .unconfirmed
            attempt.error = attempt.phase == .failed ? ConversationHistoryMaintenanceAttempt.failureMessage : ConversationHistoryMaintenanceAttempt.unconfirmedMessage
        default: return
        }
        attempt.updatedAt = now; operation.maintenance = attempt; operation.updatedAt = now
        // Even a confirmed clear is only maintenance evidence. The independent
        // read-only reconciliation proves whether the reviewed rewind applied.
        snapshot.conversationHistoryOperations?[i] = operation
    }

    mutating func finishConversationHistory(_ request: WorkspaceEffectRequest, result: EffectResult, incarnation: UUID, now: Date) {
        guard case .conversationHistory(let threadID, let operationID) = request,
              let i = snapshot.conversationHistoryOperations?.firstIndex(where: { $0.id == operationID }),
              var operation = snapshot.conversationHistoryOperations?[i], [.accepted, .dispatching].contains(operation.phase),
              operation.review.sourceThreadID == threadID, operation.review.sourceIncarnation == incarnation else { return }
        operation.piControls = nil
        switch result {
        case .conversationHistoryConfirmed(let result):
            guard operation.phase == .dispatching else { return }
            do {
                try snapshot.validateConversationHistorySource(operation.review, excludingOperationID: operationID)
                operation.phase = .applied; operation.result = result; operation.error = nil; operation.updatedAt = now
                try operation.review.validateResult(result)
                var applied = self
                try applied.applyConversationHistory(operation, now: now)
                if var files = operation.files {
                    files.phase = .accepted; files.postHistorySourceFingerprint = try applied.snapshot.checkpointRestoreSourceFingerprint(threadID: threadID)
                    files.updatedAt = now; operation.files = files
                    applied.effects.append(.init(id: files.review.id, request: .conversationHistoryFiles(threadID: threadID, operationID: operation.id, fileAttemptID: files.review.id)))
                }
                try operation.validate()
                self = applied
            } catch {
                operation.phase = .unconfirmed; operation.result = nil; operation.error = ConversationHistoryOperation.unconfirmedMessage; operation.updatedAt = now
            }
        case .failed:
            operation.phase = .failed; operation.error = ConversationHistoryOperation.failureMessage; operation.updatedAt = now
        case .cancelled, .stopped, .conversationHistoryUnconfirmed:
            operation.phase = operation.phase == .accepted ? .failed : .unconfirmed
            operation.error = operation.phase == .failed ? ConversationHistoryOperation.failureMessage : ConversationHistoryOperation.unconfirmedMessage
            operation.updatedAt = now
        default: return
        }
        snapshot.conversationHistoryOperations?[i] = operation
    }

    mutating func reconcileConversationHistory(operationID: UUID, result: ConversationHistoryReconciliation, now: Date) throws {
        guard let i = snapshot.conversationHistoryOperations?.firstIndex(where: { $0.id == operationID }),
              var operation = snapshot.conversationHistoryOperations?[i], operation.phase == .unconfirmed,
              (operation.review.kind == .rewindBeforeRun || operation.review.pi != nil || (operation.review.claude != nil && operation.claudeForkPublication != nil)),
              operation.maintenance?.phase.isWorking != true else { throw WorkspaceCommandError("Only a current unconfirmed native history action can be inspected.") }
        try snapshot.validateConversationHistorySource(operation.review, excludingOperationID: operationID)
        operation.piControls = nil
        switch result {
        case .applied(let result):
            if operation.review.pi != nil, result.pi?.candidates != (operation.piCandidates ?? []) { throw ProviderHistoryError(.invalidResponse) }
            if operation.review.openCodeV1 != nil {
                guard operation.openCodeV1Candidate?.reference == result.reference else { throw ProviderHistoryError(.invalidResponse) }
            }
            if operation.review.claude != nil, operation.review.kind == .forkAfterRun {
                guard operation.claudeForkPublication == result.claude?.publication else { throw ProviderHistoryError(.invalidResponse) }
            }
            operation.phase = .applied; operation.result = result; operation.error = nil; operation.updatedAt = now
            try operation.review.validateResult(result); try applyConversationHistory(operation, now: now)
            if var files = operation.files {
                files.phase = .failed; files.error = ConversationHistoryFilesState.notStartedMessage
                files.postHistorySourceFingerprint = try snapshot.checkpointRestoreSourceFingerprint(threadID: operation.review.sourceThreadID)
                files.updatedAt = now; operation.files = files
            }
        case .unchanged:
            guard operation.review.openCodeV2 == nil, operation.review.openCodeV1 == nil, operation.review.claude == nil, operation.review.pi == nil else { throw ProviderHistoryError(.invalidResponse) }
            operation.phase = .failed; operation.error = ConversationHistoryOperation.unchangedMessage; operation.updatedAt = now
        case .piOriginalKept(let observed):
            guard let evidence = operation.review.pi, observed == evidence.source else { throw ProviderHistoryError(.historyChanged) }
            try observed.validate()
            operation.phase = .failed; operation.error = ConversationHistoryOperation.piNotAdoptedMessage; operation.updatedAt = now
        case .claudeForkNotStarted(let observed):
            guard let evidence = operation.review.claude, operation.review.kind == .forkAfterRun,
                  operation.claudeForkPublication != nil, observed == evidence.source else { throw ProviderHistoryError(.invalidResponse) }
            try observed.validate()
            operation.phase = .failed; operation.error = ConversationHistoryOperation.unchangedMessage; operation.updatedAt = now
        case .openCodeV1NotAdopted(let observed):
            guard let evidence = operation.review.openCodeV1 else { throw ProviderHistoryError(.invalidResponse) }
            try observed.validate()
            guard observed == evidence.source else { throw ProviderHistoryError(.historyChanged) }
            operation.phase = .failed; operation.error = ConversationHistoryOperation.openCodeV1NotAdoptedMessage; operation.updatedAt = now
        case .openCodeV2Unchanged(let observed):
            guard let evidence = operation.review.openCodeV2 else { throw ProviderHistoryError(.invalidResponse) }
            try observed.validate()
            guard observed.reference == evidence.source.reference, observed.runtimeIdentity == evidence.source.runtimeIdentity,
                  observed.workspacePath == evidence.source.workspacePath, observed.stage == nil,
                  observed.fork == evidence.source.fork, observed.messages.allSatisfy(\.isSettled) else { throw ProviderHistoryError(.historyChanged) }
            if observed.maintenance == nil {
                guard observed.messages == evidence.source.messages else { throw ProviderHistoryError(.historyChanged) }
            } else {
                guard let maintenance = operation.maintenance, maintenance.phase == .applied,
                      maintenance.expected.messages == evidence.source.messages, maintenance.result == observed else { throw ProviderHistoryError(.historyChanged) }
            }
            operation.phase = .failed; operation.error = ConversationHistoryOperation.unchangedMessage; operation.updatedAt = now
        }
        snapshot.conversationHistoryOperations?[i] = operation
    }

    private mutating func applyConversationHistory(_ operation: ConversationHistoryOperation, now: Date) throws {
        let review = operation.review
        guard let sourceIndex = snapshot.threads.firstIndex(where: { $0.id == review.sourceThreadID }), let result = operation.result else { throw WorkspaceCommandError("The history action lost its source conversation.") }
        switch review.kind {
        case .forkAfterRun:
            guard let targetID = review.targetThreadID, !snapshot.threads.contains(where: { $0.id == targetID }),
                  let project = snapshot.projects.first(where: { $0.id == review.projectID }) else { throw WorkspaceCommandError("The fork target is no longer available.") }
            let configuration = review.targetConfiguration
            var target = CodingThread(project: project, model: configuration.model)
            target.id = targetID; target.title = operation.targetTitle ?? review.suggestedTitle
            target.workspacePath = configuration.workspacePath; target.provider = configuration.provider
            target.reasoningEffort = configuration.reasoningEffort; target.permission = configuration.permission; target.acpAgent = configuration.acpAgent; target.openCodeConfiguration = configuration.openCodeConfiguration; target.piConfiguration = configuration.piConfiguration; target.museConfiguration = configuration.museConfiguration; target.antigravityConfiguration = configuration.antigravityConfiguration; target.codexRuntimeConfiguration = configuration.codexRuntimeConfiguration
            target.claudeRuntimeConfiguration = configuration.claudeRuntimeConfiguration
            target.claudeResumeSelection = nil; target.claudeResumeConsumerRunID = nil
            target.claudeInheritedHead = result.claude?.inheritedHead
            target.piFreshSessionIntent = result.pi?.freshIntent; target.piFreshConsumerRunID = nil
            target.agentModeID = configuration.agentModeID; target.agentConfigValues = configuration.agentConfigValues
            target.agentConfiguration = configuration.agentConfiguration; target.providerThreadID = result.reference.nativeThreadID
            target.messages = review.prefix; target.forkedFromHistoryOperationID = operation.id
            target.checkpointPolicy = snapshot.threads[sourceIndex].checkpointPolicy
            if project.scratch != nil {
                guard let grant = operation.scratchFork else { throw ScratchWorkspaceError() }
                try grant.validate(review: review)
                guard grant.source == snapshot.threads[sourceIndex].scratchWorkspace else { throw ScratchWorkspaceError() }
                target.scratchWorkspace = grant.allocation.receipt; target.createdAt = grant.allocation.receipt.createdAt
            } else {
                guard operation.scratchFork == nil else { throw ScratchWorkspaceError() }
                target.createdAt = now
            }
            target.updatedAt = now
            snapshot.threads.append(target)
        case .rewindBeforeRun:
            var source = snapshot.threads[sourceIndex]
            let removedMessages = Set(review.removedMessageIDs), removedRuns = Set(review.removedRunIDs)
            for i in source.messages.indices where removedMessages.contains(source.messages[i].id) { source.messages[i].removedByHistoryOperationID = operation.id }
            for i in (source.runHistory ?? []).indices where removedRuns.contains(source.runHistory![i].id) { source.runHistory?[i].removedByHistoryOperationID = operation.id }
            let preservesPiRuntime = result.pi.map { $0.source == $0.snapshot && $0.candidates.isEmpty } == true
            source.providerThreadID = result.reference.nativeThreadID; source.activeRun = nil
            if !preservesPiRuntime { source.runtimeID = nil }
            if let selection = result.claude?.selection {
                source.claudeResumeSelection = selection; source.claudeResumeConsumerRunID = nil
            }
            if let pi = result.pi { source.piFreshSessionIntent = pi.freshIntent; source.piFreshConsumerRunID = nil }
            source.runtimeRequests = []; source.providerActivity = nil; source.providerMetadata = nil
            source.state = .idle; source.updatedAt = now
            snapshot.threads[sourceIndex] = source
            if !preservesPiRuntime { closeRuntimes.insert(source.id) }
        }
    }

    mutating func recallConversationHistoryPrompt(operationID: UUID, now: Date) throws {
        guard let operationIndex = snapshot.conversationHistoryOperations?.firstIndex(where: { $0.id == operationID }),
              let operation = snapshot.conversationHistoryOperations?[operationIndex], operation.phase == .applied,
              operation.review.kind == .rewindBeforeRun else { throw WorkspaceCommandError("Recall requires an applied conversation rewind.") }
        guard operation.recalledAt == nil else { return }
        guard operation.allExternalWorkSucceeded, operation.recallDismissedAt == nil,
              !snapshot.isConversationHistoryLocked(threadID: operation.review.sourceThreadID, excludingOperationID: operation.needsPromptRecall ? operation.id : nil),
              !snapshot.isCheckpointRestoreLocked(threadID: operation.review.sourceThreadID),
              let sourceIndex = snapshot.threads.firstIndex(where: { $0.id == operation.review.sourceThreadID }),
              let record = snapshot.threads[sourceIndex].runHistory?.first(where: { $0.id == operation.review.runID }), record.origin == .user,
              let message = snapshot.threads[sourceIndex].messages.first(where: { $0.id == record.userMessageID && $0.role == .user && $0.runReference == .init(threadID: operation.review.sourceThreadID, runID: record.id) }) else { throw WorkspaceCommandError("The original prompt is unavailable or another history action is pending.") }
        var source = snapshot.threads[sourceIndex], attachments = snapshot.threads[sourceIndex].draftAttachments
        var ids = Set(attachments.map(\.id))
        for attachment in message.attachments ?? [] where ids.insert(attachment.id).inserted { attachments.append(attachment) }
        do { try AttachmentLimits.validate(attachments) } catch { throw WorkspaceCommandError("The recalled attachments exceed the draft limit. Remove some attachments and try again.") }
        if !message.text.isEmpty { source.draft = source.draft.isEmpty ? message.text : source.draft + "\n\n" + message.text }
        source.draftAttachments = attachments; source.updatedAt = now
        snapshot.threads[sourceIndex] = source; snapshot.conversationHistoryOperations?[operationIndex].recalledAt = now
        snapshot.conversationHistoryOperations?[operationIndex].updatedAt = now
    }
}
