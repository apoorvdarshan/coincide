import Foundation

// What the Mac tells the phone about its projects, threads and transcripts. These mirror CoincideKit's models but
// stand on their own, so the phone never needs CoincideKit (which is macOS-only). Every type decodes leniently where a
// newer Mac might add a case: unknown kinds and statuses fall back rather than failing the message.

/// The Mac the phone talks to.
public struct RemoteServerInfo: Codable, Hashable, Sendable {
    /// Stable for this Mac, so the phone recognizes it on Bonjour and in saved connections.
    public var serverID: String
    /// The Mac's name, such as "Apoorv's MacBook Pro".
    public var name: String
    public var appVersion: String
    public var protocolVersion: Int
    public var theme: RemoteThemeInfo
    /// Whether the transcript shows agents' reasoning (Settings › General › Show reasoning).
    public var showsReasoning: Bool
    /// The follow-up behavior while a turn runs: `steer` or `queue`.
    public var followUpBehavior: String
    /// Whether the Mac notifies about finished turns, approvals and questions (its "Notify…" setting), which also
    /// decides whether it sends any to the phone. Nil from a Mac older than notification routing.
    public var notifies: Bool?

    public init(
        serverID: String, name: String, appVersion: String, protocolVersion: Int = RemoteProtocol.version,
        theme: RemoteThemeInfo = RemoteThemeInfo(), showsReasoning: Bool = true, followUpBehavior: String = "steer",
        notifies: Bool? = nil
    ) {
        self.serverID = serverID
        self.name = name
        self.appVersion = appVersion
        self.protocolVersion = protocolVersion
        self.theme = theme
        self.showsReasoning = showsReasoning
        self.followUpBehavior = followUpBehavior
        self.notifies = notifies
    }
}

/// The Mac's appearance settings, so the phone can follow its theme.
public struct RemoteThemeInfo: Codable, Hashable, Sendable {
    /// `system`, `light` or `dark`.
    public var appearance: String
    public var darkThemeID: String
    public var lightThemeID: String

    public init(appearance: String = "system", darkThemeID: String = "carbon", lightThemeID: String = "carbon-light") {
        self.appearance = appearance
        self.darkThemeID = darkThemeID
        self.lightThemeID = lightThemeID
    }
}

/// Everything the sidebar shows: projects in the Mac's order (Chats last), threads, bots and the agents to pick from.
public struct RemoteWorkspace: Codable, Hashable, Sendable {
    /// In the Mac sidebar's order, Chats last.
    public var projects: [RemoteProject]
    /// Every thread that isn't archived, plus archived ones the phone asked for, in the Mac sidebar's order within
    /// each project.
    public var threads: [RemoteThreadSummary]
    /// Bots, when the Mac has any. Nil when this Mac has no bots feature.
    public var bots: [RemoteBot]?
    public var providers: [RemoteProvider]
    /// The Mac sidebar's sections in its order: `pinned`, `projects`, `chats` (and kinds a newer Mac adds).
    public var sections: [String]
    /// The Pinned section's threads in the Mac's order.
    public var pinnedOrder: [UUID]

    public init(
        projects: [RemoteProject] = [], threads: [RemoteThreadSummary] = [], bots: [RemoteBot]? = nil,
        providers: [RemoteProvider] = [], sections: [String] = ["pinned", "projects", "chats"], pinnedOrder: [UUID] = []
    ) {
        self.projects = projects
        self.threads = threads
        self.bots = bots
        self.providers = providers
        self.sections = sections
        self.pinnedOrder = pinnedOrder
    }
}

public struct RemoteProject: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    /// The folder, with the home folder shortened to `~`.
    public var path: String
    public var isChats: Bool
    public var scripts: [RemoteScript]

    public init(id: UUID, name: String, path: String, isChats: Bool = false, scripts: [RemoteScript] = []) {
        self.id = id
        self.name = name
        self.path = path
        self.isChats = isChats
        self.scripts = scripts
    }
}

public struct RemoteScript: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var command: String
    /// `play`, `test`, `lint`, `configure`, `build` or `debug`.
    public var icon: String

    public init(id: UUID, name: String, command: String, icon: String = "play") {
        self.id = id
        self.name = name
        self.command = command
        self.icon = icon
    }
}

public struct RemoteBot: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    /// The project its threads live in, when it has one.
    public var projectID: UUID?
    public var threadIDs: [UUID]

    public init(id: UUID, name: String, projectID: UUID? = nil, threadIDs: [UUID] = []) {
        self.id = id
        self.name = name
        self.projectID = projectID
        self.threadIDs = threadIDs
    }
}

