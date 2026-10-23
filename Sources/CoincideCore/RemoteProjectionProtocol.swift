import CryptoKit
import Foundation

public enum RemoteProjectionProtocol {
    public static let maximumPageBytes = 256 * 1_024
    public static let maximumResultBytes = maximumPageBytes - 2_048
    public static let maximumContentChunkBytes = 128 * 1_024
    public static let maximumViews = 8
    public static let maximumCacheBytes = 128 * 1_024 * 1_024
    public static let openMethod = "remoteEnvironment.projection.open"
    public static let subscribeMethod = "remoteEnvironment.projection.subscribe"
    public static let catalogMethod = "remoteEnvironment.projection.catalog"
    public static let threadMethod = "remoteEnvironment.projection.thread"
    public static let messagesMethod = "remoteEnvironment.projection.messages"
    public static let runsMethod = "remoteEnvironment.projection.runs"
    public static let operationsMethod = "remoteEnvironment.projection.operations"
    public static let contentMethod = "remoteEnvironment.projection.content"
    public static let releaseMethod = "remoteEnvironment.projection.release"
    public static let changedNotification = "remoteEnvironment.projection.changed"
    public static func payload<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    public static func digest(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
}
public enum RemoteProjectionScope: Codable, Sendable, Equatable { case catalog, thread(UUID), control(UUID) }
public enum RemoteProjectionContentKind: String, Codable, Sendable {
    case text, configuration, draft, attachmentReferences, runtimeRequests, queuedTurns, checkpointAttempts
}
public enum RemoteProjectionCatalogQuery: Codable, Sendable, Equatable {
    case projects
    case threads(projectID: UUID?, includeArchived: Bool)
}

public struct RemoteProjectionBinding: Codable, Sendable, Equatable {
    public let environmentID: UUID
    public let hostID: UUID
    public let viewID: UUID
    public let sequence: Int64
    public let fingerprint: String
    public let scope: RemoteProjectionScope
    public init(environmentID: UUID, hostID: UUID, viewID: UUID, sequence: Int64, fingerprint: String, scope: RemoteProjectionScope) {
        self.environmentID = environmentID
        self.hostID = hostID
        self.viewID = viewID
        self.sequence = sequence
        self.fingerprint = fingerprint
        self.scope = scope
    }
}

public struct RemoteProjectionInvalidation: Codable, Sendable, Equatable {
    public let environmentID: UUID
    public let hostID: UUID
    public let sequence: Int64
    public init(environmentID: UUID, hostID: UUID, sequence: Int64) {
        self.environmentID = environmentID
        self.hostID = hostID
        self.sequence = sequence
    }
}

public struct RemoteProjectionOpenRequest: Codable, Sendable, Equatable {
    public let environmentID: UUID
    public let scope: RemoteProjectionScope
    public let minimumSequence: Int64?
    public init(environmentID: UUID, scope: RemoteProjectionScope = .catalog, minimumSequence: Int64? = nil) {
        self.environmentID = environmentID
        self.scope = scope
        self.minimumSequence = minimumSequence
    }
}

public typealias RemoteProjectionOpenResult = RemoteProjectionBinding

public struct RemoteProjectionPage<Item: Codable & Sendable & Equatable>: Codable, Sendable, Equatable {
    public let binding: RemoteProjectionBinding
    public let offset: Int
    public let items: [Item]
    public let totalCount: Int
    public let nextCursor: UUID?
    public let complete: Bool
    public init(binding: RemoteProjectionBinding, offset: Int = 0, items: [Item], totalCount: Int, nextCursor: UUID? = nil, complete: Bool) {
        self.binding = binding
        self.offset = offset
        self.items = items
        self.totalCount = totalCount
        self.nextCursor = nextCursor
        self.complete = complete
    }
}

public struct RemoteProjectionContentReference: Codable, Sendable, Equatable {
    public let id: UUID
    public let kind: RemoteProjectionContentKind
    public let totalBytes: Int
    public let digest: String
    public init(id: UUID, kind: RemoteProjectionContentKind, totalBytes: Int, digest: String) {
        self.id = id
        self.kind = kind
        self.totalBytes = totalBytes
        self.digest = digest
    }
}

public struct RemoteProjectionText: Codable, Sendable, Equatable {
    public let preview: String
    public let complete: Bool
    public let content: RemoteProjectionContentReference?
    public init(preview: String, complete: Bool, content: RemoteProjectionContentReference? = nil) {
        self.preview = preview
        self.complete = complete
        self.content = content
    }
}

public struct RemoteProjectionAvailability: Codable, Sendable, Equatable {
    public let allowed: Bool
    public let reason: String?
    public init(allowed: Bool, reason: String? = nil) {
        self.allowed = allowed
        self.reason = reason
    }
}

public struct RemoteProjectSummary: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let name: RemoteProjectionText
    public let workspacePath: String
    public let clonePhase: ProjectClonePhase?
    public let cloneError: RemoteProjectionText?
    public let createdAt: Date?
    public let updatedAt: Date?
    public init(id: UUID, name: RemoteProjectionText, workspacePath: String, clonePhase: ProjectClonePhase? = nil, cloneError: RemoteProjectionText? = nil, createdAt: Date? = nil, updatedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.workspacePath = workspacePath
        self.clonePhase = clonePhase
        self.cloneError = cloneError
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct RemoteThreadSummary: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let projectID: UUID
    public let title: RemoteProjectionText
    public let workspacePath: String
    public let provider: ProviderKind
    public let providerName: String
    public let model: RemoteProjectionText
    public let permission: PermissionMode
    public let state: ThreadState
    public let isPinned: Bool
    public let isArchived: Bool
    public let createdAt: Date
    public let updatedAt: Date
    public let messageCount: Int
    public let runCount: Int
    public let queueCount: Int
    public init(id: UUID, projectID: UUID, title: RemoteProjectionText, workspacePath: String, provider: ProviderKind, providerName: String, model: RemoteProjectionText, permission: PermissionMode, state: ThreadState, isPinned: Bool, isArchived: Bool, createdAt: Date, updatedAt: Date, messageCount: Int, runCount: Int, queueCount: Int) {
        self.id = id
        self.projectID = projectID
        self.title = title
        self.workspacePath = workspacePath
        self.provider = provider
        self.providerName = providerName
        self.model = model
        self.permission = permission
        self.state = state
        self.isPinned = isPinned
        self.isArchived = isArchived
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messageCount = messageCount
        self.runCount = runCount
        self.queueCount = queueCount
    }
}

public struct RemoteActiveRunSummary: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let runtimeID: UUID?
    public let startedAt: Date
    public let stopRequested: Bool
    public init(id: UUID, runtimeID: UUID? = nil, startedAt: Date, stopRequested: Bool) {
        self.id = id
        self.runtimeID = runtimeID
        self.startedAt = startedAt
        self.stopRequested = stopRequested
    }
}

