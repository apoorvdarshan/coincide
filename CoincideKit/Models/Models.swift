import Foundation

/// A coding agent Coincide can drive. Each one is a CLI the user installs and signs in to
/// with their own subscription; Coincide never sells or proxies tokens.
public enum ProviderKind: String, Codable, CaseIterable, Sendable, Hashable {
    case claude
    case codex
    case cursor
    case grok
    case opencode
    case pi
    case antigravity

    public nonisolated var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .cursor: "Cursor"
        case .grok: "Grok Build"
        case .opencode: "OpenCode"
        case .pi: "Pi"
        case .antigravity: "Antigravity"
        }
    }

    /// SF Symbol used in menus and the sidebar.
    public nonisolated var symbolName: String {
        switch self {
        case .claude: "sparkle"
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .cursor: "cursorarrow.rays"
        case .grok: "bolt.horizontal"
        case .opencode: "terminal"
        case .pi: "p.circle"
        case .antigravity: "arrow.up.and.down.and.sparkles"
        }
    }
}

public struct ModelOption: Codable, Hashable, Sendable, Identifiable {
    public var provider: ProviderKind
    /// The id passed to the provider CLI.
    public var modelID: String
    public var displayName: String
    /// Reasoning efforts the model accepts, in increasing order. Empty when it has no setting.
    public var efforts: [String]
    public var defaultEffort: String?
    /// Context window in tokens, when the provider reports it.
    public var contextWindow: Int?
    /// Whether the model accepts image input.
    public var supportsImages: Bool

    public nonisolated var id: String { "\(provider.rawValue)/\(modelID)" }

    public nonisolated init(
        provider: ProviderKind, modelID: String, displayName: String, efforts: [String] = [],
        defaultEffort: String? = nil, contextWindow: Int? = nil, supportsImages: Bool = true
    ) {
        self.provider = provider
        self.modelID = modelID
        self.displayName = displayName
        self.efforts = efforts
        self.defaultEffort = defaultEffort
        self.contextWindow = contextWindow
        self.supportsImages = supportsImages
    }
}

/// How much the agent may do without asking.
public enum AccessMode: String, Codable, CaseIterable, Sendable {
    /// Runs commands and edits files without asking.
    case fullAccess
    /// Asks before commands and file edits.
    case approval

    public nonisolated var displayName: String {
        switch self {
        case .fullAccess: String(localized: "Full access")
        case .approval: String(localized: "Ask for approval")
        }
    }
}

/// Whether a turn should act or only plan.
public enum InteractionMode: String, Codable, CaseIterable, Sendable {
    case build
    case plan

    public nonisolated var displayName: String {
        switch self {
        case .build: String(localized: "Build")
        case .plan: String(localized: "Plan")
        }
    }
}

public struct ModelSelection: Codable, Hashable, Sendable {
    public var provider: ProviderKind
    public var modelID: String
    public var effort: String?

    public nonisolated init(provider: ProviderKind, modelID: String, effort: String? = nil) {
        self.provider = provider
        self.modelID = modelID
        self.effort = effort
    }
}

public struct Project: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var path: String
    public var createdAt: Date
    public var isExpanded: Bool

    public nonisolated init(id: UUID = UUID(), name: String, path: String, createdAt: Date = Date(), isExpanded: Bool = true) {
        self.id = id
        self.name = name
        self.path = path
        self.createdAt = createdAt
        self.isExpanded = isExpanded
    }

    public nonisolated var url: URL { URL(fileURLWithPath: path) }
}

public enum ToolCategory: String, Codable, Sendable {
    case command
    case fileChange
    case read
    case search
    case web
    case mcp
    case task
    case todo
    case other

    public nonisolated var symbolName: String {
        switch self {
        case .command: "terminal"
        case .fileChange: "pencil.line"
        case .read: "doc.text"
        case .search: "magnifyingglass"
        case .web: "globe"
        case .mcp: "puzzlepiece.extension"
        case .task: "person.2"
        case .todo: "checklist"
        case .other: "wrench.and.screwdriver"
        }
    }
}

public enum ItemStatus: String, Codable, Sendable {
    case running
    case completed
    case failed
    case declined
    case waiting
}

public struct ApprovalOption: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case allowOnce
        case allowAlways
        case deny
        case cancel
    }

    /// The provider's own id for this choice.
    public var id: String
    public var label: String
    public var kind: Kind

    public nonisolated init(id: String, label: String, kind: Kind) {
        self.id = id
        self.label = label
        self.kind = kind
    }
}

public struct ApprovalInfo: Codable, Hashable, Sendable {
    public var requestID: String
    public var options: [ApprovalOption]
    /// Label of the option the user picked, or a note when the agent resolved it.
    public var resolution: String?

