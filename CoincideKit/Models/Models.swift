import Foundation

/// A coding agent Coincide can drive. Each one is a CLI the user installs and signs in to
/// with their own subscription; Coincide never sells or proxies tokens.
public enum ProviderKind: String, Codable, CaseIterable, Sendable, Hashable {
    case claude
    case codex
    case cursor
    case grok
    case opencode
    case antigravity

    public nonisolated var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .cursor: "Cursor"
        case .grok: "Grok Build"
        case .opencode: "OpenCode"
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
    /// Faster speeds the model offers besides the standard one, such as Claude's fast mode or Codex's Fast and
    /// Ultrafast service tiers. Empty when it runs at one speed.
    public var speeds: [ModelSpeed]

    public nonisolated var id: String { "\(provider.rawValue)/\(modelID)" }

    public nonisolated var reference: ModelReference { ModelReference(provider: provider, modelID: modelID) }

    public nonisolated init(
        provider: ProviderKind, modelID: String, displayName: String, efforts: [String] = [],
        defaultEffort: String? = nil, contextWindow: Int? = nil, supportsImages: Bool = true, speeds: [ModelSpeed] = []
    ) {
        self.provider = provider
        self.modelID = modelID
        self.displayName = displayName
        self.efforts = efforts
        self.defaultEffort = defaultEffort
        self.contextWindow = contextWindow
        self.supportsImages = supportsImages
        self.speeds = speeds
    }

    public nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        provider = try container.decode(ProviderKind.self, forKey: .provider)
        modelID = try container.decode(String.self, forKey: .modelID)
        displayName = try container.decode(String.self, forKey: .displayName)
        efforts = try container.decode([String].self, forKey: .efforts)
        defaultEffort = try container.decodeIfPresent(String.self, forKey: .defaultEffort)
        contextWindow = try container.decodeIfPresent(Int.self, forKey: .contextWindow)
        supportsImages = try container.decode(Bool.self, forKey: .supportsImages)
        speeds = try container.decodeIfPresent([ModelSpeed].self, forKey: .speeds) ?? []
    }

    /// The speed with id `speed`, when the model offers it.
    public nonisolated func speed(_ speed: String?) -> ModelSpeed? {
        speed.flatMap { id in speeds.first { $0.id == id } }
    }
}

/// A faster speed a model offers (T3 Code's fast mode and service tiers). Its id is what the agent is sent.
public struct ModelSpeed: Codable, Hashable, Sendable {
    /// `fast` for Claude's fast mode; for Codex, the catalog service tier id, such as `priority`.
    public var id: String
    public var name: String
    /// What the speed costs or changes, when the agent says.
    public var detail: String?

    public nonisolated init(id: String, name: String, detail: String? = nil) {
        self.id = id
        self.name = name
        self.detail = detail
    }

    /// Claude's fast mode, also used by older Codex catalogs. New Codex catalogs supply their own tier id.
    public nonisolated static let fast = ModelSpeed(id: "fast", name: String(localized: "Fast"))
}

/// One agent's model, as the user's favorite and hidden models name it.
public struct ModelReference: Codable, Hashable, Sendable {
    public var provider: ProviderKind
    public var modelID: String

    public nonisolated init(provider: ProviderKind, modelID: String) {
        self.provider = provider
        self.modelID = modelID
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
    /// A faster speed the model offers (an id of `ModelOption.speeds`), such as `fast`; nil runs at standard speed.
    public var speed: String?
    /// The provider's account that runs it (`ProviderAccount.id`); nil for the default account, as before accounts.
    public var accountID: String?

    public nonisolated init(
        provider: ProviderKind, modelID: String, effort: String? = nil, speed: String? = nil, accountID: String? = nil
    ) {
        self.provider = provider
        self.modelID = modelID
        self.effort = effort
        self.speed = speed
        self.accountID = ProviderAccountID.stored(accountID)
    }

    /// The account's id, the default account's for nil.
    public nonisolated var account: String { accountID ?? ProviderAccountID.default }

    /// The provider and model are required; an effort, speed or account this version cannot read is left unset.
    public nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        provider = try container.decode(ProviderKind.self, forKey: .provider)
        modelID = try container.decode(String.self, forKey: .modelID)
        effort = container.lenient(String.self, forKey: .effort)
        speed = container.lenient(String.self, forKey: .speed)
        accountID = ProviderAccountID.stored(container.lenient(String.self, forKey: .accountID))
    }
}

