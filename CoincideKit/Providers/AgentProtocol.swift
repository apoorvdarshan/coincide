import Foundation

/// Everything a provider needs to start (or resume) a native session for a thread.
public struct AgentLaunch: Sendable, Codable {
    public var provider: ProviderKind
    public var executable: URL
    public var environment: [String: String]
    public var workingDirectory: URL
    /// The provider's own session/thread id from an earlier run, to resume instead of starting fresh.
    public var resumeSessionID: String?
    public var selection: ModelSelection
    public var accessMode: AccessMode
    public var interactionMode: InteractionMode

    public nonisolated init(
        provider: ProviderKind, executable: URL, environment: [String: String], workingDirectory: URL,
        resumeSessionID: String?, selection: ModelSelection, accessMode: AccessMode, interactionMode: InteractionMode
    ) {
        self.provider = provider
        self.executable = executable
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.resumeSessionID = resumeSessionID
        self.selection = selection
        self.accessMode = accessMode
        self.interactionMode = interactionMode
    }
}

/// One user turn: the user's message plus, when other providers worked on the thread meanwhile, a recap
/// of what this provider missed (see `Handoff`). `text` is the two combined, ready to send.
/// The model, effort, access and interaction mode may differ from the previous turn;
/// sessions apply such changes before running the turn.
///
/// A session that had to replace its native session while sending (resuming failed, so it reports
/// `.sessionStarted` with a new id) must use `prompt(forNewSession: true)` / `recap(forNewSession: true)`:
/// the new native session has seen nothing of the thread.
public struct AgentTurnInput: Sendable, Codable {
    /// The user's message as typed, for example a slash command, followed by what they attached to it
    /// (`MessageContext.prompt(message:context:workingDirectory:)`).
    public var message: String
    /// What the provider's current native session missed: a `<conversation_handoff>` block and a line
    /// introducing the message. Nil when the session is current.
    public var handoffRecap: String?
    /// The recap for a native session that has seen nothing of the thread. Nil when there is nothing to recap.
    public var newSessionRecap: String?
    /// The thread's title, for providers that name their native sessions.
    public var threadTitle: String?
    /// The recap followed by the message: the prompt to send.
    public var text: String
    /// Absolute paths of attached images.
    public var imagePaths: [String]
    /// Absolute paths of other attached files. `message` already mentions each by path, which is all most agents get;
    /// a session whose agent reads a kind of file natively sends its content too (Claude Code takes PDFs as documents).
    public var filePaths: [String]
    public var selection: ModelSelection
    public var accessMode: AccessMode
    public var interactionMode: InteractionMode

    /// A turn whose message needs no recap.
    public nonisolated init(
        text: String, imagePaths: [String] = [], filePaths: [String] = [], selection: ModelSelection,
        accessMode: AccessMode, interactionMode: InteractionMode
    ) {
        self.init(
            message: text, handoffRecap: nil, newSessionRecap: nil, threadTitle: nil, imagePaths: imagePaths,
            filePaths: filePaths, selection: selection, accessMode: accessMode, interactionMode: interactionMode)
    }

    public nonisolated init(
        message: String, handoffRecap: String?, newSessionRecap: String?, threadTitle: String? = nil,
        imagePaths: [String] = [], filePaths: [String] = [], selection: ModelSelection, accessMode: AccessMode,
        interactionMode: InteractionMode
    ) {
        self.message = message
        self.handoffRecap = handoffRecap
        self.newSessionRecap = newSessionRecap
        self.threadTitle = threadTitle
        self.text = Handoff.compose(message: message, recap: handoffRecap)
        self.imagePaths = imagePaths
        self.filePaths = filePaths
        self.selection = selection
        self.accessMode = accessMode
        self.interactionMode = interactionMode
    }

    /// The recap to send: the full one when the native session is new, otherwise `handoffRecap`.
    public nonisolated func recap(forNewSession isNew: Bool) -> String? {
        isNew ? newSessionRecap : handoffRecap
    }

    /// The recap and the message combined, for the current native session or a new one.
    public nonisolated func prompt(forNewSession isNew: Bool) -> String {
        isNew ? Handoff.compose(message: message, recap: newSessionRecap) : text
    }
}

