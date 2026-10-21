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
    public var providerThreadID: String?
    public var provider: ProviderKind
    public var acpAgent: ACPAgentConfiguration?
    public var agentModeID: String?
    public var agentConfigValues: [String: String]?
    public var providerMetadata: JSONValue?
    public var providerActivity: ProviderActivity?
    public var agentConfiguration: [String: JSONValue]?
    public var draft: String
    public var draftAttachments: [ChatAttachment]
    public var model: String
    public var permission: PermissionMode
    public var state: ThreadState
    public var messages: [ChatMessage]
    public var queuedTurns: [QueuedTurn]
    public var queuePaused: Bool
    public var activeRun: ActiveRun?
    public var runtimeID: UUID?
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
        case queuedTurns, queuePaused, activeRun, runtimeID, runtimeRequests, workspacePreparation
        case draftAttachments
        case acpAgent, agentModeID, agentConfigValues, providerMetadata
        case providerActivity, agentConfiguration
    }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        projectID = try values.decode(UUID.self, forKey: .projectID)
        title = try values.decode(String.self, forKey: .title)
        workspacePath = try values.decode(String.self, forKey: .workspacePath)
        workspacePreparation = try values.decodeIfPresent(ThreadWorkspacePreparation.self, forKey: .workspacePreparation)
        providerThreadID = try values.decodeIfPresent(String.self, forKey: .providerThreadID)
        provider = try values.decodeIfPresent(ProviderKind.self, forKey: .provider) ?? .codex
        acpAgent = try values.decodeIfPresent(ACPAgentConfiguration.self, forKey: .acpAgent)
        agentModeID = try values.decodeIfPresent(String.self, forKey: .agentModeID)
        agentConfigValues = try values.decodeIfPresent([String: String].self, forKey: .agentConfigValues)
        providerMetadata = try values.decodeIfPresent(JSONValue.self, forKey: .providerMetadata)
        providerActivity = try values.decodeIfPresent(ProviderActivity.self, forKey: .providerActivity)
        agentConfiguration = try values.decodeIfPresent([String: JSONValue].self, forKey: .agentConfiguration)
        draft = try values.decodeIfPresent(String.self, forKey: .draft) ?? ""
        draftAttachments = try values.decodeIfPresent([ChatAttachment].self, forKey: .draftAttachments) ?? []
        model = try values.decode(String.self, forKey: .model)
        permission = try values.decode(PermissionMode.self, forKey: .permission)
        state = try values.decode(ThreadState.self, forKey: .state)
        messages = try values.decode([ChatMessage].self, forKey: .messages)
        queuedTurns = try values.decodeIfPresent([QueuedTurn].self, forKey: .queuedTurns) ?? []
        queuePaused = try values.decodeIfPresent(Bool.self, forKey: .queuePaused) ?? false
        activeRun = try values.decodeIfPresent(ActiveRun.self, forKey: .activeRun)
        runtimeID = try values.decodeIfPresent(UUID.self, forKey: .runtimeID)
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
    public init() {}
    enum CodingKeys: String, CodingKey { case schemaVersion, projects, threads, acpAgents, sidebarPreferences }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        projects = try values.decodeIfPresent([WorkspaceProject].self, forKey: .projects) ?? []
        threads = try values.decodeIfPresent([CodingThread].self, forKey: .threads) ?? []
        acpAgents = try values.decodeIfPresent([ACPAgentConfiguration].self, forKey: .acpAgents) ?? []
        sidebarPreferences = try values.decodeIfPresent(SidebarPreferences.self, forKey: .sidebarPreferences)
    }
    /// A local process cannot survive an application restart. Never display stale work as running.
    public mutating func recoverInterruptedWork() {
        for i in projects.indices {
            guard var clone = projects[i].clone, clone.isRunning else { continue }
            clone.phase = .interrupted; clone.cancelRequested = false; clone.progress.stalled = false
            clone.error = "The app closed during cloning. Retry when you are ready; existing files are preserved."
            projects[i].clone = clone
        }
        for i in threads.indices {
            if var preparation = threads[i].workspacePreparation, preparation.isRunning {
                preparation.phase = .interrupted; preparation.cancelRequested = false
                preparation.error = "The app closed during workspace preparation. Retry when ready; existing files are preserved."
                threads[i].workspacePreparation = preparation; threads[i].queuePaused = true
            }
            if threads[i].isBusy {
                threads[i].state = .interrupted
                threads[i].messages.append(.init(role: .system, text: "The app closed during this turn. Resume by sending another message."))
            }
            threads[i].activeRun = nil; threads[i].runtimeID = nil; threads[i].runtimeRequests = []
            threads[i].providerActivity = nil
            if !threads[i].queuedTurns.isEmpty { threads[i].queuePaused = true }
        }
    }
}

public struct ProviderModel: Identifiable, Sendable, Equatable {
    public var id: String
    public var name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}

public struct ApprovalRequest: Identifiable, Codable, Sendable, Equatable {
    public var id: JSONValue
    public var method: String
    public var params: JSONValue
    public var isQuestion: Bool { method == "item/tool/requestUserInput" || (method == "can_use_tool" && params["tool_name"].string == "AskUserQuestion") }
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
        if method == "session/request_permission" { return params["title"].string ?? params["toolCall"]["title"].string ?? "Approve agent tool" }
        if method == "can_use_tool" { return "Approve \(params["tool_name"].string ?? "tool")" }
        return method.contains("fileChange") ? "Approve file changes" : "Approve command"
    }
    public var detail: String {
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