/// A thread's desired reasoning and speed for one provider account. An existing entry with nil speed remembers
/// Standard; an absent entry means the thread has not used that account yet. Unsupported choices stay here while
/// `ChatThread.selectModel` gives the active model a supported selection.
public struct ProviderModelPreferences: Codable, Hashable, Sendable {
    public var effort: String?
    public var speed: String?

    public nonisolated init(effort: String? = nil, speed: String? = nil) {
        self.effort = effort
        self.speed = speed
    }

    public nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        effort = container.lenient(String.self, forKey: .effort)
        speed = container.lenient(String.self, forKey: .speed)
    }
}

/// A command the user runs often in a project, such as starting the dev server or the tests (T3 Code's project
/// scripts). It runs in a terminal of the thread, in its worktree or the project folder.
public struct ProjectScript: Codable, Hashable, Sendable, Identifiable {
    public enum Icon: String, Codable, Sendable, CaseIterable {
        case play, test, lint, configure, build, debug
    }

    public var id: UUID
    public var name: String
    public var command: String
    public var icon: Icon
    /// Runs on its own in a new worktree as soon as a thread gets one, to install dependencies or copy settings.
    public var runOnWorktreeCreate: Bool

    public nonisolated init(
        id: UUID = UUID(), name: String, command: String, icon: Icon = .play, runOnWorktreeCreate: Bool = false
    ) {
        self.id = id
        self.name = name
        self.command = command
        self.icon = icon
        self.runOnWorktreeCreate = runOnWorktreeCreate
    }

    public nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.lenient(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        command = try container.decode(String.self, forKey: .command)
        icon = container.lenient(Icon.self, forKey: .icon) ?? .play
        runOnWorktreeCreate = container.lenient(Bool.self, forKey: .runOnWorktreeCreate) ?? false
    }

    /// The scripts of a T3 Code `t3.json` file, so a project set up for T3 Code brings its scripts along.
    public nonisolated static func scripts(fromT3File data: Data) -> [ProjectScript] {
        guard let json = JSONValue.parse(String(decoding: data, as: UTF8.self)) else { return [] }
        return (json["scripts"]?.array ?? []).compactMap { entry in
            guard let name = entry["name"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
                let command = entry["command"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty
            else { return nil }
            return ProjectScript(
                name: name, command: command, icon: entry["icon"]?.string.flatMap(Icon.init(rawValue:)) ?? .play,
                runOnWorktreeCreate: entry["runOnWorktreeCreate"]?.bool ?? false)
        }
    }
}

/// Defaults captured for newly created threads in one project. Nil on Project inherits the app's defaults.
public struct ProjectThreadDefaults: Codable, Hashable, Sendable {
    public var selection: ModelSelection
    public var accessMode: AccessMode
    public var interactionMode: InteractionMode

    public nonisolated init(selection: ModelSelection, accessMode: AccessMode, interactionMode: InteractionMode = .build) {
        self.selection = selection
        self.accessMode = accessMode
        self.interactionMode = interactionMode
    }

    public nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        selection = try container.decode(ModelSelection.self, forKey: .selection)
        // An unknown future permission mode must not turn into full access.
        accessMode = container.lenient(AccessMode.self, forKey: .accessMode) ?? .approval
        interactionMode = container.lenient(InteractionMode.self, forKey: .interactionMode) ?? .build
    }
}

public struct Project: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var path: String
    public var createdAt: Date
    public var isExpanded: Bool
    /// The project's scripts, in the order the menu lists them.
    public var scripts: [ProjectScript]
    /// The home of chats: threads started without a project, like a chat app's (T3 Code's scratch project). Its folder
    /// is Coincide's own, and the sidebar lists it last, as Chats.
    public var isChats: Bool
    /// The home of bots' conversations (`AppStore.botsProject`). It is not among the user's projects; each bot
    /// runs its conversations in its own folder (`Bot.workingDirectory`).
    public var isBots: Bool
    public var threadDefaults: ProjectThreadDefaults?