public struct RemoteWorktreePreparationSummary: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let phase: ThreadWorkspacePreparationPhase
    public let sourcePath: String
    public let destinationPath: String
    public let submodules: ProjectWorktreeSubmoduleMode
    public let cancelRequested: Bool
    public let hasPlan: Bool
    public let canCancel: Bool
    public let canRetry: Bool
    public let canInspect: Bool
    public let error: RemoteProjectionText?
    public let warnings: [RemoteProjectionText]
    public init(id: UUID, phase: ThreadWorkspacePreparationPhase, sourcePath: String, destinationPath: String, submodules: ProjectWorktreeSubmoduleMode, cancelRequested: Bool, hasPlan: Bool, canCancel: Bool, canRetry: Bool, canInspect: Bool, error: RemoteProjectionText? = nil, warnings: [RemoteProjectionText] = []) {
        self.id = id
        self.phase = phase
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
        self.submodules = submodules
        self.cancelRequested = cancelRequested
        self.hasPlan = hasPlan
        self.canCancel = canCancel
        self.canRetry = canRetry
        self.canInspect = canInspect
        self.error = error
        self.warnings = warnings
    }
}

public struct RemoteThreadDetail: Codable, Sendable, Equatable {
    public let summary: RemoteThreadSummary
    public let configuration: RemoteProjectionContentReference
    public let draft: RemoteProjectionText
    public let draftAttachments: RemoteProjectionContentReference
    public let runtimeRequests: RemoteProjectionContentReference
    public let requestCount: Int
    public let queuePaused: Bool
    public let checkpointPolicy: RunCheckpointPolicy
    public let activeRun: RemoteActiveRunSummary?
    public let runtimeID: UUID?
    public let workspaceReady: Bool
    public let isBusy: Bool
    public let submit: RemoteProjectionAvailability
    public let resumeQueue: RemoteProjectionAvailability
    public let mutateFiles: RemoteProjectionAvailability
    public let openTerminal: RemoteProjectionAvailability
    public let chooseWorktree: RemoteProjectionAvailability
    public let preparation: RemoteWorktreePreparationSummary?
    public let settlementID: UUID?
    public let checkpointBanner: RemoteCheckpointBannerSummary?
    public init(summary: RemoteThreadSummary, configuration: RemoteProjectionContentReference, draft: RemoteProjectionText, draftAttachments: RemoteProjectionContentReference, runtimeRequests: RemoteProjectionContentReference, requestCount: Int, queuePaused: Bool, checkpointPolicy: RunCheckpointPolicy, activeRun: RemoteActiveRunSummary? = nil, runtimeID: UUID? = nil, workspaceReady: Bool, isBusy: Bool, submit: RemoteProjectionAvailability, resumeQueue: RemoteProjectionAvailability, mutateFiles: RemoteProjectionAvailability, openTerminal: RemoteProjectionAvailability, chooseWorktree: RemoteProjectionAvailability, preparation: RemoteWorktreePreparationSummary? = nil, settlementID: UUID? = nil, checkpointBanner: RemoteCheckpointBannerSummary? = nil) {
        self.summary = summary
        self.configuration = configuration
        self.draft = draft
        self.draftAttachments = draftAttachments
        self.runtimeRequests = runtimeRequests
        self.requestCount = requestCount
        self.queuePaused = queuePaused
        self.checkpointPolicy = checkpointPolicy
        self.activeRun = activeRun
        self.runtimeID = runtimeID
        self.workspaceReady = workspaceReady
        self.isBusy = isBusy
        self.submit = submit
        self.resumeQueue = resumeQueue
        self.mutateFiles = mutateFiles
        self.openTerminal = openTerminal
        self.chooseWorktree = chooseWorktree
        self.preparation = preparation
        self.settlementID = settlementID
        self.checkpointBanner = checkpointBanner
    }
}

