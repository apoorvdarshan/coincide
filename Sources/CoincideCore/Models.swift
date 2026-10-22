import Foundation

public struct WorkspaceProject: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var path: String
    public var clone: ProjectCloneState?
    public var repositoryIdentity: RepositoryIdentity?
    public var createdAt: Date?
    public var updatedAt: Date?
    public init(path: String) {
        self.id = UUID()
        let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        self.path = url.path; self.name = url.lastPathComponent
        let now = Date(); self.createdAt = now; self.updatedAt = now
    }
}

public enum ThreadState: String, Codable, Sendable { case idle, running, awaitingApproval, failed, interrupted }
public enum MessageRole: String, Codable, Sendable { case user, assistant, tool, system, reasoning }
public enum PermissionMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case supervised, autoAcceptEdits, auto, fullAccess
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .supervised: "Supervised"
        case .autoAcceptEdits: "Auto-accept edits"
        case .auto: "Auto"
        case .fullAccess: "Full access"
        }
    }
    public var approvalPolicy: JSONValue { .string(self == .fullAccess ? "never" : "on-request") }
    public var reviewer: JSONValue { .string(self == .auto ? "auto_review" : "user") }
    public func sandbox(cwd: String) -> JSONValue {
        switch self {
        case .fullAccess: .object(["type": .string("dangerFullAccess")])
        case .supervised: .object(["type": .string("readOnly"), "networkAccess": .bool(false)])
        case .autoAcceptEdits, .auto:
            .object(["type": .string("workspaceWrite"), "writableRoots": .array([.string(cwd)]),
                     "networkAccess": .bool(false), "excludeTmpdirEnvVar": .bool(false), "excludeSlashTmp": .bool(false)])
        }
    }
}

public struct ChatMessage: Codable, Identifiable, Sendable, Equatable {
    public var id: String
    public var role: MessageRole
    public var text: String
    public var createdAt: Date
    public var attachments: [ChatAttachment]?
    public var providerEntity: ProviderEntity?
    public var submissionError: String?
    public var promptSteeringID: UUID?
    public var runReference: TranscriptRunReference?
    public var removedByHistoryOperationID: UUID?
    public init(id: String = UUID().uuidString, role: MessageRole, text: String, attachments: [ChatAttachment]? = nil) {
        self.id = id; self.role = role; self.text = text; self.createdAt = Date(); self.attachments = attachments
    }
}

