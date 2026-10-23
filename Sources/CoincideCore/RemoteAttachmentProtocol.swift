import Foundation

public enum RemoteAttachmentProtocol {
    public static let maximumChunkBytes = 262_144
    public static let beginMethod = "remoteEnvironment.attachment.begin"
    public static let statusMethod = "remoteEnvironment.attachment.status"
    public static let appendMethod = "remoteEnvironment.attachment.append"
    public static let finalizeMethod = "remoteEnvironment.attachment.finalize"
    public static let cancelMethod = "remoteEnvironment.attachment.cancel"
    public static let downloadMethod = "remoteEnvironment.attachment.download"
    static func payload<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return try encoder.encode(value)
    }
}
public struct RemoteAttachmentTarget: Codable, Sendable, Equatable {
    public let environmentID: UUID, projectID: UUID, threadID: UUID
    public init(environmentID: UUID, projectID: UUID, threadID: UUID) {
        self.environmentID = environmentID; self.projectID = projectID; self.threadID = threadID
    }
}
public struct RemoteAttachmentUploadRequest: Codable, Sendable, Equatable {
    public let id: UUID
    public let target: RemoteAttachmentTarget
    public let name: String
    public let byteCount: Int
    public let digest: String
    public init(id: UUID = UUID(), target: RemoteAttachmentTarget, name: String, byteCount: Int, digest: String) {
        self.id = id; self.target = target; self.name = name; self.byteCount = byteCount; self.digest = digest
    }
}
public struct RemoteAttachmentChunkRequest: Codable, Sendable, Equatable {
    public let upload: RemoteAttachmentUploadRequest
    public let index: Int
    public let data: Data
    public let digest: String
    public init(upload: RemoteAttachmentUploadRequest, index: Int, data: Data, digest: String) {
        self.upload = upload; self.index = index; self.data = data; self.digest = digest
    }
}
public struct RemoteAttachmentUpload: Codable, Sendable, Equatable, Identifiable {
    public enum State: String, Codable, Sendable { case receiving, finalizing, ready, claimed, cancelled, failed, uncertain }
    public let request: RemoteAttachmentUploadRequest
    public var state: State
    public var receivedChunks: [Int]
    public var attachment: ChatAttachment?
    public var failure: RemoteAttachmentFailure?
    public var id: UUID { request.id }
    public init(request: RemoteAttachmentUploadRequest, state: State, receivedChunks: [Int] = [], attachment: ChatAttachment? = nil, failure: RemoteAttachmentFailure? = nil) {
        self.request = request; self.state = state; self.receivedChunks = receivedChunks; self.attachment = attachment; self.failure = failure
    }
}
public struct RemoteAttachmentDownloadRequest: Codable, Sendable, Equatable {
    public let target: RemoteAttachmentTarget
    public let attachmentID: UUID
    public let offset: Int, maxBytes: Int
    public init(target: RemoteAttachmentTarget, attachmentID: UUID, offset: Int, maxBytes: Int = RemoteAttachmentProtocol.maximumChunkBytes) {
        self.target = target; self.attachmentID = attachmentID; self.offset = offset; self.maxBytes = maxBytes
    }
}
public struct RemoteAttachmentDownloadResult: Codable, Sendable, Equatable {
    public let target: RemoteAttachmentTarget
    public let attachment: ChatAttachment
    public let offset: Int
    public let data: Data
    public let eof: Bool
    public init(target: RemoteAttachmentTarget, attachment: ChatAttachment, offset: Int, data: Data, eof: Bool) {
        self.target = target; self.attachment = attachment; self.offset = offset; self.data = data; self.eof = eof
    }
}
public struct RemoteAttachmentFailure: Error, Codable, Sendable, Equatable, LocalizedError {
    public enum Kind: String, Codable, Sendable { case invalidRequest, invalidTarget, notFound, collision, integrity, limitExceeded, busy, unavailable, cancelled, uncertain }
    public let kind: Kind
    public init(_ kind: Kind) { self.kind = kind }
    public var errorDescription: String? {
        switch kind {
        case .invalidRequest: "The remote attachment request is invalid."
        case .invalidTarget: "The remote attachment belongs to a different or unavailable conversation."
        case .notFound: "The remote attachment upload was not found."
        case .collision: "This attachment identity is already bound to different exact content or metadata."
        case .integrity: "The remote attachment bytes are incomplete or changed."
        case .limitExceeded: "The remote attachment storage or transfer limit was reached."
        case .busy: "The remote attachment is still being processed."
        case .unavailable: "Remote attachments are unavailable."
        case .cancelled: "The remote attachment upload was cancelled."
        case .uncertain: "Attachment publication is unconfirmed. Check its status before continuing."
        }
    }
}
struct RemoteAttachmentRecord: Codable, Sendable, Equatable {
    let upload: RemoteAttachmentUploadRequest
    let attachment: ChatAttachment
    var claimedBy: UUID?
    var cancelled: Bool
}
struct RemoteAttachmentSubmission: Codable, Sendable {
    let target: RemoteAttachmentTarget
    let incarnation: UUID
    let records: [RemoteAttachmentRecord]
}
