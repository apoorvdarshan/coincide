import Foundation
import Synchronization

/// A coding agent Coincide can drive. Each one is a CLI the user installs and signs in to
/// with their own subscription; Coincide never sells or proxies tokens.
///
/// The built-in agents are fixed cases. `acp` is an agent the user added (T3 Code's `acpRegistry` provider
/// instances): a local ACP command or an agent from the ACP Registry, keyed by its stable instance ID, with its
/// settings in `AppSettings.acpAgents`. Every kind is written as one string (`claude`, `acp:devin`), so threads and
/// settings written before custom agents existed read as they always did, and a build that doesn't know `acp:` skips
/// such entries as it skips any unknown provider.
public enum ProviderKind: RawRepresentable, Codable, CaseIterable, Sendable, Hashable {
    case claude
    case codex
    case cursor
    case grok
    case opencode
    case pi
    case antigravity
    /// Vercel's fx (`fx acp`).
    case fx
    /// Meta's Muse Code (`muse serve`).
    case muse
    /// A user-added ACP agent, by its instance ID (`ACPAgentConfig.id`).
    case acp(String)

    /// The built-in agents, in display order. Custom ACP agents come from settings.
    public nonisolated static let allCases: [ProviderKind] = [
        .claude, .codex, .cursor, .grok, .opencode, .pi, .antigravity, .fx, .muse,
    ]

    /// What starts a custom agent's raw value.
    public nonisolated static let acpPrefix = "acp:"

    public nonisolated init?(rawValue: String) {
        if rawValue.hasPrefix(Self.acpPrefix) {
            let id = String(rawValue.dropFirst(Self.acpPrefix.count))
            guard Self.isValidACPAgentID(id) else { return nil }
            self = .acp(id)
            return
        }
        guard let kind = Self.allCases.first(where: { $0.rawValue == rawValue }) else { return nil }
        self = kind
    }

    public nonisolated var rawValue: String {
        switch self {
        case .claude: "claude"
        case .codex: "codex"
        case .cursor: "cursor"
        case .grok: "grok"
        case .opencode: "opencode"
        case .pi: "pi"
        case .antigravity: "antigravity"
        case .fx: "fx"
        case .muse: "muse"
        case .acp(let id): Self.acpPrefix + id
        }
    }

    public nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let kind = ProviderKind(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown provider \(raw)")
        }
        self = kind
    }

    public nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// Whether `id` can name a custom ACP agent: lowercase letters, digits, `.`, `_` and `-`, starting with a letter or
    /// digit, at most 64 characters, so it is safe in a raw value, a file name and a `/` command.
    public nonisolated static func isValidACPAgentID(_ id: String) -> Bool {
        id.utf8.count <= 64 && id.range(of: #"^[a-z0-9][a-z0-9._-]*$"#, options: .regularExpression) != nil
    }

    /// The instance ID of a custom ACP agent; nil for the built-in agents.
    public nonisolated var acpAgentID: String? {
        if case .acp(let id) = self { return id }
        return nil
    }

    public nonisolated var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .cursor: "Cursor"
        case .grok: "Grok Build"
        case .opencode: "OpenCode"
        case .pi: "Pi"
        case .antigravity: "Antigravity"
        case .fx: "fx"
        case .muse: "Muse Code"
        // The name the user gave it, also for a thread that outlived the agent (until Coincide quits).
        case .acp(let id): ACPAgentNames.shared.name(for: id) ?? id
        }
    }

    /// Whether the provider is on before the user changes its setting. Muse Code starts off, as in T3 Code.
    public nonisolated var isEnabledByDefault: Bool { self != .muse }

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
        case .fx: "fx"
        case .muse: "infinity"
        case .acp: "point.3.connected.trianglepath.dotted"
        }
    }

    /// The access modes the agent can run in, in menu order (T3 Code's `supportedRuntimeModes`). fx asks before it
    /// changes anything and has no full access. A user-added ACP agent takes both: Coincide answers its approvals by
    /// the thread's mode, as T3 Code answers a registry agent's.
    public nonisolated var accessModes: [AccessMode] {
        self == .fx ? [.approval] : AccessMode.allCases
    }

    /// The access mode a thread set to `mode` runs in: one the agent does not offer runs as Ask for approval, as T3
    /// Code runs it Supervised.
    public nonisolated func accessMode(for mode: AccessMode) -> AccessMode {
        accessModes.contains(mode) ? mode : .approval
    }

    /// Whether the agent has a plan mode (T3 Code's `showInteractionModeToggle`). fx and Muse Code have none. A
    /// user-added ACP agent has one: its own plan mode when it offers one, otherwise plan-mode instructions.
    public nonisolated var supportsPlanMode: Bool { self != .fx && self != .muse }

    /// The interaction mode a thread set to `mode` runs in: without a plan mode, the agent builds.
    public nonisolated func interactionMode(for mode: InteractionMode) -> InteractionMode {
        supportsPlanMode ? mode : .build
    }

    /// Whether Coincide may ask the agent for commit messages, branch names and pull request text (T3 Code's
    /// `supportsTextGeneration`). fx saves every `fx acp` session under `~/.fx` and ACP cannot delete one, so each
    /// request would leave a session behind. User-added ACP agents never write them, as T3 Code doesn't use registry
    /// instances for its own text generation.
    public nonisolated var supportsTextGeneration: Bool { self != .fx && acpAgentID == nil }

    /// The composer command that switches a thread to this agent, without its slash: `codex`, or a custom agent's
    /// instance ID (`ACPAgentConfig.makeID` keeps those clear of the built-in names).
    public nonisolated var commandName: String { acpAgentID ?? rawValue }

    /// The ACP Registry's ids for agents Coincide drives as built-in providers, which the registry search leaves out
    /// as T3 Code does (each provider client's `acpRegistryAgentIds`).
    public nonisolated var registryAgentIDs: [String] {
        switch self {
        case .claude: ["claude-acp"]
        case .codex: ["codex-acp"]
        case .cursor: ["cursor"]
        case .grok: ["grok-build"]
        case .opencode: ["opencode", "opencode-v2"]
        case .pi: ["pi-acp"]
        case .antigravity: ["antigravity-acp"]
        case .fx, .muse, .acp: []
        }
    }
}

