import Foundation

public enum ProviderKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case codex, claude, opencode, pi, muse, antigravity, acp
    public static var builtIn: [Self] { [.codex, .claude] }
    public var isSupported: Bool { self == .codex || self == .claude }
    public var id: String { rawValue }
    public var name: String { switch self { case .codex: "Codex"; case .claude: "Claude"; case .opencode: "OpenCode"; case .pi: "Pi"; case .muse: "Muse"; case .antigravity: "Antigravity"; case .acp: "ACP Agent" } }
    public var executable: String { switch self { case .codex: "codex"; case .claude: "claude"; case .opencode: "opencode"; case .pi: "pi"; case .muse: "muse"; case .antigravity: "agy_acp_server.par"; case .acp: "" } }
}

/// Ephemeral app-tool authority. Only a private provider handoff may expose
/// the header; this value cannot enter the durable provider configuration.
public struct AppMCPConnection: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let endpoint: URL
    public let authorizationHeader: String
    public let scopeID: UUID
    /// Host-selected readiness proof, independent of provider-supplied names.
    /// Full app scopes retain the ordinary read tool; context-only scopes must
    /// prove the exact archive reader before a contextual prompt can be sent.
    public let requiredToolName: String
    public init(endpoint: URL, authorizationHeader: String, scopeID: UUID, requiredToolName: String = "t3_thread_read") throws {
        guard endpoint.scheme == "http", endpoint.host == "127.0.0.1", endpoint.port.map({ $0 > 0 && $0 <= 65_535 }) == true,
              endpoint.path == "/mcp", endpoint.user == nil, endpoint.password == nil, endpoint.query == nil, endpoint.fragment == nil,
              ["t3_thread_read", "t3_context_read"].contains(requiredToolName),
              authorizationHeader.hasPrefix("Bearer "), authorizationHeader.utf8.count == 50,
              authorizationHeader.dropFirst(7).utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }) else {
            throw CoincideError("The app tool connection could not be configured.")
        }
        self.endpoint = endpoint; self.authorizationHeader = authorizationHeader; self.scopeID = scopeID
        self.requiredToolName = requiredToolName
    }
    public var description: String { "AppMCPConnection(redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: EmptyCollection<Mirror.Child>()) }

    /// Native providers may echo registration settings in status, tools or errors.
    /// Scrub incoming values before they reach event projection or persistence.
    func redacting(_ text: String) -> String {
        text.replacingOccurrences(of: authorizationHeader, with: "[private app tool credential]")
            .replacingOccurrences(of: String(authorizationHeader.dropFirst(7)), with: "[private app tool credential]")
    }
    func redacting(_ value: JSONValue) -> JSONValue {
        var remaining = 100_000
        return redacting(value, depth: 0, remaining: &remaining)
    }
    private func redacting(_ value: JSONValue, depth: Int, remaining: inout Int) -> JSONValue {
        guard depth < 128, remaining > 0 else { return .string("[provider value exceeded the inspection limit]") }
        remaining -= 1
        switch value {
        case .string(let text): return .string(redacting(text))
        case .array(let values): return .array(values.map { redacting($0, depth: depth + 1, remaining: &remaining) })
        case .object(let fields):
            var result: [String: JSONValue] = [:]
            for (name, child) in fields { result[redacting(name)] = redacting(child, depth: depth + 1, remaining: &remaining) }
            return .object(result)
        default: return value
        }
    }
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
    indirect case usage(ProviderUsageUpdate)
    case entity(ProviderEntityUpdate)
    case runEntity(runID: UUID, update: ProviderEntityUpdate)
    case associateEntity(ProviderEntityKey, clientMessageID: String)
    case activity(ProviderActivity)
    case sessionApproval(ApprovalRequest)
    case sessionApprovalDismissed(JSONValue)
    case submissionFailed(clientMessageID: String, reason: String)
    case steeringCapabilitiesChanged
    case claudeHistoryEvidence(ClaudeRunHistoryEvidence)
    case piHistoryEvidence(PiRunHistoryEvidence)
    case piHistoryBarrier(UUID)
    indirect case context(runID: UUID, event: ProviderEvent)
}