public struct CodingThread: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    public var projectID: UUID
    public var title: String
    public var workspacePath: String
    public var workspacePreparation: ThreadWorkspacePreparation?
    public var settlement: ThreadSettlement?
    public var providerThreadID: String?
    public var provider: ProviderKind
    public var acpAgent: ACPAgentConfiguration?
    public var openCodeConfiguration: OpenCodeConfiguration?
    public var piConfiguration: PiConfiguration?
    public var museConfiguration: MuseConfiguration?
    public var agentModeID: String?
    public var agentConfigValues: [String: String]?
    public var providerMetadata: JSONValue?
    public var providerActivity: ProviderActivity?
    public var agentConfiguration: [String: JSONValue]?
    public var draft: String
    public var draftAttachments: [ChatAttachment]
    public var model: String
    public var reasoningEffort: String?
    public var codexReasoningPreferences: [String: String]?
    public var codexModelSelectionSource: CodexModelSelectionSource?
    public var permission: PermissionMode
    public var state: ThreadState
    public var messages: [ChatMessage]
    public var queuedTurns: [QueuedTurn]
    public var queuePaused: Bool
    public var activeRun: ActiveRun?
    public var runHistory: [ThreadRunRecord]?
    public var checkpointPolicy: RunCheckpointPolicy?
    public var forkedFromHistoryOperationID: UUID?
    public var pullRequestCheckoutOperationID: UUID?
    public var runtimeID: UUID?
    public var steeringCapabilityRevision: UInt64?
    public var runtimeRequests: [RuntimeRequest]
    public var isPinned: Bool
    public var isArchived: Bool
    public var createdAt: Date
    public var updatedAt: Date
    public init(project: WorkspaceProject, model: String = "") {
        id = UUID(); projectID = project.id; title = "New thread"; workspacePath = project.path
        self.model = model; provider = .codex; draft = ""; draftAttachments = []; permission = .supervised; state = .idle; messages = []
        queuedTurns = []; queuePaused = false; runtimeRequests = []
        isPinned = false; isArchived = false; createdAt = Date(); updatedAt = Date()
    }
    enum CodingKeys: String, CodingKey {
        case id, projectID, title, workspacePath, providerThreadID, provider, draft, model, permission, state, messages, isPinned, isArchived, createdAt, updatedAt
        case queuedTurns, queuePaused, activeRun, runHistory, checkpointPolicy, forkedFromHistoryOperationID, pullRequestCheckoutOperationID, runtimeID, steeringCapabilityRevision, runtimeRequests, workspacePreparation, settlement
        case draftAttachments, reasoningEffort, codexReasoningPreferences, codexModelSelectionSource
        case acpAgent, openCodeConfiguration, piConfiguration, agentModeID, agentConfigValues, providerMetadata
        case museConfiguration
        case providerActivity, agentConfiguration
    }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        projectID = try values.decode(UUID.self, forKey: .projectID)
        title = try values.decode(String.self, forKey: .title)
        workspacePath = try values.decode(String.self, forKey: .workspacePath)
        workspacePreparation = try values.decodeIfPresent(ThreadWorkspacePreparation.self, forKey: .workspacePreparation)
        settlement = try values.decodeIfPresent(ThreadSettlement.self, forKey: .settlement)
        providerThreadID = try values.decodeIfPresent(String.self, forKey: .providerThreadID)
        provider = try values.decodeIfPresent(ProviderKind.self, forKey: .provider) ?? .codex
        acpAgent = try values.decodeIfPresent(ACPAgentConfiguration.self, forKey: .acpAgent)
        openCodeConfiguration = try values.decodeIfPresent(OpenCodeConfiguration.self, forKey: .openCodeConfiguration)
        piConfiguration = try values.decodeIfPresent(PiConfiguration.self, forKey: .piConfiguration)
        museConfiguration = try values.decodeIfPresent(MuseConfiguration.self, forKey: .museConfiguration)
        agentModeID = try values.decodeIfPresent(String.self, forKey: .agentModeID)
        agentConfigValues = try values.decodeIfPresent([String: String].self, forKey: .agentConfigValues)
        providerMetadata = try values.decodeIfPresent(JSONValue.self, forKey: .providerMetadata)
        providerActivity = try values.decodeIfPresent(ProviderActivity.self, forKey: .providerActivity)
        agentConfiguration = try values.decodeIfPresent([String: JSONValue].self, forKey: .agentConfiguration)
        draft = try values.decodeIfPresent(String.self, forKey: .draft) ?? ""
        draftAttachments = try values.decodeIfPresent([ChatAttachment].self, forKey: .draftAttachments) ?? []
        model = try values.decode(String.self, forKey: .model)
        reasoningEffort = try values.decodeIfPresent(String.self, forKey: .reasoningEffort)
        codexReasoningPreferences = try values.decodeIfPresent([String: String].self, forKey: .codexReasoningPreferences)
        codexModelSelectionSource = try values.decodeIfPresent(CodexModelSelectionSource.self, forKey: .codexModelSelectionSource)
        permission = try values.decode(PermissionMode.self, forKey: .permission)
        state = try values.decode(ThreadState.self, forKey: .state)
        messages = try values.decode([ChatMessage].self, forKey: .messages)
        queuedTurns = try values.decodeIfPresent([QueuedTurn].self, forKey: .queuedTurns) ?? []
        queuePaused = try values.decodeIfPresent(Bool.self, forKey: .queuePaused) ?? false
        activeRun = try values.decodeIfPresent(ActiveRun.self, forKey: .activeRun)
        runHistory = try values.decodeIfPresent([ThreadRunRecord].self, forKey: .runHistory)
        checkpointPolicy = try values.decodeIfPresent(RunCheckpointPolicy.self, forKey: .checkpointPolicy)
        forkedFromHistoryOperationID = try values.decodeIfPresent(UUID.self, forKey: .forkedFromHistoryOperationID)
        pullRequestCheckoutOperationID = try values.decodeIfPresent(UUID.self, forKey: .pullRequestCheckoutOperationID)
        runtimeID = try values.decodeIfPresent(UUID.self, forKey: .runtimeID)
        steeringCapabilityRevision = try values.decodeIfPresent(UInt64.self, forKey: .steeringCapabilityRevision)
        runtimeRequests = try values.decodeIfPresent([RuntimeRequest].self, forKey: .runtimeRequests) ?? []
        isPinned = try values.decode(Bool.self, forKey: .isPinned)
        isArchived = try values.decode(Bool.self, forKey: .isArchived)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
    }
    public var isBusy: Bool { activeRun != nil || state == .running || state == .awaitingApproval }
    public var providerName: String { provider == .acp ? acpAgent?.name ?? provider.name : provider.name }
}