public struct RemoteMessageSummary: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let role: MessageRole
    public let createdAt: Date
    public let text: RemoteProjectionText
    public let attachments: RemoteProjectionContentReference?
    public let attachmentCount: Int
    public let runReference: TranscriptRunReference?
    public let removedByHistoryOperationID: UUID?
    public let submissionError: RemoteProjectionText?
    public let title: RemoteProjectionText?
    public let status: RemoteProjectionText?
    public init(id: String, role: MessageRole, createdAt: Date, text: RemoteProjectionText, attachments: RemoteProjectionContentReference? = nil, attachmentCount: Int, runReference: TranscriptRunReference? = nil, removedByHistoryOperationID: UUID? = nil, submissionError: RemoteProjectionText? = nil, title: RemoteProjectionText? = nil, status: RemoteProjectionText? = nil) {
        self.id = id
        self.role = role
        self.createdAt = createdAt
        self.text = text
        self.attachments = attachments
        self.attachmentCount = attachmentCount
        self.runReference = runReference
        self.removedByHistoryOperationID = removedByHistoryOperationID
        self.submissionError = submissionError
        self.title = title
        self.status = status
    }
}

public struct RemoteCheckpointAttemptSummary: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let stage: RunCheckpointStage
    public let workspacePath: String
    public let phase: RunCheckpointPhase
    public let requestedAt: Date
    public let updatedAt: Date
    public let isLaterObservation: Bool
    public let hasReceipt: Bool
    public let digest: String
    public let restore: RemoteProjectionAvailability
    public let error: RemoteProjectionText?
    public let cleanupWarning: RemoteProjectionText?
    public init(id: UUID, stage: RunCheckpointStage, workspacePath: String, phase: RunCheckpointPhase, requestedAt: Date, updatedAt: Date, isLaterObservation: Bool, hasReceipt: Bool, digest: String, restore: RemoteProjectionAvailability, error: RemoteProjectionText? = nil, cleanupWarning: RemoteProjectionText? = nil) {
        self.id = id
        self.stage = stage
        self.workspacePath = workspacePath
        self.phase = phase
        self.requestedAt = requestedAt
        self.updatedAt = updatedAt
        self.isLaterObservation = isLaterObservation
        self.hasReceipt = hasReceipt
        self.digest = digest
        self.restore = restore
        self.error = error
        self.cleanupWarning = cleanupWarning
    }
}

