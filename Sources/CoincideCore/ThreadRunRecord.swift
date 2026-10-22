import Foundation

public enum ThreadRunOrigin: String, Codable, Sendable { case user, agent, legacy }
public enum ThreadRunStatus: String, Codable, Sendable {
    case running, awaitingApproval, completed, interrupted, failed, unknown
    public var isTerminal: Bool { self != .running && self != .awaitingApproval }
}
public enum ThreadRunEndReason: String, Codable, Sendable {
    case providerCompleted, providerActivity, providerFailure, connectionLost, startFailed, forcedStop, applicationClosed
}

/// An observed run boundary. Adapter turn references can be client-generated;
/// retaining one does not establish provider fork or rollback support.
public struct ThreadRunRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var origin: ThreadRunOrigin
    public var configuration: ProviderConfiguration
    public var userMessageID: String?
    public var startedAt: Date
    public var endedAt: Date?
    public var status: ThreadRunStatus
    public var stopRequested: Bool
    public var providerThreadID: String?
    public var turnIDs: [String]
    public var endReason: ThreadRunEndReason?
    public var providerStopReason: String?
    public var checkpoints: ThreadRunCheckpoints?
    /// Nil on older records: their transcript boundaries must not be guessed.
    public var messageAttributionVersion: Int?

    public init(run: ActiveRun, origin: ThreadRunOrigin, userMessageID: String? = nil) {
        id = run.id; self.origin = origin; configuration = run.configuration
        self.userMessageID = userMessageID; startedAt = run.startedAt
        status = .running; stopRequested = run.stopRequested
        providerThreadID = run.configuration.nativeThreadID
        turnIDs = run.nativeTurnID.map { [$0] } ?? []
    }
}

extension CodingThread {
    mutating func beginRunRecord(_ run: ActiveRun, origin: ThreadRunOrigin, userMessageID: String? = nil, checkpoints: ThreadRunCheckpoints? = nil, attributesMessages: Bool = false) {
        if runHistory == nil { runHistory = [] }
        guard !runHistory!.contains(where: { $0.id == run.id }) else { return }
        runHistory!.append(.init(run: run, origin: origin, userMessageID: userMessageID))
        runHistory![runHistory!.count - 1].checkpoints = checkpoints
        runHistory![runHistory!.count - 1].messageAttributionVersion = attributesMessages ? 1 : nil
    }

    mutating func updateRunRecord(status: ThreadRunStatus? = nil) {
        guard let run = activeRun else { return }
        // An old active run has known settings/start time, but its origin and
        // completed predecessors cannot be reconstructed from transcript rows.
        beginRunRecord(run, origin: .legacy)
        guard let i = runHistory?.firstIndex(where: { $0.id == run.id }), runHistory?[i].status.isTerminal == false else { return }
        if let status { runHistory?[i].status = status }
        runHistory?[i].stopRequested = run.stopRequested
        if let providerThreadID { runHistory?[i].providerThreadID = providerThreadID }
        if let turn = run.nativeTurnID, !turn.isEmpty, runHistory?[i].turnIDs.contains(turn) == false { runHistory?[i].turnIDs.append(turn) }
    }

    mutating func finishRunRecord(status: ThreadRunStatus, reason: ThreadRunEndReason, now: Date, providerStopReason: String? = nil) {
        guard status.isTerminal, let run = activeRun else { return }
        updateRunRecord()
        guard let i = runHistory?.firstIndex(where: { $0.id == run.id }), runHistory?[i].status.isTerminal == false else { return }
        runHistory?[i].status = status; runHistory?[i].endedAt = now; runHistory?[i].endReason = reason
        runHistory?[i].providerStopReason = providerStopReason.map { String($0.prefix(500)) }
        if var checkpoints = runHistory?[i].checkpoints, checkpoints.postRun == nil {
            let unavailable: RunCheckpointUnavailableReason?
            if !checkpoints.providerReleased { unavailable = .providerNotStarted }
            else if reason == .applicationClosed || status == .unknown { unavailable = .unknownExit }
            else if status == .failed { unavailable = .failedRun }
            else { unavailable = nil }
            if let unavailable {
                checkpoints.postRun = .init(workspacePath: run.configuration.workspacePath, phase: .unavailable, now: now, unavailableReason: unavailable)
                runHistory?[i].checkpoints = checkpoints
            }
        }
    }

    func validateRunHistory() throws {
        let records = runHistory ?? []
        guard Set(records.map(\.id)).count == records.count,
              Set(records.map(\.id)).isDisjoint(with: Set(queuedTurns.map(\.id))),
              records.filter({ !$0.status.isTerminal }).count <= 1 else { throw CoincideError("The conversation has invalid or duplicate run history.") }
        for record in records {
            guard record.messageAttributionVersion == nil || record.messageAttributionVersion == 1 else { throw CoincideError("This run uses unsupported transcript attribution.") }
            if record.messageAttributionVersion == 1, record.origin == .user {
                guard let message = messages.first(where: { $0.id == record.userMessageID }),
                      message.runReference == .init(threadID: id, runID: record.id) else { throw CoincideError("The run's opening message has inconsistent attribution.") }
            }
            try validateRunCheckpoints(record)
            guard record.status.isTerminal == (record.endedAt != nil), record.status.isTerminal == (record.endReason != nil),
                  Set(record.turnIDs).count == record.turnIDs.count, record.turnIDs.allSatisfy({ !$0.isEmpty }),
                  record.status.isTerminal || activeRun?.id == record.id,
                  record.origin != .user || record.userMessageID != nil,
                  record.userMessageID.map({ id in messages.contains(where: { $0.id == id && $0.role == .user }) }) ?? true else {
                throw CoincideError("The conversation has invalid run boundaries or message references.")
            }
            if let run = activeRun, run.id == record.id {
                guard !record.status.isTerminal, record.configuration == run.configuration, record.startedAt == run.startedAt,
                      record.stopRequested == run.stopRequested else { throw CoincideError("Run history does not match the active turn.") }
            }
        }
        for message in messages {
            guard let reference = message.runReference, reference.threadID == id else { continue }
            guard records.contains(where: { $0.id == reference.runID }) else { throw CoincideError("A message refers to an unavailable local run.") }
        }
    }
}