    public nonisolated init(
        id: UUID = UUID(), name: String, path: String, createdAt: Date = Date(), isExpanded: Bool = true,
        scripts: [ProjectScript] = [], isChats: Bool = false, isBots: Bool = false,
        threadDefaults: ProjectThreadDefaults? = nil
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.createdAt = createdAt
        self.isExpanded = isExpanded
        self.scripts = scripts
        self.isChats = isChats
        self.isBots = isBots
        self.threadDefaults = threadDefaults
    }

    public nonisolated var url: URL { URL(fileURLWithPath: path) }

    public nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        path = try container.decode(String.self, forKey: .path)
        name = container.lenient(String.self, forKey: .name) ?? (path as NSString).lastPathComponent
        createdAt = container.lenient(Date.self, forKey: .createdAt) ?? .distantPast
        isExpanded = container.lenient(Bool.self, forKey: .isExpanded) ?? true
        scripts = container.lenientArray(ProjectScript.self, forKey: .scripts)
        isChats = container.lenient(Bool.self, forKey: .isChats) ?? false
        isBots = container.lenient(Bool.self, forKey: .isBots) ?? false
        threadDefaults = container.lenient(ProjectThreadDefaults.self, forKey: .threadDefaults)
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
    public enum ResponseMode: String, Codable, Hashable, Sendable {
        /// A nonblocking question: reply through the ordinary message/steering path, not an RPC response.
        case userMessage
    }
    /// Id the session needs back in `answer(userInput:answers:)` for a blocking request.
    public var id: String
    public var title: String?
    public var questions: [UserQuestion]
    /// Nil for a blocking provider request. Optional so previously saved requests still decode.
    public var responseMode: ResponseMode?

    public nonisolated init(
        id: String, title: String? = nil, questions: [UserQuestion], responseMode: ResponseMode? = nil
    ) {
        self.id = id
        self.title = title
        self.questions = questions
        self.responseMode = responseMode
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
    /// What the user attached to a message besides images: quotes, terminal excerpts, diff comments and files.
    public var context: [MessageContext]?
    /// True for a message the user sent into a running turn (T3 Code's steer), which belongs to that turn rather
    /// than opening one of its own. Nil for everything else, so other items are written as before.
    public var steered: Bool?
    /// The schedule that sent this message of the user's into the thread (`ScheduledTask`), shown as
    /// "Scheduled · name" over it. Nil for everything else.
    public var schedule: ScheduleMark?
    public var createdAt: Date
    public var completedAt: Date?

    /// Which schedule sent a message.
    public struct ScheduleMark: Codable, Hashable, Sendable {
        public var id: UUID
        public var name: String

        public nonisolated init(id: UUID, name: String) {
            self.id = id
            self.name = name
        }
    }

    public nonisolated init(
        id: UUID = UUID(), kind: Kind, text: String = "", title: String? = nil, detail: String? = nil,
        category: ToolCategory? = nil, status: ItemStatus? = nil, provider: ProviderKind? = nil,
        modelID: String? = nil, externalID: String? = nil, approval: ApprovalInfo? = nil,
        questions: UserInputRequest? = nil, answers: [String: [String]]? = nil, attachments: [String]? = nil,
        context: [MessageContext]? = nil, steered: Bool? = nil, schedule: ScheduleMark? = nil, createdAt: Date = Date(),
        completedAt: Date? = nil
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
        self.context = context
        self.steered = steered
        self.schedule = schedule
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
        // Context of a kind added later is left out; the rest of the message's context stays.
        context =
            container.contains(.context) && (try? container.decodeNil(forKey: .context)) != true
            ? container.lenientArray(MessageContext.self, forKey: .context) : nil
        steered = container.lenient(Bool.self, forKey: .steered)
        schedule = container.lenient(ScheduleMark.self, forKey: .schedule)
        createdAt = container.lenient(Date.self, forKey: .createdAt) ?? .distantPast
        completedAt = container.lenient(Date.self, forKey: .completedAt)
    }
}

/// A provider's native session for a thread, and how much of the transcript it has seen.
public struct ProviderSessionRef: Codable, Hashable, Sendable {
    public var sessionID: String
    /// Number of transcript items that existed when this session last finished a turn.
    public var seenItemCount: Int
    /// The account whose session this is (`ProviderAccount.id`); nil for the default account.
    public var accountID: String?
    /// Set when the session comes back after another account of its provider ran the thread: the items before this
    /// count that the provider wrote came from that account, so `Handoff` recaps them as it does other agents' turns.
    public var foreignItemsBefore: Int?

