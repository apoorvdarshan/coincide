import Foundation

/// In-place edit of one captured queued input. Does not read or modify composer
/// text, attachment selection, captured run settings, or context reservations.
public struct QueuedInputReplacement: Codable, Sendable {
    private struct Payload: Codable, Sendable {
        let threadID: UUID, projectID: UUID, queuedID: UUID
        let threadCreatedAt: Date
        let workspacePath: String, digest: String, text: String
        let configuration: ProviderConfiguration
        let attachments: [ChatAttachment]
    }
    private let storage: [Payload]
    public var threadID: UUID { storage[0].threadID }
    public var queuedID: UUID { storage[0].queuedID }
    public var digest: String { storage[0].digest }
    public var text: String { storage[0].text }
    public var attachments: [ChatAttachment] { storage[0].attachments }
    public init(thread: CodingThread, queued: QueuedTurn, text: String, attachments: [ChatAttachment]) {
        storage = [.init(threadID: thread.id, projectID: thread.projectID, queuedID: queued.id, threadCreatedAt: thread.createdAt,
            workspacePath: thread.workspacePath, digest: (try? RemoteSteeringProtocol.digest(queued)) ?? "", text: text,
            configuration: ProviderConfiguration(thread: thread), attachments: attachments)]
    }
    func matches(_ thread: CodingThread) -> Bool {
        thread.id == threadID && thread.projectID == storage[0].projectID && thread.createdAt == storage[0].threadCreatedAt &&
            thread.workspacePath.utf8.elementsEqual(storage[0].workspacePath.utf8) && RemoteLifecycleProtocol.same(ProviderConfiguration(thread: thread), storage[0].configuration)
    }
    public init(from decoder: any Decoder) throws { storage = [try Payload(from: decoder)] }
    public func encode(to encoder: any Encoder) throws { try storage[0].encode(to: encoder) }
}

internal extension QueuedInputReplacement {
    @inline(never) static func sameContent(_ lhs: [QueuedTurn], _ rhs: [QueuedTurn]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for (a, b) in zip(lhs, rhs) {
            guard a.id == b.id, a.text.utf8.elementsEqual(b.text.utf8),
                  ComposerDraftSnapshot.sameAttachments(a.attachments ?? [], b.attachments ?? []) else { return false }
        }
        return true
    }
}
