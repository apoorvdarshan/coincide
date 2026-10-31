import Foundation

// What the phone does to a thread's conversation and its composer, as the Mac's transcript and composer offer it:
// forking, rewinding to an earlier message, and the usage-limit banner. Every request here is answered `unsupported`
// by an older Mac.

/// A thread and one of its items.
public struct RemoteItemReference: Codable, Hashable, Sendable {
    public var threadID: UUID
    public var itemID: UUID

    public init(threadID: UUID, itemID: UUID) {
        self.threadID = threadID
        self.itemID = itemID
    }
}

/// Forks a thread: a new thread in the same project with the conversation so far (`forkThread`).
public struct RemoteForkRequest: Codable, Hashable, Sendable {
    public var threadID: UUID
    /// The conversation through the turn holding this item ("Fork from Here"); nil for its latest settled turn.
    public var itemID: UUID?

    public init(threadID: UUID, itemID: UUID? = nil) {
        self.threadID = threadID
        self.itemID = itemID
    }
}

/// What "Edit from Here" can do with one of the user's messages (`rewindOptions`).
public struct RemoteRewindOptions: Codable, Hashable, Sendable {
    /// The turn's checkpoint can put files back the way they were before the message ("Revert Files Too").
    public var canRevertFiles: Bool
    /// A turn runs: nothing can be rewound until it ends.
    public var isRunning: Bool

    public init(canRevertFiles: Bool, isRunning: Bool = false) {
        self.canRevertFiles = canRevertFiles
        self.isRunning = isRunning
    }
}

/// Rewinds the conversation to before one of the user's messages (`rewind`), as "Edit from Here" does on the Mac.
public struct RemoteRewindRequest: Codable, Hashable, Sendable {
    public var threadID: UUID
    public var itemID: UUID
    /// Also put files back the way they were before the message, undoing any edits since.
    public var revertsFiles: Bool

    public init(threadID: UUID, itemID: UUID, revertsFiles: Bool) {
        self.threadID = threadID
        self.itemID = itemID
        self.revertsFiles = revertsFiles
    }
}

/// The message a rewind removed, for the phone's composer to edit and send again.
public struct RemoteRewind: Codable, Hashable, Sendable {
    public var text: String
    /// The names of the pictures it had, which stay on the Mac.
    public var attachments: [String]

    public init(text: String, attachments: [String] = []) {
        self.text = text
        self.attachments = attachments
    }
}

/// The composer's usage-limit banner, worded by the Mac (`usageWarning`): an agent's limit window nearly or wholly used.
public struct RemoteUsageWarning: Codable, Hashable, Sendable {
    /// Identifies the warning, so dismissing it hides it until another window fills.
    public var key: String
    /// "You've used 92% of Claude's 5-hour limit. It resets at 4:30 PM.", as the Mac's banner says it.
    public var text: String
    /// How full the meter is, 0 to 1, in the Mac's used-or-left setting.
    public var fraction: Double
    /// The thread can continue on its own once the limit resets ("Resume at Reset").
    public var canResumeAtReset: Bool
    /// When the thread continues on its own, after "Resume at Reset".
    public var resumesAt: Date?

    public init(key: String, text: String, fraction: Double, canResumeAtReset: Bool = false, resumesAt: Date? = nil) {
        self.key = key
        self.text = text
        self.fraction = fraction
        self.canResumeAtReset = canResumeAtReset
        self.resumesAt = resumesAt
    }
}

/// The banner over a thread's composer, or none.
public struct RemoteComposerNotice: Codable, Hashable, Sendable {
    public var usageWarning: RemoteUsageWarning?

    public init(usageWarning: RemoteUsageWarning? = nil) {
        self.usageWarning = usageWarning
    }
}

/// Something done to the usage-limit banner (`usageWarningAction`).
public struct RemoteUsageWarningCommand: Codable, Hashable, Sendable {
    public enum Action: String, Codable, Sendable {
        case dismiss
        case resumeAtReset
        case cancelResume
        case unknown

        public init(from decoder: Decoder) throws {
            self = Action(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
        }
    }

    public var threadID: UUID
    public var key: String
    public var action: Action

    public init(threadID: UUID, key: String, action: Action) {
        self.threadID = threadID
        self.key = key
        self.action = action
    }
}

// MARK: Projects

/// How the Mac's sidebar orders its lists and how many threads a project shows before "Show more". Sent in the
/// workspace; nil from an older Mac. Values are the Mac's names, and ones this version doesn't know read as unknown.
public struct RemoteSidebarOptions: Codable, Hashable, Sendable {
    /// `manual`, `recentActivity` or `name`.
    public var projectSort: String
    /// `recentActivity`, `created` or `name`.
    public var threadSort: String
    public var chatSort: String
    /// `manual`, `recentActivity` or `name`.
    public var botSort: String
    /// Threads per project before "Show more": nil fits the list to the window, 0 shows all.
    public var threadsPerProject: Int?

    public init(
        projectSort: String = "manual", threadSort: String = "recentActivity", chatSort: String = "recentActivity",
        botSort: String = "recentActivity", threadsPerProject: Int? = nil
    ) {
        self.projectSort = projectSort
        self.threadSort = threadSort
        self.chatSort = chatSort
        self.botSort = botSort
        self.threadsPerProject = threadsPerProject
    }

    public static let projectSorts = ["manual", "recentActivity", "name"]
    public static let threadSorts = ["recentActivity", "created", "name"]
    public static let botSorts = ["manual", "recentActivity", "name"]
    /// The fixed counts the Mac's "Threads per Project" menu offers, besides fitting and all (0).
    public static let threadLimits = [10, 20, 50]
}

/// A project.
public struct RemoteProjectReference: Codable, Hashable, Sendable {
    public var projectID: UUID

    public init(projectID: UUID) {
        self.projectID = projectID
    }
}

/// What a project's new threads start with ("Project Defaults…"): the agent and model, permissions and mode, or the
/// global defaults.
public struct RemoteProjectDefaults: Codable, Hashable, Sendable {
    public var projectID: UUID
    /// New threads use the defaults from Settings; the fields below show those and are ignored when saving.
    public var usesGlobalDefaults: Bool
    public var provider: String
    public var modelID: String
    public var effort: String?
    /// `approval`, `fullAccess` or another mode a newer Mac adds.
    public var accessMode: String
    /// `build` or `plan`.
    public var interactionMode: String

    public init(
        projectID: UUID, usesGlobalDefaults: Bool, provider: String, modelID: String, effort: String? = nil,
        accessMode: String = "approval", interactionMode: String = "build"
    ) {
        self.projectID = projectID
        self.usesGlobalDefaults = usesGlobalDefaults
        self.provider = provider
        self.modelID = modelID
        self.effort = effort
        self.accessMode = accessMode
        self.interactionMode = interactionMode
    }
}