/// The names of the custom ACP agents, for `ProviderKind.displayName`, which has no access to settings. `AppStore`
/// adds every agent's name whenever settings load or change. Names are only added or replaced, never removed, so a
/// thread of an agent the user removed keeps its name until Coincide quits.
public final class ACPAgentNames: Sendable {
    public static let shared = ACPAgentNames()

    private let names = Mutex<[String: String]>([:])

    public nonisolated func name(for id: String) -> String? {
        names.withLock { $0[id] }
    }

    /// Adds or replaces names, by instance ID.
    public nonisolated func register(_ added: [String: String]) {
        names.withLock { names in names.merge(added) { $1 } }
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

    public nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        path = try container.decode(String.self, forKey: .path)
        name = container.lenient(String.self, forKey: .name) ?? (path as NSString).lastPathComponent
        createdAt = container.lenient(Date.self, forKey: .createdAt) ?? .distantPast
        isExpanded = container.lenient(Bool.self, forKey: .isExpanded) ?? true
    }
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

/// A text field shown with an approval, for agents that want typed input along with the choice.
public struct TextInputSpec: Codable, Hashable, Sendable {
    public var placeholder: String?
    public var initialText: String?
    public var isMultiline: Bool

    public nonisolated init(placeholder: String? = nil, initialText: String? = nil, isMultiline: Bool = false) {
        self.placeholder = placeholder
        self.initialText = initialText
        self.isMultiline = isMultiline
    }
}

public struct ApprovalInfo: Codable, Hashable, Sendable {
    public var requestID: String
    public var options: [ApprovalOption]
    /// Label of the option the user picked, or a note when the agent resolved it.
    public var resolution: String?
    public var textInput: TextInputSpec?
    /// Text the user sent with their choice.
    public var responseText: String?

    public nonisolated init(
        requestID: String, options: [ApprovalOption], resolution: String? = nil, textInput: TextInputSpec? = nil,
        responseText: String? = nil
    ) {
        self.requestID = requestID
        self.options = options
        self.resolution = resolution
        self.textInput = textInput
        self.responseText = responseText
    }
}

/// One question an agent asks the user.
public struct UserQuestion: Codable, Hashable, Sendable, Identifiable {
    public struct Option: Codable, Hashable, Sendable {
        public var label: String
        public var detail: String?

        public nonisolated init(label: String, detail: String? = nil) {
            self.label = label
            self.detail = detail
        }
    }

    public var id: String
    /// Short label, e.g. "Database".
    public var header: String?
    public var prompt: String
    public var options: [Option]
    public var allowsMultipleSelection: Bool
    /// Whether the user may type their own answer instead of (or besides) picking an option.
    public var allowsFreeText: Bool
    /// The answer should be entered in a secure field and not echoed into the transcript.
    public var isSecret: Bool

    public nonisolated init(
        id: String, header: String? = nil, prompt: String, options: [Option] = [], allowsMultipleSelection: Bool = false,
        allowsFreeText: Bool = true, isSecret: Bool = false
    ) {
        self.id = id
        self.header = header
        self.prompt = prompt
        self.options = options
        self.allowsMultipleSelection = allowsMultipleSelection
        self.allowsFreeText = allowsFreeText
        self.isSecret = isSecret
    }
}

/// A set of questions an agent asks in one go.
public struct UserInputRequest: Codable, Hashable, Sendable {
    /// Id the session needs back in `answer(userInput:answers:)`.
    public var id: String
    public var title: String?
    public var questions: [UserQuestion]

