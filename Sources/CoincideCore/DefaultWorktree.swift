import CryptoKit
import Foundation

/// A choice made for a newly authored draft. Absence keeps legacy and imported
/// conversations unchanged. Provider/model/permission are captured at Send, not here.
public final class DraftWorkspaceIntent: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let threadID: UUID
    public let threadCreatedAt: Date
    public let projectID: UUID
    public let projectCreatedAt: Date?
    public let sourcePath: String
    public let startFromOrigin: Bool
    public let submodules: ProjectWorktreeSubmoduleMode
    public let sourceProof: TaskIsolationProof
    public let baseBranch: String
    public init(id: UUID = UUID(), project: WorkspaceProject, threadID: UUID, threadCreatedAt: Date, startFromOrigin: Bool,
                submodules: ProjectWorktreeSubmoduleMode, sourceProof: TaskIsolationProof, baseBranch: String) {
        self.id = id; self.threadID = threadID; self.threadCreatedAt = threadCreatedAt; projectID = project.id; projectCreatedAt = project.createdAt
        sourcePath = project.path; self.startFromOrigin = startFromOrigin; self.submodules = submodules
        self.sourceProof = sourceProof; self.baseBranch = baseBranch
    }
    public static func == (lhs: DraftWorkspaceIntent, rhs: DraftWorkspaceIntent) -> Bool {
        lhs.id == rhs.id && lhs.threadID == rhs.threadID && lhs.threadCreatedAt == rhs.threadCreatedAt && lhs.projectID == rhs.projectID && lhs.projectCreatedAt == rhs.projectCreatedAt &&
        lhs.sourcePath.utf8.elementsEqual(rhs.sourcePath.utf8) && lhs.startFromOrigin == rhs.startFromOrigin &&
        lhs.submodules == rhs.submodules && lhs.sourceProof == rhs.sourceProof && lhs.baseBranch.utf8.elementsEqual(rhs.baseBranch.utf8)
    }
    public static func captureIfRepository(project: WorkspaceProject, threadID: UUID, threadCreatedAt: Date, startFromOrigin: Bool,
                                           submodules: ProjectWorktreeSubmoduleMode) async throws -> Self? {
        let source = try GitWorktreeDirectory(path: project.path)
        let result = try await GitWorktreeCommand(environment: nil, executable: nil).run(
            ["rev-parse", "--is-inside-work-tree"], cwdFD: source.fd)
        try source.validate()
        if result.status == 128,
           String(data: result.errorOutput, encoding: .utf8)?.hasPrefix("fatal: not a git repository") == true { return nil }
        guard result.status == 0, String(data: result.output, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) == "true" else {
            throw WorkspaceCommandError("The project repository is unavailable. No checkout or input was started.")
        }
        let value = try await capture(project: project, threadID: threadID, threadCreatedAt: threadCreatedAt, startFromOrigin: startFromOrigin, submodules: submodules)
        try source.validate()
        guard value.sourceProof.sourceIdentity == source.identity else { throw TaskIsolationError.changedRepository }
        return value
    }
    public static func capture(project: WorkspaceProject, threadID: UUID, threadCreatedAt: Date, startFromOrigin: Bool,
                               submodules: ProjectWorktreeSubmoduleMode) async throws -> Self {
        let capture = TaskIsolationCapture()
        let proof = try await capture.capture(parentWorkspacePath: project.path, projectPath: project.path)
        let status = try await GitService(root: URL(fileURLWithPath: proof.sourcePath)).status()
        let branch = status.branch
        guard !status.isDetached, !branch.isEmpty,
              status.head == proof.baseCommit else { throw WorkspaceCommandError("Choose a local branch before creating a default worktree.") }
        try await capture.validate(proof, requireCurrentHead: true)
        return .init(project: project, threadID: threadID, threadCreatedAt: threadCreatedAt, startFromOrigin: startFromOrigin, submodules: submodules,
                     sourceProof: proof, baseBranch: branch)
    }

}

/// Original native input ownership. The exact payload owns the original command
/// UUID; it contains neither a selected UI target nor a reconstructed attachment.
public struct DefaultWorktreeInput: Codable, Sendable, Equatable {
    public let threadID: UUID
    public let threadCreatedAt: Date
    public let intent: DraftWorkspaceIntent
    public let configuration: ProviderConfiguration
    public let checkpointPolicy: RunCheckpointPolicy
    public let text: String
    public let attachments: [ChatAttachment]
    public let claudeRuntime: ClaudeRuntimeConfiguration?
    public init(thread: CodingThread, intent: DraftWorkspaceIntent, text: String,
                claudeRuntime: ClaudeRuntimeConfiguration? = nil) {
        threadID = thread.id; threadCreatedAt = thread.createdAt; self.intent = intent
        configuration = .init(thread: thread); checkpointPolicy = thread.effectiveCheckpointPolicy; self.text = text; attachments = thread.draftAttachments
        self.claudeRuntime = claudeRuntime
    }
}

/// Metadata resolution is performed by the owned preparation effect, after
/// input admission. The ordinary worktree plan durably pins the resulting commit
/// before any checkout mutation or setup script can run.
public final class GitWorktreeAutomaticBase: Codable, Sendable, Equatable {
    public let startFromOrigin: Bool
    public let sourceProof: TaskIsolationProof
    public let branch: String
    public init(intent: DraftWorkspaceIntent) { startFromOrigin = intent.startFromOrigin; sourceProof = intent.sourceProof; branch = intent.baseBranch }
    public static func == (lhs: GitWorktreeAutomaticBase, rhs: GitWorktreeAutomaticBase) -> Bool {
        lhs.startFromOrigin == rhs.startFromOrigin && lhs.sourceProof == rhs.sourceProof && lhs.branch.utf8.elementsEqual(rhs.branch.utf8)
    }
}

