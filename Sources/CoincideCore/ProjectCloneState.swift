import Foundation

public enum ProjectClonePhase: String, Codable, Sendable { case queued, running, completed, failed, cancelled, interrupted }

public struct ProjectCloneState: Codable, Sendable, Equatable, Identifiable {
    public var plan: GitClonePlan
    public var phase: ProjectClonePhase
    public var progress: GitCloneProgress
    public var error: String?
    public var cancelRequested: Bool
    public var createdAt: Date
    public var updatedAt: Date
    public var endedAt: Date?
    /// Failed/cancelled attempts are preserved, so retry never removes somebody's checkout bytes.
    public var previousPlans: [GitClonePlan]
    public var id: UUID { plan.id }
    public var isReady: Bool { phase == .completed }
    public var isRunning: Bool { phase == .queued || phase == .running }
    public var canRetry: Bool { phase == .failed || phase == .cancelled || phase == .interrupted }
    public init(plan: GitClonePlan, now: Date = Date(), previousPlans: [GitClonePlan] = []) {
        self.plan = plan; phase = .queued
        progress = .init(stage: .connecting, percent: nil, detail: nil, stalled: false)
        cancelRequested = false; createdAt = now; updatedAt = now; self.previousPlans = previousPlans
    }
    public func validate(project: WorkspaceProject) throws {
        try plan.validate()
        guard plan.destinationPath == project.path,
              Set((previousPlans + [plan]).map(\.id)).count == previousPlans.count + 1,
              previousPlans.allSatisfy({ $0.source == plan.source && $0.destinationPath == plan.destinationPath }) else {
            throw CoincideError("This project has inconsistent clone state.")
        }
        for old in previousPlans { try old.validate() }
    }
}

/// The native service publishes only after Git exits and the owned checkout is promoted.
/// Completion inspection is local/read-only and must never start another clone or contact a host.
public protocol ProjectCloneSession: Sendable {
    func run(onProgress: @escaping @Sendable (GitCloneProgress) async -> Void) async throws
    func isCompleted() async throws -> Bool
}

extension GitCloneService: ProjectCloneSession { }

extension WorkspaceSnapshot {
    var cloneAttemptIDs: Set<UUID> { Set(projects.flatMap { ($0.clone?.previousPlans ?? []) + ($0.clone.map { [$0.plan] } ?? []) }.map(\.id)) }
    public func workspaceReady(for thread: CodingThread) -> Bool {
        guard let project = projects.first(where: { $0.id == thread.projectID }) else { return false }
        let preparation = threads.first(where: { $0.id == thread.id })?.workspacePreparation ?? thread.workspacePreparation
        return (project.clone?.isReady ?? true) && (preparation?.isReady ?? true)
    }
    public func providerReady(for thread: CodingThread) -> Bool {
        let current = threads.first(where: { $0.id == thread.id }) ?? thread
        return !isPullRequestCheckoutLocked(threadID: current.id) && !isPullRequestCreationLocked(threadID: current.id) && !isConversationHistoryLocked(threadID: current.id) && !isCheckpointRestoreLocked(threadID: current.id) && current.settlement == nil && current.heldPostRunCheckpoint == nil && workspaceReady(for: current) && (current.workspacePreparation?.setup?.providerReleased ?? true)
    }
}