public struct ToolCallInfo: Sendable, Hashable, Codable {
    /// Provider id for the call; later events refer to it.
    public var id: String
    public var category: ToolCategory
    /// Short label, e.g. "Run `npm test`" or "Edit Sources/App.swift".
    public var title: String
    /// Longer text such as the full command, a unified diff, or the input JSON.
    public var detail: String?

    public nonisolated init(id: String, category: ToolCategory, title: String, detail: String? = nil) {
        self.id = id
        self.category = category
        self.title = title
        self.detail = detail
    }
}

public struct ApprovalRequest: Sendable, Hashable, Codable {
    /// Id the session needs back in `respond(to:optionID:)`.
    public var id: String
    public var category: ToolCategory
    public var title: String
    public var detail: String?
    public var options: [ApprovalOption]
    public var toolCallID: String?
    /// Set when the agent wants text along with the choice (for example an extension's input dialog).
    /// The answer arrives through `respond(to:optionID:text:)`.
    public var textInput: TextInputSpec?

    public nonisolated init(
        id: String, category: ToolCategory, title: String, detail: String? = nil, options: [ApprovalOption],
        toolCallID: String? = nil, textInput: TextInputSpec? = nil
    ) {
        self.id = id
        self.category = category
        self.title = title
        self.detail = detail
        self.options = options
        self.toolCallID = toolCallID
        self.textInput = textInput
    }

    /// Allow once / allow for the session / deny, for providers that do not supply their own choices.
    public nonisolated static let standardOptions: [ApprovalOption] = [
        ApprovalOption(id: "allow", label: String(localized: "Allow"), kind: .allowOnce),
        ApprovalOption(id: "allow_always", label: String(localized: "Always allow"), kind: .allowAlways),
        ApprovalOption(id: "deny", label: String(localized: "Deny"), kind: .deny),
    ]
}

public enum TurnOutcome: Sendable, Hashable, Codable {
    case completed
    case interrupted
    case failed(String)
}

public struct TokenUsage: Sendable, Hashable, Codable {
    /// Tokens currently in the context window (input + cached), when known.
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var cachedInputTokens: Int?
    public var contextWindow: Int?
    public var costUSD: Double?

    public nonisolated init(
        inputTokens: Int? = nil, outputTokens: Int? = nil, cachedInputTokens: Int? = nil, contextWindow: Int? = nil,
        costUSD: Double? = nil
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cachedInputTokens = cachedInputTokens
        self.contextWindow = contextWindow
        self.costUSD = costUSD
    }

    /// Fills fields missing here from `other`.
    public nonisolated func merged(with other: TokenUsage) -> TokenUsage {
        TokenUsage(
            inputTokens: inputTokens ?? other.inputTokens, outputTokens: outputTokens ?? other.outputTokens,
            cachedInputTokens: cachedInputTokens ?? other.cachedInputTokens,
            contextWindow: contextWindow ?? other.contextWindow, costUSD: costUSD ?? other.costUSD)
    }
}

/// One window of the user's subscription limits, such as Claude Code's five-hour session or Codex's weekly
/// allowance (T3 Code's usage window).
public struct UsageLimitWindow: Sendable, Hashable, Codable, Identifiable {
    public enum Kind: String, Sendable, Hashable, Codable {
        case session
        case weekly
        case monthly
        case other
    }

    /// Stable for the provider, so a later report of the same window replaces it.
    public var id: String
    public var kind: Kind
    /// Short name, e.g. "Session" or "Weekly".
    public var label: String
    /// How much of the window is used, 0–100.
    public var usedPercent: Double
    public var resetsAt: Date?
    /// The window's length, when known; it tells how far through the window the user is.
    public var durationMinutes: Int?
    /// Once the window is used up, the agent keeps working on the account's paid credits instead of stopping.
    public var continuesOnCredits: Bool

    public nonisolated init(
        id: String, kind: Kind, label: String, usedPercent: Double, resetsAt: Date? = nil, durationMinutes: Int? = nil,
        continuesOnCredits: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.label = label
        self.usedPercent = usedPercent.isFinite ? min(100, max(0, usedPercent)) : 0
        self.resetsAt = resetsAt
        self.durationMinutes = durationMinutes
        self.continuesOnCredits = continuesOnCredits
    }