public protocol ProviderSession: Actor {
    nonisolated var events: AsyncStream<ProviderEvent> { get }
    nonisolated var supportsAppMCP: Bool { get }
    func configureAppMCP(_ connection: AppMCPConnection) async throws
    func models() async throws -> [ProviderModel]
    func codexSkills(forceReload: Bool) async throws -> ProviderSkillInventory
    func providerCommands(forceReload: Bool) async throws -> ProviderCommandInventory
    func openCodeInventory() async throws -> OpenCodeMetadataSnapshot
    func codexDefaultModelSelection() async throws -> CodexDefaultModelSelection
    func codexAccountSnapshot() async throws -> CodexAccountSnapshot
    func acpConnectionInfo() async throws -> ACPConnectionInfo
    func send(text: String, thread: CodingThread) async throws
    func send(input: ProviderInput, thread: CodingThread) async throws
    func contextInputDisposition(input: ProviderInput, thread: CodingThread) async throws -> ProviderContextInputDisposition
    /// Captures an owned native baseline without sending input. The caller must
    /// persist this preparation before admitting its exact one-use prompt.
    func preparePiRun(input: ProviderInput, thread: CodingThread) async throws -> PiRunHistoryPreparation
    func sendPreparedPi(input: ProviderInput, thread: CodingThread, preparation: PiRunHistoryPreparation) async throws
    func preparePiSteering(input: ProviderInput, thread: CodingThread, target: ProviderSteeringTarget, clientMessageID: String) async throws -> PiSteeringHistoryPreparation
    func sendPreparedPiSteering(input: ProviderInput, thread: CodingThread, target: ProviderSteeringTarget, clientMessageID: String, preparation: PiSteeringHistoryPreparation) async throws -> ProviderSteeringReceipt
    func cancelPiSteeringPreparation(_ preparation: PiSteeringHistoryPreparation) async
    func piHistorySnapshot(threadID: String) async throws -> PiHistorySnapshot
    func applyPiHistory(review: PiHistoryReviewEvidence, configuration: ProviderConfiguration, operationID: UUID,
        candidate: @escaping @Sendable (PiHistoryCandidate) async throws -> Void) async throws -> ProviderConversationSnapshot
    func inspectPiHistoryCandidate(review: PiHistoryReviewEvidence, candidate: PiHistoryCandidate,
        configuration: ProviderConfiguration) async throws -> ProviderConversationSnapshot
    func inspectPiHistoryOriginal(expected: PiHistorySnapshot) async throws -> PiHistorySnapshot
    func piHistoryEventBarrier(_ id: UUID) async throws
    func interrupt() async throws
    func interrupt(expectedRunID: UUID) async throws
    func steeringCapabilities() async -> ProviderSteeringCapabilities
    func steer(input: ProviderInput, thread: CodingThread, target: ProviderSteeringTarget, clientMessageID: String) async throws -> ProviderSteeringReceipt
    func steer(input: ProviderInput, thread: CodingThread, expectedTurnID: String, clientMessageID: String) async throws -> ProviderSteeringReceipt
    func respond(_ request: ApprovalRequest, allow: Bool) async throws
    func answer(_ request: ApprovalRequest, answers: [String: String]) async throws
    func selectAnswers(_ request: ApprovalRequest, selections: [String: [String]]) async throws
    func selectAnswers(_ request: ApprovalRequest, selections: [String: [String]], notes: [String: String]) async throws
    func choose(_ request: ApprovalRequest, optionID: String) async throws
    func close() async
    func historyCapabilities(threadID: String) async throws -> ProviderHistoryCapabilities
    func openCodeV1HistorySnapshot(threadID: String) async throws -> OpenCodeV1HistorySnapshot
    func applyOpenCodeV1History(review: OpenCodeV1HistoryReviewEvidence, kind: ConversationHistoryKind,
        configuration: ProviderConfiguration,
        candidate: @escaping @Sendable (OpenCodeV1HistoryCandidate) async throws -> Void) async throws -> ProviderConversationSnapshot
    func inspectOpenCodeV1HistoryCandidate(review: OpenCodeV1HistoryReviewEvidence, candidate: OpenCodeV1HistoryCandidate,
        configuration: ProviderConfiguration) async throws -> ProviderConversationSnapshot
    func openCodeV2HistorySnapshot(threadID: String) async throws -> OpenCodeV2HistorySnapshot
    func applyOpenCodeV2History(review: OpenCodeV2HistoryReviewEvidence, kind: ConversationHistoryKind, configuration: ProviderConfiguration) async throws -> ProviderConversationSnapshot
    func clearOpenCodeV2HistoryStage(expected: OpenCodeV2HistorySnapshot) async throws -> OpenCodeV2HistorySnapshot
    func conversationSnapshot(threadID: String) async throws -> ProviderConversationSnapshot
    func historyPage(threadID: String, cursor: String?, limit: Int) async throws -> ProviderHistoryPage
    func forkConversation(source: ProviderConversationReference, boundary: ProviderHistoryBoundary, configuration: ProviderConfiguration) async throws -> ProviderConversationSnapshot
    func revertConversation(thread: ProviderConversationReference, beforeTurnID: String, expectedHeadTurnID: String) async throws -> ProviderConversationSnapshot
}

