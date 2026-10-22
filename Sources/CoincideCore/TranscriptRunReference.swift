import Foundation

/// Local observation provenance, separate from provider-native turn identifiers.
/// The source thread remains explicit when messages are inherited by a future fork.
public struct TranscriptRunReference: Codable, Sendable, Equatable, Hashable {
    public let threadID: UUID
    public let runID: UUID
    public init(threadID: UUID, runID: UUID) { self.threadID = threadID; self.runID = runID }
}

public enum TranscriptRunBoundary: String, Codable, Sendable { case beforeRun, afterRun }

extension CodingThread {
    mutating func appendRunMessage(id messageID: String = UUID().uuidString, role: MessageRole, text: String, runID: UUID? = nil) {
        var message = ChatMessage(id: messageID, role: role, text: text)
        message.runReference = (runID ?? activeRun?.id).map { .init(threadID: id, runID: $0) }
        messages.append(message)
    }

    /// A transcript slice requires actual attribution. Neither timestamps, provider
    /// UUIDs nor message ordering alone establish an old run's complete boundary.
    public func transcriptPrefix(runID: UUID, boundary: TranscriptRunBoundary) throws -> [ChatMessage] {
        let records = activeHistoryRuns
        let messages = visibleMessages
        guard let target = records.firstIndex(where: { $0.id == runID }),
              records[target].messageAttributionVersion == 1, records[target].status.isTerminal else {
            throw CoincideError("This run does not have a verified local transcript boundary.")
        }
        let reference = TranscriptRunReference(threadID: id, runID: runID)
        let positions = messages.indices.filter { messages[$0].runReference == reference }
        guard let first = positions.first, let last = positions.last else { throw CoincideError("This run has no attributed transcript messages.") }
        if boundary == .beforeRun {
            guard records[target].origin == .user, records[target].userMessageID == messages[first].id,
                  messages[first].role == .user else { throw CoincideError("This run has no verified opening user message.") }
        }
        let cut = boundary == .beforeRun ? first : last + 1
        let order = Dictionary(uniqueKeysWithValues: records.enumerated().map { ($0.element.id, $0.offset) })
        for (index, message) in messages.enumerated() {
            if index < cut {
                if let provenance = message.runReference, provenance.threadID == id {
                    guard let observed = order[provenance.runID], observed < target || (boundary == .afterRun && observed == target) else {
                        throw CoincideError("The transcript contains interleaved run boundaries.")
                    }
                }
            } else {
                guard let provenance = message.runReference, provenance.threadID == id,
                      let observed = order[provenance.runID], observed > target || (boundary == .beforeRun && observed == target) else {
                    throw CoincideError("Some later messages do not have a verified run boundary.")
                }
            }
        }
        return Array(messages.prefix(cut))
    }
}
