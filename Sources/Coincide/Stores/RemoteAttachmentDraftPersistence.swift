import CoincideCore
import Foundation

struct RemoteAttachmentDraftRecord: Codable, Sendable {
    let target: RemoteAttachmentTarget
    var entries: [RemoteAttachmentEntryRecord]
}

struct RemoteAttachmentEntryRecord: Codable, Sendable {
    let local: ChatAttachment
    var upload: RemoteAttachmentUploadRequest?
    var remote: RemoteAttachmentUpload?
}

/// Only local immutable copies and opaque remote identities are retained here.
/// No source URL, remote workspace path, or transfer payload enters a manifest.
actor RemoteAttachmentDraftPersistence {
    private struct Document: Codable { let version: Int; let environmentID: UUID; let drafts: [RemoteAttachmentDraftRecord] }
    private struct Cached { var bytes: Data?; var drafts: [RemoteAttachmentDraftRecord] }
    private let root: URL
    private let manifests: RemotePrivateDocumentStore
    private var copies: AttachmentStore?
    private var cached: [UUID: Cached] = [:]
    private let maximum = 16 * 1_024 * 1_024

    init(root: URL) { self.root = root; manifests = .init(root: root.appendingPathComponent("Manifests", isDirectory: true)) }
    func load(environmentID: UUID) async throws -> [RemoteAttachmentDraftRecord] {
        if let value = cached[environmentID] { return value.drafts }
        let bytes = try await manifests.load(name: name(environmentID), maximum: maximum)
        let drafts: [RemoteAttachmentDraftRecord]
        if let bytes {
            do {
                let value = try JSONDecoder().decode(Document.self, from: bytes)
                guard value.version == 1, value.environmentID == environmentID else { throw RemoteAttachmentFailure(.integrity) }
                try validate(value.drafts, environmentID: environmentID); drafts = value.drafts
            } catch { throw RemoteAttachmentFailure(.integrity) }
        } else { drafts = [] }
        cached[environmentID] = .init(bytes: bytes, drafts: drafts)
        return drafts
    }
    func save(environmentID: UUID, drafts: [RemoteAttachmentDraftRecord]) async throws {
        _ = try await load(environmentID: environmentID)
        try validate(drafts, environmentID: environmentID)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(Document(version: 1, environmentID: environmentID, drafts: drafts))
        let previous = cached[environmentID]?.bytes
        try await manifests.save(data: bytes, name: name(environmentID), maximum: maximum, expected: previous)
        cached[environmentID] = .init(bytes: bytes, drafts: drafts)
    }
    func importFile(_ url: URL) async throws -> ChatAttachment { try await attachmentStore().importFile(url) }
    func importData(_ bytes: Data, name: String) async throws -> ChatAttachment { try await attachmentStore().importData(bytes, name: name) }
    func data(_ attachment: ChatAttachment) async throws -> Data { try await attachmentStore().data(for: attachment) }
    func url(_ attachment: ChatAttachment) async throws -> URL { try await attachmentStore().url(for: attachment) }
    private func attachmentStore() throws -> AttachmentStore {
        if let copies { return copies }
        let value = try AttachmentStore(root: root.appendingPathComponent("Copies", isDirectory: true)); copies = value; return value
    }
    private func name(_ environmentID: UUID) -> String { "attachments-" + environmentID.uuidString.lowercased() + ".json" }
    private func validate(_ drafts: [RemoteAttachmentDraftRecord], environmentID: UUID) throws {
        guard drafts.count <= 256, Set(drafts.map { $0.target.threadID }).count == drafts.count else { throw RemoteAttachmentFailure(.limitExceeded) }
        for draft in drafts {
            guard draft.target.environmentID == environmentID else { throw RemoteAttachmentFailure(.invalidTarget) }
            try AttachmentLimits.validate(draft.entries.map(\.local))
            for entry in draft.entries {
                guard entry.remote == nil || entry.upload != nil else { throw RemoteAttachmentFailure(.integrity) }
                if let upload = entry.upload {
                    guard upload.target == draft.target, upload.byteCount == entry.local.byteCount,
                          upload.digest.utf8.elementsEqual(entry.local.digest.utf8), upload.name.utf8.elementsEqual(entry.local.name.utf8),
                          entry.remote == nil || same(entry.remote?.request, upload) else { throw RemoteAttachmentFailure(.integrity) }
                }
                if let remote = entry.remote, let upload = entry.upload {
                    let count = (upload.byteCount + RemoteAttachmentProtocol.maximumChunkBytes - 1) / RemoteAttachmentProtocol.maximumChunkBytes
                    guard remote.receivedChunks.count <= count, Set(remote.receivedChunks).count == remote.receivedChunks.count,
                          remote.receivedChunks.allSatisfy({ $0 >= 0 && $0 < count }),
                          [.ready, .claimed].contains(remote.state) == (remote.attachment != nil) else { throw RemoteAttachmentFailure(.integrity) }
                    if let reference = remote.attachment { try AttachmentLimits.validate([reference]) }
                }
            }
        }
    }
    private func same(_ lhs: RemoteAttachmentUploadRequest?, _ rhs: RemoteAttachmentUploadRequest) -> Bool {
        guard let lhs else { return false }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(lhs)) == (try? encoder.encode(rhs))
    }
}
