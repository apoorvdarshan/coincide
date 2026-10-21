import Foundation

public struct WorkspaceProject: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var path: String
    public init(path: String) {
        self.id = UUID()
        let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        self.path = url.path; self.name = url.lastPathComponent
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
    public init(id: String = UUID().uuidString, role: MessageRole, text: String) {
        self.id = id; self.role = role; self.text = text; self.createdAt = Date()
    }
}

public struct CodingThread: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    public var projectID: UUID
    public var title: String
    public var workspacePath: String
    public var providerThreadID: String?
    public var model: String
    public var permission: PermissionMode
    public var state: ThreadState
    public var messages: [ChatMessage]
    public var isPinned: Bool
    public var isArchived: Bool
    public var createdAt: Date
    public var updatedAt: Date
    public init(project: WorkspaceProject, model: String = "") {
        id = UUID(); projectID = project.id; title = "New thread"; workspacePath = project.path
        self.model = model; permission = .supervised; state = .idle; messages = []
        isPinned = false; isArchived = false; createdAt = Date(); updatedAt = Date()
    }
}

public struct WorkspaceSnapshot: Codable, Sendable, Equatable {
    public var schemaVersion: Int = 1
    public var projects: [WorkspaceProject] = []
    public var threads: [CodingThread] = []
    public init() {}
    /// A local process cannot survive an application restart. Never display stale work as running.
    public mutating func recoverInterruptedWork() {
        for i in threads.indices where threads[i].state == .running || threads[i].state == .awaitingApproval {
            threads[i].state = .interrupted
            threads[i].messages.append(.init(role: .system, text: "The app closed during this turn. Resume by sending another message."))
        }
    }
}

public struct ProviderModel: Identifiable, Sendable, Equatable {
    public var id: String
    public var name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}

public struct ApprovalRequest: Identifiable, Sendable {
    public var id: JSONValue
    public var method: String
    public var params: JSONValue
    public var title: String { method.contains("fileChange") ? "Approve file changes" : "Approve command" }
    public var detail: String {
        params["command"].string ?? params["reason"].string ?? params.pretty
    }
}

extension JSONValue: Hashable {
    public func hash(into hasher: inout Hasher) {
        // Protocol request ids are strings or numbers. Encoding also gives all other values a stable hash.
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]
        hasher.combine(try? e.encode(self))
    }
}
