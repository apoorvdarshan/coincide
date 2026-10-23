import Foundation

public enum RemoteHistoryProtocol {
    public static let bindMethod = "remoteEnvironment.history.bind"
    public static let readMethod = "remoteEnvironment.history.read"
    public static let reviewMethod = "remoteEnvironment.history.review"
    public static let discardMethod = "remoteEnvironment.history.discard"
    public static let maximumResultBytes = RemoteProjectionProtocol.maximumResultBytes
    public static let maximumContentChunkBytes = RemoteProjectionProtocol.maximumContentChunkBytes
    public static let maximumLeases = 8
    public static let maximumCacheBytes = RemoteProjectionProtocol.maximumCacheBytes
    public static func payload<T: Encodable>(_ value: T) throws -> Data { try RemoteProjectionProtocol.payload(value) }
    public static func digest<T: Encodable>(_ value: T) throws -> String { RemoteProjectionProtocol.digest(try payload(value)) }
}
public enum RemoteHistoryFilesChoice: String, Codable, Sendable { case keep, restore }
public struct RemoteHistoryBinding: Codable, Sendable, Equatable {
    public let environmentID: UUID, hostID: UUID, leaseID: UUID, threadID: UUID, objectID: UUID
    public let digest: String
    public init(environmentID: UUID, hostID: UUID, leaseID: UUID, threadID: UUID, objectID: UUID, digest: String) {
        self.environmentID = environmentID; self.hostID = hostID; self.leaseID = leaseID; self.threadID = threadID; self.objectID = objectID; self.digest = digest
    }
}
public struct RemoteHistoryPage<Item: Codable & Sendable & Equatable>: Codable, Sendable, Equatable {
    public let binding: RemoteHistoryBinding
    public let offset: Int
    public let items: [Item]
    public let totalCount: Int
    public let nextCursor: UUID?
    public let complete: Bool
    public init(binding: RemoteHistoryBinding, offset: Int, items: [Item], totalCount: Int, nextCursor: UUID?, complete: Bool) {
        self.binding = binding; self.offset = offset; self.items = items; self.totalCount = totalCount; self.nextCursor = nextCursor; self.complete = complete
    }
}
public struct RemoteHistoryFileReview: Codable, Sendable, Equatable {
    public let id: UUID, checkpointRunID: UUID, attemptID: UUID
    public let stage: RunCheckpointStage
    public let affectedPathCount: Int
    public let patch: RemoteProjectionText
    public let patchTruncated: Bool
    public init(id: UUID, checkpointRunID: UUID, attemptID: UUID, stage: RunCheckpointStage, affectedPathCount: Int, patch: RemoteProjectionText, patchTruncated: Bool) {
        self.id = id; self.checkpointRunID = checkpointRunID; self.attemptID = attemptID; self.stage = stage; self.affectedPathCount = affectedPathCount; self.patch = patch; self.patchTruncated = patchTruncated
    }
}
public struct RemoteHistoryReviewSummary: Codable, Sendable, Equatable {
    public let kind: ConversationHistoryKind
    public let runID: UUID
    public let reviewedAt: Date
    public let provider: ProviderKind
    public let workspacePath: String
    public let sourceConfiguration: RemoteProjectionContentReference
    public let targetConfiguration: RemoteProjectionContentReference
    public let retainedMessageCount: Int, removedMessageCount: Int, removedRunCount: Int
    public let targetThreadID: UUID?
    public let suggestedTitle: RemoteProjectionText
    public let files: RemoteHistoryFileReview?
    public let recallPromptOnSuccess: Bool
    public let restoreFiles: RemoteProjectionAvailability
    public let mutatingPaths: [String], coordinationPaths: [String]
    public let details: [RemoteOperationDetail], warnings: [RemoteProjectionText]
    public init(kind: ConversationHistoryKind, runID: UUID, reviewedAt: Date, provider: ProviderKind, workspacePath: String, sourceConfiguration: RemoteProjectionContentReference, targetConfiguration: RemoteProjectionContentReference, retainedMessageCount: Int, removedMessageCount: Int, removedRunCount: Int, targetThreadID: UUID?, suggestedTitle: RemoteProjectionText, files: RemoteHistoryFileReview?, recallPromptOnSuccess: Bool, restoreFiles: RemoteProjectionAvailability, mutatingPaths: [String] = [], coordinationPaths: [String] = [], details: [RemoteOperationDetail] = [], warnings: [RemoteProjectionText] = []) {
        self.kind = kind; self.runID = runID; self.reviewedAt = reviewedAt; self.provider = provider; self.workspacePath = workspacePath
        self.sourceConfiguration = sourceConfiguration; self.targetConfiguration = targetConfiguration; self.retainedMessageCount = retainedMessageCount; self.removedMessageCount = removedMessageCount; self.removedRunCount = removedRunCount
        self.targetThreadID = targetThreadID; self.suggestedTitle = suggestedTitle; self.files = files; self.recallPromptOnSuccess = recallPromptOnSuccess; self.restoreFiles = restoreFiles
        self.mutatingPaths = mutatingPaths; self.coordinationPaths = coordinationPaths; self.details = details; self.warnings = warnings
    }
}
public struct RemoteHistoryReviewRequest: Codable, Sendable, Equatable {
    public let target: RemoteWorkspaceTarget
    public let runID: UUID
    public let kind: ConversationHistoryKind
    public let files: RemoteHistoryFilesChoice
    public let recallPromptOnSuccess: Bool
    public init(target: RemoteWorkspaceTarget, runID: UUID, kind: ConversationHistoryKind, files: RemoteHistoryFilesChoice = .keep, recallPromptOnSuccess: Bool = false) {
        self.target = target; self.runID = runID; self.kind = kind; self.files = files; self.recallPromptOnSuccess = recallPromptOnSuccess
    }
}
public struct RemoteHistoryReview: Codable, Sendable, Equatable, Identifiable {
    public let target: RemoteWorkspaceTarget
    public let id: UUID
    public let digest: String
    public let binding: RemoteHistoryBinding
    public let value: RemoteHistoryReviewSummary
    public init(target: RemoteWorkspaceTarget, id: UUID, digest: String, binding: RemoteHistoryBinding, value: RemoteHistoryReviewSummary) {
        self.target = target; self.id = id; self.digest = digest; self.binding = binding; self.value = value
    }
}
public enum RemoteHistoryAction: Codable, Sendable, Equatable {
    case begin(reviewID: UUID, digest: String, title: String?)
    case inspectProvider(operationID: UUID)
    case inspectFiles(operationID: UUID)
    case acknowledgeFiles(operationID: UUID)
    case recallPrompt(operationID: UUID)
    case dismissRecall(operationID: UUID)
    case keepOpenCodeV1Original(operationID: UUID)
    case clearMaintenance(operationID: UUID, reviewID: UUID, digest: String)
    case keepPiOriginal(operationID: UUID)
    case cancelPi(operationID: UUID)
    case respondPi(operationID: UUID, sessionID: UUID, request: ApprovalRequest, response: ProviderApprovalResponse)
    case inspectClaudeResume(selectionID: UUID, consumerRunID: UUID)
    case acknowledgePiFreshUnwritten(intentID: UUID, consumerRunID: UUID)
    case confirmPiFreshPersisted(intentID: UUID, consumerRunID: UUID)
    public var requiresBoundRoot: Bool {
        switch self { case .acknowledgeFiles, .recallPrompt, .dismissRecall, .cancelPi, .respondPi: false; default: true }
    }
}
public struct RemoteHistoryOperationView: Codable, Sendable, Equatable {
    public let binding: RemoteHistoryBinding
    public let operation: RemoteOperationSummary
    public let kind: ConversationHistoryKind
    public let provider: ProviderKind
    public let filesPhase: ConversationHistoryFilesPhase?
    public let filesAcknowledged: Bool
    public let needsPromptRecall: Bool
    public let recalled: Bool
    public let recallDismissed: Bool
    public let piSessionID: UUID?
    public let piRequests: RemoteProjectionContentReference?
    public let maintenanceClaim: RemoteHistoryMaintenanceClaim?
    public init(binding: RemoteHistoryBinding, operation: RemoteOperationSummary, kind: ConversationHistoryKind, provider: ProviderKind, filesPhase: ConversationHistoryFilesPhase?, filesAcknowledged: Bool, needsPromptRecall: Bool, recalled: Bool, recallDismissed: Bool, piSessionID: UUID?, piRequests: RemoteProjectionContentReference?, maintenanceClaim: RemoteHistoryMaintenanceClaim? = nil) {
        self.binding = binding; self.operation = operation; self.kind = kind; self.provider = provider; self.filesPhase = filesPhase; self.filesAcknowledged = filesAcknowledged
        self.needsPromptRecall = needsPromptRecall; self.recalled = recalled; self.recallDismissed = recallDismissed; self.piSessionID = piSessionID; self.piRequests = piRequests
        self.maintenanceClaim = maintenanceClaim
    }
}
public struct RemoteHistoryMaintenanceClaim: Codable, Sendable, Equatable {
    public let id: UUID
    public let digest: String
    public init(id: UUID, digest: String) { self.id = id; self.digest = digest }
}
public struct RemoteHistoryThreadControls: Codable, Sendable, Equatable {
    public let claudeSelectionID: UUID?, claudeConsumerRunID: UUID?, piIntentID: UUID?, piConsumerRunID: UUID?
    public let canInspectClaudeResume: Bool, canInspectPiFresh: Bool
    public init(claudeSelectionID: UUID?, claudeConsumerRunID: UUID?, piIntentID: UUID?, piConsumerRunID: UUID?, canInspectClaudeResume: Bool, canInspectPiFresh: Bool) {
        self.claudeSelectionID = claudeSelectionID; self.claudeConsumerRunID = claudeConsumerRunID; self.piIntentID = piIntentID; self.piConsumerRunID = piConsumerRunID
        self.canInspectClaudeResume = canInspectClaudeResume; self.canInspectPiFresh = canInspectPiFresh
    }
}
public struct RemoteHistoryRecallPayload: Codable, Sendable, Equatable {
    public let binding: RemoteHistoryBinding
    public let operationID: UUID, runID: UUID
    public let messageID: String
    public let text: RemoteProjectionText
    public let attachments: RemoteProjectionContentReference
    public init(binding: RemoteHistoryBinding, operationID: UUID, runID: UUID, messageID: String, text: RemoteProjectionText, attachments: RemoteProjectionContentReference) {
        self.binding = binding; self.operationID = operationID; self.runID = runID; self.messageID = messageID; self.text = text; self.attachments = attachments
    }
}
public enum RemoteHistoryQuery: Codable, Sendable, Equatable {
    case operation(operationID: UUID)
    case controls
    case recall(operationID: UUID)
    case piFresh(intentID: UUID, consumerRunID: UUID)
    case maintenance(operationID: UUID)
    case release(binding: RemoteHistoryBinding)
    case prefix(binding: RemoteHistoryBinding, newestFirst: Bool, cursor: UUID?)
    case paths(binding: RemoteHistoryBinding, cursor: UUID?)
    case content(binding: RemoteHistoryBinding, reference: RemoteProjectionContentReference, offset: Int, cursor: UUID?)
}
public struct RemoteHistoryReadRequest: Codable, Sendable, Equatable {
    public let target: RemoteWorkspaceTarget
    public let query: RemoteHistoryQuery
    public init(target: RemoteWorkspaceTarget, query: RemoteHistoryQuery) { self.target = target; self.query = query }
}
public struct RemoteHistoryContent: Codable, Sendable, Equatable {
    public let binding: RemoteHistoryBinding
    public let reference: RemoteProjectionContentReference
    public let offset: Int
    public let data: Data
    public let nextCursor: UUID?
    public let complete: Bool
    public init(binding: RemoteHistoryBinding, reference: RemoteProjectionContentReference, offset: Int, data: Data, nextCursor: UUID?, complete: Bool) {
        self.binding = binding; self.reference = reference; self.offset = offset; self.data = data; self.nextCursor = nextCursor; self.complete = complete
    }
}
public enum RemoteHistoryValue: Codable, Sendable, Equatable {
    case operation(RemoteHistoryOperationView)
    case controls(RemoteHistoryThreadControls)
    case recall(RemoteHistoryRecallPayload)
    case messages(RemoteHistoryPage<RemoteMessageSummary>)
    case paths(RemoteHistoryPage<String>)
    case content(RemoteHistoryContent)
    case piFresh(RemoteHistoryPiFreshInspection)
    case released(Bool)
}
public struct RemoteHistoryPiFreshInspection: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable { case unwritten, persisted, unavailable }
    public let intentID: UUID, consumerRunID: UUID
    public let state: State
    public init(intentID: UUID, consumerRunID: UUID, state: State) { self.intentID = intentID; self.consumerRunID = consumerRunID; self.state = state }
}
public struct RemoteHistoryReadResult: Codable, Sendable, Equatable {
    public let target: RemoteWorkspaceTarget
    public let value: RemoteHistoryValue
    public init(target: RemoteWorkspaceTarget, value: RemoteHistoryValue) { self.target = target; self.value = value }
}
public struct RemoteHistoryDiscardRequest: Codable, Sendable, Equatable {
    public let target: RemoteWorkspaceTarget
    public let reviewID: UUID
    public let digest: String
    public init(target: RemoteWorkspaceTarget, reviewID: UUID, digest: String) { self.target = target; self.reviewID = reviewID; self.digest = digest }
}
public struct RemoteHistoryDiscardResult: Codable, Sendable, Equatable {
    public let request: RemoteHistoryDiscardRequest
    public let discarded: Bool
    public init(request: RemoteHistoryDiscardRequest, discarded: Bool) { self.request = request; self.discarded = discarded }
}
public struct RemoteHistoryFailure: Error, Codable, Sendable, Equatable, LocalizedError {
    public enum Kind: String, Codable, Sendable { case invalidRequest, invalidTarget, staleReview, staleCursor, unavailable, busy, limitExceeded, operationFailed }
    public let kind: Kind
    public init(_ kind: Kind) { self.kind = kind }
    public var errorDescription: String? {
        switch kind {
        case .invalidRequest: "The remote history request is invalid."
        case .invalidTarget: "The remote conversation or checkout changed. Refresh before continuing."
        case .staleReview: "This history review or display lease changed or expired. Review the current state again."
        case .staleCursor: "This history page cursor changed or expired."
        case .unavailable: "Remote conversation history is unavailable."
        case .busy: "Another operation owns this remote conversation or checkout."
        case .limitExceeded: "The remote history request exceeded its limit."
        case .operationFailed: "The remote history operation could not be confirmed. Inspect its saved state before continuing."
        }
    }
}