extension ProviderSession {
    public func contextInputDisposition(input: ProviderInput, thread: CodingThread) async throws -> ProviderContextInputDisposition { .ordinary }
    public nonisolated var supportsAppMCP: Bool { false }
    public func configureAppMCP(_ connection: AppMCPConnection) async throws { throw MCPError(.unavailable) }
    public func preparePiRun(input: ProviderInput, thread: CodingThread) async throws -> PiRunHistoryPreparation {
        throw ProviderHistoryError(.unsupported)
    }
    public func sendPreparedPi(input: ProviderInput, thread: CodingThread, preparation: PiRunHistoryPreparation) async throws {
        throw ProviderHistoryError(.unsupported)
    }
    public func preparePiSteering(input: ProviderInput, thread: CodingThread, target: ProviderSteeringTarget, clientMessageID: String) async throws -> PiSteeringHistoryPreparation {
        throw ProviderSteeringError(.unsupported)
    }
    public func sendPreparedPiSteering(input: ProviderInput, thread: CodingThread, target: ProviderSteeringTarget, clientMessageID: String, preparation: PiSteeringHistoryPreparation) async throws -> ProviderSteeringReceipt {
        throw ProviderSteeringError(.unsupported)
    }
    public func cancelPiSteeringPreparation(_ preparation: PiSteeringHistoryPreparation) async {}
    public func piHistorySnapshot(threadID: String) async throws -> PiHistorySnapshot { throw ProviderHistoryError(.unsupported) }
    public func applyPiHistory(review: PiHistoryReviewEvidence, configuration: ProviderConfiguration, operationID: UUID,
        candidate: @escaping @Sendable (PiHistoryCandidate) async throws -> Void) async throws -> ProviderConversationSnapshot { throw ProviderHistoryError(.unsupported) }
    public func inspectPiHistoryCandidate(review: PiHistoryReviewEvidence, candidate: PiHistoryCandidate,
        configuration: ProviderConfiguration) async throws -> ProviderConversationSnapshot { throw ProviderHistoryError(.unsupported) }
    public func inspectPiHistoryOriginal(expected: PiHistorySnapshot) async throws -> PiHistorySnapshot { throw ProviderHistoryError(.unsupported) }
    public func piHistoryEventBarrier(_ id: UUID) async throws { throw ProviderHistoryError(.unsupported) }
    public func codexSkills(forceReload: Bool = false) async throws -> ProviderSkillInventory {
        throw ProviderSkillError(.unsupported)
    }
    public func providerCommands(forceReload: Bool = false) async throws -> ProviderCommandInventory {
        throw ProviderCommandError(.unsupported)
    }
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
    public func steer(input: ProviderInput, thread: CodingThread, target: ProviderSteeringTarget, clientMessageID: String) async throws -> ProviderSteeringReceipt {
        try target.validate()
        guard case .nativeTurn(let id) = target else { throw ProviderSteeringError(.unsupported) }
        return try await steer(input: input, thread: thread, expectedTurnID: id, clientMessageID: clientMessageID)
    }
    public func steer(input: ProviderInput, thread: CodingThread, expectedTurnID: String, clientMessageID: String) async throws -> ProviderSteeringReceipt { throw ProviderSteeringError(.unsupported) }
    public func historyCapabilities(threadID: String) async throws -> ProviderHistoryCapabilities { throw ProviderHistoryError(.unsupported) }
    public func openCodeV1HistorySnapshot(threadID: String) async throws -> OpenCodeV1HistorySnapshot { throw ProviderHistoryError(.unsupported) }
    public func applyOpenCodeV1History(review: OpenCodeV1HistoryReviewEvidence, kind: ConversationHistoryKind,
        configuration: ProviderConfiguration,
        candidate: @escaping @Sendable (OpenCodeV1HistoryCandidate) async throws -> Void) async throws -> ProviderConversationSnapshot { throw ProviderHistoryError(.unsupported) }
    public func inspectOpenCodeV1HistoryCandidate(review: OpenCodeV1HistoryReviewEvidence, candidate: OpenCodeV1HistoryCandidate,
        configuration: ProviderConfiguration) async throws -> ProviderConversationSnapshot { throw ProviderHistoryError(.unsupported) }
    public func openCodeV2HistorySnapshot(threadID: String) async throws -> OpenCodeV2HistorySnapshot { throw ProviderHistoryError(.unsupported) }
    public func applyOpenCodeV2History(review: OpenCodeV2HistoryReviewEvidence, kind: ConversationHistoryKind, configuration: ProviderConfiguration) async throws -> ProviderConversationSnapshot { throw ProviderHistoryError(.unsupported) }
    public func clearOpenCodeV2HistoryStage(expected: OpenCodeV2HistorySnapshot) async throws -> OpenCodeV2HistorySnapshot { throw ProviderHistoryError(.unsupported) }
    public func conversationSnapshot(threadID: String) async throws -> ProviderConversationSnapshot { throw ProviderHistoryError(.unsupported) }
    public func historyPage(threadID: String, cursor: String? = nil, limit: Int = 100) async throws -> ProviderHistoryPage { throw ProviderHistoryError(.unsupported) }
    public func forkConversation(source: ProviderConversationReference, boundary: ProviderHistoryBoundary, configuration: ProviderConfiguration) async throws -> ProviderConversationSnapshot { throw ProviderHistoryError(.unsupported) }
    public func revertConversation(thread: ProviderConversationReference, beforeTurnID: String, expectedHeadTurnID: String) async throws -> ProviderConversationSnapshot { throw ProviderHistoryError(.unsupported) }
    public func choose(_ request: ApprovalRequest, optionID: String) async throws {
        throw CoincideError("This provider does not offer selectable permission options.")
    }
    public func send(input: ProviderInput, thread: CodingThread) async throws {
        guard input.images.isEmpty else { throw CoincideError("This provider does not support image input.") }
        try await send(text: input.providerText(), thread: thread)
    }
}