    public nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(String.self, forKey: .id), kind: try container.decode(Kind.self, forKey: .kind),
            label: try container.decode(String.self, forKey: .label),
            usedPercent: try container.decode(Double.self, forKey: .usedPercent),
            resetsAt: try container.decodeIfPresent(Date.self, forKey: .resetsAt),
            durationMinutes: try container.decodeIfPresent(Int.self, forKey: .durationMinutes),
            continuesOnCredits: try container.decodeIfPresent(Bool.self, forKey: .continuesOnCredits) ?? false)
    }
}

/// A provider's usage windows as last reported, with when they were read.
public struct UsageLimits: Sendable, Hashable {
    /// Session windows first, then weekly, monthly and others.
    public private(set) var windows: [UsageLimitWindow]
    public var checkedAt: Date

    public nonisolated init(windows: [UsageLimitWindow], checkedAt: Date) {
        self.windows = Self.sorted(windows)
        self.checkedAt = checkedAt
    }

    /// Applies a report that may name only some windows: those it names are replaced (keeping a reset time or
    /// length the report leaves out), the others stay as they were.
    public nonisolated func applying(_ update: [UsageLimitWindow], at date: Date) -> UsageLimits {
        var byID = Dictionary(windows.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        for var window in update {
            if let existing = byID[window.id] {
                window.resetsAt = window.resetsAt ?? existing.resetsAt
                window.durationMinutes = window.durationMinutes ?? existing.durationMinutes
            }
            byID[window.id] = window
        }
        return UsageLimits(windows: Array(byID.values), checkedAt: max(date, checkedAt))
    }

    private nonisolated static func sorted(_ windows: [UsageLimitWindow]) -> [UsageLimitWindow] {
        func rank(_ kind: UsageLimitWindow.Kind) -> Int {
            switch kind {
            case .session: 0
            case .weekly: 1
            case .monthly: 2
            case .other: 3
            }
        }
        return windows.sorted { (rank($0.kind), $0.id) < (rank($1.kind), $1.id) }
    }
}

/// Something the user can run in an agent: a slash command such as `/compact` or one they added, or a skill.
public struct ProviderCommand: Sendable, Hashable, Identifiable, Codable {
    public enum Kind: Sendable, Hashable, Codable {
        case command
        /// Offered under `$` as well as `/`. Claude Code runs skills and custom commands alike as `/name`.
        case skill
    }

    public var name: String
    public var description: String?
    /// What the command takes after its name, such as `[file]`.
    public var argumentHint: String?
    public var kind: Kind
    /// Part of the agent itself, rather than added by the user, a project or a plugin.
    public var isBuiltIn: Bool
    /// The skill's file, which Codex takes along with the name.
    public var path: String?
    /// The agent runs it as `/name`. Codex's skills run only as `$name`.
    public var isSlashCommand: Bool

    public var id: String { name }

    public nonisolated init(
        name: String, description: String? = nil, argumentHint: String? = nil, kind: Kind = .command, isBuiltIn: Bool = false,
        path: String? = nil, isSlashCommand: Bool = true
    ) {
        self.name = name
        self.description = description
        self.argumentHint = argumentHint
        self.kind = kind
        self.isBuiltIn = isBuiltIn
        self.path = path
        self.isSlashCommand = isSlashCommand
    }

    /// Commands matching a query, best first: name, name prefix, name containing it, then description.
    public nonisolated static func matching(_ query: String, in commands: [ProviderCommand]) -> [ProviderCommand] {
        let query = query.lowercased()
        guard !query.isEmpty else { return commands }
        return commands.enumerated().compactMap { index, command -> (Int, Int, ProviderCommand)? in
            let name = command.name.lowercased()
            if name == query { return (0, index, command) }
            if name.hasPrefix(query) || name.split(separator: ":").last?.hasPrefix(query) == true { return (1, index, command) }
            if name.contains(query) { return (2, index, command) }
            if command.description?.lowercased().contains(query) == true { return (3, index, command) }
            return nil
        }
        .sorted { ($0.0, $0.1) < ($1.0, $1.1) }
        .map(\.2)
    }
}

/// Work an agent keeps running on its own, such as a background command or subagent, which can outlast the turn
/// that started it.
public struct BackgroundTask: Sendable, Hashable, Identifiable, Codable {
    public enum Kind: Sendable, Hashable, Codable {
        case agent
        case command
        case other
    }

