import Foundation

public enum ProviderKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case codex, claude, opencode, pi, muse, antigravity, acp
    public static var builtIn: [Self] { [.codex, .claude, .opencode, .pi, .muse, .antigravity] }
    public var id: String { rawValue }
    public var name: String { switch self { case .codex: "Codex"; case .claude: "Claude"; case .opencode: "OpenCode"; case .pi: "Pi"; case .muse: "Muse"; case .antigravity: "Antigravity"; case .acp: "ACP Agent" } }
    public var executable: String { switch self { case .codex: "codex"; case .claude: "claude"; case .opencode: "opencode"; case .pi: "pi"; case .muse: "muse"; case .antigravity: "agy_acp_server.par"; case .acp: "" } }
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
    case runEntity(runID: UUID, update: ProviderEntityUpdate)
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
    func openCodeInventory() async throws -> OpenCodeMetadataSnapshot
    func codexDefaultModelSelection() async throws -> CodexDefaultModelSelection
    func codexAccountSnapshot() async throws -> CodexAccountSnapshot
    func acpConnectionInfo() async throws -> ACPConnectionInfo
    func send(text: String, thread: CodingThread) async throws
    func send(input: ProviderInput, thread: CodingThread) async throws
    func interrupt() async throws
    func interrupt(expectedRunID: UUID) async throws
    func steeringCapabilities() async -> ProviderSteeringCapabilities
    func steer(input: ProviderInput, thread: CodingThread, expectedTurnID: String, clientMessageID: String) async throws -> ProviderSteeringReceipt
    func respond(_ request: ApprovalRequest, allow: Bool) async throws
    func answer(_ request: ApprovalRequest, answers: [String: String]) async throws
    func selectAnswers(_ request: ApprovalRequest, selections: [String: [String]]) async throws
    func selectAnswers(_ request: ApprovalRequest, selections: [String: [String]], notes: [String: String]) async throws
    func choose(_ request: ApprovalRequest, optionID: String) async throws
    func close() async
    func historyCapabilities(threadID: String) async throws -> ProviderHistoryCapabilities
    func conversationSnapshot(threadID: String) async throws -> ProviderConversationSnapshot
    func historyPage(threadID: String, cursor: String?, limit: Int) async throws -> ProviderHistoryPage
    func forkConversation(source: ProviderConversationReference, boundary: ProviderHistoryBoundary, configuration: ProviderConfiguration) async throws -> ProviderConversationSnapshot
    func revertConversation(thread: ProviderConversationReference, beforeTurnID: String, expectedHeadTurnID: String) async throws -> ProviderConversationSnapshot
}