public struct RemoteRunSummary: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let origin: ThreadRunOrigin
    public let status: ThreadRunStatus
    public let startedAt: Date
    public let endedAt: Date?
    public let userMessageID: String?
    public let stopRequested: Bool
    public let endReason: ThreadRunEndReason?
    public let turnCount: Int
    public let removedByHistoryOperationID: UUID?
    public let checkpointAttempts: [RemoteCheckpointAttemptSummary]
    public let checkpointAttemptCount: Int
    public let checkpointAttemptsComplete: Bool
    public let checkpointAttemptsContent: RemoteProjectionContentReference?
    public let checkpointDiff: RemoteProjectionAvailability
    public let fork: RemoteProjectionAvailability
    public let rewind: RemoteProjectionAvailability
    public let provider: ProviderKind
    public let providerName: String
    public let model: RemoteProjectionText
    public let permission: PermissionMode
    public let workspacePath: String
    public let checkpointPolicy: RunCheckpointPolicy?
    public let configuration: RemoteProjectionContentReference?
    public init(id: UUID, origin: ThreadRunOrigin, status: ThreadRunStatus, startedAt: Date, endedAt: Date? = nil, userMessageID: String? = nil, stopRequested: Bool, endReason: ThreadRunEndReason? = nil, turnCount: Int, removedByHistoryOperationID: UUID? = nil, checkpointAttempts: [RemoteCheckpointAttemptSummary], checkpointAttemptCount: Int, checkpointAttemptsComplete: Bool, checkpointAttemptsContent: RemoteProjectionContentReference? = nil, checkpointDiff: RemoteProjectionAvailability, fork: RemoteProjectionAvailability, rewind: RemoteProjectionAvailability, provider: ProviderKind = .codex, providerName: String = "", model: RemoteProjectionText = .init(preview: "", complete: true), permission: PermissionMode = .supervised, workspacePath: String = "", checkpointPolicy: RunCheckpointPolicy? = nil, configuration: RemoteProjectionContentReference? = nil) {
        self.id = id
        self.origin = origin
        self.status = status
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.userMessageID = userMessageID
        self.stopRequested = stopRequested
        self.endReason = endReason
        self.turnCount = turnCount
        self.removedByHistoryOperationID = removedByHistoryOperationID
        self.checkpointAttempts = checkpointAttempts
        self.checkpointAttemptCount = checkpointAttemptCount
        self.checkpointAttemptsComplete = checkpointAttemptsComplete
        self.checkpointAttemptsContent = checkpointAttemptsContent
        self.checkpointDiff = checkpointDiff
        self.fork = fork
        self.rewind = rewind
        self.provider = provider
        self.providerName = providerName
        self.model = model
        self.permission = permission
        self.workspacePath = workspacePath
        self.checkpointPolicy = checkpointPolicy
        self.configuration = configuration
    }
}

public enum RemoteOperationKind: String, Codable, Sendable { case conversationHistory, checkpointRestore, pullRequestCreation, pullRequestCheckout, promptSteering, worktreePreparation, settlement, projectClone }

