import Foundation

public enum ProviderKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case codex, claude, acp
    public static var builtIn: [Self] { [.codex, .claude] }
    public var id: String { rawValue }
    public var name: String { switch self { case .codex: "Codex"; case .claude: "Claude"; case .acp: "ACP Agent" } }
    public var executable: String { switch self { case .codex: "codex"; case .claude: "claude"; case .acp: "" } }
}

public enum ProviderEvent: Codable, Sendable, Equatable {
    case thread(String)
    case turn(String)
    case delta(id: String, role: MessageRole, text: String)
    case message(ChatMessage)
    case approval(ApprovalRequest)
    case approvalDismissed(JSONValue)
    case completed(ThreadState)
    case failure(String)
    case connectionClosed(String)
    case configuration(JSONValue)
    case entity(ProviderEntityUpdate)
    case associateEntity(ProviderEntityKey, clientMessageID: String)
    case activity(ProviderActivity)
    case sessionApproval(ApprovalRequest)
    case sessionApprovalDismissed(JSONValue)
    case submissionFailed(clientMessageID: String, reason: String)
    case steeringCapabilitiesChanged
    indirect case context(runID: UUID, event: ProviderEvent)
}

public protocol ProviderSession: Actor {
    nonisolated var events: AsyncStream<ProviderEvent> { get }
    func models() async throws -> [ProviderModel]
    func send(text: String, thread: CodingThread) async throws
    func send(input: ProviderInput, thread: CodingThread) async throws
    func interrupt() async throws
    func steeringCapabilities() async -> ProviderSteeringCapabilities
    func steer(input: ProviderInput, thread: CodingThread, expectedTurnID: String, clientMessageID: String) async throws -> ProviderSteeringReceipt
    func respond(_ request: ApprovalRequest, allow: Bool) async throws
    func answer(_ request: ApprovalRequest, answers: [String: String]) async throws
    func choose(_ request: ApprovalRequest, optionID: String) async throws
    func close() async
    func historyCapabilities(threadID: String) async throws -> ProviderHistoryCapabilities
    func conversationSnapshot(threadID: String) async throws -> ProviderConversationSnapshot
    func historyPage(threadID: String, cursor: String?, limit: Int) async throws -> ProviderHistoryPage
    func forkConversation(source: ProviderConversationReference, boundary: ProviderHistoryBoundary, configuration: ProviderConfiguration) async throws -> ProviderConversationSnapshot
    func revertConversation(thread: ProviderConversationReference, beforeTurnID: String, expectedHeadTurnID: String) async throws -> ProviderConversationSnapshot
}

extension ProviderSession {
    public func steeringCapabilities() async -> ProviderSteeringCapabilities { .init(unavailableReason: ProviderSteeringError(.unsupported).localizedDescription) }
    public func steer(input: ProviderInput, thread: CodingThread, expectedTurnID: String, clientMessageID: String) async throws -> ProviderSteeringReceipt { throw ProviderSteeringError(.unsupported) }
    public func historyCapabilities(threadID: String) async throws -> ProviderHistoryCapabilities { throw ProviderHistoryError(.unsupported) }
    public func conversationSnapshot(threadID: String) async throws -> ProviderConversationSnapshot { throw ProviderHistoryError(.unsupported) }
    public func historyPage(threadID: String, cursor: String? = nil, limit: Int = 100) async throws -> ProviderHistoryPage { throw ProviderHistoryError(.unsupported) }
    public func forkConversation(source: ProviderConversationReference, boundary: ProviderHistoryBoundary, configuration: ProviderConfiguration) async throws -> ProviderConversationSnapshot { throw ProviderHistoryError(.unsupported) }
    public func revertConversation(thread: ProviderConversationReference, beforeTurnID: String, expectedHeadTurnID: String) async throws -> ProviderConversationSnapshot { throw ProviderHistoryError(.unsupported) }
    public func choose(_ request: ApprovalRequest, optionID: String) async throws {
        throw CoincideError("This provider does not offer selectable permission options.")
    }
    public func send(input: ProviderInput, thread: CodingThread) async throws {
        guard input.images.isEmpty else { throw CoincideError("This provider does not support image input.") }
        try await send(text: input.text, thread: thread)
    }
}

public enum ProviderSessions {
    public static func make(for thread: CodingThread) throws -> any ProviderSession {
        if thread.provider == .acp {
            guard let agent = thread.acpAgent else { throw CoincideError("Choose an ACP agent in Settings before sending a message.") }
            try agent.validate()
            guard let executable = ProcessChannel.findExecutable(agent.executable) else {
                throw CoincideError("The executable for \(agent.name) is not installed or executable.")
            }
            let cwd = URL(fileURLWithPath: thread.workspacePath)
            if agent.experimentalV2 == true { return try ACP2Session(executable: executable, arguments: agent.arguments, cwd: cwd) }
            return try ACPSession(executable: executable, arguments: agent.arguments, cwd: cwd)
        }
        guard let executable = ProcessChannel.findExecutable(thread.provider.executable) else {
            throw CoincideError("Install and sign in to \(thread.provider.name) CLI before sending a message.")
        }
        let cwd = URL(fileURLWithPath: thread.workspacePath)
        switch thread.provider {
        case .codex: return try CodexSession(executable: executable, cwd: cwd)
        case .claude: return try ClaudeSession(executable: executable, cwd: cwd, resumeID: thread.providerThreadID)
        case .acp: throw CoincideError("Choose an ACP agent.")
        }
    }
}