    public nonisolated init(requestID: String, options: [ApprovalOption], resolution: String? = nil) {
        self.requestID = requestID
        self.options = options
        self.resolution = resolution
    }
}

/// One entry in a thread's timeline.
///
/// Field use by kind:
/// - user: `text` is the message, `attachments` holds image paths.
/// - assistant / reasoning / plan / error / notice: `text` is the (markdown) body.
/// - tool: `title` is a short label, `detail` the input (full command, diff, JSON), `text` the output.
/// - approval: `title`/`detail` describe the request, `approval` holds the choices.
public struct TranscriptItem: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case user
        case assistant
        case reasoning
        case tool
        case approval
        case plan
        case error
        case notice
    }

    public var id: UUID
    public var kind: Kind
    public var text: String
    public var title: String?
    public var detail: String?
    public var category: ToolCategory?
    public var status: ItemStatus?
    public var provider: ProviderKind?
    public var modelID: String?
    /// The provider's id for the item, used to apply streamed updates.
    public var externalID: String?
    public var approval: ApprovalInfo?
    public var attachments: [String]?
    public var createdAt: Date
    public var completedAt: Date?

    public nonisolated init(
        id: UUID = UUID(), kind: Kind, text: String = "", title: String? = nil, detail: String? = nil,
        category: ToolCategory? = nil, status: ItemStatus? = nil, provider: ProviderKind? = nil,
        modelID: String? = nil, externalID: String? = nil, approval: ApprovalInfo? = nil, attachments: [String]? = nil,
        createdAt: Date = Date(), completedAt: Date? = nil
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.title = title
        self.detail = detail
        self.category = category
        self.status = status
        self.provider = provider
        self.modelID = modelID
        self.externalID = externalID
        self.approval = approval
        self.attachments = attachments
        self.createdAt = createdAt
        self.completedAt = completedAt
    }
}

/// A provider's native session for a thread, and how much of the transcript it has seen.
public struct ProviderSessionRef: Codable, Hashable, Sendable {
    public var sessionID: String
    /// Number of transcript items that existed when this session last finished a turn.
    public var seenItemCount: Int

    public nonisolated init(sessionID: String, seenItemCount: Int) {
        self.sessionID = sessionID
        self.seenItemCount = seenItemCount
    }
}

public struct ChatThread: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var projectID: UUID
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var selection: ModelSelection
    public var accessMode: AccessMode
    public var interactionMode: InteractionMode
    public var items: [TranscriptItem]
    public var sessions: [ProviderKind: ProviderSessionRef]
    public var isPinned: Bool
    public var isArchived: Bool
    /// Working directory when the thread runs in its own git worktree.
    public var worktreePath: String?
    public var branch: String?
    /// Unsent composer text, restored when the thread is reopened.
    public var draft: String?

    public nonisolated init(
        id: UUID = UUID(), projectID: UUID, title: String = String(localized: "New thread"),
        selection: ModelSelection, accessMode: AccessMode = .fullAccess, interactionMode: InteractionMode = .build,
        items: [TranscriptItem] = [], sessions: [ProviderKind: ProviderSessionRef] = [:], isPinned: Bool = false,
        isArchived: Bool = false, worktreePath: String? = nil, branch: String? = nil, draft: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.projectID = projectID
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.selection = selection
        self.accessMode = accessMode
        self.interactionMode = interactionMode
        self.items = items
        self.sessions = sessions
        self.isPinned = isPinned
        self.isArchived = isArchived
        self.worktreePath = worktreePath
        self.branch = branch
        self.draft = draft
    }

    public nonisolated var hasUserMessages: Bool { items.contains { $0.kind == .user } }

    public nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        projectID = try container.decode(UUID.self, forKey: .projectID)
        title = try container.decode(String.self, forKey: .title)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        selection = try container.decode(ModelSelection.self, forKey: .selection)
        accessMode = try container.decodeIfPresent(AccessMode.self, forKey: .accessMode) ?? .fullAccess
        interactionMode = try container.decodeIfPresent(InteractionMode.self, forKey: .interactionMode) ?? .build
        items = try container.decodeIfPresent([TranscriptItem].self, forKey: .items) ?? []
        sessions = try container.decodeIfPresent([ProviderKind: ProviderSessionRef].self, forKey: .sessions) ?? [:]
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        isArchived = try container.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
        worktreePath = try container.decodeIfPresent(String.self, forKey: .worktreePath)
        branch = try container.decodeIfPresent(String.self, forKey: .branch)
        draft = try container.decodeIfPresent(String.self, forKey: .draft)
    }
}