    public nonisolated init(sessionID: String, seenItemCount: Int, accountID: String? = nil, foreignItemsBefore: Int? = nil) {
        self.sessionID = sessionID
        self.seenItemCount = seenItemCount
        self.accountID = ProviderAccountID.stored(accountID)
        self.foreignItemsBefore = foreignItemsBefore
    }

    public nonisolated var account: String { accountID ?? ProviderAccountID.default }

    /// A negative count, which only a damaged file could hold, loads as 0 (nothing seen).
    public nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try container.decode(String.self, forKey: .sessionID)
        seenItemCount = max(try container.decode(Int.self, forKey: .seenItemCount), 0)
        accountID = ProviderAccountID.stored(container.lenient(String.self, forKey: .accountID))
        foreignItemsBefore = container.lenient(Int.self, forKey: .foreignItemsBefore).map { max($0, 0) }
    }
}

/// Import provenance stays with the transcript even when rewinding clears native session references.
public struct ImportedSession: Codable, Hashable, Sendable {
    public var provider: ProviderKind
    public var sessionID: String
    public var sourcePath: String
    public var importedAt: Date

    public init(provider: ProviderKind, sessionID: String, sourcePath: String, importedAt: Date = Date()) {
        self.provider = provider
        self.sessionID = sessionID
        self.sourcePath = sourcePath
        self.importedAt = importedAt
    }
}

/// A look the agent took at a thread's title after naming it (`ThreadTitles`).
public enum TitleRefresh: String, Codable, Hashable, Sendable, CaseIterable {
    /// After the first turn that completes, once: the reply shows what a short first message was about. Part of
    /// naming the thread.
    case firstReply
    /// After the fifth turn, once. Written by versions that looked again there; no longer asked for.
    case fifthTurn
    /// While titles are kept up to date (`AppSettings.updatesThreadTitles`): every few turns of a thread in use.
    case update
}