/// The agent, model and settings a thread runs with.
public struct RemoteSelection: Codable, Hashable, Sendable {
    public var provider: String
    public var modelID: String
    public var modelName: String
    public var effort: String?
    public var speed: String?
    public var accountID: String?
    /// Shown only when the agent has more than one account.
    public var accountName: String?

    public init(
        provider: String, modelID: String, modelName: String, effort: String? = nil, speed: String? = nil,
        accountID: String? = nil, accountName: String? = nil
    ) {
        self.provider = provider
        self.modelID = modelID
        self.modelName = modelName
        self.effort = effort
        self.speed = speed
        self.accountID = accountID
        self.accountName = accountName
    }
}

public struct RemoteThreadSummary: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var projectID: UUID
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var selection: RemoteSelection
    /// `fullAccess` or `approval`.
    public var accessMode: String
    /// `build` or `plan`.
    public var interactionMode: String
    public var isPinned: Bool
    public var isArchived: Bool
    public var snoozedUntil: Date?
    /// Settled in the inbox: hidden until something new happens.
    public var isSettled: Bool
    /// The Mac's list hides it now (snoozed or settled with nothing waiting).
    public var isHidden: Bool
    public var branch: String?
    public var hasWorktree: Bool
    public var isRunning: Bool
    public var isStarting: Bool
    public var pendingApprovals: Int
    public var pendingQuestions: Int
    /// A result the user hasn't looked at: `completed` or `failed`.
    public var unseen: String?
    public var queuedMessages: Int
    public var hasDraft: Bool
    public var itemCount: Int

    public init(
        id: UUID, projectID: UUID, title: String, createdAt: Date = Date(), updatedAt: Date = Date(),
        selection: RemoteSelection, accessMode: String = "fullAccess", interactionMode: String = "build",
        isPinned: Bool = false, isArchived: Bool = false, snoozedUntil: Date? = nil, isSettled: Bool = false,
        isHidden: Bool = false, branch: String? = nil, hasWorktree: Bool = false, isRunning: Bool = false,
        isStarting: Bool = false, pendingApprovals: Int = 0, pendingQuestions: Int = 0, unseen: String? = nil,
        queuedMessages: Int = 0, hasDraft: Bool = false, itemCount: Int = 0
    ) {
        self.id = id
        self.projectID = projectID
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.selection = selection
        self.accessMode = accessMode
        self.interactionMode = interactionMode
        self.isPinned = isPinned
        self.isArchived = isArchived
        self.snoozedUntil = snoozedUntil
        self.isSettled = isSettled
        self.isHidden = isHidden
        self.branch = branch
        self.hasWorktree = hasWorktree
        self.isRunning = isRunning
        self.isStarting = isStarting
        self.pendingApprovals = pendingApprovals
        self.pendingQuestions = pendingQuestions
        self.unseen = unseen
        self.queuedMessages = queuedMessages
        self.hasDraft = hasDraft
        self.itemCount = itemCount
    }

    /// The agent waits for the user: an approval or a question.
    public var needsUser: Bool { pendingApprovals > 0 || pendingQuestions > 0 }
}

/// An agent the composer can switch to, with its accounts and models.
public struct RemoteProvider: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    /// `ready`, `notInstalled`, `notAuthenticated`, `error` or `unknown`.
    public var state: String
    public var accounts: [RemoteAccount]
    public var models: [RemoteModel]

    public init(id: String, name: String, state: String, accounts: [RemoteAccount] = [], models: [RemoteModel] = []) {
        self.id = id
        self.name = name
        self.state = state
        self.accounts = accounts
        self.models = models
    }

    public var isReady: Bool { state == "ready" }
}

public struct RemoteAccount: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var isReady: Bool

    public init(id: String, name: String, isReady: Bool) {
        self.id = id
        self.name = name
        self.isReady = isReady
    }
}

public struct RemoteModel: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var efforts: [String]
    public var defaultEffort: String?
    public var speeds: [RemoteSpeed]
    public var supportsImages: Bool

    public init(
        id: String, name: String, efforts: [String] = [], defaultEffort: String? = nil, speeds: [RemoteSpeed] = [],
        supportsImages: Bool = true
    ) {
        self.id = id
        self.name = name
        self.efforts = efforts
        self.defaultEffort = defaultEffort
        self.speeds = speeds
        self.supportsImages = supportsImages
    }
}

public struct RemoteSpeed: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var detail: String?

    public init(id: String, name: String, detail: String? = nil) {
        self.id = id
        self.name = name
        self.detail = detail
    }
}

// MARK: Transcript