extension ProviderSession {
    /// The default retains older adapters' behavior. Adapters with weak native
    /// turn identities can additionally fence interruption by the local run.
    public func interrupt(expectedRunID: UUID) async throws { try await interrupt() }
    public func openCodeInventory() async throws -> OpenCodeMetadataSnapshot {
        throw CoincideError("This provider does not expose a native OpenCode catalog.")
    }
    public func acpConnectionInfo() async throws -> ACPConnectionInfo {
        throw CoincideError("This provider does not expose an ACP connection.")
    }
    public func selectAnswers(_ request: ApprovalRequest, selections: [String: [String]]) async throws {
        throw CoincideError("This provider does not expose selectable question answers.")
    }
    public func selectAnswers(_ request: ApprovalRequest, selections: [String: [String]], notes: [String: String]) async throws {
        throw CoincideError("This provider does not support question answers with notes.")
    }
    public func codexAccountSnapshot() async throws -> CodexAccountSnapshot {
        throw CoincideError("This provider does not expose a Codex account.")
    }
    public func codexDefaultModelSelection() async throws -> CodexDefaultModelSelection {
        throw CoincideError("This provider does not expose Codex model defaults.")
    }
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
    public static func make(for thread: CodingThread, antigravityStateRoot: URL? = nil) throws -> any ProviderSession {
        if thread.provider == .antigravity {
            try AntigravityConfigurationValidation.configuration(.init(thread: thread))
            guard let configuration = thread.antigravityConfiguration,
                  let executable = ProcessChannel.findExecutable(configuration.executable) else {
                throw CoincideError("Choose the Antigravity runtime and its paired harness in Settings before sending a message.")
            }
            let registryRoot = (antigravityStateRoot?.deletingLastPathComponent() ??
                FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Coincide", isDirectory: true))
                .appendingPathComponent("AntigravitySettings", isDirectory: true)
            try AntigravityAccountRegistry.validateKnownGeneration(configuration, rootURL: registryRoot)
            return AntigravitySession(executable: executable, cwd: URL(fileURLWithPath: thread.workspacePath),
                configuration: configuration, permission: thread.permission,
                credentialProvider: { try AntigravityCredentialStore.read(configuration: configuration) }, stateRoot: antigravityStateRoot)
        }
        if thread.provider == .muse {
            try MuseConfigurationValidation.configuration(.init(thread: thread))
            guard let configuration = thread.museConfiguration, let executable = ProcessChannel.findExecutable(configuration.executable) else {
                throw CoincideError("Install and sign in to Muse before sending a message.")
            }
            return MuseSession(executable: executable, cwd: URL(fileURLWithPath: thread.workspacePath), configuration: configuration, permission: thread.permission)
        }
        if thread.provider == .pi {
            try PiConfigurationValidation.configuration(.init(thread: thread))
            guard let configuration = thread.piConfiguration, let executable = ProcessChannel.findExecutable(configuration.executable) else {
                throw CoincideError("Install and sign in to Pi before sending a message.")
            }
            return PiSession(executable: executable, cwd: URL(fileURLWithPath: thread.workspacePath), configuration: configuration, permission: thread.permission)
        }
        if thread.provider == .opencode {
            guard let configuration = thread.openCodeConfiguration else { throw OpenCodeConfiguration.invalid() }
            try OpenCodeConfigurationValidation.thread(thread)
            guard let executable = ProcessChannel.findExecutable(configuration.executable) else {
                throw CoincideError("Install and sign in to the selected OpenCode version before sending a message.")
            }
            if configuration.generation == .v1 {
                return OpenCodeV1Session(executable: executable, cwd: URL(fileURLWithPath: thread.workspacePath), configuration: configuration)
            }
            return OpenCodeV2Session(executable: executable, cwd: URL(fileURLWithPath: thread.workspacePath), configuration: configuration)
        }
        if thread.provider == .acp {
            guard let agent = thread.acpAgent else { throw CoincideError("Choose an ACP agent in Settings before sending a message.") }
            try agent.validate()
            guard let executable = ProcessChannel.findExecutable(agent.executable) else {
                throw CoincideError("The executable for \(agent.name) is not installed or executable.")
            }
            let cwd = URL(fileURLWithPath: thread.workspacePath)
            let grokMode = try ProviderConfiguration(thread: thread).resolvedGrokRuntimeMode()
            let arguments = grokMode.map(GrokACP.arguments(runtimeMode:)) ?? agent.arguments
            if agent.experimentalV2 == true { return try ACP2Session(executable: executable, arguments: arguments, cwd: cwd, integration: agent.integration, grokRuntimeMode: grokMode) }
            return try ACPSession(executable: executable, arguments: arguments, cwd: cwd, integration: agent.integration, grokRuntimeMode: grokMode)
        }
        guard let executable = ProcessChannel.findExecutable(thread.provider.executable) else {
            throw CoincideError("Install and sign in to \(thread.provider.name) CLI before sending a message.")
        }
        let cwd = URL(fileURLWithPath: thread.workspacePath)
        switch thread.provider {
        case .codex: return try CodexSession(executable: executable, cwd: cwd)
        case .claude: return try ClaudeSession(executable: executable, cwd: cwd, resumeID: thread.providerThreadID)
        case .opencode: throw OpenCodeConfiguration.invalid()
        case .pi: throw PiConfiguration.invalid()
        case .muse: throw MuseConfiguration.invalid()
        case .antigravity: throw AntigravityConfiguration.invalid()
        case .acp: throw CoincideError("Choose an ACP agent.")
        }
    }
}