public struct WorkspaceSnapshot: Codable, Sendable, Equatable {
    public var schemaVersion: Int = 1
    public var projects: [WorkspaceProject] = []
    public var threads: [CodingThread] = []
    public var acpAgents: [ACPAgentConfiguration] = []
    public var sidebarPreferences: SidebarPreferences?
    public var conversationHistoryOperations: [ConversationHistoryOperation]?
    public var pullRequestCreations: [PullRequestCreationOperation]?
    public var pullRequestCheckouts: [PullRequestCheckoutOperation]?
    public var promptSteerings: [PromptSteeringOperation]?
    public var checkpointRestoreOperations: [RunCheckpointRestoreOperation]?
    public init() {}
    enum CodingKeys: String, CodingKey { case schemaVersion, projects, threads, acpAgents, sidebarPreferences, conversationHistoryOperations, checkpointRestoreOperations, pullRequestCreations, pullRequestCheckouts, promptSteerings }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        projects = try values.decodeIfPresent([WorkspaceProject].self, forKey: .projects) ?? []
        threads = try values.decodeIfPresent([CodingThread].self, forKey: .threads) ?? []
        acpAgents = try values.decodeIfPresent([ACPAgentConfiguration].self, forKey: .acpAgents) ?? []
        sidebarPreferences = try values.decodeIfPresent(SidebarPreferences.self, forKey: .sidebarPreferences)
        conversationHistoryOperations = try values.decodeIfPresent([ConversationHistoryOperation].self, forKey: .conversationHistoryOperations)
        pullRequestCreations = try values.decodeIfPresent([PullRequestCreationOperation].self, forKey: .pullRequestCreations)
        pullRequestCheckouts = try values.decodeIfPresent([PullRequestCheckoutOperation].self, forKey: .pullRequestCheckouts)
        promptSteerings = try values.decodeIfPresent([PromptSteeringOperation].self, forKey: .promptSteerings)
        checkpointRestoreOperations = try values.decodeIfPresent([RunCheckpointRestoreOperation].self, forKey: .checkpointRestoreOperations)
    }
    /// A local process cannot survive an application restart. Never display stale work as running.
    public mutating func recoverInterruptedWork() {
        for i in (promptSteerings ?? []).indices {
            guard var operation = promptSteerings?[i] else { continue }
            if operation.isWorking {
                operation.fallbackAllowed = false
                operation.phase = operation.phase == .accepted ? .failed : .unconfirmed
                operation.error = operation.phase == .failed ? PromptSteeringOperation.failureMessage : PromptSteeringOperation.unconfirmedMessage
                operation.updatedAt = Date()
                if let t = threads.firstIndex(where: { $0.id == operation.threadID }),
                   let m = threads[t].messages.firstIndex(where: { $0.id == operation.messageID }) {
                    threads[t].messages[m].submissionError = operation.error
                    if operation.isUnconfirmed { threads[t].queuePaused = true }
                }
            }
            promptSteerings?[i] = operation
        }
        for i in (pullRequestCheckouts ?? []).indices {
            guard let phase = pullRequestCheckouts?[i].phase, phase == .accepted || phase == .dispatching else { continue }
            let failed = phase == .accepted || pullRequestCheckouts?[i].review.plan.isReadOnly == true
            pullRequestCheckouts?[i].phase = failed ? .failed : .unconfirmed
            pullRequestCheckouts?[i].error = failed ? PullRequestCheckoutOperation.failureMessage : PullRequestCheckoutOperation.unconfirmedMessage
            pullRequestCheckouts?[i].cancelRequested = false
            pullRequestCheckouts?[i].updatedAt = Date()
        }
        for i in (pullRequestCreations ?? []).indices {
            guard let phase = pullRequestCreations?[i].phase, phase == .accepted || phase == .dispatching else { continue }
            pullRequestCreations?[i].phase = phase == .accepted ? .failed : .unconfirmed
            pullRequestCreations?[i].error = phase == .accepted ? PullRequestCreationOperation.failureMessage : PullRequestCreationOperation.unconfirmedMessage
            pullRequestCreations?[i].updatedAt = Date()
        }
        for i in (checkpointRestoreOperations ?? []).indices {
            guard let phase = checkpointRestoreOperations?[i].phase, phase == .accepted || phase == .dispatching else { continue }
            checkpointRestoreOperations?[i].phase = phase == .accepted ? .failed : .unconfirmed
            checkpointRestoreOperations?[i].error = phase == .accepted ? RunCheckpointRestoreOperation.failureMessage : RunCheckpointRestoreOperation.unconfirmedMessage
            checkpointRestoreOperations?[i].updatedAt = Date()
        }
        for i in (conversationHistoryOperations ?? []).indices {
            guard var operation = conversationHistoryOperations?[i] else { continue }
            if operation.phase == .accepted || operation.phase == .dispatching {
                let accepted = operation.phase == .accepted
                operation.phase = accepted ? .failed : .unconfirmed
                operation.error = accepted ? ConversationHistoryOperation.failureMessage : ConversationHistoryOperation.unconfirmedMessage
                operation.updatedAt = Date()
            }
            if operation.phase == .applied, var files = operation.files,
               files.phase == .accepted || files.phase == .dispatching {
                let accepted = files.phase == .accepted
                files.phase = accepted ? .failed : .unconfirmed
                files.error = accepted ? ConversationHistoryFilesState.notStartedMessage : ConversationHistoryFilesState.unconfirmedMessage
                files.updatedAt = Date(); operation.files = files; operation.updatedAt = files.updatedAt
            }
            conversationHistoryOperations?[i] = operation
        }
        for i in projects.indices {
            guard var clone = projects[i].clone, clone.isRunning else { continue }
            clone.phase = .interrupted; clone.cancelRequested = false; clone.progress.stalled = false
            clone.error = "The app closed during cloning. Retry when you are ready; existing files are preserved."
            projects[i].clone = clone
        }
        for i in threads.indices {
            for j in (threads[i].runHistory ?? []).indices {
                guard var checkpoints = threads[i].runHistory?[j].checkpoints else { continue }
                if checkpoints.baseline.phase.isRunning {
                    checkpoints.baseline.phase = .interrupted; checkpoints.baseline.error = ThreadRunCheckpointAttempt.interruptedMessage
                    checkpoints.baseline.updatedAt = Date()
                }
                if var post = checkpoints.postRun, post.phase.isRunning {
                    post.phase = .interrupted; post.error = ThreadRunCheckpointAttempt.interruptedMessage; post.updatedAt = Date()
                    checkpoints.postRun = post; threads[i].queuePaused = true
                }
                checkpoints.pendingStart = nil
                threads[i].runHistory?[j].checkpoints = checkpoints
            }
            if var settlement = threads[i].settlement {
                if var run = settlement.script, [.discovering, .starting, .running, .stopping].contains(run.phase) {
                    let provenSuccess = run.phase == .stopping && run.pendingAction == .cancel && run.commandExit == .exited(0)
                    run.phase = provenSuccess ? .succeeded : .interrupted; run.pendingAction = nil
                    run.error = provenSuccess ? nil : ThreadProjectScriptRun.settleInterruptedError
                    run.updatedAt = Date(); run.endedAt = Date(); settlement.script = run
                }
                settlement.phase = .settled; threads[i].settlement = settlement; threads[i].queuePaused = true
            }
            if var preparation = threads[i].workspacePreparation, var setup = preparation.setup,
               [.discovering, .starting, .running, .stopping].contains(setup.phase) {
                let provenSuccess = setup.phase == .stopping && setup.pendingAction == .cancel && setup.commandExit == .exited(0)
                setup.phase = provenSuccess ? .succeeded : .interrupted; setup.pendingAction = nil
                setup.error = provenSuccess ? nil : ThreadProjectScriptRun.interruptedError
                setup.updatedAt = Date(); setup.endedAt = Date(); preparation.setup = setup
                threads[i].workspacePreparation = preparation; threads[i].queuePaused = true
            }
            if var preparation = threads[i].workspacePreparation, preparation.isRunning {
                preparation.phase = .interrupted; preparation.cancelRequested = false
                preparation.error = "The app closed during workspace preparation. Retry when ready; existing files are preserved."
                threads[i].workspacePreparation = preparation; threads[i].queuePaused = true
            }
            if threads[i].isBusy {
                threads[i].finishRunRecord(status: .interrupted, reason: .applicationClosed, now: Date())
                threads[i].state = .interrupted
                threads[i].appendRunMessage(role: .system, text: "The app closed during this turn. Resume by sending another message.")
            }
            threads[i].activeRun = nil; threads[i].runtimeID = nil; threads[i].runtimeRequests = []
            threads[i].providerActivity = nil
            if !threads[i].queuedTurns.isEmpty { threads[i].queuePaused = true }
        }
    }
}

