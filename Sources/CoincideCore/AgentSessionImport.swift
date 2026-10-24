import CryptoKit
import Foundation

/// Exact pinned project-import providers. Other native adapters' resume support
/// does not imply a filesystem discovery/import contract.
public enum AgentSessionSource: String, Codable, Sendable, CaseIterable { case claudeAgent, codex
    public var provider: ProviderKind { self == .codex ? .codex : .claude }
}
public struct AgentSessionProfile: Codable, Sendable, Equatable, Identifiable {
    private struct Payload: Codable, Sendable, Equatable { let source: AgentSessionSource; let configuration: ProviderConfiguration; let transcriptsRoot: String; let id: UUID }
    private var storage: [Payload]
    public var source: AgentSessionSource { storage[0].source }
    public var configuration: ProviderConfiguration { storage[0].configuration }
    public var transcriptsRoot: String { storage[0].transcriptsRoot }
    public var id: UUID { storage[0].id }
    /// Host-captured CLI home/configuration root, never a remote request path.
    public init(configuration: ProviderConfiguration, transcriptsRoot: String) throws {
        let source: AgentSessionSource
        switch configuration.provider {
        case .codex: source = .codex; try configuration.codexRuntimeConfiguration?.validate()
        case .claude:
            source = .claudeAgent
            guard let runtime = configuration.claudeRuntimeConfiguration else { throw AgentSessionImportError.invalidProfile }
            try runtime.validate()
        }
        guard transcriptsRoot.hasPrefix("/"), transcriptsRoot != "/", !transcriptsRoot.contains("\0"), transcriptsRoot.utf8.count <= 4_096 else { throw AgentSessionImportError.invalidProfile }
        storage = [.init(source: source, configuration: configuration, transcriptsRoot: transcriptsRoot,
            id: try AppMCPAdmission.instanceID(configuration: configuration))]
    }
    public init(from decoder: any Decoder) throws {
        let value = try Payload(from: decoder)
        let checked = try Self(configuration: value.configuration, transcriptsRoot: value.transcriptsRoot)
        guard checked.source == value.source, checked.id == value.id else { throw AgentSessionImportError.invalidProfile }
        self = checked
    }
    public func encode(to encoder: any Encoder) throws { try storage[0].encode(to: encoder) }
}
public struct AgentSessionImportSource: Codable, Sendable, Equatable {
    public let provider: AgentSessionSource
    public let providerInstanceID: UUID
    public let providerSessionID: String
    public let filePath: String
    public let size: UInt64
    public let device: UInt64
    public let inode: UInt64
    public let modificationNanoseconds: Int64
    public let birthNanoseconds: Int64
    public let digest: String
    public var changeNanoseconds: Int64? = nil
}
public struct AgentSessionMessage: Codable, Sendable, Equatable {
    public let role: MessageRole
    public let text: String
    public let createdAt: Date
}
public struct AgentSessionTranscript: Codable, Sendable, Equatable {
    private struct Payload: Codable, Sendable, Equatable {
        let source: AgentSessionSource; let providerInstanceID: UUID; let providerSessionID: String
        let workspacePath: String; let title: String; let model: String?
        let createdAt: Date; let updatedAt: Date; let messages: [AgentSessionMessage]; let omittedMessageCount: Int
    }
    private var storage: [Payload]
    public var source: AgentSessionSource { storage[0].source }
    public var providerInstanceID: UUID { storage[0].providerInstanceID }
    public var providerSessionID: String { storage[0].providerSessionID }
    public var workspacePath: String { storage[0].workspacePath }
    public var title: String { storage[0].title }
    public var model: String? { storage[0].model }
    public var createdAt: Date { storage[0].createdAt }
    public var updatedAt: Date { storage[0].updatedAt }
    public var messages: [AgentSessionMessage] { storage[0].messages }
    public var omittedMessageCount: Int { storage[0].omittedMessageCount }
    init(source: AgentSessionSource, providerInstanceID: UUID, providerSessionID: String, workspacePath: String,
         title: String, model: String?, createdAt: Date, updatedAt: Date, messages: [AgentSessionMessage], omittedMessageCount: Int) {
        storage = [.init(source: source, providerInstanceID: providerInstanceID, providerSessionID: providerSessionID, workspacePath: workspacePath,
            title: title, model: model, createdAt: createdAt, updatedAt: updatedAt, messages: messages, omittedMessageCount: omittedMessageCount)]
    }
    public init(from decoder: any Decoder) throws { storage = [try Payload(from: decoder)] }
    public func encode(to encoder: any Encoder) throws { try storage[0].encode(to: encoder) }
}
public struct AgentSessionProjectCandidate: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let path: String
    public let title: String
    public let projectID: UUID?
    public let sources: [AgentSessionSource]
    public let threadCount: Int
    public let lastActiveAt: Date?
    public let alreadyImported: Bool
    public var git: AgentSessionProjectGit? = nil
}
public struct AgentSessionProjectGit: Codable, Sendable, Equatable {
    public let remoteKey: String?
    public let repository: String?
}
public struct AgentSessionScanResult: Codable, Sendable, Equatable {
    public let id: UUID
    public let candidates: [AgentSessionProjectCandidate]
    public let scannedAt: Date
    public let truncated: Bool
}
public struct AgentSessionImportReview: Codable, Sendable, Equatable, Identifiable {
    private struct Payload: Codable, Sendable, Equatable {
        let id: UUID; let digest: String; let scanID: UUID; let projectID: UUID; let expectedWorkspaceRoot: String
        let workspaceIdentity: GitWorktreeNodeIdentity; let profile: AgentSessionProfile
        let transcript: AgentSessionTranscript; let sources: [AgentSessionImportSource]
    }
    private var storage: [Payload]
    public var id: UUID { storage[0].id }; public var digest: String { storage[0].digest }; public var scanID: UUID { storage[0].scanID }
    public var projectID: UUID { storage[0].projectID }; public var expectedWorkspaceRoot: String { storage[0].expectedWorkspaceRoot }
    public var workspaceIdentity: GitWorktreeNodeIdentity { storage[0].workspaceIdentity }; public var profile: AgentSessionProfile { storage[0].profile }
    public var transcript: AgentSessionTranscript { storage[0].transcript }; public var sources: [AgentSessionImportSource] { storage[0].sources }
    init(id: UUID, digest: String, scanID: UUID, projectID: UUID, expectedWorkspaceRoot: String, workspaceIdentity: GitWorktreeNodeIdentity,
         profile: AgentSessionProfile, transcript: AgentSessionTranscript, sources: [AgentSessionImportSource]) {
        storage = [.init(id: id, digest: digest, scanID: scanID, projectID: projectID, expectedWorkspaceRoot: expectedWorkspaceRoot,
            workspaceIdentity: workspaceIdentity, profile: profile, transcript: transcript, sources: sources)]
    }
    public init(from decoder: any Decoder) throws { storage = [try Payload(from: decoder)] }
    public func encode(to encoder: any Encoder) throws { try storage[0].encode(to: encoder) }
}
public struct AgentSessionImportPage: Sendable, Equatable {
    public let scanID: UUID
    public let reviews: [AgentSessionImportReview]
    public let alreadyImported: [AgentSessionImportSource]
    public let duplicates: [AgentSessionImportSource]
    public let skippedCount: Int
    public let nextCursor: UUID?
    public let complete: Bool
}
public enum AgentSessionImportError: Error, LocalizedError, Sendable, Equatable {
    case invalidProfile, invalidRequest, unavailable, changed, limit, staleScan
    public var errorDescription: String? {
        switch self {
        case .invalidProfile: "Choose a captured Codex or Claude provider profile."
        case .invalidRequest: "The session import request is invalid."
        case .unavailable: "The agent session could not be read safely."
        case .changed: "The project or native transcript changed. Scan again before importing."
        case .limit: "The session scan or selected history exceeds its bounded limit."
        case .staleScan: "This session scan expired. Scan again before importing."
        }
    }
}
public enum AgentSessionImportProtocol {
    public static let maximumDiscoveredTranscripts = 5_000
    public static let maximumRecentTranscripts = 100
    public static let maximumTranscriptBytes = 4 * 1_024 * 1_024 * 1_024
    public static let maximumHistoryBytes = 32 * 1_024 * 1_024
    public static let maximumRecords = 100_000
    public static let maximumMessages = 200
    public static let recentInterval: TimeInterval = 30 * 24 * 60 * 60
    public static func payload<T: Encodable>(_ value: T) throws -> Data { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return try encoder.encode(value) }
    public static func digest<T: Encodable>(_ value: T) throws -> String { SHA256.hash(data: try payload(value)).map { String(format: "%02x", $0) }.joined() }
    public static func threadID(providerInstanceID: UUID, providerSessionID: String) -> UUID { TaskOrchestration.derivedID(providerInstanceID, "agent-session-import:" + providerSessionID) }
}
