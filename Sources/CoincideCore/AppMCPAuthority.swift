import CryptoKit
import Foundation

/// Durable command ownership contains identifiers and a permission ceiling,
/// never the HTTP bearer credential or a copy of the invocation arguments.
public struct AppMCPCommandAuthority: Codable, Equatable, Sendable {
    public let sessionID: UUID
    public let threadID: UUID
    public let projectID: UUID
    public let runtimeID: UUID
    public let incarnation: UUID
    public let providerInstanceID: UUID
    public let workspacePath: String
    public let provider: ProviderKind
    public let permission: PermissionMode
    public let runID: UUID

    public init(context: AppMCPContext) throws {
        let scope = context.scope
        guard let runID = context.runID,
              context.configuration.provider == scope.provider,
              context.configuration.workspacePath == scope.workspacePath,
              context.configuration.permission == scope.permission,
              try AppMCPAdmission.instanceID(configuration: context.configuration) == scope.providerInstanceID else { throw AppMCPError(.staleCaller) }
        try scope.validate()
        self.sessionID = scope.sessionID; self.threadID = scope.threadID; self.projectID = scope.projectID
        self.runtimeID = scope.runtimeID; self.incarnation = scope.incarnation; self.providerInstanceID = scope.providerInstanceID
        self.workspacePath = scope.workspacePath; self.provider = scope.provider; self.permission = scope.permission; self.runID = runID
    }
}

public struct AppMCPThreadOrigin: Codable, Equatable, Sendable {
    public let sessionID: UUID
    public let threadID: UUID
    public let runID: UUID
    public init(sessionID: UUID, threadID: UUID, runID: UUID) {
        self.sessionID = sessionID; self.threadID = threadID; self.runID = runID
    }
}

enum AppMCPTaskContext {
    @TaskLocal static var authority: AppMCPCommandAuthority?
}

/// Snapshot checks are repeated inside each command transaction. The Engine
/// additionally checks its live runtime, incarnation and unrevoked scope; those
/// ephemeral facts cannot be inferred from a journal snapshot alone.
enum AppMCPAdmission {
    static func instanceID(configuration: ProviderConfiguration) throws -> UUID {
        switch configuration.provider {
        case .codex: return configuration.codexRuntimeConfiguration?.instanceID ?? CodexRuntimeConfiguration.defaultInstanceID
        case .claude: return configuration.claudeRuntimeConfiguration?.instanceID ?? ClaudeRuntimeConfiguration.defaultInstanceID
        case .antigravity: return configuration.antigravityConfiguration?.instanceID ?? AntigravityConfiguration.defaultInstanceID
        case .pi:
            guard let id = configuration.piConfiguration?.instanceID else { throw AppMCPError(.staleCaller) }; return id
        case .opencode:
            guard let id = configuration.openCodeConfiguration?.instanceID else { throw AppMCPError(.staleCaller) }; return id
        case .muse:
            guard let id = configuration.museConfiguration?.instanceID else { throw AppMCPError(.staleCaller) }; return id
        case .acp:
            guard let id = configuration.acpAgent?.id else { throw AppMCPError(.staleCaller) }; return id
        }
    }

    /// Automatic review and automatic edit approval are distinct policies. The
    /// two middle modes are incomparable, rather than assigned an invented rank.
    static func permits(_ target: PermissionMode, ceiling: PermissionMode) -> Bool {
        ceiling == .fullAccess || target == .supervised || target == ceiling
    }
    private static func require(_ permission: PermissionMode, authority: AppMCPCommandAuthority, current: PermissionMode) throws {
        guard permits(permission, ceiling: authority.permission), permits(permission, ceiling: current) else { throw AppMCPError(.permissionDenied) }
    }
    private static func caller(authority: AppMCPCommandAuthority, snapshot: WorkspaceSnapshot) throws -> CodingThread {
        guard MCPProtocol.text(authority.workspacePath, maximum: 4_096), authority.workspacePath.hasPrefix("/"),
              let caller = snapshot.threads.first(where: { $0.id == authority.threadID }), !caller.isArchived,
              caller.projectID == authority.projectID, caller.runtimeID == authority.runtimeID,
              caller.provider == authority.provider, caller.workspacePath == authority.workspacePath,
              let run = caller.activeRun, run.id == authority.runID, !run.stopRequested,
              run.configuration.provider == authority.provider, run.configuration.workspacePath == authority.workspacePath,
              run.configuration.permission == authority.permission,
              try instanceID(configuration: run.configuration) == authority.providerInstanceID else { throw AppMCPError(.staleCaller) }
        return caller
    }