public struct ApprovalRequest: Identifiable, Codable, Sendable, Equatable {
    public var id: JSONValue
    public var method: String
    public var params: JSONValue
    public var isQuestion: Bool { method == "muse/userInput" || method == "opencode/form" || method == "opencode/question" || GrokACP.questionMethod(method) || method == "item/tool/requestUserInput" || (method == "can_use_tool" && params["tool_name"].string == "AskUserQuestion") || CursorACPMethod.canonical(method) == CursorACPMethod.question }
    public var openCodeForm: OpenCodeV2Form? { try? OpenCodeV2Form.presentation(self) }
    public var openCodeQuestion: OpenCodeV1Question? { try? OpenCodeV1Question.presentation(self) }
    public var grokQuestion: GrokACPQuestionRequest? { GrokACP.questionMethod(method) ? try? .init(params: params) : nil }
    public var isGrokQuestion: Bool { GrokACP.questionMethod(method) }
    public var piExtension: PiExtensionRequest? { try? PiExtensionRequest.presentation(self) }
    public var museApproval: MuseApprovalRequest? { try? MuseApprovalRequest.presentation(self) }
    public var museUserInput: MuseUserInputRequest? { try? MuseUserInputRequest.presentation(self) }
    public var questions: [JSONValue] {
        if method == "can_use_tool" {
            return (params["input"]["questions"].array ?? []).map { question in
                var item = question.object ?? [:]
                item["id"] = question["question"]
                return .object(item)
            }
        }
        return params["questions"].array ?? []
    }
    public var title: String {
        if method == "muse/approval" { return museApproval?.title ?? "Muse needs your approval" }
        if method == "muse/userInput" { return "Answer Muse questions" }
        if method == "pi/extension" { return piExtension?.title ?? "Pi needs your input" }
        if method == "opencode/question" { return "Answer OpenCode questions" }
        if GrokACP.questionMethod(method) { return "Answer Grok questions" }
        if method == "opencode/form" || method == "opencode/permission" { return params["title"].string ?? "OpenCode needs your input" }
        if let question = cursorQuestion { return question.title ?? "Answer Cursor questions" }
        if let plan = cursorPlan { return plan.name ?? "Review Cursor plan" }
        if method == "session/request_permission" { return params["title"].string ?? params["toolCall"]["title"].string ?? "Approve agent tool" }
        if method == "can_use_tool" { return "Approve \(params["tool_name"].string ?? "tool")" }
        return method.contains("fileChange") ? "Approve file changes" : "Approve command"
    }
    public var detail: String {
        if method == "muse/approval" { return museApproval?.detail ?? "Review Muse's request." }
        if method == "pi/extension" { return piExtension?.message ?? "Review Pi's request." }
        if method == "opencode/permission" { return params["description"].string ?? "Review the requested action." }
        if let plan = cursorPlan { return plan.plan }
        if method == "session/request_permission" {
            if params.object?["subject"] != nil { return [params["description"].string, params["subject"].pretty].compactMap { $0 }.joined(separator: "\n") }
            return params["description"].string ?? params["toolCall"]["rawInput"].pretty
        }
        if method == "can_use_tool" { return params["input"]["command"].string ?? params["input"].pretty }
        return params["command"].string ?? params["reason"].string ?? params.pretty
    }
}

extension JSONValue: Hashable {
    public func hash(into hasher: inout Hasher) {
        // Protocol request ids are strings or numbers. Encoding also gives all other values a stable hash.
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]
        hasher.combine(try? e.encode(self))
    }
}
