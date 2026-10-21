import Foundation

public enum ProviderKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case codex, claude
    public var id: String { rawValue }
    public var name: String { self == .codex ? "Codex" : "Claude" }
    public var executable: String { self == .codex ? "codex" : "claude" }
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
    indirect case context(runID: UUID, event: ProviderEvent)
}

public protocol ProviderSession: Actor {
    nonisolated var events: AsyncStream<ProviderEvent> { get }
    func models() async throws -> [ProviderModel]
    func send(text: String, thread: CodingThread) async throws
    func interrupt() async throws
    func respond(_ request: ApprovalRequest, allow: Bool) async throws
    func answer(_ request: ApprovalRequest, answers: [String: String]) async throws
    func close() async
}

public enum ProviderSessions {
    public static func make(for thread: CodingThread) throws -> any ProviderSession {
        guard let executable = ProcessChannel.findExecutable(thread.provider.executable) else {
            throw CoincideError("Install and sign in to \(thread.provider.name) CLI before sending a message.")
        }
        let cwd = URL(fileURLWithPath: thread.workspacePath)
        switch thread.provider {
        case .codex: return try CodexSession(executable: executable, cwd: cwd)
        case .claude: return try ClaudeSession(executable: executable, cwd: cwd, resumeID: thread.providerThreadID)
        }
    }
}