public enum ProviderSessions {
    public static func make(for thread: CodingThread, antigravityStateRoot: URL? = nil,
                            antigravityInstallation: AntigravityInstallation = .shared,
                            antigravityAccountRoot: URL? = nil,
                            codexInstallation: CodexInstallation = .shared,
                            codexOwnedRuntime: CodexOwnedRuntimeBroker = .shared) throws -> any ProviderSession {
        guard thread.provider.isSupported else { throw CoincideError("Coincide supports Codex and Claude only.") }
        if thread.provider == .codex {
            try CodexRuntimeConfigurationValidation.configuration(.init(thread: thread))
            let configuration = thread.codexRuntimeConfiguration ?? .init()
            if configuration.authenticationMode == .ownedChatGPT {
                return try codexOwnedRuntime.makeSession(configuration: configuration, cwd: URL(fileURLWithPath: thread.workspacePath), installation: codexInstallation)
            }
            let lease = try codexInstallation.acquire(configuration: configuration)
            let environment = try CodexRuntimeEnvironment.make(configuration: configuration)
            return try CodexSession(executable: lease.resolved.executable, cwd: URL(fileURLWithPath: thread.workspacePath),
                                    environment: environment, installationLease: lease, runtimeConfiguration: configuration)
        }
        let claudeCapture = thread.activeRun?.configuration ?? ProviderConfiguration(thread: thread)
        if thread.provider == .claude, let configuration = claudeCapture.claudeRuntimeConfiguration {
            try claudeCapture.validateClaudeConfiguration()
            let launch = claudeCapture.claudeLaunchSelection
            // Discovery never adopts a deferred selection or resumes a reserved
            // fresh UUID which has no transcript until an explicit user input.
            let resume = thread.claudeResumeSelection?.kind == .freshSession && launch == nil ? nil : claudeCapture.nativeThreadID ?? thread.providerThreadID
            return try ClaudeSession(executable: URL(fileURLWithPath: configuration.executable),
                cwd: URL(fileURLWithPath: claudeCapture.workspacePath), resumeID: resume,
                configuration: configuration, launchSelection: launch,
                modelOptions: try ClaudeModelControl.options(in: claudeCapture))
        }
        guard let executable = ProcessChannel.findExecutable(thread.provider.executable) else {
            throw CoincideError("Install and sign in to \(thread.provider.name) CLI before sending a message.")
        }
        let cwd = URL(fileURLWithPath: thread.workspacePath)
        switch thread.provider {
        case .codex: throw CodexRuntimeConfiguration.invalid()
        case .claude: return try ClaudeSession(executable: executable, cwd: cwd, resumeID: thread.providerThreadID,
            modelOptions: try ClaudeModelControl.options(in: thread.activeRun?.configuration ?? .init(thread: thread)))
        case .opencode: throw OpenCodeConfiguration.invalid()
        case .pi: throw PiConfiguration.invalid()
        case .muse: throw MuseConfiguration.invalid()
        case .antigravity: throw AntigravityConfiguration.invalid()
        case .acp: throw CoincideError("Choose an ACP agent.")
        }
    }
}
