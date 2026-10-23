import Foundation

public enum RemoteContextProtocol {
    public static let bindMethod = "remoteEnvironment.context.bind"
    public static let reviewMethod = "remoteEnvironment.context.review"
    public static let readMethod = "remoteEnvironment.context.read"
    public static let discardMethod = "remoteEnvironment.context.discard"
    public static let maximumResultBytes = RemoteProjectionProtocol.maximumResultBytes
    public static func payload<T: Encodable>(_ value: T) throws -> Data { try ContextTransferProtocol.payload(value) }
}
/// No executable, home, authentication binding or native thread identity can be
/// chosen by a remote client. The trusted host captures that provider profile.
public struct RemoteContextDestination: Codable, Sendable, Equatable {
    public let provider: ProviderKind?
    public let model: String?
    public let permission: PermissionMode?
    public let workspacePath: String?
    public init(provider: ProviderKind? = nil, model: String? = nil, permission: PermissionMode? = nil, workspacePath: String? = nil) {
        self.provider = provider; self.model = model; self.permission = permission; self.workspacePath = workspacePath
    }
}
public enum RemoteContextIntent: Codable, Sendable, Equatable {
    case fork(RemoteContextDestination)
    case providerHandoff(RemoteContextDestination)
    case mergeBack(expectedParent: RemoteWorkspaceTarget)
}
public struct RemoteContextReviewRequest: Codable, Sendable, Equatable {
    public let target: RemoteWorkspaceTarget
    public let sourcePoint: ContextTransferSourcePoint
    public let intent: RemoteContextIntent
    public init(target: RemoteWorkspaceTarget, sourcePoint: ContextTransferSourcePoint = .latestStable, intent: RemoteContextIntent) {
        self.target = target; self.sourcePoint = sourcePoint; self.intent = intent
    }
}
public struct RemoteContextReviewSummary: Codable, Sendable, Equatable {
    public let kind: ContextTransferKind
    public let strategy: ContextTransferStrategy
    public let sourcePoint: ContextTransferResolvedPoint
    public let basePoint: ContextTransferResolvedPoint?
    public let targetThreadID: UUID
    public let projectID: UUID
    public let title: RemoteProjectionText
    public let sourceConfiguration: RemoteProjectionContentReference
    public let targetConfiguration: RemoteProjectionContentReference
    public let archiveItemCount: Int
    public let archiveByteCount: Int
    public let previewSelection: RemoteProjectionContentReference?
    public let warnings: [RemoteProjectionText]
    public init(kind: ContextTransferKind, strategy: ContextTransferStrategy, sourcePoint: ContextTransferResolvedPoint,
                basePoint: ContextTransferResolvedPoint?, targetThreadID: UUID, projectID: UUID, title: RemoteProjectionText,
                sourceConfiguration: RemoteProjectionContentReference, targetConfiguration: RemoteProjectionContentReference,
                archiveItemCount: Int, archiveByteCount: Int, previewSelection: RemoteProjectionContentReference?, warnings: [RemoteProjectionText]) {
        self.kind = kind; self.strategy = strategy; self.sourcePoint = sourcePoint; self.basePoint = basePoint
        self.targetThreadID = targetThreadID; self.projectID = projectID; self.title = title
        self.sourceConfiguration = sourceConfiguration; self.targetConfiguration = targetConfiguration
        self.archiveItemCount = archiveItemCount; self.archiveByteCount = archiveByteCount; self.previewSelection = previewSelection; self.warnings = warnings
    }
}
public struct RemoteContextReview: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let digest: String
    public let target: RemoteWorkspaceTarget
    public let binding: RemoteHistoryBinding
    public let value: RemoteContextReviewSummary
    public init(id: UUID, digest: String, target: RemoteWorkspaceTarget, binding: RemoteHistoryBinding, value: RemoteContextReviewSummary) {
        self.id = id; self.digest = digest; self.target = target; self.binding = binding; self.value = value
    }
}
public enum RemoteContextAction: Codable, Sendable, Equatable {
    case begin(reviewID: UUID, digest: String, title: String?)
    case useFreshContext(deliveryID: UUID, expectedTransferIDs: [UUID])
    public var requiresBoundRoot: Bool { if case .begin = self { true } else { false } }
}
public struct RemoteContextTransferSummary: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let commandID: UUID
    public let sourceThreadID: UUID
    public let targetThreadID: UUID
    public let sourcePoint: ContextTransferResolvedPoint
    public let basePoint: ContextTransferResolvedPoint?
    public let kind: ContextTransferKind
    public let strategy: ContextTransferStrategy
    public let status: ContextTransferStatus
    public let targetRunID: UUID?
    public let updatedAt: Date
    public let error: RemoteProjectionText?
    public let deliveryID: UUID?
    public let deliveryStatus: ContextTransferDeliveryStatus?
    public let selection: RemoteProjectionContentReference?
    public let archivedItemCount: Int
    public init(id: UUID, commandID: UUID, sourceThreadID: UUID, targetThreadID: UUID, sourcePoint: ContextTransferResolvedPoint,
                basePoint: ContextTransferResolvedPoint?, kind: ContextTransferKind, strategy: ContextTransferStrategy,
                status: ContextTransferStatus, targetRunID: UUID?, updatedAt: Date, error: RemoteProjectionText?,
                deliveryID: UUID?, deliveryStatus: ContextTransferDeliveryStatus?, selection: RemoteProjectionContentReference?, archivedItemCount: Int) {
        self.id = id; self.commandID = commandID; self.sourceThreadID = sourceThreadID; self.targetThreadID = targetThreadID
        self.sourcePoint = sourcePoint; self.basePoint = basePoint; self.kind = kind; self.strategy = strategy; self.status = status
        self.targetRunID = targetRunID; self.updatedAt = updatedAt; self.error = error; self.deliveryID = deliveryID
        self.deliveryStatus = deliveryStatus; self.selection = selection; self.archivedItemCount = archivedItemCount
    }
}
public struct RemoteContextDeliveryControl: Codable, Sendable, Equatable {
    public let deliveryID: UUID
    public let transferIDs: [UUID]
    public let canUseFreshContext: Bool
    public init(deliveryID: UUID, transferIDs: [UUID], canUseFreshContext: Bool) {
        self.deliveryID = deliveryID; self.transferIDs = transferIDs; self.canUseFreshContext = canUseFreshContext
    }
}
public struct RemoteContextInventory: Codable, Sendable, Equatable {
    public let binding: RemoteHistoryBinding
    public let lineage: ContextTransferLineage?
    public let pendingCount: Int
    public let uncertain: RemoteContextDeliveryControl?
    public let transfers: RemoteHistoryPage<RemoteContextTransferSummary>
    public init(binding: RemoteHistoryBinding, lineage: ContextTransferLineage?, pendingCount: Int,
                uncertain: RemoteContextDeliveryControl?, transfers: RemoteHistoryPage<RemoteContextTransferSummary>) {
        self.binding = binding; self.lineage = lineage; self.pendingCount = pendingCount; self.uncertain = uncertain; self.transfers = transfers
    }
}
public struct RemoteContextMessage: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let runID: UUID?
    public let role: String
    public let kind: String
    public let text: RemoteProjectionText
    public init(id: String, runID: UUID?, role: String, kind: String, text: RemoteProjectionText) {
        self.id = id; self.runID = runID; self.role = role; self.kind = kind; self.text = text
    }
}
public enum RemoteContextQuery: Codable, Sendable, Equatable {
    case inventory
    case transfers(binding: RemoteHistoryBinding, cursor: UUID?)
    case transfer(id: UUID)
    case messages(binding: RemoteHistoryBinding, cursor: UUID?)
    case content(binding: RemoteHistoryBinding, reference: RemoteProjectionContentReference, offset: Int, cursor: UUID?)
    case release(binding: RemoteHistoryBinding)
}
public struct RemoteContextReadRequest: Codable, Sendable, Equatable {
    public let target: RemoteWorkspaceTarget
    public let query: RemoteContextQuery
    public init(target: RemoteWorkspaceTarget, query: RemoteContextQuery) { self.target = target; self.query = query }
}
public enum RemoteContextValue: Codable, Sendable, Equatable {
    case inventory(RemoteContextInventory)
    case transfers(RemoteHistoryPage<RemoteContextTransferSummary>)
    case transfer(binding: RemoteHistoryBinding, summary: RemoteContextTransferSummary)
    case messages(RemoteHistoryPage<RemoteContextMessage>)
    case content(RemoteHistoryContent)
    case released(Bool)
}
public struct RemoteContextReadResult: Codable, Sendable, Equatable {
    public let target: RemoteWorkspaceTarget
    public let value: RemoteContextValue
    public init(target: RemoteWorkspaceTarget, value: RemoteContextValue) { self.target = target; self.value = value }
}
public struct RemoteContextDiscardRequest: Codable, Sendable, Equatable {
    public let target: RemoteWorkspaceTarget
    public let reviewID: UUID
    public let digest: String
    public init(target: RemoteWorkspaceTarget, reviewID: UUID, digest: String) { self.target = target; self.reviewID = reviewID; self.digest = digest }
}
public struct RemoteContextDiscardResult: Codable, Sendable, Equatable {
    public let request: RemoteContextDiscardRequest
    public let discarded: Bool
    public init(request: RemoteContextDiscardRequest, discarded: Bool) { self.request = request; self.discarded = discarded }
}
public struct RemoteContextFailure: Error, Codable, Sendable, Equatable, LocalizedError {
    public enum Kind: String, Codable, Sendable { case invalidRequest, invalidTarget, staleReview, staleCursor, unavailable, busy, limitExceeded, operationFailed }
    public let kind: Kind
    public init(_ kind: Kind) { self.kind = kind }
    public var errorDescription: String? {
        switch kind {
        case .invalidRequest: "The remote context request is invalid."
        case .invalidTarget: "The remote source or destination changed. Refresh before continuing."
        case .staleReview: "This context review changed or expired. Review its exact source and destination again."
        case .staleCursor: "This context display page expired. Refresh its saved view."
        case .unavailable: "Remote context transfers are unavailable."
        case .busy: "Another action owns this source or destination."
        case .limitExceeded: "This context request exceeded its explicit limit."
        case .operationFailed: "The context action could not be confirmed. Inspect its saved outcome before continuing."
        }
    }
}
