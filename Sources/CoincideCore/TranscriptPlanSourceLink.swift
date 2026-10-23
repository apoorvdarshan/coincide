import CryptoKit
import Foundation

/// Display provenance for a fresh implementation conversation. This is not
/// native history/fork proof and never imports the source transcript/context.
public struct TranscriptPlanSourceLink: Codable, Sendable, Equatable {
    private final class Storage: Codable, Sendable {
        let threadID: UUID
        let threadCreatedAt: Date
        let messageID: String
        let messageDigest: String
        let runReference: TranscriptRunReference?
        init(thread: CodingThread, message: ChatMessage) throws {
            threadID = thread.id; threadCreatedAt = thread.createdAt; messageID = message.id
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            messageDigest = SHA256.hash(data: try encoder.encode(message)).map { String(format: "%02x", $0) }.joined()
            runReference = message.runReference
        }
    }
    private let storage: Storage
    public var threadID: UUID { storage.threadID }
    public var threadCreatedAt: Date { storage.threadCreatedAt }
    public var messageID: String { storage.messageID }
    public var messageDigest: String { storage.messageDigest }
    public var runReference: TranscriptRunReference? { storage.runReference }
    init(thread: CodingThread, message: ChatMessage) throws { storage = try .init(thread: thread, message: message) }
    public init(from decoder: any Decoder) throws { storage = try Storage(from: decoder) }
    public func encode(to encoder: any Encoder) throws { try storage.encode(to: encoder) }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.threadID == rhs.threadID && lhs.threadCreatedAt == rhs.threadCreatedAt &&
        lhs.messageID.utf8.elementsEqual(rhs.messageID.utf8) && lhs.messageDigest == rhs.messageDigest && lhs.runReference == rhs.runReference
    }
}

public struct TranscriptPlanDestination: Codable, Sendable, Equatable {
    public let threadID: UUID
    public init(threadID: UUID = UUID()) { self.threadID = threadID }
}
