import CoincideCore
import Foundation

struct ComposerStashEntry: Codable, Sendable, Identifiable {
    let id: UUID
    let createdAt: Date
    let draft: ComposerDraftSnapshot
    var snippet: String {
        let value = draft.text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return value.isEmpty ? "\(draft.attachments.count) attachment(s)" : String(value.prefix(90))
    }
}

enum ComposerPendingPurpose: Codable, Sendable, Equatable {
    case stash(UUID), restore(UUID), attachment(UUID)
}
struct ComposerPendingMutation: Codable, Sendable, Identifiable {
    let id: UUID
    let purpose: ComposerPendingPurpose
    let replacement: ComposerDraftReplacement
}
struct ComposerDraftToolsDocument: Codable, Sendable {
    var version = 1
    var entries: [ComposerStashEntry] = []
    var pending: [ComposerPendingMutation] = []
}

/// Reference-only manifest; attachment bytes remain in the engine's immutable
/// private AttachmentStore. Reload never replays a draft mutation or import.
actor ComposerDraftPersistence {
    private let files: RemotePrivateDocumentStore
    private var bytes: Data?
    private var loaded = false
    private let maximum = 16 * 1_024 * 1_024
    init(root: URL) { files = .init(root: root) }
    func load() async throws -> ComposerDraftToolsDocument {
        let data = try await files.load(name: "prompt-stash.json", maximum: maximum)
        let value: ComposerDraftToolsDocument
        do {
            value = try data.map { try JSONDecoder().decode(ComposerDraftToolsDocument.self, from: $0) } ?? .init()
            try validate(value)
        } catch { throw CoincideError("The saved prompt stash could not be read. Its existing file was preserved.") }
        bytes = data; loaded = true; return value
    }
    func save(_ value: ComposerDraftToolsDocument) async throws {
        guard loaded else { throw CoincideError("Load the prompt stash before changing it.") }
        try validate(value)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        guard data.count <= maximum else { throw CoincideError("The prompt stash is full. Delete an older prompt before trying again.") }
        try await files.save(data: data, name: "prompt-stash.json", maximum: maximum, expected: bytes)
        bytes = data
    }
    private func validate(_ value: ComposerDraftToolsDocument) throws {
        guard value.version == 1, value.entries.count <= 20, value.pending.count <= 100,
              Set(value.entries.map(\.id)).count == value.entries.count, Set(value.pending.map(\.id)).count == value.pending.count else {
            throw CoincideError("The prompt stash has invalid or oversized entries.")
        }
        for entry in value.entries { try validate(entry.draft) }
        for operation in value.pending {
            try validate(operation.replacement.expected)
            guard operation.replacement.text.utf8.count <= 8 * 1_024 * 1_024 else { throw CoincideError("This prompt is too large to keep in the stash.") }
            try AttachmentLimits.validate(operation.replacement.attachments)
        }
    }
    private func validate(_ draft: ComposerDraftSnapshot) throws {
        guard !draft.workspacePath.isEmpty, draft.workspacePath.utf8.count <= 32_768, !draft.workspacePath.contains("\0"),
              draft.text.utf8.count <= 8 * 1_024 * 1_024 else { throw CoincideError("This prompt is too large to keep in the stash.") }
        try AttachmentLimits.validate(draft.attachments)
    }
}
