import CoincideCore
import CryptoKit
import Foundation

struct RemoteComposerScope: Codable, Sendable, Equatable {
    let environmentID: UUID, hostID: UUID, threadID: UUID, projectID: UUID
    let threadCreatedAt: Date, projectCreatedAt: Date?
    let workspacePath: String
    let configuration: Data
    var key: String { Self.digest((try? Self.bytes(self)) ?? Data()) }
    static func bytes<T: Encodable>(_ value: T) throws -> Data { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return try encoder.encode(value) }
    static func fingerprint<T: Encodable>(_ value: T) -> Data { Data(SHA256.hash(data: (try? bytes(value)) ?? Data())) }
    static func digest(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    func sameDraftIdentity(_ other: Self) -> Bool {
        environmentID == other.environmentID && threadID == other.threadID && projectID == other.projectID &&
            threadCreatedAt == other.threadCreatedAt && projectCreatedAt == other.projectCreatedAt && workspacePath.utf8.elementsEqual(other.workspacePath.utf8)
    }
    func matches(_ other: Self) -> Bool { (try? Self.bytes(self)) == (try? Self.bytes(other)) }
}
struct RemoteComposerRecord: Codable, Sendable {
    let scope: RemoteComposerScope
    var draft: ComposerDraftSnapshot
}

/// The local CAS and original-ID result are written together. No host paths
/// enter AttachmentStore; downloaded content is imported as a fresh local ID.
actor RemoteComposerPersistence {
    private struct Receipt: Codable { let digest: String; let applied: Bool }
    private struct Copy: Codable { let original: ChatAttachment; let local: ChatAttachment }
    private struct Document: Codable {
        var version = 1
        var records: [String: RemoteComposerRecord] = [:]
        var receipts: [UUID: Receipt] = [:]
        var copies: [UUID: Copy] = [:]
        var reservedCopyBytes: Int? = nil
    }
    private let manifests: RemotePrivateDocumentStore
    private let root: URL
    private var attachments: AttachmentStore?
    private var document: Document?
    private var previous: Data?
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private func acquire() async { if !busy { busy = true; return }; await withCheckedContinuation { waiters.append($0) } }
    private func release() { if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() } }
    private let maximum = 16 * 1_024 * 1_024
    init(root: URL) { self.root = root; manifests = .init(root: root.appendingPathComponent("Metadata", isDirectory: true)) }
    private func load() async throws -> Document {
        if let document { return document }
        let bytes = try await manifests.load(name: "composer.json", maximum: maximum)
        let value = try bytes.map { try JSONDecoder().decode(Document.self, from: $0) } ?? Document()
        guard value.version == 1, value.records.count <= 256, value.receipts.count <= 4_096, value.copies.count <= 4_096 else { throw RemoteEnvironmentStorageError(.limitExceeded) }
        for (key, record) in value.records {
            let scope = record.scope
            guard key == scope.key, scope.configuration.count == 32, scope.threadCreatedAt.timeIntervalSince1970.isFinite,
                  scope.projectCreatedAt?.timeIntervalSince1970.isFinite != false, scope.workspacePath.hasPrefix("/"), scope.workspacePath.utf8.count <= 16_384,
                  record.draft.threadID == scope.threadID, record.draft.projectID == scope.projectID,
                  record.draft.workspacePath.utf8.elementsEqual(scope.workspacePath.utf8), record.draft.text.utf16.count <= 120_000 else { throw RemoteAttachmentFailure(.integrity) }
            try AttachmentLimits.validate(record.draft.attachments)
        }
        for copy in value.copies.values { try AttachmentLimits.validate([copy.original]); try AttachmentLimits.validate([copy.local]) }
        guard (value.reservedCopyBytes ?? 0) >= 0, (value.reservedCopyBytes ?? 0) <= 512 * 1_024 * 1_024 else { throw RemoteAttachmentFailure(.limitExceeded) }
        document = value; previous = bytes; return value
    }
    private func save(_ value: Document) async throws {
        guard value.records.count <= 256, value.receipts.count <= 4_096, value.copies.count <= 4_096 else { throw RemoteEnvironmentStorageError(.limitExceeded) }
        let bytes = try RemoteComposerScope.bytes(value)
        do { try await manifests.save(data: bytes, name: "composer.json", maximum: maximum, expected: previous) }
        catch { document = nil; previous = nil; throw error }
        document = value; previous = bytes
    }
    func records() async throws -> [RemoteComposerRecord] {
        await acquire(); defer { release() }
        return try await load().records.values.sorted { $0.scope.key < $1.scope.key }
    }
    func record(_ scope: RemoteComposerScope) async throws -> RemoteComposerRecord? {
        await acquire(); defer { release() }; return try await load().records[scope.key]
    }
    func write(_ record: RemoteComposerRecord, expected: ComposerDraftSnapshot?, commandID: UUID? = nil, replacement: ComposerDraftReplacement? = nil) async throws -> ComposerDraftToolsOutcome {
        await acquire(); defer { release() }
        var value = try await load()
        let digest = try replacement.map { RemoteComposerScope.digest(try RemoteComposerScope.bytes($0)) }
        if let commandID, let receipt = value.receipts[commandID] {
            guard receipt.digest == digest else { throw RemoteEnvironmentStorageError(.commandChanged) }
            return receipt.applied ? .applied : .rejected
        }
        if let old = value.records[record.scope.key] {
            guard old.scope.matches(record.scope), expected.map({ $0.matches(old.draft) }) == true else { throw RemoteEnvironmentStorageError(.commandChanged) }
        } else if expected != nil { throw RemoteEnvironmentStorageError(.commandChanged) }
        guard record.draft.text.utf16.count <= 120_000, record.draft.threadID == record.scope.threadID,
              record.draft.projectID == record.scope.projectID, record.draft.workspacePath.utf8.elementsEqual(record.scope.workspacePath.utf8) else { throw RemoteEnvironmentStorageError(.limitExceeded) }
        try AttachmentLimits.validate(record.draft.attachments)
        value.records[record.scope.key] = record
        if let commandID, let digest { value.receipts[commandID] = .init(digest: digest, applied: true) }
        try await save(value); return .applied
    }
    func receipt(_ id: UUID, replacement: ComposerDraftReplacement) async throws -> ComposerDraftToolsOutcome {
        await acquire(); defer { release() }
        let value = try await load()
        let digest = RemoteComposerScope.digest(try RemoteComposerScope.bytes(replacement))
        guard let receipt = value.receipts[id] else { return .rejected }
        guard receipt.digest == digest else { throw RemoteEnvironmentStorageError(.commandChanged) }
        return receipt.applied ? .applied : .rejected
    }
    private func store() throws -> AttachmentStore {
        if let attachments { return attachments }
        let created = try AttachmentStore(root: root.appendingPathComponent("Copies", isDirectory: true)); attachments = created; return created
    }
    func importData(_ data: Data, name: String, original: ChatAttachment? = nil) async throws -> ChatAttachment {
        await acquire(); defer { release() }
        var value = try await load()
        if let original, let copy = value.copies[original.id] {
            guard ComposerDraftSnapshot.sameAttachments([copy.original], [original]) else { throw RemoteAttachmentFailure(.collision) }
            _ = try await store().data(for: copy.local); return original
        }
        let digest = RemoteComposerScope.digest(data)
        let existing = value.copies.values.first { $0.local.digest == digest && $0.local.byteCount == data.count && $0.original.name.utf8.elementsEqual(name.utf8) }
        let local: ChatAttachment
        if let existing { _ = try await store().data(for: existing.local); local = existing.local }
        else {
            var unique: [UUID: Int] = [:]; for copy in value.copies.values { unique[copy.local.id] = copy.local.byteCount }
            let reserved = max(value.reservedCopyBytes ?? 0, unique.values.reduce(0, +))
            guard data.count <= AttachmentLimits.fileBytes, reserved + data.count <= 512 * 1_024 * 1_024 else { throw RemoteAttachmentFailure(.limitExceeded) }
            // Reserve before allocating bytes. Interrupted/ambiguous copy writes
            // remain charged after restart instead of creating uncounted blobs.
            value.reservedCopyBytes = reserved + data.count; try await save(value)
            local = try await store().importData(data, name: name)
        }
        let reference = original ?? local
        guard reference.byteCount == local.byteCount, reference.digest == local.digest else { throw RemoteAttachmentFailure(.integrity) }
        value.copies[reference.id] = .init(original: reference, local: local); try await save(value); return reference
    }
    func url(_ reference: ChatAttachment) async throws -> URL? {
        await acquire(); defer { release() }
        let value = try await load()
        guard let copy = value.copies[reference.id], ComposerDraftSnapshot.sameAttachments([copy.original], [reference]) else { return nil }
        _ = try await store().data(for: copy.local)
        return try await store().url(for: copy.local)
    }
    func data(_ reference: ChatAttachment) async throws -> Data? {
        await acquire(); defer { release() }
        let value = try await load()
        guard let copy = value.copies[reference.id] else { return nil }
        guard ComposerDraftSnapshot.sameAttachments([copy.original], [reference]) else { throw RemoteAttachmentFailure(.collision) }
        return try await store().data(for: copy.local)
    }
}
