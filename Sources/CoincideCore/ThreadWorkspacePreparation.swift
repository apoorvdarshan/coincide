import Foundation

public enum ThreadWorkspacePreparationPhase: String, Codable, Sendable {
    case queued, resolving, preparing, completed, failed, cancelled, interrupted
}

/// The intent is durable before Git resolves a base or creates a checkout. Previous attempts
/// remain references only; retrying never removes their folders, branches, or ownership records.
public struct ThreadWorkspacePreparationAttempt: Codable, Sendable, Equatable {
    public let request: GitWorktreeRequest
    public let plan: GitWorktreePlan?
    public init(request: GitWorktreeRequest, plan: GitWorktreePlan?) { self.request = request; self.plan = plan }
}

public struct ThreadWorkspacePreparation: Codable, Sendable, Equatable, Identifiable {
    public var request: GitWorktreeRequest
    public var plan: GitWorktreePlan?
    public var result: GitWorktreeResult?
    public var phase: ThreadWorkspacePreparationPhase
    public var error: String?
    public var cancelRequested: Bool
    public var createdAt: Date
    public var updatedAt: Date
    public var endedAt: Date?
    public var previousAttempts: [ThreadWorkspacePreparationAttempt]
    public var id: UUID { request.id }
    public var destinationPath: String { request.destinationPath }
    public var isReady: Bool { phase == .completed }
    public var isRunning: Bool { phase == .queued || phase == .resolving || phase == .preparing }
    public var canRetry: Bool { phase == .failed || phase == .cancelled || phase == .interrupted }
    public init(request: GitWorktreeRequest, now: Date = Date(), previousAttempts: [ThreadWorkspacePreparationAttempt] = []) {
        self.request = request; phase = .queued; cancelRequested = false
        createdAt = now; updatedAt = now; self.previousAttempts = previousAttempts
    }
    public func validate(thread: CodingThread) throws {
        try request.validate()
        guard thread.workspacePath == destinationPath,
              Set((previousAttempts.map { $0.request.id }) + [id]).count == previousAttempts.count + 1,
              !cancelRequested || isRunning,
              phase != .preparing || plan != nil,
              (phase != .queued && phase != .resolving) || plan == nil,
              !isReady || (plan != nil && result != nil),
              result == nil || isReady else { throw CoincideError("This conversation has inconsistent workspace preparation state.") }
        try Self.validate(plan: plan, request: request)
        if let result { try Self.validate(result: result, plan: plan) }
        for previous in previousAttempts {
            try previous.request.validate(); try Self.validate(plan: previous.plan, request: previous.request)
            guard previous.request.destinationRoot == request.destinationRoot else { throw CoincideError("Workspace preparation history belongs to another managed root.") }
        }
        if !isReady {
            guard thread.providerThreadID == nil, thread.runtimeID == nil, thread.runtimeRequests.isEmpty,
                  thread.queuedTurns.allSatisfy({ $0.configuration.workspacePath == destinationPath && $0.configuration.nativeThreadID == nil }) else {
                throw CoincideError("An unfinished workspace cannot retain a provider session or queued turns in another folder.")
            }
        }
    }
    static func validate(plan: GitWorktreePlan?, request: GitWorktreeRequest) throws {
        guard let plan else { return }; try plan.validate()
        guard plan.request == request, plan.destinationPath == request.destinationPath else { throw CoincideError("The worktree plan does not match its saved intent.") }
    }
    static func validate(result: GitWorktreeResult, plan: GitWorktreePlan?) throws {
        try result.validate()
        guard let plan, result.destinationPath == plan.destinationPath, result.branch == plan.branch, result.headCommit == plan.baseCommit,
              result.submoduleWarning == nil || plan.request.submodules != .none,
              [40, 64].contains(result.headCommit.utf8.count), result.headCommit.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else {
            throw CoincideError("The prepared worktree does not match its saved plan.")
        }
    }
}
