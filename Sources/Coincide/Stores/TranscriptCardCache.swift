import CoincideCore
import CryptoKit
import Foundation

/// Immutable original transcript ownership, including raw path bytes. Remote
/// consumers add their environment/host identity rather than borrowing local scope.
struct TranscriptCardScope: Hashable, Sendable {
    let threadID: UUID
    let createdAt: Date
    let projectID: UUID
    let workspacePath: Data
    let runID: UUID?
    let environmentID: UUID?
    let hostID: UUID?

    init(threadID: UUID, createdAt: Date, projectID: UUID, workspacePath: String, runID: UUID? = nil,
         environmentID: UUID? = nil, hostID: UUID? = nil) {
        self.threadID = threadID; self.createdAt = createdAt; self.projectID = projectID
        self.workspacePath = Data(workspacePath.utf8); self.runID = runID
        self.environmentID = environmentID; self.hostID = hostID
    }
    init(thread: CodingThread, runID: UUID? = nil) {
        self.init(threadID: thread.id, createdAt: thread.createdAt, projectID: thread.projectID,
                  workspacePath: thread.workspacePath, runID: runID)
    }
}

/// A content revision includes every stored message field. Equal lengths, JSON
/// key counts and Swift's canonically equivalent String equality are not revisions.
@MainActor final class TranscriptCardCache {
    static let maximumEntries = 4_096
    static let maximumBytes = 32 * 1_024 * 1_024
    private struct Key: Hashable { let scope: TranscriptCardScope; let id: Data; let context: TranscriptToolContext; let contextPath: Data? }
    private struct Entry { let digest: Data; let card: TranscriptToolCard; let cost: Int }
    private struct Revision: Encodable {
        let message: ChatMessage
        let result: ChatMessage?
        let rawText: Data
        let rawResultText: Data?
    }
    private var values: [Key: Entry] = [:]
    private(set) var retainedBytes = 0
    var count: Int { values.count }

    func card(_ message: ChatMessage, _ result: ChatMessage?, _ context: TranscriptToolContext,
              scope: TranscriptCardScope) -> TranscriptToolCard {
        guard message.text.utf8.count <= Self.maximumBytes / 4,
              (result?.text.utf8.count ?? 0) <= Self.maximumBytes / 4 else {
            return TranscriptToolPresentation.card(for: message, result: result, context: context)
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard let bytes = try? encoder.encode(Revision(message: message, result: result,
            rawText: Data(message.text.utf8), rawResultText: result.map { Data($0.text.utf8) })) else {
            return TranscriptToolPresentation.card(for: message, result: result, context: context)
        }
        let digest = Data(SHA256.hash(data: bytes))
        let key = Key(scope: scope, id: Data(message.id.utf8), context: context, contextPath: context.workspacePath.map { Data($0.utf8) })
        if let cached = values[key], cached.digest == digest { return cached.card }
        if let old = values.removeValue(forKey: key) { retainedBytes -= old.cost }
        let card = TranscriptToolPresentation.card(for: message, result: result, context: context)
        // Account conservatively for both original payload and derived card strings.
        guard bytes.count <= Self.maximumBytes / 2 else { return card }
        let cost = bytes.count * 2 + scope.workspacePath.count + key.id.count + digest.count
        guard cost <= Self.maximumBytes else { return card }
        if values.count >= Self.maximumEntries || retainedBytes > Self.maximumBytes - cost {
            values.removeAll(keepingCapacity: true); retainedBytes = 0
        }
        values[key] = .init(digest: digest, card: card, cost: cost); retainedBytes += cost
        return card
    }
}
