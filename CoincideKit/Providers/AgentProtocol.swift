import Foundation

/// Everything a provider needs to start (or resume) a native session for a thread.
public struct AgentLaunch: Sendable {
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

/// One user turn. `text` already includes any handoff recap from other providers.
/// The model, effort, access and interaction mode may differ from the previous turn;
/// sessions apply such changes before running the turn.
public struct AgentTurnInput: Sendable {
    public var text: String
    /// Absolute paths of attached images.
    public var imagePaths: [String]
    public var selection: ModelSelection
    public var accessMode: AccessMode
    public var interactionMode: InteractionMode

    public nonisolated init(
        text: String, imagePaths: [String] = [], selection: ModelSelection, accessMode: AccessMode,
        interactionMode: InteractionMode
    ) {
        self.text = text
        self.imagePaths = imagePaths
        self.selection = selection
        self.accessMode = accessMode
        self.interactionMode = interactionMode
    }
}

public struct ToolCallInfo: Sendable, Hashable {
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

public struct ApprovalRequest: Sendable, Hashable {
    /// Id the session needs back in `respond(to:optionID:)`.
    public var id: String
    public var category: ToolCategory
    public var title: String
    public var detail: String?
    public var options: [ApprovalOption]
    public var toolCallID: String?

    public nonisolated init(
        id: String, category: ToolCategory, title: String, detail: String? = nil, options: [ApprovalOption],
        toolCallID: String? = nil
    ) {
        self.id = id
        self.category = category
        self.title = title
        self.detail = detail
        self.options = options
        self.toolCallID = toolCallID
    }

    /// Allow once / allow for the session / deny, for providers that do not supply their own choices.
    public nonisolated static let standardOptions: [ApprovalOption] = [
        ApprovalOption(id: "allow", label: String(localized: "Allow"), kind: .allowOnce),
        ApprovalOption(id: "allow_always", label: String(localized: "Always allow"), kind: .allowAlways),
        ApprovalOption(id: "deny", label: String(localized: "Deny"), kind: .deny),
    ]
}

public enum TurnOutcome: Sendable, Hashable {
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

/// What a session reports while it runs. Item ids are the provider's; Coincide maps them to
/// transcript items. A delta for an id that has not been seen yet starts a new item.
public enum AgentEvent: Sendable, Hashable {
    /// The provider's session id, persisted so the thread can resume it later.
    /// Emit it again if a resume failed and a fresh session was created instead.
    case sessionStarted(id: String)
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
    /// The agent's current plan or todo list, as markdown. Replaces the previous plan of the turn.
    case plan(text: String)
    case usage(TokenUsage)
    /// The session reported which model it is actually using.
    case modelResolved(String)
    /// The provider discovered (or refreshed) its model list while running.
    case modelsDiscovered([ModelOption])
    case notice(String)
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
    /// ending with exactly one `.turnCompleted`.
    func send(_ input: AgentTurnInput) async throws
    func respond(to approvalID: String, optionID: String)
    /// Asks the provider to stop the running turn. It should still end with `.turnCompleted(.interrupted)`.
    func interrupt()
    /// Ends the process. No events are expected afterwards.
    func shutdown()
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

    public nonisolated init(
        state: State, version: String? = nil, executable: URL? = nil, account: String? = nil, message: String? = nil
    ) {
        self.state = state
        self.version = version
        self.executable = executable
        self.account = account
        self.message = message
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
