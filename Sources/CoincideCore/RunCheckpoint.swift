import Foundation

public enum RunCheckpointPolicy: String, Codable, Sendable, CaseIterable { case automatic, disabled }
public enum RunCheckpointStage: String, Codable, Sendable { case baseline, postRun }
public enum RunCheckpointPhase: String, Codable, Sendable {
    case resolving, capturing, ready, unavailable, failed, interrupted, skipped
    public var isRunning: Bool { self == .resolving || self == .capturing }
    public var holdsPostRunQueue: Bool { isRunning || self == .failed || self == .interrupted }
}
public enum RunCheckpointUnavailableReason: String, Codable, Sendable { case notRepository, agentInitiated, failedRun, unknownExit, providerNotStarted }

public struct ThreadRunCheckpointAttempt: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let workspacePath: String
    public var phase: RunCheckpointPhase
    public let requestedAt: Date
    public var updatedAt: Date
    public var plan: GitCheckpointPlan?
    public var receipt: GitCheckpointReceipt?
    public var error: String?
    public var cleanupWarning: String?
    public let isLaterObservation: Bool
    public var unavailableReason: RunCheckpointUnavailableReason?
    public init(id: UUID = UUID(), workspacePath: String, phase: RunCheckpointPhase = .resolving,
                now: Date = Date(), isLaterObservation: Bool = false, unavailableReason: RunCheckpointUnavailableReason? = nil) {
        self.id = id; self.workspacePath = workspacePath; self.phase = phase; requestedAt = now; updatedAt = now
        self.isLaterObservation = isLaterObservation; self.unavailableReason = unavailableReason
    }
    public static let failureMessage = "A workspace checkpoint could not be saved. Existing files and staging were preserved."
    public static let interruptedMessage = "The app stopped during checkpoint capture. Existing evidence was preserved; no provider work was replayed."
    public static let cleanupWarningMessage = "The checkpoint is saved, but some temporary checkpoint data was preserved."
    public var canRetryPostRun: Bool { phase == .failed || phase == .interrupted }
    public var canContinuePostRun: Bool { canRetryPostRun }
    public func validate(workspacePath expected: String) throws {
        guard workspacePath == expected, requestedAt.timeIntervalSince1970.isFinite, updatedAt.timeIntervalSince1970.isFinite,
              error.map({ $0 == Self.failureMessage || $0 == Self.interruptedMessage }) ?? true,
              cleanupWarning == nil || cleanupWarning == Self.cleanupWarningMessage,
              (phase == .unavailable) == (unavailableReason != nil) else { throw CoincideError("This run has invalid checkpoint state.") }
        if let plan { try plan.validate(); guard plan.id == id, plan.workspacePath == workspacePath else { throw CoincideError("The checkpoint plan belongs to another run or workspace.") } }
        if let receipt { try receipt.validate(); guard plan == receipt.plan else { throw CoincideError("The checkpoint receipt does not match its recorded plan.") } }
        guard (phase != .capturing || plan != nil), (phase == .ready) == (receipt != nil), phase != .resolving || plan == nil else { throw CoincideError("The checkpoint phase does not match its evidence.") }
    }
}
public struct CheckpointPendingProviderStart: Codable, Sendable, Equatable {
    public let configuration: ProviderConfiguration
    public let prompt: String
    public let attachments: [ChatAttachment]?
    public init(configuration: ProviderConfiguration, prompt: String, attachments: [ChatAttachment]? = nil) {
        self.configuration = configuration; self.prompt = prompt; self.attachments = attachments
    }
}
public struct ThreadRunCheckpoints: Codable, Sendable, Equatable {
    public var baseline: ThreadRunCheckpointAttempt
    public var postRun: ThreadRunCheckpointAttempt?
    public var previousPostRunAttempts: [ThreadRunCheckpointAttempt]
    public var providerReleased: Bool
    public var pendingStart: CheckpointPendingProviderStart?
    public init(baseline: ThreadRunCheckpointAttempt, providerReleased: Bool = false, pendingStart: CheckpointPendingProviderStart? = nil) {
        self.baseline = baseline; self.providerReleased = providerReleased; self.pendingStart = pendingStart; previousPostRunAttempts = []
    }
}
public struct HeldPostRunCheckpoint: Sendable, Equatable {
    public let runID: UUID
    public let attempt: ThreadRunCheckpointAttempt
    public init(runID: UUID, attempt: ThreadRunCheckpointAttempt) { self.runID = runID; self.attempt = attempt }
}