    /// Checks the entire batch before any inner reducer runs. Permission edits
    /// and newly created threads are projected for subsequent members; all other
    /// lifecycle semantics remain with the existing reducers, which run below.
    @inline(never)
    static func validate(authority: AppMCPCommandAuthority, snapshot: WorkspaceSnapshot, commands: [EngineCommand]) throws {
        do { try validateBatch(authority: authority, snapshot: snapshot, commands: commands) }
        catch let error as AppMCPError { throw WorkspaceCommandError(error.localizedDescription) }
    }
    @inline(never)
    private static func validateBatch(authority: AppMCPCommandAuthority, snapshot: WorkspaceSnapshot, commands: [EngineCommand]) throws {
        let caller = try caller(authority: authority, snapshot: snapshot)
        guard !commands.isEmpty, commands.count <= 64 else { throw AppMCPError(.invalidRequest) }
        var created: [UUID: CodingThread] = [:], permissions: [UUID: PermissionMode] = [:]
        for command in commands {
            let currentCeiling = permissions[authority.threadID] ?? caller.permission
            try validateCommand(command, authority: authority, snapshot: snapshot, created: &created,
                                permissions: &permissions, currentCeiling: currentCeiling)
        }
    }
    @inline(never)
    private static func validateCommand(_ command: EngineCommand, authority: AppMCPCommandAuthority, snapshot: WorkspaceSnapshot,
                                        created: inout [UUID: CodingThread], permissions: inout [UUID: PermissionMode], currentCeiling: PermissionMode) throws {
        let capturedCreated = created, capturedPermissions = permissions
        func target(_ id: UUID) throws -> CodingThread {
            guard let thread = capturedCreated[id] ?? snapshot.threads.first(where: { $0.id == id }) else { throw AppMCPError(.notFound) }
            try require(capturedPermissions[id] ?? thread.permission, authority: authority, current: currentCeiling)
            if let active = thread.activeRun { try require(active.configuration.permission, authority: authority, current: currentCeiling) }
            return thread
        }
        func newThread(_ thread: CodingThread) throws {
            guard capturedCreated[thread.id] == nil, !snapshot.threads.contains(where: { $0.id == thread.id }),
                  thread.createdByAppMCP == nil || thread.createdByAppMCP == AppMCPThreadOrigin(sessionID: authority.sessionID, threadID: authority.threadID, runID: authority.runID) else { throw AppMCPError(.invalidRequest) }
            try require(thread.permission, authority: authority, current: currentCeiling)
            if let run = thread.activeRun { try require(run.configuration.permission, authority: authority, current: currentCeiling) }
            for queued in thread.queuedTurns { try require(queued.configuration.permission, authority: authority, current: currentCeiling) }
        }
        func environment() throws {
            guard authority.permission == .fullAccess, currentCeiling == .fullAccess else { throw AppMCPError(.capabilityDenied) }
        }
        switch command {
        case .appMCP: throw AppMCPError(.invalidRequest)
        case .client(let command):
            switch command {
            case .createThread(let thread):
                try newThread(thread); created[thread.id] = thread
            case .addProjectWithThread(_, let thread), .startProjectClone(_, let thread):
                try environment(); try newThread(thread); created[thread.id] = thread
            case .addProject, .renameProject, .removeProject:
                try environment()
            case .editThread(let id, let edit):
                _ = try target(id)
                if case .permission(let permission) = edit {
                    try require(permission, authority: authority, current: currentCeiling); permissions[id] = permission
                }
                // Provider-native agent/model choices are validated by their
                // existing reducers. They are not permission-mode aliases.
            case .submit(let id, _), .submitFromAppMCP(let id, _, _), .submitCapturedClaude(let id, _, _), .submitCapturedPi(let id, _, _),
                 .interrupt(let id), .interruptFromAppMCP(let id, _, _), .settleThread(let id, _, _), .resumeThread(let id, _):
                _ = try target(id)
            case .resumeQueue(let id):
                let thread = try target(id)
                for queued in thread.queuedTurns { try require(queued.configuration.permission, authority: authority, current: currentCeiling) }
            case .removeQueued(let id, let queuedID), .editQueued(let id, let queuedID), .replaceQueuedText(let id, let queuedID, _, _),
                 .moveQueued(let id, let queuedID, _, _):
                let thread = try target(id)
                guard let queued = thread.queuedTurns.first(where: { $0.id == queuedID }) else { throw AppMCPError(.notFound) }
                try require(queued.configuration.permission, authority: authority, current: currentCeiling)
            case .respond(let id, let requestID, _):
                let thread = try target(id)
                guard thread.runtimeRequests.contains(where: { $0.id == requestID && $0.request.isQuestion && !$0.responding }) else { throw AppMCPError(.capabilityDenied) }
            default: throw AppMCPError(.unsupported)
            }
        case .appMCPRequestGuard(let id, _, _, let request):
            _ = try target(id)
            guard request.isQuestion else { throw AppMCPError(.capabilityDenied) }
        case .appMCPTargetGuard(let id, let configuration):
            let thread = try target(id)
            guard ProviderConfiguration(thread: thread) == configuration else { throw AppMCPError(.staleCaller) }
        case .promptSteeringAccepted(let operation):
            _ = try target(operation.threadID)
            try require(operation.configuration.permission, authority: authority, current: currentCeiling)
            try require(operation.input.configuration.permission, authority: authority, current: currentCeiling)
        case .conversationHistoryAccepted(let review, _):
            _ = try target(review.sourceThreadID)
            try require(review.sourceConfiguration.permission, authority: authority, current: currentCeiling)
            try require(review.targetConfiguration.permission, authority: authority, current: currentCeiling)
        case .beginWorktreePreparation(let id, _, _, _, _, _, _, _): _ = try target(id)
        default: throw AppMCPError(.unsupported)
        }
    }