public struct RemoteOperationSummary: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let kind: RemoteOperationKind
    public let projectID: UUID
    public let threadID: UUID?
    public let runID: UUID?
    public let attemptID: UUID?
    public let targetThreadID: UUID?
    public let phase: String
    public let updatedAt: Date
    public let title: RemoteProjectionText
    public let error: RemoteProjectionText?
    public let acknowledged: Bool
    public let cancelRequested: Bool
    public let actions: [String: RemoteProjectionAvailability]
    public let fingerprint: String
    public let details: [RemoteOperationDetail]
    public let warnings: [RemoteProjectionText]
    public let workspacePaths: [String]
    public let pullRequest: GitHubPullRequestReference?
    public let url: String?
    public let readOnly: Bool?
    public init(id: UUID, kind: RemoteOperationKind, projectID: UUID, threadID: UUID? = nil, runID: UUID? = nil, attemptID: UUID? = nil, targetThreadID: UUID? = nil, phase: String, updatedAt: Date, title: RemoteProjectionText, error: RemoteProjectionText? = nil, acknowledged: Bool, cancelRequested: Bool, actions: [String: RemoteProjectionAvailability], fingerprint: String, details: [RemoteOperationDetail] = [], warnings: [RemoteProjectionText] = [], workspacePaths: [String] = [], pullRequest: GitHubPullRequestReference? = nil, url: String? = nil, readOnly: Bool? = nil) {
        self.id = id
        self.kind = kind
        self.projectID = projectID
        self.threadID = threadID
        self.runID = runID
        self.attemptID = attemptID
        self.targetThreadID = targetThreadID
        self.phase = phase
        self.updatedAt = updatedAt
        self.title = title
        self.error = error
        self.acknowledged = acknowledged
        self.cancelRequested = cancelRequested
        self.actions = actions
        self.fingerprint = fingerprint
        self.details = details
        self.warnings = warnings
        self.workspacePaths = workspacePaths
        self.pullRequest = pullRequest
        self.url = url
        self.readOnly = readOnly
    }
}

public struct RemoteProjectionCatalogRequest: Codable, Sendable, Equatable {
    public let binding: RemoteProjectionBinding
    public let query: RemoteProjectionCatalogQuery
    public let cursor: UUID?
    public init(binding: RemoteProjectionBinding, query: RemoteProjectionCatalogQuery, cursor: UUID? = nil) {
        self.binding = binding
        self.query = query
        self.cursor = cursor
    }
}

public enum RemoteProjectionCatalogResult: Codable, Sendable, Equatable { case projects(RemoteProjectionPage<RemoteProjectSummary>), threads(RemoteProjectionPage<RemoteThreadSummary>) }

public struct RemoteProjectionThreadRequest: Codable, Sendable, Equatable {
    public let binding: RemoteProjectionBinding
    public let threadID: UUID
    public init(binding: RemoteProjectionBinding, threadID: UUID) {
        self.binding = binding
        self.threadID = threadID
    }
}

public struct RemoteProjectionThreadResult: Codable, Sendable, Equatable {
    public let binding: RemoteProjectionBinding
    public let thread: RemoteThreadDetail
    public init(binding: RemoteProjectionBinding, thread: RemoteThreadDetail) {
        self.binding = binding
        self.thread = thread
    }
}

public struct RemoteProjectionMessagesRequest: Codable, Sendable, Equatable {
    public let binding: RemoteProjectionBinding
    public let threadID: UUID
    public let newestFirst: Bool
    public let cursor: UUID?
    public init(binding: RemoteProjectionBinding, threadID: UUID, newestFirst: Bool = true, cursor: UUID? = nil) {
        self.binding = binding
        self.threadID = threadID
        self.newestFirst = newestFirst
        self.cursor = cursor
    }
}

public typealias RemoteProjectionMessagesResult = RemoteProjectionPage<RemoteMessageSummary>

public struct RemoteProjectionRunsRequest: Codable, Sendable, Equatable {
    public let binding: RemoteProjectionBinding
    public let threadID: UUID
    public let cursor: UUID?
    public init(binding: RemoteProjectionBinding, threadID: UUID, cursor: UUID? = nil) {
        self.binding = binding
        self.threadID = threadID
        self.cursor = cursor
    }
}

public typealias RemoteProjectionRunsResult = RemoteProjectionPage<RemoteRunSummary>

public struct RemoteProjectionOperationsRequest: Codable, Sendable, Equatable {
    public let binding: RemoteProjectionBinding
    public let threadID: UUID?
    public let cursor: UUID?
    public init(binding: RemoteProjectionBinding, threadID: UUID? = nil, cursor: UUID? = nil) {
        self.binding = binding
        self.threadID = threadID
        self.cursor = cursor
    }
}

