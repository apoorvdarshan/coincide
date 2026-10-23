import Foundation

public enum RemoteSteeringProtocol {
    public static let readMethod = "remoteEnvironment.steering.read"
    public static let pageMethod = "remoteEnvironment.steering.page"
    public static let contentMethod = "remoteEnvironment.steering.content"
    public static let releaseMethod = "remoteEnvironment.steering.release"
    public static let maximumBytes = RemoteProjectionProtocol.maximumResultBytes
    public static func digest<T: Encodable>(_ value: T) throws -> String { RemoteProjectionProtocol.digest(try RemoteProjectionProtocol.payload(value)) }
    static func queueRevision(_ queue: [QueuedTurn]) throws -> String {
        struct Row: Encodable { let id: UUID; let digest: String }
        return try digest(queue.map { Row(id: $0.id, digest: try digest($0)) })
    }
    public static func operationID(_ commandID: UUID) -> UUID { TaskOrchestration.derivedID(commandID, "remote-steering-operation") }
}
public struct RemoteSteeringBinding: Codable, Sendable, Equatable {
    public let environmentID: UUID, hostID: UUID, viewID: UUID, threadID: UUID
    public let digest: String
}
public struct RemoteSteeringCapture: Codable, Sendable, Equatable {
    public let binding: RemoteSteeringBinding
    public let threadCreatedAt: Date, projectCreatedAt: Date?
    public let runID: UUID?, runtimeID: UUID?
    public let activeConfigurationDigest: String?
    public let queueRevision: String?
    public init(binding: RemoteSteeringBinding, threadCreatedAt: Date, projectCreatedAt: Date?, runID: UUID?, runtimeID: UUID?, activeConfigurationDigest: String?, queueRevision: String? = nil) {
        self.binding = binding; self.threadCreatedAt = threadCreatedAt; self.projectCreatedAt = projectCreatedAt; self.runID = runID; self.runtimeID = runtimeID; self.activeConfigurationDigest = activeConfigurationDigest; self.queueRevision = queueRevision
    }
}
public struct RemoteSteeringContentReference: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable { case text, attachments }
    public let id: UUID
    public let kind: Kind
    public let totalBytes: Int
    public let digest: String
}
public struct RemoteQueuedInputSummary: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let createdAt: Date
    public let digest: String
    public let preview: String
    public let text: RemoteSteeringContentReference
    public let attachments: RemoteSteeringContentReference
    public let attachmentCount: Int
    public let provider: ProviderKind
    public let model: String
    public let permission: PermissionMode
    public let canSteer: Bool, canEdit: Bool
    public let reason: String?
}
public struct RemoteSteeringOperationSummary: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID, runID: UUID
    public let digest: String
    public let phase: PromptSteeringPhase
    public let preview: String
    public let text: RemoteSteeringContentReference
    public let attachments: RemoteSteeringContentReference
    public let error: String?
    public let acknowledged: Bool
}
public enum RemoteSteeringPageKind: String, Codable, Sendable { case queue, operations }
public struct RemoteSteeringPage: Codable, Sendable, Equatable {
    public let capture: RemoteSteeringCapture
    public let kind: RemoteSteeringPageKind
    public let operations: [RemoteSteeringOperationSummary]
    public let offset: Int, totalCount: Int
    public let items: [RemoteQueuedInputSummary]
    public let nextCursor: UUID?
    public let complete: Bool
}
public struct RemoteSteeringReadRequest: Codable, Sendable { public let target: RemoteWorkspaceTarget; public init(target: RemoteWorkspaceTarget) { self.target = target } }
public struct RemoteSteeringReadResult: Codable, Sendable {
    public let target: RemoteWorkspaceTarget
    public let sequence: Int64
    public let canSteer: Bool, interruptsTools: Bool
    public let reason: String?
    public let page: RemoteSteeringPage
    public let operationPage: RemoteSteeringPage
    public let activeModel: String?
    public let activePermission: PermissionMode?
    public let operationCount: Int
}
public struct RemoteSteeringPageRequest: Codable, Sendable {
    public let target: RemoteWorkspaceTarget; public let binding: RemoteSteeringBinding; public let cursor: UUID; public let kind: RemoteSteeringPageKind
    public init(target: RemoteWorkspaceTarget, binding: RemoteSteeringBinding, cursor: UUID, kind: RemoteSteeringPageKind) { self.target = target; self.binding = binding; self.cursor = cursor; self.kind = kind }
}
public struct RemoteSteeringContentRequest: Codable, Sendable {
    public let target: RemoteWorkspaceTarget
    public let binding: RemoteSteeringBinding
    public let reference: RemoteSteeringContentReference
    public let offset: Int
    public init(target: RemoteWorkspaceTarget, binding: RemoteSteeringBinding, reference: RemoteSteeringContentReference, offset: Int) {
        self.target = target; self.binding = binding; self.reference = reference; self.offset = offset
    }
}
public struct RemoteSteeringContentResult: Codable, Sendable {
    public let binding: RemoteSteeringBinding
    public let reference: RemoteSteeringContentReference
    public let offset: Int
    public let data: Data
    public let complete: Bool
}
public struct RemoteSteeringReleaseRequest: Codable, Sendable { public let target: RemoteWorkspaceTarget; public let binding: RemoteSteeringBinding; public init(target: RemoteWorkspaceTarget, binding: RemoteSteeringBinding) { self.target = target; self.binding = binding } }
public struct RemoteSteeringReleaseResult: Codable, Sendable { public let binding: RemoteSteeringBinding; public let released: Bool }
public indirect enum RemoteSteeringAction: Codable, Sendable, Equatable {
    case steerComposer(capture: RemoteSteeringCapture, input: RemoteComposerSubmission)
    case steerQueued(capture: RemoteSteeringCapture, queuedID: UUID, digest: String)
    case editQueued(capture: RemoteSteeringCapture, queuedID: UUID, digest: String, text: String, selectedAttachmentIDs: [UUID], uploadedAttachmentIDs: [UUID], orderedAttachmentIDs: [UUID])
    case removeQueued(capture: RemoteSteeringCapture, queuedID: UUID, digest: String)
    case moveQueued(capture: RemoteSteeringCapture, queuedID: UUID, beforeID: UUID?, revision: String)
    case acknowledge(capture: RemoteSteeringCapture, operationID: UUID, digest: String)
    public var capture: RemoteSteeringCapture { switch self { case .steerComposer(let v, _), .steerQueued(let v, _, _), .editQueued(let v, _, _, _, _, _, _), .removeQueued(let v, _, _), .moveQueued(let v, _, _, _), .acknowledge(let v, _, _): v } }
    var uploadedIDs: [UUID] { switch self { case .steerComposer(_, let input): input.uploadedAttachmentIDs; case .editQueued(_, _, _, _, _, let ids, _): ids; default: [] } }
    var requiresRoot: Bool { switch self { case .acknowledge, .removeQueued, .moveQueued: false; default: true } }
}