    /// Mutates only a local decision. A late rejection discards every preceding
    /// snapshot/effect; callers publish the one resulting decision atomically.
    @inline(never)
    static func reduce(authority: AppMCPCommandAuthority, commands: [EngineCommand], id: UUID,
                       snapshot: WorkspaceSnapshot, now: Date) throws -> WorkspaceDecision {
        do { return try reduceBatch(authority: authority, commands: commands, id: id, snapshot: snapshot, now: now) }
        catch let error as AppMCPError { throw WorkspaceCommandError(error.localizedDescription) }
    }
    @inline(never)
    private static func reduceBatch(authority: AppMCPCommandAuthority, commands: [EngineCommand], id: UUID,
                                    snapshot: WorkspaceSnapshot, now: Date) throws -> WorkspaceDecision {
        try validate(authority: authority, snapshot: snapshot, commands: commands)
        var combined = WorkspaceDecision(snapshot: snapshot)
        for (index, command) in commands.enumerated() {
            try validate(authority: authority, snapshot: combined.snapshot, commands: [command])
            let innerID = commands.count == 1 ? id : memberCommandID(parentID: id, index: index)
            let inner = try WorkspaceDecision.make(command, id: innerID, snapshot: combined.snapshot, now: now)
            if let next = inner.cancelCloneAttempt {
                guard combined.cancelCloneAttempt == nil || combined.cancelCloneAttempt == next else { throw AppMCPError(.invalidRequest) }
                combined.cancelCloneAttempt = next
            }
            if let next = inner.cancelWorktreeAttempt {
                guard combined.cancelWorktreeAttempt == nil || combined.cancelWorktreeAttempt == next else { throw AppMCPError(.invalidRequest) }
                combined.cancelWorktreeAttempt = next
            }
            combined.snapshot = inner.snapshot; combined.effects += inner.effects; combined.closeRuntimes.formUnion(inner.closeRuntimes)
        }
        guard Set(combined.effects.map(\.id)).count == combined.effects.count else { throw AppMCPError(.invalidRequest) }
        return combined
    }

    static func commandID(sessionID: UUID, clientRequestID: String, action: String) throws -> UUID {
        guard MCPProtocol.text(clientRequestID, maximum: 512), MCPProtocol.text(action, maximum: 256) else { throw AppMCPError(.invalidRequest) }
        return digestUUID(domain: "coincide-app-mcp-command-v1", fields: [sessionID.uuidString.lowercased(), clientRequestID, action])
    }
    static func memberCommandID(parentID: UUID, index: Int) -> UUID {
        digestUUID(domain: "coincide-app-mcp-batch-member-v1", fields: [parentID.uuidString.lowercased(), String(index)])
    }
    private static func digestUUID(domain: String, fields: [String]) -> UUID {
        var input = Data(domain.utf8)
        for field in fields {
            let bytes = Data(field.utf8)
            var count = UInt64(bytes.count).bigEndian
            withUnsafeBytes(of: &count) { input.append(contentsOf: $0) }
            input.append(bytes)
        }
        var bytes = Array(SHA256.hash(data: input).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50; bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