public typealias RemoteProjectionOperationsResult = RemoteProjectionPage<RemoteOperationSummary>

public struct RemoteProjectionContentRequest: Codable, Sendable, Equatable {
    public let binding: RemoteProjectionBinding
    public let reference: RemoteProjectionContentReference
    public let offset: Int
    public let cursor: UUID?
    public init(binding: RemoteProjectionBinding, reference: RemoteProjectionContentReference, offset: Int = 0, cursor: UUID? = nil) {
        self.binding = binding
        self.reference = reference
        self.offset = offset
        self.cursor = cursor
    }
}

public struct RemoteProjectionContentResult: Codable, Sendable, Equatable {
    public let binding: RemoteProjectionBinding
    public let reference: RemoteProjectionContentReference
    public let offset: Int
    public let data: Data
    public let nextCursor: UUID?
    public let complete: Bool
    public init(binding: RemoteProjectionBinding, reference: RemoteProjectionContentReference, offset: Int, data: Data, nextCursor: UUID? = nil, complete: Bool) {
        self.binding = binding
        self.reference = reference
        self.offset = offset
        self.data = data
        self.nextCursor = nextCursor
        self.complete = complete
    }
}

public struct RemoteProjectionReleaseRequest: Codable, Sendable, Equatable {
    public let binding: RemoteProjectionBinding
    public init(binding: RemoteProjectionBinding) {
        self.binding = binding
    }
}

public struct RemoteProjectionReleaseResult: Codable, Sendable, Equatable {
    public let binding: RemoteProjectionBinding
    public let released: Bool
    public init(binding: RemoteProjectionBinding, released: Bool) {
        self.binding = binding
        self.released = released
    }
}

public struct RemoteProjectionFailure: Error, Codable, Sendable, Equatable, LocalizedError {
    public enum Kind: String, Codable, Sendable { case invalidRequest, wrongEnvironment, staleView, staleCursor, notFound, unavailable, limitExceeded }
    public let kind: Kind
    public init(_ kind: Kind) { self.kind = kind }
    public var errorDescription: String? {
        switch kind {
        case .invalidRequest: "The remote projection request is invalid."
        case .wrongEnvironment: "The projection belongs to a different remote environment."
        case .staleView: "This remote view expired. Refresh it before continuing."
        case .staleCursor: "This remote page changed or expired. Refresh its view."
        case .notFound: "The requested remote item is unavailable."
        case .unavailable: "Remote browsing is unavailable."
        case .limitExceeded: "The remote view exceeds its bounded storage or page limit."
        }
    }
}

public struct RemoteOperationDetail: Codable, Sendable, Equatable {
    public let label: String
    public let value: RemoteProjectionText
    public init(label: String, value: RemoteProjectionText) { self.label = label; self.value = value }
}
public struct RemoteCheckpointBannerSummary: Codable, Sendable, Equatable {
    public let runID: UUID
    public let stage: RunCheckpointStage
    public let attempt: RemoteCheckpointAttemptSummary
    public let title: String
    public let detail: String
    public let providerReleased: Bool
    public let canRetry: Bool
    public let canContinue: Bool
    public init(runID: UUID, stage: RunCheckpointStage, attempt: RemoteCheckpointAttemptSummary, title: String, detail: String,
                providerReleased: Bool, canRetry: Bool, canContinue: Bool) {
        self.runID = runID; self.stage = stage; self.attempt = attempt; self.title = title; self.detail = detail
        self.providerReleased = providerReleased; self.canRetry = canRetry; self.canContinue = canContinue
    }
}
public enum RemoteOperationAction: String, Codable, Sendable, CaseIterable {
    case inspectCreation, acknowledgeCreation, openPullRequest
    case inspectCheckout, acknowledgeCheckout, cancelCheckout, openConversation
    case inspectRestore, acknowledgeRestore
    case retryWorktree, inspectWorktree, cancelWorktree
    case inspectProvider, inspectFiles, acknowledgeFiles, recallPrompt, dismissRecall, keepOriginal
    case inspectMaintenance, clearMaintenance, cancelPi, respondPi, acknowledgeSteering
}