    public var id: String
    public var title: String
    public var kind: Kind
    /// The provider's id of the tool call that started it, when known.
    public var toolCallID: String?

    public nonisolated init(id: String, title: String, kind: Kind, toolCallID: String? = nil) {
        self.id = id
        self.title = title
        self.kind = kind
        self.toolCallID = toolCallID
    }
}

/// What a session reports while it runs. Item ids are the provider's; Coincide maps them to
/// transcript items. A delta for an id that has not been seen yet starts a new item.
///
/// Codable because the agent host logs events and sends them to the app (`AgentHostWire`): renaming a case or
/// one of its labels changes what older logs and helpers say, so add cases instead.
public enum AgentEvent: Sendable, Hashable, Codable {
    /// The provider's session id, persisted so the thread can resume it later.
    /// Emit it again if a resume failed and a fresh session was created instead.
    case sessionStarted(id: String)
    /// The session moved to a new native id that still holds the whole conversation (for example a fork),
    /// so the thread needs no recap for it.
    case sessionContinued(id: String)
    case assistantTextDelta(itemID: String, delta: String)
    /// Authoritative full text for an assistant item; replaces anything streamed so far.
    case assistantText(itemID: String, text: String)
    case reasoningDelta(itemID: String, delta: String)
    case reasoningText(itemID: String, text: String)
    case toolStarted(ToolCallInfo)
    /// Refines a tool call's title or detail once more input has streamed in.
    case toolUpdated(ToolCallInfo)
    case toolOutput(id: String, delta: String)
    case toolCompleted(id: String, status: ItemStatus, output: String?)
    case approvalRequested(ApprovalRequest)
    /// The provider resolved or withdrew a pending approval itself.
    case approvalResolved(id: String)
    /// The agent asks the user one or more questions (Claude's AskUserQuestion, Codex's request_user_input, …).
    /// Answers go back through `answer(userInput:answers:)`.
    case userInputRequested(UserInputRequest)
    /// The provider withdrew or resolved a pending question itself.
    case userInputResolved(id: String)
    /// The agent's current plan or todo list, as markdown. Replaces the previous plan of the turn.
    case plan(text: String)
    case usage(TokenUsage)
    /// The user's subscription limits for this provider: the windows named here replace earlier reports of
    /// the same windows, and windows left out keep their last report.
    case rateLimits([UsageLimitWindow])
    /// The session reported which model it is actually using.
    case modelResolved(String)
    /// The provider discovered (or refreshed) its model list while running.
    case modelsDiscovered([ModelOption])
    case notice(String)
    /// Everything the agent now runs in the background; replaces the previous report.
    case backgroundWork([BackgroundTask])
    /// The commands and skills the agent offers in this session's folder; replaces the previous report.
    case commandsDiscovered([ProviderCommand])
    /// The provider started a turn on its own, without a prompt from Coincide: for example Claude Code
    /// answering a finished background task, or an extension waking the agent. The thread shows as
    /// running until the provider ends the turn with `.turnCompleted`, and Stop calls `interrupt()`.
    /// `note` says why, when known. Never emit it for a turn `send` started.
    case agentTurnStarted(note: String?)
    case turnCompleted(TurnOutcome)
    /// The underlying process ended. `error` is set when it ended unexpectedly.
    case sessionExited(error: String?)
}

/// A live, native provider session bound to one Coincide thread.
/// Implementations deliver events on the main actor, in order.
@MainActor
public protocol AgentSession: AnyObject {
    var provider: ProviderKind { get }
    /// Provider session id once known.
    var sessionID: String? { get }
    var onEvent: ((AgentEvent) -> Void)? { get set }