/// One entry in a thread's transcript, as `TranscriptItem` describes it on the Mac.
public struct RemoteItem: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case user, assistant, reasoning, tool, approval, plan, error, notice, question
        /// A kind a newer Mac added.
        case unknown

        public init(from decoder: Decoder) throws {
            self = Kind(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
        }
    }

    public var id: UUID
    /// Its position in the whole transcript, so an update can be placed among the items the phone has.
    public var index: Int
    public var kind: Kind
    public var text: String
    public var title: String?
    public var detail: String?
    /// The tool's category: `command`, `fileChange`, `read`, `search`, `web`, `mcp`, `task`, `todo` or `other`.
    public var category: String?
    /// `running`, `completed`, `failed`, `declined` or `waiting`.
    public var status: String?
    public var provider: String?
    public var modelID: String?
    public var approval: RemoteApproval?
    public var questions: RemoteQuestionSet?
    public var answers: [String: [String]]?
    /// File names of the images the user attached.
    public var attachments: [String]?
    /// One-line summaries of the context the user attached: quotes, terminal output, review comments, files.
    public var context: [String]?
    public var steered: Bool
    /// The text or detail was cut to keep messages small; the full text is on the Mac.
    public var isClipped: Bool
    public var createdAt: Date
    public var completedAt: Date?

    public init(
        id: UUID, index: Int, kind: Kind, text: String = "", title: String? = nil, detail: String? = nil,
        category: String? = nil, status: String? = nil, provider: String? = nil, modelID: String? = nil,
        approval: RemoteApproval? = nil, questions: RemoteQuestionSet? = nil, answers: [String: [String]]? = nil,
        attachments: [String]? = nil, context: [String]? = nil, steered: Bool = false, isClipped: Bool = false,
        createdAt: Date = Date(), completedAt: Date? = nil
    ) {
        self.id = id
        self.index = index
        self.kind = kind
        self.text = text
        self.title = title
        self.detail = detail
        self.category = category
        self.status = status
        self.provider = provider
        self.modelID = modelID
        self.approval = approval
        self.questions = questions
        self.answers = answers
        self.attachments = attachments
        self.context = context
        self.steered = steered
        self.isClipped = isClipped
        self.createdAt = createdAt
        self.completedAt = completedAt
    }

    public var isWaiting: Bool { status == "waiting" }
}

public struct RemoteApproval: Codable, Hashable, Sendable {
    public struct Option: Codable, Hashable, Sendable, Identifiable {
        public var id: String
        public var label: String
        /// `allowOnce`, `allowAlways`, `deny` or `cancel`.
        public var kind: String

        public init(id: String, label: String, kind: String) {
            self.id = id
            self.label = label
            self.kind = kind
        }
    }

    public var options: [Option]
    public var resolution: String?
    /// Placeholder of a text field the agent wants filled in with the choice, when it wants one.
    public var textPlaceholder: String?
    public var acceptsText: Bool
    public var responseText: String?

    public init(
        options: [Option], resolution: String? = nil, textPlaceholder: String? = nil, acceptsText: Bool = false,
        responseText: String? = nil
    ) {
        self.options = options
        self.resolution = resolution
        self.textPlaceholder = textPlaceholder
        self.acceptsText = acceptsText
        self.responseText = responseText
    }
}

public struct RemoteQuestionSet: Codable, Hashable, Sendable {
    public struct Question: Codable, Hashable, Sendable, Identifiable {
        public struct Option: Codable, Hashable, Sendable {
            public var label: String
            public var detail: String?

            public init(label: String, detail: String? = nil) {
                self.label = label
                self.detail = detail
            }
        }

        public var id: String
        public var header: String?
        public var prompt: String
        public var options: [Option]
        public var allowsMultipleSelection: Bool
        public var allowsFreeText: Bool
        public var isSecret: Bool

        public init(
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

    public var title: String?
    public var questions: [Question]

    public init(title: String? = nil, questions: [Question]) {
        self.title = title
        self.questions = questions
    }
}

/// The running turn, when there is one, and the messages waiting for it.
public struct RemoteTurnState: Codable, Hashable, Sendable {
    public var isRunning: Bool
    public var isStarting: Bool
    public var startedAt: Date?
    public var provider: String?
    /// Whether a message sent now can go into the running turn.
    public var canSteer: Bool
    public var queued: [RemoteQueuedMessage]
    /// When a thread stopped at a usage limit resumes on its own.
    public var resumesAt: Date?

    public init(
        isRunning: Bool = false, isStarting: Bool = false, startedAt: Date? = nil, provider: String? = nil,
        canSteer: Bool = false, queued: [RemoteQueuedMessage] = [], resumesAt: Date? = nil
    ) {
        self.isRunning = isRunning
        self.isStarting = isStarting
        self.startedAt = startedAt
        self.provider = provider
        self.canSteer = canSteer
        self.queued = queued
        self.resumesAt = resumesAt
    }
}

public struct RemoteQueuedMessage: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var text: String
    public var imageCount: Int