enum DefaultWorktreeIdentity {
    static func preparationID(commandID: UUID) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(("Coincide.default-worktree.v1:" + commandID.uuidString).utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50; bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

extension WorkspaceDecision {
    @inline(never)
    static func reduceDefaultWorktreeRetry(threadID: UUID, attemptID: UUID, snapshot: WorkspaceSnapshot, now: Date) throws -> Self {
        var decision = Self(snapshot: snapshot)
        guard let i = snapshot.threads.firstIndex(where: { $0.id == threadID }),
              var state = snapshot.threads[i].workspacePreparation, state.id == attemptID,
              state.request.automaticBase != nil, state.canRetry,
              !snapshot.threads[i].isBusy, !snapshot.threads[i].isArchived, snapshot.threads[i].settlement == nil,
              !snapshot.isConversationHistoryLocked(threadID: threadID),
              !snapshot.isCheckpointRestoreLocked(threadID: threadID),
              !snapshot.isPullRequestCheckoutLocked(threadID: threadID),
              !snapshot.isPullRequestCreationLocked(threadID: threadID),
              !snapshot.isCheckpointRestoreLocked(path: state.request.sourcePath),
              !snapshot.isPullRequestCheckoutLocked(path: state.request.sourcePath),
              !snapshot.isPullRequestCreationLocked(path: state.request.sourcePath) else {
            throw WorkspaceCommandError("This worktree attempt changed. Refresh it before retrying.")
        }
        state.phase = state.plan == nil ? .queued : .preparing
        state.cancelRequested = false; state.error = nil; state.endedAt = nil; state.updatedAt = now
        decision.snapshot.threads[i].workspacePreparation = state
        decision.snapshot.threads[i].queuePaused = false
        decision.effects.append(.init(request: state.plan.map { .prepareWorktree(threadID: threadID, plan: $0) }
            ?? .resolveWorktree(threadID: threadID, request: state.request)))
        return decision
    }
    @inline(never)
    static func reduceDefaultWorktree(_ input: DefaultWorktreeInput, request: GitWorktreeRequest,
                                     id: UUID, snapshot: WorkspaceSnapshot, now: Date) throws -> Self {
        guard let thread = snapshot.threads.first(where: { $0.id == input.threadID }),
              let project = snapshot.projects.first(where: { $0.id == input.intent.projectID }),
              project.scratch == nil, thread.scratchWorkspace == nil,
              thread.createdAt == input.threadCreatedAt, thread.id == input.intent.threadID,
              thread.createdAt == input.intent.threadCreatedAt, thread.projectID == project.id,
              project.createdAt == input.intent.projectCreatedAt,
              project.path.utf8.elementsEqual(input.intent.sourcePath.utf8),
              thread.workspacePath.utf8.elementsEqual(input.intent.sourcePath.utf8),
              thread.draftWorkspaceIntent == input.intent, thread.workspacePreparation == nil,
              thread.messages.isEmpty, thread.runHistory?.isEmpty != false,
              thread.queuedTurns.isEmpty, thread.providerThreadID == nil, thread.runtimeID == nil,
              thread.draftAttachments == input.attachments, thread.effectiveCheckpointPolicy == input.checkpointPolicy,
              try JSONEncoder.sorted.encode(ProviderConfiguration(thread: thread)) == JSONEncoder.sorted.encode(input.configuration),
              request.id == DefaultWorktreeIdentity.preparationID(commandID: id), request.sourcePath.utf8.elementsEqual(input.intent.sourcePath.utf8),
              request.automaticBase?.startFromOrigin == input.intent.startFromOrigin else {
            throw WorkspaceCommandError("This draft's workspace choice changed. Review it before sending.")
        }
        var captured = snapshot
        do {
            if let runtime = input.claudeRuntime {
                guard thread.provider == .claude, thread.claudeRuntimeConfiguration == nil,
                      runtime.registeredWorkspacePath.utf8.elementsEqual(thread.workspacePath.utf8) else { throw ClaudeRuntimeConfiguration.invalid() }
                try runtime.validate(); captured.threads[captured.threads.firstIndex(where: { $0.id == thread.id })!].claudeRuntimeConfiguration = runtime
            }
        } catch let error as CoincideError { throw WorkspaceCommandError(error.localizedDescription) }
        let ready = captured.threads.first(where: { $0.id == thread.id })!
        var decision = Self(snapshot: captured)
        do {
            try decision.beginWorktreePreparation(threadID: thread.id, request: request,
                expectedSourcePath: thread.workspacePath, previousAttemptID: nil, reviewSetup: true,
                claudeRuntimeConfiguration: try ready.claudeRuntimeConfiguration?.replacingWorkspace(request.destinationPath,
                    physicalPath: ClaudeRuntimeValidation.physical(request.destinationPath, allowMissing: true)), now: now)
        } catch let error as CoincideError { throw WorkspaceCommandError(error.localizedDescription) }
        // Native submission captures the repathed provider configuration and the
        // original draft attachments, then queues behind real checkout/setup readiness.
        var submitted = try Self.make(.client(.submit(threadID: thread.id, text: input.text)),
            id: id, snapshot: decision.snapshot, now: now, validatingLedger: false)
        submitted.effects = decision.effects + submitted.effects
        submitted.closeRuntimes.formUnion(decision.closeRuntimes)
        return submitted
    }
}

private extension JSONEncoder {
    static var sorted: JSONEncoder { let value = JSONEncoder(); value.outputFormatting = [.sortedKeys]; return value }
}