public struct ChatThread: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var projectID: UUID
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var selection: ModelSelection
    /// Desired reasoning and speed by provider/account (`accountSessionKey`), independent of model capabilities.
    /// Nil for threads that have not changed a composer choice yet; their current selection seeds the first entry.
    public var modelPreferences: [String: ProviderModelPreferences]?
    public var accessMode: AccessMode
    public var interactionMode: InteractionMode
    public var items: [TranscriptItem]
    /// Each provider's native session, of the account the thread last ran that provider with.
    public var sessions: [ProviderKind: ProviderSessionRef]
    /// The sessions of providers' other accounts, set aside (by `accountSessionKey`) until the thread runs that account
    /// again: one account cannot resume another's session. Nil rather than empty, so threads that never used another
    /// account are written as before.
    public var accountSessions: [String: ProviderSessionRef]?
    public var isPinned: Bool
    public var isArchived: Bool
    /// Hidden from the thread list until then (T3 Code's snooze), unless the agent needs the user first.
    public var snoozedUntil: Date?
    /// Working directory when the thread runs in its own git worktree.
    public var worktreePath: String?
    public var branch: String?
    /// Unsent composer text, restored when the thread is reopened.
    public var draft: String?
    /// Unsent context cards, restored with the draft after switching threads or restarting.
    public var draftContext: [MessageContext]?
    public var importedSession: ImportedSession?
    /// True once the user named the thread, so the agent never titles it again. Nil rather than false, so threads
    /// the user never renamed are written as before.
    public var titledByUser: Bool?
    /// The looks the agent has taken at the title after naming it, counted when asked so none runs twice. Nil for a
    /// thread whose first message was sent before looks were counted, which joins them at its next completed turn, or
    /// that came with its messages (an import, a fork), which keeps its title.
    public var titleRefreshes: [TitleRefresh]?
    /// The user turns the thread had, and when, at the agent's last look at its title, so titles kept up to date wait
    /// a few turns and minutes between looks. Nil before the first look, so threads are written as before.
    public var titleCheckTurns: Int?
    public var titleCheckedAt: Date?
    /// The bot whose conversation this is (`Bot.id`), in the Bots container. Nil for every other thread, so their
    /// files are written as before.
    public var botID: UUID?
    /// What a message sent while the agent works does in this thread. Nil for a thread made before threads kept their
    /// own, which does what `AppSettings.existingThreadsFollowUpBehavior` says (`AppStore.followUpBehavior(of:)`).
    public var followUpBehavior: FollowUpBehavior?

    public nonisolated init(
        id: UUID = UUID(), projectID: UUID, title: String = String(localized: "New thread"),
        selection: ModelSelection, accessMode: AccessMode = .fullAccess, interactionMode: InteractionMode = .build,
        items: [TranscriptItem] = [], sessions: [ProviderKind: ProviderSessionRef] = [:], isPinned: Bool = false,
        isArchived: Bool = false, worktreePath: String? = nil, branch: String? = nil, draft: String? = nil, draftContext: [MessageContext]? = nil,
        botID: UUID? = nil, followUpBehavior: FollowUpBehavior? = nil, createdAt: Date = Date()
    ) {
        self.id = id
        self.projectID = projectID
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.selection = selection
        modelPreferences = nil
        self.accessMode = accessMode
        self.interactionMode = interactionMode
        self.items = items
        self.sessions = sessions
        accountSessions = nil
        self.isPinned = isPinned
        self.isArchived = isArchived
        self.worktreePath = worktreePath
        self.branch = branch
        self.draft = draft
        self.draftContext = draftContext
        self.botID = botID
        self.followUpBehavior = followUpBehavior
    }

    public nonisolated var hasUserMessages: Bool { items.contains { $0.kind == .user } }

    /// The user named the thread, so the agent leaves its title alone.
    public nonisolated var isTitleCustom: Bool { titledByUser == true }

    /// "claude/<account id>": where `accountSessions` keeps an account's session.
    public nonisolated static func accountSessionKey(_ provider: ProviderKind, _ account: String) -> String {
        "\(provider.rawValue)/\(account)"
    }

    /// Resolves a user model/account pick, or an explicit reasoning/speed change, using only that account's own
    /// choices. A model that cannot use a desired value temporarily uses its default reasoning or Standard speed.
    /// Explicit changes replace the desired value even when the active model was already using that fallback.
    public nonisolated mutating func selectModel(
        _ requested: ModelSelection, option: ModelOption?, rememberingEffort: Bool = false, rememberingSpeed: Bool = false
    ) {
        var preferences = modelPreferences ?? [:]
        let currentKey = Self.accountSessionKey(selection.provider, selection.account)
        if preferences[currentKey] == nil {
            preferences[currentKey] = ProviderModelPreferences(effort: selection.effort, speed: selection.speed)
        }
        let nextKey = Self.accountSessionKey(requested.provider, requested.account)
        var desired = preferences[nextKey] ?? ProviderModelPreferences(effort: option?.defaultEffort)
        if rememberingEffort { desired.effort = requested.effort }
        if rememberingSpeed { desired.speed = requested.speed }
        preferences[nextKey] = desired

        let changedModel = requested.provider != selection.provider || requested.account != selection.account
            || requested.modelID != selection.modelID
        let resolveBoth = changedModel || !(rememberingEffort || rememberingSpeed)
        var resolved = requested
        if rememberingEffort, option == nil {
            // Remote/CLI allow an explicit effort for a custom model whose catalog is not available yet.
            resolved.effort = requested.effort
        } else {
            resolved.effort =
                resolveBoth || rememberingEffort
                ? desired.effort.flatMap { option?.efforts.contains($0) == true ? $0 : nil } ?? option?.defaultEffort
                : selection.effort
        }
        resolved.speed = resolveBoth || rememberingSpeed ? option?.speed(desired.speed)?.id : selection.speed
        selection = resolved
        modelPreferences = preferences
    }

    /// The native session `account` of `provider` has in the thread, whether it is the provider's current one or set
    /// aside.
    public nonisolated func session(_ provider: ProviderKind, account: String) -> ProviderSessionRef? {
        if let current = sessions[provider], current.account == account { return current }
        return accountSessions?[Self.accountSessionKey(provider, account)]
    }

    /// Makes `account`'s session the provider's current one and sets the other account's aside, so the provider's next
    /// turn continues `account`'s own session (or starts one) and gets a recap of what the other account did. Returns
    /// whether anything changed.
    @discardableResult
    public nonisolated mutating func activateAccount(_ account: String, for provider: ProviderKind) -> Bool {
        let current = sessions[provider]
        if let current, current.account == account { return false }
        var parked = accountSessions ?? [:]
        var restored = parked.removeValue(forKey: Self.accountSessionKey(provider, account))
        if let current { parked[Self.accountSessionKey(provider, current.account)] = current }
        guard current != nil || restored != nil else { return false }
        accountSessions = parked.isEmpty ? nil : parked
        // What the provider wrote while this account was set aside came from another account.
        if var ref = restored, ref.seenItemCount < items.count {
            ref.foreignItemsBefore = items.count
            restored = ref
        }
        sessions[provider] = restored
        return true
    }

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
        let preferences = (container.lenient([String: ProviderModelPreferences].self, forKey: .modelPreferences) ?? [:]).filter { key, _ in
            let parts = key.split(separator: "/", maxSplits: 1)
            return parts.count == 2 && ProviderKind(rawValue: String(parts[0])) != nil
        }
        modelPreferences = preferences.isEmpty ? nil : preferences
        // An unreadable mode (for example one a newer build added) fails closed.
        accessMode = container.lenient(AccessMode.self, forKey: .accessMode) ?? .approval
        interactionMode = container.lenient(InteractionMode.self, forKey: .interactionMode) ?? .build
        items = container.lenientArray(TranscriptItem.self, forKey: .items)
        sessions = container.lenientProviderMap(ProviderSessionRef.self, forKey: .sessions)
        // Sessions of a provider this version does not know are left out.
        let parked = (container.lenient([String: ProviderSessionRef].self, forKey: .accountSessions) ?? [:]).filter { key, _ in
            key.split(separator: "/", maxSplits: 1).first.flatMap { ProviderKind(rawValue: String($0)) } != nil
        }
        accountSessions = parked.isEmpty ? nil : parked
        isPinned = container.lenient(Bool.self, forKey: .isPinned) ?? false
        isArchived = container.lenient(Bool.self, forKey: .isArchived) ?? false
        snoozedUntil = container.lenient(Date.self, forKey: .snoozedUntil)
        worktreePath = container.lenient(String.self, forKey: .worktreePath)
        branch = container.lenient(String.self, forKey: .branch)
        draft = container.lenient(String.self, forKey: .draft)
        draftContext = container.contains(.draftContext) ? container.lenientArray(MessageContext.self, forKey: .draftContext) : nil
        importedSession = container.lenient(ImportedSession.self, forKey: .importedSession)
        titledByUser = container.lenient(Bool.self, forKey: .titledByUser)
        // Refreshes this version does not know are left out (`ThreadFile` notices them).
        titleRefreshes =
            container.contains(.titleRefreshes) && !((try? container.decodeNil(forKey: .titleRefreshes)) ?? true)
            ? container.lenientArray(TitleRefresh.self, forKey: .titleRefreshes) : nil
        titleCheckTurns = container.lenient(Int.self, forKey: .titleCheckTurns)
        titleCheckedAt = container.lenient(Date.self, forKey: .titleCheckedAt)
        botID = container.lenient(UUID.self, forKey: .botID)
        followUpBehavior = container.lenient(FollowUpBehavior.self, forKey: .followUpBehavior)
    }
}

/// How selections and sessions store a provider account's id (`ProviderAccount.id`).
public enum ProviderAccountID {
    /// The account every agent has: the CLI's own login in its usual home.
    public nonisolated static let `default` = "default"

    /// `id` as selections and sessions store it: nil for the default account or an empty id, so their files stay as
    /// before accounts.
    public nonisolated static func stored(_ id: String?) -> String? {
        guard let id, !id.isEmpty, id != `default` else { return nil }
        return id
    }
}