    /// Spawns the process and completes the handshake, resuming `resumeSessionID` when set.
    /// If resuming fails, start a fresh session and report its id with `.sessionStarted`.
    func start() async throws
    /// Starts a turn. Returns once the provider accepted it; progress arrives as events,
    /// ending with exactly one `.turnCompleted`. A session that had to replace its native session
    /// while sending (it reported `.sessionStarted` with a new id) sends `input.prompt(forNewSession: true)`.
    func send(_ input: AgentTurnInput) async throws
    func respond(to approvalID: String, optionID: String)
    /// Answers an approval that asked for text (`ApprovalRequest.textInput`).
    func respond(to approvalID: String, optionID: String, text: String?)
    /// Answers a `.userInputRequested` event. `answers` maps each question id to the chosen option labels
    /// or free text. An empty dictionary means the user dismissed the questions.
    func answer(userInput requestID: String, answers: [String: [String]])
    /// Asks the provider to stop the running turn. It should still end with `.turnCompleted(.interrupted)`.
    func interrupt()
    /// Ends the process. No events are expected afterwards.
    func shutdown()

    /// Whether the provider takes more messages into a running turn (`steer`), as T3 Code's active steering.
    var supportsSteering: Bool { get }
    /// Adds the user's message to the running turn, so the agent takes it into account without starting over;
    /// the turn still ends with one `.turnCompleted`. Returns once the provider accepted the message (a session may
    /// first wait briefly for the provider to start the turn). Throws when it cannot take one now (the turn has not
    /// started, is ending or is being stopped); the runner then sends the message after the turn instead. The input
    /// carries no recap: the session has seen the whole thread.
    func steer(_ input: AgentTurnInput) async throws
}

extension AgentSession {
    public func respond(to approvalID: String, optionID: String, text: String?) {
        respond(to: approvalID, optionID: optionID)
    }

    public func answer(userInput requestID: String, answers: [String: [String]]) {}

    public var supportsSteering: Bool { false }

    public func steer(_ input: AgentTurnInput) async throws {
        throw AgentError.providerError(String(localized: "\(provider.displayName) can't take messages while it works."))
    }
}

public struct ProviderStatus: Sendable, Hashable {
    public enum State: String, Sendable {
        case unknown
        case ready
        case notInstalled
        case notAuthenticated
        case error
    }

    public var state: State
    public var version: String?
    public var executable: URL?
    /// Account or plan, e.g. "user@example.com (Max)", when the provider reports it.
    public var account: String?
    public var message: String?
    /// The subscription's usage windows, when the check could read them.
    public var usageLimits: UsageLimits?
    /// The commands and skills the check found, from the user's home folder. Sessions report each folder's own.
    public var commands: [ProviderCommand] = []

    public nonisolated init(
        state: State, version: String? = nil, executable: URL? = nil, account: String? = nil, message: String? = nil,
        usageLimits: UsageLimits? = nil
    ) {
        self.state = state
        self.version = version
        self.executable = executable
        self.account = account
        self.message = message
        self.usageLimits = usageLimits
    }

    public nonisolated static let unknown = ProviderStatus(state: .unknown)
}

/// Knows how to find, probe and launch one provider CLI.
@MainActor
public protocol AgentProvider: AnyObject {
    var kind: ProviderKind { get }
    /// Executable names to look for on PATH, in order of preference.
    var executableNames: [String] { get }
    /// Setup hint shown when the provider is missing, e.g. "Install Claude Code and run `claude auth login`".
    var setupHint: String { get }

    /// Checks installation and sign-in. `executable` is nil when nothing was found on PATH.
    func detect(executable: URL?, environment: [String: String]) async -> ProviderStatus
    /// Models to offer in the picker. May run the CLI to discover them; fall back to a built-in list.
    func models(status: ProviderStatus, environment: [String: String]) async -> [ModelOption]
    func makeSession(_ launch: AgentLaunch) -> AgentSession
}

public enum AgentError: LocalizedError, Sendable {
    case notInstalled(ProviderKind)
    case notRunning
    case protocolError(String)
    case providerError(String)
    case timeout(String)

    public nonisolated var errorDescription: String? {
        switch self {
        case .notInstalled(let kind):
            String(localized: "\(kind.displayName) is not installed or could not be found on PATH.")
        case .notRunning: String(localized: "The agent session is not running.")
        case .protocolError(let message): String(localized: "Unexpected response from the agent: \(message)")
        case .providerError(let message): message
        case .timeout(let what): String(localized: "Timed out waiting for \(what).")
        }
    }
}