    public nonisolated init(id: String, title: String? = nil, questions: [UserQuestion]) {
        self.id = id
        self.title = title
        self.questions = questions
    }
}

/// One entry in a thread's timeline.
///
/// Field use by kind:
/// - user: `text` is the message, `attachments` holds image paths, `steered` marks one sent into a running turn.
/// - assistant / reasoning / plan / error / notice: `text` is the (markdown) body.
/// - tool: `title` is a short label, `detail` the input (full command, diff, JSON), `text` the output.
/// - approval: `title`/`detail` describe the request, `approval` holds the choices.
/// - question: `questions` holds what the agent asked, `answers` what the user replied (question id → values).
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
        case question
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
    public var questions: UserInputRequest?
    public var answers: [String: [String]]?
    public var attachments: [String]?
    /// True for a message the user sent into a running turn (T3 Code's steer), which belongs to that turn rather
    /// than opening one of its own. Nil for everything else, so other items are written as before.
    public var steered: Bool?
    public var createdAt: Date
    public var completedAt: Date?

    public nonisolated init(
        id: UUID = UUID(), kind: Kind, text: String = "", title: String? = nil, detail: String? = nil,
        category: ToolCategory? = nil, status: ItemStatus? = nil, provider: ProviderKind? = nil,
        modelID: String? = nil, externalID: String? = nil, approval: ApprovalInfo? = nil,
        questions: UserInputRequest? = nil, answers: [String: [String]]? = nil, attachments: [String]? = nil,
        steered: Bool? = nil, createdAt: Date = Date(), completedAt: Date? = nil
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
        self.questions = questions
        self.answers = answers
        self.attachments = attachments
        self.steered = steered
        self.createdAt = createdAt
        self.completedAt = completedAt
    }

    /// Whether the user sent this message into a running turn (`steered`).
    public nonisolated var isSteered: Bool { steered == true }

    /// Whether this is a message of the user's that opens a turn: any of theirs but one steered into a running turn.
    /// (The app also starts a turn at the notice of one an agent started on its own.)
    public nonisolated var opensUserTurn: Bool { kind == .user && !isSteered }

    /// Only the id and kind are required; a field this version cannot read (a status or category added
    /// later, say) is left empty rather than failing the item.
    public nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        kind = try container.decode(Kind.self, forKey: .kind)
        text = container.lenient(String.self, forKey: .text) ?? ""
        title = container.lenient(String.self, forKey: .title)
        detail = container.lenient(String.self, forKey: .detail)
        category = container.lenient(ToolCategory.self, forKey: .category)
        status = container.lenient(ItemStatus.self, forKey: .status)
        provider = container.lenient(ProviderKind.self, forKey: .provider)
        modelID = container.lenient(String.self, forKey: .modelID)
        externalID = container.lenient(String.self, forKey: .externalID)
        approval = container.lenient(ApprovalInfo.self, forKey: .approval)
        questions = container.lenient(UserInputRequest.self, forKey: .questions)
        answers = container.lenient([String: [String]].self, forKey: .answers)
        attachments = container.lenient([String].self, forKey: .attachments)
        steered = container.lenient(Bool.self, forKey: .steered)
        createdAt = container.lenient(Date.self, forKey: .createdAt) ?? .distantPast
        completedAt = container.lenient(Date.self, forKey: .completedAt)
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

    /// A negative count, which only a damaged file could hold, loads as 0 (nothing seen).
    public nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try container.decode(String.self, forKey: .sessionID)
        seenItemCount = max(try container.decode(Int.self, forKey: .seenItemCount), 0)
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

    /// Only the id and project are required; anything else this version cannot read falls back to a
    /// default (items it cannot read are left out), so a thread is never lost to one bad field.
    public nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        projectID = try container.decode(UUID.self, forKey: .projectID)
        title = container.lenient(String.self, forKey: .title) ?? String(localized: "New thread")
        createdAt = container.lenient(Date.self, forKey: .createdAt) ?? .distantPast
        updatedAt = container.lenient(Date.self, forKey: .updatedAt) ?? createdAt
        selection =
            container.lenient(ModelSelection.self, forKey: .selection) ?? ModelSelection(provider: .claude, modelID: "default")
        // An unreadable mode (for example one a newer build added) fails closed.
        accessMode = container.lenient(AccessMode.self, forKey: .accessMode) ?? .approval
        interactionMode = container.lenient(InteractionMode.self, forKey: .interactionMode) ?? .build
        items = container.lenientArray(TranscriptItem.self, forKey: .items)
        sessions = container.lenientProviderMap(ProviderSessionRef.self, forKey: .sessions)
        isPinned = container.lenient(Bool.self, forKey: .isPinned) ?? false
        isArchived = container.lenient(Bool.self, forKey: .isArchived) ?? false
        worktreePath = container.lenient(String.self, forKey: .worktreePath)
        branch = container.lenient(String.self, forKey: .branch)
        draft = container.lenient(String.self, forKey: .draft)
    }
}