/// All native configuration, input and target proof remains host-only.
struct RemoteSteeringPreparation: Codable, Sendable {
    private struct Payload: Codable, Sendable {
        let target: RemoteWorkspaceTarget, capture: RemoteSteeringCapture
        let incarnation: UUID
        let action: RemoteSteeringAction
        let operation: PromptSteeringOperation?
        let records: [RemoteAttachmentRecord]
        let queuedEdit: QueuedInputReplacement?
        let queueOrder: [UUID]?
    }
    private let storage: [Payload]
    var target: RemoteWorkspaceTarget { storage[0].target }
    var capture: RemoteSteeringCapture { storage[0].capture }
    var incarnation: UUID { storage[0].incarnation }
    var action: RemoteSteeringAction { storage[0].action }
    var operation: PromptSteeringOperation? { storage[0].operation }
    var records: [RemoteAttachmentRecord] { storage[0].records }
    var queuedEdit: QueuedInputReplacement? { storage[0].queuedEdit }
    var queueOrder: [UUID]? { storage[0].queueOrder }
    init(target: RemoteWorkspaceTarget, capture: RemoteSteeringCapture, incarnation: UUID, action: RemoteSteeringAction,
         operation: PromptSteeringOperation? = nil, records: [RemoteAttachmentRecord] = [], queuedEdit: QueuedInputReplacement? = nil, queueOrder: [UUID]? = nil) {
        storage = [.init(target: target, capture: capture, incarnation: incarnation, action: action, operation: operation, records: records, queuedEdit: queuedEdit, queueOrder: queueOrder)]
    }
    init(from decoder: any Decoder) throws { storage = [try Payload(from: decoder)] }
    func encode(to encoder: any Encoder) throws { try storage[0].encode(to: encoder) }
}
