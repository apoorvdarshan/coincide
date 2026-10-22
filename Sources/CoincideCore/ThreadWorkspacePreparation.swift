import Foundation

public enum ThreadWorkspacePreparationPhase: String, Codable, Sendable {
    case queued, resolving, preparing, completed, failed, cancelled, interrupted
}

/// The intent is durable before Git resolves a base or creates a checkout. Previous attempts
/// remain references only; retrying never removes their folders, branches, or ownership records.
public struct ThreadWorkspacePreparationAttempt: Codable, Sendable, Equatable {
    public let request: GitWorktreeRequest
    public let plan: GitWorktreePlan?
    public let setup: ThreadProjectScriptRun?
    public init(request: GitWorktreeRequest, plan: GitWorktreePlan?, setup: ThreadProjectScriptRun? = nil) { self.request = request; self.plan = plan; self.setup = setup }
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
    public var setup: ThreadProjectScriptRun?
    public var id: UUID { request.id }
    public var destinationPath: String { request.destinationPath }
    public var isReady: Bool { phase == .completed }
    public var isRunning: Bool { phase == .queued || phase == .resolving || phase == .preparing }
    public var canRetry: Bool { phase == .failed || phase == .cancelled || phase == .interrupted }
    /// The main checkout is registered in Git's inventory, but selecting it is not
    /// a dedicated-worktree creation and must never invoke the setup role.
    var permitsProjectSetup: Bool { Self.isDedicatedWorktree(plan) }
    private static func isDedicatedWorktree(_ plan: GitWorktreePlan?) -> Bool {
        guard let plan else { return false }
        if case .reuse = plan.request.selection {
            return plan.worktreeGitDirectoryPath != plan.commonDirectoryPath &&
                plan.worktreeGitDirectoryIdentity != plan.commonDirectoryIdentity
        }
        return true
    }
    public init(request: GitWorktreeRequest, now: Date = Date(), previousAttempts: [ThreadWorkspacePreparationAttempt] = [], reviewSetup: Bool = false) {
        self.request = request; phase = .queued; cancelRequested = false
        createdAt = now; updatedAt = now; self.previousAttempts = previousAttempts
        setup = reviewSetup ? .init(now: now) : nil
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
        try setup?.validate(workspacePath: destinationPath)
        guard setup?.plan == nil || permitsProjectSetup else { throw CoincideError("Project setup requires a dedicated worktree.") }
        for previous in previousAttempts {
            try previous.request.validate(); try Self.validate(plan: previous.plan, request: previous.request)
            try previous.setup?.validate(workspacePath: previous.request.destinationPath)
            guard previous.setup?.plan == nil || Self.isDedicatedWorktree(previous.plan) else { throw CoincideError("Project setup history requires a dedicated worktree.") }
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