    public init(id: UUID, text: String, imageCount: Int = 0) {
        self.id = id
        self.text = text
        self.imageCount = imageCount
    }
}

/// A thread's transcript as the phone first sees it: its newest items, the turn state, and what changed per turn.
public struct RemoteTranscript: Codable, Hashable, Sendable {
    public var thread: RemoteThreadSummary
    public var items: [RemoteItem]
    /// Older items exist before the first one sent.
    public var hasEarlier: Bool
    public var turn: RemoteTurnState
    /// Files each finished turn changed, keyed by the id of the item that opened the turn.
    public var turnChanges: [String: [RemoteChangedFile]]

    public init(
        thread: RemoteThreadSummary, items: [RemoteItem], hasEarlier: Bool = false, turn: RemoteTurnState = RemoteTurnState(),
        turnChanges: [String: [RemoteChangedFile]] = [:]
    ) {
        self.thread = thread
        self.items = items
        self.hasEarlier = hasEarlier
        self.turn = turn
        self.turnChanges = turnChanges
    }
}

public struct RemoteItemPage: Codable, Hashable, Sendable {
    public var items: [RemoteItem]
    public var hasEarlier: Bool

    public init(items: [RemoteItem], hasEarlier: Bool) {
        self.items = items
        self.hasEarlier = hasEarlier
    }
}

public struct RemoteChangedFile: Codable, Hashable, Sendable, Identifiable {
    public var path: String
    public var oldPath: String?
    /// `added`, `modified`, `deleted`, `renamed` or `untracked`.
    public var status: String
    public var additions: Int
    public var deletions: Int

    public var id: String { path }

    public init(path: String, oldPath: String? = nil, status: String, additions: Int = 0, deletions: Int = 0) {
        self.path = path
        self.oldPath = oldPath
        self.status = status
        self.additions = additions
        self.deletions = deletions
    }
}

/// A diff split per file, each with its unified patch.
public struct RemoteDiff: Codable, Hashable, Sendable {
    public struct File: Codable, Hashable, Sendable, Identifiable {
        public var path: String
        public var oldPath: String?
        public var status: String
        public var additions: Int
        public var deletions: Int
        public var isBinary: Bool
        /// The file's hunks in unified form, starting at its first `@@` line. Empty for a binary file.
        public var patch: String

        public var id: String { path }

        public init(
            path: String, oldPath: String? = nil, status: String, additions: Int = 0, deletions: Int = 0,
            isBinary: Bool = false, patch: String = ""
        ) {
            self.path = path
            self.oldPath = oldPath
            self.status = status
            self.additions = additions
            self.deletions = deletions
            self.isBinary = isBinary
            self.patch = patch
        }
    }

    /// What it shows, such as "Turn changes" or "Uncommitted changes".
    public var title: String
    public var files: [File]
    /// Some files were left out or cut short to keep the message small.
    public var isTruncated: Bool

    public init(title: String, files: [File], isTruncated: Bool = false) {
        self.title = title
        self.files = files
        self.isTruncated = isTruncated
    }
}

/// An agent account's usage windows.
public struct RemoteUsage: Codable, Hashable, Sendable, Identifiable {
    public struct Window: Codable, Hashable, Sendable, Identifiable {
        public var id: String
        public var label: String
        public var usedPercent: Double
        public var resetsAt: Date?

        public init(id: String, label: String, usedPercent: Double, resetsAt: Date? = nil) {
            self.id = id
            self.label = label
            self.usedPercent = usedPercent
            self.resetsAt = resetsAt
        }
    }

    public var provider: String
    public var providerName: String
    public var accountID: String
    public var accountName: String?
    public var windows: [Window]
    public var checkedAt: Date?

    public var id: String { "\(provider)/\(accountID)" }

    public init(
        provider: String, providerName: String, accountID: String, accountName: String? = nil, windows: [Window],
        checkedAt: Date? = nil
    ) {
        self.provider = provider
        self.providerName = providerName
        self.accountID = accountID
        self.accountName = accountName
        self.windows = windows
        self.checkedAt = checkedAt
    }
}

/// A phone allowed to connect, as the Mac's Settings list it.
public struct RemoteDevice: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var pairedAt: Date
    public var lastSeenAt: Date?

    public init(id: String, name: String, pairedAt: Date = Date(), lastSeenAt: Date? = nil) {
        self.id = id
        self.name = name
        self.pairedAt = pairedAt
        self.lastSeenAt = lastSeenAt
    }
}