public protocol RunCheckpointSession: Sendable {
    func prepare(id: UUID) async throws -> GitCheckpointPlan
    func capture(_ plan: GitCheckpointPlan) async throws -> GitCheckpointReceipt
    func inspect(_ plan: GitCheckpointPlan) async throws -> GitCheckpointInspection
    func finalizeScratch(_ receipt: GitCheckpointReceipt) async throws -> GitCheckpointScratchResult
    func diff(from: GitCheckpointReceipt, to: GitCheckpointReceipt, paths: [String]?, ignoreWhitespace: Bool, maxBytes: Int) async throws -> GitCheckpointDiff
}
extension RunCheckpointSession {
    public func diff(from: GitCheckpointReceipt, to: GitCheckpointReceipt, paths: [String]?, ignoreWhitespace: Bool, maxBytes: Int) async throws -> GitCheckpointDiff { throw GitCheckpointError(.incomplete) }
}
extension GitCheckpointService: RunCheckpointSession { }

extension CodingThread {
    public var effectiveCheckpointPolicy: RunCheckpointPolicy { checkpointPolicy ?? .automatic }
    public var heldPostRunCheckpoint: HeldPostRunCheckpoint? {
        for record in (runHistory ?? []).reversed() {
            if let attempt = record.checkpoints?.postRun, attempt.phase.holdsPostRunQueue { return .init(runID: record.id, attempt: attempt) }
        }
        return nil
    }
    public func runCheckpoint(runID: UUID, stage: RunCheckpointStage) -> ThreadRunCheckpointAttempt? {
        guard let checkpoints = runHistory?.first(where: { $0.id == runID })?.checkpoints else { return nil }
        return stage == .baseline ? checkpoints.baseline : checkpoints.postRun
    }
    mutating func updateCheckpoint(runID: UUID, stage: RunCheckpointStage, _ body: (inout ThreadRunCheckpointAttempt) -> Void) {
        guard let i = runHistory?.firstIndex(where: { $0.id == runID }), var checkpoints = runHistory?[i].checkpoints else { return }
        if stage == .baseline { body(&checkpoints.baseline) }
        else if var attempt = checkpoints.postRun { body(&attempt); checkpoints.postRun = attempt }
        runHistory?[i].checkpoints = checkpoints
    }
    func validateRunCheckpoints(_ record: ThreadRunRecord) throws {
        guard let checkpoints = record.checkpoints else { return }
        let attempts = [checkpoints.baseline] + checkpoints.previousPostRunAttempts + (checkpoints.postRun.map { [$0] } ?? [])
        guard Set(attempts.map(\.id)).count == attempts.count, !attempts.contains(where: { $0.id == record.id }),
              !(checkpoints.providerReleased && checkpoints.pendingStart != nil),
              checkpoints.providerReleased || record.status.isTerminal || checkpoints.pendingStart != nil else { throw CoincideError("The run has inconsistent checkpoint ownership.") }
        for attempt in attempts { try attempt.validate(workspacePath: record.configuration.workspacePath) }
        if let pending = checkpoints.pendingStart {
            guard !record.status.isTerminal, activeRun?.id == record.id, pending.configuration == record.configuration,
                  let message = messages.first(where: { $0.id == record.userMessageID }), pending.prompt == message.text, pending.attachments == message.attachments,
                  checkpoints.baseline.phase.isRunning else { throw CoincideError("The deferred provider start changed after acceptance.") }
        }
        if let post = checkpoints.postRun { guard record.status.isTerminal, checkpoints.providerReleased || (post.phase == .unavailable && post.unavailableReason == .providerNotStarted) else { throw CoincideError("A final checkpoint cannot precede the run boundary.") } }
    }
}
